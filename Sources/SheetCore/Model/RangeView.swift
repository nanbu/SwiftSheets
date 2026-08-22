import Foundation

/// A rectangle of a table, seen lazily (spec §14.4 — openpyxl's `ws['A1':'C3']`). Nothing is built until it is
/// asked for: iterating hands out one row at a time, and the table's cells are shared rather than copied, so a view
/// over a hundred thousand rows costs nothing until you read them.
///
///     for row in sheet.range("A2:D100") {
///         guard let name = row[0]?.textValue else { continue }
///         total += row[2]?.numberValue ?? 0
///     }
///     let block = sheet.range("B2:B99").values     // materialised only where you say so
///
/// The view is a snapshot: it holds the table as it was when `range(_:)` was called, so editing the sheet
/// afterwards does not change what it shows.
public struct RangeView: Sendable, Sequence {
    /// The rectangle this view covers.
    public let range: CellRange
    private let table: Table

    init(table: Table, range: CellRange) {
        self.table = table
        self.range = range
    }

    /// One row of the rectangle. The values are read from the table on demand; the row itself stores none of them.
    public struct Row: Sendable, RandomAccessCollection {
        /// The row's absolute index in the sheet.
        public let row: Int
        private let table: Table
        private let firstColumn: Int
        private let width: Int

        init(table: Table, row: Int, firstColumn: Int, width: Int) {
            self.table = table; self.row = row; self.firstColumn = firstColumn; self.width = width
        }

        public var startIndex: Int { 0 }
        public var endIndex: Int { width }
        public func index(after i: Int) -> Int { i + 1 }
        public func index(before i: Int) -> Int { i - 1 }

        /// The value at the i-th position of the row, counted from the left edge of the range.
        public subscript(i: Int) -> CellValue? { table[ref(i)] }
        /// Where the i-th position of the row actually is.
        public func ref(_ i: Int) -> CellRef { CellRef(row: row, col: firstColumn + i) }
        /// The whole cell (style, link and note included), or nil when the sheet has none there.
        public func cell(_ i: Int) -> Cell? { table.cell(at: ref(i)) }
    }

    public struct Iterator: IteratorProtocol {
        private let view: RangeView
        private var row: Int

        init(_ view: RangeView) { self.view = view; row = view.range.minRow }

        public mutating func next() -> Row? {
            guard row <= view.range.maxRow else { return nil }
            defer { row += 1 }
            return view.row(at: row)
        }
    }

    public func makeIterator() -> Iterator { Iterator(self) }

    /// The row at an absolute row index. Reading outside the range is a programming error.
    public func row(at index: Int) -> Row {
        precondition(range.minRow...range.maxRow ~= index, "row \(index) is outside \(range.a1)")
        return Row(table: table, row: index, firstColumn: range.minCol, width: range.size.cols)
    }

    /// The value at an absolute reference; nil when it falls outside the range.
    public subscript(_ ref: CellRef) -> CellValue? { range.contains(ref) ? table[ref] : nil }
    /// The value at an absolute A1 coordinate ("B2"); nil when it falls outside the range.
    public subscript(_ a1: String) -> CellValue? { CellRef(a1).flatMap { self[$0] } }
    /// The value at a position relative to the top-left of the range (`view[0, 0]` is its first cell).
    public subscript(row: Int, col: Int) -> CellValue? {
        self[CellRef(row: range.minRow + row, col: range.minCol + col)]
    }

    /// Rows × columns, materialised — the same array `Sheet.values(in:)` returns.
    public var values: [[CellValue?]] { map(Array.init) }
    /// The cells that actually exist inside the range, in row-major order.
    public var existingCells: [(ref: CellRef, cell: Cell)] {
        table.existingRefs(in: range).sorted().map { ($0, table.cell(at: $0)!) }
    }
    /// How many rows the view has.
    public var count: Int { range.size.rows }
    public var isEmpty: Bool { false }
}
