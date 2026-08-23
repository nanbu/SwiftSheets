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

    /// A canvas with several tables (Numbers) collapses to the first one on the way into a worksheet — with a warning,
    /// never in silence.
    @Test func extraTablesOfASheetAreReported() throws {
        var ws = Sheet(name: "Canvas")
        ws["A1"] = .text("first")
        let second = ws.addTable(named: "Second", anchor: CellRef("D1")!)
        ws.tables[second]["A1"] = .text("second")
        let result = try XLSXCodec.write(Workbook(sheets: [ws]))
        let dropped = result.warnings.filter { $0.kind == .dropped }
        #expect(dropped.count == 1)
        #expect(dropped.first?.subject == .tables && dropped.first?.sheet == "Canvas")
        #expect(dropped.first?.message.contains("1 other table(s)") == true)
        #expect(result.suggestion?.format == .numbers)   // XLSX cannot hold them either — only Numbers can
        let back = try XLSXCodec.read(result.data).workbook.sheets[0]
        #expect(back.tables.count == 1 && back["A1"] == .text("first"))
        #expect(!back.cells.values.contains { $0.value == .text("second") })
    }

    @Test func deflateRoundTrip() throws {
        let text = Data(String(repeating: "SwiftSheets deflate round trip. ", count: 200).utf8)
        let packed = try #require(Zip.deflate(text))
        #expect(packed.count < text.count / 4)
        #expect(try Zip.inflate(packed, expectedSize: text.count) == text)
    }
}

/// Data validation is write-side only (spec appendix B.13): built from the model, preserved verbatim when the file
/// had its own, and never dropped in silence.
@Suite struct DataValidationTests {
    static func sheetXML(_ wb: Workbook) throws -> String {
        String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/worksheets/sheet1.xml"), as: UTF8.self)
    }

    /// `list(_:over:)` is the "suggest, do not reject" form the file format spells with three flags.
    @Test func aListSuggestsWithoutRejecting() throws {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws["A1"] = "status"
        ws.dataValidations = [.list("'Choices'!$A$2:$A$4", over: MultiCellRange("A2:A9")!)]
        wb.sheets[0] = ws
        let xml = try Self.sheetXML(wb)
        #expect(xml.contains("<dataValidations count=\"1\">"))
        #expect(xml.contains("type=\"list\""))
        #expect(xml.contains("<formula1>'Choices'!$A$2:$A$4</formula1>"))
        #expect(xml.contains("sqref=\"A2:A9\""))
        #expect(xml.contains("allowBlank=\"1\""))
        #expect(!xml.contains("showErrorMessage=\"1\""))       // ← nothing is rejected
        #expect(!xml.contains("showDropDown=\"1\""))           // ← the arrow IS shown (the attribute is inverted)
    }

    /// The strict form, and the attributes that only it writes.
    @Test func aRejectingListSaysSo() throws {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws.dataValidations = [.list("\"a,b\"", over: MultiCellRange("B2")!, rejects: true)]
        wb.sheets[0] = ws
        let xml = try Self.sheetXML(wb)
        #expect(xml.contains("showErrorMessage=\"1\"") && xml.contains("errorStyle=\"stop\""))
    }

    /// `hideDropDown` is the meaning; `showDropDown="1"` is how the file spells it.
    @Test func hidingTheArrowWritesTheInvertedAttribute() throws {
        var wb = Workbook()
        var ws = wb.activeSheet
        var dv = DataValidation.list("\"a,b\"", over: MultiCellRange("A1")!)
        dv.hideDropDown = true
        ws.dataValidations = [dv]
        wb.sheets[0] = ws
        #expect(try Self.sheetXML(wb).contains("showDropDown=\"1\""))
    }

    /// Every attribute survives the trip to XML, including the two-sided operator form and the message texts.
    @Test func everyAttributeIsWritten() throws {
        var wb = Workbook()
        var ws = wb.activeSheet
        ws.dataValidations = [DataValidation(kind: .whole, ranges: MultiCellRange("A1:A5 C1")!, formula1: "0",
                                             formula2: "100", operator: .between, errorStyle: .warning,
                                             allowBlank: true, showInputMessage: true, showErrorMessage: true,
                                             errorTitle: "範囲外", error: "0〜100 <で>", promptTitle: "入力",
                                             prompt: "0〜100", imeMode: "halfAlpha")]
        wb.sheets[0] = ws
        let xml = try Self.sheetXML(wb)
        for attribute in ["type=\"whole\"", "operator=\"between\"", "errorStyle=\"warning\"", "imeMode=\"halfAlpha\"",
                          "allowBlank=\"1\"", "showInputMessage=\"1\"", "showErrorMessage=\"1\"",
                          "errorTitle=\"範囲外\"", "promptTitle=\"入力\"", "sqref=\"A1:A5 C1\"",
                          "<formula1>0</formula1>", "<formula2>100</formula2>"] {
            #expect(xml.contains(attribute), Comment(rawValue: attribute))
        }
        #expect(xml.contains("&lt;で&gt;"))                    // message text is escaped
        #expect(xml.contains("</dataValidation></dataValidations>"))
    }

    /// The schema allows one `<dataValidations>` per sheet, so a file that brought its own keeps it — and the
    /// model's rules are reported as degraded rather than vanishing.
    @Test func aPreservedBlockWinsAndTheLossIsReported() throws {
        var wb = try XLSXCodec.read(try PreservationTests.fixture("charts-and-friends.xlsx")).workbook
        var ws = wb.sheets[0]
        #expect(ws.hasUnmodelledValidations, "the fixture is expected to carry its own validations")
        #expect(ws.dataValidations.isEmpty, "reading does not model them")
        ws.dataValidations = [.list("\"x,y\"", over: MultiCellRange("ZZ1")!)]
        wb.sheets[0] = ws
        let result = try XLSXCodec.write(wb)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("data validation") })
        let xml = String(decoding: try ZipArchive(data: result.data).read("xl/worksheets/sheet1.xml"), as: UTF8.self)
        #expect(xml.components(separatedBy: "<dataValidations").count == 2, "exactly one block")
        #expect(!xml.contains("ZZ1"))
    }

    /// A sheet with no rules writes no element at all (and the generated one sits in schema order).
    @Test func noRulesNoElementAndTheOrderIsTheSchemas() throws {
        var wb = Workbook()
        #expect(try !Self.sheetXML(wb).contains("dataValidations"))
        var ws = wb.activeSheet
        ws["A1"] = 1
        ws.merge("B1:C1")
        ws.dataValidations = [.list("\"a\"", over: MultiCellRange("A1")!)]
        ws[cell: "A2"].hyperlink = Hyperlink(target: "https://example.com/")
        wb.sheets[0] = ws
        let xml = try Self.sheetXML(wb)
        let order = ["<sheetData>", "<mergeCells", "<dataValidations", "<hyperlinks>", "<pageMargins"]
        let positions = order.map { xml.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())
    }
}
