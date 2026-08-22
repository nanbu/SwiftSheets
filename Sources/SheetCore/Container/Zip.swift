import Foundation
import Compression

/// Minimal ZIP container reader: central directory → entries; stored (0) and deflate (8); no ZIP64, no encryption.
package struct ZipArchive: Sendable {
    package struct Entry: Sendable { package let name: String; package let method: UInt16; package let crc32: UInt32; package let compressedSize: Int; package let uncompressedSize: Int; package let localHeaderOffset: Int }

    private let data: Data
    package let entries: [String: Entry]

    package init(data: Data) throws {
        self.data = data
        // the central directory is read straight out of the buffer: a package has as many parts as it has sheets,
        // and copying the whole file into an array for each of them is how a 50 MB workbook costs a gigabyte
        self.entries = try data.withUnsafeBytes { raw -> [String: Entry] in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 22 else { throw SheetError.corruptedContainer(detail: "file too small") }
            var eocd = -1
            var i = bytes.count - 22
            let lowest = max(0, bytes.count - 22 - 65535)
            while i >= lowest {
                if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw SheetError.corruptedContainer(detail: "end of central directory not found") }
            let count = Int(Zip.u16(bytes, eocd + 10))
            let cdSize = Int(Zip.u32(bytes, eocd + 12))
            let cdOffset = Int(Zip.u32(bytes, eocd + 16))
            guard cdOffset != 0xFFFF_FFFF, cdOffset + cdSize <= bytes.count else { throw SheetError.corruptedContainer(detail: "ZIP64 or corrupt central directory") }
            var entries: [String: Entry] = [:]
            entries.reserveCapacity(count)
            var p = cdOffset
            for _ in 0..<count {
                guard p >= 0, p + 46 <= bytes.count, Zip.u32(bytes, p) == 0x0201_4b50 else { throw SheetError.corruptedContainer(detail: "bad central directory entry") }
                let method = Zip.u16(bytes, p + 10), crc = Zip.u32(bytes, p + 16)
                let csize = Int(Zip.u32(bytes, p + 20)), usize = Int(Zip.u32(bytes, p + 24))
                let nameLen = Int(Zip.u16(bytes, p + 28)), extraLen = Int(Zip.u16(bytes, p + 30)), commentLen = Int(Zip.u16(bytes, p + 32))
                let localOffset = Int(Zip.u32(bytes, p + 42))
                guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw SheetError.corruptedContainer(detail: "ZIP64 entry") }
                // the header's own lengths are attacker-controlled: every slice below must be inside the buffer
                guard p + 46 + nameLen + extraLen + commentLen <= bytes.count else { throw SheetError.corruptedContainer(detail: "central directory entry runs past the end of the file") }
                guard localOffset + 30 <= bytes.count else { throw SheetError.corruptedContainer(detail: "local header offset past the end of the file") }
                let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[(p + 46)..<(p + 46 + nameLen)]), as: UTF8.self)
                entries[name] = Entry(name: name, method: method, crc32: crc, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: localOffset)
                p += 46 + nameLen + extraLen + commentLen
            }
            return entries
        }
    }

    package func contains(_ name: String) -> Bool { entries[name] != nil }

    package func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw SheetError.corruptedContainer(detail: "missing part \(name)") }
        let h = e.localHeaderOffset
        let start = try data.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard h >= 0, h + 30 <= bytes.count, Zip.u32(bytes, h) == 0x0403_4b50 else { throw SheetError.corruptedContainer(detail: "bad local header for \(name)") }
            let nameLen = Int(Zip.u16(bytes, h + 26)), extraLen = Int(Zip.u16(bytes, h + 28))
            return h + 30 + nameLen + extraLen
        }
        guard e.compressedSize >= 0, start + e.compressedSize <= data.count else { throw SheetError.corruptedContainer(detail: "truncated data for \(name)") }
        let base = data.startIndex
        let payload = data.subdata(in: (base + start)..<(base + start + e.compressedSize))
        switch e.method {
        case 0: return payload
        case 8: return try Zip.inflate(payload, expectedSize: e.uncompressedSize)
        default: throw SheetError.corruptedContainer(detail: "unsupported compression method \(e.method) for \(name)")
        }
    }
}

/// ZIP writer: deflate (method 8) via the Compression framework, falling back to stored when that does not shrink.
package struct ZipWriter {
    private struct Entry { let name: [UInt8]; let method: UInt16; let crc: UInt32; let csize: Int; let usize: Int; let offset: Int }
    private var entries: [Entry] = []
    private var body = Data()
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1  // 2026-01-01; readers ignore it

    package init() {}

    /// Adds an entry. `stored: true` writes it uncompressed (ODS needs its `mimetype` first and stored).
    package mutating func add(_ name: String, _ data: Data, stored: Bool = false) {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if !stored, data.count > 64, let deflated = Zip.deflate(data), deflated.count < data.count { method = 8; payload = deflated }
        let offset = body.count
        var h = Data()
        h.append(Zip.le32(0x0403_4b50)); h.append(Zip.le16(20)); h.append(Zip.le16(0x0800)); h.append(Zip.le16(method))
        h.append(Zip.le16(dosTime)); h.append(Zip.le16(dosDate)); h.append(Zip.le32(crc))
        h.append(Zip.le32(UInt32(payload.count))); h.append(Zip.le32(UInt32(data.count)))
        h.append(Zip.le16(UInt16(nameBytes.count))); h.append(Zip.le16(0)); h.append(contentsOf: nameBytes)
        body.append(h); body.append(payload)
        entries.append(Entry(name: nameBytes, method: method, crc: crc, csize: payload.count, usize: data.count, offset: offset))
    }

    package func finish() -> Data {
        var cd = Data()
        for e in entries {
            cd.append(Zip.le32(0x0201_4b50)); cd.append(Zip.le16(20)); cd.append(Zip.le16(20)); cd.append(Zip.le16(0x0800)); cd.append(Zip.le16(e.method))
            cd.append(Zip.le16(dosTime)); cd.append(Zip.le16(dosDate)); cd.append(Zip.le32(e.crc))
            cd.append(Zip.le32(UInt32(e.csize))); cd.append(Zip.le32(UInt32(e.usize)))
            cd.append(Zip.le16(UInt16(e.name.count))); cd.append(Zip.le16(0)); cd.append(Zip.le16(0)); cd.append(Zip.le16(0)); cd.append(Zip.le16(0)); cd.append(Zip.le32(0))
            cd.append(Zip.le32(UInt32(e.offset))); cd.append(contentsOf: e.name)
        }
        var out = body
        let cdOffset = out.count
        out.append(cd)
        out.append(Zip.le32(0x0605_4b50)); out.append(Zip.le16(0)); out.append(Zip.le16(0))
        out.append(Zip.le16(UInt16(entries.count))); out.append(Zip.le16(UInt16(entries.count)))
        out.append(Zip.le32(UInt32(cd.count))); out.append(Zip.le32(UInt32(cdOffset))); out.append(Zip.le16(0))
        return out
    }
}

package enum Zip {
    static func u16<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }
    static func u32<C: RandomAccessCollection>(_ b: C, _ i: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }

    /// `COMPRESSION_ZLIB` in the Compression framework is the raw DEFLATE stream — exactly ZIP method 8.
    static func inflate(_ src: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw SheetError.corruptedContainer(detail: "negative uncompressed size") }
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw SheetError.corruptedContainer(detail: "inflate produced \(written) of \(expectedSize) bytes") }
        return dst
    }

    static func deflate(_ src: Data) -> Data? {
        let capacity = src.count + 64
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }
}

/// CRC-32 (IEEE, poly 0xEDB88320).
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
