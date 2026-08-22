import Foundation
import Testing
@testable import SwiftSheets

/// Two tests driven by `Tests/OpenpyxlParity/verify_with_openpyxl.py`: one writes a workbook that openpyxl then
/// inspects, the other reads a workbook openpyxl wrote and checks the same expectations. Both are skipped unless
/// `SWIFTSHEETS_INTEROP_DIR` is set, so `swift test` stays self-contained.
@Suite struct OpenpyxlInteropTests {
    static var dir: URL? { ProcessInfo.processInfo.environment["SWIFTSHEETS_INTEROP_DIR"].map { URL(fileURLWithPath: $0) } }

    /// The content both sides agree on (mirrored in verify_with_openpyxl.py).
    static func build() -> Workbook {
        let wb = Workbook()
        let ws = wb.active
        ws.title = "Plan"
        ws["A1"].value = "Title"; ws["A1"].font = Font(name: "Arial", size: 14, bold: true, color: .rgb("FF112233"))
        ws["B1"].value = 42; ws["C1"].value = 3.5; ws["D1"].value = true
        ws["E1"].value = CellValue(CivilDate(year: 2026, month: 9, day: 1)!); ws["E1"].numberFormat = "yyyy/m/d"
        ws["F1"].value = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30)))
        ws["G1"].value = .formula("=B1*2", cached: CellValueBox(.integer(84)))
        ws["H1"].value = .number(0.25); ws["H1"].numberFormat = "0%"
        ws["A2"].value = "  padded  "
        ws["B2"].value = "multi\nline"; ws["B2"].alignment = Alignment(horizontal: .center, vertical: .top, wrapText: true)
        ws["C2"].fill = .solid(.rgb("FFBFD7F5"))
        ws["D2"].border = Border(left: Side(style: .thin, color: .rgb("FF888888")), right: Side(style: .medium))
        ws["E2"].value = "<A&B> \"q\" 日本語"
        ws["F2"].value = .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))])
        ws["G2"].value = .time(TimeOfDay(hour: 9, minute: 30)); ws["G2"].numberFormat = "h:mm"
        ws["H2"].value = .error("#N/A")
        ws["A3"].value = "merged"; ws.mergeCells("A3:C3")
        ws.freezePanes(at: "B2")
        ws.setColumnWidth(1, 20); ws.setColumnDimension("C") { $0.hidden = true }
        ws.setRowDimension(2) { $0.height = 30 }
        ws.setRowDimension(4) { $0.hidden = true; $0.outlineLevel = 1 }
        ws["A4"].value = "hidden row"; ws["A5"].value = "level 1"
        ws["A6"].value = "link"; ws["A6"].hyperlink = Hyperlink(target: "https://example.com/")
        ws.properties.summaryBelow = false
        ws.autoFilter = CellRange("A1:H1")
        ws.printTitleRows = 1...1
        ws.setPrintArea("A1:H6")
        let hidden = wb.createSheet("Hidden"); hidden.state = .hidden; hidden["A1"].value = "secret"
        wb.properties.creator = "interop"; wb.properties.title = "Interop"
        wb.definedNames["PlanRange"] = "Plan!$A$1:$H$6"
        return wb
    }

    static func check(_ wb: Workbook) {
        let ws = wb["Plan"]!
        #expect(wb.sheetNames == ["Plan", "Hidden"] && wb["Hidden"]?.state == .hidden)
        #expect(wb.properties.creator == "interop" && wb.properties.title == "Interop")
        #expect(wb.definedNames["PlanRange"] == "Plan!$A$1:$H$6")
        #expect(ws["A1"].value == .string("Title") && ws["A1"].font.bold && ws["A1"].font.size == 14 && ws["A1"].font.color == .rgb("FF112233"))
        #expect(ws["B1"].value == .integer(42) && ws["C1"].value == .number(3.5) && ws["D1"].value == .bool(true))
        #expect(ws["E1"].value == CellValue(CivilDate(year: 2026, month: 9, day: 1)!) && ws["E1"].numberFormat == "yyyy/m/d")
        #expect(ws["F1"].value?.dateValue?.time == TimeOfDay(hour: 13, minute: 30))
        #expect(ws["G1"].value == .formula("=B1*2", cached: CellValueBox(.integer(84))) || ws["G1"].value == .formula("=B1*2", cached: nil))
        #expect(ws["H1"].value == .number(0.25) && ws["H1"].numberFormat == "0%")
        #expect(ws["A2"].value == .string("  padded  "))
        #expect(ws["B2"].value == .string("multi\nline") && ws["B2"].alignment.wrapText && ws["B2"].alignment.horizontal == .center && ws["B2"].alignment.vertical == .top)
        #expect(ws["C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(ws["D2"].border.left.style == .thin && ws["D2"].border.left.color == .rgb("FF888888") && ws["D2"].border.right.style == .medium)
        #expect(ws["E2"].value == .string("<A&B> \"q\" 日本語"))
        #expect(ws["F2"].value == .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))]) || ws["F2"].value?.stringValue == "設計 レビュー")
        #expect(ws["G2"].value == .time(TimeOfDay(hour: 9, minute: 30)) && ws["H2"].value == .error("#N/A"))
        #expect(ws.mergedCells.map(\.coordinate) == ["A3:C3"] && ws["A3"].value == .string("merged"))
        #expect(ws.freezePanes?.description == "B2")
        #expect(ws.columnDimension("A").width == 20 && ws.columnDimension("C").hidden)
        #expect(ws.rowDimension(2).height == 30 && ws.rowDimension(4).hidden && ws.rowDimension(4).outlineLevel == 1)
        #expect(ws["A6"].hyperlink?.target == "https://example.com/")
        #expect(ws.properties.summaryBelow == false && ws.autoFilter?.coordinate == "A1:H1")
        #expect(ws.printTitleRows == 1...1 && ws.printArea.map(\.coordinate) == ["A1:H6"])
    }

    @Test(.enabled(if: dir != nil)) func writesVerificationWorkbook() throws {
        try Self.build().save(to: Self.dir!.appendingPathComponent("swiftsheets.xlsx"))
    }

    @Test(.enabled(if: dir != nil)) func readsVerificationWorkbook() throws {
        let wb = try Workbook(contentsOf: Self.dir!.appendingPathComponent("openpyxl.xlsx"))
        Self.check(wb)
        let again = try Workbook(data: try wb.save())   // and survives a SwiftSheets round trip
        Self.check(again)
    }
}
