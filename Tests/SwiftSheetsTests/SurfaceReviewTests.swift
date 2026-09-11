import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The last look at the surface before 1.0 (spec Appendix B.89): the behaviour behind each rename, one test apiece.
struct SurfaceReviewTests {
    static let externalLinks = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/preservation/external-links.xlsx")

    /// A reading span is a `Range` now, and a range cannot run backwards: a file saying `eb` < `sb`, or a negative
    /// `sb`, is clamped by the reader instead of trapping it.
    @Test func aBackwardsReadingSpanIsClampedInsteadOfTrapping() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let data = try wb.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: data)
        let patched = sheet.replacingOccurrences(
            of: "<c r=\"A1\" t=\"s\"><v>0</v></c>",
            with: "<c r=\"A1\" t=\"inlineStr\"><is><t>漢字</t><rPh sb=\"2\" eb=\"1\"><t>カ</t></rPh><rPh sb=\"-3\" eb=\"1\"><t>ジ</t></rPh></is></c>")
        #expect(patched != sheet)
        let repacked = try Package.repacking(data, replacing: "xl/worksheets/sheet1.xml", with: Data(patched.utf8))
        let cell = try Workbook.read(repacked, format: .xlsx).workbook.sheets[0][cell: "A1"]
        #expect(cell.phonetic?.runs.map(\.range) == [2..<2, 0..<1], "\(String(describing: cell.phonetic))")
    }

    /// The warning for preserved parts a conversion cannot carry says what they hold, from the inventory, instead of
    /// guessing "charts, drawings, VBA…".
    @Test(arguments: [SheetFormat.ods, .numbers])
    func theLostPartsWarningNamesWhatTheyHold(_ format: SheetFormat) throws {
        let wb = try Workbook(contentsOf: Self.externalLinks)
        let result = try wb.write(as: format)
        let warning = result.warnings.first { $0.message.contains("cannot be carried into") }
        #expect(warning?.message.contains("what they hold:") == true, "\(result.warnings.map(\.message))")
        #expect(warning?.message.contains("externalLink 1") == true, "\(result.warnings.map(\.message))")
        #expect(warning?.message.contains("VBA") == false)
    }

    /// Assigning a theme colour normalises it the way the initialiser does, so `rgb(ofThemeColor:)` answers ARGB.
    @Test func assigningAThemeColourNormalisesIt() {
        var theme = Theme.office
        theme.colors[4] = "#4472c4"
        #expect(theme.colors[4] == "FF4472C4")
        #expect(theme.rgb(ofThemeColor: 4) == "FF4472C4")
    }

    /// A shape made by hand covers one cell, a size both writers agree on, rather than a picture's `.original`.
    @Test func aShapeMadeByHandCoversOneCell() {
        #expect(Shape(.rectangle).anchor == .span(CellRange("A1:A1")!))
    }

    /// `Cell.init` takes a thread like every other extra.
    @Test func aCellIsMadeWithAThread() {
        let cell = Cell(value: "x", thread: CommentThread("Check this", author: "Reviewer"))
        #expect(cell.thread?.text == "Check this")
        #expect(cell.value == .text("x"))
    }

    /// `addSparkline` has a typed twin, and the two agree.
    @Test func aSparklineIsAddedAtATypedCellOrAnAddress() {
        var wb = Workbook()
        wb.addSheet(named: "Typed")
        wb.sheets[0].addSparkline(.column, dataRange: "A1:H1", at: "I1")
        wb.sheets[1].addSparkline(.column, dataRange: "A1:H1", at: CellRef("I1")!)
        #expect(wb.sheets[0].sparklines == wb.sheets[1].sparklines)
        #expect(wb.sheets[0].sparklines.first?.sparklines == [SparklineGroup.Sparkline(dataRange: "A1:H1", at: CellRef("I1")!)])
    }

    /// A table is placed with `at:` whether the place is a cell or a canvas point.
    @Test func aTableIsPlacedAtACellOrAPoint() {
        var sheet = Workbook().sheets[0]
        let byCell = sheet.addTable(named: "ByCell", at: CellRef("D10")!)
        let byPoint = sheet.addTable(named: "ByPoint", at: CanvasPoint(x: 294, y: 180))
        #expect(sheet.tables[byCell].anchor == CellRef("D10")!)
        #expect(sheet.tables[byPoint].anchor == CellRef("D10")!, "the rounded grid view of the point")
        #expect(sheet.tables[byPoint].position == CanvasPoint(x: 294, y: 180))
    }

    /// The canvas values encode like `CellRef`, and the preservation summary can go in a set.
    @Test func canvasValuesAreCodableAndTheSummaryIsHashable() throws {
        let rect = CanvasRect(x: 12.5, y: 40, width: 200, height: 120)
        #expect(try JSONDecoder().decode(CanvasRect.self, from: JSONEncoder().encode(rect)) == rect)
        let wb = try Workbook(contentsOf: Self.externalLinks)
        #expect(Set([wb.preservationSummary, wb.preservationSummary]).count == 1)
    }
}
