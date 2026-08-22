import Foundation

/// A sheet: a named canvas holding one or more tables (exactly one for XLSX / ODS) plus sheet-level options — view,
/// freeze panes, print setup, sheet-scoped names. The cell API of the default table is available directly on the
/// sheet, so XLSX / ODS code never has to mention `tables`.
public struct Sheet: Hashable, Sendable {
    /// The tab name. Validation and de-duplication happen when the sheet is placed in a `Workbook`
    /// (`Workbook.sheets` rejects `\ * ? : / [ ]`, empty names and duplicates).
    public var name: String
    public var state: SheetState = .visible
    public var tables: [Table] = [Table()]
    /// Freeze rows above and columns left of this cell ("B2" freezes row 1 and column A). A1 / nil means no freeze.
    public var freezePanes: CellRef? {
        didSet { if freezePanes == CellRef(row: 0, col: 0) { freezePanes = nil } }
    }
    public var autoFilter: CellRange?
    public var properties = SheetProperties()
    public var view = SheetView()
    public var sheetFormat = SheetFormatProperties()
    public var pageMargins = PageMargins()
    public var pageSetup = PageSetup()
    public var printOptions = PrintOptions()
    /// Rows repeated at the top of every printed page (`_xlnm.Print_Titles`), 0-based.
    public var printTitleRows: ClosedRange<Int>?
    /// Columns repeated at the left of every printed page, 0-based.
    public var printTitleColumns: ClosedRange<Int>?
    /// The print area(s) (`_xlnm.Print_Area`).
    public var printArea: [CellRange] = []
    /// Sheet-scoped defined names: name → formula text.
    public var definedNames: [String: String] = [:]
    /// Informational: the `<dimension ref>` the file declared, if any.
    public var declaredDimension: CellRange?
    /// Material the reader kept for a lossless write-back (spec §6).
    public var preserved = SheetPreservation()

    public init(name: String) { self.name = name }

    public var isHidden: Bool {
        get { state != .visible }
        set { state = newValue ? .hidden : .visible }
    }
    /// Tab colour as "RRGGBB" / "AARRGGBB".
    public var tabColor: String? {
        get { if case .rgb(let v)? = properties.tabColor { return v }; return nil }
        set { properties.tabColor = newValue.map { Color(hex: $0) } }
    }

    // MARK: - Default table

    /// The first table — the whole grid for XLSX / ODS sheets. Created on demand if the sheet has none.
    public var table: Table {
        get { tables.first ?? Table() }
        _modify {
            if tables.isEmpty { tables.append(Table()) }
            yield &tables[0]
        }
        set { if tables.isEmpty { tables.append(newValue) } else { tables[0] = newValue } }
    }

    /// Adds a table (Numbers: several per sheet). Returns its index.
    @discardableResult
    public mutating func addTable(named name: String? = nil, anchor: CellRef = CellRef(row: 0, col: 0)) -> Int {
        var t = Table(name: name); t.anchor = anchor
        tables.append(t)
        return tables.count - 1
    }

    // MARK: - Titles

    public static let invalidNameCharacters: Set<Character> = ["\\", "*", "?", ":", "/", "[", "]"]

    /// Nil when the name is acceptable, else the reason.
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty { return "Title must have at least one character" }
        if let bad = name.first(where: invalidNameCharacters.contains) { return "Invalid character \(bad) found in sheet title" }
        return nil
    }

    /// When `name` (case-insensitively) matches an existing name, append the next free integer after the highest
    /// suffix already used with that stem (openpyxl `avoid_duplicate_name`).
    public static func uniqueName(_ name: String, among names: [String]) -> String {
        guard names.contains(where: { $0.lowercased() == name.lowercased() }) else { return name }
        var highest = 0
        for n in names where n.lowercased().hasPrefix(name.lowercased()) {
            let suffix = n.dropFirst(name.count)
            if suffix.isEmpty { continue }
            if suffix.allSatisfy(\.isNumber), let v = Int(suffix) { highest = Swift.max(highest, v) }
        }
        return name + String(highest + 1)
    }

    // MARK: - Cell API (forwarded to the default table)

    public var cells: [CellRef: Cell] {
        get { table.cells }
        set { table.cells = newValue }
    }
    public subscript(_ a1: String) -> CellValue? {
        get { table[a1] }
        set { table[a1] = newValue }
    }
    public subscript(_ row: Int, _ col: Int) -> CellValue? {
        get { table[row, col] }
        set { table[row, col] = newValue }
    }
    public subscript(_ ref: CellRef) -> CellValue? {
        get { table[ref] }
        set { table[ref] = newValue }
    }
    public subscript(cell ref: CellRef) -> Cell {
        get { table[cell: ref] }
        set { table[cell: ref] = newValue }
    }
    public subscript(cell a1: String) -> Cell {
        get { table[cell: a1] }
        set { table[cell: a1] = newValue }
    }
    public func cell(at ref: CellRef) -> Cell? { table.cell(at: ref) }
    public func cell(_ a1: String) -> Cell? { table.cell(a1) }
    public mutating func removeCell(at ref: CellRef) { table.removeCell(at: ref) }
    public mutating func removeCell(_ a1: String) { table.removeCell(a1) }

    public func style(at ref: CellRef) -> CellStyle { table.style(at: ref) }
    public func style(_ a1: String) -> CellStyle { table.style(a1) }
    public mutating func style(at ref: CellRef, _ update: (inout CellStyle) -> Void) { table.style(at: ref, update) }
    public mutating func style(_ a1: String, _ update: (inout CellStyle) -> Void) { table.style(a1, update) }
    public mutating func style(_ range: CellRange, _ update: (inout CellStyle) -> Void) { table.style(range, update) }

    public var extent: CellRange? { table.extent }
    public var rowCount: Int { table.rowCount }
    public var columnCount: Int { table.columnCount }
    public var dimensions: String { table.dimensions }

    public func rows(in range: CellRange? = nil) -> [[CellValue?]] { table.rows(in: range) }
    public func rows(in a1: String) -> [[CellValue?]] { table.rows(in: a1) }
    public func columns(in range: CellRange? = nil) -> [[CellValue?]] { table.columns(in: range) }
    public func columns(in a1: String) -> [[CellValue?]] { table.columns(in: a1) }
    public func values(in range: CellRange? = nil) -> [[CellValue?]] { table.values(in: range) }
    /// A lazy view over a rectangle (spec §14.4): `for row in sheet.range("A2:D100")`.
    public func range(_ range: CellRange) -> RangeView { table.range(range) }
    public func range(_ a1: String) -> RangeView { table.range(a1) }
    public func values(in a1: String) -> [[CellValue?]] { table.values(in: a1) }
    public func cells(in range: CellRange) -> [[Cell]] { table.cells(in: range) }
    public func column(_ name: String) -> [CellValue?] { table.column(name) }
    public func row(_ r: Int) -> [CellValue?] { table.row(r) }

    public var nextAppendRow: Int {
        get { table.nextAppendRow }
        set { table.nextAppendRow = newValue }
    }
    public mutating func append(_ values: [CellValue?]) { table.append(values) }
    public mutating func append(_ values: [Int: CellValue?]) { table.append(values) }
    public mutating func append(_ values: [String: CellValue?]) { table.append(values) }

    /// Inserts rows; formulas on this sheet follow. Use `Workbook.insertRows(inSheet:at:count:)` to update
    /// references from other sheets as well.
    public mutating func insertRows(at index: Int, count: Int = 1) { table.insertRows(at: index, count: count, sheetName: name) }
    public mutating func insertColumns(at index: Int, count: Int = 1) { table.insertColumns(at: index, count: count, sheetName: name) }
    public mutating func deleteRows(at index: Int, count: Int = 1) { table.deleteRows(at: index, count: count, sheetName: name) }
    public mutating func deleteColumns(at index: Int, count: Int = 1) { table.deleteColumns(at: index, count: count, sheetName: name) }
    @discardableResult
    public mutating func moveRange(_ range: CellRange, rows: Int = 0, cols: Int = 0) -> CellRange? { table.moveRange(range, rows: rows, cols: cols) }
    @discardableResult
    public mutating func moveRange(_ a1: String, rows: Int = 0, cols: Int = 0) -> CellRange? { table.moveRange(a1, rows: rows, cols: cols) }

    public var merges: [CellRange] {
        get { table.merges }
        set { table.merges = newValue }
    }
    public mutating func merge(_ a1: String) { table.merge(a1) }
    public mutating func merge(_ range: CellRange) { table.merge(range) }
    @discardableResult public mutating func unmerge(_ a1: String) -> Bool { table.unmerge(a1) }
    @discardableResult public mutating func unmerge(_ range: CellRange) -> Bool { table.unmerge(range) }
    public func mergedRange(containing ref: CellRef) -> CellRange? { table.mergedRange(containing: ref) }
    public func isMerged(_ a1: String) -> Bool { table.isMerged(a1) }
    public func isMerged(_ ref: CellRef) -> Bool { table.isMerged(ref) }

    public var rowDimensions: [Int: RowDimension] {
        get { table.rowDimensions }
        set { table.rowDimensions = newValue }
    }
    public var columnDimensions: [Int: ColumnDimension] {
        get { table.columnDimensions }
        set { table.columnDimensions = newValue }
    }
    public func rowDimension(_ row: Int) -> RowDimension { table.rowDimension(row) }
    public mutating func setRowDimension(_ row: Int, _ update: (inout RowDimension) -> Void) { table.setRowDimension(row, update) }
    public func columnDimension(_ col: Int) -> ColumnDimension { table.columnDimension(col) }
    public func columnDimension(_ name: String) -> ColumnDimension { table.columnDimension(name) }
    public mutating func setColumnDimension(_ col: Int, _ update: (inout ColumnDimension) -> Void) { table.setColumnDimension(col, update) }
    public mutating func setColumnDimension(_ name: String, _ update: (inout ColumnDimension) -> Void) { table.setColumnDimension(name, update) }
    public mutating func setWidth(_ width: Double?, ofColumn col: Int) { table.setWidth(width, ofColumn: col) }
    public mutating func setWidth(_ width: Double?, ofColumn name: String) { table.setWidth(width, ofColumn: name) }
    public mutating func setHeight(_ height: Double?, ofRow row: Int) { table.setHeight(height, ofRow: row) }
    public mutating func groupRows(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) { table.groupRows(range, outlineLevel: outlineLevel, hidden: hidden) }
    public mutating func groupColumns(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) { table.groupColumns(range, outlineLevel: outlineLevel, hidden: hidden) }
    public mutating func groupColumns(_ start: String, _ end: String, outlineLevel: Int = 1, hidden: Bool = false) { table.groupColumns(start, end, outlineLevel: outlineLevel, hidden: hidden) }
    public var columnGroups: [String] { table.columnGroups }

    // MARK: - Panes / printing

    /// Freeze at "B2" etc.; "" or "A1" clears.
    public mutating func freezePanes(at a1: String) { freezePanes = CellRef(a1) }
    /// The freeze cell as A1 text; assign "B2" or nil.
    public var freezePanesA1: String? {
        get { freezePanes?.a1 }
        set { freezePanes = newValue.flatMap(CellRef.init) }
    }
    /// The auto-filter range as A1 text; assign "A1:D100" or nil.
    public var autoFilterA1: String? {
        get { autoFilter?.a1 }
        set { autoFilter = newValue.flatMap(CellRange.init) }
    }

    /// The `_xlnm.Print_Titles` formula, e.g. `'Sheet'!$1:$2,'Sheet'!$C:$D`. Nil when unset.
    public var printTitles: String? {
        var parts: [String] = []
        let q = CellRef.quoteSheetName(name)
        if let r = printTitleRows { parts.append("\(q)!$\(r.lowerBound + 1):$\(r.upperBound + 1)") }
        if let c = printTitleColumns { parts.append("\(q)!$\(CellRef.columnName(c.lowerBound)):$\(CellRef.columnName(c.upperBound))") }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// The `_xlnm.Print_Area` formula, e.g. `'Sheet'!$A$1:$F$5`. Empty string when unset.
    public var printAreaFormula: String {
        printArea.map { "\(CellRef.quoteSheetName(name))!\($0.absoluteA1)" }.joined(separator: ",")
    }

    /// Sets the print area from "A1:F5" / "$A$1:$F$5" (multiple areas comma separated). Nil or "" clears.
    public mutating func setPrintArea(_ text: String?) {
        guard let text, !text.isEmpty else { printArea = []; return }
        printArea = text.split(separator: ",").compactMap { part in
            let s = String(part)
            return CellRange(CellRange.splitSheetName(s)?.cells ?? s).map { var r = $0; r.sheet = nil; return r }
        }
    }

    /// Parses a `_xlnm.Print_Titles` formula such as `'Sheet1'!$1:$2,$A:$A`.
    public mutating func setPrintTitles(_ formula: String?) {
        printTitleRows = nil; printTitleColumns = nil
        guard let formula else { return }
        for part in formula.split(separator: ",") {
            let cells = CellRange.splitSheetName(String(part))?.cells ?? String(part)
            guard let b = RangeBounds(cells) else { continue }
            if b.minCol == nil, let lo = b.minRow, let hi = b.maxRow { printTitleRows = lo...hi }
            else if b.minRow == nil, let lo = b.minCol, let hi = b.maxCol { printTitleColumns = lo...hi }
        }
    }

    /// Parses "1:4" into `printTitleRows` and "A:F" into `printTitleColumns`.
    public mutating func setPrintTitleRows(_ text: String?) {
        guard let text, let b = RangeBounds(text), let lo = b.minRow, let hi = b.maxRow, b.minCol == nil else { printTitleRows = nil; return }
        printTitleRows = lo...hi
    }
    public mutating func setPrintTitleColumns(_ text: String?) {
        guard let text, let b = RangeBounds(text), let lo = b.minCol, let hi = b.maxCol, b.minRow == nil else { printTitleColumns = nil; return }
        printTitleColumns = lo...hi
    }
}
