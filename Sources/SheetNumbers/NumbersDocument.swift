import Foundation
import SheetCore

/// The object store of one Numbers document: every file of the package, every IWA object by identifier, and the
/// bookkeeping to add objects (new ids after the maximum, PackageMetadata kept in step).
final class NumbersDocument {
    enum Entry { case iwa(IWAFile); case blob(Data) }
    static let documentID = 1
    static let packageID = 2

    private(set) var order: [String] = []
    private(set) var files: [String: Entry] = [:]
    /// object id → (file path, archive index)
    private(set) var locations: [Int: (String, Int)] = [:]
    private var maxID = 0
    private(set) var lastZipEntryIsBundleIndex = false

    init(data: Data) throws {
        let zip = try ZipArchive(data: data)
        if zip.contains(".iwph") { throw SheetError.unsupportedFeature("encrypted Numbers documents are not supported") }
        let names = zip.entries.keys.sorted { (zip.entries[$0]!.localHeaderOffset) < (zip.entries[$1]!.localHeaderOffset) }
        for name in names where !name.hasSuffix("/") {
            let blob = try zip.read(name)
            if name.lowercased().hasSuffix("index.zip") {   // a zipped package bundle: the IWAs live one level down
                let inner = try ZipArchive(data: blob)
                for n in inner.entries.keys.sorted() where !n.hasSuffix("/") { try store(n, try inner.read(n)) }
                lastZipEntryIsBundleIndex = true
            } else {
                try store(name, blob)
            }
        }
        guard locations[NumbersDocument.documentID] != nil else { throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "no document object (id 1)") }
        maxID = locations.keys.max() ?? 0
    }

    private func store(_ name: String, _ blob: Data) throws {
        if name.hasSuffix(".iwa"), IWAFile.isIWA(blob) {
            let f = try IWAFile(data: blob, path: name)
            for (i, a) in f.archives.enumerated() { locations[a.identifier] = (name, i) }
            files[name] = .iwa(f)
        } else {
            files[name] = .blob(blob)
        }
        order.append(name)
    }

    // MARK: - Objects

    func object(_ id: Int) -> ProtoMessage? {
        guard let (path, i) = locations[id], case .iwa(let f)? = files[path] else { return nil }
        return f.archives[i].objects.first
    }
    func typeName(_ id: Int) -> String? { object(id)?.typeName }
    func archive(_ id: Int) -> IWAArchive? {
        guard let (path, i) = locations[id], case .iwa(let f)? = files[path] else { return nil }
        return f.archives[i]
    }

    /// All identifiers whose object is of a type (by registry name, e.g. "TST.TableInfoArchive").
    func identifiers(ofType name: String) -> [Int] {
        locations.keys.filter { typeName($0) == name }.sorted()
    }

    func blob(_ path: String) -> Data? { if case .blob(let d)? = files[path] { return d }; return nil }

    // MARK: - Mutation

    func update(_ id: Int, _ body: (inout ProtoMessage) -> Void) {
        guard let (path, i) = locations[id], case .iwa(var f)? = files[path] else { return }
        var obj = f.archives[i].objects[0]
        body(&obj)
        f.archives[i].objects[0] = obj
        syncReferences(&f.archives[i])
        files[path] = .iwa(f)
    }

    func replace(_ id: Int, with obj: ProtoMessage) { update(id) { $0 = obj } }

    /// `message_infos[0].object_references` must list every referenced object; Numbers relies on it.
    private func syncReferences(_ a: inout IWAArchive) {
        let refs = a.objects[0].allReferences()
        var infos = a.header.messages("message_infos")
        guard !infos.isEmpty else { return }
        var uniq: [Int] = []
        for r in refs where !uniq.contains(r) { uniq.append(r) }
        infos[0].remove("object_references")
        for r in uniq { infos[0].fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.MessageInfo", "object_references")!, value: .varint(UInt64(r)))) }
        a.header.set("message_infos", messages: infos)
    }

    func nextID() -> Int {
        maxID += 1
        update(NumbersDocument.packageID) { $0.set("last_object_identifier", int: maxID) }
        return maxID
    }

    /// Adds an object. `file` names an existing IWA file to append to, or a new one to create ("Index/Tables/Tile-{id}.iwa"
    /// style names get the id substituted). Returns the new id.
    @discardableResult
    func add(_ obj: ProtoMessage, file: String, version: [Int] = [1, 0, 5]) throws -> Int {
        let id = nextID()
        // an object read from a newer Numbers than our registry knows has no type id to write back — that is the
        // file's doing, not the caller's, so it is an error rather than a trap
        guard let type = obj.typeName, let typeID = NumbersSchema.shared.registryByName[type] else {
            throw SheetError.unsupportedFeature("object type \(obj.typeName ?? "unknown") is not in the bundled Numbers registry")
        }
        var info = ProtoMessage(typeName: "TSP.MessageInfo")
        info.set("type", int: typeID)
        for v in version { info.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.MessageInfo", "version")!, value: .varint(UInt64(v)))) }
        info.set("length", int: obj.encodedSize)
        var header = ProtoMessage(typeName: "TSP.ArchiveInfo")
        header.set("identifier", int: id)
        header.set("message_infos", messages: [info])
        var a = IWAArchive(header: header, objects: [obj])
        syncReferences(&a)
        let path = file.replacingOccurrences(of: "{id}", with: String(id))
        if case .iwa(var f)? = files[path] {
            f.archives.append(a)
            locations[id] = (path, f.archives.count - 1)
            files[path] = .iwa(f)
        } else {
            files[path] = .iwa(IWAFile(archives: [a]))
            locations[id] = (path, 0)
            order.append(path)
        }
        return id
    }

    /// Removes an object, its archive and — when the file becomes empty — the file itself. The package metadata is
    /// kept in step: a component that no longer has an object, or an external reference to it, makes Numbers declare
    /// the document damaged.
    func remove(_ id: Int) {
        guard let (path, i) = locations[id], case .iwa(var f)? = files[path] else { return }
        f.archives.remove(at: i)
        locations[id] = nil
        for (k, v) in locations where v.0 == path && v.1 > i { locations[k] = (path, v.1 - 1) }
        if f.archives.isEmpty { files[path] = nil; order.removeAll { $0 == path } } else { files[path] = .iwa(f) }
        forgetComponent(id)
    }

    /// Drops the `TSP.ComponentInfo` of an object and every external reference naming it.
    func forgetComponent(_ id: Int) {
        update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            comps.removeAll { $0.int("identifier") == id }
            for i in comps.indices {
                let refs = comps[i].messages("external_references").filter { $0.int("object_identifier") != id && $0.int("component_identifier") != id }
                comps[i].remove("external_references")
                for r in refs { comps[i].append("external_references", message: r) }
            }
            pkg.set("components", messages: comps)
        }
    }

    /// The `TSP.ComponentInfo` identifier of the component an object lives in — the package metadata names each
    /// component by a locator, which is its IWA file without the "Index/" prefix and the ".iwa" suffix. A component
    /// that saved to its default place leaves `locator` empty and only names its `preferred_locator`.
    func componentID(forObject id: Int) -> Int? {
        guard let (path, _) = locations[id], path.hasPrefix("Index/"), path.hasSuffix(".iwa") else { return nil }
        let locator = String(path.dropFirst("Index/".count).dropLast(".iwa".count))
        guard let pkg = object(NumbersDocument.packageID) else { return nil }
        for c in pkg.messages("components") {
            let name = c.string("locator").flatMap { $0.isEmpty ? nil : $0 } ?? c.string("preferred_locator") ?? ""
            if name == locator { return c.int("identifier") }
        }
        return nil
    }

    /// Records that one component now names objects living in another. Numbers keeps this list itself, and a
    /// document whose cross-component references are missing from it is one it offers to repair.
    func addExternalReferences(from component: Int, to objects: [(object: Int, component: Int)]) {
        guard !objects.isEmpty else { return }
        update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            guard let i = comps.firstIndex(where: { $0.int("identifier") == component }) else { return }
            var known = Set(comps[i].messages("external_references").compactMap { ref -> String? in
                guard let o = ref.int("object_identifier"), let c = ref.int("component_identifier") else { return nil }
                return "\(o)|\(c)"
            })
            for entry in objects where known.insert("\(entry.object)|\(entry.component)").inserted {
                var ref = ProtoMessage(typeName: "TSP.ComponentExternalReference")
                ref.set("object_identifier", int: entry.object)
                ref.set("component_identifier", int: entry.component)
                comps[i].append("external_references", message: ref)
            }
            pkg.set("components", messages: comps)
        }
    }

    func setBlob(_ path: String, _ data: Data) { if files[path] == nil { order.append(path) }; files[path] = .blob(data) }

    // MARK: - Output

    /// The single-file `.numbers` package. Every entry is stored, not deflated — that is what Numbers itself writes
    /// (the IWA payload is already Snappy-compressed) and what Numbers expects to find.
    func encoded() -> Data {
        var zip = ZipWriter()
        for name in order {
            switch files[name] {
            case .iwa(let f)?: zip.add(name, f.encoded(), stored: true)
            case .blob(let d)?: zip.add(name, d, stored: true)
            case nil: continue
            }
        }
        return zip.finish()
    }

    /// Invariants Numbers checks when opening a document; anything reported here makes it offer to repair the file.
    func integrityProblems() -> [String] {
        var problems: [String] = []
        guard let pkg = object(NumbersDocument.packageID) else { return ["no package metadata (object 2)"] }
        let components = pkg.messages("components")
        for c in components {
            guard let id = c.int("identifier") else { continue }
            if object(id) == nil { problems.append("component \(id) has no object") }
            if let locator = c.string("locator"), !locator.isEmpty, locations[id] == nil {
                problems.append("component \(id) points at Index/\(locator).iwa, which is not in the package")
            }
            for e in c.messages("external_references") {
                if let o = e.int("object_identifier"), o != 0, object(o) == nil { problems.append("component \(id) references missing object \(o)") }
                if let ci = e.int("component_identifier"), ci != 0, object(ci) == nil { problems.append("component \(id) references missing component \(ci)") }
            }
        }
        for id in locations.keys {
            for r in object(id)?.allReferences() ?? [] where r != 0 && object(r) == nil {
                problems.append("object \(id) (\(typeName(id) ?? "?")) references missing object \(r)")
            }
        }
        if let last = pkg.int("last_object_identifier"), let maximum = locations.keys.max(), last < maximum {
            problems.append("last_object_identifier \(last) is below the highest object id \(maximum)")
        }
        return problems
    }
}
