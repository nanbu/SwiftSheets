import Foundation

/// The contract every format codec fulfils: detect, read, write, inspect, read row by row, write row by row — and
/// report what no direction could express.
///
/// Both directions answer with a result, not a bare value: "read it, but this part of the file has no place in the
/// model" is exactly as much a loss as "wrote it, but this feature has no place in the format", and the spec's rule
/// (§4.1, §6) is that a loss is never silent. A codec that has nothing to report returns no warnings.
///
/// The contract is what a `CodecSet` dispatches on (spec Appendix B.44): it holds the codecs an application links
/// as `any SpreadsheetCodec.Type`, keyed by `format`, and every entry point of the library — `read`, `inspect`,
/// `write`, `streamingReader`, `streamingWriter` — is one of these requirements reached through the table. That is
/// why the row-by-row readers and writers are requirements too, and why the file-on-disk forms are: a codec whose
/// documents can be a folder (Numbers) opens the folder, and a streaming reader opens a file through positioned
/// reads rather than a mapping (Appendix B.39.8), so the codec has to be the one that opens the URL.
package protocol SpreadsheetCodec: Sendable {
    static var format: SheetFormat { get }
    /// Whether this codec can read the container. Answered from `SheetFormat.detect(in:)` so that the rules of
    /// §4.2 have exactly one implementation.
    static func canDecode(_ container: ZipInspection) -> Bool
    static func read(_ data: Data, options: ReadOptions) throws -> ReadResult
    static func write(_ workbook: Workbook, options: WriteOptions) throws -> WriteResult

    /// Reads a file on disk. The default maps the file and reads the bytes; a codec whose documents can be a folder
    /// on disk overrides it.
    static func read(contentsOf url: URL, options: ReadOptions) throws -> ReadResult
    /// What a file of this format says about itself before any cell is read (spec Appendix B.39.3): the sheets it
    /// declares, how many cells each says it holds, what the package expands to, who wrote it.
    static func inspect(_ data: Data, options: InspectOptions) throws -> WorkbookSummary
    /// `inspect` over a file on disk. The default maps the file; a codec whose documents can be a folder overrides it.
    static func inspect(contentsOf url: URL, options: InspectOptions) throws -> WorkbookSummary
    /// A reader that walks a file on disk one row at a time (spec Appendix B.40), through positioned reads rather
    /// than a mapping. `limits` is what the container may declare about itself; `csv` the dialect and encoding of a
    /// text file — a codec ignores what does not apply to its format.
    static func streamingReader(contentsOf url: URL, limits: ZipLimits, csv: CSVReadOptions) throws -> StreamingReader
    /// The same reader over bytes. `filename` is the extension hint plain text needs (`.tsv`).
    static func streamingReader(_ data: Data, limits: ZipLimits, csv: CSVReadOptions, filename: String?) throws -> StreamingReader
    /// A writer that appends rows to a new file (spec Appendix B.42), starting with a sheet named `sheetName`.
    /// `epoch` is the date origin where the format has one; `csv` the dialect and encoding of a text file.
    ///
    /// `url` is the temporary file the set reserved beside the destination, never the destination itself: what
    /// makes the destination survive a failed write is that no codec is ever handed it (spec Appendix B.51).
    static func streamingSink(url: URL, sheetName: String, epoch: DateEpoch, csv: CSVWriteOptions) throws -> any StreamingRowSink
}

extension SpreadsheetCodec {
    /// The file, mapped rather than copied when it is big enough to matter and stable enough to be safe, then read.
    package static func read(contentsOf url: URL, options: ReadOptions) throws -> ReadResult {
        try read(try Data(contentsOf: url, options: .mappedIfSafe), options: options)
    }

    /// The file, mapped, then inspected.
    package static func inspect(contentsOf url: URL, options: InspectOptions) throws -> WorkbookSummary {
        try inspect(try Data(contentsOf: url, options: .mappedIfSafe), options: options)
    }
}

/// One format an application can open, as a value to put in a `CodecSet` (spec Appendix B.50).
///
/// A `Codec` is a choice, not a worker: the only thing it says is which `format` it is for, and there is no way to
/// make one except by naming the constant its product publishes — `.xlsx` and `.xlsm` come with `SheetXLSX`, `.ods`
/// with `SheetODS`, `.numbers` with `SheetNumbers`, `.csv` with `SheetCSV`. An application that does not link a
/// product cannot name its format, and the compiler says so at the line that names it rather than at run time.
///
/// Reading and writing stay on `CodecSet`, which is where detection, the refusals that come before any codec, and
/// the warnings a format cannot carry all live (spec Appendix B.44). Handing out the implementation would be a
/// second door into the library that skips them.
public struct Codec: Sendable {
    package let implementation: any SpreadsheetCodec.Type

    package init(_ implementation: any SpreadsheetCodec.Type) { self.implementation = implementation }

    /// The format this codec is for.
    public var format: SheetFormat { implementation.format }
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
    /// What a formula cell arrives as: the formula with its last computed value beside it, or that value alone
    /// (spec Appendix B.54).
    public var formulaCells = FormulaCellReading.formulas
    /// Keep parts the codec does not interpret (charts, VBA, …) for a lossless write-back (spec §6). Off saves memory
    /// when only values are needed.
    public var preservesUnknownParts = true
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
    /// Which sheets to read (spec Appendix B.39.10). Nil reads them all. An XLSX sheet left out is carried as the
    /// bytes it arrived in and written back unchanged — a same-format save loses nothing — and reported with a
    /// `degraded` warning; an ODS or Numbers sheet left out comes back empty, and writing such a workbook reports
    /// the sheets it could not fill in.
    public var sheets: SheetSelection?
    /// How many sheets of an XLSX / XLSM workbook may be parsed at once (spec Appendix B.41). Nil, the default,
    /// decides on its own: the sheets are read side by side, up to one per processor core, when there are at
    /// least two of them and their parts expand to a few megabytes — a small workbook is not worth the threads.
    /// `1` reads them one after another whatever their size; `n` reads at most `n` at once and does so even for a
    /// small workbook.
    ///
    /// This is also the handle on memory: every sheet ends up in the model whichever way it is read, and what
    /// reading side by side adds is the working room of the sheets in flight at the same moment — bounded by
    /// this number (the performance record, docs/performance.html, has the measured figures for eight sheets
    /// read one at a time and side by side). ODS and Numbers ignore it: an ODS document is one part, and a
    /// Numbers document is read from an index.
    public var concurrency: Int?

    public init(formulaCells: FormulaCellReading = .formulas, preservesUnknownParts: Bool = true, csv: CSVReadOptions = CSVReadOptions(),
                filename: String? = nil, cellLimit: Int = Int.max, limits: ZipLimits = ZipLimits(),
                sheets: SheetSelection? = nil, concurrency: Int? = nil) {
        self.formulaCells = formulaCells; self.preservesUnknownParts = preservesUnknownParts; self.csv = csv
        self.filename = filename; self.cellLimit = cellLimit; self.limits = limits; self.sheets = sheets
        self.concurrency = concurrency
    }
}

/// What a read makes of a formula cell (spec Appendix B.54). The same choice serves the whole-workbook readers and the
/// row-by-row ones, in every format that carries formulas.
public enum FormulaCellReading: String, Sendable, Hashable, CaseIterable {
    /// The formula, parsed, with the value the producing application last computed beside it —
    /// `CellValue.formula(_:cached:)`. The default.
    case formulas
    /// Only that last computed value, as a plain value (`.number`, `.text`, …), so a cell reads the same whether it was
    /// typed or calculated. A formula cell whose file carries no computed value reads as **empty** (nil) — the library
    /// does not calculate.
    case cachedValues
}

/// The sheets a read should take in, by name or by position in the file's order.
public enum SheetSelection: Sendable, Hashable {
    case named([String])
    case indices([Int])

    /// Whether the sheet at `index` named `name` is selected.
    public func includes(name: String, index: Int) -> Bool {
        switch self {
        case .named(let names): return names.contains(name)
        case .indices(let indices): return indices.contains(index)
        }
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

    /// Builds the suggestion from the warnings (spec §11.2): many warnings, or a whole feature dropped, point to the
    /// format that would have kept them — which is decided by *what* was lost, not by what was asked for. Macros need
    /// a macro-enabled workbook; several tables on one sheet need Numbers; everything else the library writes is kept
    /// best by XLSX. No format keeps all three, so Numbers is named only when the tables are the whole loss, and the
    /// count is of the elements the named format would actually keep — a suggestion that overstates is worse than
    /// none. When the target already is that format there is nowhere better to go, and nothing is suggested.
    package static func suggest(from warnings: [ConversionWarning], target: SheetFormat, options: WriteOptions) -> Suggestion? {
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
        let place = [sheet, location?.address].compactMap { $0 }.joined(separator: "!")
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
