import Foundation
@_exported import SheetCore
@_exported import SheetXLSX
@_exported import SheetCSV
@_exported import SheetODS
@_exported import SheetNumbers

extension CodecSet {
    /// Every codec the library ships. The conveniences of this product — `Workbook(contentsOf:)`, `Workbook.inspect`,
    /// `write(to:as:)`, `Workbook.convert`, `StreamingReader(contentsOf:)`, `StreamingWriter(to:)` — are this set's
    /// methods under their older names (spec §4.3, Appendix B.44). An application that links fewer products makes
    /// its own `CodecSet` and has the same facade.
    public static let all = CodecSet([.xlsx, .xlsm, .csv, .ods, .numbers])
}

/// The facade (spec §4.3 / §14.2): detect the format from the bytes, hand off to the codec; write by explicit
/// format or by file extension. Reading one format and writing another *is* the conversion — the model mediates.
/// Every method here is `CodecSet.all`'s; the set holds the rules, this product only names them.
extension Workbook {
    /// Opens a file. The format is detected from its content; the extension only breaks ties for plain text.
    /// `format` skips detection, as it does over bytes. Anything the file held that the model cannot say is on
    /// `readWarnings` (and on `ReadResult` from `read`).
    public init(contentsOf url: URL, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws {
        self = try CodecSet.all.read(contentsOf: url, format: format, options: options).workbook
    }

    /// Parses bytes. `format` overrides detection.
    public init(data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws {
        self = try CodecSet.all.read(data, format: format, options: options).workbook
    }

    /// Opens a file and hands back the workbook together with what reading it could not carry over. `format` skips
    /// detection, as it does over bytes.
    public static func read(contentsOf url: URL, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        try CodecSet.all.read(contentsOf: url, format: format, options: options)
    }

    /// Parses bytes and hands back the workbook together with what reading them could not carry over.
    public static func read(_ data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        try CodecSet.all.read(data, format: format, options: options)
    }

    /// What a file says about itself, before any cell of it is read: its sheets, how many cells each declares,
    /// what the package expands to, who wrote it (spec Appendix B.39.3). For a file you do not trust, this is how
    /// to choose a `ReadOptions.cellLimit` — or to decline. Reads the package directory and the head of each
    /// sheet part; with `InspectOptions.countsCells`, walks each sheet's markup as bytes to count what is there.
    /// `format` skips detection, as it does over bytes.
    public static func inspect(contentsOf url: URL, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try CodecSet.all.inspect(contentsOf: url, format: format, options: options)
    }

    public static func inspect(_ data: Data, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try CodecSet.all.inspect(data, format: format, options: options)
    }

    /// Serializes in a format. The result carries every warning about what the format could not express.
    public func write(as format: SheetFormat, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try CodecSet.all.write(self, as: format, options: options)
    }

    /// Writes to a file. Without `format`, the extension decides (falling back to the source format, then .xlsx).
    ///
    /// The write is atomic: the bytes land in a temporary file that replaces the destination only once it is complete.
    /// Saving over the file you just opened is this library's whole reason for existing, so a crash (or a full disk)
    /// half-way through must leave the original where it was.
    /// Inspect the returned warnings, or explicitly discard the result with `_ =` (spec Appendix B.47).
    public func write(to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try CodecSet.all.write(self, to: url, as: format, options: options)
    }

    /// Read → write in one step. The result carries **both** halves of the trip — what the source held that the
    /// model cannot say, and what the model holds that the destination cannot say (spec Appendix B.23); the read's
    /// warnings come first. `suggestion` is the write's.
    /// Inspect the returned warnings, or explicitly discard the result with `_ =` (spec Appendix B.47).
    public static func convert(_ source: URL, to output: URL, as format: SheetFormat, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) throws -> WriteResult {
        try CodecSet.all.convert(source, to: output, as: format, readOptions: readOptions, writeOptions: writeOptions)
    }
}

/// The same facade for async code — `CodecSet.all`'s async methods (spec Appendix B.108). In an async function these
/// are the ones a call picks, so the call needs `await`; each runs the synchronous engine away from the caller's actor
/// and stops with `CancellationError` once its task is cancelled. The initializers stay synchronous: in async code,
/// `try await Workbook.read(contentsOf:)` is the way to open a file without holding the actor.
extension Workbook {
    /// `read(contentsOf:format:options:)`, away from the caller's actor and stopped by cancelling its task.
    @concurrent public static func read(contentsOf url: URL, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) async throws -> ReadResult {
        try await CodecSet.all.read(contentsOf: url, format: format, options: options)
    }

    /// `read(_:format:options:)`, away from the caller's actor and stopped by cancelling its task.
    @concurrent public static func read(_ data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) async throws -> ReadResult {
        try await CodecSet.all.read(data, format: format, options: options)
    }

    /// `inspect(contentsOf:format:options:)`, away from the caller's actor and stopped by cancelling its task.
    @concurrent public static func inspect(contentsOf url: URL, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) async throws -> WorkbookSummary {
        try await CodecSet.all.inspect(contentsOf: url, format: format, options: options)
    }

    /// `inspect(_:format:options:)`, away from the caller's actor and stopped by cancelling its task.
    @concurrent public static func inspect(_ data: Data, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) async throws -> WorkbookSummary {
        try await CodecSet.all.inspect(data, format: format, options: options)
    }

    /// `write(as:options:)`, away from the caller's actor and stopped by cancelling its task.
    @concurrent public func write(as format: SheetFormat, options: WriteOptions = WriteOptions()) async throws -> WriteResult {
        try await CodecSet.all.write(self, as: format, options: options)
    }

    /// `write(to:as:options:)`, away from the caller's actor. Cancelling its task before the file is replaced leaves
    /// whatever was at `url` untouched; once replaced, the save is reported.
    /// Inspect the returned warnings, or explicitly discard the result with `_ =` (spec Appendix B.47).
    @concurrent public func write(to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions()) async throws -> WriteResult {
        try await CodecSet.all.write(self, to: url, as: format, options: options)
    }

    /// `convert(_:to:as:readOptions:writeOptions:)`, away from the caller's actor and stopped by cancelling its task
    /// as `write(to:as:options:)` is. Inspect the returned warnings, or explicitly discard the result with `_ =`.
    @concurrent public static func convert(_ source: URL, to output: URL, as format: SheetFormat, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) async throws -> WriteResult {
        try await CodecSet.all.convert(source, to: output, as: format, readOptions: readOptions, writeOptions: writeOptions)
    }
}
