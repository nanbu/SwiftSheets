import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Pictures and charts of an opened XLSX file are read into `sheet.images` / `sheet.charts` (spec Appendix B.72).
/// Untouched, the drawing and its parts are written back byte for byte; an addition is spliced in; a change or a
/// removal rebuilds the drawing from the model and says what that costs.
struct DrawingReadTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fourCharts = fixtures.appendingPathComponent("drawings/openpyxl-four-charts.xlsx")
    static let chartsAndFriends = fixtures.appendingPathComponent("preservation/charts-and-friends.xlsx")
    static func png() throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("images/tiny.png")) }

    @Test func readsFourChartsIncludingOneTheWriterCannotDraw() throws {
        let sheet = try Workbook(contentsOf: Self.fourCharts).sheets[0]
        #expect(sheet.charts.count == 4)
        #expect(sheet.charts.map(\.kind) == [.column, .line, .pie, Chart.Kind(rawValue: "scatterChart")])
        #expect(sheet.charts.map(\.title) == ["BarChart", "LineChart", "PieChart", "ScatterChart"])
        let bar = sheet.charts[0]
        #expect(bar.series.count == 2 && bar.legend)
        #expect(bar.series[0].values == "'Data'!$B$2:$B$4" && bar.series[0].categories == "'Data'!$A$2:$A$4")
        #expect(bar.series[0].nameReference == "'Data'!B1" && bar.series[0].name == nil)
        #expect(bar.anchor?.topLeft == CellRef("E2"), "a one-cell anchor starts where it says")
        #expect((bar.anchor?.maxColumn ?? 0) > 5 && (bar.anchor?.maxRow ?? 0) > 2, "…and reaches over the cells its extent covers")
        let scatter = sheet.charts[3]
        #expect(scatter.series[0].values == "'Data'!$C$2:$C$4" && scatter.series[0].categories == "'Data'!$B$2:$B$4", "yVal is the values, xVal the categories")
    }

    @Test func untouchedChartsAreWrittenBackByteForByte() throws {
        let source = try Data(contentsOf: Self.fourCharts)
        let wb = try Workbook(contentsOf: Self.fourCharts)
        let result = try wb.write(as: .xlsx)
        for part in ["xl/drawings/drawing1.xml", "xl/drawings/_rels/drawing1.xml.rels", "xl/charts/chart1.xml", "xl/charts/chart4.xml"] {
            #expect(try Package.part(part, of: result.data) == Package.part(part, of: source), Comment(rawValue: part))
        }
        #expect(!result.warnings.contains { $0.message.contains("chart") }, "\(result.warnings.map(\.message))")
        #expect(try Workbook.read(result.data, format: .xlsx).workbook.sheets[0].charts == wb.sheets[0].charts)
    }

    @Test func aChangedChartRebuildsTheDrawingAndSaysWhatItCosts() throws {
        var wb = try Workbook(contentsOf: Self.fourCharts)
        wb.sheets[0].charts[0].title = "Renamed"
        let result = try wb.write(as: .xlsx)
        let sheetXML = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        #expect(sheetXML.components(separatedBy: "<drawing ").count == 2, "exactly one <drawing> element")
        #expect(try Package.part("xl/drawings/drawing1.xml", of: result.data).contains("xdr:twoCellAnchor"), "regenerated in this writer's form")
        let charts = try ZipInspection(data: result.data).entryNames.filter { $0.hasPrefix("xl/charts/") }.sorted()
        #expect(charts.count == 3, "the scatter chart cannot be drawn by this writer: \(charts)")
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("a scatterChart chart was not written") })
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back.charts.count == 3 && back.charts[0].title == "Renamed")
        #expect(back.charts[0].series[0].nameReference == "'Data'!B1", "a name reference is written back as a reference")
    }

    @Test func pictureReadBackAndRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try SheetImage(data: Self.png()), at: "B2", sizing: .scaled(width: 40, height: 30))
        wb.sheets[0].addImage(try SheetImage(data: Self.png()), over: "D4:F8")
        var absolute = try SheetImage(data: Self.png())
        absolute.anchor = .absolute(CanvasRect(x: 100, y: 50, width: 20, height: 10))
        wb.sheets[0].images.append(absolute)
        let data = try wb.write(as: .xlsx).data
        let backWB = try Workbook.read(data, format: .xlsx).workbook
        let back = backWB.sheets[0]
        #expect(back.images.count == 3)
        #expect(back.images[0].anchor == .cell(CellRef("B2")!, sizing: .scaled(width: 40, height: 30)))
        #expect(back.images[1].anchor == .span(CellRange("D4:F8")!))
        #expect(back.images[2].anchor == .absolute(CanvasRect(x: 100, y: 50, width: 20, height: 10)))
        #expect(back.images.map(\.data) == wb.sheets[0].images.map(\.data))
        #expect(back.images[0].format == .png)

        // untouched: bytes; an added picture: spliced beside the kept ones; a removed one: rebuilt
        let again = try backWB.write(as: .xlsx).data
        #expect(try Package.part("xl/drawings/drawing1.xml", of: again) == Package.part("xl/drawings/drawing1.xml", of: data))
        var added = backWB
        added.sheets[0].images.append(try SheetImage(data: Self.png()))
        let spliced = try added.write(as: .xlsx).data
        #expect(try Package.part("xl/drawings/drawing1.xml", of: spliced).hasPrefix(Package.part("xl/drawings/drawing1.xml", of: data).dropLast("</xdr:wsDr>".count)))
        #expect(try Workbook.read(spliced, format: .xlsx).workbook.sheets[0].images.count == 4)
        var removed = backWB
        removed.sheets[0].images.removeFirst()
        let rebuilt = try removed.write(as: .xlsx).data
        #expect(try Workbook.read(rebuilt, format: .xlsx).workbook.sheets[0].images.map(\.anchor) == [.span(CellRange("D4:F8")!), .absolute(CanvasRect(x: 100, y: 50, width: 20, height: 10))])
        #expect(try ZipInspection(data: rebuilt).entryNames.filter { $0.hasPrefix("xl/media/") }.count == 2, "the retired picture's media part is gone")
        var none = backWB
        none.sheets[0].images = []
        let bare = try none.write(as: .xlsx).data
        #expect(!(try Package.part("xl/worksheets/sheet1.xml", of: bare)).contains("<drawing "))
    }

    /// A file whose drawing holds a chart the model reads and a picture in a format it does not: the picture is
    /// noted, the chart is read, and only a change costs the picture.
    @Test func whatTheModelCannotHoldIsNotedAndOnlyAChangeDropsIt() throws {
        let wb = try Workbook(contentsOf: Self.chartsAndFriends)
        let sheet = try #require(wb.sheets.first { !$0.charts.isEmpty })
        #expect(sheet.charts[0].kind == .column && sheet.charts[0].title == "Quantities")
        #expect(try wb.write(as: .xlsx).warnings.allSatisfy { !$0.message.contains("drawing was rebuilt") })
    }
}
