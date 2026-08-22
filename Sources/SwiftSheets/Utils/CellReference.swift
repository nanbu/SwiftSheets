import Foundation

/// "A1"-style coordinates. 1-based column and row. Mirrors `openpyxl.utils.cell`.
public struct CellReference: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let column: Int
    public let row: Int

    /// Excel's limits: columns A…XFD, rows 1…1048576.
    public static let maxColumn = 18278
    public static let maxRow = 1_048_576

    public init(column: Int, row: Int) { self.column = column; self.row = row }

    /// Parses "A1", "$B$2", "AB12". Returns nil when malformed (no row, row 0, more than three letters).
    public init?(_ ref: String) {
        var col = 0, row = 0, seenDigit = false, letters = 0
        for ch in ref.uppercased().unicodeScalars {
            if ch == "$" { continue }
            if ("A"..."Z").contains(ch), !seenDigit { col = col * 26 + Int(ch.value - 64); letters += 1 }
            else if ("0"..."9").contains(ch) { seenDigit = true; row = row * 10 + Int(ch.value - 48) }
            else { return nil }
        }
        guard col > 0, row > 0, letters <= 3 else { return nil }
        self.column = col; self.row = row
    }

    public var columnLetter: String { CellReference.columnLetter(column) }
    public var description: String { columnLetter + String(row) }
    /// "$A$1" (openpyxl `absolute_coordinate` for a single cell).
    public var absolute: String { "$" + columnLetter + "$" + String(row) }
    public static func < (a: CellReference, b: CellReference) -> Bool { a.row != b.row ? a.row < b.row : a.column < b.column }

    /// The cell `rows` below and `columns` to the right (openpyxl `cell.offset`).
    public func offset(row: Int = 0, column: Int = 0) -> CellReference { CellReference(column: self.column + column, row: self.row + row) }

    /// 1 → "A", 28 → "AB" (openpyxl.utils.get_column_letter). Returns "" for 0; callers that need validation use `columnLetter(validating:)`.
    public static func columnLetter(_ col: Int) -> String {
        var n = col, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    /// Like `columnLetter(_:)` but nil outside 1…18278, as openpyxl raises `ValueError`.
    public static func columnLetter(validating col: Int) -> String? { (1...maxColumn).contains(col) ? columnLetter(col) : nil }

    /// "AB" → 28 (openpyxl.utils.column_index_from_string). Case-insensitive; nil for more than three letters or non-letters.
    public static func columnIndex(_ letters: String) -> Int? {
        var n = 0, count = 0
        for ch in letters.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(ch) else { return nil }
            n = n * 26 + Int(ch.value - 64); count += 1
        }
        return count >= 1 && count <= 3 && n <= maxColumn ? n : nil
    }

    /// All column letters from `start` to `end` inclusive (openpyxl `get_column_interval`).
    public static func columnLetters(from start: Int, to end: Int) -> [String] { start <= end ? (start...end).map(columnLetter) : [] }
    public static func columnLetters(from start: String, to end: String) -> [String]? {
        guard let a = columnIndex(start), let b = columnIndex(end) else { return nil }
        return columnLetters(from: a, to: b)
    }

    /// "ZF51" → "$ZF$51", "A:G" → "$A:$G", "1" → "$1" (openpyxl `absolute_coordinate`). Nil when not a coordinate or range.
    public static func absolute(_ coordinate: String) -> String? {
        let parts = coordinate.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        func one(_ s: String) -> String? {
            guard let m = RangeBounds.match(s), m.letters != nil || m.digits != nil else { return nil }
            return (m.letters.map { "$" + $0 } ?? "") + (m.digits.map { "$" + $0 } ?? "")
        }
        guard let a = one(parts[0]) else { return nil }
        if parts.count == 1 { return a }
        guard let b = one(parts[1]) else { return nil }
        return a + ":" + b
    }

    /// Quotes a sheet title for use in formulas: `My Sheet` → `'My Sheet'`, doubling embedded quotes (openpyxl `quote_sheetname`).
    public static func quoteSheetName(_ title: String) -> String { "'" + title.replacingOccurrences(of: "'", with: "''") + "'" }
}

/// The four (possibly open) boundaries of a range string: "C1:C4", "D:F", "1:10", "A", "1" (openpyxl `range_boundaries`).
/// Whole-column and whole-row ranges leave the other axis nil.
public struct RangeBounds: Hashable, Sendable {
    public var minColumn: Int?, minRow: Int?, maxColumn: Int?, maxRow: Int?

    public init(minColumn: Int? = nil, minRow: Int? = nil, maxColumn: Int? = nil, maxRow: Int? = nil) {
        self.minColumn = minColumn; self.minRow = minRow; self.maxColumn = maxColumn; self.maxRow = maxRow
    }

    struct Match { let letters: String?; let digits: String? }

    /// `[$]?[A-Z]{1,3}?[$]?\d+?` — both parts optional.
    static func match(_ s: String) -> Match? {
        var letters = "", digits = "", seenDigit = false
        for ch in s.uppercased().unicodeScalars {
            if ch == "$" { if seenDigit { return nil }; continue }
            if ("A"..."Z").contains(ch), !seenDigit { letters.unicodeScalars.append(ch) }
            else if ("0"..."9").contains(ch) { seenDigit = true; digits.unicodeScalars.append(ch) }
            else { return nil }
        }
        guard letters.count <= 3 else { return nil }
        return Match(letters: letters.isEmpty ? nil : letters, digits: digits.isEmpty ? nil : digits)
    }

    public init?(_ rangeString: String) {
        let parts = rangeString.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let a = RangeBounds.match(parts[0]) else { return nil }
        let b = parts.count == 2 ? RangeBounds.match(parts[1]) : nil
        if parts.count == 2 {
            guard let b else { return nil }
            let cols = [a.letters, b.letters], rows = [a.digits, b.digits]
            let allCols = cols.allSatisfy { $0 != nil }, allRows = rows.allSatisfy { $0 != nil }
            let anyCols = cols.contains { $0 != nil }, anyRows = rows.contains { $0 != nil }
            guard (allCols && allRows) || (allCols && !anyRows) || (allRows && !anyCols) else { return nil }
        } else {
            guard a.letters != nil || a.digits != nil else { return nil }
        }
        var c0: Int? = nil, c1: Int? = nil
        if let l = a.letters { guard let i = CellReference.columnIndex(l) else { return nil }; c0 = i }
        if let l = b?.letters { guard let i = CellReference.columnIndex(l) else { return nil }; c1 = i }
        minColumn = c0; minRow = a.digits.flatMap { Int($0) }
        if let b {
            maxColumn = b.letters == nil ? minColumn : c1
            maxRow = b.digits == nil ? minRow : b.digits.flatMap { Int($0) }
        } else { maxColumn = minColumn; maxRow = minRow }
        if minRow == 0 || maxRow == 0 { return nil }
    }
}

/// A rectangular range such as "A1:C3", optionally qualified with a sheet title ("'My Sheet'!A1:C3").
/// Mirrors `openpyxl.worksheet.cell_range.CellRange`: set operations, shifting, expanding and edge enumeration.
public struct CellRange: Hashable, Sendable, CustomStringConvertible {
    public var minColumn: Int, minRow: Int, maxColumn: Int, maxRow: Int
    /// Sheet title when the range was given as "Sheet!A1:B2".
    public var title: String?

    public init(minColumn: Int, minRow: Int, maxColumn: Int, maxRow: Int, title: String? = nil) {
        self.minColumn = minColumn; self.minRow = minRow; self.maxColumn = maxColumn; self.maxRow = maxRow; self.title = title
    }

    /// Parses "A1:C3", "A1", "Sheet1!$A$1:B4", "'My Sheet'!A1:E6". Nil when malformed or when the end precedes the start
    /// (openpyxl raises `ValueError` for "A4:B1").
    public init?(_ ref: String) {
        var body = ref, title: String? = nil
        if let bang = CellRange.splitSheetTitle(ref) { title = bang.title; body = bang.cells }
        guard let b = RangeBounds(body), let c0 = b.minColumn, let r0 = b.minRow, let c1 = b.maxColumn, let r1 = b.maxRow else { return nil }
        guard c1 >= c0, r1 >= r0 else { return nil }
        self.init(minColumn: c0, minRow: r0, maxColumn: c1, maxRow: r1, title: title)
    }

    /// "Sheet1!A1:B2" → ("Sheet1", "A1:B2"); "'E,F'!A1" → ("E,F", "A1"). Nil without a "!".
    public static func splitSheetTitle(_ ref: String) -> (title: String, cells: String)? {
        if ref.hasPrefix("'") {
            // quoted title: find the closing quote that is followed by "!"
            var i = ref.index(after: ref.startIndex), title = ""
            while i < ref.endIndex {
                let ch = ref[i]
                if ch == "'" {
                    let next = ref.index(after: i)
                    if next < ref.endIndex, ref[next] == "'" { title.append("'"); i = ref.index(after: next); continue }
                    if next < ref.endIndex, ref[next] == "!" { return (title, String(ref[ref.index(after: next)...])) }
                    return nil
                }
                title.append(ch); i = ref.index(after: i)
            }
            return nil
        }
        guard let bang = ref.lastIndex(of: "!") else { return nil }
        let title = String(ref[..<bang])
        guard !title.isEmpty, !title.contains(" ") else { return nil }
        return (title, String(ref[ref.index(after: bang)...]))
    }

    /// "A1:C3", or "A1" for a single cell (openpyxl `coord`).
    public var coordinate: String {
        let a = CellReference.columnLetter(minColumn) + String(minRow)
        if minColumn == maxColumn, minRow == maxRow { return a }
        return a + ":" + CellReference.columnLetter(maxColumn) + String(maxRow)
    }
    public var description: String { coordinate }
    /// "'Sheet 1'!A1:B4" when a title is set, else the coordinate (openpyxl `str(range)`).
    public var qualified: String { title.map { CellReference.quoteSheetName($0) + "!" + coordinate } ?? coordinate }
    /// (minColumn, minRow, maxColumn, maxRow) — openpyxl `bounds`.
    public var bounds: (Int, Int, Int, Int) { (minColumn, minRow, maxColumn, maxRow) }
    public var size: (columns: Int, rows: Int) { (maxColumn - minColumn + 1, maxRow - minRow + 1) }
    public var topLeft: CellReference { CellReference(column: minColumn, row: minRow) }
    public var bottomRight: CellReference { CellReference(column: maxColumn, row: maxRow) }

    public func contains(_ ref: CellReference) -> Bool {
        (minColumn...maxColumn).contains(ref.column) && (minRow...maxRow).contains(ref.row)
    }
    public func contains(_ coordinate: String) -> Bool { CellReference(coordinate).map(contains) ?? false }

    // MARK: - Geometry

    /// Moved by the given offsets; nil when a boundary would drop below 1 (openpyxl raises).
    public func shifted(rows: Int = 0, columns: Int = 0) -> CellRange? {
        guard minColumn + columns >= 1, minRow + rows >= 1 else { return nil }
        return CellRange(minColumn: minColumn + columns, minRow: minRow + rows, maxColumn: maxColumn + columns, maxRow: maxRow + rows, title: title)
    }
    public mutating func shift(rows: Int = 0, columns: Int = 0) {
        guard let s = shifted(rows: rows, columns: columns) else { preconditionFailure("shift would move \(coordinate) off the sheet") }
        self = s
    }

    /// Grown on each side; stays ≥ 1.
    public func expanded(right: Int = 0, down: Int = 0, left: Int = 0, up: Int = 0) -> CellRange {
        CellRange(minColumn: max(1, minColumn - left), minRow: max(1, minRow - up), maxColumn: maxColumn + right, maxRow: maxRow + down, title: title)
    }
    /// Shrunk on each side; nil when nothing would remain.
    public func shrunk(right: Int = 0, bottom: Int = 0, left: Int = 0, top: Int = 0) -> CellRange? {
        let c0 = minColumn + left, r0 = minRow + top, c1 = maxColumn - right, r1 = maxRow - bottom
        guard c1 >= c0, r1 >= r0 else { return nil }
        return CellRange(minColumn: c0, minRow: r0, maxColumn: c1, maxRow: r1, title: title)
    }

    /// True when `other` names a sheet and it is not this range's sheet (openpyxl `_check_title` raises in that case;
    /// an untitled `other` is always compatible).
    public func isOnDifferentSheet(from other: CellRange) -> Bool {
        guard let b = other.title else { return false }
        return title != b
    }

    /// The smallest range containing both; nil when the sheets differ.
    public func union(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other) else { return nil }
        return CellRange(minColumn: min(minColumn, other.minColumn), minRow: min(minRow, other.minRow),
                         maxColumn: max(maxColumn, other.maxColumn), maxRow: max(maxRow, other.maxRow), title: title)
    }
    /// The overlap; nil when disjoint or on different sheets.
    public func intersection(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other), !isDisjoint(with: other) else { return nil }
        return CellRange(minColumn: max(minColumn, other.minColumn), minRow: max(minRow, other.minRow),
                         maxColumn: min(maxColumn, other.maxColumn), maxRow: min(maxRow, other.maxRow), title: title)
    }
    public func isDisjoint(with other: CellRange) -> Bool {
        minColumn > other.maxColumn || other.minColumn > maxColumn || minRow > other.maxRow || other.minRow > maxRow
    }
    public func isSubset(of other: CellRange) -> Bool {
        other.minColumn <= minColumn && maxColumn <= other.maxColumn && other.minRow <= minRow && maxRow <= other.maxRow
    }
    public func isSuperset(of other: CellRange) -> Bool { other.isSubset(of: self) }
    /// Strict subset ordering (openpyxl `<` / `>`).
    public static func < (a: CellRange, b: CellRange) -> Bool { a != b && a.isSubset(of: b) }
    public static func > (a: CellRange, b: CellRange) -> Bool { b < a }

    // MARK: - Enumeration

    public var top: [CellReference] { (minColumn...maxColumn).map { CellReference(column: $0, row: minRow) } }
    public var bottom: [CellReference] { (minColumn...maxColumn).map { CellReference(column: $0, row: maxRow) } }
    public var left: [CellReference] { (minRow...maxRow).map { CellReference(column: minColumn, row: $0) } }
    public var right: [CellReference] { (minRow...maxRow).map { CellReference(column: maxColumn, row: $0) } }
    /// Row by row (openpyxl `rows`, `rows_from_range`).
    public var rows: [[CellReference]] { (minRow...maxRow).map { r in (minColumn...maxColumn).map { CellReference(column: $0, row: r) } } }
    /// Column by column (openpyxl `cols`, `cols_from_range`).
    public var cols: [[CellReference]] { (minColumn...maxColumn).map { c in (minRow...maxRow).map { CellReference(column: c, row: $0) } } }
    /// Every cell, row-major.
    public var cells: [CellReference] { rows.flatMap { $0 } }
}

/// A set of ranges written space-separated ("A1 B2:B5"), as in `sqref` attributes (openpyxl `MultiCellRange`).
public struct MultiCellRange: Hashable, Sendable, CustomStringConvertible {
    public private(set) var ranges: Set<CellRange> = []

    public init() {}
    public init(_ ranges: some Sequence<CellRange>) { self.ranges = Set(ranges) }
    public init?(_ sqref: String) {
        for part in sqref.split(separator: " ") {
            guard let r = CellRange(String(part)) else { return nil }
            ranges.insert(r)
        }
    }

    /// Adds a range unless it is already covered by one of the existing ranges.
    public mutating func add(_ range: CellRange) { if !ranges.contains(where: { range.isSubset(of: $0) }) { ranges.insert(range) } }
    public mutating func add(_ coordinate: String) { if let r = CellRange(coordinate) { add(r) } }
    /// Removes exactly this range; returns false when it was not a member (openpyxl raises `KeyError`).
    @discardableResult public mutating func remove(_ range: CellRange) -> Bool { ranges.remove(range) != nil }
    @discardableResult public mutating func remove(_ coordinate: String) -> Bool { CellRange(coordinate).map { remove($0) } ?? false }
    public func contains(_ ref: CellReference) -> Bool { ranges.contains { $0.contains(ref) } }
    public func contains(_ coordinate: String) -> Bool { CellReference(coordinate).map(contains) ?? false }
    public var isEmpty: Bool { ranges.isEmpty }
    /// Sorted, space-separated ("A1 B2:B5").
    public var description: String { ranges.map(\.coordinate).sorted { a, b in (CellRange(a)!.topLeft, a) < (CellRange(b)!.topLeft, b) }.joined(separator: " ") }
    public var sorted: [CellRange] { ranges.sorted { ($0.topLeft, $0.coordinate) < ($1.topLeft, $1.coordinate) } }
}
