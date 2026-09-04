import Foundation

/// The contract every format codec fulfils: detect, read, write — and report what neither direction could express.
///
/// Both directions answer with a result, not a bare value: "read it, but this part of the file has no place in the
/// model" is exactly as much a loss as "wrote it, but this feature has no place in the format", and the spec's rule
/// (§4.1, §6) is that a loss is never silent. A codec that has nothing to report returns no warnings.
public protocol SpreadsheetCodec {
    static var format: SheetFormat { get }
    /// Whether this codec can read the container. Answered from `SheetFormat.detect(in:)` so that the rules of
    /// §4.2 have exactly one implementation.
    static func canDecode(_ container: ZipInspection) -> Bool
    static func read(_ data: Data, options: ReadOptions) throws -> ReadResult
    static func write(_ workbook: Workbook, options: WriteOptions) throws -> WriteResult
}

/// A workbook plus whatever the file held that the model cannot say (spec §6): a data style with no Excel
/// equivalent, cells in a storage version we cannot decode, undecodable bytes repaired under `lossy`.
public struct ReadResult: Sendable {
    public let workbook: Workbook
    public let warnings: [ConversionWarning]

    public init(workbook: Workbook, warnings: [ConversionWarning] = []) {
        var wb = workbook
        wb.readWarnings = warnings          // they travel with the model, so a plain `Workbook(contentsOf:)` keeps them
        self.workbook = wb
        self.warnings = warnings
    }
}

/// Options for reading any format.
public struct ReadOptions: Sendable, Hashable {
    /// Formula cells yield their cached values (openpyxl `data_only=True`).
    public var dataOnly = false
    /// Keep parts the codec does not interpret (charts, VBA, …) for a lossless write-back (spec §6). Off saves memory
    /// when only values are needed.
    public var preserveUnknownParts = true
    public var csv = CSVReadOptions()
    /// The original file name, when known — an extension hint for text files (`.tsv` → tab dialect).
    public var filename: String?
    /// The most cells one document may expand to before reading stops (with a `degraded` warning naming the
    /// sheet). ODS compresses runs of rows and cells, so a kilobyte of XML can ask for 16,384 × 1,048,576 of them.
    ///
    /// There is no ceiling by default: how many cells are worth holding is the caller's decision, and
    /// `Workbook.inspect` says how many a file declares before any of them is read. Set it for input you do not
    /// trust — every cell costs about 100–200 bytes in memory (spec Appendix B.39).
    public var cellLimit = Int.max

    /// What the container may declare about itself before it is refused as hostile — entry count, expanded size,
    /// compression ratio. Raise them for a package you know; the defaults are far past any real spreadsheet.
    public var limits = ZipLimits()
    /// The password of a protected file (spec Appendix B.39.9): an Excel workbook encrypted the way Excel 2010
    /// and later do it (ECMA-376 agile encryption), or an OpenDocument package encrypted as ODF 1.2 / 1.3 say.
    /// A wrong one is `SheetError.wrongPassword`; a protected file read without one is `unsupportedFeature`.
    public var password: String?

    public init(dataOnly: Bool = false, preserveUnknownParts: Bool = true, csv: CSVReadOptions = CSVReadOptions(),
                filename: String? = nil, cellLimit: Int = Int.max, limits: ZipLimits = ZipLimits(), password: String? = nil) {
        self.dataOnly = dataOnly; self.preserveUnknownParts = preserveUnknownParts; self.csv = csv
        self.filename = filename; self.cellLimit = cellLimit; self.limits = limits; self.password = password
    }
}

/// Options for writing any format.
public struct WriteOptions: Sendable, Hashable {
    public var csv = CSVWriteOptions()
    /// Warnings at or above this count (or any dropped VBA / chart) make `WriteResult.suggestion` propose another format.
    public var suggestionThreshold = 10
    /// Protect the file with a password (spec Appendix B.39.9): XLSX / XLSM as ECMA-376 agile encryption
    /// (AES-256, SHA-512, the form Excel 2010 and later write), ODS as ODF 1.3 §4.3 (AES-256-CBC per entry).
    /// CSV and Numbers cannot be protected and throw `unsupportedFeature`.
    public var password: String?

    public init(csv: CSVWriteOptions = CSVWriteOptions(), suggestionThreshold: Int = 10, password: String? = nil) {
        self.csv = csv; self.suggestionThreshold = suggestionThreshold; self.password = password
    }
}

/// The bytes written plus everything that did not survive the trip.
public struct WriteResult: Sendable {
    public let data: Data
    public let warnings: [ConversionWarning]
    /// Set when the degradation crosses `WriteOptions.suggestionThreshold`: a better-suited format to consider.
    public let suggestion: Suggestion?

    public init(data: Data, warnings: [ConversionWarning] = [], suggestion: Suggestion? = nil) {
        self.data = data; self.warnings = warnings; self.suggestion = suggestion
    }

    public struct Suggestion: Sendable, Hashable {
        public let format: SheetFormat
        public let message: String
        public init(format: SheetFormat, message: String) { self.format = format; self.message = message }
    }

    /// Builds the suggestion from the warnings (spec §11.2): many warnings, or a whole feature dropped, point to the
    /// format that would have kept them — which is decided by *what* was lost, not by what was asked for. Macros need
    /// a macro-enabled workbook; several tables on one sheet need Numbers; everything else the library writes is kept
    /// best by XLSX. No format keeps all three, so Numbers is named only when the tables are the whole loss, and the
    /// count is of the elements the named format would actually keep — a suggestion that overstates is worse than
    /// none. When the target already is that format there is nowhere better to go, and nothing is suggested.
    public static func suggest(from warnings: [ConversionWarning], target: SheetFormat, options: WriteOptions) -> Suggestion? {
        let dropped = warnings.filter { $0.kind == .dropped }
        guard warnings.count >= options.suggestionThreshold || dropped.contains(where: { $0.location == nil }) else { return nil }
        let alternative: SheetFormat
        if dropped.contains(where: { $0.subject == .macros }) { alternative = .xlsm }
        else if !dropped.isEmpty, dropped.allSatisfy({ $0.subject == .tables }) { alternative = .numbers }
        else { alternative = .xlsx }
        guard alternative != target else { return nil }
        let kept = warnings.filter { alternative == .numbers ? $0.subject == .tables : $0.subject != .tables }
        guard !kept.isEmpty else { return nil }
        return Suggestion(format: alternative, message: "\(kept.count) element(s) cannot be represented in \(target.rawValue.uppercased()); writing \(alternative.rawValue.uppercased()) would keep them.")
    }
}

/// One thing a conversion could not express faithfully. Never thrown — collected on the result.
public struct ConversionWarning: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// Gone from the output.
        case dropped
        /// Present but simplified (e.g. a formula replaced by its cached value).
        case degraded
        /// Replaced by the nearest equivalent.
        case substituted
    }
    /// What the warning is about. Enough to group warnings in a user interface, and enough for `WriteResult.suggest`
    /// to name a format that would have kept the thing rather than guessing from the target.
    public enum Subject: Sendable, Hashable {
        case macros
        /// Charts, drawings, pivot caches, images — the parts a same-format write preserves and a conversion cannot.
        case objects
        case formatting
        case formulas
        case sheets
        /// Several tables on one sheet (a Numbers canvas). Only Numbers can hold them; a worksheet, an ODS sheet and
        /// a CSV file are one grid each. Distinct from `.sheets` because the format that would keep it is different.
        case tables
        case other
    }
    public let kind: Kind
    public let subject: Subject
    public let sheet: String?
    public let location: CellRef?
    public let message: String

    public init(_ kind: Kind, subject: Subject = .other, sheet: String? = nil, location: CellRef? = nil, message: String) {
        self.kind = kind; self.subject = subject; self.sheet = sheet; self.location = location; self.message = message
    }

    public var description: String {
        let place = [sheet, location?.a1].compactMap { $0 }.joined(separator: "!")
        return (place.isEmpty ? "" : place + ": ") + message
    }
}

/// Where a workbook came from, for display and for choosing the write-back format.
public struct SourceInfo: Sendable, Hashable {
    public var format: SheetFormat
    /// The generating application as the file declares it (docProps/app.xml `Application`), when present.
    public var application: String?
    public var version: String?
    public init(format: SheetFormat, application: String? = nil, version: String? = nil) {
        self.format = format; self.application = application; self.version = version
    }
}
