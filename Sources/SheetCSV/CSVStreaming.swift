import Foundation
import SheetCore

/// Reads a delimited text file one record at a time, without holding it (spec Appendix B.39.10). The file is
/// read in pieces, decoded as the pieces arrive (a character cut by a piece boundary waits for the next piece),
/// and each record is handed over as soon as its line end has been seen. What it costs is the piece in hand and
/// the record on its way to the caller.
///
///     let reader = try CSVStreamingReader(contentsOf: url)
///     try reader.forEachRow { values in … }
///     for try await values in reader.rows() { … }
///
/// UTF-8 (with or without a BOM) and UTF-16 (with a BOM) are decoded piece by piece; a legacy encoding named in
/// `CSVReadOptions.encoding` (Shift_JIS, EUC-JP, …) is not self-synchronising, so such a file is decoded whole.
public struct CSVStreamingReader {
    private let source: any ByteSource
    private let options: CSVReadOptions
    private let filename: String?
    public static let pieceSize = 256 * 1024

    public init(contentsOf url: URL, options: CSVReadOptions = CSVReadOptions()) throws {
        source = try FileByteSource(url: url)
        self.options = options
        filename = url.lastPathComponent
    }

    public init(data: Data, options: CSVReadOptions = CSVReadOptions(), filename: String? = nil) {
        source = DataByteSource(data)
        self.options = options
        self.filename = filename
    }

    /// Visits every record in order. Throwing from `body` stops the walk and rethrows.
    public func forEachRow(_ body: ([CellValue?]) throws -> Void) throws {
        let walk = try Walk(source: source, options: options, filename: filename)
        while let record = try walk.next() { try body(record) }
    }

    /// The records as a sequence to iterate with `for try await`, pulled from the file as the loop asks.
    public func rows() -> AsyncThrowingStream<[CellValue?], Error> {
        let source = self.source, options = self.options, filename = self.filename
        final class Box: @unchecked Sendable { var walk: Walk?; var error: Error? }
        let box = Box()
        do { box.walk = try Walk(source: source, options: options, filename: filename) } catch { box.error = error }
        return AsyncThrowingStream(unfolding: {
            if let error = box.error { box.error = nil; throw error }
            return try box.walk?.next()
        })
    }

    /// One walk through the file: decoding, dialect, records.
    final class Walk {
        private let source: any ByteSource
        private let options: CSVReadOptions
        private var position = 0
        private var pendingBytes: [UInt8] = []          // an incomplete character at a piece boundary
        private var encoding: String.Encoding
        private var whole: String?                      // a legacy encoding: decoded in one go
        private var parser: RecordParser?
        private var records: [[String]] = []
        private var finished = false
        private let inference: CSVCodec.TypeInference?
        private let filename: String?
        private var sawFirstPiece = false

        init(source: any ByteSource, options: CSVReadOptions, filename: String?) throws {
            self.source = source; self.options = options; self.filename = filename
            inference = options.inferTypes ? CSVCodec.TypeInference(dateFormats: options.dateFormats) : nil
            let head = try source.bytes(in: 0..<Swift.min(source.count, 4))
            if let explicit = options.encoding {
                encoding = explicit
                if explicit == .utf8, let (bomEncoding, length) = TextEncodingSniffer.bom(in: head), bomEncoding == .utf8 { position = length }
            } else if let (bomEncoding, length) = TextEncodingSniffer.bom(in: head) {
                encoding = bomEncoding; position = length
            } else {
                encoding = .utf8
            }
            if encoding == .utf16 { encoding = .utf16BigEndian }
            if encoding != .utf8 && encoding != .utf16LittleEndian && encoding != .utf16BigEndian {
                // not self-synchronising: decode the whole file, as the ordinary reader does
                let (text, _) = try CSVCodec.decode(try source.bytes(in: 0..<source.count), options: options)
                whole = text
            }
        }

        /// The next record, typed as the options ask, or nil at the end.
        func next() throws -> [CellValue?]? {
            while records.isEmpty, !finished { try pull() }
            guard !records.isEmpty else { return nil }
            let record = records.removeFirst()
            return record.map { field -> CellValue? in
                guard !field.isEmpty else { return nil }
                return inference?.value(for: field) ?? .text(field)
            }
        }

        private func pull() throws {
            let text: String
            var final = false
            if let whole {
                text = whole; self.whole = nil; final = true
                position = source.count
            } else if position >= source.count {
                text = ""; final = true
            } else {
                let end = Swift.min(position + CSVStreamingReader.pieceSize, source.count)
                var bytes = pendingBytes
                bytes.append(contentsOf: try source.bytes(in: position..<end))
                position = end
                final = position >= source.count
                // hold back an incomplete character; a whole file that ends in one is a fault
                let keep = final ? 0 : Self.incompleteTail(bytes, encoding: encoding)
                pendingBytes = Array(bytes.suffix(keep))
                let usable = Data(bytes.prefix(bytes.count - keep))
                if encoding == .utf8 {
                    if let bad = TextEncodingSniffer.firstInvalidUTF8Offset(in: usable) {
                        guard options.lossy else { throw SheetError.malformedPart(path: "offset \(position - bytes.count + bad)", detail: "invalid UTF-8 sequence") }
                    }
                    text = String(decoding: usable, as: UTF8.self)
                } else {
                    guard let decoded = String(data: usable, encoding: encoding) else {
                        throw SheetError.malformedPart(path: "offset \(position - bytes.count)", detail: "undecodable UTF-16")
                    }
                    text = decoded
                }
            }
            if parser == nil {
                // the first piece decides the dialect, as the first line does for the ordinary reader
                var body = Substring(text)
                let delimiter: Character
                if let dialect = options.dialect {
                    delimiter = dialect.delimiter
                } else if let sep = CSVCodec.excelSeparatorLine(in: body) {
                    delimiter = sep.delimiter
                    body = body[sep.bodyStart...]
                } else {
                    delimiter = CSVCodec.sniffDelimiter(firstLineOf: body, filename: filename)
                }
                parser = RecordParser(delimiter: delimiter.unicodeScalars.first!, quote: (options.dialect?.quote ?? "\"").unicodeScalars.first!)
                records.append(contentsOf: parser!.feed(String(body), final: final))
            } else {
                records.append(contentsOf: parser!.feed(text, final: final))
            }
            if final { finished = true }
        }

        /// How many bytes at the end of `bytes` are the start of a character the next piece completes.
        static func incompleteTail(_ bytes: [UInt8], encoding: String.Encoding) -> Int {
            switch encoding {
            case .utf8:
                // walk back over up to three continuation bytes to the lead byte, and see whether it is complete
                var i = bytes.count - 1
                var back = 0
                while i >= 0, back < 4, bytes[i] & 0xC0 == 0x80 { i -= 1; back += 1 }
                guard i >= 0 else { return 0 }
                let lead = bytes[i]
                let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
                return back + 1 < needed ? back + 1 : 0
            case .utf16LittleEndian, .utf16BigEndian:
                var keep = bytes.count % 2
                let n = bytes.count - keep
                if n >= 2 {
                    let hi = encoding == .utf16LittleEndian ? bytes[n - 1] : bytes[n - 2]
                    if hi >= 0xD8, hi <= 0xDB { keep += 2 }   // a lead surrogate waiting for its trail
                }
                return keep
            default: return 0
            }
        }
    }

    /// The RFC 4180 record machine of the ordinary reader, resumable across pieces: a quoted field may span
    /// pieces, and a CR at a piece's end waits to see whether an LF follows it.
    struct RecordParser {
        let delimiter: Unicode.Scalar
        let quote: Unicode.Scalar
        private var record: [String] = []
        private var field = String.UnicodeScalarView()
        private var inQuotes = false
        private var fieldStarted = false
        private var recordStarted = false
        private var pendingCR = false

        init(delimiter: Unicode.Scalar, quote: Unicode.Scalar) { self.delimiter = delimiter; self.quote = quote }

        mutating func feed(_ text: String, final: Bool) -> [[String]] {
            var out: [[String]] = []
            let scalars = text.unicodeScalars
            var i = scalars.startIndex
            func endRecord() {
                if recordStarted || fieldStarted || !field.isEmpty { record.append(String(field)) }
                out.append(record)
                record = []; field = String.UnicodeScalarView()
                inQuotes = false; fieldStarted = false; recordStarted = false
            }
            if pendingCR {
                pendingCR = false
                endRecord()
                if i < scalars.endIndex, scalars[i] == "\n" { i = scalars.index(after: i) }
            }
            while i < scalars.endIndex {
                let c = scalars[i]
                let next = scalars.index(after: i)
                if inQuotes {
                    if c == quote {
                        if next < scalars.endIndex, scalars[next] == quote { field.append(quote); i = scalars.index(after: next); continue }
                        if next == scalars.endIndex, !final { pendingQuote = true; i = next; continue }
                        inQuotes = false
                    } else {
                        field.append(c)
                    }
                    i = next
                    continue
                }
                switch c {
                case quote where field.isEmpty && !fieldStarted:
                    inQuotes = true; fieldStarted = true; recordStarted = true
                case delimiter:
                    record.append(String(field)); field = String.UnicodeScalarView()
                    fieldStarted = false; recordStarted = true
                case "\n":
                    endRecord()
                case "\r":
                    if next == scalars.endIndex, !final { pendingCR = true; i = next; continue }
                    endRecord()
                    if next < scalars.endIndex, scalars[next] == "\n" { i = scalars.index(after: next); continue }
                default:
                    field.append(c); fieldStarted = true; recordStarted = true
                }
                i = next
            }
            if final, recordStarted || fieldStarted || !field.isEmpty { endRecord() }
            return out
        }

        /// A quote at the very end of a piece: it may be a closing quote, or the first half of a doubled one.
        private var pendingQuote = false {
            didSet { if pendingQuote { inQuotes = true } }
        }
    }
}

/// Writes a delimited text file one record at a time (spec Appendix B.39.10): each record is rendered, encoded
/// and put straight into the file. Nothing grows with the number of rows.
public final class CSVStreamingWriter {
    private let handle: FileHandle
    private let options: CSVWriteOptions
    private let renderer: CSVCodec.FieldRenderer
    private var row = 0
    private var closed = false
    private var pending = Data()
    /// What could not be written as asked: a formula without a cached value, text the encoding cannot carry.
    public private(set) var warnings: [ConversionWarning] = []

    public init(url: URL, options: CSVWriteOptions = CSVWriteOptions()) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: url.path) else { throw SheetError.ioFailure(detail: "cannot open \(url.lastPathComponent) for writing") }
        handle = h
        self.options = options
        renderer = CSVCodec.FieldRenderer(options: options)
        if options.includeBOM {
            switch options.encoding {
            case .utf8: pending.append(contentsOf: [0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: pending.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: pending.append(contentsOf: [0xFE, 0xFF])
            default: break
            }
        }
    }

    /// Appends one record. `nil` is an empty field.
    public func append(_ values: [CellValue?]) throws {
        precondition(!closed, "the writer is closed")
        var line: [String] = []
        for (c, value) in values.enumerated() {
            guard let value else { line.append(""); continue }
            let ref = CellRef(row: row, col: c)
            let field = renderer.render(value, at: ref, sheet: "Sheet1", warnings: &warnings)
            line.append(CSVCodec.quoted(field, delimiter: options.dialect.delimiter, quote: options.dialect.quote))
        }
        let text = line.joined(separator: String(options.dialect.delimiter)) + options.newline.rawValue
        guard let bytes = text.data(using: options.encoding) ?? (options.lossy ? text.data(using: options.encoding, allowLossyConversion: true) : nil) else {
            throw SheetError.unsupportedFeature("text in row \(row + 1) cannot be represented in \(String.localizedName(of: options.encoding))")
        }
        if text.data(using: options.encoding) == nil {
            warnings.append(ConversionWarning(.degraded, sheet: "Sheet1", location: CellRef(row: row, col: 0), message: "text cannot be represented in \(String.localizedName(of: options.encoding)); unencodable characters replaced"))
        }
        pending.append(bytes)
        row += 1
        if pending.count >= 64 * 1024 { try flush() }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        try handle.write(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }

    /// Writes what is buffered and closes the file. Calling it twice is harmless.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try flush()
        try handle.close()
    }

    deinit { if !closed { try? handle.close() } }
}
