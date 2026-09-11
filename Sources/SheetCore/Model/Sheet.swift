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
        didSet { if freezePanes == CellRef(row: 1, column: 1) { freezePanes = nil } }
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
    public var structuredTables: [StructuredTable] = []
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
    /// Manual page breaks, as the file spells them (`<brk id>`): the number of the row / column the break sits below / right of (B.61).
    public var rowBreaks: [Int] = []
    public var columnBreaks: [Int] = []
    /// Rows repeated at the top of every printed page (`_xlnm.Print_Titles`), by row number (1 = the first row).
    public var printTitleRows: ClosedRange<Int>?
    /// Columns repeated at the left of every printed page, by column number (1 = A).
    public var printTitleColumns: ClosedRange<Int>?
    /// The print area(s) (`_xlnm.Print_Area`).
    public var printArea: [CellRange] = []
    /// Sheet-scoped defined names: name → formula text.
    public var definedNames: [String: String] = [:]
    /// Informational: the `<dimension ref>` the file declared, if any.
    public var declaredDimension: CellRange?
    /// The sheet's pictures: those placed by `addImage` (spec Appendix B.32) and those read from the file's
    /// drawing (B.72). An untouched picture is written back as the bytes it arrived in.
    public var images: [SheetImage] = []
    /// The sheet's charts: those placed by `addChart` (spec Appendix B.34) and those read from the file's drawing
    /// (B.72) — a read chart may be of a kind the writers cannot draw, and is written back unchanged until it is
    /// edited.
    public var charts: [Chart] = []
    /// The sheet's shapes and text boxes: those placed by `addShape` / `addTextBox` (spec Appendix B.75) and
    /// those read from the file's drawing. An untouched shape is written back as the bytes it arrived in.
    public var shapes: [Shape] = []
    /// The sheet's sparkline groups (spec Appendix B.79): read from the file, or added with `addSparkline`.
    public var sparklines: [SparklineGroup] = []
    /// Material the reader kept for a lossless write-back (spec §6).
    package var preserved = SheetPreservation()

    /// Whether this sheet is a grid, was left unread by sheet selection, or is not a grid (Appendix B.46).
    /// Independent of `state` (tab visibility). Renaming and moving the sheet retain this state; a duplicate
    /// gets its own preservation, so the copy of an unread or non-grid sheet is a plain `.grid` holding the
    /// cells the model had. A chart sheet left out of the selection stays `.nonGrid` — the workbook
    /// relationship names its kind without the part being parsed. Adding cells to an unread or non-grid sheet
    /// does not make its source content readable; the existing write-back rules and loss warnings still apply.
    /// `.grid` does not promise that a read was complete: consult `Workbook.readWarnings` for cell limits and
    /// other reading losses.
    public var contentState: SheetContentState {
        if preserved.isUnread { return .unread }
        return preserved.foreignSheet == nil ? .grid : .nonGrid
    }

    public init(name: String) { self.name = name }

    public var isHidden: Bool {
        get { state != .visible }
        set { state = newValue ? .hidden : .visible }
    }
    /// The colour of the sheet's tab — the same `Color` every other colour in the model uses, so a theme or indexed
    /// colour read from a file is seen here too (spec Appendix B.59). `Color(hex: "1072BA")` for an RGB one. The
    /// value lives in `properties.tabColor`; this is that value's front door.
    public var tabColor: Color? {
        get { properties.tabColor }
        set { properties.tabColor = newValue }
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

    /// Adds a table (Numbers: several per sheet) whose A1 sits at `anchor` on the default grid. Returns its index.
    @discardableResult
    public mutating func addTable(named name: String? = nil, at anchor: CellRef = CellRef(row: 1, column: 1)) -> Int {
        var t = Table(name: name); t.anchor = anchor
        tables.append(t)
        return tables.count - 1
    }
    /// Adds a table at an exact point of a Numbers canvas (spec Appendix B.85). Returns its index.
    @discardableResult
    public mutating func addTable(named name: String? = nil, at position: CanvasPoint) -> Int {
        var t = Table(name: name); t.position = position
        t.anchor = CellRef(row: Int(position.y / 20) + 1, column: Int(position.x / 98) + 1)
        tables.append(t)
        return tables.count - 1
    }

    /// Adds a named table over `ref`, taking its column names from the sheet's own first row. Returns the name it
    /// was given (sanitised, and de-duplicated against the tables already on this sheet).
    @discardableResult
    public mutating func addStructuredTable(named name: String, over ref: CellRange,
                                       styleInfo: TableStyleInfo? = .default) -> String {
        var final = StructuredTable.sanitizedName(name)
        let taken = structuredTables.map { $0.name.lowercased() }
        if taken.contains(final.lowercased()) {
            var n = 2
            while taken.contains((final + String(n)).lowercased()) { n += 1 }
            final += String(n)
        }
        let header = (ref.topLeft.column...ref.bottomRight.column).map { self[ref.topLeft.row, $0] }
        structuredTables.append(StructuredTable(name: final, ref: ref, headerRow: header, styleInfo: styleInfo))
        return final
    }
    /// The A1 form. An unparsable range is a programming error, so the name always comes back (Appendix B.53).
    @discardableResult
    public mutating func addStructuredTable(named name: String, over a1: String, styleInfo: TableStyleInfo? = .default) -> String {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        return addStructuredTable(named: name, over: r, styleInfo: styleInfo)
    }
    /// The named table covering a cell, if any.
    public func structuredTable(containing ref: CellRef) -> StructuredTable? { structuredTables.first { $0.ref.contains(ref) } }

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
                                                 filters: filters), (try? pivot.validate()) != nil else { return false }
        pivotTables.append(pivot)
        return true
    }

    /// Adds one rule over a range, as its own block (openpyxl `ws.conditional_formatting.add`).
    public mutating func addConditionalFormatting(_ rule: ConditionalFormattingRule, over ranges: MultiCellRange) {
        var r = rule
        // a text rule's formula reads the range's own first cell, not A1
        if let anchor = ranges.sorted.first?.topLeft { r.anchorTextFormula(at: anchor.address) }
        if r.priority == 1 { r.priority = (conditionalFormatting.flatMap(\.rules).map(\.priority).max() ?? 0) + 1 }
        if let i = conditionalFormatting.firstIndex(where: { $0.ranges == ranges }) { conditionalFormatting[i].rules.append(r) }
        else { conditionalFormatting.append(ConditionalFormatting(ranges: ranges, rules: [r])) }
    }
    /// Adds one rule over `"A2:D99"` (or `"A1 C1:C9"`). An unparsable list is a programming error (Appendix B.53).
    public mutating func addConditionalFormatting(_ rule: ConditionalFormattingRule, over sqref: String) {
        guard let ranges = MultiCellRange(sqref) else { preconditionFailure("invalid range list \(sqref)") }
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
    public subscript(_ row: Int, _ column: Int) -> CellValue? {
        get { table[row, column] }
        set { table[row, column] = newValue }
    }
    public subscript(_ ref: CellRef) -> CellValue? {
        get { table[ref] }
        set { table[ref] = newValue }
    }
    /// The cells that carry a note, in reading order. Notes are rare, so this walks the cells rather than keeping
    /// an index of them.
    public var notes: [(ref: CellRef, note: CellNote)] {
        table.cells.compactMap { ref, cell in cell.note.map { (ref, $0) } }.sorted { $0.ref < $1.ref }
    }
    /// The threaded comments of the default table, by cell (spec Appendix B.80).
    public var threads: [(ref: CellRef, thread: CommentThread)] {
        table.cells.compactMap { ref, cell in cell.thread.map { (ref, $0) } }.sorted { $0.ref < $1.ref }
    }

    public subscript(cell ref: CellRef) -> Cell {
        get { table[cell: ref] }
        set { table[cell: ref] = newValue }
    }
    public subscript(cell a1: String) -> Cell {
        get { table[cell: a1] }
        set { table[cell: a1] = newValue }
    }
    public func cell(_ ref: CellRef) -> Cell? { table.cell(ref) }
    public func cell(_ a1: String) -> Cell? { table.cell(a1) }
    public mutating func removeCell(_ ref: CellRef) { table.removeCell(ref) }
    public mutating func removeCell(_ a1: String) { table.removeCell(a1) }

    /// The style of the cell at `ref`, or the default style when the cell holds none.
    public func style(at ref: CellRef) -> CellStyle { table.style(at: ref) }
    /// The style of the cell at an A1 address; the default style for an address that does not parse.
    public func style(_ a1: String) -> CellStyle { table.style(a1) }
    /// Changes the style of the cell at `ref` in place, creating the cell when it has none.
    public mutating func setStyle(at ref: CellRef, _ update: (inout CellStyle) -> Void) { table.setStyle(at: ref, update) }
    public mutating func setStyle(_ a1: String, _ update: (inout CellStyle) -> Void) { table.setStyle(a1, update) }
    public mutating func setStyle(_ range: CellRange, _ update: (inout CellStyle) -> Void) { table.setStyle(range, update) }

    public var extent: CellRange? { table.extent }
    public var rowCount: Int { table.rowCount }
    public var columnCount: Int { table.columnCount }
    /// "A1:J42", or "A1:A1" for an empty sheet (the `<dimension>` form).
    public var extentAddress: String { table.extentAddress }

    public func rows(in range: CellRange? = nil) -> [[CellValue?]] { table.rows(in: range) }
    public func rows(in a1: String) -> [[CellValue?]] { table.rows(in: a1) }
    public func columns(in range: CellRange? = nil) -> [[CellValue?]] { table.columns(in: range) }
    public func columns(in a1: String) -> [[CellValue?]] { table.columns(in: a1) }
    /// A lazy view over a rectangle (spec §14.4): `for row in sheet.range("A2:D100")`.
    public func range(_ range: CellRange) -> RangeView { table.range(range) }
    public func range(_ a1: String) -> RangeView { table.range(a1) }
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
    public mutating func moveRange(_ range: CellRange, rows: Int = 0, columns: Int = 0) -> CellRange? { table.moveRange(range, rows: rows, columns: columns) }
    @discardableResult
    public mutating func moveRange(_ a1: String, rows: Int = 0, columns: Int = 0) -> CellRange? { table.moveRange(a1, rows: rows, columns: columns) }

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
    public func columnDimension(_ column: Int) -> ColumnDimension { table.columnDimension(column) }
    public func columnDimension(_ name: String) -> ColumnDimension { table.columnDimension(name) }
    public mutating func setColumnDimension(_ column: Int, _ update: (inout ColumnDimension) -> Void) { table.setColumnDimension(column, update) }
    public mutating func setColumnDimension(_ name: String, _ update: (inout ColumnDimension) -> Void) { table.setColumnDimension(name, update) }
    public mutating func setWidth(_ width: Double?, ofColumn column: Int) { table.setWidth(width, ofColumn: column) }
    public mutating func setWidth(_ width: Double?, ofColumn name: String) { table.setWidth(width, ofColumn: name) }
    public mutating func setHeight(_ height: Double?, ofRow row: Int) { table.setHeight(height, ofRow: row) }
    /// Places a picture at one cell (spec Appendix B.32). `.resizeCellToFit` grows the column and row to the
    /// image's pixel size here and now — the writer never changes the model behind your back — and the picture
    /// itself is stored `.fitCell`, so it fills the cell it just shaped.
    public mutating func addImage(_ image: SheetImage, at ref: CellRef, sizing: ImagePlacement = .original) {
        var img = image
        switch sizing {
        case .original: img.anchor = .cell(ref, sizing: .original)
        case .scaled(let w, let h): img.anchor = .cell(ref, sizing: .scaled(width: w, height: h))
        case .fitCell: img.anchor = .cell(ref, sizing: .fitCell)
        case .resizeCellToFit:
            setWidth(CellPixels.columnWidth(forPixels: Double(image.pixelWidth)), ofColumn: ref.column)
            setHeight(CellPixels.rowHeight(forPixels: Double(image.pixelHeight)), ofRow: ref.row)
            img.anchor = .cell(ref, sizing: .fitCell)
        }
        images.append(img)
    }
    /// A1 form of `addImage(_:at:sizing:)`. An unparseable reference is a programmer error, as with subscripts.
    public mutating func addImage(_ image: SheetImage, at a1: String, sizing: ImagePlacement = .original) {
        guard let r = CellRef(a1) else { preconditionFailure("invalid cell reference \(a1)") }
        addImage(image, at: r, sizing: sizing)
    }
    /// Stretches a picture over a range (both corners follow their cells).
    public mutating func addImage(_ image: SheetImage, over range: CellRange) {
        var img = image
        img.anchor = .span(range)
        images.append(img)
    }
    /// A1 form of `addImage(_:over:)`.
    public mutating func addImage(_ image: SheetImage, over a1: String) {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        addImage(image, over: r)
    }

    public mutating func groupRows(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) { table.groupRows(range, outlineLevel: outlineLevel, hidden: hidden) }
    public mutating func groupColumns(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) { table.groupColumns(range, outlineLevel: outlineLevel, hidden: hidden) }
    public mutating func groupColumns(_ start: String, _ end: String, outlineLevel: Int = 1, hidden: Bool = false) { table.groupColumns(start, end, outlineLevel: outlineLevel, hidden: hidden) }
    public var columnGroups: [String] { table.columnGroups }

    // MARK: - Panes / printing

    /// The `_xlnm.Print_Titles` formula, e.g. `'Sheet'!$1:$2,'Sheet'!$C:$D` — the A1-string twin of `printTitleRows`
    /// and `printTitleColumns`. Nil when neither is set; assigning nil clears both.
    ///
    /// The setter takes the formula exactly as a file saves it, and is the reader's own way in
    /// (`WorkbookReader.assignLocalNames`), so it is **lenient**: a part that will not parse is dropped rather than
    /// treated as a programming error. Spec Appendix B.53 draws the line there: the strict rule is for coordinates
    /// a programmer writes, not for text that came out of a file.
    public var printTitlesFormula: String? {
        get {
            var parts: [String] = []
            let q = CellRef.quoteSheetName(name)
            if let r = printTitleRows { parts.append("\(q)!$\(r.lowerBound):$\(r.upperBound)") }
            if let c = printTitleColumns { parts.append("\(q)!$\(CellRef.columnName(c.lowerBound)):$\(CellRef.columnName(c.upperBound))") }
            return parts.isEmpty ? nil : parts.joined(separator: ",")
        }
        set {
            printTitleRows = nil; printTitleColumns = nil
            guard let newValue else { return }
            for part in newValue.split(separator: ",") {
                let cells = CellRange.splitSheetName(String(part))?.cells ?? String(part)
                guard let b = RangeBounds(cells) else { continue }
                if b.minColumn == nil, let lo = b.minRow, let hi = b.maxRow { printTitleRows = lo...hi }
                else if b.minRow == nil, let lo = b.minColumn, let hi = b.maxColumn { printTitleColumns = lo...hi }
            }
        }
    }

    /// The `_xlnm.Print_Area` formula, e.g. `'Sheet'!$A$1:$F$5` (several areas comma separated) — the A1-string twin
    /// of `printArea`. Nil when unset; assigning nil or "" clears.
    ///
    /// Lenient for the same reason as `printTitlesFormula`: a workbook whose print area is `MySheet!#REF!` — what
    /// Excel leaves behind when the sheet it pointed at is deleted — has to open, so a part that will not parse is
    /// dropped.
    public var printAreaFormula: String? {
        get { printArea.isEmpty ? nil : printArea.map { "\(CellRef.quoteSheetName(name))!\($0.absoluteAddress)" }.joined(separator: ",") }
        set {
            guard let newValue, !newValue.isEmpty else { printArea = []; return }
            printArea = newValue.split(separator: ",").compactMap { part in
                let s = String(part)
                return CellRange(CellRange.splitSheetName(s)?.cells ?? s).map { var r = $0; r.sheet = nil; return r }
            }
        }
    }
}
