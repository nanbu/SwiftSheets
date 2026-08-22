import Foundation

/// Separator / quoting conventions of a delimited text file.
public struct CSVDialect: Sendable, Hashable {
    public var delimiter: Character = ","
    public var quote: Character = "\""
    public init(delimiter: Character = ",", quote: Character = "\"") { self.delimiter = delimiter; self.quote = quote }
    public static let comma = CSVDialect()
    public static let tab = CSVDialect(delimiter: "\t")
    public static let semicolon = CSVDialect(delimiter: ";")
}

public enum CSVNewline: String, Sendable, Hashable {
    case crlf = "\r\n"
    case lf = "\n"
}

/// Reading options (spec §9). With no encoding given, UTF-8 is assumed and a UTF-8 / UTF-16 BOM is honoured.
public struct CSVReadOptions: Sendable, Hashable {
    /// nil = UTF-8 with automatic BOM handling. Set for legacy files (`.shiftJIS`, `.japaneseEUC`, …); BOM sniffing
    /// is then off (a leading UTF-8 BOM is still stripped for `.utf8`).
    public var encoding: String.Encoding?
    /// nil = sniff `,` / `;` / tab from the first line (a `.tsv` filename prefers tab).
    public var dialect: CSVDialect?
    /// Off by default: every field is text, so "01234" keeps its zero and "1-2" stays a string.
    public var inferTypes = false
    /// Date patterns tried (in order) when inferring types, e.g. ["yyyy/MM/dd"]. ISO `yyyy-MM-dd` is always tried last.
    public var dateFormats: [String] = []
    /// Replace undecodable bytes instead of failing, with a `degraded` warning.
    public var lossy = false

    public init(encoding: String.Encoding? = nil, dialect: CSVDialect? = nil, inferTypes: Bool = false, dateFormats: [String] = [], lossy: Bool = false) {
        self.encoding = encoding; self.dialect = dialect; self.inferTypes = inferTypes; self.dateFormats = dateFormats; self.lossy = lossy
    }
}

/// Writing options (spec §9). Default: UTF-8, no BOM, comma, CRLF, the active sheet.
public struct CSVWriteOptions: Sendable, Hashable {
    public var encoding: String.Encoding = .utf8
    /// True for files people will double-click into Excel (without a BOM, Japanese Excel assumes a legacy code page).
    /// Only meaningful for UTF-8 / UTF-16.
    public var includeBOM = false
    public var dialect = CSVDialect.comma
    public var newline = CSVNewline.crlf
    /// The sheet to write; nil = the active sheet.
    public var sheet: String?
    /// Characters the encoding cannot represent are replaced (with a `degraded` warning) instead of failing.
    public var lossy = false
    /// Dates are written in this `DateFormatter` pattern; nil = ISO 8601 (`yyyy-MM-dd`, with time when present).
    public var dateFormat: String?

    public init(encoding: String.Encoding = .utf8, includeBOM: Bool = false, dialect: CSVDialect = .comma, newline: CSVNewline = .crlf,
                sheet: String? = nil, lossy: Bool = false, dateFormat: String? = nil) {
        self.encoding = encoding; self.includeBOM = includeBOM; self.dialect = dialect; self.newline = newline
        self.sheet = sheet; self.lossy = lossy; self.dateFormat = dateFormat
    }
}

