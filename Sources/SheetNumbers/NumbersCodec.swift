import Foundation
import SheetCore

/// Apple Numbers (.numbers). Placeholder — being implemented (spec chapters 10 / 11).
public enum NumbersCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .numbers }
    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }
    /// The empty document every written file starts from (numbers-parser's template — see NOTICE).
    public static var templateURL: URL { Bundle.module.url(forResource: "empty", withExtension: "numbers")! }
    /// Reading is tolerant (spec §10.3): whatever could not be interpreted is reported in the result rather than thrown.
    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let doc = try NumbersDocument(data: data, limits: options.limits)
        var reader = NumbersReader(doc: doc, options: options)
        let wb = try reader.workbook()
        return ReadResult(workbook: wb, warnings: reader.warnings)
    }
    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        var writer = try NumbersWriter(workbook: workbook, options: options)
        let data = try writer.write()
        return WriteResult(data: data, warnings: writer.warnings, suggestion: WriteResult.suggest(from: writer.warnings, target: .numbers, options: options))
    }
}
