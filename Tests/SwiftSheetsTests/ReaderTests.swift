import Foundation
import Testing
@testable import SwiftSheets

func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

@Suite struct ReaderTests {
    @Test func readsValuesTypesAndStyles() throws {
        let wb = try Workbook(data: try fixture("styled"))
        #expect(wb.sheetNames == ["Data", "Hidden"])
        #expect(wb["Hidden"]?.state == .hidden)
        #expect(wb.properties.creator == "fixture" && wb.properties.title == "Styled")
        let ws = wb["Data"]!
        #expect(ws["A1"].value == .string("Title"))
        #expect(ws["A1"].font.bold && ws["A1"].font.italic && ws["A1"].font.name == "Arial" && ws["A1"].font.size == 14)
        #expect(ws["A1"].font.color == .rgb("FF112233"))
        #expect(ws["B1"].value == .integer(42))
        #expect(ws["C1"].value == .number(3.5))
        #expect(ws["D1"].value == .bool(true))
        #expect(ws["E1"].value == .date(CivilDateTime(date: CivilDate(year: 2026, month: 9, day: 1)!)))
        #expect(ws["E1"].numberFormat == "yyyy/m/d" && ws["E1"].isDate)
        #expect(ws["F1"].value?.dateValue?.time == TimeOfDay(hour: 13, minute: 30))
        #expect(ws["G1"].value == .formula("=B1*2", cached: nil))
        #expect(ws["H1"].value == .number(0.25) && ws["H1"].numberFormat == "0%")
        #expect(ws["A2"].value == .string("  padded  "))
        #expect(ws["B2"].alignment.wrapText && ws["B2"].alignment.horizontal == .center && ws["B2"].alignment.vertical == .top)
        #expect(ws["C2"].fill == .solid(.rgb("FFBFD7F5")))
        #expect(ws["D2"].border.left.style == .thin && ws["D2"].border.left.color == .rgb("FF888888") && ws["D2"].border.right.style == .medium)
        #expect(ws["E2"].value == .string("<A&B> \"q\""))
        #expect(ws.mergedCells.map(\.description) == ["A3:C3"])
        #expect(ws.freezePanes == CellReference("B2"))
        #expect(ws.columnDimension("A").width == 20 && ws.columnDimension("C").hidden)
        #expect(ws.rowDimension(2).height == 30)
        #expect(ws.rowDimension(4).hidden && ws.rowDimension(4).outlineLevel == 1)
        #expect(ws.rowDimension(5).collapsed && ws.rowDimension(5).outlineLevel == 1)
        #expect(ws["A6"].hyperlink?.target == "https://example.com/")
        #expect(ws.properties.summaryBelow == false)
        #expect(ws.autoFilter?.description == "A1:H1")
    }

    @Test func dataOnlyReturnsCachedValues() throws {
        let wb = try Workbook(data: try fixture("rph"), dataOnly: true)
        #expect(wb.active["D1"].value == .string("要件定義"))
        let full = try Workbook(data: try fixture("rph"))
        #expect(full.active["D1"].value == .formula("=A1", cached: CellValueBox(.string("要件定義"))))
    }

    @Test func japaneseExcelShapes() throws {
        let wb = try Workbook(data: try fixture("rph"))
        let ws = wb.active
        #expect(ws.title == "工程表")
        #expect(ws["A1"].value == .string("要件定義"))                         // furigana skipped
        if case .richText(let runs)? = ws["A2"].value {
            #expect(runs.map(\.text) == ["設計 ", "レビュー"] && runs[1].font?.bold == true)
            #expect(ws["A2"].value?.stringValue == "設計 レビュー")
        } else { Issue.record("expected rich text") }
        #expect(ws["A3"].value == .string("　字下げ"))
        #expect(ws["B1"].value?.dateValue?.date.description == "2026-09-01")
        #expect(ws["C1"].value == .string("inline"))                           // <c> without r → next column
        #expect(ws["B2"].value == .number(2.0))                               // "2.0" keeps float-ness like openpyxl
        #expect(ws["C2"].value == .bool(true))
        #expect(ws["D2"].value == .error("#DIV/0!"))
        #expect(ws.rowDimension(2).hidden && ws.rowDimension(2).outlineLevel == 1)
        #expect(ws["B3"].value == .time(TimeOfDay(hour: 12, minute: 0)))      // serial 0.5 with a date format
    }

    @Test func date1904() throws {
        let wb = try Workbook(data: try fixture("date1904"))
        #expect(wb.epoch == .mac1904)
        #expect(wb.active["A1"].value?.dateValue?.date.description == "2026-09-01")
        #expect(wb.active["B1"].value == .integer(7))
    }
}

@Suite struct UtilityTests {
    @Test func references() {
        #expect(CellReference("AB12") == CellReference(column: 28, row: 12))
        #expect(CellReference("$A$1")?.description == "A1")
        #expect(CellReference.columnLetter(703) == "AAA" && CellReference.columnIndex("AAA") == 703)
        #expect(CellRange("C3:A1") == nil)   // openpyxl raises for a reversed range
        #expect(CellRange("A1:C3")?.description == "A1:C3")
        #expect(CellReference("1A") == nil)
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
