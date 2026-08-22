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
        // the file is mapped rather than copied when it is big enough to matter and stable enough to be safe
        return try read(try Data(contentsOf: url, options: .mappedIfSafe), format: nil, options: opts)
    }

    /// Parses bytes and hands back the workbook together with what reading them could not carry over.
    public static func read(_ data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        switch f {
        case .xlsx: return try XLSXCodec.read(data, options: options)
        case .xlsm: return try XLSMCodec.read(data, options: options)
        case .csv: return try CSVCodec.read(data, options: options)
        case .ods: return try ODSCodec.read(data, options: options)
        case .numbers: return try NumbersCodec.read(data, options: options)
        }
    }

    /// Serializes in a format. The result carries every warning about what the format could not express.
    public func write(as format: SheetFormat, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        switch format {
        case .xlsx: return try XLSXCodec.write(self, options: options)
        case .xlsm: return try XLSMCodec.write(self, options: options)
        case .csv: return try CSVCodec.write(self, options: options)
        case .ods: return try ODSCodec.write(self, options: options)
        case .numbers: return try NumbersCodec.write(self, options: options)
        }
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
    @discardableResult
    public static func convert(_ source: URL, to format: SheetFormat, output: URL, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) throws -> WriteResult {
        try Workbook(contentsOf: source, options: readOptions).write(to: output, as: format, options: writeOptions)
    }
}
