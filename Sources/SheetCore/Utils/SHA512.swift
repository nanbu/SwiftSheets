import Foundation

/// SHA-512 (FIPS 180-4), written out here rather than borrowed.
///
/// The library hashes exactly one thing a hundred thousand times over: the password on a protected sheet
/// (ECMA-376 §18.2.29) and on a protected workbook (spec Appendix B.39.9). Apple's CryptoKit has that hash, but
/// CryptoKit is an Apple framework, and a machine without it would otherwise lose both. The arithmetic buys the
/// same answer everywhere, and the published test vectors say whether the answer is right. The state form
/// (`State`) takes bytes in pieces and keeps its schedule, so the hundred thousand rounds pay for arithmetic
/// rather than for allocation.
package enum SHA512 {
    static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2, 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df, 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec, 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817]

    @inline(__always) static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    static func compress(_ h: inout [UInt64], _ block: UnsafePointer<UInt8>, _ w: inout [UInt64]) {
        // raw pointers throughout: in a debug build every array subscript is a call, and this runs a hundred
        // thousand times per password
        h.withUnsafeMutableBufferPointer { hp in
            w.withUnsafeMutableBufferPointer { wp in
                k.withUnsafeBufferPointer { kp in
                    let w = wp.baseAddress!, k = kp.baseAddress!, h = hp.baseAddress!
                    for i in 0..<16 {
                        var v: UInt64 = 0
                        for j in 0..<8 { v = (v << 8) | UInt64(block[i * 8 + j]) }
                        w[i] = v
                    }
                    for i in 16..<80 {
                        let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
                        let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
                        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                    }
                    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                    for i in 0..<80 {
                        let t1 = hh &+ (rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
                        let t2 = (rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)) &+ ((a & b) ^ (a & c) ^ (b & c))
                        hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                    }
                    h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
                    h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
                }
            }
        }
    }

    /// The 64-byte digest of `message`.
    package static func hash(_ message: Data) -> Data {
        var s = State()
        s.update(message)
        return s.finalize()
    }

    package struct State: HashState {
        private var h: [UInt64] = [0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
                                   0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179]
        private var buffer = [UInt8](repeating: 0, count: 128)
        private var buffered = 0
        private var length: UInt64 = 0
        private var w = [UInt64](repeating: 0, count: 80)

        package init() {}

        package mutating func update(_ bytes: UnsafeRawBufferPointer) {
            var i = 0
            let n = bytes.count
            length &+= UInt64(n)
            if buffered > 0 {
                while buffered < 128, i < n { buffer[buffered] = bytes[i]; buffered += 1; i += 1 }
                if buffered == 128 { buffer.withUnsafeBufferPointer { SHA512.compress(&h, $0.baseAddress!, &w) }; buffered = 0 }
            }
            while i + 128 <= n {
                SHA512.compress(&h, bytes.baseAddress!.advanced(by: i).assumingMemoryBound(to: UInt8.self), &w)
                i += 128
            }
            while i < n { buffer[buffered] = bytes[i]; buffered += 1; i += 1 }
        }

        package mutating func finalize() -> Data {
            // padding: one 1 bit, zeros, then the message length in bits as a 128-bit big-endian count
            let bits = length &* 8
            var tail = [UInt8](buffer[0..<buffered])
            tail.append(0x80)
            while tail.count % 128 != 112 { tail.append(0) }
            tail.append(contentsOf: [UInt8](repeating: 0, count: 8))          // the high 64 bits: no message is that long
            for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(shift)) & 0xff)) }
            tail.withUnsafeBufferPointer { p in
                var offset = 0
                while offset < p.count { SHA512.compress(&h, p.baseAddress!.advanced(by: offset), &w); offset += 128 }
            }
            var out = Data(capacity: 64)
            for v in h { for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(shift)) & 0xff)) } }
            return out
        }
    }
}
