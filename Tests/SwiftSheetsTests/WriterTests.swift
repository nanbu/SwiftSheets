import Foundation
import Testing
@testable import SwiftSheets

@Suite struct WriterTests {
    /// Build a workbook with every feature, save, reload with our own reader — everything must survive.
    @Test func roundTripThroughOurselves() throws {
        let wb = Workbook()
        let ws = wb.active
        ws.title = "Plan"
        ws["A1"].value = "Title"; ws["A1"].font = Font(name: "Arial", size: 14, bold: true, color: .rgb("FF112233"))
        ws.cell(row: 1, column: 2, value: 42)
        ws.cell(row: 1, column: 3, value: 3.5)
        ws.cell(row: 1, column: 4, value: true)
        ws.cell(row: 1, column: 5, value: CellValue(CivilDate(year: 2026, month: 9, day: 1)!)).numberFormat = "yyyy/m/d"
        ws.cell(row: 1, column: 6, value: .formula("=B1*2", cached: CellValueBox(.integer(84))))
        ws.cell(row: 1, column: 7, value: .number(0.25)).numberFormat = "0%"
        ws.cell(row: 2, column: 1, value: "  padded  ")
        ws["B2"].value = "multi\nline"; ws["B2"].alignment = Alignment(horizontal: .center, vertical: .top, wrapText: true)
        ws["C2"].fill = .solid(.rgb("FFBFD7F5"))
        ws["D2"].border = Border(left: Side(style: .thin, color: .rgb("FF888888")), right: Side(style: .medium))
        ws["E2"].value = "<A&B> \"q\" 日本語"
        ws["F2"].value = .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))])
        ws["G2"].value = .time(TimeOfDay(hour: 9, minute: 30)); ws["G2"].numberFormat = "h:mm"
        ws["H2"].value = .error("#N/A")
        ws.mergeCells("A3:C3"); ws["A3"].value = "merged"
        ws.freezePanes(at: "B2")
        ws.setColumnWidth(1, 20); ws.setColumnDimension("C") { $0.hidden = true }
        ws.setRowDimension(2) { $0.height = 30 }
        ws.setRowDimension(4) { $0.hidden = true; $0.outlineLevel = 1 }
        ws.setRowDimension(5) { $0.outlineLevel = 1; $0.collapsed = true }
        ws["A6"].value = "link"; ws["A6"].hyperlink = Hyperlink(target: "https://example.com/")
        ws.properties.summaryBelow = false
        ws.autoFilter = CellRange("A1:H1")
        let hidden = wb.createSheet("Hidden"); hidden.state = .hidden; hidden["A1"].value = "secret"
        wb.properties.creator = "test"; wb.properties.title = "Round trip"
        wb.definedNames["Plan"] = "Plan!$A$1:$H$6"

        let data = try wb.save()
        let back = try Workbook(data: data)
        let r = back["Plan"]!
        #expect(back.sheetNames == ["Plan", "Hidden"] && back["Hidden"]?.state == .hidden)
        #expect(back.properties.creator == "test" && back.properties.title == "Round trip")
        #expect(back.definedNames["Plan"] == "Plan!$A$1:$H$6")
        #expect(r["A1"].value == .string("Title") && r["A1"].font.bold && r["A1"].font.size == 14 && r["A1"].font.color == .rgb("FF112233"))
        #expect(r["B1"].value == .integer(42) && r["C1"].value == .number(3.5) && r["D1"].value == .bool(true))
        #expect(r["E1"].value == CellValue(CivilDate(year: 2026, month: 9, day: 1)!) && r["E1"].numberFormat == "yyyy/m/d")
        #expect(r["F1"].value == .formula("=B1*2", cached: CellValueBox(.integer(84))))
        #expect(r["G1"].value == .number(0.25) && r["G1"].numberFormat == "0%")
        #expect(r["A2"].value == .string("  padded  "))
        #expect(r["B2"].value == .string("multi\nline") && r["B2"].alignment.wrapText && r["B2"].alignment.horizontal == .center)
        #expect(r["C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(r["D2"].border.left.style == .thin && r["D2"].border.left.color == .rgb("FF888888") && r["D2"].border.right.style == .medium)
        #expect(r["E2"].value == .string("<A&B> \"q\" 日本語"))
        #expect(r["F2"].value == .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))]))
        #expect(r["G2"].value == .time(TimeOfDay(hour: 9, minute: 30)))
        #expect(r["H2"].value == .error("#N/A"))
        #expect(r.mergedCells.map(\.description) == ["A3:C3"])
        #expect(r.freezePanes == CellReference("B2"))
        #expect(r.columnDimension("A").width == 20 && r.columnDimension("C").hidden)
        #expect(r.rowDimension(2).height == 30 && r.rowDimension(4).hidden && r.rowDimension(5).collapsed)
        #expect(r["A6"].hyperlink?.target == "https://example.com/")
        #expect(r.properties.summaryBelow == false && r.autoFilter?.description == "A1:H1")
    }

    @Test func readModifySave() throws {
        let wb = try Workbook(data: try fixture("styled"))
        wb["Data"]!["B1"].value = .integer(43)
        wb["Data"]!.append([.string("new"), .integer(1), nil, .bool(false)])
        let back = try Workbook(data: try wb.save())
        let ws = back["Data"]!
        #expect(ws["B1"].value == .integer(43))
        #expect(ws.cell(row: 7, column: 1).value == .string("new") && ws.cell(row: 7, column: 4).value == .bool(false))
        #expect(ws["A1"].font.bold)   // styles survive the read → write path
    }

    @Test func emptyWorkbookIsValid() throws {
        let wb = Workbook()
        let back = try Workbook(data: try wb.save())
        #expect(back.sheetNames == ["Sheet"] && back.active.cells.isEmpty)
    }

    @Test func deflateRoundTrip() throws {
        let text = Data(String(repeating: "SwiftSheets deflate round trip. ", count: 200).utf8)
        let packed = try #require(Zip.deflate(text))
        #expect(packed.count < text.count / 4)
        #expect(try Zip.inflate(packed, expectedSize: text.count) == text)
    }
}
