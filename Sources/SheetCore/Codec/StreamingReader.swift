import Foundation

/// Reads a spreadsheet of any format one row at a time, without ever building the workbook (openpyxl's
/// `read_only=True`; spec Appendix B.40). The rows come back in one shape whatever the file was: an XLSX `<row>`,
/// an ODS `<table:table-row>`, a row of a Numbers tile, a record of a text file.
///
/// A `CodecSet` makes one for a file whose format it holds — `codecs.streamingReader(contentsOf:)` — detecting the
/// format from the bytes as `read` does and handing the file to the reader that walks it: `XLSXStreamingReader`,
/// `ODSStreamingReader`, `NumbersStreamingReader` or `CSVStreamingReader`. The `SwiftSheets` product adds
/// `StreamingReader(contentsOf:)` and `StreamingReader(data:)`, which are the same over `CodecSet.all`.
///
///     let reader = try StreamingReader(contentsOf: url)          // import SwiftSheets
///     var total = 0
///     try reader.forEachRow(inSheet: reader.sheetNames[0], valuesOnly: 3) { values in
///         if case .integer(let qty)? = values[2] { total += qty }
///     }
///     for try await row in reader.rows(inSheet: "売上") { … }
///
/// **What it costs.** The file is read through positioned reads, not mapped. An XLSX sheet part and an ODS body are
/// expanded a piece at a time; a Numbers table is read one tile of rows at a time from a document indexed but not
/// decoded; what every reader has to hold whole is the file's string table (XLSX shared strings, a Numbers table's
/// string list) and the row in your hands. `ReadOptions.cellLimit` does not apply — nothing accumulates for it to
/// bound.
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

    /// Wraps a format's own reader. Only a codec makes one: the readers' shared contract stays inside the package,
    /// so the set of formats that walk this way is the set of codecs the library ships (spec Appendix B.44).
    package init(source: any StreamingRowSource, format: SheetFormat) { self.source = source; self.format = format }

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
