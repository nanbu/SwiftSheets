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
        ws.filterColumns = [FilterColumn(column: 0, values: ["Title"], includesBlanks: true),
                            FilterColumn(column: 1, conditions: [FilterCondition(.greaterThan, "10")])]
        ws.sortState = SortState(range: CellRange("A1:H1")!, conditions: [SortCondition(range: CellRange("B1:B1")!, descending: true)])
        ws.printTitleRows = 0...0
        ws.setPrintArea("A1:H6")
        wb.activeSheet = ws
        let hidden = wb.addSheet(named: "Hidden"); wb.sheets[hidden].state = .hidden; wb.sheets[hidden]["A1"] = "secret"
        wb.metadata.creator = "interop"; wb.metadata.title = "Interop"
        wb.definedNames["PlanRange"] = "Plan!$A$1:$H$6"
        wb.addNamedStyle(NamedStyle(name: "Accent X", style: accentStyle))
        wb.sheets["Plan"]![cell: "A7"].comment = CellNote("確認してください\n2 行目", author: "南部")
        wb.sheets["Plan"]!.headerFooter.oddHeader = "&L四半期報告&C&P"
        wb.sheets["Plan"]!.headerFooter.oddFooter = "&R&F"
        wb.sheets["Plan"]!.rowBreaks = [4]
        wb.sheets["Plan"]!.columnBreaks = [2]
        wb.sheets["Plan"]!["B7"] = .formula(FormulaExpr.parse("=SUM(B1:B2)"), cached: .integer(42))
        wb.sheets["Plan"]!.table.arrayFormulas[CellRef("B7")!] = CellRange("B7:B8")
        wb.sheets["Plan"]![cell: "B6"].style = NamedStyle(name: "Accent X", style: accentStyle).applied
        wb.sheets["Plan"]!["B6"] = 1000
        // a list that suggests without rejecting, and a strict numeric rule (spec B.13)
        wb.sheets["Plan"]!.dataValidations = [
            .list("\"Todo,Doing,Done\"", over: MultiCellRange("C4:C6")!),
            DataValidation(kind: .whole, ranges: MultiCellRange("D4:D6")!, formula1: "0", formula2: "100",
                           operator: .between, errorStyle: .stop, allowBlank: true, showErrorMessage: true,
                           errorTitle: "範囲外", error: "0〜100 で入力してください"),
        ]
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
        #expect(ws.filterColumns == [FilterColumn(column: 0, values: ["Title"], includesBlanks: true),
                                     FilterColumn(column: 1, conditions: [FilterCondition(.greaterThan, "10")])])
        #expect(ws.sortState == SortState(range: CellRange("A1:H1")!, conditions: [SortCondition(range: CellRange("B1:B1")!, descending: true)]))
        #expect(ws.printTitleRows == 0...0 && ws.printArea.map(\.a1) == ["A1:H6"])
        #expect(ws[cell: "A7"].comment == CellNote("確認してください\n2 行目", author: "南部"))
        #expect(ws.headerFooter.oddHeader == "&L四半期報告&C&P" && ws.headerFooter.oddFooter == "&R&F")
        #expect(ws.rowBreaks == [4] && ws.columnBreaks == [2])
        #expect(ws.table.arrayFormulas[CellRef("B7")!] == CellRange("B7:B8"))
        #expect(wb.namedStyles.map(\.name) == ["Normal", "Accent X"])
        #expect(wb.namedStyle("Accent X")?.style.numberFormat == "#,##0")
        #expect(wb.namedStyle("Accent X")?.style.font.bold == true)
        #expect(ws[cell: "B6"].style.namedStyle == "Accent X" && ws["B6"] == .integer(1000))
        // openpyxl's own list validation, read into the model (spec B.13)
        #expect(!ws.hasUnmodelledValidations)
        #expect(ws.dataValidations.count == 1)
        #expect(ws.dataValidations[0].kind == .list && ws.dataValidations[0].formula1 == "\"Todo,Doing,Done\"")
        #expect(ws.dataValidations[0].ranges == MultiCellRange("C4:C6") && ws.dataValidations[0].allowBlank)
    }

    /// The features added after the first interop pass — conditional formatting, named tables, differential and
    /// gradient formats, the exotic filter kinds, custom document properties, protection and a pivot table. Written
    /// by SwiftSheets and inspected by openpyxl; the reverse direction is covered by the checks openpyxl's own
    /// writer supports.
    static func buildFeatures() -> Workbook {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws.name = "Data"
        ws.append([.text("Item"), .text("Qty"), .text("Price")])
        ws.append([.text("apple"), .integer(3), .number(1.5)])
        ws.append([.text("pear"), .integer(5), .number(2.25)])
        ws.append([.text("plum"), .integer(2), .number(4)])

        let red = DifferentialStyle(font: DifferentialFont(bold: true, color: .rgb("FF9C0006")),
                                    fill: .solid(.rgb("FFFFC7CE")), numberFormat: "0.00")
        ws.addConditionalFormatting(.cellIs(.greaterThan, "3", paint: red), over: "B2:B4")
        ws.addConditionalFormatting(.expression("$A2=\"pear\"", paint: red), over: "A2:A4")
        ws.addConditionalFormatting(.colorScale(.threeColor(from: .rgb("FFF8696B"), through: .rgb("FFFFEB84"),
                                                            to: .rgb("FF63BE7B"))), over: "C2:C4")
        ws.addConditionalFormatting(.dataBar(DataBar(color: .rgb("FF638EC6"), minLength: 10, maxLength: 90)), over: "B2:B4")
        ws.addConditionalFormatting(.iconSet(.threeBand("3Arrows")), over: "C2:C4")
        ws.addConditionalFormatting(.top(2, paint: red, bottom: true), over: "B2:B4")

        ws.addExcelTable(named: "Sales", over: CellRange("A1:C4")!)

        ws[cell: "E1"].fill = .gradient(GradientFill(from: .white, to: .rgb("FFBFD7F5"), degree: 90))
        ws["E1"] = "gradient"

        var pivotSheet = Sheet(name: "Pivot")
        var other = Sheet(name: "Filtered")
        for r in 0..<6 { other[r, 0] = .text("row\(r)"); other[r, 1] = .integer(r) }
        other.autoFilter = CellRange("A1:B6")
        other.filterColumns = [FilterColumn(column: 1, top10: Top10Filter(count: 3, top: false, percent: true))]
        wb.sheets[0] = ws
        wb.sheets.append(pivotSheet)
        wb.sheets.append(other)
        wb.addPivotTable(named: "集計", to: "Pivot", at: CellRef("A3")!,
                         summarizing: CellRange("A1:C4")!, on: "Data",
                         rows: ["Item"], values: [("Qty", .sum), ("Price", .average)])
        _ = pivotSheet

        wb.customProperties = [CustomDocumentProperty(name: "管理番号", "A-1234"),
                               CustomDocumentProperty(name: "改訂", 7),
                               CustomDocumentProperty(name: "社外秘", true)]
        return wb
    }

    @Test(.enabled(if: dir != nil)) func writesFeatureWorkbook() throws {
        try XLSXCodec.write(Self.buildFeatures()).data.write(to: Self.dir!.appendingPathComponent("features.xlsx"))
    }

    /// The streaming writer's output, for openpyxl to read as an ordinary workbook.
    @Test(.enabled(if: dir != nil)) func writesStreamedWorkbook() throws {
        let writer = try StreamingWriter(url: Self.dir!.appendingPathComponent("streamed.xlsx"), sheetName: "Big")
        try writer.append([.text("n"), .text("square"), .text("note")])
        for i in 1...2000 { try writer.append([.integer(i), .integer(i * i), .text("行 \(i)")]) }
        var styled = Cell(); styled.value = .text("見出し"); styled.font.bold = true
        styled.fill = .solid(.rgb("FFBFD7F5")); styled.numberFormat = "0.00"
        try writer.append([styled])
        try writer.addSheet(named: "Second")
        try writer.append([.text("  余白  "), .bool(true), .error("#N/A"), .number(1.5)])
        try writer.close()
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
