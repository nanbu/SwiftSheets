import Foundation

/// One cell as a streaming reader hands it over (spec Appendix B.40).
public struct StreamedCell: Sendable {
    public let ref: CellRef
    public let value: CellValue?
    /// The cell's formatting, when `StreamingReadOptions.includeStyles` asked for it.
    public let style: CellStyle?

    public init(ref: CellRef, value: CellValue?, style: CellStyle? = nil) {
        self.ref = ref; self.value = value; self.style = style
    }
}

/// One row as a streaming reader hands it over: the cells the file actually holds, in column order. A row the
/// file skipped is never delivered, and a row's missing cells are simply absent — `values(width:)` fills the gaps
/// in when a dense array is what you want. The same shape from every format: an XLSX `<row>`, an ODS
/// `<table:table-row>` (one delivery per repetition), a row of a Numbers tile.
public struct StreamedRow: Sendable {
    /// 0-based, as everywhere else in the model. For a Numbers table, the table's own row number.
    public let index: Int
    public let cells: [StreamedCell]

    public init(index: Int, cells: [StreamedCell]) { self.index = index; self.cells = cells }

    /// A dense array from column 0 to `width - 1` (or to the row's own last cell when `width` is nil).
    public func values(width: Int? = nil) -> [CellValue?] {
        let last = width.map { $0 - 1 } ?? (cells.last?.ref.col ?? -1)
        guard last >= 0 else { return [] }
        var out = [CellValue?](repeating: nil, count: last + 1)
        for c in cells where c.ref.col <= last { out[c.ref.col] = c.value }
        return out
    }
    public var isEmpty: Bool { cells.allSatisfy { $0.value == nil } }
}

/// What a streaming reader does with the sheet it walks.
public struct StreamingReadOptions: Sendable, Hashable {
    /// Resolve each cell's formatting as well as its value. Off by default: it is the expensive half, and a
    /// row-by-row pass is usually after the numbers.
    public var includeStyles = false
    /// Formula cells yield their cached values rather than the formula (openpyxl's `data_only`).
    public var dataOnly = false
    /// Rows with no cell that holds anything are handed over anyway. Off by default, as openpyxl's reader is.
    public var includesEmptyRows = false
    public init(includeStyles: Bool = false, dataOnly: Bool = false, includesEmptyRows: Bool = false) {
        self.includeStyles = includeStyles; self.dataOnly = dataOnly; self.includesEmptyRows = includesEmptyRows
    }
}

/// What every format's streaming reader implements, so the one `StreamingReader` in the facade can hand a file of
/// any format to the reader that walks it (spec Appendix B.40.1). `forEachRow` is the push shape — the reader
/// drives the parse and calls `body` per row; `rowWalk` is the pull shape — the caller asks for one row at a time
/// and the reader reads no further than that. A reader implements whichever is natural and gets the other one.
package protocol StreamingRowSource {
    /// The sheets of the file, in the file's order.
    var sheetNames: [String] { get }
    /// How many tables the sheet holds: one for XLSX / ODS / CSV, one or more for Numbers.
    func tableCount(inSheet name: String) throws -> Int
    /// Visits every row of one table of a sheet in order. Throwing from `body` stops the walk and rethrows.
    func forEachRow(inSheet name: String, table: Int, options: StreamingReadOptions, _ body: (StreamedRow) throws -> Void) throws
    /// A walk over the rows of one table of a sheet, pulled one at a time.
    func rowWalk(inSheet name: String, table: Int, options: StreamingReadOptions) throws -> any StreamingRowWalk
}

/// One walk through a sheet's rows: `next()` reads as far as the next row and no further, and answers nil at the
/// end. Not `Sendable` — a walk has a position.
package protocol StreamingRowWalk: AnyObject {
    func next() throws -> StreamedRow?
}

extension StreamingRowSource {
    /// The push shape from the pull shape, for a reader that only implements `rowWalk`.
    package func forEachRow(inSheet name: String, table: Int, options: StreamingReadOptions, _ body: (StreamedRow) throws -> Void) throws {
        let walk = try rowWalk(inSheet: name, table: table, options: options)
        while let row = try walk.next() { try body(row) }
    }

    /// The sheet's only table, or the one asked for. A format whose sheets hold one grid throws for any other.
    package func checkTable(_ table: Int, inSheet name: String) throws {
        let count = try tableCount(inSheet: name)
        guard (0..<count).contains(table) else {
            throw SheetError.invalidWorkbook(count == 1
                ? "sheet \(name) has one table; table \(table) does not exist"
                : "sheet \(name) has \(count) tables; table \(table) does not exist")
        }
    }
}

/// The rows of a walk as a sequence to iterate — `for try await row in …` — pulled one at a time as the loop asks
/// for them, so a walk that stops early reads no further (spec Appendix B.39.10). The sequence is asynchronous
/// only because that is the shape Swift gives a sequence that can throw; nothing runs concurrently.
package enum StreamingRowSequence {
    package static func make(_ makeWalk: () throws -> any StreamingRowWalk) -> AsyncThrowingStream<StreamedRow, Error> {
        /// One consumer pulls on the walk, one row at a time, so its access is sequential by construction.
        final class Box: @unchecked Sendable {
            var walk: (any StreamingRowWalk)?
            var setupError: Error?
        }
        let box = Box()
        do { box.walk = try makeWalk() } catch { box.setupError = error }
        return AsyncThrowingStream(unfolding: {
            if let error = box.setupError { box.setupError = nil; throw error }
            guard let walk = box.walk else { return nil }
            let row = try walk.next()
            if row == nil { box.walk = nil }
            return row
        })
    }
}

/// A SAX handler that turns a part's events into rows and hands each to a receiver: the streaming sheet parsers
/// of XLSX and ODS. The receiver can be rebound after the parser is made, which is what lets a walk make the
/// parser first and then point it at its own queue.
package protocol StreamingRowParser: SAXHandler {
    /// The walk reached the end of what it was asked to read and stopped the parse on purpose — not a failure.
    var reachedEnd: Bool { get }
    /// What the receiver threw, if the receiver stopped the walk.
    var thrown: Error? { get }
    func rebind(_ body: @escaping (StreamedRow) throws -> Void)
}

/// The pull shape of a piece-fed parse (spec Appendix B.39.10): the next piece of the part is expanded and parsed
/// only when the rows already in hand run out, so a caller that stops early leaves the rest of the part folded.
package final class PieceFedRowWalk: StreamingRowWalk {
    private var queue: [StreamedRow] = []
    private var head = 0
    private let feeder: SAXDriver.PieceFeeder
    private let parser: any StreamingRowParser
    private var finished = false

    package init(parser: any StreamingRowParser, stream: ZipEntryStream, part: String) throws {
        let driver = SAXDriver(handler: parser)
        parser.driver = driver
        self.parser = parser
        feeder = try SAXDriver.PieceFeeder(driver: driver, stream: stream, part: part)
        // the feeder delivers nothing until `feedNext`, so the receiver can be the walk's own queue
        parser.rebind { [unowned self] row in self.queue.append(row) }
    }

    package func next() throws -> StreamedRow? {
        while head == queue.count, !finished {
            queue.removeAll(keepingCapacity: true); head = 0
            if try !feeder.feedNext() { finished = true }
        }
        if head < queue.count { defer { head += 1 }; return queue[head] }
        // the parser stops itself at the end of the rows; that stop is not a failure
        if let thrown = parser.thrown { throw thrown }
        if let failure = feeder.failure, !parser.reachedEnd { throw failure }
        return nil
    }
}

/// The writers that put rows into a file as they arrive (spec Appendix B.42): one per format, behind the umbrella
/// `StreamingWriter` in the SwiftSheets module. A row is written once and cannot be gone back to; `close()`
/// completes the file, and only then are the warnings final.
package protocol StreamingRowSink: AnyObject {
    /// Finishes the sheet being written and starts another. A format that holds one sheet throws.
    func addSheet(named name: String) throws
    /// Appends a row of cells, formatting and all, at whatever row comes next.
    func append(_ cells: [Cell]) throws
    /// Writes what is pending and completes the file. Calling it twice is harmless; not calling it leaves the file
    /// unfinished.
    func close() throws
    /// What the format could not carry as asked — a number format it has no spelling for, a formula written as
    /// its value. Never silent (spec §6).
    var warnings: [ConversionWarning] { get }
}

extension StreamingRowSink {
    /// Appends a row of values, unformatted.
    package func append(_ values: [CellValue?]) throws {
        try append(values.map { value in var c = Cell(); c.value = value; return c })
    }
}
