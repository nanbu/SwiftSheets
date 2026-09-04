import Foundation
import SheetCore
import SheetXLSX
import SheetCSV
import SheetODS
import SheetNumbers

/// Writes a spreadsheet of any format one row at a time, without ever building the workbook (openpyxl's
/// `write_only=True`; spec Appendix B.42). The format comes from the path's extension, as `Workbook.write(to:)`
/// decides it, or from `format:`; the rows go to the writer that knows the format — `XLSXStreamingWriter`,
/// `ODSStreamingWriter`, `NumbersStreamingWriter` or `CSVStreamingWriter` — and are appended the same way
/// whichever it is.
///
///     let writer = try StreamingWriter(url: url, sheetName: "売上")
///     try writer.append([.text("品目"), .text("数量")])
///     for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
///     try writer.close()
///     print(writer.warnings)
///
/// **What it costs.** One row, the styles the rows have worn so far, and what the format has to hold until the end:
/// XLSX nothing (the sheet is compressed as it goes), ODS the rows themselves on disk until `close()` (its one part
/// puts the styles before the tables), Numbers its string list and a tile of 256 rows. The performance record has
/// the measured peaks.
///
/// **What it does not do.** Values and formatting, one grid per sheet: no merges, no notes, no charts, nothing
/// preserved. A row written cannot be gone back to. Delimited text holds one sheet, so `addSheet` is refused
/// there. `close()` must be called, or the file is left unfinished.
public final class StreamingWriter {
    private let sink: any StreamingRowSink
    /// The format being written.
    public let format: SheetFormat

    /// Starts a file whose first sheet is `sheetName`. `format` overrides the extension; a path with neither is
    /// written as XLSX. `epoch` is the date origin for XLSX and Numbers; `csv` the dialect and encoding of a text
    /// file.
    public init(url: URL, format: SheetFormat? = nil, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900,
                csv: CSVWriteOptions = CSVWriteOptions()) throws {
        let f = format ?? SheetFormat(fileExtension: url.pathExtension) ?? .xlsx
        self.format = f
        switch f {
        case .xlsx: sink = try XLSXStreamingWriter(url: url, sheetName: sheetName, epoch: epoch)
        case .xlsm: sink = try XLSXStreamingWriter(url: url, sheetName: sheetName, epoch: epoch, macroEnabled: true)
        case .ods: sink = try ODSStreamingWriter(url: url, sheetName: sheetName)
        case .numbers: sink = try NumbersStreamingWriter(url: url, sheetName: sheetName, epoch: epoch)
        case .csv: sink = try CSVStreamingWriter(url: url, options: csv)
        }
    }

    /// Finishes the sheet being written and starts another. Delimited text holds one sheet and refuses a second.
    public func addSheet(named name: String) throws { try sink.addSheet(named: name) }
    /// Appends a row of values, at whatever row comes next. `nil` is an empty cell.
    public func append(_ values: [CellValue?]) throws { try sink.append(values) }
    /// Appends a row of cells, formatting and all.
    public func append(_ cells: [Cell]) throws { try sink.append(cells) }
    /// Writes what is pending and completes the file. Calling it twice is harmless.
    public func close() throws { try sink.close() }
    /// What the format could not carry as asked — final once `close()` has run. Never silent (spec §6).
    public var warnings: [ConversionWarning] { sink.warnings }
}
