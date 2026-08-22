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
        return TextEncodingSniffer.looksLikeText(data) ? .csv : nil
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

    /// True when the bytes decode as UTF-8 / UTF-16 text without control characters other than tab / newlines.
    public static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        var body = data
        var encoding = String.Encoding.utf8
        if let (enc, len) = bom(in: data) { encoding = enc; body = data.dropFirst(len) }
        guard let text = String(data: body.prefix(64 * 1024), encoding: encoding) ?? (encoding == .utf8 ? nil : nil) else {
            // a truncated multi-byte sequence at the 64 KiB boundary is not a format verdict
            return data.count > 64 * 1024 && String(data: body.prefix(32 * 1024), encoding: encoding) != nil
        }
        return !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }
    }
}
