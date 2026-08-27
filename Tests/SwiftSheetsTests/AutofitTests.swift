import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Column autofit (spec Appendix B.33): the width table, the per-type measurements, and the only-grow rule —
/// all against XlsxWriter's reference behaviour.
@Suite struct AutofitTests {

    /// The width table gives XlsxWriter's own answers: "Hello" is 9+8+4+4+8 = 33 px (checked against the
    /// Python original via ast.literal_eval of its CHAR_WIDTHS).
    @Test func theWidthTableMatchesTheReference() {
        #expect(TextWidth.pixels("Hello") == 33)
        #expect(TextWidth.pixels(" ") == 3 && TextWidth.pixels("%") == 11)
        #expect(TextWidth.pixels("one\nlonger line") == TextWidth.pixels("longer line"), "wrapped text measures its longest line")
    }

    /// The departure from the source, documented in B.33: East Asian text is 16 px a character, not 8.
    @Test func wideCharactersAreSixteenPixels() {
        #expect(TextWidth.pixels("日本語") == 48)
        #expect(TextWidth.pixels("ｶﾀｶﾅ") == 32, "halfwidth katakana is narrow (8 px) — outside the wide blocks")
        #expect(TextWidth.pixels("Ａ１") == 32, "fullwidth forms are wide")
    }

    /// Text, numbers, booleans and dates measure by their own rules; the padding is 7 px.
    @Test func autofitMeasuresByType() {
        var sheet = Sheet(name: "S")
        sheet["A1"] = "Hello"                       // 33 px + 7 → width (40-5)/7
        sheet["B1"] = true                          // TRUE: 31 px
        sheet["C1"] = 123                           // 3 digits × 7 = 21 px
        sheet.autofitColumns()
        #expect(sheet.columnDimensions[0]?.width == (33 + 7 - 5) / 7.0)
        #expect(sheet.columnDimensions[1]?.width == (31 + 7 - 5) / 7.0)
        #expect(sheet.columnDimensions[2]?.width == (21 + 7 - 5) / 7.0)
    }

    /// A column the caller already made wider is not narrowed; a narrower one grows.
    @Test func autofitOnlyGrows() {
        var sheet = Sheet(name: "S")
        sheet["A1"] = "Hi"
        sheet.setWidth(50, ofColumn: 0)
        sheet.autofitColumn(0)
        #expect(sheet.columnDimensions[0]?.width == 50, "a wide column stays wide")
        sheet.setWidth(1, ofColumn: 0)
        sheet.autofitColumn("A")
        #expect(sheet.columnDimensions[0]?.width ?? 0 > 1, "a narrow one grows to fit")
    }

    /// The cap and the filter button: a long text stops at maxWidth, a filtered column gets 16 px more.
    @Test func capAndFilterButton() {
        var sheet = Sheet(name: "S")
        sheet["A1"] = CellValue.text(String(repeating: "w", count: 300))
        sheet.autofitColumn(0, maxWidth: 40)
        #expect(sheet.columnDimensions[0]?.width == 40)

        var filtered = Sheet(name: "F")
        filtered["A1"] = "Hello"
        filtered.autoFilter = CellRange("A1:A9")
        filtered.autofitColumn(0)
        #expect(filtered.columnDimensions[0]?.width == (33 + 16 + 7 - 5) / 7.0)
    }

    /// A formula measures by its cached value; without one it moves nothing.
    @Test func formulasMeasureTheirCachedValue() {
        var sheet = Sheet(name: "S")
        sheet["A1"] = CellValue.formula(FormulaExpr.number(1), cached: .text("cached text"))
        sheet["B1"] = Formula("=A1*2")              // no cached value
        sheet.autofitColumns()
        #expect(sheet.columnDimensions[0]?.width == Double(TextWidth.pixels("cached text") + 7 - 5) / 7.0)
        #expect(sheet.columnDimensions[1]?.width == nil, "nothing measurable, nothing set")
    }
}
