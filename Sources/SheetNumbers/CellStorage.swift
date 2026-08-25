import Foundation
import SheetCore

/// The packed per-cell record of a `TST.TileRowInfo` (storage version 5): a 12-byte header (version, cell type,
/// flags) followed by the fields the flag bits announce, in flag order. Decoded from observed documents (numbers-parser
/// documents the layout; no Apple source).
struct CellStorage {
    enum CellType: Int { case generic = 0, span = 1, number = 2, text = 3, formula = 4, date = 5, bool = 6, duration = 7, formulaError = 8, automatic = 9, currency = 10 }
    static let decimal128Bias = 0x1820

    var cellType: CellType
    var decimal: Decimal?
    var double: Double?
    var seconds: Double?
    var stringID: Int?
    var richID: Int?
    var cellStyleID: Int?
    var textStyleID: Int?
    var formulaID: Int?
    var conditionalStyleID: Int?
    var formulaErrorID: Int?
    var numFormatID: Int?
    var currencyFormatID: Int?
    var dateFormatID: Int?
    var durationFormatID: Int?
    var textFormatID: Int?
    var boolFormatID: Int?
    var extras: UInt16 = 0

    static func decode(_ buffer: Data) throws -> CellStorage {
        let b = [UInt8](buffer)
        guard b.count >= 12 else { throw SheetError.malformedPart(path: "cell storage", detail: "record shorter than its header") }
        guard b[0] == 5 else { throw SheetError.unsupportedFeature("cell storage version \(b[0]) (only version 5 is supported)") }
        guard let type = CellType(rawValue: Int(b[1])) else { throw SheetError.unsupportedFeature("cell type \(b[1])") }
        var s = CellStorage(cellType: type)
        s.extras = UInt16(b[6]) | UInt16(b[7]) << 8
        let flags = Int(UInt32(b[8]) | UInt32(b[9]) << 8 | UInt32(b[10]) << 16 | UInt32(b[11]) << 24)
        var o = 12
        func int32() throws -> Int {
            guard o + 4 <= b.count else { throw SheetError.malformedPart(path: "cell storage", detail: "truncated field") }
            let v = Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
            o += 4
            return Int(v)
        }
        func double() throws -> Double {
            guard o + 8 <= b.count else { throw SheetError.malformedPart(path: "cell storage", detail: "truncated double") }
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * UInt64(k)) }
            o += 8
            return Double(bitPattern: v)
        }
        if flags & 0x1 != 0 {
            guard o + 16 <= b.count else { throw SheetError.malformedPart(path: "cell storage", detail: "truncated decimal128") }
            s.decimal = decodeDecimal128(Array(b[o..<(o + 16)])); o += 16
        }
        if flags & 0x2 != 0 { s.double = try double() }
        if flags & 0x4 != 0 { s.seconds = try double() }
        if flags & 0x8 != 0 { s.stringID = try int32() }
        if flags & 0x10 != 0 { s.richID = try int32() }
        if flags & 0x20 != 0 { s.cellStyleID = try int32() }
        if flags & 0x40 != 0 { s.textStyleID = try int32() }
        if flags & 0x80 != 0 { s.conditionalStyleID = try int32() }
        if flags & 0x100 != 0 { _ = try int32() }       // conditional rule style
        if flags & 0x200 != 0 { s.formulaID = try int32() }
        if flags & 0x400 != 0 { _ = try int32() }       // control
        if flags & 0x800 != 0 { s.formulaErrorID = try int32() }
        if flags & 0x1000 != 0 { _ = try int32() }      // suggest
        if flags & 0x2000 != 0 { s.numFormatID = try int32() }
        if flags & 0x4000 != 0 { s.currencyFormatID = try int32() }
        if flags & 0x8000 != 0 { s.dateFormatID = try int32() }
        if flags & 0x10000 != 0 { s.durationFormatID = try int32() }
        if flags & 0x20000 != 0 { s.textFormatID = try int32() }
        if flags & 0x40000 != 0 { s.boolFormatID = try int32() }
        return s
    }

    /// IEEE 754 decimal128 as Numbers writes it: 113-bit binary integer significand (bytes 0…13 + bit 0 of byte 14),
    /// 14-bit biased exponent, sign bit.
    static func decodeDecimal128(_ b: [UInt8]) -> Decimal {
        let exp = Int((Int(b[15] & 0x7F) << 7) | Int(b[14] >> 1)) - decimal128Bias
        var mantissa = Decimal(Int(b[14] & 1))
        for i in stride(from: 13, through: 0, by: -1) { mantissa = mantissa * 256 + Decimal(Int(b[i])) }
        guard var value = Decimal(string: "\(mantissa)e\(exp)") else { return 0 }
        if b[15] & 0x80 != 0 { value = -value }
        return value
    }

    /// The inverse: the decimal's own significand and exponent go straight into the record.
    static func encodeDecimal128(_ value: Decimal) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        let negative = value < 0
        let magnitude = negative ? -value : value
        var exponent = Int(magnitude.exponent)
        var digits = "\(magnitude.significand)"
        if magnitude == 0 {
            digits = "0"; exponent = 0
        } else if exponent > 0, exponent <= 34 - digits.count {
            // Numbers writes a whole number with its own digits and no exponent — 100, not 1e2 — where Swift's
            // `Decimal` normalises the other way. Both spell the same value, but the reference reader renders
            // the exponent form as "100.0", so a formula written that way stops looking like the one asked for.
            digits += String(repeating: "0", count: exponent)
            exponent = 0
        }
        // base-10 digit string → little-endian base-256 bytes
        var bytes: [UInt8] = []
        while digits != "0" {
            var rem = 0, next = ""
            for ch in digits.unicodeScalars {
                let cur = rem * 10 + Int(ch.value - 48)
                let q = cur / 256
                rem = cur % 256
                if !next.isEmpty || q > 0 { next.unicodeScalars.append(UnicodeScalar(UInt8(q + 48))) }
            }
            bytes.append(UInt8(rem))
            digits = next.isEmpty ? "0" : next
        }
        for (i, byte) in bytes.prefix(14).enumerated() { out[i] = byte }
        if bytes.count > 14 { out[14] = bytes[14] & 1 }
        let biased = exponent + decimal128Bias
        out[14] |= UInt8((biased & 0x7F) << 1)
        out[15] |= UInt8((biased >> 7) & 0x7F)
        if negative { out[15] |= 0x80 }
        return out
    }

    // MARK: - Encoding (write side)

    /// A version-5 record for a value. `stringID` / `richID` index the table's string / rich-text lists,
    /// `cellStyleID` / `textStyleID` its style list and the `*FormatID`s its format list. The fields go out in flag
    /// order, which is the order `decode` reads them in.
    static func encode(type: CellType, decimal: Decimal? = nil, double: Double? = nil, seconds: Double? = nil, stringID: Int? = nil,
                       cellStyleID: Int? = nil, textStyleID: Int? = nil, conditionalStyleID: Int? = nil, formulaID: Int? = nil,
                       numFormatID: Int? = nil, currencyFormatID: Int? = nil, dateFormatID: Int? = nil,
                       durationFormatID: Int? = nil, textFormatID: Int? = nil, boolFormatID: Int? = nil) -> Data {
        var flags = 0
        var body = [UInt8]()
        func int32(_ v: Int) { let u = UInt32(bitPattern: Int32(v)); for k in 0..<4 { body.append(UInt8((u >> (8 * UInt32(k))) & 0xFF)) } }
        func dbl(_ v: Double) { let u = v.bitPattern; for k in 0..<8 { body.append(UInt8((u >> (8 * UInt64(k))) & 0xFF)) } }
        var extras: UInt8 = 0
        if let decimal { flags |= 0x1; body.append(contentsOf: encodeDecimal128(decimal)) }
        if let double { flags |= 0x2; dbl(double) }
        if let seconds { flags |= 0x4; dbl(seconds) }
        if let stringID { flags |= 0x8; int32(stringID); extras |= 0x80 }
        if let cellStyleID { flags |= 0x20; int32(cellStyleID) }
        if let textStyleID { flags |= 0x40; int32(textStyleID) }
        if let conditionalStyleID { flags |= 0x80; int32(conditionalStyleID) }
        if let formulaID { flags |= 0x200; int32(formulaID) }
        if let numFormatID { flags |= 0x2000; int32(numFormatID); extras |= 1 }
        if let currencyFormatID { flags |= 0x4000; int32(currencyFormatID); extras |= 2 }
        if let dateFormatID { flags |= 0x8000; int32(dateFormatID); extras |= 8 }
        if let durationFormatID { flags |= 0x10000; int32(durationFormatID); extras |= 4 }
        if let textFormatID { flags |= 0x20000; int32(textFormatID) }
        if let boolFormatID { flags |= 0x40000; int32(boolFormatID); extras |= 0x20 }
        var out = [UInt8](repeating: 0, count: 12)
        out[0] = 5; out[1] = UInt8(type.rawValue); out[6] = extras
        let f = UInt32(flags)
        for k in 0..<4 { out[8 + k] = UInt8((f >> (8 * UInt32(k))) & 0xFF) }
        out.append(contentsOf: body)
        return Data(out)
    }
}
