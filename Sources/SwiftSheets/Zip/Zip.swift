import Foundation
import Compression

/// Minimal ZIP container reader: central directory → entries; stored (0) and deflate (8); no ZIP64, no encryption.
struct ZipArchive {
    struct Entry { let name: String; let method: UInt16; let crc32: UInt32; let compressedSize: Int; let uncompressedSize: Int; let localHeaderOffset: Int }

    private let data: Data
    let entries: [String: Entry]

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw SheetsError(.zip, "file too small") }
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 65535)
        while i >= lowest {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw SheetsError(.zip, "end of central directory not found") }
        let count = Int(Zip.u16(bytes, eocd + 10))
        let cdSize = Int(Zip.u32(bytes, eocd + 12))
        let cdOffset = Int(Zip.u32(bytes, eocd + 16))
        guard cdOffset != 0xFFFF_FFFF, cdOffset + cdSize <= bytes.count else { throw SheetsError(.zip, "ZIP64 or corrupt central directory") }
        var entries: [String: Entry] = [:]
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= bytes.count, Zip.u32(bytes, p) == 0x0201_4b50 else { throw SheetsError(.zip, "bad central directory entry") }
            let method = Zip.u16(bytes, p + 10), crc = Zip.u32(bytes, p + 16)
            let csize = Int(Zip.u32(bytes, p + 20)), usize = Int(Zip.u32(bytes, p + 24))
            let nameLen = Int(Zip.u16(bytes, p + 28)), extraLen = Int(Zip.u16(bytes, p + 30)), commentLen = Int(Zip.u16(bytes, p + 32))
            let localOffset = Int(Zip.u32(bytes, p + 42))
            guard csize != 0xFFFF_FFFF, usize != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw SheetsError(.zip, "ZIP64 entry") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, crc32: crc, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: localOffset)
            p += 46 + nameLen + extraLen + commentLen
        }
        self.entries = entries
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    func read(_ name: String) throws -> Data {
        guard let e = entries[name] else { throw SheetsError(.zip, "missing part \(name)") }
        let bytes = [UInt8](data)
        let h = e.localHeaderOffset
        guard h + 30 <= bytes.count, Zip.u32(bytes, h) == 0x0403_4b50 else { throw SheetsError(.zip, "bad local header for \(name)") }
        let nameLen = Int(Zip.u16(bytes, h + 26)), extraLen = Int(Zip.u16(bytes, h + 28))
        let start = h + 30 + nameLen + extraLen
        guard start + e.compressedSize <= bytes.count else { throw SheetsError(.zip, "truncated data for \(name)") }
        let payload = data.subdata(in: start..<(start + e.compressedSize))
        switch e.method {
        case 0: return payload
        case 8: return try Zip.inflate(payload, expectedSize: e.uncompressedSize)
        default: throw SheetsError(.zip, "unsupported compression method \(e.method) for \(name)")
        }
    }
}

/// ZIP writer: deflate (method 8) via the Compression framework, falling back to stored when that does not shrink.
struct ZipWriter {
    private struct Entry { let name: [UInt8]; let method: UInt16; let crc: UInt32; let csize: Int; let usize: Int; let offset: Int }
    private var entries: [Entry] = []
    private var body = Data()
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1  // 2026-01-01; readers ignore it

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if data.count > 64, let deflated = Zip.deflate(data), deflated.count < data.count { method = 8; payload = deflated }
        let offset = body.count
        var h = Data()
        h.append(Zip.le32(0x0403_4b50)); h.append(Zip.le16(20)); h.append(Zip.le16(0x0800)); h.append(Zip.le16(method))
        h.append(Zip.le16(dosTime)); h.append(Zip.le16(dosDate)); h.append(Zip.le32(crc))
        h.append(Zip.le32(UInt32(payload.count))); h.append(Zip.le32(UInt32(data.count)))
        h.append(Zip.le16(UInt16(nameBytes.count))); h.append(Zip.le16(0)); h.append(contentsOf: nameBytes)
        body.append(h); body.append(payload)
        entries.append(Entry(name: nameBytes, method: method, crc: crc, csize: payload.count, usize: data.count, offset: offset))
    }

    func finish() -> Data {
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

enum Zip {
    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]) }

    /// `COMPRESSION_ZLIB` in the Compression framework is the raw DEFLATE stream — exactly ZIP method 8.
    static func inflate(_ src: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw SheetsError(.zip, "inflate produced \(written) of \(expectedSize) bytes") }
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
