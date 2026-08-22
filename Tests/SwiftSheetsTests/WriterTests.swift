import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

@Suite struct WriterTests {
    /// Build a workbook with every feature, save, reload with our own reader — everything must survive.
    @Test func roundTripThroughOurselves() throws {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws.name = "Plan"
        ws["A1"] = "Title"; ws[cell: "A1"].font = Font(name: "Arial", size: 14, bold: true, color: .rgb("FF112233"))
        ws[0, 1] = 42
        ws[0, 2] = 3.5
        ws[0, 3] = true
        ws[0, 4] = CellValue(CivilDate(year: 2026, month: 9, day: 1)!); ws[cell: CellRef(row: 0, col: 4)].numberFormat = "yyyy/m/d"
        ws[0, 5] = .formula(FormulaExpr.parse("=B1*2"), cached: .integer(84))
        ws[0, 6] = .number(0.25); ws[cell: CellRef(row: 0, col: 6)].numberFormat = "0%"
        ws[1, 0] = "  padded  "
        ws["B2"] = "multi\nline"; ws[cell: "B2"].alignment = Alignment(horizontal: .center, vertical: .top, wrapText: true)
        ws[cell: "C2"].fill = .solid(.rgb("FFBFD7F5"))
        ws[cell: "D2"].border = Border(left: Side(style: .thin, color: .rgb("FF888888")), right: Side(style: .medium))
        ws["E2"] = "<A&B> \"q\" 日本語"
        ws["F2"] = .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))])
        ws["G2"] = .time(TimeOfDay(hour: 9, minute: 30)); ws[cell: "G2"].numberFormat = "h:mm"
        ws["H2"] = .error("#N/A")
        ws.merge("A3:C3"); ws["A3"] = "merged"
        ws.freezePanes(at: "B2")
        ws.setWidth(20, ofColumn: 0); ws.setColumnDimension("C") { $0.hidden = true }
        ws.setRowDimension(1) { $0.height = 30 }
        ws.setRowDimension(3) { $0.hidden = true; $0.outlineLevel = 1 }
        ws.setRowDimension(4) { $0.outlineLevel = 1; $0.collapsed = true }
        ws["A6"] = "link"; ws[cell: "A6"].hyperlink = Hyperlink(target: "https://example.com/")
        ws.properties.summaryBelow = false
        ws.autoFilter = CellRange("A1:H1")
        wb.activeSheet = ws
        let hidden = wb.addSheet(named: "Hidden"); wb.sheets[hidden].state = .hidden; wb.sheets[hidden]["A1"] = "secret"
        wb.metadata.creator = "test"; wb.metadata.title = "Round trip"
        wb.definedNames["Plan"] = "Plan!$A$1:$H$6"

        let data = try XLSXCodec.write(wb).data
        let back = try XLSXCodec.read(data).workbook
        let r = back.sheets["Plan"]!
        #expect(back.sheetNames == ["Plan", "Hidden"] && back.sheets["Hidden"]?.state == .hidden)
        #expect(back.metadata.creator == "test" && back.metadata.title == "Round trip")
        #expect(back.definedNames["Plan"] == "Plan!$A$1:$H$6")
        #expect(r["A1"] == .text("Title") && r[cell: "A1"].font.bold && r[cell: "A1"].font.size == 14 && r[cell: "A1"].font.color == .rgb("FF112233"))
        #expect(r["B1"] == .integer(42) && r["C1"] == .number(3.5) && r["D1"] == .bool(true))
        #expect(r["E1"] == CellValue(CivilDate(year: 2026, month: 9, day: 1)!) && r[cell: "E1"].numberFormat == "yyyy/m/d")
        #expect(r["F1"] == .formula(FormulaExpr.parse("=B1*2"), cached: .integer(84)))
        #expect(r["G1"] == .number(0.25) && r[cell: "G1"].numberFormat == "0%")
        #expect(r["A2"] == .text("  padded  "))
        #expect(r["B2"] == .text("multi\nline") && r[cell: "B2"].alignment.wrapText && r[cell: "B2"].alignment.horizontal == .center)
        #expect(r[cell: "C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(r[cell: "D2"].border.left.style == .thin && r[cell: "D2"].border.left.color == .rgb("FF888888") && r[cell: "D2"].border.right.style == .medium)
        #expect(r["E2"] == .text("<A&B> \"q\" 日本語"))
        #expect(r["F2"] == .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))]))
        #expect(r["G2"] == .time(TimeOfDay(hour: 9, minute: 30)))
        #expect(r["H2"] == .error("#N/A"))
        #expect(r.merges.map(\.a1) == ["A3:C3"])
        #expect(r.freezePanes == CellRef("B2"))
        #expect(r.columnDimension("A").width == 20 && r.columnDimension("C").hidden)
        #expect(r.rowDimension(1).height == 30 && r.rowDimension(3).hidden && r.rowDimension(4).collapsed)
        #expect(r[cell: "A6"].hyperlink?.target == "https://example.com/")
        #expect(r.properties.summaryBelow == false && r.autoFilter?.a1 == "A1:H1")
    }

    @Test func readModifySave() throws {
        var wb = try XLSXCodec.read(try fixture("styled")).workbook
        wb.sheets["Data"]!["B1"] = .integer(43)
        wb.sheets["Data"]!.append([.text("new"), .integer(1), nil, .bool(false)])
        let back = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        let ws = back.sheets["Data"]!
        #expect(ws["B1"] == .integer(43))
        #expect(ws[6, 0] == .text("new") && ws[6, 3] == .bool(false))
        #expect(ws[cell: "A1"].font.bold)   // styles survive the read → write path
    }

    @Test func emptyWorkbookIsValid() throws {
        let wb = Workbook()
        let back = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook
        #expect(back.sheetNames == ["Sheet1"] && back.activeSheet.cells.isEmpty)
    }

    @Test func deflateRoundTrip() throws {
        let text = Data(String(repeating: "SwiftSheets deflate round trip. ", count: 200).utf8)
        let packed = try #require(Zip.deflate(text))
        #expect(packed.count < text.count / 4)
        #expect(try Zip.inflate(packed, expectedSize: text.count) == text)
    }
}
