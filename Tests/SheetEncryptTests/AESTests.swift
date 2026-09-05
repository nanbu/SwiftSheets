import Foundation
import Testing
import SheetCore
import SheetDecrypt
import SheetEncrypt

/// The cipher under password-protected files, checked against each standard's own published vectors (spec
/// Appendix B.39.9). None of these numbers came from this library. Both halves are exercised — the inverse cipher
/// is SheetDecrypt's and the forward cipher SheetEncrypt's extension of it (Rev 4.29) — and the vectors passing
/// unchanged is the proof that splitting the file changed no arithmetic.
@Suite struct AESTests {
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ hex: String) -> Data {
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return out
    }

    /// FIPS 197 Appendix C: the worked examples for 128-bit and 256-bit keys.
    @Test func aesMatchesFIPS197() throws {
        let plain = Self.bytes("00112233445566778899aabbccddeeff")
        let aes128 = try AES(key: Self.bytes("000102030405060708090a0b0c0d0e0f"))
        #expect(Self.hex(try aes128.encryptECB(plain)) == "69c4e0d86a7b0430d8cdb78070b4c55a")
        #expect(try aes128.decryptECB(Self.bytes("69c4e0d86a7b0430d8cdb78070b4c55a")) == plain)
        let aes256 = try AES(key: Self.bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        #expect(Self.hex(try aes256.encryptECB(plain)) == "8ea2b7ca516745bfeafc49904b496089")
        #expect(try aes256.decryptECB(Self.bytes("8ea2b7ca516745bfeafc49904b496089")) == plain)
    }

    /// NIST SP 800-38A F.2.1 / F.2.2: AES-128 CBC.
    @Test func cbcMatchesSP80038A() throws {
        let key = Self.bytes("2b7e151628aed2a6abf7158809cf4f3c"), iv = Self.bytes("000102030405060708090a0b0c0d0e0f")
        let plain = Self.bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        let cipher = Self.bytes("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7")
        let aes = try AES(key: key)
        #expect(try aes.encryptCBC(plain, iv: iv) == cipher)
        #expect(try aes.decryptCBC(cipher, iv: iv) == plain)
    }

    /// The cost that matters in practice: a few megabytes of AES each way.
    @Test func theCostIsReasonable() throws {
        let clock = ContinuousClock()
        let aes = try AES(key: RandomBytes.make(32))
        let iv = RandomBytes.make(16)
        let body = Data(count: 4 << 20)
        let t = clock.measure { _ = try? aes.encryptCBC(body, iv: iv) }
        #expect(t < .seconds(5), "4 MiB of AES-256-CBC took \(t)")
        let t2 = clock.measure { _ = try? aes.decryptCBC(body, iv: iv) }
        #expect(t2 < .seconds(5), "4 MiB of AES-256-CBC decryption took \(t2)")
        print("AESTests: 4 MiB AES-256-CBC encrypt \(t), decrypt \(t2)")
    }
}
