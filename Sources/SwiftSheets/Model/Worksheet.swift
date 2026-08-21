import Foundation

/// A worksheet: a sparse grid of cells plus row/column formatting, merges, freeze panes and sheet-level options.
/// Reference type, like openpyxl's `Worksheet`.
public final class Worksheet {
    public var title: String
    public var state: SheetState = .visible
    public internal(set) var cells: [CellReference: Cell] = [:]
    public var rowDimensions: [Int: RowDimension] = [:]
    public var columnDimensions: [String: ColumnDimension] = [:]
    public var mergedCells: [CellRange] = []
    public var freezePanes: CellReference?
    public var autoFilter: CellRange?
    public var properties = SheetProperties()
    public var view = SheetView()
    public var pageMargins = PageMargins()
    public var pageSetup = PageSetup()
    public var printTitleRows: ClosedRange<Int>?
    /// Informational: the `<dimension ref>` the file declared, if any.
    public internal(set) var declaredDimension: CellRange?
    weak var workbook: Workbook?

    init(title: String, workbook: Workbook?) { self.title = title; self.workbook = workbook }

    // MARK: - Cells

    /// `ws["A1"]` — creates the cell on first access, as openpyxl does.
    public subscript(ref: String) -> Cell {
        guard let r = CellReference(ref) else { preconditionFailure("invalid cell reference \(ref)") }
        return cell(row: r.row, column: r.column)
    }

    public subscript(ref: CellReference) -> Cell { cell(row: ref.row, column: ref.column) }

    public func cell(row: Int, column: Int) -> Cell {
        let ref = CellReference(column: column, row: row)
        if let c = cells[ref] { return c }
        let c = Cell(row: row, column: column)
        cells[ref] = c
        return c
    }

    @discardableResult
    public func cell(row: Int, column: Int, value: CellValue?) -> Cell {
        let c = cell(row: row, column: column)
        c.value = value
        return c
    }

    /// The cell if it exists, without creating it.
    public func existingCell(row: Int, column: Int) -> Cell? { cells[CellReference(column: column, row: row)] }

    /// Value shortcut: nil when the cell does not exist or is empty.
    public func value(row: Int, column: Int) -> CellValue? { existingCell(row: row, column: column)?.value }

    /// Appends a row after the last used row (openpyxl `ws.append`). `nil` entries leave cells untouched.
    public func append(_ values: [CellValue?]) {
        let r = maxRow + 1
        for (i, v) in values.enumerated() where v != nil { cell(row: r, column: i + 1, value: v) }
        if values.allSatisfy({ $0 == nil }) { _ = cell(row: r, column: 1) }  // keep the row "used"
    }

    public var minRow: Int { cells.keys.map(\.row).min() ?? 1 }
    public var maxRow: Int { cells.keys.map(\.row).max() ?? 1 }
    public var minColumn: Int { cells.keys.map(\.column).min() ?? 1 }
    public var maxColumn: Int { cells.keys.map(\.column).max() ?? 1 }
    /// "A1:J42"
    public var dimensions: String { CellRange(minColumn: minColumn, minRow: minRow, maxColumn: maxColumn, maxRow: maxRow).description }

    /// Rows of cells in a rectangle (openpyxl `iter_rows`). Cells are created on the fly like openpyxl does.
    public func rows(minRow: Int? = nil, maxRow: Int? = nil, minColumn: Int? = nil, maxColumn: Int? = nil) -> [[Cell]] {
        let r0 = minRow ?? self.minRow, r1 = maxRow ?? self.maxRow, c0 = minColumn ?? self.minColumn, c1 = maxColumn ?? self.maxColumn
        guard r0 <= r1, c0 <= c1 else { return [] }
        return (r0...r1).map { r in (c0...c1).map { c in cell(row: r, column: c) } }
    }

    /// Values only, `nil` for empty cells (openpyxl `iter_rows(values_only=True)`).
    public func values(minRow: Int? = nil, maxRow: Int? = nil, minColumn: Int? = nil, maxColumn: Int? = nil) -> [[CellValue?]] {
        let r0 = minRow ?? self.minRow, r1 = maxRow ?? self.maxRow, c0 = minColumn ?? self.minColumn, c1 = maxColumn ?? self.maxColumn
        guard r0 <= r1, c0 <= c1 else { return [] }
        return (r0...r1).map { r in (c0...c1).map { c in existingCell(row: r, column: c)?.value } }
    }

    public func deleteRows(_ start: Int, count: Int = 1) {
        var moved: [CellReference: Cell] = [:]
        for (ref, c) in cells {
            if ref.row >= start + count {
                let nc = Cell(row: ref.row - count, column: ref.column); nc.value = c.value; nc.style = c.style; nc.hyperlink = c.hyperlink; nc.comment = c.comment
                moved[nc.reference] = nc
            } else if ref.row < start { moved[ref] = c }
        }
        cells = moved
    }

    // MARK: - Merges / dimensions

    public func mergeCells(_ range: String) {
        guard let r = CellRange(range) else { preconditionFailure("invalid range \(range)") }
        mergedCells.append(r)
    }

    public func unmergeCells(_ range: String) {
        mergedCells.removeAll { $0.description == CellRange(range)?.description }
    }

    public func rowDimension(_ row: Int) -> RowDimension { rowDimensions[row] ?? RowDimension() }
    public func setRowDimension(_ row: Int, _ update: (inout RowDimension) -> Void) {
        var d = rowDimension(row); update(&d); rowDimensions[row] = d
    }
    public func columnDimension(_ letter: String) -> ColumnDimension { columnDimensions[letter.uppercased()] ?? ColumnDimension() }
    public func setColumnDimension(_ letter: String, _ update: (inout ColumnDimension) -> Void) {
        var d = columnDimension(letter); update(&d); columnDimensions[letter.uppercased()] = d
    }
    /// Sets the width of a column by index (1 = A).
    public func setColumnWidth(_ column: Int, _ width: Double) {
        setColumnDimension(CellReference.columnLetter(column)) { $0.width = width }
    }

    /// Freeze rows above and columns left of this cell ("B2" freezes row 1 and column A).
    public func freezePanes(at ref: String) { freezePanes = CellReference(ref) }
}
