import Foundation
import SheetCore

/// ECMA-376 SpreadsheetML (.xlsx). Reads with full preservation of uninterpreted parts; writes the package the way
/// Excel expects it (schema element order, the two mandatory fills, `calcChain` dropped so Excel recalculates).
public enum XLSXCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .xlsx }

    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }

    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        ReadResult(workbook: try WorkbookReader.read(data, options: options))
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try WorkbookWriter.write(workbook, format: .xlsx, options: options)
    }
}

/// Macro-enabled workbooks (.xlsm): the same package with a different workbook content type. The VBA project is
/// carried as an opaque part — never interpreted, never executed — and dropped (with a warning) when writing .xlsx.
public enum XLSMCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .xlsm }

    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }

    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        ReadResult(workbook: try WorkbookReader.read(data, options: options))
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try WorkbookWriter.write(workbook, format: .xlsm, options: options)
    }
}
