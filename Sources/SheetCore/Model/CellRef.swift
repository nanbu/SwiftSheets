import Foundation

/// A cell position. Integers are **0-based** (`row: 0, col: 0` is A1); the only 1-based form is the A1 string.
/// Mixing the two systems is the classic off-by-one, so there is no 1-based integer API at all.
public struct CellRef: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public var row: Int
    public var col: Int

    /// Excel's limits: columns A…XFD (16,384), rows 1…1,048,576.
    public static let maxCol = 16_383
    public static let maxRow = 1_048_575
    /// The largest column index the A1 parser accepts (three letters: ZZZ).
    static let maxParsedCol = 18_277

    public init(row: Int, col: Int) { self.row = row; self.col = col }

    /// Parses "A1", "$B$2", "AB12". Nil when malformed (no row, row 0, more than three letters).
    public init?(_ a1: String) {
        var col = 0, row = 0, seenDigit = false, letters = 0
        for ch in a1.uppercased().unicodeScalars {
            if ch == "$" { continue }
            if ("A"..."Z").contains(ch), !seenDigit { col = col * 26 + Int(ch.value - 64); letters += 1 }
            else if ("0"..."9").contains(ch) { seenDigit = true; row = row * 10 + Int(ch.value - 48) }
            else { return nil }
        }
        guard col > 0, row > 0, letters <= 3 else { return nil }
        self.row = row - 1; self.col = col - 1
    }

    /// "A1".
    public var a1: String { columnName + String(row + 1) }
    public var description: String { a1 }
    /// "A".
    public var columnName: String { CellRef.columnName(col) }
    /// The 1-based row number as it appears on screen and in messages.
    public var rowNumber: Int { row + 1 }
    /// "$A$1".
    public var absoluteA1: String { "$" + columnName + "$" + String(row + 1) }

    public static func < (a: CellRef, b: CellRef) -> Bool { a.row != b.row ? a.row < b.row : a.col < b.col }

    /// The cell `rows` below and `cols` to the right.
    public func offset(rows: Int = 0, cols: Int = 0) -> CellRef { CellRef(row: row + rows, col: col + cols) }

    // MARK: - Column names (bijective base-26)

    /// 0 → "A", 27 → "AB". Negative indices give "".
    public static func columnName(_ col: Int) -> String {
        var n = col + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    /// Like `columnName(_:)` but nil outside 0…maxParsedCol (openpyxl raises `ValueError`).
    public static func columnName(validating col: Int) -> String? { (0...maxParsedCol).contains(col) ? columnName(col) : nil }

    /// "AB" → 27. Case-insensitive; nil for more than three letters or non-letters.
    public static func columnIndex(_ name: String) -> Int? {
        var n = 0, count = 0
        for ch in name.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(ch) else { return nil }
            n = n * 26 + Int(ch.value - 64); count += 1
        }
        return count >= 1 && count <= 3 ? n - 1 : nil
    }

    /// All column names from `start` to `end` inclusive (0-based indices).
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

/// The four (possibly open) boundaries of a range string: "C1:C4", "D:F", "1:10", "A", "1". 0-based.
/// Whole-column and whole-row ranges leave the other axis nil.
public struct RangeBounds: Hashable, Sendable {
    public var minCol: Int?, minRow: Int?, maxCol: Int?, maxRow: Int?

    public init(minCol: Int? = nil, minRow: Int? = nil, maxCol: Int? = nil, maxRow: Int? = nil) {
        self.minCol = minCol; self.minRow = minRow; self.maxCol = maxCol; self.maxRow = maxRow
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
        if let l = a.letters { guard let i = CellRef.columnIndex(l) else { return nil }; c0 = i }
        if let l = b?.letters { guard let i = CellRef.columnIndex(l) else { return nil }; c1 = i }
        minCol = c0; minRow = a.digits.flatMap { Int($0) }.map { $0 - 1 }
        if let b {
            maxCol = b.letters == nil ? minCol : c1
            maxRow = b.digits == nil ? minRow : b.digits.flatMap { Int($0) }.map { $0 - 1 }
        } else { maxCol = minCol; maxRow = minRow }
        if minRow == -1 || maxRow == -1 { return nil }
    }
}

/// A rectangular range such as "A1:C3", optionally qualified with a sheet name ("'My Sheet'!A1:C3"). 0-based bounds.
public struct CellRange: Hashable, Sendable, CustomStringConvertible, Codable {
    public var minRow: Int, minCol: Int, maxRow: Int, maxCol: Int
    /// Sheet name when the range was given as "Sheet!A1:B2".
    public var sheet: String?

    public init(minRow: Int, minCol: Int, maxRow: Int, maxCol: Int, sheet: String? = nil) {
        self.minRow = minRow; self.minCol = minCol; self.maxRow = maxRow; self.maxCol = maxCol; self.sheet = sheet
    }

    public init(from a: CellRef, to b: CellRef, sheet: String? = nil) {
        self.init(minRow: Swift.min(a.row, b.row), minCol: Swift.min(a.col, b.col), maxRow: Swift.max(a.row, b.row), maxCol: Swift.max(a.col, b.col), sheet: sheet)
    }

    public init(_ ref: CellRef) { self.init(minRow: ref.row, minCol: ref.col, maxRow: ref.row, maxCol: ref.col) }

    /// Parses "A1:C3", "A1", "Sheet1!$A$1:B4", "'My Sheet'!A1:E6". Nil when malformed or when the end precedes the
    /// start ("A4:B1").
    public init?(_ a1: String) {
        var body = a1, sheet: String? = nil
        if let bang = CellRange.splitSheetName(a1) { sheet = bang.sheet; body = bang.cells }
        guard let b = RangeBounds(body), let c0 = b.minCol, let r0 = b.minRow, let c1 = b.maxCol, let r1 = b.maxRow else { return nil }
        guard c1 >= c0, r1 >= r0 else { return nil }
        self.init(minRow: r0, minCol: c0, maxRow: r1, maxCol: c1, sheet: sheet)
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
    public var a1: String {
        let a = CellRef.columnName(minCol) + String(minRow + 1)
        if minCol == maxCol, minRow == maxRow { return a }
        return a + ":" + CellRef.columnName(maxCol) + String(maxRow + 1)
    }
    public var description: String { a1 }
    /// "'Sheet 1'!A1:B4" when a sheet is set, else the plain A1 form.
    public var qualifiedA1: String { sheet.map { CellRef.quoteSheetName($0) + "!" + a1 } ?? a1 }
    /// "$A$1:$C$3".
    public var absoluteA1: String { topLeft.absoluteA1 + (isSingleCell ? "" : ":" + bottomRight.absoluteA1) }
    public var isSingleCell: Bool { minCol == maxCol && minRow == maxRow }
    public var size: (rows: Int, cols: Int) { (maxRow - minRow + 1, maxCol - minCol + 1) }
    public var topLeft: CellRef { CellRef(row: minRow, col: minCol) }
    public var bottomRight: CellRef { CellRef(row: maxRow, col: maxCol) }

    public func contains(_ ref: CellRef) -> Bool { (minCol...maxCol).contains(ref.col) && (minRow...maxRow).contains(ref.row) }
    public func contains(_ a1: String) -> Bool { CellRef(a1).map(contains) ?? false }

    // MARK: - Geometry

    /// Moved by the given offsets; nil when a boundary would go negative.
    public func shifted(rows: Int = 0, cols: Int = 0) -> CellRange? {
        guard minCol + cols >= 0, minRow + rows >= 0 else { return nil }
        return CellRange(minRow: minRow + rows, minCol: minCol + cols, maxRow: maxRow + rows, maxCol: maxCol + cols, sheet: sheet)
    }
    public mutating func shift(rows: Int = 0, cols: Int = 0) {
        guard let s = shifted(rows: rows, cols: cols) else { preconditionFailure("shift would move \(a1) off the sheet") }
        self = s
    }

    /// Grown on each side; stays ≥ 0.
    public func expanded(right: Int = 0, down: Int = 0, left: Int = 0, up: Int = 0) -> CellRange {
        CellRange(minRow: Swift.max(0, minRow - up), minCol: Swift.max(0, minCol - left), maxRow: maxRow + down, maxCol: maxCol + right, sheet: sheet)
    }
    /// Shrunk on each side; nil when nothing would remain.
    public func shrunk(right: Int = 0, bottom: Int = 0, left: Int = 0, top: Int = 0) -> CellRange? {
        let c0 = minCol + left, r0 = minRow + top, c1 = maxCol - right, r1 = maxRow - bottom
        guard c1 >= c0, r1 >= r0 else { return nil }
        return CellRange(minRow: r0, minCol: c0, maxRow: r1, maxCol: c1, sheet: sheet)
    }

    /// True when `other` names a sheet and it is not this range's sheet (an unqualified `other` is always compatible).
    public func isOnDifferentSheet(from other: CellRange) -> Bool {
        guard let b = other.sheet else { return false }
        return sheet != b
    }

    /// The smallest range containing both; nil when the sheets differ.
    public func union(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other) else { return nil }
        return CellRange(minRow: Swift.min(minRow, other.minRow), minCol: Swift.min(minCol, other.minCol),
                         maxRow: Swift.max(maxRow, other.maxRow), maxCol: Swift.max(maxCol, other.maxCol), sheet: sheet)
    }
    /// The overlap; nil when disjoint or on different sheets.
    public func intersection(_ other: CellRange) -> CellRange? {
        guard !isOnDifferentSheet(from: other), !isDisjoint(with: other) else { return nil }
        return CellRange(minRow: Swift.max(minRow, other.minRow), minCol: Swift.max(minCol, other.minCol),
                         maxRow: Swift.min(maxRow, other.maxRow), maxCol: Swift.min(maxCol, other.maxCol), sheet: sheet)
    }
    public func isDisjoint(with other: CellRange) -> Bool {
        minCol > other.maxCol || other.minCol > maxCol || minRow > other.maxRow || other.minRow > maxRow
    }
    public func isSubset(of other: CellRange) -> Bool {
        other.minCol <= minCol && maxCol <= other.maxCol && other.minRow <= minRow && maxRow <= other.maxRow
    }
    public func isSuperset(of other: CellRange) -> Bool { other.isSubset(of: self) }
    /// Strict subset ordering.
    public static func < (a: CellRange, b: CellRange) -> Bool { a != b && a.isSubset(of: b) }
    public static func > (a: CellRange, b: CellRange) -> Bool { b < a }

    // MARK: - Enumeration

    public var top: [CellRef] { (minCol...maxCol).map { CellRef(row: minRow, col: $0) } }
    public var bottom: [CellRef] { (minCol...maxCol).map { CellRef(row: maxRow, col: $0) } }
    public var left: [CellRef] { (minRow...maxRow).map { CellRef(row: $0, col: minCol) } }
    public var right: [CellRef] { (minRow...maxRow).map { CellRef(row: $0, col: maxCol) } }
    /// Row by row.
    public var rows: [[CellRef]] { (minRow...maxRow).map { r in (minCol...maxCol).map { CellRef(row: r, col: $0) } } }
    /// Column by column.
    public var cols: [[CellRef]] { (minCol...maxCol).map { c in (minRow...maxRow).map { CellRef(row: $0, col: c) } } }
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
    public var description: String { sorted.map(\.a1).joined(separator: " ") }
    public var sorted: [CellRange] { ranges.sorted { ($0.topLeft, $0.a1) < ($1.topLeft, $1.a1) } }
}
