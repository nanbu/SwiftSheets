import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// Charts on a Numbers canvas (spec Appendix B.88): read from the mediator's formulas, written as the same objects
/// Numbers writes, and judged by Numbers saving the document again and exporting it to Excel.
@Suite struct NumbersChartTests {
    static func fixture(_ name: String) throws -> Workbook {
        try Workbook(data: try Data(contentsOf: NumbersCanvasTests.fixtures.appendingPathComponent(name)))
    }

    @Test func readsTheChartNumbersMade() throws {
        let wb = try Self.fixture("chart-and-control-15.numbers")
        let sheet = try #require(wb.sheets.first { !$0.charts.isEmpty })
        let chart = sheet.charts[0]
        #expect(chart.kind == .column)
        #expect(chart.title == "qty")
        #expect(chart.legend == true)
        try #require(chart.series.count == 1)
        #expect(chart.series[0].values.hasSuffix("!$B$2:$B$4"), Comment(rawValue: chart.series[0].values))
        #expect(chart.series[0].categories?.hasSuffix("!$A$2:$A$4") == true, Comment(rawValue: chart.series[0].categories ?? "nil"))
        #expect(chart.series[0].nameReference?.hasSuffix("!$B$1") == true, Comment(rawValue: chart.series[0].nameReference ?? "nil"))
        let f = try #require(chart.frame)
        #expect(NumbersCanvasTests.points(.absolute(f)) == [225, 61, 373, 153])
        #expect(chart.anchor == nil && chart.anchorOrFrameCells != nil)
        #expect(!wb.readWarnings.contains { $0.message.contains("a chart") }, "\(wb.readWarnings.map(\.message))")
    }

    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Data"
        let s = wb.sheets[0]
        _ = s
        wb.sheets[0]["A1"] = "Month"; wb.sheets[0]["B1"] = "Sales"; wb.sheets[0]["C1"] = "Cost"
        for (i, (m, v, c)) in [("Jan", 10.0, 4.0), ("Feb", 20.0, 6.0), ("Mar", 15.0, 5.0)].enumerated() {
            wb.sheets[0][CellRef(row: i + 2, column: 1)] = CellValue(m)
            wb.sheets[0][CellRef(row: i + 2, column: 2)] = CellValue(v)
            wb.sheets[0][CellRef(row: i + 2, column: 3)] = CellValue(c)
        }
        var chart = Chart(.column, title: "Sales by month")
        chart.addSeries(values: "Data!$B$2:$B$4", categories: "Data!$A$2:$A$4", nameReference: "Data!$B$1")
        chart.addSeries(values: "Data!$C$2:$C$4", categories: "Data!$A$2:$A$4", name: "Cost")
        wb.sheets[0].addChart(chart, over: "E2:K12")
        return wb
    }

    @Test func writesAChartAndReadsItBack() throws {
        let result = try Self.workbook().write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("chart") }, "\(result.warnings.map(\.message))")
        let back = try Workbook(data: result.data).sheets[0]
        try #require(back.charts.count == 1)
        let chart = back.charts[0]
        #expect(chart.kind == .column && chart.title == "Sales by month" && chart.legend)
        try #require(chart.series.count == 2)
        #expect(chart.series[0].values == "'Data::Table 1'!$B$2:$B$4")
        #expect(chart.series[0].categories == "'Data::Table 1'!$A$2:$A$4")
        #expect(chart.series[0].nameReference == "'Data::Table 1'!$B$1")
        #expect(chart.series[1].values == "'Data::Table 1'!$C$2:$C$4")
        let f = try #require(chart.frame)
        #expect(NumbersCanvasTests.points(.absolute(f)) == [4 * 98, 20, 7 * 98, 219], "E2:K12 on the default grid")
        // the package: one mediator, registered with the engine as an owner of kind 2
        let doc = try NumbersDocument(data: result.data)
        let mediators = doc.identifiers(ofType: "TN.ChartMediatorArchive")
        #expect(mediators.count == 1)
        let owners = doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive").compactMap { doc.object($0) }
        #expect(owners.contains { $0.int("owner_kind") == 2 && $0.reference("formula_owner") != nil })
    }

    @Test func otherKindsAndUnlinkedSeriesAreNamed() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var scatter = Chart(Chart.Kind(rawValue: "scatterChart"))
        scatter.addSeries(values: "A1:A2")
        wb.sheets[0].addChart(scatter, over: "C1:F5")
        var lost = Chart(.pie)
        lost.addSeries(values: "Nowhere!$A$1:$A$3")
        wb.sheets[0].addChart(lost, over: "C6:F9")
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("scatterChart chart was not written") }, "\(result.warnings.map(\.message))")
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("pie chart with no series on a table of this workbook") })
        #expect(try Workbook(data: result.data).sheets[0].charts.isEmpty)
    }

    /// What Numbers made survives a pass through the writer.
    @Test func numbersOwnChartSurvivesOurWriter() throws {
        let wb = try Self.fixture("chart-and-control-15.numbers")
        let back = try Workbook(data: try wb.write(as: .numbers).data)
        let a = try #require(wb.sheets.first { !$0.charts.isEmpty }?.charts.first)
        let b = try #require(back.sheets.first { !$0.charts.isEmpty }?.charts.first)
        #expect(a.kind == b.kind && a.title == b.title && a.series.map(\.values) == b.series.map(\.values))
    }

    /// Numbers itself opens the written chart, saves it again and exports it: the chart is still a column chart
    /// over the same cells, and Excel gets a chart part.
    @Test(.enabled(if: NumbersCanvasTests.numbersCanJudge, "Numbers.app is not here, or this terminal may not drive it"))
    func numbersItselfKeepsTheChart() throws {
        let stage = NumbersCanvasTests.stage
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let written = stage.appending(path: "chart.numbers")
        try Self.workbook().write(as: .numbers).data.write(to: written)
        let resaved = stage.appending(path: "chart-resaved.numbers")
        let run = try #require(NumbersCanvasTests.numbersApp(["resave", written.path, resaved.path]))
        try #require(run.status == 0, Comment(rawValue: "Numbers did not save the document again: \(run.output)"))
        let back = try Workbook(data: try Data(contentsOf: resaved)).sheets[0]
        try #require(back.charts.count == 1, Comment(rawValue: "Numbers kept \(back.charts.count) chart(s)"))
        #expect(back.charts[0].kind == .column)
        #expect(back.charts[0].series.map(\.values) == ["'Data::Table 1'!$B$2:$B$4", "'Data::Table 1'!$C$2:$C$4"])
        let exported = stage.appending(path: "chart-exported.xlsx")
        let export = try #require(NumbersCanvasTests.numbersApp(["export", written.path, exported.path]))
        try #require(export.status == 0, Comment(rawValue: "Numbers did not export: \(export.output)"))
        let excel = try Workbook(data: try Data(contentsOf: exported))
        #expect(excel.sheets[0].charts.count == 1, "the chart reached Excel")
        #expect(excel.sheets[0].charts.first?.kind == .column)
    }
}
