import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Suite struct ReaderTests {
    @Test func readsValuesTypesAndStyles() throws {
        let wb = try XLSXCodec.read(try fixture("styled"))
        #expect(wb.sheetNames == ["Data", "Hidden"])
        #expect(wb.sheets["Hidden"]?.state == .hidden)
        #expect(wb.metadata.creator == "fixture" && wb.metadata.title == "Styled")
        let ws = wb.sheets["Data"]!
        #expect(ws["A1"] == .text("Title"))
        #expect(ws[cell: "A1"].font.bold && ws[cell: "A1"].font.italic && ws[cell: "A1"].font.name == "Arial" && ws[cell: "A1"].font.size == 14)
        #expect(ws[cell: "A1"].font.color == .rgb("FF112233"))
        #expect(ws["B1"] == .integer(42))
        #expect(ws["C1"] == .number(3.5))
        #expect(ws["D1"] == .bool(true))
        #expect(ws["E1"] == .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!)))
        #expect(ws[cell: "E1"].numberFormat == "yyyy/m/d" && ws[cell: "E1"].isDate)
        #expect(ws["F1"]?.dateValue?.time == TimeOfDay(hour: 13, minute: 30))
        #expect(ws["G1"] == Formula("=B1*2"))
        #expect(ws["H1"] == .number(0.25) && ws[cell: "H1"].numberFormat == "0%")
        #expect(ws["A2"] == .text("  padded  "))
        #expect(ws[cell: "B2"].alignment.wrapText && ws[cell: "B2"].alignment.horizontal == .center && ws[cell: "B2"].alignment.vertical == .top)
        #expect(ws[cell: "C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(ws[cell: "D2"].border.left.style == .thin && ws[cell: "D2"].border.left.color == .rgb("FF888888") && ws[cell: "D2"].border.right.style == .medium)
        #expect(ws["E2"] == .text("<A&B> \"q\""))
        #expect(ws.merges.map(\.a1) == ["A3:C3"])
        #expect(ws.freezePanes == CellRef("B2"))
        #expect(ws.columnDimension("A").width == 20 && ws.columnDimension("C").hidden)
        #expect(ws.rowDimension(1).height == 30)
        #expect(ws.rowDimension(3).hidden && ws.rowDimension(3).outlineLevel == 1)
        #expect(ws.rowDimension(4).collapsed && ws.rowDimension(4).outlineLevel == 1)
        #expect(ws[cell: "A6"].hyperlink?.target == "https://example.com/")
        #expect(ws.properties.summaryBelow == false)
        #expect(ws.autoFilter?.a1 == "A1:H1")
    }

    @Test func dataOnlyReturnsCachedValues() throws {
        let wb = try XLSXCodec.read(try fixture("rph"), options: ReadOptions(dataOnly: true))
        #expect(wb.activeSheet["D1"] == .text("要件定義"))
        let full = try XLSXCodec.read(try fixture("rph"))
        #expect(full.activeSheet["D1"] == .formula(FormulaExpr.parse("=A1"), cached: .text("要件定義")))
    }

    @Test func japaneseExcelShapes() throws {
        let wb = try XLSXCodec.read(try fixture("rph"))
        let ws = wb.activeSheet
        #expect(ws.name == "工程表")
        #expect(ws["A1"] == .text("要件定義"))                                // furigana skipped
        if case .richText(let runs)? = ws["A2"] {
            #expect(runs.map(\.text) == ["設計 ", "レビュー"] && runs[1].font?.bold == true)
            #expect(ws["A2"]?.textValue == "設計 レビュー")
        } else { Issue.record("expected rich text") }
        #expect(ws["A3"] == .text("　字下げ"))
        #expect(ws["B1"]?.dateValue?.date.description == "2026-09-01")
        #expect(ws["C1"] == .text("inline"))                                  // <c> without r → next column
        #expect(ws["B2"] == .number(2.0))                                     // "2.0" keeps float-ness like openpyxl
        #expect(ws["C2"] == .bool(true))
        #expect(ws["D2"] == .error("#DIV/0!"))
        #expect(ws.rowDimension(1).hidden && ws.rowDimension(1).outlineLevel == 1)
        #expect(ws["B3"] == .time(TimeOfDay(hour: 12, minute: 0)))            // serial 0.5 with a date format
    }

    @Test func date1904() throws {
        let wb = try XLSXCodec.read(try fixture("date1904"))
        #expect(wb.epoch == .mac1904)
        #expect(wb.activeSheet["A1"]?.dateValue?.date.description == "2026-09-01")
        #expect(wb.activeSheet["B1"] == .integer(7))
    }
}

@Suite struct UtilityTests {
    @Test func references() {
        #expect(CellRef("AB12") == CellRef(row: 11, col: 27))
        #expect(CellRef("$A$1")?.a1 == "A1")
        #expect(CellRef.columnName(702) == "AAA" && CellRef.columnIndex("AAA") == 702)
        #expect(CellRange("C3:A1") == nil)   // openpyxl raises for a reversed range
        #expect(CellRange("A1:C3")?.a1 == "A1:C3")
        #expect(CellRef("1A") == nil)
    }

    @Test func excelDates() {
        #expect(ExcelDate.fromSerial(46266)?.dateValue?.date.description == "2026-09-01")
        #expect(ExcelDate.fromSerial(60)?.dateValue?.date.description == "1900-02-28")
        #expect(ExcelDate.fromSerial(61)?.dateValue?.date.description == "1900-03-01")
        #expect(ExcelDate.fromSerial(0.5) == .time(TimeOfDay(hour: 12, minute: 0)))
        #expect(ExcelDate.toSerial(CivilDate(year: 2026, month: 9, day: 1)!) == 46266)
        #expect(ExcelDate.toSerial(CivilDate(year: 2026, month: 9, day: 1)!, epoch: .mac1904) == 44804)
        #expect(CivilDate(year: 2026, month: 2, day: 30) == nil)
        #expect(CivilDate(iso: "2026-09-06")?.isoWeekday == 7)
    }

    @Test func numberFormats() {
        #expect(NumberFormat.isDateFormat("yyyy/m/d") && NumberFormat.isDateFormat("[$-411]ggge\"年\"m\"月\"d\"日\""))
        #expect(!NumberFormat.isDateFormat("0.00") && !NumberFormat.isDateFormat("\"days\" 0") && !NumberFormat.isDateFormat("@"))
        #expect(NumberFormat.isPercentFormat("0%") && !NumberFormat.isPercentFormat("0\"%\""))
    }

    @Test func crc() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
