import Foundation
import Testing
@testable import SheetCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The two things that used to be Apple's alone: folding bytes, and hashing a password. Both now have to answer the
/// same on any machine, so both are checked against something outside this library rather than against themselves.
@Suite struct CompressionTests {

    /// A raw DEFLATE stream neither backend produced — zlib's own compressor made it, at the default level, with the
    /// `windowBits = -15` that means "no wrapper". Whichever toolbox is compiled in has to read it.
    @Test func readsADeflateStreamItDidNotWrite() throws {
        let bytes: [UInt8] = [
            0x0b, 0x2e, 0xcf, 0x4c, 0x2b, 0x09, 0xce, 0x48, 0x4d, 0x2d, 0x29, 0x56, 0x28, 0x4a, 0x4d, 0x4c, 0x29,
            0x56, 0x48, 0x54, 0x70, 0x71, 0x75, 0xf3, 0x71, 0x0c, 0x71, 0x55, 0x28, 0x2e, 0x01, 0x8a, 0xe4, 0x2a,
            0x64, 0x96, 0x28, 0xa4, 0x64, 0xa6, 0x28, 0xe4, 0xe5, 0x97, 0x28, 0x94, 0x17, 0x65, 0x96, 0xa4, 0xea,
            0x29, 0x04, 0x0f, 0x6e, 0x4d, 0x00]
        let expected = String(repeating: "SwiftSheets reads a DEFLATE stream it did not write. ", count: 4)
        let out = try Deflate.decompress(Data(bytes), expectedSize: expected.utf8.count)
        #expect(String(decoding: out, as: UTF8.self) == expected)
    }

    @Test func roundTripsThroughWhicheverBackendIsCompiledIn() throws {
        let text = Data(String(repeating: "SwiftSheets deflate round trip. ", count: 200).utf8)
        let packed = try #require(Deflate.compress(text))
        #expect(packed.count < text.count / 4)
        #expect(try Deflate.decompress(packed, expectedSize: text.count) == text)
    }

    /// The streaming compressor and the one-shot one write the same kind of stream: what one folds, the other reads.
    @Test func theStreamingCompressorAgreesWithTheOneShotOne() throws {
        let piece = Data(String(repeating: "row,of,a,streamed,sheet\n", count: 500).utf8)
        let encoder = try DeflateEncoder()
        var packed = Data()
        for _ in 0..<4 { packed += try encoder.encode(piece) }
        packed += try encoder.finish()
        let whole = piece + piece + piece + piece
        #expect(try Deflate.decompress(packed, expectedSize: whole.count) == whole)
    }

    @Test func aTruncatedStreamIsACorruptEntryRatherThanAGuess() throws {
        let text = Data(String(repeating: "cut me short. ", count: 100).utf8)
        let packed = try #require(Deflate.compress(text))
        #expect(throws: SheetError.self) { try Deflate.decompress(packed.prefix(packed.count / 2), expectedSize: text.count) }
    }

    /// FIPS 180-4's own published digests. `abc` and the 112-character one are the standard pair; the empty message
    /// is the third, and the long one crosses a block boundary that a one-block implementation would get wrong.
    @Test(arguments: [
        ("", "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"),
        ("abc", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
        ("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
    ])
    func matchesThePublishedDigests(_ message: String, _ expected: String) {
        let digest = SHA512.hash(Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(digest == expected)
    }

    #if canImport(CryptoKit)
    /// While a machine with CryptoKit is to hand, make it the judge: the same bytes, hashed both ways.
    @Test func agreesWithCryptoKitOverAwkwardLengths() {
        for length in [0, 1, 55, 111, 112, 113, 127, 128, 129, 1000] {
            let message = Data((0..<length).map { UInt8($0 % 251) })
            #expect(SHA512.hash(message) == Data(CryptoKit.SHA512.hash(data: message)), "length \(length)")
        }
    }
    #endif
}
