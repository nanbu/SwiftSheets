import Foundation

// The hashes that sheet protection and key derivation are built on (spec Appendix B.39.9): SHA-1 (FIPS 180-4),
// SHA-256 (FIPS 180-4), HMAC (RFC 2104) and PBKDF2 (RFC 8018), plus the random bytes a salt needs. Written out
// here for the same reason SHA-512 was (Appendix B.38): the library has no package dependencies, CryptoKit is
// Apple's alone, and a Linux machine has nothing else to offer. Every one is checked against its standard's
// published vectors in `CryptoTests`.
//
// None of this is encryption. What decrypts a protected file (AES's inverse cipher, the compound file, the two
// package forms) lives in the SheetDecrypt product, and what encrypts one in SheetEncrypt — so that an app
// linking only the plain products carries no encryption code at all (Appendix B.39.9, Rev 4.29).

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

/// Bytes nobody can predict: salts and keys.
package enum RandomBytes {
    package static func make(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(UInt8.random(in: 0...255, using: &generator)) }
        return out
    }
}
