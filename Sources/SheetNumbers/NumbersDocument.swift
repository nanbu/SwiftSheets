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
    func add(_ obj: ProtoMessage, file: String, version: [Int] = [1, 0, 5]) -> Int {
        let id = nextID()
        guard let type = obj.typeName, let typeID = NumbersSchema.shared.registryByName[type] else { preconditionFailure("object type \(obj.typeName ?? "?") is not in the registry") }
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

    func remove(_ id: Int) {
        guard let (path, i) = locations[id], case .iwa(var f)? = files[path] else { return }
        f.archives.remove(at: i)
        locations[id] = nil
        for (k, v) in locations where v.0 == path && v.1 > i { locations[k] = (path, v.1 - 1) }
        if f.archives.isEmpty { files[path] = nil; order.removeAll { $0 == path } } else { files[path] = .iwa(f) }
    }

    func setBlob(_ path: String, _ data: Data) { if files[path] == nil { order.append(path) }; files[path] = .blob(data) }

    // MARK: - Output

    /// The single-file `.numbers` package (a ZIP of IWAs and blobs — the layout Numbers writes itself).
    func encoded() -> Data {
        var zip = ZipWriter()
        for name in order {
            switch files[name] {
            case .iwa(let f)?: zip.add(name, f.encoded())
            case .blob(let d)?: zip.add(name, d, stored: name.hasSuffix(".jpg") || name.hasSuffix(".png"))
            case nil: continue
            }
        }
        return zip.finish()
    }
}
