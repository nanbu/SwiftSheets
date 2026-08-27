import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Charts built with `addChart` (spec Appendix B.34): the part, its anchor, reference qualification, the shared
/// drawing with pictures, and the counted losses elsewhere.
@Suite struct ChartTests {

    /// An unqualified range gains the sheet's name and absolute dollars; a qualified one passes untouched.
    @Test func referencesAreQualifiedForTheChart() {
        #expect(ChartParts.qualify("B2:B13", sheet: "Data") == "Data!$B$2:$B$13")
        #expect(ChartParts.qualify("B2:B13", sheet: "月次 売上") == "'月次 売上'!$B$2:$B$13")
        #expect(ChartParts.qualify("'集計'!$B$2:$B$13", sheet: "Data") == "'集計'!$B$2:$B$13")
    }

    /// A column chart gets the whole kit: part, content type, graphic-frame anchor, axes wired to each other.
    @Test func aColumnChartGrowsAWholePart() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = "月"; sheet["B1"] = "売上"
        for i in 0..<3 { sheet[i + 1, 0] = CellValue.text("m\(i)"); sheet[i + 1, 1] = CellValue.integer(i * 100) }
        var chart = Chart(.column, title: "月次売上")
        chart.addSeries(values: "B2:B4", categories: "A2:A4", name: "売上")
        sheet.addChart(chart, over: "D2:K16")
        wb.sheets[0] = sheet
        let data = try wb.data(as: .xlsx)

        let part = try Package.part("xl/charts/chart1.xml", of: data)
        #expect(part.contains("<c:barChart><c:barDir val=\"col\"/>"))
        #expect(part.contains("<c:f>Sheet1!$B$2:$B$4</c:f>"), "values qualified with the host sheet")
        #expect(part.contains("<c:v>売上</c:v>") && part.contains("<a:t>月次売上</a:t>"))
        #expect(part.contains("<c:catAx>") && part.contains("<c:valAx>") && part.contains("<c:legend>"))

        let drawing = try Package.part("xl/drawings/drawing1.xml", of: data)
        #expect(drawing.contains("<xdr:graphicFrame") && drawing.contains("r:id=\"rId1\""))
        #expect(drawing.contains("<xdr:to><xdr:col>11</xdr:col>"), "K16's far corner is one past")
        #expect(try Package.part("xl/drawings/_rels/drawing1.xml.rels", of: data).contains("chart1.xml"))
        #expect(try Package.part("[Content_Types].xml", of: data).contains("PartName=\"/xl/charts/chart1.xml\""))
    }

    /// The pie has no axes; the bar flips its direction; the line smooths nothing.
    @Test func eachKindWritesItsOwnShape() throws {
        func part(_ kind: Chart.Kind) throws -> String {
            var wb = Workbook()
            wb.sheets[0]["A1"] = 1
            var chart = Chart(kind)
            chart.addSeries(values: "A1:A3")
            chart.legend = false
            wb.sheets[0].addChart(chart, over: "C1:H10")
            return try Package.part("xl/charts/chart1.xml", of: try wb.data(as: .xlsx))
        }
        let pie = try part(.pie)
        #expect(pie.contains("<c:pieChart>") && !pie.contains("<c:catAx>") && !pie.contains("<c:legend>"))
        #expect(try part(.bar).contains("<c:barDir val=\"bar\"/>"))
        #expect(try part(.line).contains("<c:lineChart>"))
    }

    /// A chart and a picture share one drawing part — and adding both to a sheet that already had a chart from
    /// its source file splices them after the preserved bytes.
    @Test func chartsAndPicturesShareTheDrawing() throws {
        let original = try PreservationTests.fixture("charts-and-friends.xlsx")
        var wb = try XLSXCodec.read(original).workbook
        let sourceChart = try Package.part("xl/charts/chart1.xml", of: original)

        wb.sheets[0].addImage(try ImageTests.image("tiny.png"), at: "H2")
        var chart = Chart(.pie)
        chart.addSeries(values: "B2:B4")
        wb.sheets[0].addChart(chart, over: "H8:M20")
        let data = try XLSXCodec.write(wb).data

        #expect(try Package.part("xl/charts/chart1.xml", of: data) == sourceChart, "the source's chart is untouched")
        #expect(try Package.part("xl/charts/chart2.xml", of: data).contains("<c:pieChart>"), "ours is numbered after it")
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: data)
        #expect(drawing.contains("<xdr:pic>") && drawing.contains("<xdr:graphicFrame"))
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: data).matches(of: #/<drawing /#).count == 1)
    }

    /// Several charts and a picture on a fresh sheet share one generated drawing, relationships numbered in order.
    @Test func manyChartsAndAPictureOnAFreshSheet() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].addImage(try ImageTests.image("tiny.png"), at: "A3")
        for (i, kind) in [Chart.Kind.column, .line, .pie].enumerated() {
            var chart = Chart(kind)
            chart.addSeries(values: "A1:A2")
            wb.sheets[0].addChart(chart, over: CellRange("C\(i * 12 + 1):J\(i * 12 + 10)")!)
        }
        let data = try wb.data(as: .xlsx)
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: data)
        #expect(drawing.matches(of: #/<xdr:graphicFrame/#).count == 3 && drawing.contains("<xdr:pic>"))
        let rels = try Package.part("xl/drawings/_rels/drawing1.xml.rels", of: data)
        for n in 1...4 { #expect(rels.contains("Id=\"rId\(n)\""), "relationships run rId1…rId4 in order") }
        for n in 1...3 { #expect(try Package.part("xl/charts/chart\(n).xml", of: data) != "", "chart\(n).xml exists") }
    }

    /// The B.22 nail for charts: our own output, read and saved again, changes not a byte.
    @Test func theSecondSaveChangesNothing() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var chart = Chart(.line, title: "t")
        chart.addSeries(values: "A1:A5")
        wb.sheets[0].addChart(chart, over: "C1:J12")
        let first = try wb.data(as: .xlsx)
        let back = try Workbook(data: first)
        #expect(back.sheets[0].charts.isEmpty, "our own chart reads back as preserved bytes, not as a model chart")
        let second = try back.data(as: .xlsx)
        for part in ["xl/charts/chart1.xml", "xl/drawings/drawing1.xml", "xl/drawings/_rels/drawing1.xml.rels"] {
            #expect(try ZipInspection(data: second).entry(named: part) == ZipInspection(data: first).entry(named: part),
                    "\(part) must survive the second save byte for byte")
        }
    }

    /// A chart with no series is not invented; the formats with no place for charts count them out loud.
    @Test func emptyChartsAndOtherFormatsSpeakUp() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].addChart(Chart(.column), over: "C1:H10")
        let result = try wb.write(to: URL(filePath: NSTemporaryDirectory() + "chart-empty.xlsx"))
        #expect(result.warnings.contains { $0.message.contains("no series") })
        #expect(try ZipInspection(data: try wb.data(as: .xlsx)).entry(named: "xl/charts/chart1.xml") == nil)

        var full = Workbook()
        full.sheets[0]["A1"] = 1
        var chart = Chart(.pie)
        chart.addSeries(values: "A1:A2")
        full.sheets[0].addChart(chart, over: "C1:H10")
        for format in [SheetFormat.ods, .numbers, .csv] {
            let r = try full.write(to: URL(filePath: NSTemporaryDirectory() + "chart-drop.\(format.rawValue)"), as: format)
            #expect(r.warnings.contains { $0.kind == .dropped && $0.message.contains("1 chart(s)") },
                    "\(format.rawValue) must count the chart out loud")
        }
    }
}
