import Foundation
import Testing
@testable import SheetCore

/// The hashes under sheet protection and key derivation, checked against each standard's own published vectors
/// (spec Appendix B.39.9). None of these numbers came from this library. AES is checked the same way in
/// `SheetEncryptTests` — since 0.17.0 the plain products carry no cipher (Rev 4.29), and neither does this suite.
@Suite struct CryptoTests {
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ hex: String) -> Data {
        var out = Data(); var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return out
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
}
