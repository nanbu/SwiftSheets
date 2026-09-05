import Foundation
import SheetCore
import SheetDecrypt

/// The forward cipher (FIPS 197 §5.1): the `Te` tables and `encryptBlock`, with the CBC / ECB walks over it. The
/// key schedule and the inverse cipher are SheetDecrypt's; this extension is the only place in the package that
/// encrypts a block (spec Appendix B.39.9, Rev 4.29).
extension AES {
    // the round tables: Te[i][x] = MixColumns column of SubBytes(x) rotated by i
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

    /// One block: `input` → `output` (16 bytes each; may be the same memory).
    package func encryptBlock(_ input: UnsafePointer<UInt8>, _ output: UnsafeMutablePointer<UInt8>) {
        let k = roundKeys
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
}
