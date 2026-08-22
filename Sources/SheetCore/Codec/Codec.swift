import Foundation

/// The contract every format codec fulfils: detect, read, write — and report what the write could not express.
public protocol SpreadsheetCodec {
    static var format: SheetFormat { get }
    /// Whether this codec can read the container (content-based; see `SheetFormat.detect`).
    static func canDecode(_ container: ZipInspection) -> Bool
    static func read(_ data: Data, options: ReadOptions) throws -> Workbook
    static func write(_ workbook: Workbook, options: WriteOptions) throws -> WriteResult
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

    public init(dataOnly: Bool = false, preserveUnknownParts: Bool = true, csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) {
        self.dataOnly = dataOnly; self.preserveUnknownParts = preserveUnknownParts; self.csv = csv; self.filename = filename
    }
}

/// Options for writing any format.
public struct WriteOptions: Sendable, Hashable {
    public var csv = CSVWriteOptions()
    /// Warnings at or above this count (or any dropped VBA / chart) make `WriteResult.suggestion` propose another format.
    public var suggestionThreshold = 10

    public init(csv: CSVWriteOptions = CSVWriteOptions(), suggestionThreshold: Int = 10) {
        self.csv = csv; self.suggestionThreshold = suggestionThreshold
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

    /// Builds the suggestion from the warnings (spec §11.2): many warnings, or a dropped opaque part, point to the
    /// format that would have kept them.
    public static func suggest(from warnings: [ConversionWarning], target: SheetFormat, options: WriteOptions) -> Suggestion? {
        let dropped = warnings.filter { $0.kind == .dropped }
        guard warnings.count >= options.suggestionThreshold || dropped.contains(where: { $0.location == nil }) else { return nil }
        let alternative: SheetFormat = target == .xlsx ? .xlsm : .xlsx
        return Suggestion(format: alternative, message: "\(warnings.count) element(s) cannot be represented in \(target.rawValue.uppercased()); writing \(alternative.rawValue.uppercased()) would keep them.")
    }
}

/// One thing a write could not express faithfully. Never thrown — collected on the result.
public struct ConversionWarning: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable {
        /// Gone from the output.
        case dropped
        /// Present but simplified (e.g. a formula replaced by its cached value).
        case degraded
        /// Replaced by the nearest equivalent.
        case substituted
    }
    public let kind: Kind
    public let sheet: String?
    public let location: CellRef?
    public let message: String

    public init(_ kind: Kind, sheet: String? = nil, location: CellRef? = nil, message: String) {
        self.kind = kind; self.sheet = sheet; self.location = location; self.message = message
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
