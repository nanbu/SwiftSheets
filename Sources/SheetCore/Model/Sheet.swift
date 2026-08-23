import Foundation

/// A sheet: a named canvas holding one or more tables (exactly one for XLSX / ODS) plus sheet-level options — view,
/// freeze panes, print setup, sheet-scoped names. The cell API of the default table is available directly on the
/// sheet, so XLSX / ODS code never has to mention `tables`.
public struct Sheet: Equatable, Sendable {
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
    /// What each filtered column lets through. Only meaningful together with `autoFilter`.
    public var filterColumns: [FilterColumn] = []
    /// The sort the auto-filter last applied. Excel records it; the rows are already in that order in the file.
    public var sortState: SortState?
    /// True when the file's auto-filter uses a kind `filterColumns` cannot say (colour, icon, dynamic, top 10, date
    /// groups). Such an `<autoFilter>` is kept as source XML and written back unchanged, so editing
    /// `filterColumns` on this sheet has no effect on a same-format write.
    public package(set) var hasUnmodelledFilters = false
    /// Rules for what ranges of cells accept (`<dataValidation>`), read and written alike (spec B.13).
    public var dataValidations: [DataValidation] = []
    /// True when the file this sheet was read from carries a validation the model cannot say — a rule with a vendor
    /// attribute outside the schema's own. Such a `<dataValidations>` block is kept as source XML and written back
    /// unchanged (and `dataValidations` is left empty rather than holding half of it), so rules set on this sheet
    /// have no effect on a same-format write — the writer says so with a `degraded` warning.
    ///
    /// Validations that live in the worksheet's `<extLst>` (Excel's `x14` form, the one a cross-sheet list source
    /// needs) are a different part of the file: they are preserved on their own and this flag says nothing of them.
    public package(set) var hasUnmodelledValidations = false
    /// The conditional formats of the sheet (`<conditionalFormatting>`) — cells that repaint themselves according
    /// to what they hold. Read and written alike.
    public var conditionalFormatting: [ConditionalFormatting] = []
    /// True when the file this sheet was read from carries a conditional format the model cannot say — a rule of an
    /// unknown kind, or one with the `<extLst>` extensions Excel writes for data bars it improved after the original
    /// schema. Such a block is kept as source XML and written back unchanged, and it is left out of
    /// `conditionalFormatting` rather than being half-read.
    public package(set) var hasUnmodelledConditionalFormats = false
    /// The named tables drawn over this sheet's cells (`xl/tables/*.xml`) — Excel's "Format as Table". Distinct
    /// from `tables`, which is the grid itself.
    public var excelTables: [ExcelTable] = []
    /// The pivot tables drawn on this sheet (`xl/pivotTables/*.xml`), each with the cache it reads.
    public var pivotTables: [PivotTable] = []
    /// What a protected sheet still lets people do (`<sheetProtection>`).
    public var protection = SheetProtection()
    /// Windows of a protected sheet that stay editable (`<protectedRanges>`).
    public var protectedRanges: [ProtectedRange] = []
    /// The sheet's "what if" scenarios (`<scenarios>`).
    public var scenarios = ScenarioList()
    public var properties = SheetProperties()
    public var view = SheetView()
    public var sheetFormat = SheetFormatProperties()
    public var pageMargins = PageMargins()
    public var pageSetup = PageSetup()
    public var printOptions = PrintOptions()
    public var headerFooter = HeaderFooter()
    /// Manual page breaks: the 0-based row / column index the break sits *above* / *left of*.
    public var rowBreaks: [Int] = []
    public var columnBreaks: [Int] = []
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

    /// Adds a named table over `ref`, taking its column names from the sheet's own first row. Returns the name it
    /// was given (sanitised, and de-duplicated against the tables already on this sheet).
    @discardableResult
    public mutating func addExcelTable(named name: String, over ref: CellRange,
                                       styleInfo: TableStyleInfo? = .default) -> String {
        var final = ExcelTable.sanitizedName(name)
        let taken = excelTables.map { $0.name.lowercased() }
        if taken.contains(final.lowercased()) {
            var n = 2
            while taken.contains((final + String(n)).lowercased()) { n += 1 }
            final += String(n)
        }
        let header = (ref.topLeft.col...ref.bottomRight.col).map { self[ref.topLeft.row, $0] }
        excelTables.append(ExcelTable(name: final, ref: ref, headerRow: header, styleInfo: styleInfo))
        return final
    }
    @discardableResult
    public mutating func addExcelTable(named name: String, over a1: String, styleInfo: TableStyleInfo? = .default) -> String? {
        guard let r = CellRange(a1) else { return nil }
        return addExcelTable(named: name, over: r, styleInfo: styleInfo)
    }
    /// The named table covering a cell, if any.
    public func excelTable(containing ref: CellRef) -> ExcelTable? { excelTables.first { $0.ref.contains(ref) } }

    /// Adds a pivot table summarising `source` on `sourceSheet`, laid out with its top-left cell at `anchor`.
    ///
    /// `rows`, `columns`, `values` and `filters` name source columns by their header text. The header row is read
    /// from `headerRow`; use `Workbook.addPivotTable` when the source is on another sheet and you would rather not
    /// fetch it yourself. Returns false when no field could be placed.
    @discardableResult
    public mutating func addPivotTable(named name: String, summarizing source: CellRange, on sourceSheet: String,
                                       headerRow: [CellValue?], at anchor: CellRef,
                                       rows: [String] = [], columns: [String] = [],
                                       values: [(String, PivotDataField.Function)] = [],
                                       filters: [String] = []) -> Bool {
        guard let pivot = PivotTable.summarizing(source, on: sourceSheet, headerRow: headerRow, named: name,
                                                 at: anchor, rows: rows, columns: columns, values: values,
                                                 filters: filters), pivot.validationError() == nil else { return false }
        pivotTables.append(pivot)
        return true
    }

    /// Adds one rule over a range, as its own block (openpyxl `ws.conditional_formatting.add`).
    public mutating func addConditionalFormatting(_ rule: ConditionalFormattingRule, over ranges: MultiCellRange) {
        var r = rule
        // a text rule's formula reads the range's own first cell, not A1
        if let anchor = ranges.sorted.first?.topLeft { r.anchorTextFormula(at: anchor.a1) }
        if r.priority == 1 { r.priority = (conditionalFormatting.flatMap(\.rules).map(\.priority).max() ?? 0) + 1 }
        if let i = conditionalFormatting.firstIndex(where: { $0.ranges == ranges }) { conditionalFormatting[i].rules.append(r) }
        else { conditionalFormatting.append(ConditionalFormatting(ranges: ranges, rules: [r])) }
    }
    /// Adds one rule over `"A2:D99"` (or `"A1 C1:C9"`); ignored when the text is not a range.
    public mutating func addConditionalFormatting(_ rule: ConditionalFormattingRule, over sqref: String) {
        guard let ranges = MultiCellRange(sqref) else { return }
        addConditionalFormatting(rule, over: ranges)
    }
    /// The rules covering a cell, most important first.
    public func conditionalFormattingRules(at ref: CellRef) -> [ConditionalFormattingRule] {
        conditionalFormatting.filter { $0.ranges.contains(ref) }.flatMap(\.rules).sorted { $0.priority < $1.priority }
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
    /// The cells that carry a note, in reading order. Notes are rare, so this walks the cells rather than keeping
    /// an index of them.
    public var notes: [(ref: CellRef, note: CellNote)] {
        table.cells.compactMap { ref, cell in cell.comment.map { (ref, $0) } }.sorted { $0.ref < $1.ref }
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
