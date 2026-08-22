import Foundation

/// A worksheet: a sparse grid of cells plus row/column formatting, merges, freeze panes and sheet-level options.
/// Reference type, like openpyxl's `Worksheet`.
public final class Worksheet {
    /// The tab name. Rules follow openpyxl: must not be empty or contain `\ * ? : / [ ]`, and a name already used by a
    /// sibling sheet gets a numeric suffix. An invalid assignment keeps the previous title (openpyxl raises);
    /// `Worksheet.validateTitle(_:)` explains why. Titles over 31 characters are accepted (Excel warns).
    public var title: String {
        didSet {
            guard title != oldValue else { return }
            guard Worksheet.validateTitle(title) == nil else { title = oldValue; return }
            if let wb = workbook { title = Worksheet.uniqueTitle(title, among: wb.worksheets.filter { $0 !== self }.map(\.title)) }
        }
    }
    public var state: SheetState = .visible
    public internal(set) var cells: [CellReference: Cell] = [:]
    public var rowDimensions: [Int: RowDimension] = [:]
    public var columnDimensions: [String: ColumnDimension] = [:]
    public var mergedCells: [CellRange] = []
    /// Freeze rows above and columns left of this cell ("B2" freezes row 1 and column A). "A1" means no freeze.
    public var freezePanes: CellReference? {
        didSet { if freezePanes == CellReference(column: 1, row: 1) { freezePanes = nil } }
    }
    public var autoFilter: CellRange?
    public var properties = SheetProperties()
    public var view = SheetView()
    public var sheetFormat = SheetFormat()
    public var pageMargins = PageMargins()
    public var pageSetup = PageSetup()
    public var printOptions = PrintOptions()
    /// Rows repeated at the top of every printed page (`_xlnm.Print_Titles`), e.g. 1...1.
    public var printTitleRows: ClosedRange<Int>?
    /// Columns repeated at the left of every printed page, by index (1 = A).
    public var printTitleColumns: ClosedRange<Int>?
    /// The print area(s) (`_xlnm.Print_Area`).
    public var printArea: [CellRange] = []
    /// Sheet-scoped defined names (`localSheetId`): name → formula text.
    public var definedNames: [String: String] = [:]
    /// Informational: the `<dimension ref>` the file declared, if any.
    public internal(set) var declaredDimension: CellRange?
    /// The last row written by `append` or seen by the reader (openpyxl `_current_row`); 0 for an empty sheet.
    public internal(set) var currentRow = 0
    weak var workbook: Workbook?

    init(title: String, workbook: Workbook?) { self.title = title; self.workbook = workbook }

    // MARK: - Titles

    public static let invalidTitleCharacters: Set<Character> = ["\\", "*", "?", ":", "/", "[", "]"]

    /// Nil when the title is acceptable, else the reason (openpyxl raises `ValueError` with the same message).
    public static func validateTitle(_ title: String) -> String? {
        if title.isEmpty { return "Title must have at least one character" }
        if let bad = title.first(where: invalidTitleCharacters.contains) { return "Invalid character \(bad) found in sheet title" }
        return nil
    }

    /// openpyxl `avoid_duplicate_name`: when `title` (case-insensitively) matches an existing name, append the next free
    /// integer after the highest suffix already used with that stem.
    public static func uniqueTitle(_ title: String, among names: [String]) -> String {
        guard names.contains(where: { $0.lowercased() == title.lowercased() }) else { return title }
        var highest = 0
        for n in names where n.lowercased().hasPrefix(title.lowercased()) {
            let suffix = n.dropFirst(title.count)
            if suffix.isEmpty { continue }
            if suffix.allSatisfy(\.isNumber), let v = Int(suffix) { highest = max(highest, v) }
        }
        return title + String(highest + 1)
    }

    // MARK: - Cells

    /// `ws["A1"]` — creates the cell on first access, as openpyxl does.
    public subscript(ref: String) -> Cell {
        guard let r = CellReference(ref) else { preconditionFailure("invalid cell reference \(ref)") }
        return cell(row: r.row, column: r.column)
    }

    public subscript(ref: CellReference) -> Cell { cell(row: ref.row, column: ref.column) }

    /// The cells of a range, row by row (`ws["A1:B2"]`). Nil when the string is not a range.
    public subscript(range range: String) -> [[Cell]]? {
        guard let r = CellRange(range) else { return nil }
        return rows(minRow: r.minRow, maxRow: r.maxRow, minColumn: r.minColumn, maxColumn: r.maxColumn)
    }

    public func cell(row: Int, column: Int) -> Cell {
        precondition(row >= 1 && column >= 1, "Row or column values must be at least 1")
        let ref = CellReference(column: column, row: row)
        if let c = cells[ref] { return c }
        let c = Cell(row: row, column: column, worksheet: self)
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
    public func existingCell(_ ref: String) -> Cell? { CellReference(ref).flatMap { cells[$0] } }

    /// Value shortcut: nil when the cell does not exist or is empty.
    public func value(row: Int, column: Int) -> CellValue? { existingCell(row: row, column: column)?.value }

    /// Removes a cell entirely (`del ws["A1"]`).
    public func removeCell(_ ref: String) { if let r = CellReference(ref) { cells[r] = nil } }
    public func removeCell(row: Int, column: Int) { cells[CellReference(column: column, row: row)] = nil }

    /// Appends a row after the last appended / loaded row (openpyxl `ws.append`). `nil` entries leave cells untouched;
    /// an empty array advances the row without creating cells.
    public func append(_ values: [CellValue?]) {
        currentRow += 1
        for (i, v) in values.enumerated() where v != nil { cell(row: currentRow, column: i + 1, value: v) }
    }

    /// Appends a row from column index → value (openpyxl `ws.append({1: ..., 3: ...})`).
    public func append(_ values: [Int: CellValue?]) {
        currentRow += 1
        for (col, v) in values where v != nil { cell(row: currentRow, column: col, value: v) }
    }

    /// Appends a row from column letter → value (openpyxl `ws.append({"A": ..., "C": ...})`).
    public func append(_ values: [String: CellValue?]) {
        currentRow += 1
        for (letter, v) in values where v != nil { if let col = CellReference.columnIndex(letter) { cell(row: currentRow, column: col, value: v) } }
    }

    public var minRow: Int { cells.keys.map(\.row).min() ?? 1 }
    public var maxRow: Int { cells.keys.map(\.row).max() ?? 1 }
    public var minColumn: Int { cells.keys.map(\.column).min() ?? 1 }
    public var maxColumn: Int { cells.keys.map(\.column).max() ?? 1 }
    /// "A1:J42" — always a range, "A1:A1" for an empty sheet (openpyxl `calculate_dimension`).
    public var dimensions: String {
        "\(CellReference.columnLetter(minColumn))\(minRow):\(CellReference.columnLetter(maxColumn))\(maxRow)"
    }

    /// Rows of cells in a rectangle (openpyxl `iter_rows`): from A1 to the last used cell unless bounds are given.
    /// Cells are created on the fly like openpyxl does. With no cells and no bounds the result is empty (`ws.rows` yields nothing then).
    public func rows(minRow: Int? = nil, maxRow: Int? = nil, minColumn: Int? = nil, maxColumn: Int? = nil) -> [[Cell]] {
        guard let (r0, r1, c0, c1) = bounds(minRow, maxRow, minColumn, maxColumn) else { return [] }
        return (r0...r1).map { r in (c0...c1).map { c in cell(row: r, column: c) } }
    }

    /// Columns of cells in a rectangle (openpyxl `iter_cols` / `ws.columns`).
    public func columns(minRow: Int? = nil, maxRow: Int? = nil, minColumn: Int? = nil, maxColumn: Int? = nil) -> [[Cell]] {
        guard let (r0, r1, c0, c1) = bounds(minRow, maxRow, minColumn, maxColumn) else { return [] }
        return (c0...c1).map { c in (r0...r1).map { r in cell(row: r, column: c) } }
    }

    /// Values only, `nil` for empty cells (openpyxl `iter_rows(values_only=True)` / `ws.values`). Creates no cells.
    public func values(minRow: Int? = nil, maxRow: Int? = nil, minColumn: Int? = nil, maxColumn: Int? = nil) -> [[CellValue?]] {
        guard let (r0, r1, c0, c1) = bounds(minRow, maxRow, minColumn, maxColumn) else { return [] }
        return (r0...r1).map { r in (c0...c1).map { c in existingCell(row: r, column: c)?.value } }
    }

    private func bounds(_ minRow: Int?, _ maxRow: Int?, _ minColumn: Int?, _ maxColumn: Int?) -> (Int, Int, Int, Int)? {
        if cells.isEmpty, minRow == nil, maxRow == nil, minColumn == nil, maxColumn == nil { return nil }
        let r0 = minRow ?? 1, r1 = maxRow ?? self.maxRow, c0 = minColumn ?? 1, c1 = maxColumn ?? self.maxColumn
        return r0 <= r1 && c0 <= c1 ? (r0, r1, c0, c1) : nil
    }

    /// The cells of one whole column by letter (`ws["C"]`), from row 1 to the last used row.
    public func column(_ letter: String) -> [Cell] {
        guard let c = CellReference.columnIndex(letter) else { return [] }
        return (1...maxRow).map { cell(row: $0, column: c) }
    }

    /// The cells of one whole row (`ws[2]`), from column A to the last used column.
    public func row(_ r: Int) -> [Cell] { (1...maxColumn).map { cell(row: r, column: $0) } }

    // MARK: - Moving cells (openpyxl insert_rows / delete_rows / move_range)

    /// Moves a single cell, overwriting the destination (openpyxl `_move_cell`). Formulas are not translated.
    func moveCell(row: Int, column: Int, rowOffset: Int, columnOffset: Int) {
        let from = CellReference(column: column, row: row)
        let c = cells[from] ?? Cell(row: row, column: column, worksheet: self)
        cells[from] = nil
        c.row += rowOffset; c.column += columnOffset
        cells[c.reference] = c
    }

    private func moveCells(minRow: Int? = nil, minColumn: Int? = nil, offset: Int, rowsNotColumns: Bool) {
        // openpyxl materialises the affected block first (`list(self.iter_rows(...))`), so gaps move as empty cells.
        if !cells.isEmpty {
            let r0 = minRow ?? self.minRow, c0 = minColumn ?? self.minColumn, r1 = self.maxRow, c1 = self.maxColumn
            if r0 <= r1, c0 <= c1 { for r in r0...r1 { for c in c0...c1 { _ = cell(row: r, column: c) } } }
        }
        let affected = cells.keys.filter { k in (minRow.map { k.row >= $0 } ?? true) && (minColumn.map { k.column >= $0 } ?? true) }
        let ordered = affected.sorted { a, b in
            let ka = rowsNotColumns ? a.row : a.column, kb = rowsNotColumns ? b.row : b.column
            return offset > 0 ? ka > kb : ka < kb
        }
        for ref in ordered { moveCell(row: ref.row, column: ref.column, rowOffset: rowsNotColumns ? offset : 0, columnOffset: rowsNotColumns ? 0 : offset) }
    }

    /// Inserts `count` empty rows before row `index` (openpyxl `insert_rows`). Row dimensions and merges are not shifted.
    public func insertRows(_ index: Int, count: Int = 1) {
        moveCells(minRow: index, offset: count, rowsNotColumns: true)
        currentRow = maxRow
    }

    /// Inserts `count` empty columns before column `index` (openpyxl `insert_cols`).
    public func insertColumns(_ index: Int, count: Int = 1) {
        moveCells(minColumn: index, offset: count, rowsNotColumns: false)
    }

    /// Deletes `count` rows starting at `start` (openpyxl `delete_rows`).
    public func deleteRows(_ start: Int, count: Int = 1) {
        let remainder = Worksheet.gutter(start, count, maxRow)
        moveCells(minRow: start + count, offset: -count, rowsNotColumns: true)
        for r in remainder { for k in cells.keys where k.row == r { cells[k] = nil } }
        currentRow = cells.isEmpty ? 0 : maxRow
    }

    /// Deletes `count` columns starting at `start` (openpyxl `delete_cols`).
    public func deleteColumns(_ start: Int, count: Int = 1) {
        let remainder = Worksheet.gutter(start, count, maxColumn)
        moveCells(minColumn: start + count, offset: -count, rowsNotColumns: false)
        for c in remainder { for k in cells.keys where k.column == c { cells[k] = nil } }
    }

    /// The rows / columns a delete must clear explicitly because nothing moves into them (openpyxl `_gutter`).
    static func gutter(_ index: Int, _ offset: Int, _ maxValue: Int) -> [Int] {
        let lo = max(maxValue + 1 - offset, index), hi = min(index + offset, maxValue)
        return lo <= hi ? Array(lo...hi) : []
    }

    /// Moves the cells of a range by `rows` / `columns`, overwriting whatever is there (openpyxl `move_range`).
    /// Formulas are not translated. Returns the rebased range.
    @discardableResult
    public func moveRange(_ range: CellRange, rows: Int = 0, columns: Int = 0) -> CellRange {
        guard rows != 0 || columns != 0 else { return range }
        let order: [CellReference]
        if rows != 0 { order = rows > 0 ? range.rows.reversed().flatMap { $0 } : range.rows.flatMap { $0 } }
        else { order = columns > 0 ? range.cols.reversed().flatMap { $0 } : range.cols.flatMap { $0 } }
        for ref in order { moveCell(row: ref.row, column: ref.column, rowOffset: rows, columnOffset: columns) }
        return range.shifted(rows: rows, columns: columns) ?? range
    }

    @discardableResult
    public func moveRange(_ range: String, rows: Int = 0, columns: Int = 0) -> CellRange? {
        CellRange(range).map { moveRange($0, rows: rows, columns: columns) }
    }

    // MARK: - Merges

    /// Merges a range. As in openpyxl, only the top-left cell keeps its value; the others are cleared and the top-left
    /// cell's border is extended along the edges of the merged area.
    public func mergeCells(_ range: String) {
        guard let r = CellRange(range) else { preconditionFailure("invalid range \(range)") }
        mergeCells(r)
    }

    public func mergeCells(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) {
        mergeCells(CellRange(minColumn: startColumn, minRow: startRow, maxColumn: endColumn, maxRow: endRow))
    }

    public func mergeCells(_ r: CellRange) {
        var r = r; r.title = nil
        mergedCells.append(r)
        cleanMergedRange(r)
    }

    /// Clears the non-anchor cells of a merged range and formats its edges (openpyxl `_clean_merge_range`).
    func cleanMergedRange(_ r: CellRange) {
        for ref in r.cells.dropFirst() {
            if let c = cells[ref] { c.value = nil; c.hyperlink = nil; c.comment = nil }
        }
        formatMergedRange(r)
    }

    /// openpyxl `MergedCellRange`: the anchor takes the bottom / right sides from the bottom-right cell, then the cells
    /// along each edge take that side of the anchor's border (their own settings win), and every cell inherits the
    /// anchor's protection.
    func formatMergedRange(_ r: CellRange) {
        let start = cell(row: r.minRow, column: r.minColumn)
        if let end = cells[r.bottomRight], end !== start {
            start.border = start.border.combined(with: Border(right: end.border.right, bottom: end.border.bottom))
        }
        let edges: [(Side, [CellReference], Border)] = [
            (start.border.top, r.top, Border(top: start.border.top)), (start.border.left, r.left, Border(left: start.border.left)),
            (start.border.right, r.right, Border(right: start.border.right)), (start.border.bottom, r.bottom, Border(bottom: start.border.bottom)),
        ]
        for (side, refs, border) in edges where side.style != nil {
            for ref in refs { let c = self[ref]; c.border = c.border.combined(with: border) }
        }
        let protection = start.protection
        for ref in r.cells { self[ref].protection = protection }
    }

    /// Unmerges exactly this range; false when it was not merged (openpyxl raises `KeyError`).
    @discardableResult
    public func unmergeCells(_ range: String) -> Bool {
        guard let r = CellRange(range) else { return false }
        return unmergeCells(r)
    }

    @discardableResult
    public func unmergeCells(startRow: Int, startColumn: Int, endRow: Int, endColumn: Int) -> Bool {
        unmergeCells(CellRange(minColumn: startColumn, minRow: startRow, maxColumn: endColumn, maxRow: endRow))
    }

    @discardableResult
    public func unmergeCells(_ r: CellRange) -> Bool {
        guard let i = mergedCells.firstIndex(where: { $0.coordinate == r.coordinate }) else { return false }
        mergedCells.remove(at: i)
        for ref in r.cells.dropFirst() { cells[ref] = nil }   // openpyxl drops the MergedCell placeholders
        return true
    }

    /// The merged range containing a cell, if any.
    public func mergedRange(containing ref: CellReference) -> CellRange? { mergedCells.first { $0.contains(ref) } }
    /// True when the cell is inside any merged range (`"A1" in ws.merged_cells`).
    public func isMerged(_ coordinate: String) -> Bool { CellReference(coordinate).map { mergedRange(containing: $0) != nil } ?? false }

    // MARK: - Dimensions

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

    /// Puts rows `start...end` in an outline group (openpyxl `row_dimensions.group`).
    public func groupRows(_ start: Int, _ end: Int, outlineLevel: Int = 1, hidden: Bool = false) {
        for r in start...end { setRowDimension(r) { $0.outlineLevel = outlineLevel; $0.hidden = hidden } }
    }

    /// Puts columns `start...end` (letters) in an outline group (openpyxl `column_dimensions.group`).
    public func groupColumns(_ start: String, _ end: String, outlineLevel: Int = 1, hidden: Bool = false) {
        guard let a = CellReference.columnIndex(start), let b = CellReference.columnIndex(end), a <= b else { return }
        for c in a...b { setColumnDimension(CellReference.columnLetter(c)) { $0.outlineLevel = outlineLevel; $0.hidden = hidden } }
    }

    /// Runs of adjacent outlined columns as "F:K" strings (openpyxl `column_groups`).
    public var columnGroups: [String] {
        let outlined = columnDimensions.compactMap { k, v in v.outlineLevel > 0 ? CellReference.columnIndex(k) : nil }.sorted()
        var groups: [(Int, Int)] = []
        for c in outlined {
            if let last = groups.last, last.1 == c - 1 { groups[groups.count - 1].1 = c } else { groups.append((c, c)) }
        }
        return groups.map { "\(CellReference.columnLetter($0.0)):\(CellReference.columnLetter($0.1))" }
    }

    // MARK: - Panes / printing

    /// Freeze rows above and columns left of this cell ("B2" freezes row 1 and column A). "" or "A1" clears.
    public func freezePanes(at ref: String) { freezePanes = CellReference(ref) }

    /// The `_xlnm.Print_Titles` formula, e.g. `'Sheet'!$1:$2,'Sheet'!$C:$D` (openpyxl `print_titles`). Nil when unset.
    public var printTitles: String? {
        var parts: [String] = []
        let q = CellReference.quoteSheetName(title)
        if let r = printTitleRows { parts.append("\(q)!$\(r.lowerBound):$\(r.upperBound)") }
        if let c = printTitleColumns { parts.append("\(q)!$\(CellReference.columnLetter(c.lowerBound)):$\(CellReference.columnLetter(c.upperBound))") }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// The `_xlnm.Print_Area` formula, e.g. `'Sheet'!$A$1:$F$5` (openpyxl `print_area`). Empty string when unset.
    public var printAreaFormula: String {
        printArea.map { "\(CellReference.quoteSheetName(title))!\($0.topLeft.absolute):\($0.bottomRight.absolute)" }.joined(separator: ",")
    }

    /// Sets the print area from "A1:F5" / "$A$1:$F$5" (multiple areas comma separated). Nil or "" clears.
    public func setPrintArea(_ text: String?) {
        guard let text, !text.isEmpty else { printArea = []; return }
        printArea = text.split(separator: ",").compactMap { part in
            let s = String(part)
            return CellRange(CellRange.splitSheetTitle(s)?.cells ?? s).map { var r = $0; r.title = nil; return r }
        }
    }

    /// Parses a `_xlnm.Print_Titles` formula such as `'Sheet1'!$1:$2,$A:$A` into `printTitleRows` / `printTitleColumns`.
    public func setPrintTitles(_ formula: String?) {
        printTitleRows = nil; printTitleColumns = nil
        guard let formula else { return }
        for part in formula.split(separator: ",") {
            let cells = CellRange.splitSheetTitle(String(part))?.cells ?? String(part)
            guard let b = RangeBounds(cells) else { continue }
            if b.minColumn == nil, let lo = b.minRow, let hi = b.maxRow { printTitleRows = lo...hi }
            else if b.minRow == nil, let lo = b.minColumn, let hi = b.maxColumn { printTitleColumns = lo...hi }
        }
    }

    /// Parses "1:4" into `printTitleRows` and "A:F" into `printTitleColumns` (openpyxl `print_title_rows` / `_cols`).
    public func setPrintTitleRows(_ text: String?) {
        guard let text, let b = RangeBounds(text), let lo = b.minRow, let hi = b.maxRow, b.minColumn == nil else { printTitleRows = nil; return }
        printTitleRows = lo...hi
    }
    public func setPrintTitleColumns(_ text: String?) {
        guard let text, let b = RangeBounds(text), let lo = b.minColumn, let hi = b.maxColumn, b.minRow == nil else { printTitleColumns = nil; return }
        printTitleColumns = lo...hi
    }
}
