import Foundation
import SheetCore

/// Apple Numbers (.numbers). Placeholder — being implemented (spec chapters 10 / 11).
package enum NumbersCodec: SpreadsheetCodec {
    package static var format: SheetFormat { .numbers }
    package static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }
    /// The empty document every written file starts from (numbers-parser's template — see NOTICE).
    package static var templateURL: URL { NumbersResources.url("empty", "numbers")! }
    /// Reading is tolerant (spec §10.3): whatever could not be interpreted is reported in the result rather than thrown.
    package static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let doc = try NumbersDocument(data: data, limits: options.limits)
        var reader = NumbersReader(doc: doc, options: options)
        let wb = try reader.workbook()
        return ReadResult(workbook: wb, warnings: reader.warnings)
    }
    /// A document saved as a folder (a package on disk) rather than a single file.
    package static func read(folder url: URL, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let doc = try NumbersDocument(folder: url, limits: options.limits)
        var reader = NumbersReader(doc: doc, options: options)
        let wb = try reader.workbook()
        return ReadResult(workbook: wb, warnings: reader.warnings)
    }

    package static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        var writer = try NumbersWriter(workbook: workbook.resolvingColors(), options: options)   // B.71
        let data = try writer.write()
        return WriteResult(data: data, warnings: writer.warnings, suggestion: WriteResult.suggest(from: writer.warnings, target: .numbers, options: options))
    }
}

// MARK: - The rest of the codec contract (spec Appendix B.44)

extension NumbersCodec {
    /// A document saved as a folder (a package on disk) is opened as one; a file is mapped and read. This is the
    /// override the contract's default `read(contentsOf:)` exists for.
    package static func read(contentsOf url: URL, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        if url.isDirectoryOnDisk { return try read(folder: url, options: options) }
        return try read(try Data(contentsOf: url, options: .mappedIfSafe), options: options)
    }

    /// Every table model names its own row and column counts, so a sheet's size is read from the object graph
    /// without touching the cell tiles (spec Appendix B.39.3).
    package static func inspect(_ data: Data, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try NumbersInspector.inspect(data, options: options)
    }

    /// `inspect` over a file or a folder on disk.
    package static func inspect(contentsOf url: URL, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        if url.isDirectoryOnDisk { return try NumbersInspector.inspect(folder: url, options: options) }
        return try inspect(try Data(contentsOf: url, options: .mappedIfSafe), options: options)
    }

    /// The reader opens a file through positioned reads, and a folder as a folder.
    package static func streamingReader(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws -> StreamingReader {
        StreamingReader(source: try NumbersStreamingReader(contentsOf: url, limits: limits), format: .numbers)
    }

    package static func streamingReader(_ data: Data, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws -> StreamingReader {
        StreamingReader(source: try NumbersStreamingReader(data: data, limits: limits), format: .numbers)
    }

    package static func streamingSink(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900, csv: CSVWriteOptions = CSVWriteOptions()) throws -> any StreamingRowSink {
        try NumbersStreamingWriter(url: url, sheetName: sheetName, epoch: epoch)
    }
}
