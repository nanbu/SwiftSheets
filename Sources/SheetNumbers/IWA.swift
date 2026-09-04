import Foundation
import SheetCore

/// One IWA archive segment: a `TSP.ArchiveInfo` header followed by its objects (almost always one).
struct IWAArchive: Hashable {
    var header: ProtoMessage      // TSP.ArchiveInfo
    var objects: [ProtoMessage]

    var identifier: Int { header.int("identifier") ?? 0 }
    /// The registry type id of object `i`.
    func typeID(_ i: Int = 0) -> Int? { let infos = header.messages("message_infos"); return i < infos.count ? infos[i].int("type") : nil }

    /// Re-emits the segment; `message_infos[i].length` is refreshed from the objects.
    func encoded() -> Data {
        var h = header
        let infos = h.messages("message_infos")
        var updated: [ProtoMessage] = []
        for (i, var info) in infos.enumerated() {
            if i < objects.count { info.set("length", int: objects[i].encodedSize) }
            updated.append(info)
        }
        h.set("message_infos", messages: updated)
        let hb = h.encoded()
        var out = Data()
        var n = hb.count
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        out.append(hb)
        for o in objects { out.append(o.encoded()) }
        return out
    }
}

/// An `.iwa` file: 4-byte chunk headers (0x00 + 24-bit little-endian length) framing Snappy blocks whose
/// concatenation is a sequence of archive segments (spec §10, figure 4).
struct IWAFile: Hashable {
    var archives: [IWAArchive] = []

    static func isIWA(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < b.count {
                guard i + 4 <= b.count, b[i] == 0 else { return false }
                let len = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16
                i += 4 + len
            }
            return i == b.count && !b.isEmpty
        }
    }

    /// The decompressed archive stream (what byte-level round-trip tests compare). Read where it lies: the file
    /// is not copied into an array to be walked, and each block is expanded straight from it.
    static func payload(of data: Data) throws -> Data {
        try data.withUnsafeBytes { raw -> Data in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            var out = Data()
            while i < b.count {
                guard i + 4 <= b.count, b[i] == 0 else { throw SheetError.corruptedContainer(detail: "IWA chunk header") }
                let len = Int(b[i + 1]) | Int(b[i + 2]) << 8 | Int(b[i + 3]) << 16
                guard i + 4 + len <= b.count else { throw SheetError.corruptedContainer(detail: "IWA chunk truncated") }
                let chunk = UnsafeBufferPointer(rebasing: b[(i + 4)..<(i + 4 + len)])
                if let d = try? Snappy.decompress(chunk) { out.append(d) } else { out.append(chunk) }   // some writers leave chunks uncompressed
                i += 4 + len
            }
            return out
        }
    }

    init(data: Data, path: String) throws {
        let stream = try IWAFile.payload(of: data)
        try self.init(payload: stream, path: path)
    }

    init(payload: Data, path: String) throws {
        let b = [UInt8](payload)
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
            guard i + hlen <= b.count else { throw SheetError.malformedPart(path: path, detail: "truncated ArchiveInfo") }
            let header = try ProtoMessage(decoding: Data(b[i..<(i + hlen)]), typeName: "TSP.ArchiveInfo")
            i += hlen
            var objects: [ProtoMessage] = []
            for info in header.messages("message_infos") {
                let len = info.int("length") ?? 0
                guard i + len <= b.count else { throw SheetError.malformedPart(path: path, detail: "truncated object payload") }
                let type = info.int("type") ?? 0
                let name = type == 0 ? nil : NumbersSchema.shared.registry[type]
                objects.append(try ProtoMessage(decoding: Data(b[i..<(i + len)]), typeName: name))
                i += len
            }
            archives.append(IWAArchive(header: header, objects: objects))
        }
    }

    init(archives: [IWAArchive]) { self.archives = archives }

    /// The archive stream, uncompressed.
    func payload() -> Data {
        var out = Data()
        for a in archives { out.append(a.encoded()) }
        return out
    }

    /// The framed, Snappy-compressed file bytes.
    func encoded() -> Data {
        let stream = payload()
        var out = Data()
        var rest = stream[...]
        repeat {
            let chunk = Data(rest.prefix(65536))
            rest = rest.dropFirst(chunk.count)
            let packed = Snappy.compress(chunk)
            out.append(0)
            out.append(UInt8(packed.count & 0xFF)); out.append(UInt8((packed.count >> 8) & 0xFF)); out.append(UInt8((packed.count >> 16) & 0xFF))
            out.append(packed)
        } while !rest.isEmpty
        return out
    }
}
