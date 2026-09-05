import Foundation

/// The file formats SwiftSheets knows about. Detection is content-based (see `detect(from:)`), never by extension.
public enum SheetFormat: String, Hashable, Sendable, CaseIterable, Codable {
    case xlsx, xlsm, ods, numbers, csv

    /// The usual file extension.
    public var fileExtension: String { rawValue }

    /// The product that carries this format's codec — what a `CodecSet` names when it lacks one (Appendix B.44).
    package var productName: String {
        switch self {
        case .xlsx, .xlsm: "SheetXLSX"
        case .csv: "SheetCSV"
        case .ods: "SheetODS"
        case .numbers: "SheetNumbers"
        }
    }

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

    /// The same rules over a file, reading only what they need: the first bytes, the ZIP directory at the end and
    /// the one or two small entries the rules look at — never the whole file, whatever its size (spec §4.2,
    /// Appendix B.39.4). A directory is a Numbers document saved as a package (`Index.zip` inside). Throws only
    /// when the file cannot be read at all; a file that is nothing recognisable answers nil.
    public static func detect(contentsOf url: URL) throws -> SheetFormat? {
        if url.isDirectoryOnDisk { return NumbersBundle.isBundle(url) ? .numbers : nil }
        return try detect(source: try FileByteSource(url: url), filename: url.lastPathComponent)
    }

    /// Detection over any byte source: what `detect(contentsOf:)` does, for a test to count the bytes it reads.
    package static func detect(source: any ByteSource, filename: String? = nil) throws -> SheetFormat? {
        // four bytes decide whether this is a package; only text needs a window
        if ZipInspection.looksLikeZip(try source.bytes(in: 0..<Swift.min(source.count, 4))) {
            guard let zip = try? ZipArchive(source: source) else { return nil }
            return detect(in: ZipInspection(archive: zip))
        }
        let head = try source.bytes(in: 0..<Swift.min(source.count, 64 * 1024))
        if TextEncodingSniffer.looksLikeText(head, isWholeFile: source.count <= head.count) { return .csv }
        return filename.flatMap { SheetFormat(fileExtension: ($0 as NSString).pathExtension) }
    }

    /// Everything detection can say in one answer: a spreadsheet of some format, a file this library recognises
    /// but will not open (encrypted, or the legacy `.xls` generation) and why, or nothing it knows. One call
    /// instead of `detect` followed by `UnopenableInput.probe`.
    public static func probe(contentsOf url: URL) throws -> FormatProbe {
        if url.isDirectoryOnDisk { return NumbersBundle.isBundle(url) ? .spreadsheet(.numbers) : .unrecognized }
        return try probe(source: try FileByteSource(url: url), filename: url.lastPathComponent)
    }

    public static func probe(_ data: Data, filename: String? = nil) -> FormatProbe {
        (try? probe(source: DataByteSource(data), filename: filename)) ?? .unrecognized
    }

    /// `limits` is what a package may declare about itself before it is refused, for a caller about to open the
    /// file with the same limits — a package the default limits refuse is not "unrecognised" to such a caller.
    package static func probe(source: any ByteSource, filename: String? = nil, limits: ZipLimits = .default) throws -> FormatProbe {
        let signature = try source.bytes(in: 0..<Swift.min(source.count, 8))
        if signature.count >= 8, [UInt8](signature) == UnopenableInput.compoundFileSignature {
            // a compound file: the stream names sit in its directory, which follows the streams — scanned a window
            // at a time to the end, since a protected package is as big as the workbook inside it
            return .unopenable(try UnopenableInput.probe(compoundFile: source))
        }
        if ZipInspection.looksLikeZip(signature) {
            guard let zip = try? ZipArchive(source: source, limits: limits) else { return .unrecognized }
            let container = ZipInspection(archive: zip)
            guard let format = detect(in: container) else { return .unrecognized }
            if let unopenable = UnopenableInput.probe(in: container) { return .unopenable(unopenable) }
            return .spreadsheet(format)
        }
        let head = try source.bytes(in: 0..<Swift.min(source.count, 64 * 1024))
        if TextEncodingSniffer.looksLikeText(head, isWholeFile: source.count <= head.count) { return .spreadsheet(.csv) }
        if let f = filename.flatMap({ SheetFormat(fileExtension: ($0 as NSString).pathExtension) }) { return .spreadsheet(f) }
        return .unrecognized
    }
}

/// What `SheetFormat.probe` answers.
public enum FormatProbe: Sendable, Hashable {
    /// A spreadsheet this library reads.
    case spreadsheet(SheetFormat)
    /// A file the library recognises and will not open — encrypted, or a legacy `.xls` — with the reason.
    case unopenable(UnopenableInput)
    /// Nothing the library knows.
    case unrecognized

    /// The format, when the answer is a spreadsheet.
    public var format: SheetFormat? { if case .spreadsheet(let f) = self { return f }; return nil }
}

/// A Numbers document saved as a folder rather than a single file: `Index.zip` (or an `Index/` folder of IWA
/// files) beside `Metadata/` and `Data/`.
package enum NumbersBundle {
    package static func isBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("Index.zip").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Index/Document.iwa").path)
    }
}

extension URL {
    /// True when the URL names an existing directory.
    package var isDirectoryOnDisk: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
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
        data.withUnsafeBytes { firstInvalidUTF8Offset(in: $0) }
    }

    package static func firstInvalidUTF8Offset(in raw: UnsafeRawBufferPointer) -> Int? {
        do {
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
    /// Looks at the first 64 KiB, as bytes — nothing is decoded into a `String` to be judged.
    public static func looksLikeText(_ data: Data) -> Bool {
        looksLikeText(data.prefix(64 * 1024), isWholeFile: data.count <= 64 * 1024)
    }

    /// `window` is the head of the file; `isWholeFile` says whether it is all of it, in which case a sequence
    /// cut off at the window's end is a fault rather than a boundary.
    package static func looksLikeText(_ window: Data, isWholeFile: Bool) -> Bool {
        guard !window.isEmpty else { return true }
        let encoding: String.Encoding
        var body = window
        if let (enc, len) = bom(in: window) { encoding = enc; body = window.dropFirst(len) } else { encoding = .utf8 }
        switch encoding {
        case .utf8:
            if let bad = firstInvalidUTF8Offset(in: body) {
                // a multi-byte sequence cut by the window's edge is not a verdict
                guard !isWholeFile, bad >= body.count - 3 else { return false }
            }
            return !body.withUnsafeBytes { raw in raw.contains { $0 < 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D } }
        case .utf16LittleEndian, .utf16BigEndian:
            let little = encoding == .utf16LittleEndian
            return body.withUnsafeBytes { raw -> Bool in
                let b = raw.bindMemory(to: UInt8.self)
                var i = 0
                var expectTrail = false
                while i + 1 < b.count {
                    let unit = little ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : UInt16(b[i]) << 8 | UInt16(b[i + 1])
                    if expectTrail {
                        guard UTF16.isTrailSurrogate(unit) else { return false }
                        expectTrail = false
                    } else if UTF16.isLeadSurrogate(unit) {
                        expectTrail = true
                    } else if UTF16.isTrailSurrogate(unit) {
                        return false
                    } else if unit < 0x20, unit != 0x09, unit != 0x0A, unit != 0x0D {
                        return false
                    }
                    i += 2
                }
                if isWholeFile { return i == b.count && !expectTrail }   // an odd byte or a lone lead is a fault
                return true
            }
        default:
            return false
        }
    }
}
