import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// The workbook's theme is read from the theme part, resolves theme and indexed colours to RGB, and is what the
/// writers for formats without a theme (ODS, Numbers) draw their colours from (spec Appendix B.70).
struct ThemeTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/preservation/charts-and-friends.xlsx")

    @Test func readsTheThemePart() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let theme = try #require(wb.theme)
        #expect(theme.colors[3] == "FF1F497D", "dark 2 is index 3")
        #expect(theme.colors[4] == "FF4F81BD", "accent 1 is index 4")
        #expect(theme.colors[0] == "FFFFFFFF" && theme.colors[1] == "FF000000", "the system colours come from lastClr")
        #expect(theme.minorFont == "Calibri")
        #expect(wb.rgb(of: .theme(4)) == "FF4F81BD")
    }

    @Test func excelsTintsAreReproduced() {
        let wb = Workbook()   // no theme of its own: Theme.office
        #expect(wb.rgb(of: .theme(0, tint: -0.05)) == "FFF2F2F2", "white, darker 5%")
        #expect(wb.rgb(of: .theme(0, tint: -0.15)) == "FFD9D9D9")
        #expect(wb.rgb(of: .theme(0, tint: -0.25)) == "FFBFBFBF")
        #expect(wb.rgb(of: .theme(0, tint: -0.35)) == "FFA6A6A6")
        #expect(wb.rgb(of: .theme(0, tint: -0.5)) == "FF808080")
        #expect(wb.rgb(of: .theme(1, tint: 0.5)) == "FF808080", "black, lighter 50%")
        #expect(wb.rgb(of: .theme(1)) == "FF000000")
        #expect(wb.rgb(of: .theme(12)) == nil)
        #expect(wb.rgb(of: .indexed(2)) == "FFFF0000" && wb.rgb(of: .indexed(64)) == "FF000000")
        #expect(wb.rgb(of: .rgb("ff8800")) == "FFFF8800" && wb.rgb(of: .auto) == nil)
        var custom = wb
        custom.indexedColors = ["00112233"]
        #expect(custom.rgb(of: .indexed(0)) == "00112233", "the file's own palette wins")
    }

    /// ODS has no theme, so the writer draws the colour the theme resolves to instead of black plus a warning.
    @Test func odsWritesTheResolvedColour() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].setStyle("A1") { $0.fill = .solid(.theme(4)); $0.font.color = .indexed(2); $0.border.left = Side(style: .thin, color: .theme(0, tint: -0.5)) }
        let result = try wb.write(as: .ods)
        #expect(!result.warnings.contains { $0.message.contains("theme/indexed colours") }, "\(result.warnings.map(\.message))")
        let content = try Package.part("content.xml", of: result.data)
        #expect(content.contains("fo:background-color=\"#4472c4\""))
        #expect(content.contains("fo:color=\"#ff0000\""))
        #expect(content.contains("#808080"))
        let back = try Workbook.read(result.data, format: .ods).workbook
        #expect(back.sheets[0].style("A1").fill.foregroundColor == .rgb("FF4472C4"))
    }

    @Test func numbersWritesTheResolvedColour() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].setStyle("A1") { $0.fill = .solid(.theme(5)) }
        let back = try Workbook.read(try wb.write(as: .numbers).data, format: .numbers).workbook
        #expect(back.sheets[0].style("A1").fill.foregroundColor == .rgb("FFED7D31"))
    }

    /// A fresh workbook's theme part is generated from `wb.theme`; a source's theme travels as bytes until the
    /// model's theme differs, and is then regenerated under the same path.
    @Test func theThemePartFollowsTheModel() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        var theme = Theme.office
        theme.colors[4] = "FF112233"
        theme.minorFont = "Meiryo"
        wb.theme = theme
        let data = try wb.write(as: .xlsx).data
        let part = try Package.part("xl/theme/theme1.xml", of: data)
        #expect(part.contains("<a:accent1><a:srgbClr val=\"112233\"/></a:accent1>") && part.contains("typeface=\"Meiryo\""))
        #expect(try Workbook.read(data, format: .xlsx).workbook.theme == theme)

        let source = try Workbook(contentsOf: Self.fixture)
        let sourceTheme = try Package.part("xl/theme/theme1.xml", of: try Data(contentsOf: Self.fixture))
        let untouched = try source.write(as: .xlsx).data
        #expect(try Package.part("xl/theme/theme1.xml", of: untouched) == sourceTheme, "an untouched theme is the same bytes")
        var edited = source
        edited.theme!.colors[4] = "FFABCDEF"
        let rewritten = try edited.write(as: .xlsx).data
        let rewrittenPart = try Package.part("xl/theme/theme1.xml", of: rewritten)
        #expect(rewrittenPart != sourceTheme && rewrittenPart.contains("ABCDEF"))
        #expect(try Workbook.read(rewritten, format: .xlsx).workbook.theme == edited.theme)
    }
}
