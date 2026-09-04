import Foundation
import SheetCore

/// Raw Snappy blocks (no stream framing — IWA has its own 4-byte chunk header). Decompression implements the full
/// tag set; compression emits literals only, which is a valid Snappy stream every decoder accepts (spec §10.2).
enum Snappy {
    static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { raw in try decompress(raw.bindMemory(to: UInt8.self)) }
    }

    /// The most a block may declare it expands to. An IWA chunk holds at most 64 KiB before Snappy (Numbers and
    /// this library both cut there); the ceiling is far past that so that another writer's larger block still
    /// opens, and low enough that a hostile length cannot ask for gigabytes.
    static let maxExpandedLength = 256 << 20

    /// Reads the block where it lies and writes straight into the result — no copy of the input, none of the output.
    ///
    /// Every index is checked before it is used and every copy is bounded by the declared length, so a block of
    /// any bytes at all ends in a `SheetError` or a result, never a trap (spec §12, pillar 5). The loop keeps its
    /// state in plain locals rather than in variables captured by nested functions: the Linux build trapped
    /// inside such a nested copy on a fuzzed block that the macOS build passed, and a loop with nothing captured
    /// has nothing for the two toolchains to disagree about.
    static func decompress(_ src: UnsafeBufferPointer<UInt8>) throws -> Data {
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
        guard expected <= Snappy.maxExpandedLength else { throw SheetError.corruptedContainer(detail: "snappy: implausible length \(expected)") }
        var result = Data(count: expected)
        let produced = try result.withUnsafeMutableBytes { rawOut -> Int in
            let out = rawOut.bindMemory(to: UInt8.self)
            let capacity = Swift.min(out.count, expected)
            var n = 0   // bytes written so far
            while i < src.count {
                let tag = src[i]; i += 1
                var copyLength = 0, copyOffset = 0
                switch tag & 0x03 {
                case 0:   // literal
                    var len = Int(tag >> 2) + 1
                    if len > 60 {
                        let extra = len - 60
                        guard i + extra <= src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated literal length") }
                        len = 0
                        for k in 0..<extra { len |= Int(src[i + k]) << (8 * k) }
                        len += 1
                        i += extra
                    }
                    guard len <= src.count - i else { throw SheetError.corruptedContainer(detail: "snappy: truncated literal") }
                    guard len <= capacity - n else { throw SheetError.corruptedContainer(detail: "snappy: output past its declared length") }
                    for k in 0..<len { out[n + k] = src[i + k] }
                    n += len
                    i += len
                    continue
                case 1:   // copy, 1-byte offset
                    guard i < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                    copyLength = Int((tag >> 2) & 0x07) + 4
                    copyOffset = (Int(tag & 0xE0) << 3) | Int(src[i]); i += 1
                case 2:   // copy, 2-byte offset
                    guard i + 1 < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                    copyLength = Int(tag >> 2) + 1
                    copyOffset = Int(src[i]) | (Int(src[i + 1]) << 8); i += 2
                default:  // copy, 4-byte offset
                    guard i + 3 < src.count else { throw SheetError.corruptedContainer(detail: "snappy: truncated copy") }
                    copyLength = Int(tag >> 2) + 1
                    copyOffset = Int(src[i]) | (Int(src[i + 1]) << 8) | (Int(src[i + 2]) << 16) | (Int(src[i + 3]) << 24); i += 4
                }
                guard copyOffset > 0, copyOffset <= n else { throw SheetError.corruptedContainer(detail: "snappy: bad copy offset") }
                guard copyLength <= capacity - n else { throw SheetError.corruptedContainer(detail: "snappy: output past its declared length") }
                let start = n - copyOffset
                for k in 0..<copyLength { out[n + k] = out[start + k] }   // overlapping copies are allowed (byte by byte)
                n += copyLength
            }
            return n
        }
        guard produced == expected else { throw SheetError.corruptedContainer(detail: "snappy: expected \(expected) bytes, got \(produced)") }
        return result
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
