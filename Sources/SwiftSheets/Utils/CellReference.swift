import Foundation

/// "A1"-style coordinates. 1-based column and row.
public struct CellReference: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let column: Int
    public let row: Int

    public init(column: Int, row: Int) { self.column = column; self.row = row }

    /// Parses "A1", "$B$2", "AB12". Returns nil when malformed.
    public init?(_ ref: String) {
        var col = 0, row = 0, seenDigit = false
        for ch in ref.uppercased().unicodeScalars {
            if ch == "$" { continue }
            if ("A"..."Z").contains(ch), !seenDigit { col = col * 26 + Int(ch.value - 64) }
            else if ("0"..."9").contains(ch) { seenDigit = true; row = row * 10 + Int(ch.value - 48) }
            else { return nil }
        }
        guard col > 0, row > 0 else { return nil }
        self.column = col; self.row = row
    }

    public var columnLetter: String { CellReference.columnLetter(column) }
    public var description: String { columnLetter + String(row) }
    public static func < (a: CellReference, b: CellReference) -> Bool { a.row != b.row ? a.row < b.row : a.column < b.column }

    /// 1 → "A", 28 → "AB" (openpyxl.utils.get_column_letter).
    public static func columnLetter(_ col: Int) -> String {
        var n = col, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(UInt8(65 + r))) + s; n = (n - 1) / 26 }
        return s
    }

    /// "AB" → 28 (openpyxl.utils.column_index_from_string).
    public static func columnIndex(_ letters: String) -> Int? {
        var n = 0
        for ch in letters.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(ch) else { return nil }
            n = n * 26 + Int(ch.value - 64)
        }
        return n > 0 ? n : nil
    }
}

/// A rectangular range such as "A1:C3".
public struct CellRange: Hashable, Sendable, CustomStringConvertible {
    public var minColumn: Int, minRow: Int, maxColumn: Int, maxRow: Int

    public init(minColumn: Int, minRow: Int, maxColumn: Int, maxRow: Int) {
        self.minColumn = minColumn; self.minRow = minRow; self.maxColumn = maxColumn; self.maxRow = maxRow
    }

    public init?(_ ref: String) {
        let parts = ref.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let a = CellReference(parts[0]) else { return nil }
        let b = parts.count > 1 ? CellReference(parts[1]) : a
        guard let b else { return nil }
        self.init(minColumn: min(a.column, b.column), minRow: min(a.row, b.row), maxColumn: max(a.column, b.column), maxRow: max(a.row, b.row))
    }

    public var description: String {
        "\(CellReference.columnLetter(minColumn))\(minRow):\(CellReference.columnLetter(maxColumn))\(maxRow)"
    }

    public func contains(_ ref: CellReference) -> Bool {
        (minColumn...maxColumn).contains(ref.column) && (minRow...maxRow).contains(ref.row)
    }
}
