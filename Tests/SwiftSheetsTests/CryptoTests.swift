import Foundation
import Testing
@testable import SheetCore

/// The arithmetic under password-protected files, checked against each standard's own published vectors
/// (spec Appendix B.39.9). None of these numbers came from this library.
@Suite struct CryptoTests {
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

    @Test func sha256MatchesFIPS180() {
        #expect(Self.hex(SHA256.hash(Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Self.hex(SHA256.hash(Data())) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Self.hex(SHA256.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func sha1MatchesFIPS180() {
        #expect(Self.hex(SHA1.hash(Data("abc".utf8))) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Self.hex(SHA1.hash(Data())) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
        #expect(Self.hex(SHA1.hash(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))) == "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    }

    /// RFC 4231 test case 2, and RFC 2202 test case 2 for SHA-1.
    @Test func hmacMatchesTheRFCs() {
        let key = Data("Jefe".utf8), msg = Data("what do ya want for nothing?".utf8)
        #expect(Self.hex(HMAC<SHA256>.authenticate(msg, key: key)) == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        #expect(Self.hex(HMAC<SHA1>.authenticate(msg, key: key)) == "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
        #expect(Self.hex(HMAC<SHA512>.authenticate(msg, key: key)) == "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737")
    }

    /// RFC 6070 (PBKDF2-HMAC-SHA1) and the SHA-256 vectors that RFC 7914 §11 publishes.
    @Test func pbkdf2MatchesTheRFCs() {
        let p = Data("password".utf8), s = Data("salt".utf8)
        #expect(Self.hex(PBKDF2<SHA1>.derive(password: p, salt: s, iterations: 1, length: 20)) == "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        #expect(Self.hex(PBKDF2<SHA1>.derive(password: p, salt: s, iterations: 2, length: 20)) == "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
        #expect(Self.hex(PBKDF2<SHA1>.derive(password: p, salt: s, iterations: 4096, length: 20)) == "4b007901b765489abead49d926f721d065a429c1")
        #expect(Self.hex(PBKDF2<SHA256>.derive(password: Data("passwd".utf8), salt: s, iterations: 1, length: 64)) == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        #expect(Self.hex(PBKDF2<SHA256>.derive(password: Data("Password".utf8), salt: Data("NaCl".utf8), iterations: 80000, length: 64)) == "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    }

    /// The cost that matters in practice: a hundred thousand SHA-512 rounds, and a few megabytes of AES.
    @Test func theCostIsReasonable() throws {
        let clock = ContinuousClock()
        let aes = try AES(key: RandomBytes.make(32))
        let iv = RandomBytes.make(16)
        let body = Data(count: 4 << 20)
        let t = clock.measure { _ = try? aes.encryptCBC(body, iv: iv) }
        #expect(t < .seconds(5), "4 MiB of AES-256-CBC took \(t)")
        let t2 = clock.measure { _ = try? aes.decryptCBC(body, iv: iv) }
        #expect(t2 < .seconds(5), "4 MiB of AES-256-CBC decryption took \(t2)")
        print("CryptoTests: 4 MiB AES-256-CBC encrypt \(t), decrypt \(t2)")
    }
}
