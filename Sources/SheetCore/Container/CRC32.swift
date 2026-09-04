import Foundation
import CZlib

/// CRC-32 (IEEE, polynomial 0xEDB88320) — the checksum every ZIP entry carries.
///
/// The arithmetic is zlib's: it is on every machine this library runs on, it is the same function whichever DEFLATE
/// route is compiled in, and it uses the processor's CRC instructions where they exist. A byte-at-a-time table
/// loop in Swift was measured at 0.09 s over a 33 MB sheet; zlib does the same in a millisecond.
public enum CRC32 {
    /// The classic lookup table, kept for anyone who wants to check the arithmetic by hand.
    package static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var running = Running()
        running.update(data)
        return running.value
    }

    /// CRC-32 over data that arrives in pieces.
    package struct Running {
        private var state: UInt = 0
        package init() {}
        package mutating func update(_ data: Data) {
            guard !data.isEmpty else { return }
            state = data.withUnsafeBytes { raw in Running.advance(state, raw) }
        }
        package mutating func update(_ raw: UnsafeRawBufferPointer) {
            guard !raw.isEmpty else { return }
            state = Running.advance(state, raw)
        }
        package var value: UInt32 { UInt32(truncatingIfNeeded: state) }

        private static func advance(_ state: UInt, _ raw: UnsafeRawBufferPointer) -> UInt {
            var crc = uLong(state)
            var offset = 0
            // zlib counts a buffer in 32 bits; anything longer is fed in turns
            while offset < raw.count {
                let chunk = Swift.min(raw.count - offset, Int(UInt32.max))
                crc = crc32(crc, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Bytef.self), uInt(chunk))
                offset += chunk
            }
            return UInt(crc)
        }
    }
}
