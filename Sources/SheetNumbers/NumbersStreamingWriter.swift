import Foundation
import SheetCore

/// Writes a Numbers document one row at a time, without ever building it (spec Appendix B.42).
///
/// A Numbers table keeps its cells in tiles of 256 rows, each a part of its own in the package — so a tile is
/// packed and written into the file the moment it fills, and let go. What has to wait for the end is small: the
/// table model, the string list (one entry per distinct text — the same thing an XLSX reader's shared-string
/// table is), the style list and a column count per column. Memory stays a few megabytes plus that list.
///
///     let writer = try NumbersStreamingWriter(url: url, sheetName: "売上")
///     try writer.append([.text("品目"), .text("数量")])
///     for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
///     try writer.close()
///
/// **What it does not do.** Values and cell formatting, one table per sheet: a formula is written as its cached
/// value, rich text as plain text, and links, notes and cell controls are dropped — each reported in
/// `warnings`, never silently. A tile's rows are written at one width, so the table is as wide as its widest row
/// and a row wider than the tiles already written is refused: give the first row every column the table will
/// need. `close()` must be called, or the file is left unfinished.
public final class NumbersStreamingWriter: StreamingRowSink {
    private var writer: NumbersWriter
    private let zip: ZipFileWriter
    private var sheetIDs: [Int] = []
    private var table: NumbersWriter.StreamedTable
    private var closed = false
    /// What the rows carried that the format, or this writer, could not: final once `close()` has run.
    public private(set) var warnings: [ConversionWarning] = []

    /// Starts a document whose first sheet is `sheetName`. `epoch` is the date origin the calculation engine
    /// records.
    public init(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900) throws {
        zip = try ZipFileWriter(url: url)
        var w = try NumbersWriter(workbook: Workbook(), options: WriteOptions())
        w.streamEpoch(epoch)
        let first = w.streamTemplateSheet
        table = try w.streamBegin(sheet: first, name: sheetName)
        sheetIDs = [first]
        writer = w
    }

    /// Finishes the sheet being written and starts another.
    public func addSheet(named name: String) throws {
        precondition(!closed, "the writer is closed")
        try writer.streamFinish(&table) { try self.zip.add($0, $1, stored: true) }
        let sid = try writer.streamCloneSheet()
        sheetIDs.append(sid)
        table = try writer.streamBegin(sheet: sid, name: name)
    }

    /// Appends a row of cells, formatting and all, at whatever row comes next.
    public func append(_ cells: [Cell]) throws {
        precondition(!closed, "the writer is closed")
        try writer.streamAppend(cells, to: &table) { try self.zip.add($0, $1, stored: true) }
    }

    /// Packs the last tile, writes the rest of the document and closes the file. Calling it twice is harmless.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try writer.streamFinish(&table) { try self.zip.add($0, $1, stored: true) }
        try writer.streamFinishDocument(sheets: sheetIDs)
        try writer.doc.encoded(into: zip)
        try zip.finish()
        warnings = writer.warnings
    }

    deinit { if !closed { zip.abandon() } }
}
