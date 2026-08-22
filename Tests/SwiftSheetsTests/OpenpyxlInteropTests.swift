import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

/// Two tests driven by `Tests/OpenpyxlParity/verify_with_openpyxl.py`: one writes a workbook that openpyxl then
/// inspects, the other reads a workbook openpyxl wrote and checks the same expectations. Both are skipped unless
/// `SWIFTSHEETS_INTEROP_DIR` is set, so `swift test` stays self-contained.
@Suite struct OpenpyxlInteropTests {
    static var dir: URL? { ProcessInfo.processInfo.environment["SWIFTSHEETS_INTEROP_DIR"].map { URL(fileURLWithPath: $0) } }

    /// The content both sides agree on (mirrored in verify_with_openpyxl.py).
    static func build() -> Workbook {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws.name = "Plan"
        ws["A1"] = "Title"; ws[cell: "A1"].font = Font(name: "Arial", size: 14, bold: true, color: .rgb("FF112233"))
        ws["B1"] = 42; ws["C1"] = 3.5; ws["D1"] = true
        ws["E1"] = CellValue(CivilDate(year: 2026, month: 9, day: 1)!); ws[cell: "E1"].numberFormat = "yyyy/m/d"
        ws["F1"] = .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!, time: TimeOfDay(hour: 13, minute: 30)))
        ws["G1"] = .formula(FormulaExpr.parse("=B1*2"), cached: .integer(84))
        ws["H1"] = .number(0.25); ws[cell: "H1"].numberFormat = "0%"
        ws["A2"] = "  padded  "
        ws["B2"] = "multi\nline"; ws[cell: "B2"].alignment = Alignment(horizontal: .center, vertical: .top, wrapText: true)
        ws[cell: "C2"].fill = .solid(.rgb("FFBFD7F5"))
        ws[cell: "D2"].border = Border(left: Side(style: .thin, color: .rgb("FF888888")), right: Side(style: .medium))
        ws["E2"] = "<A&B> \"q\" 日本語"
        ws["F2"] = .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))])
        ws["G2"] = .time(TimeOfDay(hour: 9, minute: 30)); ws[cell: "G2"].numberFormat = "h:mm"
        ws["H2"] = .error("#N/A")
        ws["A3"] = "merged"; ws.merge("A3:C3")
        ws.freezePanes(at: "B2")
        ws.setWidth(20, ofColumn: 0); ws.setColumnDimension("C") { $0.hidden = true }
        ws.setRowDimension(1) { $0.height = 30 }
        ws.setRowDimension(3) { $0.hidden = true; $0.outlineLevel = 1 }
        ws["A4"] = "hidden row"; ws["A5"] = "level 1"
        ws["A6"] = "link"; ws[cell: "A6"].hyperlink = Hyperlink(target: "https://example.com/")
        ws.properties.summaryBelow = false
        ws.autoFilter = CellRange("A1:H1")
        ws.printTitleRows = 0...0
        ws.setPrintArea("A1:H6")
        wb.activeSheet = ws
        let hidden = wb.addSheet(named: "Hidden"); wb.sheets[hidden].state = .hidden; wb.sheets[hidden]["A1"] = "secret"
        wb.metadata.creator = "interop"; wb.metadata.title = "Interop"
        wb.definedNames["PlanRange"] = "Plan!$A$1:$H$6"
        wb.addNamedStyle(NamedStyle(name: "Accent X", style: accentStyle))
        wb.sheets["Plan"]![cell: "A7"].comment = CellNote("確認してください\n2 行目", author: "南部")
        wb.sheets["Plan"]![cell: "B6"].style = NamedStyle(name: "Accent X", style: accentStyle).applied
        wb.sheets["Plan"]!["B6"] = 1000
        return wb
    }

    /// The formatting the named style carries; the same on both sides.
    static var accentStyle: CellStyle {
        var s = CellStyle()
        s.font = Font(name: "Arial", size: 12, bold: true, color: .rgb("FF7F6000"))
        s.fill = .solid(.rgb("FFFFF2CC"))
        s.numberFormat = "#,##0"
        return s
    }

    static func check(_ wb: Workbook) {
        let ws = wb.sheets["Plan"]!
        #expect(wb.sheetNames == ["Plan", "Hidden"] && wb.sheets["Hidden"]?.state == .hidden)
        #expect(wb.metadata.creator == "interop" && wb.metadata.title == "Interop")
        #expect(wb.definedNames["PlanRange"] == "Plan!$A$1:$H$6")
        #expect(ws["A1"] == .text("Title") && ws[cell: "A1"].font.bold && ws[cell: "A1"].font.size == 14 && ws[cell: "A1"].font.color == .rgb("FF112233"))
        #expect(ws["B1"] == .integer(42) && ws["C1"] == .number(3.5) && ws["D1"] == .bool(true))
        #expect(ws["E1"] == CellValue(CivilDate(year: 2026, month: 9, day: 1)!) && ws[cell: "E1"].numberFormat == "yyyy/m/d")
        #expect(ws["F1"]?.dateValue?.time == TimeOfDay(hour: 13, minute: 30))
        #expect(ws["G1"] == .formula(FormulaExpr.parse("=B1*2"), cached: .integer(84)) || ws["G1"] == Formula("=B1*2"))
        #expect(ws["H1"] == .number(0.25) && ws[cell: "H1"].numberFormat == "0%")
        #expect(ws["A2"] == .text("  padded  "))
        #expect(ws["B2"] == .text("multi\nline") && ws[cell: "B2"].alignment.wrapText && ws[cell: "B2"].alignment.horizontal == .center && ws[cell: "B2"].alignment.vertical == .top)
        #expect(ws[cell: "C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(ws[cell: "D2"].border.left.style == .thin && ws[cell: "D2"].border.left.color == .rgb("FF888888") && ws[cell: "D2"].border.right.style == .medium)
        #expect(ws["E2"] == .text("<A&B> \"q\" 日本語"))
        #expect(ws["F2"] == .richText([TextRun("設計 "), TextRun("レビュー", font: Font(bold: true))]) || ws["F2"]?.textValue == "設計 レビュー")
        #expect(ws["G2"] == .time(TimeOfDay(hour: 9, minute: 30)) && ws["H2"] == .error("#N/A"))
        #expect(ws.merges.map(\.a1) == ["A3:C3"] && ws["A3"] == .text("merged"))
        #expect(ws.freezePanes?.a1 == "B2")
        #expect(ws.columnDimension("A").width == 20 && ws.columnDimension("C").hidden)
        #expect(ws.rowDimension(1).height == 30 && ws.rowDimension(3).hidden && ws.rowDimension(3).outlineLevel == 1)
        #expect(ws[cell: "A6"].hyperlink?.target == "https://example.com/")
        #expect(ws.properties.summaryBelow == false && ws.autoFilter?.a1 == "A1:H1")
        #expect(ws.printTitleRows == 0...0 && ws.printArea.map(\.a1) == ["A1:H6"])
        #expect(ws[cell: "A7"].comment == CellNote("確認してください\n2 行目", author: "南部"))
        #expect(wb.namedStyles.map(\.name) == ["Normal", "Accent X"])
        #expect(wb.namedStyle("Accent X")?.style.numberFormat == "#,##0")
        #expect(wb.namedStyle("Accent X")?.style.font.bold == true)
        #expect(ws[cell: "B6"].style.namedStyle == "Accent X" && ws["B6"] == .integer(1000))
    }

    @Test(.enabled(if: dir != nil)) func writesVerificationWorkbook() throws {
        try XLSXCodec.write(Self.build()).data.write(to: Self.dir!.appendingPathComponent("swiftsheets.xlsx"))
    }

    @Test(.enabled(if: dir != nil)) func readsVerificationWorkbook() throws {
        let wb = try XLSXCodec.read(try Data(contentsOf: Self.dir!.appendingPathComponent("openpyxl.xlsx"))).workbook
        Self.check(wb)
        let again = try XLSXCodec.read(try XLSXCodec.write(wb).data).workbook   // and survives a SwiftSheets round trip
        Self.check(again)
    }
}
