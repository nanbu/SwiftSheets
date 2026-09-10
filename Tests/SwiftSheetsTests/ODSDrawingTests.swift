import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
import SwiftSheets

/// Pictures and charts of an ODS file are read into the model, and charts are written as embedded chart documents
/// (spec Appendix B.72) — LibreOffice, where installed, is the judge of what it wrote and what it can read back.
@Suite(.serialized) struct ODSDrawingTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fourCharts = fixtures.appendingPathComponent("drawings/libreoffice-four-charts.ods")
    static func png() throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent("images/tiny.png")) }
    static func same(_ a: String, _ b: String) -> Bool {
        guard let x = CellRange(a.replacingOccurrences(of: "$", with: "")), let y = CellRange(b.replacingOccurrences(of: "$", with: "")) else { return false }
        return x.minRow == y.minRow && x.maxRow == y.maxRow && x.minColumn == y.minColumn && x.maxColumn == y.maxColumn && x.sheet == y.sheet
    }

    @Test func readsLibreOfficesFourCharts() throws {
        let result = try Workbook.read(contentsOf: Self.fourCharts)
        let sheet = result.workbook.sheets[0]
        #expect(sheet.charts.count == 4)
        // document order: LibreOffice walks the cells row by row (E2, M2, E18, M18)
        #expect(sheet.charts.map(\.kind) == [.column, .pie, .line, Chart.Kind(rawValue: "chart:scatter")])
        #expect(sheet.charts.map(\.title) == ["BarChart", "PieChart", "LineChart", "ScatterChart"])
        let bar = sheet.charts[0]
        #expect(bar.series.count == 2 && bar.legend)
        #expect(Self.same(bar.series[0].values, "Data!B2:B4") && Self.same(bar.series[0].categories ?? "", "Data!A2:A4"))
        #expect(Self.same(bar.series[0].nameReference ?? "", "Data!B1:B1"))
        #expect(bar.anchor?.topLeft == CellRef("E2"), "the frame's cell is the anchor")
        #expect((bar.anchor?.maxColumn ?? 0) > 5, "…and its size reaches over the cells to the right")
        // the chart's parts left the opaque store: they are the model's now
        #expect(!result.workbook.preserved.opaqueParts.keys.contains { $0.hasPrefix("Object 1/") || $0 == "ObjectReplacements/Object 1" })
        // and writing back makes fresh chart documents, so nothing is "not re-linked"
        let rewritten = try result.workbook.write(as: .ods)
        #expect(!rewritten.warnings.contains { $0.message.contains("not re-linked") }, "\(rewritten.warnings.map(\.message))")
        let back = try Workbook.read(rewritten.data, format: .ods).workbook.sheets[0]
        #expect(back.charts.map(\.kind) == sheet.charts.map(\.kind) && back.charts.map(\.title) == sheet.charts.map(\.title))
    }

    @Test func aChartAddedHereBecomesAChartDocument() throws {
        var wb = Workbook()
        var s = wb.sheets[0]; s.name = "Sales"
        s.append([.text("Item"), .text("Q1")])
        s.append([.text("A"), .integer(1)]); s.append([.text("B"), .integer(2)]); s.append([.text("C"), .integer(3)])
        var chart = Chart(.bar, title: "Quantities")
        chart.addSeries(values: "B2:B4", categories: "A2:A4", nameReference: "B1")
        s.addChart(chart, over: "D2:K16")
        wb.sheets[0] = s
        let result = try wb.write(as: .ods)
        #expect(!result.warnings.contains { $0.message.contains("chart") }, "\(result.warnings.map(\.message))")
        let content = try Package.part("content.xml", of: result.data)
        #expect(content.contains("<draw:object xlink:href=\"./Object 1\""))
        #expect(content.contains("table:end-cell-address=\"Sales.L17\""))
        let object = try Package.part("Object 1/content.xml", of: result.data)
        #expect(object.contains("chart:class=\"chart:bar\"") && object.contains("chart:vertical=\"true\""))
        #expect(object.contains("chart:values-cell-range-address=\"Sales.B2:Sales.B4\"") && object.contains("<chart:categories table:cell-range-address=\"Sales.A2:Sales.A4\"/>"))
        #expect(object.contains("chart:label-cell-address=\"Sales.B1:Sales.B1\"") && object.contains("<text:p>Quantities</text:p>"))
        let manifest = try Package.part("META-INF/manifest.xml", of: result.data)
        #expect(manifest.contains("manifest:full-path=\"Object 1/\" manifest:media-type=\"application/vnd.oasis.opendocument.chart\""))
        let back = try Workbook.read(result.data, format: .ods).workbook.sheets[0]
        #expect(back.charts.count == 1 && back.charts[0].kind == .bar && back.charts[0].title == "Quantities")
        #expect(back.charts[0].anchor == CellRange("D2:K16")!)
        #expect(Self.same(back.charts[0].series[0].values, "Sales!B2:B4"))
    }

    @Test func picturesReadBack() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try SheetImage(data: Self.png()), at: "B2")
        wb.sheets[0].addImage(try SheetImage(data: Self.png()), over: "D4:F8")
        var absolute = try SheetImage(data: Self.png())
        absolute.anchor = .absolute(x: 72, y: 36, width: 20, height: 10)
        wb.sheets[0].images.append(absolute)
        let data = try wb.write(as: .ods).data
        let result = try Workbook.read(data, format: .ods)
        let back = result.workbook.sheets[0]
        #expect(back.images.count == 3, "\(result.warnings.map(\.message))")
        // document order: the sheet's own shapes come before the cells
        #expect(back.images.contains { $0.anchor == .cell(CellRef("B2")!, sizing: .original) })
        #expect(back.images.contains { $0.anchor == .span(CellRange("D4:F8")!) })
        let absoluteBack = back.images.compactMap { image -> (Double, Double, Double, Double)? in
            if case .absolute(let x, let y, let w, let h) = image.anchor { return (x, y, w, h) } else { return nil }
        }
        #expect(absoluteBack.count == 1)
        if let a = absoluteBack.first { #expect(abs(a.0 - 72) < 0.5 && abs(a.1 - 36) < 0.5 && abs(a.2 - 20) < 0.5 && abs(a.3 - 10) < 0.5) }
        #expect(Set(back.images.map(\.data)) == Set(wb.sheets[0].images.map(\.data)))
        #expect(!result.workbook.preserved.opaqueParts.keys.contains { $0.hasPrefix("Pictures/") }, "the pictures are the model's, not opaque parts")
        let again = try result.workbook.write(as: .ods)
        #expect(!again.warnings.contains { $0.message.contains("not re-linked") })
        #expect(try Workbook.read(again.data, format: .ods).workbook.sheets[0].images.count == 3)
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeCarriesTheChartIntoXLSX() throws {
        var wb = Workbook()
        var s = wb.sheets[0]; s.name = "Data"
        s.append([.text("Item"), .text("Q1")]); s.append([.text("A"), .integer(1)]); s.append([.text("B"), .integer(2)])
        var chart = Chart(.column, title: "T")
        chart.addSeries(values: "B2:B3", categories: "A2:A3", nameReference: "B1")
        s.addChart(chart, over: "D2:J12")
        wb.sheets[0] = s
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsODSChart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ods = dir.appendingPathComponent("chart.ods")
        _ = try wb.write(to: ods)
        let xlsx = try ODSImageTests.convert(ods, to: "xlsx")
        let sheet = try Workbook(contentsOf: xlsx).sheets[0]
        #expect(sheet.charts.count == 1, "LibreOffice rebuilt the chart on its way to Excel")
        #expect(sheet.charts.first?.kind == .column && sheet.charts.first?.title == "T")
    }
}
