import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers

/// The Snappy decoder on hostile blocks (spec §12, pillar 5): a block of any bytes ends in a `SheetError` or a
/// result, never a trap. The Linux build once trapped inside the decoder on a fuzzed Numbers part that the macOS
/// build passed, so the decoder itself is fuzzed here, apart from any document.
@Suite struct SnappyFuzzTests {
    /// The text the valid block expands to: a phrase three times over, then two runs of digits.
    static let text = Data("SwiftSheets streams rows. SwiftSheets streams rows. SwiftSheets streams rows. 0123456789 0123456789".utf8)

    /// A valid block with a literal and every copy kind — the phrase once as a literal, twice more as copies
    /// with a 2-byte and a 4-byte offset, the digits once as a literal and once as a 1-byte-offset copy.
    static func validBlock() -> Data {
        var block = Data([UInt8(text.count)])                                   // 99 bytes, one varint byte
        block.append(UInt8((26 - 1) << 2)); block.append(text.prefix(26))       // literal: the phrase
        block.append(UInt8(((26 - 1) << 2) | 0x02)); block.append(26); block.append(0)   // copy 26 back 26
        block.append(UInt8(((26 - 1) << 2) | 0x03)); block.append(contentsOf: [26, 0, 0, 0])   // and again
        block.append(UInt8((11 - 1) << 2)); block.append(text.suffix(21).prefix(11))      // literal "0123456789 "
        block.append(UInt8(((10 - 4) << 2) | 0x01)); block.append(11)           // copy 10 back 11: the digits again
        return block
    }

    @Test func theValidBlockDecodes() throws {
        #expect(try Snappy.decompress(Self.validBlock()) == Self.text)
    }

    /// Thousands of mutants of the valid block, and blocks of pure noise: every one lands on a SheetError or a result.
    @Test(arguments: [UInt64(1), 2, 3, 0x5417_5EED]) func mutatedBlocksNeverTrap(_ seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let base = [UInt8](Self.validBlock())
        for round in 0..<5_000 {
            var bytes = base
            switch round % 5 {
            case 0: for _ in 0..<Int.random(in: 1...6, using: &rng) { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            case 1: bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
            case 2: bytes.insert(contentsOf: (0..<Int.random(in: 1...8, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }, at: Int.random(in: 0...bytes.count, using: &rng))
            case 3: bytes = (0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            default:   // a huge declared length, then the block
                bytes = [0xFF, 0xFF, 0xFF, 0xFF, UInt8.random(in: 0...0x0F, using: &rng)] + base.dropFirst()
            }
            do { _ = try Snappy.decompress(Data(bytes)) }
            catch is SheetError {}
            catch { Issue.record(Comment(rawValue: "seed \(seed) round \(round): \(type(of: error))")) }
        }
    }
}
