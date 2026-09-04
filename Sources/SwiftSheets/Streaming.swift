import Foundation
import SheetCore
import SheetXLSX
import SheetCSV
import SheetODS
import SheetNumbers

/// Reads a spreadsheet of any format one row at a time, without ever building the workbook (openpyxl's
/// `read_only=True`; spec Appendix B.40). The format is detected from the bytes, as `Workbook(contentsOf:)` does,
/// and the file is handed to the reader that walks it: `XLSXStreamingReader`, `ODSStreamingReader`,
/// `NumbersStreamingReader` or `CSVStreamingReader`. The rows come back in one shape whatever the file was.
///
///     let reader = try StreamingReader(contentsOf: url)
///     var total = 0
///     try reader.forEachRow(inSheet: reader.sheetNames[0], valuesOnly: 3) { values in
///         if case .integer(let qty)? = values[2] { total += qty }
///     }
///     for try await row in reader.rows(inSheet: "売上") { … }
///
/// **What it costs.** The file is mapped, not read. An XLSX sheet part and an ODS body are expanded a piece at a
/// time; a Numbers table is read one tile of rows at a time from a document indexed but not decoded; what every
/// reader has to hold whole is the file's string table (XLSX shared strings, a Numbers table's string list) and the
/// row in your hands. `ReadOptions.cellLimit` does not apply — nothing accumulates for it to bound.
///
/// **What it does not do.** Values and (on request) formatting: no merges, no notes, no charts, nothing preserved.
/// Nothing is written back — for that, read the workbook the ordinary way. A Numbers sheet may hold several
/// tables: `forEachRow(inSheet:)` walks the first, as `Sheet.table` is the first, and `table:` reaches the others.
public struct StreamingReader {
    private let source: any StreamingRowSource
    /// The format the file turned out to be.
    public let format: SheetFormat
    /// The sheets of the file, in the file's order (one, "Sheet1", for delimited text).
    public var sheetNames: [String] { source.sheetNames }

    /// Maps the file rather than reading it, so a workbook far larger than memory can be walked. A Numbers document
    /// saved as a folder is opened as one. `limits` is what the container may declare about itself before it is
    /// refused (`ReadOptions.limits`); `password` opens a protected XLSX or ODS (the package is decrypted whole
    /// first — a protected package cannot be walked a row at a time); `csv` is the dialect and encoding of a text
    /// file.
    public init(contentsOf url: URL, limits: ZipLimits = ZipLimits(), password: String? = nil, csv: CSVReadOptions = CSVReadOptions()) throws {
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            self.init(source: try NumbersStreamingReader(folder: url, limits: limits), format: .numbers)
            return
        }
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe), format: nil, limits: limits, password: password,
                      csv: csv, filename: url.lastPathComponent)
    }

    private init(source: any StreamingRowSource, format: SheetFormat) { self.source = source; self.format = format }

    /// Reads from bytes. `format` overrides detection; `filename` only breaks ties for plain text (`.tsv`).
    public init(data: Data, format: SheetFormat? = nil, limits: ZipLimits = ZipLimits(), password: String? = nil,
                csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws {
        var data = data
        // An encrypted package or a legacy .xls says so plainly (spec Appendix B.39.9). A protected Office package
        // with a password is decrypted here and walked as the plain package it holds; a protected ODS is decrypted
        // by its own reader (its manifest says which entries are), a protected Numbers document is refused by name.
        if let unopenable = UnopenableInput.probe(data) {
            guard unopenable == .encryptedOOXML, let password else { throw unopenable.error }
            data = try OOXMLEncryption.decrypt(data, password: password)
        }
        guard let f = format ?? SheetFormat.detect(from: data, filename: filename) else { throw SheetError.unrecognizedFormat }
        self.format = f
        switch f {
        case .xlsx, .xlsm: source = try XLSXStreamingReader(data: data, limits: limits, password: password)
        case .ods: source = try ODSStreamingReader(data: data, limits: limits, password: password)
        case .numbers: source = try NumbersStreamingReader(data: data, limits: limits)
        case .csv: source = CSVStreamingReader(data: data, options: csv, filename: filename)
        }
    }

    /// How many tables the sheet holds: one for an XLSX, ODS or CSV sheet; one or more for a Numbers sheet, whose
    /// canvas may carry several. The same count `Workbook.inspect` reports as `SheetSummary.tableCount`.
    public func tableCount(inSheet name: String) throws -> Int { try source.tableCount(inSheet: name) }

    /// Visits every row of a sheet in order. Throwing from `body` stops the walk and rethrows. `table` picks a
    /// table on a Numbers sheet (0 is the first, the one `Sheet.table` is); for any other format only 0 exists,
    /// and another number is an error rather than an empty walk.
    public func forEachRow(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: (StreamedRow) throws -> Void) throws {
        try source.forEachRow(inSheet: name, table: table, options: options, body)
    }

    /// The rows of a sheet as a sequence to iterate — `for try await row in reader.rows(inSheet: "売上")` — pulled
    /// from the file as the loop asks for them, so a walk that stops early reads no further. The sequence is
    /// asynchronous only because that is the shape Swift gives a sequence that can throw; nothing runs concurrently.
    public func rows(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions()) -> AsyncThrowingStream<StreamedRow, Error> {
        StreamingRowSequence.make { try source.rowWalk(inSheet: name, table: table, options: options) }
    }

    /// The same walk, as dense value arrays (openpyxl's `values_only=True`). `width` pads every row to that many
    /// columns so the rows line up.
    public func forEachRow(inSheet name: String, table: Int = 0, valuesOnly width: Int?,
                           options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: ([CellValue?]) throws -> Void) throws {
        try forEachRow(inSheet: name, table: table, options: options) { try body($0.values(width: width)) }
    }
}
