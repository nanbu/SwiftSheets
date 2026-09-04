import Foundation

// The arithmetic that password-protected spreadsheets are built on (spec Appendix B.39.9): AES (FIPS 197),
// SHA-1 (FIPS 180-4), SHA-256 (FIPS 180-4), HMAC (RFC 2104) and PBKDF2 (RFC 8018). Written out here for the
// same reason SHA-512 was (Appendix B.38): the library has no package dependencies, CryptoKit is Apple's alone,
// and a Linux machine has nothing else to offer. Every one is checked against its standard's published vectors
// in `CryptoTests`, and the whole is checked against files other encryptors produced.
//
// None of this is written for speed; a password is hashed a hundred thousand times and a package is a few
// megabytes, and both are measured in `CryptoTests` rather than assumed.

/// A hash with the shape HMAC and PBKDF2 need: a block size, a digest size, and a state that takes bytes in
/// pieces — so a key derivation that runs a hundred thousand rounds pays for arithmetic, not for allocation.
package protocol HashFunction {
    associatedtype State: HashState
    static var blockSize: Int { get }
    static var digestSize: Int { get }
    static func hash(_ data: Data) -> Data
}

package protocol HashState {
    init()
    mutating func update(_ bytes: UnsafeRawBufferPointer)
    mutating func finalize() -> Data
}

extension HashState {
    package mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
}

extension SHA512: HashFunction {
    package static var blockSize: Int { 128 }
    package static var digestSize: Int { 64 }
}

/// The Merkle–Damgård frame the 32-bit hashes share: a block buffer, a running length, and padding at the end.
package struct Block32Hasher<Core: Block32Core>: HashState {
    private var h: [UInt32]
    private var buffer = [UInt8](repeating: 0, count: 64)
    private var buffered = 0
    private var length: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: Core.scheduleSize)

    package init() { h = Core.initial }

    package mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var i = 0
        let n = bytes.count
        length &+= UInt64(n)
        if buffered > 0 {
            while buffered < 64, i < n { buffer[buffered] = bytes[i]; buffered += 1; i += 1 }
            if buffered == 64 { buffer.withUnsafeBufferPointer { Core.compress(&h, $0.baseAddress!, &w) }; buffered = 0 }
        }
        while i + 64 <= n {
            Core.compress(&h, bytes.baseAddress!.advanced(by: i).assumingMemoryBound(to: UInt8.self), &w)
            i += 64
        }
        while i < n { buffer[buffered] = bytes[i]; buffered += 1; i += 1 }
    }

    package mutating func finalize() -> Data {
        let bits = length &* 8
        var tail = [UInt8](buffer[0..<buffered])
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (UInt64(i) * 8))) }
        tail.withUnsafeBufferPointer { p in
            var offset = 0
            while offset < p.count { Core.compress(&h, p.baseAddress!.advanced(by: offset), &w); offset += 64 }
        }
        var out = Data(capacity: Core.digestWords * 4)
        for v in h.prefix(Core.digestWords) { out.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
        return out
    }
}

package protocol Block32Core {
    static var initial: [UInt32] { get }
    static var scheduleSize: Int { get }
    static var digestWords: Int { get }
    static func compress(_ h: inout [UInt32], _ block: UnsafePointer<UInt8>, _ w: inout [UInt32])
}

@inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
@inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
@inline(__always) private func word(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt32 {
    UInt32(p[i]) << 24 | UInt32(p[i + 1]) << 16 | UInt32(p[i + 2]) << 8 | UInt32(p[i + 3])
}

// MARK: - SHA-256

package enum SHA256: HashFunction, Block32Core {
    package typealias State = Block32Hasher<SHA256>
    package static var blockSize: Int { 64 }
    package static var digestSize: Int { 32 }
    package static var scheduleSize: Int { 64 }
    package static var digestWords: Int { 8 }
    package static var initial: [UInt32] { [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19] }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    package static func compress(_ h: inout [UInt32], _ block: UnsafePointer<UInt8>, _ w: inout [UInt32]) {
        h.withUnsafeMutableBufferPointer { hp in
            w.withUnsafeMutableBufferPointer { wp in
                k.withUnsafeBufferPointer { kp in
                    let w = wp.baseAddress!, k = kp.baseAddress!, h = hp.baseAddress!
                    for t in 0..<16 { w[t] = word(block, t * 4) }
                    for t in 16..<64 {
                        let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                        let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                        w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                    }
                    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                    for t in 0..<64 {
                        let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[t] &+ w[t]
                        let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
                        hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                    }
                    h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
                    h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
                }
            }
        }
    }

    package static func hash(_ data: Data) -> Data {
        var s = State()
        s.update(data)
        return s.finalize()
    }
}

// MARK: - SHA-1

/// Old, and not to be trusted for anything new — but the "standard" encryption of Excel 2007 and the ODF
/// key derivation of every LibreOffice release are built on it, and reading those files means computing it.
package enum SHA1: HashFunction, Block32Core {
    package typealias State = Block32Hasher<SHA1>
    package static var blockSize: Int { 64 }
    package static var digestSize: Int { 20 }
    package static var scheduleSize: Int { 80 }
    package static var digestWords: Int { 5 }
    package static var initial: [UInt32] { [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0] }

    package static func compress(_ h: inout [UInt32], _ block: UnsafePointer<UInt8>, _ w: inout [UInt32]) {
        h.withUnsafeMutableBufferPointer { hp in
            w.withUnsafeMutableBufferPointer { wp in
                let w = wp.baseAddress!, h = hp.baseAddress!
                for t in 0..<16 { w[t] = word(block, t * 4) }
                for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
                var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
                for t in 0..<80 {
                    let f: UInt32, k: UInt32
                    switch t {
                    case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                    case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                    case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                    default: f = b ^ c ^ d; k = 0xCA62C1D6
                    }
                    let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
                    e = d; d = c; c = rotl(b, 30); b = a; a = temp
                }
                h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
            }
        }
    }

    package static func hash(_ data: Data) -> Data {
        var s = State()
        s.update(data)
        return s.finalize()
    }
}

// MARK: - HMAC and PBKDF2

package struct HMAC<H: HashFunction> {
    private let inner: H.State
    private let outer: H.State

    /// The two padded-key states, computed once; every message starts from a copy of them.
    package init(key: Data) {
        var k = key.count > H.blockSize ? H.hash(key) : key
        k.append(Data(count: H.blockSize - k.count))
        var i = H.State(), o = H.State()
        i.update(Data(k.map { $0 ^ 0x36 }))
        o.update(Data(k.map { $0 ^ 0x5c }))
        inner = i; outer = o
    }

    package func authenticate(_ message: Data) -> Data {
        var i = inner
        i.update(message)
        var o = outer
        o.update(i.finalize())
        return o.finalize()
    }

    package static func authenticate(_ message: Data, key: Data) -> Data { HMAC(key: key).authenticate(message) }
}

package enum PBKDF2<H: HashFunction> {
    package static func derive(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        let mac = HMAC<H>(key: password)
        var out = Data()
        var block: UInt32 = 1
        while out.count < length {
            var saltWithIndex = salt
            saltWithIndex.append(contentsOf: [UInt8(block >> 24), UInt8((block >> 16) & 0xff), UInt8((block >> 8) & 0xff), UInt8(block & 0xff)])
            var u = mac.authenticate(saltWithIndex)
            var t = [UInt8](u)
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = mac.authenticate(u)
                    u.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in for i in 0..<t.count { t[i] ^= raw[i] } }
                }
            }
            out.append(contentsOf: t)
            block += 1
        }
        return out.prefix(length)
    }
}

// MARK: - AES

/// AES-128 / AES-192 / AES-256 block cipher with CBC and ECB, as the spreadsheet encryptions use it. The
/// table-driven form (four 32-bit tables each way), so that a package of tens of megabytes is a matter of
/// seconds rather than minutes.
package struct AES {
    private static let sbox: [UInt8] = [
        0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
        0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
        0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
        0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
        0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
        0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
        0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
        0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16]
    private static let inverseSbox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()
    @inline(__always) private static func xtime(_ b: UInt8) -> UInt8 { (b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0) }
    @inline(__always) private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, p: UInt8 = 0
        for _ in 0..<8 { if b & 1 != 0 { p ^= a }; a = xtime(a); b >>= 1 }
        return p
    }
    // the round tables: Te[i][x] = MixColumns column of SubBytes(x) rotated by i; Td likewise with the inverse
    private static let te: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)
        for x in 0..<256 {
            let s = sbox[x]
            let s2 = xtime(s), s3 = s2 ^ s
            let w = UInt32(s2) << 24 | UInt32(s) << 16 | UInt32(s) << 8 | UInt32(s3)
            t[0][x] = w
            t[1][x] = (w >> 8) | (w << 24)
            t[2][x] = (w >> 16) | (w << 16)
            t[3][x] = (w >> 24) | (w << 8)
        }
        return t
    }()
    private static let td: [[UInt32]] = {
        var t = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)
        for x in 0..<256 {
            let s = inverseSbox[x]
            let w = UInt32(mul(s, 14)) << 24 | UInt32(mul(s, 9)) << 16 | UInt32(mul(s, 13)) << 8 | UInt32(mul(s, 11))
            t[0][x] = w
            t[1][x] = (w >> 8) | (w << 24)
            t[2][x] = (w >> 16) | (w << 16)
            t[3][x] = (w >> 24) | (w << 8)
        }
        return t
    }()

    private let encryptionKeys: [UInt32]   // 4 words per round key
    private let decryptionKeys: [UInt32]
    private let rounds: Int

    package init(key: Data) throws {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { throw SheetError.unsupportedFeature("AES key of \(key.count) bytes") }
        let nk = key.count / 4
        rounds = nk + 6
        let total = 4 * (rounds + 1)
        var w = [UInt32](repeating: 0, count: total)
        let k = [UInt8](key)
        for i in 0..<nk { w[i] = UInt32(k[4 * i]) << 24 | UInt32(k[4 * i + 1]) << 16 | UInt32(k[4 * i + 2]) << 8 | UInt32(k[4 * i + 3]) }
        var rcon: UInt32 = 0x0100_0000
        for i in nk..<total {
            var temp = w[i - 1]
            if i % nk == 0 {
                temp = (temp << 8) | (temp >> 24)
                temp = AES.subWord(temp) ^ rcon
                rcon = UInt32(AES.xtime(UInt8(rcon >> 24))) << 24
            } else if nk > 6, i % nk == 4 {
                temp = AES.subWord(temp)
            }
            w[i] = w[i - nk] ^ temp
        }
        encryptionKeys = w
        // the decryption keys: the same schedule with InvMixColumns applied to the middle rounds (the equivalent
        // inverse cipher of FIPS 197 §5.3.5), in reverse order
        var d = [UInt32](repeating: 0, count: total)
        for r in 0...rounds {
            for c in 0..<4 {
                let word = w[4 * (rounds - r) + c]
                if r == 0 || r == rounds {
                    d[4 * r + c] = word
                } else {
                    d[4 * r + c] = AES.td[0][Int(AES.sbox[Int(word >> 24)])] ^ AES.td[1][Int(AES.sbox[Int((word >> 16) & 0xff)])]
                        ^ AES.td[2][Int(AES.sbox[Int((word >> 8) & 0xff)])] ^ AES.td[3][Int(AES.sbox[Int(word & 0xff)])]
                }
            }
        }
        decryptionKeys = d
    }

    @inline(__always) private static func subWord(_ w: UInt32) -> UInt32 {
        UInt32(sbox[Int(w >> 24)]) << 24 | UInt32(sbox[Int((w >> 16) & 0xff)]) << 16 | UInt32(sbox[Int((w >> 8) & 0xff)]) << 8 | UInt32(sbox[Int(w & 0xff)])
    }

    @inline(__always) private static func load(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
    }
    @inline(__always) private static func store(_ w: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(w >> 24); p[1] = UInt8((w >> 16) & 0xff); p[2] = UInt8((w >> 8) & 0xff); p[3] = UInt8(w & 0xff)
    }

    /// One block: `input` → `output` (16 bytes each; may be the same memory).
    package func encryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        let k = encryptionKeys
        var s0 = AES.load(input) ^ k[0], s1 = AES.load(input + 4) ^ k[1], s2 = AES.load(input + 8) ^ k[2], s3 = AES.load(input + 12) ^ k[3]
        let te0 = AES.te[0], te1 = AES.te[1], te2 = AES.te[2], te3 = AES.te[3]
        var r = 1
        while r < rounds {
            let t0 = te0[Int(s0 >> 24)] ^ te1[Int((s1 >> 16) & 0xff)] ^ te2[Int((s2 >> 8) & 0xff)] ^ te3[Int(s3 & 0xff)] ^ k[4 * r]
            let t1 = te0[Int(s1 >> 24)] ^ te1[Int((s2 >> 16) & 0xff)] ^ te2[Int((s3 >> 8) & 0xff)] ^ te3[Int(s0 & 0xff)] ^ k[4 * r + 1]
            let t2 = te0[Int(s2 >> 24)] ^ te1[Int((s3 >> 16) & 0xff)] ^ te2[Int((s0 >> 8) & 0xff)] ^ te3[Int(s1 & 0xff)] ^ k[4 * r + 2]
            let t3 = te0[Int(s3 >> 24)] ^ te1[Int((s0 >> 16) & 0xff)] ^ te2[Int((s1 >> 8) & 0xff)] ^ te3[Int(s2 & 0xff)] ^ k[4 * r + 3]
            s0 = t0; s1 = t1; s2 = t2; s3 = t3
            r += 1
        }
        let sb = AES.sbox
        let o0 = (UInt32(sb[Int(s0 >> 24)]) << 24 | UInt32(sb[Int((s1 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s2 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s3 & 0xff)])) ^ k[4 * rounds]
        let o1 = (UInt32(sb[Int(s1 >> 24)]) << 24 | UInt32(sb[Int((s2 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s3 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s0 & 0xff)])) ^ k[4 * rounds + 1]
        let o2 = (UInt32(sb[Int(s2 >> 24)]) << 24 | UInt32(sb[Int((s3 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s0 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s1 & 0xff)])) ^ k[4 * rounds + 2]
        let o3 = (UInt32(sb[Int(s3 >> 24)]) << 24 | UInt32(sb[Int((s0 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s1 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s2 & 0xff)])) ^ k[4 * rounds + 3]
        AES.store(o0, output); AES.store(o1, output + 4); AES.store(o2, output + 8); AES.store(o3, output + 12)
    }

    package func decryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        let k = decryptionKeys
        var s0 = AES.load(input) ^ k[0], s1 = AES.load(input + 4) ^ k[1], s2 = AES.load(input + 8) ^ k[2], s3 = AES.load(input + 12) ^ k[3]
        let td0 = AES.td[0], td1 = AES.td[1], td2 = AES.td[2], td3 = AES.td[3]
        var r = 1
        while r < rounds {
            let t0 = td0[Int(s0 >> 24)] ^ td1[Int((s3 >> 16) & 0xff)] ^ td2[Int((s2 >> 8) & 0xff)] ^ td3[Int(s1 & 0xff)] ^ k[4 * r]
            let t1 = td0[Int(s1 >> 24)] ^ td1[Int((s0 >> 16) & 0xff)] ^ td2[Int((s3 >> 8) & 0xff)] ^ td3[Int(s2 & 0xff)] ^ k[4 * r + 1]
            let t2 = td0[Int(s2 >> 24)] ^ td1[Int((s1 >> 16) & 0xff)] ^ td2[Int((s0 >> 8) & 0xff)] ^ td3[Int(s3 & 0xff)] ^ k[4 * r + 2]
            let t3 = td0[Int(s3 >> 24)] ^ td1[Int((s2 >> 16) & 0xff)] ^ td2[Int((s1 >> 8) & 0xff)] ^ td3[Int(s0 & 0xff)] ^ k[4 * r + 3]
            s0 = t0; s1 = t1; s2 = t2; s3 = t3
            r += 1
        }
        let sb = AES.inverseSbox
        let o0 = (UInt32(sb[Int(s0 >> 24)]) << 24 | UInt32(sb[Int((s3 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s2 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s1 & 0xff)])) ^ k[4 * rounds]
        let o1 = (UInt32(sb[Int(s1 >> 24)]) << 24 | UInt32(sb[Int((s0 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s3 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s2 & 0xff)])) ^ k[4 * rounds + 1]
        let o2 = (UInt32(sb[Int(s2 >> 24)]) << 24 | UInt32(sb[Int((s1 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s0 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s3 & 0xff)])) ^ k[4 * rounds + 2]
        let o3 = (UInt32(sb[Int(s3 >> 24)]) << 24 | UInt32(sb[Int((s2 >> 16) & 0xff)]) << 16 | UInt32(sb[Int((s1 >> 8) & 0xff)]) << 8 | UInt32(sb[Int(s0 & 0xff)])) ^ k[4 * rounds + 3]
        AES.store(o0, output); AES.store(o1, output + 4); AES.store(o2, output + 8); AES.store(o3, output + 12)
    }

    /// CBC over whole blocks; `data.count` must be a multiple of 16 (padding is the caller's, since each
    /// format pads differently).
    package func encryptCBC(_ data: Data, iv: Data) throws -> Data {
        guard data.count % 16 == 0, iv.count == 16 else { throw SheetError.corruptedContainer(detail: "AES-CBC input is not whole blocks") }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                iv.withUnsafeBytes { v in
                    let src = i.bindMemory(to: UInt8.self).baseAddress!, dst = o.bindMemory(to: UInt8.self).baseAddress!
                    var previous = v.bindMemory(to: UInt8.self).baseAddress!
                    var block = [UInt8](repeating: 0, count: 16)
                    var offset = 0
                    while offset < data.count {
                        for j in 0..<16 { block[j] = src[offset + j] ^ previous[j] }
                        block.withUnsafeBufferPointer { encryptBlock($0.baseAddress!, dst + offset) }
                        previous = UnsafePointer(dst + offset)
                        offset += 16
                    }
                }
            }
        }
        return out
    }

    package func decryptCBC(_ data: Data, iv: Data) throws -> Data {
        guard data.count % 16 == 0, iv.count == 16 else { throw SheetError.corruptedContainer(detail: "AES-CBC input is not whole blocks") }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                iv.withUnsafeBytes { v in
                    let src = i.bindMemory(to: UInt8.self).baseAddress!, dst = o.bindMemory(to: UInt8.self).baseAddress!
                    var previous = v.bindMemory(to: UInt8.self).baseAddress!
                    var offset = 0
                    while offset < data.count {
                        decryptBlock(src + offset, dst + offset)
                        for j in 0..<16 { dst[offset + j] ^= previous[j] }
                        previous = src + offset
                        offset += 16
                    }
                }
            }
        }
        return out
    }

    package func encryptECB(_ data: Data) throws -> Data {
        guard data.count % 16 == 0 else { throw SheetError.corruptedContainer(detail: "AES-ECB input is not whole blocks") }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                let src = i.bindMemory(to: UInt8.self).baseAddress!, dst = o.bindMemory(to: UInt8.self).baseAddress!
                var offset = 0
                while offset < data.count { encryptBlock(src + offset, dst + offset); offset += 16 }
            }
        }
        return out
    }

    package func decryptECB(_ data: Data) throws -> Data {
        guard data.count % 16 == 0 else { throw SheetError.corruptedContainer(detail: "AES-ECB input is not whole blocks") }
        var out = Data(count: data.count)
        out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                let src = i.bindMemory(to: UInt8.self).baseAddress!, dst = o.bindMemory(to: UInt8.self).baseAddress!
                var offset = 0
                while offset < data.count { decryptBlock(src + offset, dst + offset); offset += 16 }
            }
        }
        return out
    }
}

/// Bytes nobody can predict: salts and keys.
package enum RandomBytes {
    package static func make(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(UInt8.random(in: 0...255, using: &generator)) }
        return out
    }
}
