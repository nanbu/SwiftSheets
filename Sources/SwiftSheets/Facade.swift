import Foundation
@_exported import SheetCore
@_exported import SheetXLSX
@_exported import SheetCSV
@_exported import SheetODS
@_exported import SheetNumbers

/// The facade (spec §4.3 / §14.2): detect the format from the bytes, hand off to the codec; write by explicit
/// format or by file extension. Reading one format and writing another *is* the conversion — the model mediates.
extension Workbook {
    /// Opens a file. The format is detected from its content; the extension only breaks ties for plain text.
    /// Anything the file held that the model cannot say is on `readWarnings` (and on `ReadResult` from `read`).
    public init(contentsOf url: URL, options: ReadOptions = ReadOptions()) throws {
        self = try Workbook.read(contentsOf: url, options: options).workbook
    }

    /// Parses bytes. `format` overrides detection.
    public init(data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws {
        self = try Workbook.read(data, format: format, options: options).workbook
    }

    /// Opens a file and hands back the workbook together with what reading it could not carry over.
    public static func read(contentsOf url: URL, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        // a Numbers document saved as a package is a folder on disk, not a file (spec §4.2)
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            return try NumbersCodec.read(folder: url, options: opts)
        }
        // the file is mapped rather than copied when it is big enough to matter and stable enough to be safe
        return try read(try Data(contentsOf: url, options: .mappedIfSafe), format: nil, options: opts)
    }

    /// Parses bytes and hands back the workbook together with what reading them could not carry over.
    public static func read(_ data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        // An encrypted package or a legacy .xls says so plainly rather than passing for noise (spec §1.3 / §14.11).
        // Ahead of detection, because the filename hint would otherwise offer "secret.csv" to the CSV reader.
        // A protected Office package with a password is decrypted here and read as the plain package it holds.
        if let unopenable = UnopenableInput.probe(data) {
            guard unopenable == .encryptedOOXML, let password = options.password else { throw unopenable.error }
            var plainOptions = options
            plainOptions.password = nil
            return try read(try OOXMLEncryption.decrypt(data, password: password), format: format, options: plainOptions)
        }
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        switch f {
        case .xlsx: return try XLSXCodec.read(data, options: options)
        case .xlsm: return try XLSMCodec.read(data, options: options)
        case .csv: return try CSVCodec.read(data, options: options)
        case .ods: return try ODSCodec.read(data, options: options)
        case .numbers: return try NumbersCodec.read(data, options: options)
        }
    }

    /// What a file says about itself, before any cell of it is read: its sheets, how many cells each declares,
    /// what the package expands to, who wrote it (spec Appendix B.39.3). For a file you do not trust, this is how
    /// to choose a `ReadOptions.cellLimit` — or to decline. Reads the package directory and the head of each
    /// sheet part; with `InspectOptions.countCells`, walks each sheet's markup as bytes to count what is there.
    public static func inspect(contentsOf url: URL, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            return try NumbersInspector.inspect(folder: url, options: opts)
        }
        return try inspect(try Data(contentsOf: url, options: .mappedIfSafe), format: nil, options: opts)
    }

    public static func inspect(_ data: Data, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        if let unopenable = UnopenableInput.probe(data) {
            guard unopenable == .encryptedOOXML, let password = options.password else { throw unopenable.error }
            var plainOptions = options
            plainOptions.password = nil
            return try inspect(try OOXMLEncryption.decrypt(data, password: password), format: format, options: plainOptions)
        }
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        switch f {
        case .xlsx, .xlsm:
            return try XLSXInspector.inspect(try ZipArchive(data: data, limits: options.limits), format: f, options: options)
        case .ods:
            return try ODSInspector.inspect(try ZipArchive(data: data, limits: options.limits), options: options)
        case .numbers:
            return try NumbersInspector.inspect(data, options: options)
        case .csv:
            var sheet = SheetSummary(name: "Sheet1")
            var lines = 0
            var lastWasNewline = true
            data.withUnsafeBytes { raw in
                for b in raw { if b == 0x0A { lines += 1; lastWasNewline = true } else { lastWasNewline = false } }
            }
            if !lastWasNewline { lines += 1 }
            sheet.rowCount = lines
            return WorkbookSummary(format: .csv, sheets: [sheet], producer: nil, expandedBytes: data.count, partCount: 1)
        }
    }

    /// Serializes in a format. The result carries every warning about what the format could not express.
    public func write(as format: SheetFormat, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        var result: WriteResult
        switch format {
        case .xlsx: result = try XLSXCodec.write(self, options: options)
        case .xlsm: result = try XLSMCodec.write(self, options: options)
        case .csv: result = try CSVCodec.write(self, options: options)
        case .ods: result = try ODSCodec.write(self, options: options)
        case .numbers: result = try NumbersCodec.write(self, options: options)
        }
        if let password = options.password {
            // the package is complete; now it is wrapped the way the format protects it (spec Appendix B.39.9)
            let protected: Data
            switch format {
            case .xlsx, .xlsm: protected = try OOXMLEncryption.encrypt(result.data, password: password)
            case .ods: protected = try ODSEncryption.encrypt(result.data, password: password)
            case .csv: throw SheetError.unsupportedFeature("a CSV file cannot be password-protected: it is plain text by definition")
            case .numbers: throw SheetError.unsupportedFeature("a password-protected Numbers document cannot be written: Numbers' encryption is not documented")
            }
            result = WriteResult(data: protected, warnings: result.warnings, suggestion: result.suggestion)
        }
        let extra = format == .ods ? [] : openDocumentOnlyWarnings(for: format)
        guard !extra.isEmpty else { return result }
        return WriteResult(data: result.data, warnings: result.warnings + extra, suggestion: result.suggestion)
    }

    /// What only OpenDocument can hold (spec Appendix B.17) and this format therefore drops.
    ///
    /// The warning is raised **here** rather than inside each codec, so that the ODF-only model can grow without
    /// touching a codec that predates it — `SheetXLSX` in particular is frozen. The cost of that choice is that
    /// calling `XLSXCodec.write` directly does not raise it; going through `Workbook.write` / `data(as:)` does.
    func openDocumentOnlyWarnings(for format: SheetFormat) -> [ConversionWarning] {
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

    /// The bytes only, when warnings are not of interest.
    public func data(as format: SheetFormat, options: WriteOptions = WriteOptions()) throws -> Data {
        try write(as: format, options: options).data
    }

    /// Writes to a file. Without `format`, the extension decides (falling back to the source format, then .xlsx).
    ///
    /// The write is atomic: the bytes land in a temporary file that replaces the destination only once it is complete.
    /// Saving over the file you just opened is this library's whole reason for existing, so a crash (or a full disk)
    /// half-way through must leave the original where it was.
    @discardableResult
    public func write(to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        let f = format ?? SheetFormat(fileExtension: url.pathExtension) ?? sourceInfo?.format ?? .xlsx
        let result = try write(as: f, options: options)
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
    public static func convert(_ source: URL, to format: SheetFormat, output: URL, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) throws -> WriteResult {
        let opened = try Workbook.read(contentsOf: source, options: readOptions)
        let written = try opened.workbook.write(to: output, as: format, options: writeOptions)
        guard !opened.warnings.isEmpty else { return written }
        return WriteResult(data: written.data, warnings: opened.warnings + written.warnings,
                           suggestion: written.suggestion)
    }
}
