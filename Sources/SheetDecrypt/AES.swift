import Foundation
import SheetCore

/// AES-128 / AES-192 / AES-256 as the spreadsheet encryptions use it (FIPS 197), in the table-driven form (four
/// 32-bit tables each way), so that a package of tens of megabytes is a matter of seconds rather than minutes.
///
/// This file is the half that opens a protected file: the key schedule, which both directions share, and the
/// inverse cipher (the inverse S-box, the `Td` tables, `decryptBlock` and the CBC / ECB walks over it). The forward
/// cipher — `encryptBlock` and the `Te` tables — is the SheetEncrypt product's extension of this type, so that a
/// binary linking only SheetDecrypt carries no code that encrypts (spec Appendix B.39.9, Rev 4.29). The arithmetic
/// is unchanged from when both halves shared a file; FIPS 197 Appendix C and SP 800-38A F.2 are the judges.
package struct AES {
    package static let sbox: [UInt8] = [
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
    @inline(__always) package static func xtime(_ b: UInt8) -> UInt8 { (b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0) }
    @inline(__always) private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, p: UInt8 = 0
        for _ in 0..<8 { if b & 1 != 0 { p ^= a }; a = xtime(a); b >>= 1 }
        return p
    }
    // the inverse round tables: Td[i][x] = InvMixColumns column of InvSubBytes(x) rotated by i
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

    /// The key schedule (FIPS 197 §5.2), 4 words per round key — what the forward cipher runs on.
    package let roundKeys: [UInt32]
    /// The same schedule with InvMixColumns applied to the middle rounds, in reverse order — the equivalent
    /// inverse cipher of FIPS 197 §5.3.5.
    private let decryptionKeys: [UInt32]
    package let rounds: Int

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
        roundKeys = w
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

    @inline(__always) package static func load(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
    }
    @inline(__always) package static func store(_ w: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(w >> 24); p[1] = UInt8((w >> 16) & 0xff); p[2] = UInt8((w >> 8) & 0xff); p[3] = UInt8(w & 0xff)
    }

    /// One block: `input` → `output` (16 bytes each; may be the same memory).
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
