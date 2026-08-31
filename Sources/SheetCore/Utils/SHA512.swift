import Foundation

/// SHA-512 (FIPS 180-4), written out here rather than borrowed.
///
/// The library hashes exactly one thing: the password on a protected sheet, which ECMA-376 §18.2.29 defines as
/// SHA-512 applied a hundred thousand times over. Apple's CryptoKit has that hash, but CryptoKit is an Apple
/// framework, and a machine without it would otherwise lose sheet protection along with it. Sixty lines of
/// arithmetic buy the same answer everywhere, and the published test vectors say whether the answer is right.
package enum SHA512 {

    /// The 64-byte digest of `message`.
    package static func hash(_ message: Data) -> Data {
        var h: [UInt64] = [0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
                           0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179]

        // padding: one 1 bit, zeros, then the message length in bits as a 128-bit big-endian count
        var block = [UInt8](); block.reserveCapacity(message.count + 145)
        block.append(contentsOf: message)
        block.append(0x80)
        while block.count % 128 != 112 { block.append(0) }
        let bits = UInt64(message.count) &* 8
        block.append(contentsOf: [UInt8](repeating: 0, count: 8))          // the high 64 bits: no message is that long
        for shift in stride(from: 56, through: 0, by: -8) { block.append(UInt8((bits >> UInt64(shift)) & 0xff)) }

        var w = [UInt64](repeating: 0, count: 80)
        block.withUnsafeBufferPointer { bytes in
            w.withUnsafeMutableBufferPointer { w in
                for start in stride(from: 0, to: bytes.count, by: 128) {
                    for i in 0..<16 {
                        var v: UInt64 = 0
                        for j in 0..<8 { v = (v << 8) | UInt64(bytes[start + i * 8 + j]) }
                        w[i] = v
                    }
                    for i in 16..<80 {
                        let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
                        let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
                        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                    }
                    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                    for i in 0..<80 {
                        let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                        let ch = (e & f) ^ (~e & g)
                        let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                        let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                        let maj = (a & b) ^ (a & c) ^ (b & c)
                        let t2 = s0 &+ maj
                        hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
                    }
                    h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
                }
            }
        }

        var out = Data(capacity: 64)
        for v in h { for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((v >> UInt64(shift)) & 0xff)) } }
        return out
    }

    private static func rotr(_ v: UInt64, _ n: UInt64) -> UInt64 { (v >> n) | (v << (64 - n)) }

    /// The first 64 bits of the fractional parts of the cube roots of the first eighty primes (FIPS 180-4 §4.2.3).
    private static let k: [UInt64] = [
        0x428a_2f98_d728_ae22, 0x7137_4491_23ef_65cd, 0xb5c0_fbcf_ec4d_3b2f, 0xe9b5_dba5_8189_dbbc,
        0x3956_c25b_f348_b538, 0x59f1_11f1_b605_d019, 0x923f_82a4_af19_4f9b, 0xab1c_5ed5_da6d_8118,
        0xd807_aa98_a303_0242, 0x1283_5b01_4570_6fbe, 0x2431_85be_4ee4_b28c, 0x550c_7dc3_d5ff_b4e2,
        0x72be_5d74_f27b_896f, 0x80de_b1fe_3b16_96b1, 0x9bdc_06a7_25c7_1235, 0xc19b_f174_cf69_2694,
        0xe49b_69c1_9ef1_4ad2, 0xefbe_4786_384f_25e3, 0x0fc1_9dc6_8b8c_d5b5, 0x240c_a1cc_77ac_9c65,
        0x2de9_2c6f_592b_0275, 0x4a74_84aa_6ea6_e483, 0x5cb0_a9dc_bd41_fbd4, 0x76f9_88da_8311_53b5,
        0x983e_5152_ee66_dfab, 0xa831_c66d_2db4_3210, 0xb003_27c8_98fb_213f, 0xbf59_7fc7_beef_0ee4,
        0xc6e0_0bf3_3da8_8fc2, 0xd5a7_9147_930a_a725, 0x06ca_6351_e003_826f, 0x1429_2967_0a0e_6e70,
        0x27b7_0a85_46d2_2ffc, 0x2e1b_2138_5c26_c926, 0x4d2c_6dfc_5ac4_2aed, 0x5338_0d13_9d95_b3df,
        0x650a_7354_8baf_63de, 0x766a_0abb_3c77_b2a8, 0x81c2_c92e_47ed_aee6, 0x9272_2c85_1482_353b,
        0xa2bf_e8a1_4cf1_0364, 0xa81a_664b_bc42_3001, 0xc24b_8b70_d0f8_9791, 0xc76c_51a3_0654_be30,
        0xd192_e819_d6ef_5218, 0xd699_0624_5565_a910, 0xf40e_3585_5771_202a, 0x106a_a070_32bb_d1b8,
        0x19a4_c116_b8d2_d0c8, 0x1e37_6c08_5141_ab53, 0x2748_774c_df8e_eb99, 0x34b0_bcb5_e19b_48a8,
        0x391c_0cb3_c5c9_5a63, 0x4ed8_aa4a_e341_8acb, 0x5b9c_ca4f_7763_e373, 0x682e_6ff3_d6b2_b8a3,
        0x748f_82ee_5def_b2fc, 0x78a5_636f_4317_2f60, 0x84c8_7814_a1f0_ab72, 0x8cc7_0208_1a64_39ec,
        0x90be_fffa_2363_1e28, 0xa450_6ceb_de82_bde9, 0xbef9_a3f7_b2c6_7915, 0xc671_78f2_e372_532b,
        0xca27_3ece_ea26_619c, 0xd186_b8c7_21c0_c207, 0xeada_7dd6_cde0_eb1e, 0xf57d_4f7f_ee6e_d178,
        0x06f0_67aa_7217_6fba, 0x0a63_7dc5_a2c8_98a6, 0x113f_9804_bef9_0dae, 0x1b71_0b35_131c_471b,
        0x28db_77f5_2304_7d84, 0x32ca_ab7b_40c7_2493, 0x3c9e_be0a_15c9_bebc, 0x431d_67c4_9c10_0d4c,
        0x4cc5_d4be_cb3e_42b6, 0x597f_299c_fc65_7e2a, 0x5fcb_6fab_3ad6_faec, 0x6c44_198c_4a47_5817]
}
