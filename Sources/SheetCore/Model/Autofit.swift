import Foundation

/// The pixel width of text in Excel's default face, and the column autofit built on it (spec Appendix B.33).
///
/// Translated from XlsxWriter (BSD-2 — see NOTICE): `CHAR_WIDTHS` is that project's measurement of Calibri 11,
/// pixel by pixel, for the 95 printable ASCII characters; everything else falls back to 8 px there. One
/// deliberate departure: East Asian wide characters get 16 px here, since 8 px would fold Japanese text in half.
/// An approximation either way — the true width depends on the workbook's default font, which viewers themselves
/// only approximate.
public enum TextWidth {
    /// Pixel widths of U+0020…U+007E in Calibri 11 (XlsxWriter's `CHAR_WIDTHS`).
    static let ascii: [Int] = [3, 5, 6, 7, 7, 11, 10, 3, 5, 5, 7, 7, 4, 5, 4, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
                               4, 4, 7, 7, 7, 7, 13, 9, 8, 8, 9, 7, 7, 9, 9, 4, 5, 8, 6, 12, 10, 10, 8, 10, 8,
                               7, 7, 9, 9, 13, 8, 7, 7, 5, 6, 5, 7, 7, 4, 7, 8, 6, 8, 8, 5, 7, 8, 4, 4, 7, 4,
                               12, 8, 8, 8, 8, 5, 6, 5, 8, 7, 11, 7, 7, 6, 5, 7, 5, 7]

    /// One character's width in pixels.
    public static func pixels(_ scalar: Unicode.Scalar) -> Int {
        if (0x20...0x7E).contains(scalar.value) { return ascii[Int(scalar.value) - 0x20] }
        return isEastAsianWide(scalar) ? 16 : 8
    }

    /// The width of one line of text in pixels (the longest line, when the text wraps).
    public static func pixels(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.unicodeScalars.reduce(0) { $0 + pixels($1) } }
            .max() ?? 0
    }

    /// The blocks Unicode renders double-width: CJK, kana, hangul, fullwidth forms. The ranges of East Asian
    /// Width classes W and F, coarsened to whole blocks.
    static func isEastAsianWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,       // Hangul Jamo
             0x2E80...0x303E,       // CJK Radicals … CJK Symbols and Punctuation
             0x3041...0x33FF,       // Hiragana … CJK Compatibility
             0x3400...0x4DBF,       // CJK Extension A
             0x4E00...0x9FFF,       // CJK Unified Ideographs
             0xA000...0xA4CF,       // Yi
             0xAC00...0xD7A3,       // Hangul Syllables
             0xF900...0xFAFF,       // CJK Compatibility Ideographs
             0xFE30...0xFE4F,       // CJK Compatibility Forms
             0xFF00...0xFF60,       // Fullwidth Forms
             0xFFE0...0xFFE6,
             0x20000...0x3FFFD:     // CJK Extensions B and beyond
            return true
        default:
            return false
        }
    }
}

extension Sheet {
    /// Sizes one column to its content, the way Excel's own double-click does — approximately (Appendix B.33).
    /// A column the caller already made wider keeps its width; the fit only ever grows it.
    public mutating func autofitColumn(_ col: Int, maxWidth: Double = 255) {
        guard let extent else { return }
        var maxPixels = 0
        for row in extent.minRow...extent.maxRow {
            guard let cell = table.cells[CellRef(row: row, col: col)] else { continue }
            maxPixels = max(maxPixels, Self.contentPixels(cell))
        }
        guard maxPixels > 0 else { return }
        if let filter = autoFilter, (filter.minCol...filter.maxCol).contains(col) { maxPixels += 16 }
        let width = min(CellPixels.columnWidth(forPixels: Double(maxPixels + 7)), maxWidth)
        let existing = columnDimensions[col]?.width
        if existing == nil || width > existing! { setWidth(width, ofColumn: col) }
    }

    /// A1 form of `autofitColumn(_:maxWidth:)`. An unparseable column name is a programmer error, as with subscripts.
    public mutating func autofitColumn(_ name: String, maxWidth: Double = 255) {
        autofitColumn(CellRef.columnIndex(name)!, maxWidth: maxWidth)
    }

    /// Sizes every column that holds anything.
    public mutating func autofitColumns(maxWidth: Double = 255) {
        guard let extent else { return }
        for col in extent.minCol...extent.maxCol { autofitColumn(col, maxWidth: maxWidth) }
    }

    /// XlsxWriter's per-type measurements: text by the width table, numbers seven pixels a digit, dates a fixed
    /// stretch, TRUE and FALSE their rendered widths, formulas by their cached value — or not at all.
    static func contentPixels(_ cell: Cell) -> Int {
        guard let value = cell.value else { return 0 }
        return valuePixels(value)
    }

    private static func valuePixels(_ value: CellValue) -> Int {
        switch value {
        case .text, .richText: TextWidth.pixels(value.stringValue)
        case .integer, .number: 7 * value.stringValue.count
        case .date, .time, .duration: 68
        case .bool(let b): b ? 31 : 36
        case .formula(_, let cached): cached.map(valuePixels) ?? 0
        case .error: TextWidth.pixels(value.stringValue)
        }
    }
}
