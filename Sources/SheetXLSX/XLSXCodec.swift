import Foundation
import SheetCore

/// ECMA-376 SpreadsheetML (.xlsx). Reads with full preservation of uninterpreted parts; writes the package the way
/// Excel expects it (schema element order, the two mandatory fills, `calcChain` dropped so Excel recalculates).
public enum XLSXCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .xlsx }

    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }

    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let r = try WorkbookReader.read(data, options: options)
        return ReadResult(workbook: r.workbook, warnings: r.warnings)
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try WorkbookWriter.write(workbook, format: .xlsx, options: options)
    }

    /// The workbook part names the sheets, each sheet part declares its used range at the top, the ZIP directory
    /// says what everything expands to (spec Appendix B.39.3). Nothing past the first piece of a sheet part is read
    /// unless `InspectOptions.countCells` asks for a count.
    public static func inspect(_ data: Data, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try XLSXInspector.inspect(try ZipArchive(data: data, limits: options.limits), format: .xlsx, options: options)
    }

    public static func streamingReader(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws -> StreamingReader {
        StreamingReader(source: try XLSXStreamingReader(contentsOf: url, limits: limits), format: .xlsx)
    }

    public static func streamingReader(data: Data, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws -> StreamingReader {
        StreamingReader(source: try XLSXStreamingReader(data: data, limits: limits), format: .xlsx)
    }

    public static func streamingWriter(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900, csv: CSVWriteOptions = CSVWriteOptions()) throws -> StreamingWriter {
        StreamingWriter(sink: try XLSXStreamingWriter(url: url, sheetName: sheetName, epoch: epoch), format: .xlsx)
    }
}

/// Macro-enabled workbooks (.xlsm): the same package with a different workbook content type. The VBA project is
/// carried as an opaque part — never interpreted, never executed — and dropped (with a warning) when writing .xlsx.
public enum XLSMCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .xlsm }

    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }

    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let r = try WorkbookReader.read(data, options: options)
        return ReadResult(workbook: r.workbook, warnings: r.warnings)
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try WorkbookWriter.write(workbook, format: .xlsm, options: options)
    }

    public static func inspect(_ data: Data, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try XLSXInspector.inspect(try ZipArchive(data: data, limits: options.limits), format: .xlsm, options: options)
    }

    public static func streamingReader(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws -> StreamingReader {
        StreamingReader(source: try XLSXStreamingReader(contentsOf: url, limits: limits), format: .xlsm)
    }

    public static func streamingReader(data: Data, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws -> StreamingReader {
        StreamingReader(source: try XLSXStreamingReader(data: data, limits: limits), format: .xlsm)
    }

    public static func streamingWriter(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900, csv: CSVWriteOptions = CSVWriteOptions()) throws -> StreamingWriter {
        StreamingWriter(sink: try XLSXStreamingWriter(url: url, sheetName: sheetName, epoch: epoch, macroEnabled: true), format: .xlsm)
    }
}
