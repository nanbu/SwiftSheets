import Foundation
import Testing
@testable import SheetCore

/// Value-type semantics of the model (spec §3, §14).
@Suite struct ModelTests {
    @Test func valueSemantics() {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = "x"
        #expect(wb.sheets[0]["A1"] == nil)   // a copy was edited
        wb.sheets[0] = sheet
        #expect(wb.sheets[0]["A1"] == .text("x"))
        let snapshot = wb
        wb.sheets[0]["A1"] = "y"
        #expect(snapshot.sheets[0]["A1"] == .text("x"))
        #expect(wb.sheets[0]["A1"] == .text("y"))
    }

    @Test func literalsAndTypedAccessors() {
        var s = Sheet(name: "S")
        s["A1"] = "売上"; s["B1"] = 1_250_000; s["C1"] = 0.07; s["D1"] = true; s["E1"] = CellValue(CivilDate(year: 2026, month: 9, day: 1)!)
        s["F1"] = CellValue(Decimal(string: "12345678901234567890.5")!); s["H1"] = 42.5
        s["G1"] = CellValue(Date(timeIntervalSince1970: 0), in: TimeZone(identifier: "UTC")!)
        #expect(s["A1"]?.textValue == "売上")
        #expect(s["B1"]?.numberValue == 1_250_000)
        #expect(s["B1"]?.intValue == 1_250_000)
        #expect(s["C1"] == .number(Decimal(string: "0.07")!))
        #expect(s["C1"]?.doubleValue == 0.07)
        #expect(s["D1"]?.boolValue == true)
        #expect(s["E1"]?.dateValue?.date.description == "2026-09-01")
        #expect(s["F1"]?.numberValue == Decimal(string: "12345678901234567890.5")!)   // digits survive; Double would not hold them
        #expect(s["F1"]?.intValue == nil && s["H1"]?.stringValue == "42.5" && s["B1"]?.stringValue == "1250000")
        #expect(s["G1"]?.dateValue?.date.description == "1970-01-01")
        #expect(s["A1"]?.numberValue == nil)
        #expect(s["Z9"] == nil)
        #expect(s.extent == CellRange("A1:H1"))
        #expect(s.rowCount == 1 && s.columnCount == 8)
        s["A1"] = nil
        #expect(s.cell("A1") == nil)   // nothing left, so the cell is gone
        s.style("B1") { $0.numberFormat = "#,##0" }
        s["B1"] = nil
        #expect(s.cell("B1") != nil)   // formatting keeps the cell
        #expect(Sheet(name: "E").extent == nil)
        #expect(Sheet(name: "E").rows().isEmpty)
    }

    @Test func sheetsCollection() {
        var wb = Workbook()
        #expect(wb.sheetNames == ["Sheet1"])
        let i = wb.addSheet(named: "Sheet1")
        #expect(i == 1 && wb.sheetNames == ["Sheet1", "Sheet11"])
        wb.sheets[1].name = "Sales"
        #expect(wb.sheetNames == ["Sheet1", "Sales"])
        wb.sheets[1].name = "Bad/Name"
        #expect(wb.sheets[1].name == "Sales")   // invalid: unchanged
        wb.sheets[1].name = ""
        #expect(wb.sheets[1].name == "Sales")
        wb.sheets[1].name = "sheet1"
        #expect(wb.sheets[1].name == "sheet11")   // case-insensitive duplicate gets the next free suffix (openpyxl's rule)
        wb.sheets["sheet11"]?["A1"] = "x"   // optional chaining through the name subscript mutates in place
        #expect(wb.sheets[1]["A1"] == .text("x"))
        wb.sheets["sheet11"] = nil
        #expect(wb.sheetNames == ["Sheet1"])
        wb.sheets["New"] = Sheet(name: "Other")   // absent name: appended under the key
        #expect(wb.sheetNames == ["Sheet1", "New"])
        wb.activeIndex = 5
        #expect(wb.activeIndex == 1)
        #expect(wb.duplicateSheet(named: "Sheet1") == 2)
        #expect(wb.sheetNames[2] == "Sheet1 Copy")
        wb.moveSheet(named: "Sheet1 Copy", to: 0)
        #expect(wb.sheetNames[0] == "Sheet1 Copy")
        #expect(wb.removeSheet(named: "nope") == false)
    }

    @Test func insertDeleteShiftsEverythingOnTheSheet() {
        var s = Sheet(name: "S")
        s["A1"] = 1; s["A2"] = 2; s["A3"] = 3
        s.merge("B2:C2")
        s.setHeight(30, ofRow: 1)
        s["D1"] = Formula("=SUM(A1:A3)")
        s.insertRows(at: 1, count: 2)
        #expect(s["A1"] == .integer(1) && s["A2"] == nil && s["A4"] == .integer(2) && s["A5"] == .integer(3))
        #expect(s.merges == [CellRange("B4:C4")!])
        #expect(s.rowDimension(3).height == 30)
        #expect(s["D1"]?.formula?.text == "=SUM(A1:A5)")
        s.deleteRows(at: 0, count: 4)
        #expect(s["A1"] == .integer(3))
        #expect(s.merges.isEmpty)
        #expect(s["D1"] == nil)
        s.insertColumns(at: 0)
        #expect(s["B1"] == .integer(3))
        #expect(s.nextAppendRow == 1)
    }

    @Test func appendContinuesBelowTheLastWrittenRow() {
        var s = Sheet(name: "S")
        s["A1"] = "header"
        s.append(["a", 1])
        s.append([2: "c"])
        s.append(["B": "b"])
        #expect(s["A2"] == .text("a") && s["B2"] == .integer(1) && s["C3"] == .text("c") && s["B4"] == .text("b"))
        #expect(s.nextAppendRow == 4)
        #expect(s.rows(in: "A1:C2") == [[.text("header"), nil, nil], [.text("a"), .integer(1), nil]])
        #expect(s.columns(in: "A1:A2") == [[.text("header"), .text("a")]])
        #expect(s.column("B") == [nil, .integer(1), nil, .text("b")])
        #expect(s.row(1) == [.text("a"), .integer(1), nil])
    }

    @Test func stylesAndDimensions() {
        var s = Sheet(name: "S")
        s.style("A1:B1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "F5F5F7")); $0.border.bottom = Side(style: .medium) }
        #expect(s.style("B1").font.bold && s.style("C1").font.bold == false)
        #expect(s[cell: "A1"].fill == PatternFill.solid(.rgb("FFF5F5F7")))
        s.setWidth(14, ofColumn: "C"); s.setHeight(24, ofRow: 0)
        #expect(s.columnDimension("C").width == 14 && s.columnDimension(2).width == 14 && s.rowDimension(0).height == 24)
        s.groupColumns("F", "H")
        #expect(s.columnGroups == ["F:H"])
        s.freezePanes(at: "B2")
        #expect(s.freezePanes == CellRef(row: 1, col: 1) && s.freezePanesA1 == "B2")
        s.freezePanes(at: "A1")
        #expect(s.freezePanes == nil)
        s.autoFilterA1 = "A1:D100"
        #expect(s.autoFilter == CellRange("A1:D100"))
        s.tabColor = "1072BA"
        #expect(s.properties.tabColor == .rgb("FF1072BA"))
        s.isHidden = true
        #expect(s.state == .hidden)
    }

    @Test func tablesOnASheet() {
        var s = Sheet(name: "Canvas")
        s["A1"] = "default table"
        let t = s.addTable(named: "Second", anchor: CellRef("D10")!)
        s.tables[t]["A1"] = "second"
        #expect(s.tables.count == 2 && s.tables[1].name == "Second" && s.tables[1].anchor.a1 == "D10")
        #expect(s["A1"] == .text("default table") && s.tables[1]["A1"] == .text("second"))
    }

    @Test func preservationSummary() {
        var store = PreservationStore()
        #expect(store.summary == "VBA project: no")
        store.opaqueParts["xl/vbaProject.bin"] = Data()
        store.opaqueParts["xl/charts/chart1.xml"] = Data()
        store.opaqueParts["xl/charts/chart2.xml"] = Data()
        store.opaqueParts["xl/theme/theme1.xml"] = Data()
        #expect(store.summary == "VBA project: yes / charts: 2 / other parts: 1")
    }
}
