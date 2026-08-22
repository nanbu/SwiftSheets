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
    public init(contentsOf url: URL, options: ReadOptions = ReadOptions()) throws {
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        try self.init(data: try Data(contentsOf: url), options: opts)
    }

    /// Parses bytes. `format` overrides detection.
    public init(data: Data, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws {
        guard let f = format ?? SheetFormat.detect(from: data, filename: options.filename) else { throw SheetError.unrecognizedFormat }
        switch f {
        case .xlsx: self = try XLSXCodec.read(data, options: options)
        case .xlsm: self = try XLSMCodec.read(data, options: options)
        case .csv: self = try CSVCodec.read(data, options: options)
        case .ods: self = try ODSCodec.read(data, options: options)
        case .numbers: self = try NumbersCodec.read(data, options: options)
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
    @discardableResult
    public func write(to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        let f = format ?? SheetFormat(fileExtension: url.pathExtension) ?? sourceInfo?.format ?? .xlsx
        let result = try write(as: f, options: options)
        try result.data.write(to: url)
        return result
    }

    /// Read → write in one step.
    @discardableResult
    public static func convert(_ source: URL, to format: SheetFormat, output: URL, readOptions: ReadOptions = ReadOptions(), writeOptions: WriteOptions = WriteOptions()) throws -> WriteResult {
        try Workbook(contentsOf: source, options: readOptions).write(to: output, as: format, options: writeOptions)
    }
}
