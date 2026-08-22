import Foundation
import SheetCore

/// Raw Snappy blocks (no stream framing — IWA has its own 4-byte chunk header). Decompression implements the full
/// tag set; compression emits literals only, which is a valid Snappy stream every decoder accepts (spec §10.2).
enum Snappy {
    static func decompress(_ data: Data) throws -> Data {
        let src = [UInt8](data)
        var i = 0
        // preamble: uncompressed length as a varint
        var expected = 0, shift = 0
        while true {
            guard i < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated length") }
            let b = src[i]; i += 1
            expected |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 35 { throw SheetError.corruptedContainer(detail: "snappy: bad length varint") }
        }
        var out = [UInt8]()
        out.reserveCapacity(expected)
        while i < src.count {
            let tag = src[i]; i += 1
            switch tag & 0x03 {
            case 0:   // literal
                var len = Int(tag >> 2) + 1
                if len > 60 {
                    let n = len - 60
                    guard i + n <= src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated literal length") }
                    len = 0
                    for k in 0..<n { len |= Int(src[i + k]) << (8 * k) }
                    len += 1
                    i += n
                }
                guard i + len <= src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated literal") }
                out.append(contentsOf: src[i..<(i + len)])
                i += len
            case 1:   // copy, 1-byte offset
                let len = Int((tag >> 2) & 0x07) + 4
                guard i < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                let offset = (Int(tag & 0xE0) << 3) | Int(src[i]); i += 1
                try copy(&out, offset: offset, length: len)
            case 2:   // copy, 2-byte offset
                let len = Int(tag >> 2) + 1
                guard i + 1 < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                let offset = Int(src[i]) | (Int(src[i + 1]) << 8); i += 2
                try copy(&out, offset: offset, length: len)
            default:  // copy, 4-byte offset
                let len = Int(tag >> 2) + 1
                guard i + 3 < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                let offset = Int(src[i]) | (Int(src[i + 1]) << 8) | (Int(src[i + 2]) << 16) | (Int(src[i + 3]) << 24); i += 4
                try copy(&out, offset: offset, length: len)
            }
        }
        guard out.count == expected else { throw SheetError.corruptedContainer(detail: "snappy: expected \(expected) bytes, got \(out.count)") }
        return Data(out)
    }

    private static func copy(_ out: inout [UInt8], offset: Int, length: Int) throws {
        guard offset > 0, offset <= out.count else { throw SheetError.corruptedContainer(detail: "snappy: bad copy offset") }
        let start = out.count - offset
        for k in 0..<length { out.append(out[start + k]) }   // overlapping copies are allowed (byte by byte)
    }

    /// Literal-only encoding: a length preamble and literal runs of at most 2^32 bytes.
    static func compress(_ data: Data) -> Data {
        var out = [UInt8]()
        var n = data.count
        repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        var remaining = data[...]
        while !remaining.isEmpty {
            let chunk = remaining.prefix(65536)
            let len = chunk.count - 1
            if len < 60 { out.append(UInt8(len << 2)) }
            else { out.append(UInt8(61 << 2)); out.append(UInt8(len & 0xFF)); out.append(UInt8((len >> 8) & 0xFF)) }
            out.append(contentsOf: chunk)
            remaining = remaining.dropFirst(chunk.count)
        }
        return Data(out)
    }
}
