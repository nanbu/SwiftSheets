import Foundation

/// The codecs an application links, as one table keyed by format — and on it the five things the library does with
/// a file of any format: open it, ask it about itself before reading, write it, walk it row by row, write it row by
/// row (spec Appendix B.44).
///
/// The `SwiftSheets` product holds every codec as `CodecSet.all`, and its conveniences — `Workbook(contentsOf:)`,
/// `Workbook.inspect`, `StreamingReader(contentsOf:)`, `StreamingWriter(url:)` — are these methods on that set. An
/// application that links only the formats it needs makes its own set and gets the same facade, with the same
/// detection and the same refusals:
///
///     import SheetXLSX, SheetODS, SheetNumbers (and SheetCore) — no SheetCSV, no umbrella — then:
///     let codecs = CodecSet([XLSXCodec.self, XLSMCodec.self, ODSCodec.self, NumbersCodec.self])
///     let summary = try codecs.inspect(contentsOf: url)        // before reading: sheets, declared cells
///     let workbook = try codecs.read(contentsOf: url).workbook
///     let reader = try codecs.streamingReader(contentsOf: url)
///
/// A file whose format the set has no codec for is refused by name — the format, and the product to link — rather
/// than passed off as unrecognised (spec §6: nothing is silent). Detection lives in `SheetFormat` and knows every
/// format whether or not its codec is linked, which is what lets the refusal say what the file is. The rules that
/// sit in front of every codec live here too, once: an encrypted package or a legacy `.xls` is refused as what it
/// is (§1.3 / §14.11), a Numbers document saved as a folder is opened as one (§4.2), and the file name only breaks
/// ties for plain text.
///
/// The set is a value: build it once and keep it. Naming two codecs for one format keeps the last one named.
public struct CodecSet: Sendable {
    private let table: [SheetFormat: any SpreadsheetCodec.Type]
    /// The formats this set opens, in the order their codecs were named.
    public let formats: [SheetFormat]

    public init(_ codecs: [any SpreadsheetCodec.Type]) {
        var table: [SheetFormat: any SpreadsheetCodec.Type] = [:]
        var formats: [SheetFormat] = []
        for codec in codecs where table.updateValue(codec, forKey: codec.format) == nil { formats.append(codec.format) }
        self.table = table
        self.formats = formats
    }

    public func contains(_ format: SheetFormat) -> Bool { table[format] != nil }

    /// The codec for a format — or the refusal that names the format and the product that would open it.
    public func codec(for format: SheetFormat) throws -> any SpreadsheetCodec.Type {
        guard let codec = table[format] else {
            throw SheetError.unsupportedFeature("no codec for .\(format.rawValue) is in this CodecSet — link the \(format.productName) product, or the SwiftSheets product, which has every codec")
        }
        return codec
    }

    // MARK: - Reading

    /// Opens a file. The format is detected from its content; the extension only breaks ties for plain text. A
    /// Numbers document saved as a package is a folder on disk, not a file (spec §4.2). Anything the file held that
    /// the model cannot say is on the result's `warnings`, and on the workbook's `readWarnings`.
    public func read(contentsOf url: URL, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            return try codec(for: .numbers).read(contentsOf: url, options: opts)
        }
        // the file is mapped rather than copied when it is big enough to matter and stable enough to be safe
        return try read(try Data(contentsOf: url, options: .mappedIfSafe), format: nil, options: opts)
    }

    /// Parses bytes. `format` overrides detection.
    public func read(_ data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        // An encrypted package or a legacy .xls says so plainly rather than passing for noise (spec §1.3 / §14.11).
        // Ahead of detection, because the filename hint would otherwise offer "secret.csv" to the CSV reader.
        // Opening a protected package is the SheetDecrypt product's (Appendix B.39.9): nothing here decrypts.
        if let unopenable = UnopenableInput.probe(data) { throw unopenable.error }
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        return try codec(for: f).read(data, options: options)
    }

    // MARK: - Asking before reading

    /// What a file says about itself, before any cell of it is read: its sheets, how many cells each declares,
    /// what the package expands to, who wrote it (spec Appendix B.39.3). For a file you do not trust, this is how
    /// to choose a `ReadOptions.cellLimit` — or to decline. Reads the package directory and the head of each
    /// sheet part; with `InspectOptions.countCells`, walks each sheet's markup as bytes to count what is there.
    public func inspect(contentsOf url: URL, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            return try codec(for: .numbers).inspect(contentsOf: url, options: opts)
        }
        return try inspect(try Data(contentsOf: url, options: .mappedIfSafe), format: nil, options: opts)
    }

    /// `inspect` over bytes. `format` overrides detection.
    public func inspect(_ data: Data, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        if let unopenable = UnopenableInput.probe(data) { throw unopenable.error }
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        return try codec(for: f).inspect(data, options: options)
    }

    // MARK: - Writing

    /// Serializes in a format. The result carries every warning about what the format could not express.
    public func write(_ workbook: Workbook, as format: SheetFormat, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        let result = try codec(for: format).write(workbook, options: options)
        let extra = workbook.openDocumentOnlyWarnings(for: format)
        guard !extra.isEmpty else { return result }
        return WriteResult(data: result.data, warnings: result.warnings + extra, suggestion: result.suggestion)
    }

    /// Writes to a file. Without `format`, the extension decides (falling back to the source format, then .xlsx).
    ///
    /// The write is atomic: the bytes land in a temporary file that replaces the destination only once it is complete.
    /// Saving over the file you just opened is this library's whole reason for existing, so a crash (or a full disk)
    /// half-way through must leave the original where it was.
    @discardableResult
    public func write(_ workbook: Workbook, to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        let result = try write(workbook, as: workbook.outputFormat(for: url, requested: format), options: options)
        try result.data.write(to: url, options: .atomic)
        return result
    }

    /// Read → write in one step.
    ///
    /// The result carries **both** halves of the trip: what the source file held that the model cannot say, and
    /// what the model holds that the destination cannot say. Reading is as much a place to lose something as
    /// writing — a Numbers document's charts and cell controls are reported by the read and by nothing else — and
    /// this is the one call that never hands back the workbook, so a caller has nowhere else to find them
    /// (spec Appendix B.23). The read's warnings come first, in the order the trip made them.
    ///
    /// `suggestion` is unchanged: which format would have kept more is a question about the write.
    @discardableResult
    public func convert(_ source: URL, to format: SheetFormat, output: URL, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) throws -> WriteResult {
        let opened = try read(contentsOf: source, options: readOptions)
        let written = try write(opened.workbook, to: output, as: format, options: writeOptions)
        guard !opened.warnings.isEmpty else { return written }
        return WriteResult(data: written.data, warnings: opened.warnings + written.warnings, suggestion: written.suggestion)
    }

    // MARK: - Row by row

    /// A reader that walks a file of any format in the set one row at a time, without building the workbook (spec
    /// Appendix B.40). The file is read through positioned reads rather than mapped, so a workbook far larger than
    /// memory can be walked (Appendix B.39.8). `limits` is what the container may declare about itself before it is
    /// refused (`ReadOptions.limits`); `csv` is the dialect and encoding of a text file. A protected XLSX or ODS is
    /// refused by name — the SheetDecrypt product adds `StreamingReader(contentsOf:password:)`.
    public func streamingReader(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws -> StreamingReader {
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            return try codec(for: .numbers).streamingReader(contentsOf: url, limits: limits, csv: csv)
        }
        // the same answer `SheetFormat.probe(contentsOf:)` gives, with this reader's limits: the format, or the
        // name of what cannot be opened
        switch try SheetFormat.probe(source: try FileByteSource(url: url), filename: url.lastPathComponent, limits: limits) {
        case .unopenable(let unopenable): throw unopenable.error
        case .unrecognized: throw SheetError.unrecognizedFormat
        case .spreadsheet(let f): return try codec(for: f).streamingReader(contentsOf: url, limits: limits, csv: csv)
        }
    }

    /// The same reader over bytes. `format` overrides detection; `filename` only breaks ties for plain text (`.tsv`).
    public func streamingReader(data: Data, format: SheetFormat? = nil, limits: ZipLimits = ZipLimits(),
                                csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws -> StreamingReader {
        // An encrypted package or a legacy .xls says so plainly (spec Appendix B.39.9), a protected ODS or Numbers
        // document by name. The probe runs with this reader's limits, as it does for a file (Rev 4.31).
        let f: SheetFormat
        if let format {
            // a compound file is refused by name before the named reader sees a package that is not one
            if let unopenable = try UnopenableInput.probe(source: DataByteSource(data)) { throw unopenable.error }
            f = format
        } else {
            switch try SheetFormat.probe(source: DataByteSource(data), filename: filename, limits: limits) {
            case .unopenable(let unopenable): throw unopenable.error
            case .unrecognized: throw SheetError.unrecognizedFormat
            case .spreadsheet(let detected): f = detected
            }
        }
        return try codec(for: f).streamingReader(data: data, limits: limits, csv: csv, filename: filename)
    }

    /// A writer that appends rows to a new file, without ever building the workbook (spec Appendix B.42). The
    /// format comes from `format`, else from the path's extension, else XLSX — the rule `write(to:)` uses. `epoch`
    /// is the date origin for XLSX and Numbers; `csv` the dialect and encoding of a text file.
    public func streamingWriter(url: URL, format: SheetFormat? = nil, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900,
                                csv: CSVWriteOptions = CSVWriteOptions()) throws -> StreamingWriter {
        let f = format ?? SheetFormat(fileExtension: url.pathExtension) ?? .xlsx
        return try codec(for: f).streamingWriter(url: url, sheetName: sheetName, epoch: epoch, csv: csv)
    }
}

extension Workbook {
    /// The format a file write lands in: the argument, else the extension, else the source format, else .xlsx.
    /// One rule for the plain write and for SheetEncrypt's protected one.
    package func outputFormat(for url: URL, requested format: SheetFormat?) -> SheetFormat {
        format ?? SheetFormat(fileExtension: url.pathExtension) ?? sourceInfo?.format ?? .xlsx
    }

    /// What only OpenDocument can hold (spec Appendix B.17) and this format therefore drops.
    ///
    /// The warning is raised by `CodecSet.write` rather than inside each codec, so that the ODF-only model can grow
    /// without touching a codec that predates it — `SheetXLSX` in particular is frozen. The cost of that choice is
    /// that calling `XLSXCodec.write` directly does not raise it; going through a set (or the umbrella's
    /// `Workbook.write` / `data(as:)`) does.
    package func openDocumentOnlyWarnings(for format: SheetFormat) -> [ConversionWarning] {
        guard format != .ods else { return [] }
        var out: [ConversionWarning] = []
        func drop(_ what: String) {
            out.append(ConversionWarning(.dropped, subject: .other,
                                         message: "\(what) is dropped: only OpenDocument has it"))
        }
        // Not "these settings differ from ours" but "the destination will read this document differently" — the
        // question a warning is worth. LibreOffice writes its own defaults into every ODS, so the older test
        // reported a loss on every ODS conversion ever made (spec Appendix B.23).
        var settings = calculationSettings
        if format == .xlsx || format == .xlsm {
            // <calcPr> has the iteration and full-precision settings (spec Appendix B.40.4): not a loss there
            let outside = CalculationSettings.asAssumedOutsideODF
            settings.iterationEnabled = outside.iterationEnabled
            settings.iterationSteps = outside.iterationSteps
            settings.iterationMaximumDifference = outside.iterationMaximumDifference
            settings.precisionAsShown = outside.precisionAsShown
        }
        for difference in settings.differences(from: .asAssumedOutsideODF) {
            out.append(ConversionWarning(.dropped, subject: .other,
                                         message: "a calculation setting is dropped — \(difference); only OpenDocument keeps it in the file"))
        }
        if !labelRanges.isEmpty { drop("\(labelRanges.count) label range(s) — headings usable in formulas") }
        if consolidation != nil { drop("the stored consolidation definition") }
        let arrows = sheets.reduce(0) { $0 + $1.tables.reduce(0) { $0 + $1.detective.count } }
        if arrows > 0 { drop("\(arrows) cell(s) with tracing arrows") }
        return out
    }
}
