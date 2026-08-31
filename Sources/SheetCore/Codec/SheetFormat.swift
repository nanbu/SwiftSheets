import Foundation

/// The file formats SwiftSheets knows about. Detection is content-based (see `detect(from:)`), never by extension.
public enum SheetFormat: String, Hashable, Sendable, CaseIterable, Codable {
    case xlsx, xlsm, ods, numbers, csv

    /// The usual file extension.
    public var fileExtension: String { rawValue }

    /// The format a file extension implies; nil for unknown extensions. "tsv" maps to `.csv`.
    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "xlsx": self = .xlsx
        case "xlsm": self = .xlsm
        case "ods": self = .ods
        case "numbers": self = .numbers
        case "csv", "tsv", "txt": self = .csv
        default: return nil
        }
    }

    /// Content-based detection (spec §4.2), in this fixed order:
    /// 1. ZIP with a `mimetype` entry reading `application/vnd.oasis.opendocument.spreadsheet` → `.ods`
    /// 2. ZIP with `[Content_Types].xml` → OOXML; `.xlsm` when the workbook part is macro-enabled, else `.xlsx`
    /// 3. ZIP with `Index/Document.iwa` (or a bundle's `Index.zip`) → `.numbers`
    /// 4. Not a ZIP: readable as text (UTF-8 / UTF-16 with or without BOM) → `.csv`
    /// 5. Otherwise nil.
    public static func detect(from data: Data) -> SheetFormat? {
        if ZipInspection.looksLikeZip(data) {
            guard let zip = try? ZipInspection(data: data) else { return nil }
            return detect(in: zip)
        }
        return TextEncodingSniffer.looksLikeText(data) ? .csv : nil
    }

    /// Steps 1–3 of the same rules, for a container that is already open. Every codec's `canDecode` answers from
    /// here: the order in which a package is recognised is one decision, and it lives in one place.
    public static func detect(in zip: ZipInspection) -> SheetFormat? {
        if let mime = zip.entry(named: "mimetype"), String(decoding: mime, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "application/vnd.oasis.opendocument.spreadsheet" {
            return .ods
        }
        if let ct = zip.entry(named: "[Content_Types].xml") {
            let text = String(decoding: ct, as: UTF8.self)
            return text.contains("ms-excel.sheet.macroEnabled.main+xml") ? .xlsm : .xlsx
        }
        if zip.contains("Index/Document.iwa") || zip.contains("Index.zip") { return .numbers }
        return nil
    }

    /// Detection with a filename hint: the content decides, the extension only breaks ties (plain text → `.csv`).
    public static func detect(from data: Data, filename: String?) -> SheetFormat? {
        if let f = detect(from: data) { return f }
        return filename.flatMap { SheetFormat(fileExtension: ($0 as NSString).pathExtension) }
    }
}

/// How a text file is encoded, as far as its first bytes tell.
public enum TextEncodingSniffer {
    /// UTF-8 / UTF-16 BOM detection. Returns the encoding and the BOM length.
    public static func bom(in data: Data) -> (String.Encoding, Int)? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return (.utf8, 3) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return (.utf16LittleEndian, 2) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return (.utf16BigEndian, 2) }
        return nil
    }

    /// Byte offset of the first sequence that is not valid UTF-8; nil when the whole buffer is.
    ///
    /// Reads the buffer where it lies — a part can be tens of megabytes, and copying it to check it would cost
    /// more than the check.
    package static func firstInvalidUTF8Offset(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i < n {
                let b = bytes[i]
                if b < 0x80 { i += 1; continue }
                let length: Int
                var minSecond: UInt8 = 0x80, maxSecond: UInt8 = 0xBF
                switch b {
                case 0xC2...0xDF: length = 2
                case 0xE0: length = 3; minSecond = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: length = 3
                case 0xED: length = 3; maxSecond = 0x9F          // no surrogates
                case 0xF0: length = 4; minSecond = 0x90
                case 0xF1...0xF3: length = 4
                case 0xF4: length = 4; maxSecond = 0x8F          // ≤ U+10FFFF
                default: return i
                }
                guard i + length <= n else { return i }
                guard bytes[i + 1] >= minSecond, bytes[i + 1] <= maxSecond else { return i }
                for k in 2..<length where bytes[i + k] < 0x80 || bytes[i + k] > 0xBF { return i }
                i += length
            }
            return nil
        }
    }

    /// True when the bytes decode as UTF-8 / UTF-16 text without control characters other than tab / newlines.
    public static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var body = data
        var encoding = String.Encoding.utf8
        if let (enc, len) = bom(in: data) { encoding = enc; body = data.dropFirst(len) }
        guard let text = String(data: body.prefix(64 * 1024), encoding: encoding) else {
            // a truncated multi-byte sequence at the 64 KiB boundary is not a format verdict
            return data.count > 64 * 1024 && String(data: body.prefix(32 * 1024), encoding: encoding) != nil
        }
        return !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }
    }
}
