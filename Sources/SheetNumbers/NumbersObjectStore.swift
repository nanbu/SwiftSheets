import Foundation
import SheetCore

/// What a reader needs from a Numbers document's object graph: an object by identifier, its type, the
/// identifiers of a type, and a file of the package. `NumbersDocument` — the mutable store the writer and
/// `inspect` also use — answers from everything decoded up front; `NumbersObjectIndex` answers from a table of
/// contents and decodes on demand (spec Appendix B.40.3). The code that reads cells, styles and formatting runs
/// is written against this protocol so both readers share it.
protocol NumbersObjectStore: AnyObject {
    func object(_ id: Int) -> ProtoMessage?
    func typeName(_ id: Int) -> String?
    /// All identifiers whose object is of a type (by registry name, e.g. "TST.TableInfoArchive"), sorted.
    func identifiers(ofType name: String) -> [Int]
    func blob(_ path: String) -> Data?
}

extension NumbersDocument: NumbersObjectStore {}

/// A Numbers document as a table of contents rather than a decoded tree (spec Appendix B.40.3).
///
/// Every IWA part of the package is expanded once and its archive headers (`TSP.ArchiveInfo`) are decoded, which
/// says where each object lies and what type it is — but no object is decoded until it is asked for. A part
/// holding nothing but tiles (`TST.Tile`, the 256-row blocks a table's cells live in) has its expanded bytes let
/// go after indexing and is expanded again when a walk reaches it; every other part (the document, the sheets,
/// the table models, the string and formula lists, the stylesheet) keeps its expanded bytes, and an object decoded
/// from one of those is kept. What this costs over a whole read is the index, the non-tile parts and one tile at
/// a time, instead of the whole tree.
final class NumbersObjectIndex: NumbersObjectStore {
    struct Slot {
        let file: Int
        let offset: Int
        let length: Int
        let typeName: String?
    }
    private var files: [(name: String, load: () throws -> Data)] = []
    /// The expanded archive stream of each IWA file, nil once let go (a tile-only file).
    private var payloads: [Data?] = []
    private var tileOnly: [Bool] = []
    private var slots: [Int: Slot] = [:]
    private var cache: [Int: ProtoMessage] = [:]
    private var blobLoaders: [String: () throws -> Data] = [:]
    private var blobs: [String: Data] = [:]
    /// The identifiers of every object, by type, for `identifiers(ofType:)`.
    private var byType: [String: [Int]] = [:]
    /// The tile-only files that were expanded again by a walk — what a test holds the reader to.
    private(set) var reexpansions = 0

    /// The single-file form, or a zipped package bundle (`Index.zip` inside the outer package).
    convenience init(data: Data, limits: ZipLimits = ZipLimits()) throws {
        try self.init(archive: try ZipArchive(data: data, limits: limits), limits: limits)
    }

    /// The single-file form on disk, read through positioned reads rather than mapped: the index holds what it
    /// keeps of every IWA, and the tiles are expanded again from the file as a walk reaches them (Rev 4.31).
    convenience init(url: URL, limits: ZipLimits = ZipLimits()) throws {
        try self.init(archive: try ZipArchive(source: try FileByteSource(url: url), limits: limits), limits: limits)
    }

    init(archive zip: ZipArchive, limits: ZipLimits) throws {
        if zip.contains(".iwph") { throw UnopenableInput.encryptedNumbers.error }
        try add(zip, limits: limits)
        try finishLoading()
    }

    /// A document saved as a folder (a package on disk): `Index.zip` — or an `Index/` folder of IWA files —
    /// beside `Metadata/` and `Data/` (spec §4.2).
    init(folder url: URL, limits: ZipLimits = ZipLimits()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent(".iwph").path) { throw UnopenableInput.encryptedNumbers.error }
        let indexZip = url.appendingPathComponent("Index.zip")
        if fm.fileExists(atPath: indexZip.path) {
            try add(try ZipArchive(source: try FileByteSource(url: indexZip), limits: limits), limits: limits)
        }
        let base = url.resolvingSymlinksInPath()
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw SheetError.ioFailure(detail: "cannot list \(url.lastPathComponent)")
        }
        var found: [(String, URL)] = []
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let resolved = file.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(base.path) else { continue }
            let relative = resolved.dropFirst(base.path.count).drop { $0 == "/" }
            guard relative != "Index.zip", !relative.hasPrefix(".") else { continue }
            found.append((String(relative), file))
        }
        for (name, file) in found.sorted(by: { $0.0 < $1.0 }) {
            try store(name) { try Data(contentsOf: file, options: .mappedIfSafe) }
        }
        try finishLoading()
    }

    private func add(_ zip: ZipArchive, limits: ZipLimits) throws {
        let names = zip.entries.keys.sorted { (zip.entries[$0]!.localHeaderOffset) < (zip.entries[$1]!.localHeaderOffset) }
        for name in names where !name.hasSuffix("/") {
            if name.lowercased().hasSuffix("index.zip") {   // a zipped package bundle: the IWAs live one level down
                let inner = try ZipArchive(data: try zip.read(name), limits: limits)
                for n in inner.entries.keys.sorted() where !n.hasSuffix("/") { try store(n) { try inner.read(n) } }
            } else {
                try store(name) { try zip.read(name) }
            }
        }
    }

    private func store(_ name: String, _ load: @escaping () throws -> Data) throws {
        guard name.hasSuffix(".iwa") else { blobLoaders[name] = load; return }
        let data = try load()
        guard IWAFile.isIWA(data) else { blobLoaders[name] = load; return }
        let payload = try IWAFile.payload(of: data)
        let fileIndex = files.count
        files.append((name, load))
        var allTiles = true
        var sawAny = false
        try NumbersObjectIndex.walkArchives(payload, path: name) { identifier, typeName, offset, length in
            slots[identifier] = Slot(file: fileIndex, offset: offset, length: length, typeName: typeName)
            if let typeName { byType[typeName, default: []].append(identifier) }
            sawAny = true
            if typeName != "TST.Tile" { allTiles = false }
        }
        let dropped = sawAny && allTiles
        tileOnly.append(dropped)
        payloads.append(dropped ? nil : payload)
    }

    /// The archive segments of an expanded IWA stream: each one's identifier, and the type and place of its first
    /// object (the one `object(_:)` answers with, as `NumbersDocument` does).
    static func walkArchives(_ payload: Data, path: String, _ body: (_ identifier: Int, _ typeName: String?, _ offset: Int, _ length: Int) throws -> Void) throws {
        try payload.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            func varint() throws -> Int {
                var v = 0, shift = 0
                while true {
                    guard i < b.count else { throw SheetError.malformedPart(path: path, detail: "truncated archive length") }
                    let x = b[i]; i += 1
                    v |= Int(x & 0x7F) << shift
                    if x & 0x80 == 0 { return v }
                    shift += 7
                    if shift > 56 { throw SheetError.malformedPart(path: path, detail: "archive length varint too long") }
                }
            }
            while i < b.count {
                let hlen = try varint()
                guard hlen >= 0, hlen <= b.count - i else { throw SheetError.malformedPart(path: path, detail: "truncated ArchiveInfo") }
                let header = try ProtoMessage(decoding: Data(UnsafeBufferPointer(rebasing: b[i..<(i + hlen)])), typeName: "TSP.ArchiveInfo")
                i += hlen
                let identifier = header.int("identifier") ?? 0
                var first = true
                for info in header.messages("message_infos") {
                    let len = info.int("length") ?? 0
                    guard len >= 0, len <= b.count - i else { throw SheetError.malformedPart(path: path, detail: "truncated object payload") }
                    if first {
                        let type = info.int("type") ?? 0
                        try body(identifier, type == 0 ? nil : NumbersSchema.shared.registry[type], i, len)
                        first = false
                    }
                    i += len
                }
            }
        }
    }

    private func finishLoading() throws {
        guard slots[NumbersDocument.documentID] != nil else { throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "no document object (id 1)") }
        for key in byType.keys { byType[key]?.sort() }
    }

    // MARK: - NumbersObjectStore

    func object(_ id: Int) -> ProtoMessage? {
        if let hit = cache[id] { return hit }
        guard let slot = slots[id] else { return nil }
        guard let payload = expandedPayload(of: slot.file) else { return nil }
        let object = try? ProtoMessage(decoding: payload.subdata(in: (payload.startIndex + slot.offset)..<(payload.startIndex + slot.offset + slot.length)), typeName: slot.typeName)
        // kept for next time unless it is a tile or a large list (a table's string list decodes to many times its
        // bytes, and a walk turns it into a dictionary once and has no further use for the tree)
        if let object, !tileOnly[slot.file], slot.length <= NumbersObjectIndex.largestCachedObject { cache[id] = object }
        return object
    }

    /// Objects past this many bytes are decoded each time they are asked for rather than kept.
    static let largestCachedObject = 256 * 1024

    /// The expanded bytes of a file: kept for most, made again for a tile-only file each time it is asked for.
    private func expandedPayload(of file: Int) -> Data? {
        if let kept = payloads[file] { return kept }
        guard let data = try? files[file].load(), let payload = try? IWAFile.payload(of: data) else { return nil }
        reexpansions += 1
        return payload
    }

    func typeName(_ id: Int) -> String? { slots[id]?.typeName }
    func identifiers(ofType name: String) -> [Int] { byType[name] ?? [] }

    func blob(_ path: String) -> Data? {
        if let kept = blobs[path] { return kept }
        guard let load = blobLoaders[path], let data = try? load() else { return nil }
        blobs[path] = data
        return data
    }

    /// How many objects the index knows, and how many files it keeps expanded — for tests.
    var objectCount: Int { slots.count }
    var keptFileCount: Int { payloads.filter { $0 != nil }.count }
    var fileCount: Int { files.count }
}
