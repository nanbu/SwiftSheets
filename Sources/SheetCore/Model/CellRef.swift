import Foundation

/// A cell position, numbered the way the sheet shows it: `row: 1, column: 1` is A1, `row: 2, column: 3` is C2
/// (spec Appendix B.61). Cell coordinates are screen numbers everywhere in the model; only positions in Swift
/// collections (`workbook.sheets[0]`, the arrays `rows(in:)` hands back) are Swift indices. Row 0 and column 0 do
/// not exist, and a writing entry point stops on them.
public struct CellRef: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public var row: Int
    public var column: Int

    /// Excel's limits: columns A…XFD (16,384), rows 1…1,048,576.
    public static let maxColumn = 16_384
    public static let maxRow = 1_048_576
    /// The largest column number the A1 parser accepts (three letters: ZZZ).
    static let maxParsedCol = 18_278

    public init(row: Int, column: Int) { self.row = row; self.column = column }

    /// Parses "A1", "$B$2", "AB12". Nil when malformed (no row, row 0, more than three letters, a row number past
    /// the sheet's last row). Every bound is checked *while* scanning: a hostile file must not be able to overflow
    /// the accumulators (spec §12, malformed input never traps).
    public init?(_ a1: String) {
        var col = 0, row = 0, seenDigit = false, letters = 0
        for ch in a1.uppercased().unicodeScalars {
            if ch == "$" { continue }
            if ("A"..."Z").contains(ch), !seenDigit {
                letters += 1
                guard letters <= 3 else { return nil }
                col = col * 26 + Int(ch.value - 64)
            }
            else if ("0"..."9").contains(ch) {
                seenDigit = true
                row = row * 10 + Int(ch.value - 48)
                guard row <= CellRef.maxRow else { return nil }
            }
            else { return nil }
        }
        guard col > 0, row > 0 else { return nil }
        self.row = row; self.column = col
    }

    /// "A1".
    public var address: String { columnName + String(row) }
    public var description: String { address }
    /// "A".
    public var columnName: String { CellRef.columnLetters(column) }
    /// "$A$1".
    public var absoluteAddress: String { "$" + columnName + "$" + String(row) }

    public static func < (a: CellRef, b: CellRef) -> Bool { a.row != b.row ? a.row < b.row : a.column < b.column }

    /// The cell `rows` below and `columns` to the right — the same word as `CellRange.shifted`.
    public func shifted(rows: Int = 0, columns: Int = 0) -> CellRef { CellRef(row: row + rows, column: column + columns) }

    // MARK: - Column names (bijective base-26)

    /// 1 → "A", 28 → "AB". Zero and negative numbers give "".
    /// The letters of a column counted from 1 (`1` is "A"). Stops below 1 (spec Appendix B.92): a column 0 used to answer
    /// "" and put `$$2:$$4` into a formula. `columnName(validating:)` answers nil instead.
    public static func columnName(_ column: Int) -> String {
        precondition(column >= 1, "columns count from 1 (column \(column))")
        return columnLetters(column)
    }

    /// `columnName(_:)` without the stop: "" below 1. The library formats addresses through this, so a malformed file or
    /// an invalid reference printed in a message never stops the process (spec §12).
    package static func columnLetters(_ column: Int) -> String {
        var n = column, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    /// Like `columnName(_:)` but nil outside 1…18,278 (openpyxl raises `ValueError`).
    public static func columnName(validating column: Int) -> String? { (1...maxParsedCol).contains(column) ? columnLetters(column) : nil }

    /// "AB" → 28. Case-insensitive; nil for more than three letters or non-letters. The length is checked while
    /// scanning so that a long run of letters cannot overflow `n`.
    public static func columnIndex(_ name: String) -> Int? {
        var n = 0, count = 0
        for ch in name.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(ch) else { return nil }
            count += 1
            guard count <= 3 else { return nil }
            n = n * 26 + Int(ch.value - 64)
        }
        return count >= 1 ? n : nil
    }

    /// All column names from `start` to `end` inclusive (column numbers, 1 = A).
    public static func columnNames(from start: Int, to end: Int) -> [String] { start <= end ? (start...end).map(columnName) : [] }
    public static func columnNames(from start: String, to end: String) -> [String]? {
        guard let a = columnIndex(start), let b = columnIndex(end) else { return nil }
        return columnNames(from: a, to: b)
    }

    /// "ZF51" → "$ZF$51", "A:G" → "$A:$G", "1" → "$1". Nil when not a coordinate or range.
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

    /// Quotes a sheet name for use in formulas: `My Sheet` → `'My Sheet'`, doubling embedded quotes.
    public static func quoteSheetName(_ name: String) -> String { "'" + name.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Quotes only when needed: names that are not simple identifiers get single quotes.
    public static func formulaSheetName(_ name: String) -> String {
        let simple = !name.isEmpty && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "." }
            && !(name.first?.isNumber ?? true) && CellRef(name) == nil && RangeBounds.match(name) == nil
        return simple ? name : quoteSheetName(name)
    }
}

/// The four (possibly open) boundaries of a range string: "C1:C4", "D:F", "1:10", "A", "1". Screen numbers (1 = A = row 1).
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
            if ("A"..."Z").contains(ch), !seenDigit {
                letters.unicodeScalars.append(ch)
                guard letters.count <= 3 else { return nil }
            }
            else if ("0"..."9").contains(ch) {
                seenDigit = true
                digits.unicodeScalars.append(ch)
                guard digits.count <= 10 else { return nil }   // far past the last row; only a hostile input gets here
            }
            else { return nil }
        }
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
        if let l = a.letters { guard let i = CellRef.columnIndex(l) else { return nil }; c0 = i }
        if let l = b?.letters { guard let i = CellRef.columnIndex(l) else { return nil }; c1 = i }
        minColumn = c0; minRow = a.digits.flatMap { Int($0) }
        if let b {
            maxColumn = b.letters == nil ? minColumn : c1
            maxRow = b.digits == nil ? minRow : b.digits.flatMap { Int($0) }
        } else { maxColumn = minColumn; maxRow = minRow }
        if minRow == 0 || maxRow == 0 { return nil }   // there is no row 0
    }
}

/// A rectangular range such as "A1:C3", optionally qualified with a sheet name ("'My Sheet'!A1:C3"). Bounds are screen
/// numbers, both ends included: "A1:C3" is rows 1…3, columns 1…3.
public struct CellRange: Hashable, Sendable, CustomStringConvertible, Codable {
    public var minRow: Int, minColumn: Int, maxRow: Int, maxColumn: Int
    /// Sheet name when the range was given as "Sheet!A1:B2".
    public var sheet: String?

    public init(minRow: Int, minColumn: Int, maxRow: Int, maxColumn: Int, sheet: String? = nil) {
        self.minRow = minRow; self.minColumn = minColumn; self.maxRow = maxRow; self.maxColumn = maxColumn; self.sheet = sheet
    }

    public init(from a: CellRef, to b: CellRef, sheet: String? = nil) {
        self.init(minRow: Swift.min(a.row, b.row), minColumn: Swift.min(a.column, b.column), maxRow: Swift.max(a.row, b.row), maxColumn: Swift.max(a.column, b.column), sheet: sheet)
    }

    public init(_ ref: CellRef) { self.init(minRow: ref.row, minColumn: ref.column, maxRow: ref.row, maxColumn: ref.column) }

    /// Parses "A1:C3", "A1", "Sheet1!$A$1:B4", "'My Sheet'!A1:E6". Nil when malformed or when the end precedes the
    /// start ("A4:B1").
    public init?(_ a1: String) {
        var body = a1, sheet: String? = nil
        if let bang = CellRange.splitSheetName(a1) { sheet = bang.sheet; body = bang.cells }
        guard let b = RangeBounds(body), let c0 = b.minColumn, let r0 = b.minRow, let c1 = b.maxColumn, let r1 = b.maxRow else { return nil }
        guard c1 >= c0, r1 >= r0 else { return nil }
        self.init(minRow: r0, minColumn: c0, maxRow: r1, maxColumn: c1, sheet: sheet)
    }

    /// "Sheet1!A1:B2" → ("Sheet1", "A1:B2"); "'E,F'!A1" → ("E,F", "A1"). Nil without a "!".
    public static func splitSheetName(_ ref: String) -> (sheet: String, cells: String)? {
        if ref.hasPrefix("'") {
            var i = ref.index(after: ref.startIndex), name = ""
            while i < ref.endIndex {
                let ch = ref[i]
                if ch == "'" {
                    let next = ref.index(after: i)
                    if next < ref.endIndex, ref[next] == "'" { name.append("'"); i = ref.index(after: next); continue }
                    if next < ref.endIndex, ref[next] == "!" { return (name, String(ref[ref.index(after: next)...])) }
                    return nil
                }
                name.append(ch); i = ref.index(after: i)
            }
            return nil
        }
        guard let bang = ref.lastIndex(of: "!") else { return nil }
        let name = String(ref[..<bang])
        guard !name.isEmpty, !name.contains(" ") else { return nil }
        return (name, String(ref[ref.index(after: bang)...]))
    }

    /// "A1:C3", or "A1" for a single cell.
    public var address: String {
        let a = CellRef.columnLetters(minColumn) + String(minRow)
        if minColumn == maxColumn, minRow == maxRow { return a }
        return a + ":" + CellRef.columnLetters(maxColumn) + String(maxRow)
    }
    public var description: String { address }
    /// "'Sheet 1'!A1:B4" when a sheet is set, else the plain A1 form.
    public var qualifiedAddress: String { sheet.map { CellRef.quoteSheetName($0) + "!" + address } ?? address }
    /// "$A$1:$C$3".
    public var absoluteAddress: String { topLeft.absoluteAddress + (isSingleCell ? "" : ":" + bottomRight.absoluteAddress) }
    public var isSingleCell: Bool { minColumn == maxColumn && minRow == maxRow }
    public var size: (rows: Int, columns: Int) { (maxRow - minRow + 1, maxColumn - minColumn + 1) }
    public var topLeft: CellRef { CellRef(row: minRow, column: minColumn) }
    public var bottomRight: CellRef { CellRef(row: maxRow, column: maxColumn) }

    public func contains(_ ref: CellRef) -> Bool { (minColumn...maxColumn).contains(ref.column) && (minRow...maxRow).contains(ref.row) }
    public func contains(_ a1: String) -> Bool { CellRef(a1).map(contains) ?? false }

    // MARK: - Geometry

    /// Moved by the given offsets; nil when a boundary would leave the sheet (above row 1 or left of column A).
    public func shifted(rows: Int = 0, columns: Int = 0) -> CellRange? {
        guard minColumn + columns >= 1, minRow + rows >= 1 else { return nil }
        return CellRange(minRow: minRow + rows, minColumn: minColumn + columns, maxRow: maxRow + rows, maxColumn: maxColumn + columns, sheet: sheet)
    }
    public mutating func shift(rows: Int = 0, columns: Int = 0) {
        guard let s = shifted(rows: rows, columns: columns) else { preconditionFailure("shift would move \(address) off the sheet") }
        self = s
    }

    /// Grown on each side; never past row 1 or column A.
    public func expanded(right: Int = 0, down: Int = 0, left: Int = 0, up: Int = 0) -> CellRange {
        CellRange(minRow: Swift.max(1, minRow - up), minColumn: Swift.max(1, minColumn - left), maxRow: maxRow + down, maxColumn: maxColumn + right, sheet: sheet)
    }
    /// Shrunk on each side; nil when nothing would remain.
    public func shrunk(right: Int = 0, down: Int = 0, left: Int = 0, up: Int = 0) -> CellRange? {
        let c0 = minColumn + left, r0 = minRow + up, c1 = maxColumn - right, r1 = maxRow - down
        guard c1 >= c0, r1 >= r0 else { return nil }
        return CellRange(minRow: r0, minColumn: c0, maxRow: r1, maxColumn: c1, sheet: sheet)
    }

    /// True when `other` names a sheet and it is not this range's sheet (an unqualified `other` is always compatible).
    public func isOnDifferentSheet(from other: CellRange) -> Bool {
        guard let b = other.sheet else { return false }
        return sheet != b
    }

    /// The smallest range containing both; nil when the sheets differ.
    public func union(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other) else { return nil }
        return CellRange(minRow: Swift.min(minRow, other.minRow), minColumn: Swift.min(minColumn, other.minColumn),
                         maxRow: Swift.max(maxRow, other.maxRow), maxColumn: Swift.max(maxColumn, other.maxColumn), sheet: sheet)
    }
    /// The overlap; nil when disjoint or on different sheets.
    public func intersection(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other), !isDisjoint(with: other) else { return nil }
        return CellRange(minRow: Swift.max(minRow, other.minRow), minColumn: Swift.max(minColumn, other.minColumn),
                         maxRow: Swift.min(maxRow, other.maxRow), maxColumn: Swift.min(maxColumn, other.maxColumn), sheet: sheet)
    }
    public func isDisjoint(with other: CellRange) -> Bool {
        minColumn > other.maxColumn || other.minColumn > maxColumn || minRow > other.maxRow || other.minRow > maxRow
    }
    public func isSubset(of other: CellRange) -> Bool {
        other.minColumn <= minColumn && maxColumn <= other.maxColumn && other.minRow <= minRow && maxRow <= other.maxRow
    }
    public func isSuperset(of other: CellRange) -> Bool { other.isSubset(of: self) }
    /// Strict subset ordering.
    public static func < (a: CellRange, b: CellRange) -> Bool { a != b && a.isSubset(of: b) }
    public static func > (a: CellRange, b: CellRange) -> Bool { b < a }

    // MARK: - Enumeration

    public var top: [CellRef] { (minColumn...maxColumn).map { CellRef(row: minRow, column: $0) } }
    public var bottom: [CellRef] { (minColumn...maxColumn).map { CellRef(row: maxRow, column: $0) } }
    public var left: [CellRef] { (minRow...maxRow).map { CellRef(row: $0, column: minColumn) } }
    public var right: [CellRef] { (minRow...maxRow).map { CellRef(row: $0, column: maxColumn) } }
    /// Row by row.
    public var rows: [[CellRef]] { (minRow...maxRow).map { r in (minColumn...maxColumn).map { CellRef(row: r, column: $0) } } }
    /// Column by column.
    public var columns: [[CellRef]] { (minColumn...maxColumn).map { c in (minRow...maxRow).map { CellRef(row: $0, column: c) } } }
    /// Every cell, row-major.
    public var cells: [CellRef] { rows.flatMap { $0 } }
}

/// A set of ranges written space-separated ("A1 B2:B5"), as in `sqref` attributes.
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
    public mutating func add(_ a1: String) { if let r = CellRange(a1) { add(r) } }
    /// Removes exactly this range; false when it was not a member.
    @discardableResult public mutating func remove(_ range: CellRange) -> Bool { ranges.remove(range) != nil }
    @discardableResult public mutating func remove(_ a1: String) -> Bool { CellRange(a1).map { remove($0) } ?? false }
    public func contains(_ ref: CellRef) -> Bool { ranges.contains { $0.contains(ref) } }
    public func contains(_ a1: String) -> Bool { CellRef(a1).map(contains) ?? false }
    public var isEmpty: Bool { ranges.isEmpty }
    /// Sorted, space-separated ("A1 B2:B5").
    public var description: String { sorted.map(\.address).joined(separator: " ") }
    public var sorted: [CellRange] { ranges.sorted { ($0.topLeft, $0.address) < ($1.topLeft, $1.address) } }
}
