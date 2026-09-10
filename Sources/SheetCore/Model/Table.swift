import Foundation

/// A rectangular grid of cells with its row / column formatting and merges. XLSX and ODS sheets hold exactly one
/// (the `Sheet` API forwards to it); Numbers sheets may hold several, each anchored somewhere on the canvas.
/// Equatable, not Hashable: two tables are compared in tests and in round-trip checks, but hashing one means
/// hashing every cell in it — an invitation to put a whole sheet in a `Set` and pay for it silently.
public struct Table: Equatable, Sendable {
    public var name: String?
    /// Where the table's A1 sits on the sheet canvas (Numbers); always A1 for XLSX / ODS.
    public var anchor = CellRef(row: 1, column: 1)
    /// Sparse: only cells that hold a value, a style, a link or a note exist here.
    ///
    /// Assigning or mutating this map directly is allowed, but it costs the table its knowledge of the used range —
    /// the next `extent` (and everything built on it: `rowCount`, `row(_:)`, `rows(in:)`, every writer) has to scan
    /// all of it again. The typed paths — the subscripts, `append`, `store(_:at:)` — keep that knowledge instead.
    public var cells: [CellRef: Cell] {
        get { storage }
        _modify {
            extentState = .unknown
            yield &storage
        }
        set {
            storage = newValue
            extentState = .unknown
        }
    }

    private var storage: [CellRef: Cell] = [:]

    /// What is known about the used range. Recomputing it is a scan of every cell, and `rowCount` sits in enough
    /// loops that doing it per row turns an export into an O(n²) walk.
    private enum ExtentState: Sendable {
        case empty
        case range(CellRange)
        /// Someone edited `cells` directly; the next read has to work it out.
        case unknown
    }
    private var extentState: ExtentState = .empty

    /// Writes (or removes, with `nil`) a cell and keeps the used range in step. Removing from the edge of the range
    /// gives up on it rather than rescanning: the answer is only needed when someone asks.
    private mutating func put(_ cell: Cell?, at ref: CellRef) {
        if let cell {
            // every write lands here — a value, a style, a note — so this is where row 0 / column 0 is refused (B.61)
            precondition(ref.row >= 1 && ref.column >= 1, "rows and columns count from 1 (row \(ref.row), column \(ref.column))")
            storage[ref] = cell
            switch extentState {
            case .empty: extentState = .range(CellRange(ref))
            case .range(let r):
                if !r.contains(ref) {
                    extentState = .range(CellRange(minRow: Swift.min(r.minRow, ref.row), minColumn: Swift.min(r.minColumn, ref.column),
                                                   maxRow: Swift.max(r.maxRow, ref.row), maxColumn: Swift.max(r.maxColumn, ref.column)))
                }
            case .unknown: break
            }
        } else {
            guard storage.removeValue(forKey: ref) != nil else { return }
            if storage.isEmpty { extentState = .empty; return }
            if case .range(let r) = extentState,
               ref.row == r.minRow || ref.row == r.maxRow || ref.column == r.minColumn || ref.column == r.maxColumn {
                extentState = .unknown   // the bounds may have shrunk; only a scan can say
            }
        }
    }

    /// Stores a cell exactly as given — a reader keeps `<c r="A1"/>` even though it carries nothing — without the
    /// blank-dropping the subscripts do, and with the used range kept up to date.
    package mutating func store(_ cell: Cell, at ref: CellRef) { put(cell, at: ref) }

    public static func == (a: Table, b: Table) -> Bool {
        a.name == b.name && a.anchor == b.anchor && a.storage == b.storage && a.rowDimensions == b.rowDimensions
            && a.columnDimensions == b.columnDimensions && a.merges == b.merges && a.nextAppendRow == b.nextAppendRow
    }

    public var rowDimensions: [Int: RowDimension] = [:]
    public var columnDimensions: [Int: ColumnDimension] = [:]
    public var merges: [CellRange] = []
    /// Array formulas by their anchor cell: one formula that fills a whole range (`{=TRANSPOSE(A1:C1)}` — entered
    /// in Excel with ctrl-shift-enter). The anchor holds the formula; the other cells of the range hold its
    /// results. Without the range Excel treats the formula as an ordinary one, which changes what it computes.
    public var arrayFormulas: [CellRef: CellRange] = [:]
    /// The tracing arrows ODF keeps on a cell (`table:detective`), by the cell they hang on. A sparse map rather
    /// than a field of `Cell`: this is rare, and a `Cell` is the type whose size the whole library budgets for
    /// (spec Appendix B.17). ODF only — Excel draws the same arrows but never saves them.
    public var detective: [CellRef: CellDetective] = [:]
    /// The number of the row `append` writes next (1 = the first row). The reader sets it past the last row of the file.
    public var nextAppendRow = 1

    public init(name: String? = nil) { self.name = name }

    // MARK: - Values

    /// The value at an A1 coordinate; nil for an absent or empty cell. Assigning nil clears the value (and drops the
    /// cell when nothing else is set). Invalid coordinates are a programming error.
    public subscript(_ a1: String) -> CellValue? {
        get { CellRef(a1).flatMap { cells[$0]?.value } }
        set {
            guard let r = CellRef(a1) else { preconditionFailure("invalid cell reference \(a1)") }
            self[r] = newValue
        }
    }

    /// Row and column as the sheet shows them (`table[1, 1]` is A1).
    public subscript(_ row: Int, _ column: Int) -> CellValue? {
        get { cells[CellRef(row: row, column: column)]?.value }
        set { self[CellRef(row: row, column: column)] = newValue }
    }

    public subscript(_ ref: CellRef) -> CellValue? {
        get { cells[ref]?.value }
        set {
            precondition(ref.row >= 1 && ref.column >= 1, "rows and columns count from 1 (row \(ref.row), column \(ref.column))")
            if newValue == nil, storage[ref] == nil { return }
            var c = storage[ref] ?? Cell()
            c.value = newValue
            put(c.isBlank ? nil : c, at: ref)
            nextAppendRow = Swift.max(nextAppendRow, ref.row + 1)   // `append` continues below, as openpyxl's _current_row does
        }
    }

    /// The whole cell (value + style + link + note); an empty `Cell()` when absent. Assigning a blank cell removes it.
    public subscript(cell ref: CellRef) -> Cell {
        get { cells[ref] ?? Cell() }
        set { put(newValue.isBlank ? nil : newValue, at: ref); nextAppendRow = Swift.max(nextAppendRow, ref.row + 1) }
    }
    public subscript(cell a1: String) -> Cell {
        get { CellRef(a1).map { self[cell: $0] } ?? Cell() }
        set { guard let r = CellRef(a1) else { preconditionFailure("invalid cell reference \(a1)") }; self[cell: r] = newValue }
    }

    /// The cell if it exists, without creating it.
    public func cell(_ ref: CellRef) -> Cell? { cells[ref] }
    public func cell(_ a1: String) -> Cell? { CellRef(a1).flatMap { cells[$0] } }

    /// Removes a cell entirely.
    public mutating func removeCell(_ ref: CellRef) { put(nil, at: ref) }
    public mutating func removeCell(_ a1: String) {
        guard let r = CellRef(a1) else { preconditionFailure("invalid cell reference \(a1)") }
        put(nil, at: r)
    }

    // MARK: - Styles

    public func style(_ ref: CellRef) -> CellStyle { cells[ref]?.style ?? .default }
    public func style(_ a1: String) -> CellStyle { CellRef(a1).map(style(_:)) ?? .default }

    /// Edits the style of one cell in place (the cell is created if needed). Named `setStyle` rather than `style`
    /// so that taking a style and changing one are different words, as they are for a row's or a column's
    /// dimension (spec Appendix B.53).
    public mutating func setStyle(_ ref: CellRef, _ update: (inout CellStyle) -> Void) {
        var c = storage[ref] ?? Cell()
        update(&c.style)
        put(c.isBlank ? nil : c, at: ref)
    }
    /// Edits the style of every cell in a range ("A1:D1") or of a single cell ("A1").
    public mutating func setStyle(_ a1: String, _ update: (inout CellStyle) -> Void) {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        setStyle(r, update)
    }
    public mutating func setStyle(_ range: CellRange, _ update: (inout CellStyle) -> Void) {
        // cells of a range usually start from the same style and end at the same one, so the result is interned:
        // styling A1:D1000 should cost one `CellStyle`, not a thousand copies of it
        var made: [CellStyle: SharedStyle] = [:]
        for ref in range.cells {
            var c = storage[ref] ?? Cell()
            var style = c.style
            update(&style)
            if style == .default {
                c.style = style
            } else if let shared = made[style] {
                c.sharedStyle = shared
            } else {
                let shared = SharedStyle(style)
                made[style] = shared
                c.sharedStyle = shared
            }
            put(c.isBlank ? nil : c, at: ref)
        }
    }

    // MARK: - Extent

    /// The smallest range holding every existing cell; nil when the table is empty. Known without a scan unless
    /// `cells` was edited directly.
    public var extent: CellRange? {
        switch extentState {
        case .empty: return storage.isEmpty ? nil : scannedExtent()
        case .range(let r): return r
        case .unknown: return scannedExtent()
        }
    }

    private func scannedExtent() -> CellRange? {
        guard let first = storage.keys.first else { return nil }
        var r0 = first.row, r1 = first.row, c0 = first.column, c1 = first.column
        for k in storage.keys { r0 = Swift.min(r0, k.row); r1 = Swift.max(r1, k.row); c0 = Swift.min(c0, k.column); c1 = Swift.max(c1, k.column) }
        return CellRange(minRow: r0, minColumn: c0, maxRow: r1, maxColumn: c1)
    }
    /// Rows from the top through the last used row (0 when empty) — also the number of the last used row.
    public var rowCount: Int { extent?.maxRow ?? 0 }
    /// Columns from the left through the last used column (0 when empty) — also the number of the last used column.
    public var columnCount: Int { extent?.maxColumn ?? 0 }
    /// "A1:J42", or "A1:A1" for an empty table (the `<dimension>` form).
    public var dimensions: String { extent.map { $0.isSingleCell ? $0.a1 + ":" + $0.a1 : $0.a1 } ?? "A1:A1" }

    // MARK: - Iteration

    private func bounds(_ range: CellRange?) -> CellRange? {
        if let range { return range }
        guard let e = extent else { return nil }
        return CellRange(minRow: 1, minColumn: 1, maxRow: e.maxRow, maxColumn: e.maxColumn)   // from A1, like openpyxl's iter_rows
    }

    /// Values row by row (nil for empty cells). Without a range: A1 through the last used cell; nothing when empty.
    public func rows(in range: CellRange? = nil) -> [[CellValue?]] {
        guard let b = bounds(range) else { return [] }
        return (b.minRow...b.maxRow).map { r in (b.minColumn...b.maxColumn).map { c in cells[CellRef(row: r, column: c)]?.value } }
    }
    public func rows(in a1: String) -> [[CellValue?]] { CellRange(a1).map { rows(in: $0) } ?? [] }

    /// Values column by column.
    public func columns(in range: CellRange? = nil) -> [[CellValue?]] {
        guard let b = bounds(range) else { return [] }
        return (b.minColumn...b.maxColumn).map { c in (b.minRow...b.maxRow).map { r in cells[CellRef(row: r, column: c)]?.value } }
    }
    public func columns(in a1: String) -> [[CellValue?]] { CellRange(a1).map { columns(in: $0) } ?? [] }

    /// A lazy view over a rectangle: rows on demand, nothing materialised, the cells shared rather than copied
    /// (spec §14.4). `rows(in:)` is the eager form of the same thing.
    public func range(_ range: CellRange) -> RangeView { RangeView(table: self, range: range) }
    /// The same from an A1 range string ("A1:C3"). An unparsable string is a programming error, as it is for `style`.
    public func range(_ a1: String) -> RangeView {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        return range(r)
    }


    /// The cells of a rectangle, row by row (empty `Cell()` where none exists).
    public func cells(in range: CellRange) -> [[Cell]] {
        range.rows.map { $0.map { self[cell: $0] } }
    }

    /// One whole column of values by name ("C"), from row 1 through the last used row (index 0 is row 1).
    public func column(_ name: String) -> [CellValue?] {
        guard let c = CellRef.columnIndex(name), rowCount > 0 else { return [] }
        return (1...rowCount).map { cells[CellRef(row: $0, column: c)]?.value }
    }
    /// One whole row of values, from column A through the last used column (index 0 is column A).
    public func row(_ r: Int) -> [CellValue?] {
        guard columnCount > 0 else { return [] }
        return (1...columnCount).map { cells[CellRef(row: r, column: $0)]?.value }
    }

    // MARK: - Appending

    /// Writes a row after the last appended / loaded row. `nil` entries leave cells untouched; an empty array just
    /// advances the row.
    public mutating func append(_ values: [CellValue?]) {
        let r = nextAppendRow
        for (i, v) in values.enumerated() where v != nil { self[CellRef(row: r, column: i + 1)] = v }
        nextAppendRow = r + 1
    }
    /// Column number (1 = A) → value.
    public mutating func append(_ values: [Int: CellValue?]) {
        let r = nextAppendRow
        for (c, v) in values where v != nil { self[CellRef(row: r, column: c)] = v }
        nextAppendRow = r + 1
    }
    /// Column name → value.
    public mutating func append(_ values: [String: CellValue?]) {
        let r = nextAppendRow
        for (n, v) in values where v != nil { if let c = CellRef.columnIndex(n) { self[CellRef(row: r, column: c)] = v } }
        nextAppendRow = r + 1
    }

    // MARK: - Structure

    /// Inserts `count` empty rows before row `index`. Cells, row formatting, merges and same-sheet formula references
    /// below move down. `sheetName` tells which qualified references belong to this table's sheet.
    public mutating func insertRows(at index: Int, count: Int = 1, sheetName: String? = nil) {
        shift(axis: .rows, at: index, delta: count, sheetName: sheetName)
    }
    public mutating func insertColumns(at index: Int, count: Int = 1, sheetName: String? = nil) {
        shift(axis: .columns, at: index, delta: count, sheetName: sheetName)
    }
    /// Deletes `count` rows starting at `index`; references into them become `#REF!`.
    public mutating func deleteRows(at index: Int, count: Int = 1, sheetName: String? = nil) {
        shift(axis: .rows, at: index, delta: -count, sheetName: sheetName)
    }
    public mutating func deleteColumns(at index: Int, count: Int = 1, sheetName: String? = nil) {
        shift(axis: .columns, at: index, delta: -count, sheetName: sheetName)
    }

    private mutating func shift(axis: FormulaExpr.Axis, at index: Int, delta: Int, sheetName: String?) {
        guard delta != 0, index >= 1 else { return }
        let deletedEnd = index - delta   // exclusive, for deletions
        func moved(_ v: Int) -> Int? {
            if delta > 0 { return v >= index ? v + delta : v }
            if v < index { return v }
            return v < deletedEnd ? nil : v + delta
        }
        var newCells: [CellRef: Cell] = [:]
        newCells.reserveCapacity(storage.count)
        for (ref, cell) in storage {
            let key = axis == .rows ? ref.row : ref.column
            guard let m = moved(key) else { continue }
            newCells[axis == .rows ? CellRef(row: m, column: ref.column) : CellRef(row: ref.row, column: m)] = cell
        }
        storage = newCells
        extentState = .unknown
        // formulas everywhere in the table follow (unqualified refs and refs naming this sheet)
        let own = sheetName
        for (ref, cell) in storage {
            guard case .formula(let f, let cached)? = cell.value else { continue }
            let shifted = f.shiftingReferences(axis: axis, at: index, delta: delta) { $0 == nil || $0 == own }
            if shifted != f { var c = cell; c.value = .formula(shifted, cached: cached); storage[ref] = c }
        }
        if axis == .rows {
            var dims: [Int: RowDimension] = [:]
            for (r, d) in rowDimensions { if let m = moved(r) { dims[m] = d } }
            rowDimensions = dims
        } else {
            var dims: [Int: ColumnDimension] = [:]
            for (c, d) in columnDimensions { if let m = moved(c) { dims[m] = d } }
            columnDimensions = dims
        }
        merges = merges.compactMap { m in
            let lo = axis == .rows ? m.minRow : m.minColumn, hi = axis == .rows ? m.maxRow : m.maxColumn
            var nlo: Int, nhi: Int
            if delta > 0 { nlo = lo >= index ? lo + delta : lo; nhi = hi >= index ? hi + delta : hi }
            else {
                if hi < index { nlo = lo; nhi = hi }
                else if lo >= deletedEnd { nlo = lo + delta; nhi = hi + delta }
                else { nlo = lo < index ? lo : index; nhi = hi >= deletedEnd ? hi + delta : index - 1 }
                guard nhi >= nlo, !(nlo == nhi && (axis == .rows ? m.minColumn == m.maxColumn : m.minRow == m.maxRow)) else { return nil }
            }
            return axis == .rows ? CellRange(minRow: nlo, minColumn: m.minColumn, maxRow: nhi, maxColumn: m.maxColumn, sheet: m.sheet)
                                 : CellRange(minRow: m.minRow, minColumn: nlo, maxRow: m.maxRow, maxColumn: nhi, sheet: m.sheet)
        }
        if axis == .rows { nextAppendRow = rowCount + 1 }
    }

    /// Moves the cells of a range by `rows` / `cols`, overwriting whatever is there (openpyxl `move_range`).
    /// Formulas inside the moved block are not translated. Returns the rebased range (nil when it would go negative).
    @discardableResult
    public mutating func moveRange(_ range: CellRange, rows: Int = 0, columns: Int = 0) -> CellRange? {
        guard rows != 0 || columns != 0 else { return range }
        guard let target = range.shifted(rows: rows, columns: columns) else { return nil }
        let order: [CellRef]
        if rows != 0 { order = rows > 0 ? range.rows.reversed().flatMap { $0 } : range.rows.flatMap { $0 } }
        else { order = columns > 0 ? range.columns.reversed().flatMap { $0 } : range.columns.flatMap { $0 } }
        for ref in order {
            let cell = storage[ref]
            put(nil, at: ref)
            put(cell, at: ref.shifted(rows: rows, columns: columns))
        }
        return target
    }
    /// Nil still means "the move would go negative"; an unparsable string is a programming error (Appendix B.53).
    @discardableResult
    public mutating func moveRange(_ a1: String, rows: Int = 0, columns: Int = 0) -> CellRange? {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        return moveRange(r, rows: rows, columns: columns)
    }

    // MARK: - Merges

    /// Merges a range. Only the top-left cell keeps its value; the others are cleared and the top-left cell's border
    /// is extended along the edges of the merged area (openpyxl behaviour, which matches what Excel displays).
    public mutating func merge(_ a1: String) {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        merge(r)
    }
    public mutating func merge(_ range: CellRange) {
        var r = range; r.sheet = nil
        merges.append(r)
        cleanMergedRange(r)
    }

    /// The refs inside a range that this table actually holds a cell for, found without walking the whole rectangle
    /// when the rectangle is the bigger of the two. A merge may legitimately span millions of cells (`A1:XFD1048576`
    /// is a single `<mergeCell>`), so enumerating the rectangle — let alone storing a `Cell` per position — is what
    /// turns a two-kilobyte file into hundreds of megabytes.
    func existingRefs(in r: CellRange) -> [CellRef] {
        let rows = r.maxRow - r.minRow + 1, cols = r.maxColumn - r.minColumn + 1
        // `rows * cols <= cells.count`, written so that a hostile range cannot overflow the multiplication
        if rows > 0, cols > 0, rows <= storage.count / Swift.max(cols, 1) {
            var out: [CellRef] = []
            for row in r.minRow...r.maxRow {
                for col in r.minColumn...r.maxColumn {
                    let ref = CellRef(row: row, column: col)
                    if storage[ref] != nil { out.append(ref) }
                }
            }
            return out
        }
        return storage.keys.filter { r.contains($0) }
    }

    /// Clears the non-anchor cells of a merged range and formats its edges (openpyxl `_clean_merge_range`).
    package mutating func cleanMergedRange(_ r: CellRange) {
        for ref in existingRefs(in: r) where ref != r.topLeft {
            if var c = storage[ref] { c.value = nil; c.hyperlink = nil; c.note = nil; put(c.isBlank ? nil : c, at: ref) }
        }
        formatMergedRange(r)
    }

    /// How many cells a merge may bring into existence to carry the anchor's edge borders and protection. Real
    /// documents merge title rows and small blocks; `A1:XFD1048576` is a single `<mergeCell>` element in a file
    /// anyone can hand us. Past this many, the formatting reaches only the cells that already exist — the same
    /// "a giant repeat is padding, not content" judgement the ODS reader makes for RLE runs (spec §8.3).
    package static let maxMaterialisedMergeCells = 65_536

    /// openpyxl `MergedCellRange`: the anchor takes the bottom / right sides from the bottom-right cell, then the cells
    /// along each edge take that side of the anchor's border (their own settings win), and every cell inherits the
    /// anchor's protection.
    ///
    /// Nothing is created that would carry nothing — apart from the anchor, which is one cell and which the ODS
    /// writer needs in order to write the span at all. The edges are only walked when that side really has a border
    /// style, the default protection is never written into absent cells (it is what they already have), and both stop
    /// materialising past `maxMaterialisedMergeCells`. The interior of a merge shows the anchor's cell either way.
    mutating func formatMergedRange(_ r: CellRange) {
        var start = self[cell: r.topLeft]
        if !r.isSingleCell, let end = storage[r.bottomRight] {
            start.border = start.border.combined(with: Border(right: end.border.right, bottom: end.border.bottom))
        }
        put(start, at: r.topLeft)   // the anchor always exists: it is one cell, and the ODS writer hangs the span on it
        // the edge lists are built only for sides that have a style — `r.left` on a full-sheet merge is a million refs
        let edges: [(side: Side, border: Border, refs: () -> [CellRef])] = [
            (start.border.top, Border(top: start.border.top), { r.top }),
            (start.border.left, Border(left: start.border.left), { r.left }),
            (start.border.right, Border(right: start.border.right), { r.right }),
            (start.border.bottom, Border(bottom: start.border.bottom), { r.bottom }),
        ]
        for (side, border, refs) in edges where side.style != nil {
            let list = refs()
            let materialise = list.count <= Table.maxMaterialisedMergeCells
            for ref in list {
                if !materialise, storage[ref] == nil { continue }
                var c = self[cell: ref]
                c.border = c.border.combined(with: border)
                if !c.isBlank { put(c, at: ref) }
            }
        }
        let protection = start.protection
        guard protection != Protection() else { return }   // the default protection is what an absent cell already has
        for ref in refsToFormat(in: r) {
            var c = self[cell: ref]
            guard c.protection != protection else { continue }
            c.protection = protection
            put(c, at: ref)
        }
    }

    /// Every position of a small range (openpyxl's behaviour: placeholders are created), but only the positions that
    /// already hold a cell once the range grows past `maxMaterialisedMergeCells`.
    private func refsToFormat(in r: CellRange) -> [CellRef] {
        let rows = r.maxRow - r.minRow + 1, cols = r.maxColumn - r.minColumn + 1
        // `rows * cols <= maxMaterialisedMergeCells`, written so that a hostile range cannot overflow the product
        if rows > 0, cols > 0, rows <= Table.maxMaterialisedMergeCells / Swift.max(cols, 1) { return r.cells }
        return existingRefs(in: r)
    }

    /// Unmerges exactly this range; false when it was not merged. An unparsable string is a programming error.
    @discardableResult
    public mutating func unmerge(_ a1: String) -> Bool {
        guard let r = CellRange(a1) else { preconditionFailure("invalid range \(a1)") }
        return unmerge(r)
    }
    @discardableResult
    public mutating func unmerge(_ range: CellRange) -> Bool {
        guard let i = merges.firstIndex(where: { $0.a1 == range.a1 }) else { return false }
        merges.remove(at: i)
        for ref in existingRefs(in: range) where ref != range.topLeft { put(nil, at: ref) }   // openpyxl drops the MergedCell placeholders
        return true
    }

    /// The merged range containing a cell, if any.
    public func mergedRange(containing ref: CellRef) -> CellRange? { merges.first { $0.contains(ref) } }
    public func isMerged(_ a1: String) -> Bool { CellRef(a1).map { mergedRange(containing: $0) != nil } ?? false }
    public func isMerged(_ ref: CellRef) -> Bool { mergedRange(containing: ref) != nil }

    // MARK: - Dimensions

    public func rowDimension(_ row: Int) -> RowDimension { rowDimensions[row] ?? RowDimension() }
    public mutating func setRowDimension(_ row: Int, _ update: (inout RowDimension) -> Void) {
        var d = rowDimension(row); update(&d); rowDimensions[row] = d.isDefault ? nil : d
    }
    public func columnDimension(_ column: Int) -> ColumnDimension { columnDimensions[column] ?? ColumnDimension() }
    public func columnDimension(_ name: String) -> ColumnDimension { CellRef.columnIndex(name).map(columnDimension) ?? ColumnDimension() }
    public mutating func setColumnDimension(_ column: Int, _ update: (inout ColumnDimension) -> Void) {
        var d = columnDimension(column); update(&d); columnDimensions[column] = d.isDefault ? nil : d
    }
    public mutating func setColumnDimension(_ name: String, _ update: (inout ColumnDimension) -> Void) {
        guard let c = CellRef.columnIndex(name) else { preconditionFailure("invalid column name \(name)") }
        setColumnDimension(c, update)
    }
    /// Column width in characters.
    public mutating func setWidth(_ width: Double?, ofColumn column: Int) { setColumnDimension(column) { $0.width = width } }
    public mutating func setWidth(_ width: Double?, ofColumn name: String) { setColumnDimension(name) { $0.width = width } }
    /// Row height in points.
    public mutating func setHeight(_ height: Double?, ofRow row: Int) { setRowDimension(row) { $0.height = height } }

    /// Puts rows `range` in an outline group.
    public mutating func groupRows(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) {
        for r in range { setRowDimension(r) { $0.outlineLevel = outlineLevel; $0.hidden = hidden } }
    }
    /// Puts columns `range` (column numbers, 1 = A) in an outline group.
    public mutating func groupColumns(_ range: ClosedRange<Int>, outlineLevel: Int = 1, hidden: Bool = false) {
        for c in range { setColumnDimension(c) { $0.outlineLevel = outlineLevel; $0.hidden = hidden } }
    }
    /// Puts columns "F"…"K" in an outline group.
    /// An unparsable column name is a programming error; `start` after `end` is simply an empty group.
    public mutating func groupColumns(_ start: String, _ end: String, outlineLevel: Int = 1, hidden: Bool = false) {
        guard let a = CellRef.columnIndex(start) else { preconditionFailure("invalid column name \(start)") }
        guard let b = CellRef.columnIndex(end) else { preconditionFailure("invalid column name \(end)") }
        guard a <= b else { return }
        groupColumns(a...b, outlineLevel: outlineLevel, hidden: hidden)
    }
    /// Runs of adjacent outlined columns as "F:K" strings.
    public var columnGroups: [String] {
        let outlined = columnDimensions.compactMap { k, v in v.outlineLevel > 0 ? k : nil }.sorted()
        var groups: [(Int, Int)] = []
        for c in outlined {
            if let last = groups.last, last.1 == c - 1 { groups[groups.count - 1].1 = c } else { groups.append((c, c)) }
        }
        return groups.map { "\(CellRef.columnName($0.0)):\(CellRef.columnName($0.1))" }
    }
}
