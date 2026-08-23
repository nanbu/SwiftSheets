import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Named tables — Excel's "Format as Table", the `xl/tables/*.xml` parts (openpyxl `ws.tables`).
@Suite struct ExcelTableTests {

    static func sales() -> Workbook {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.append([.text("Item"), .text("Qty"), .text("Price")])
        ws.append([.text("apple"), .integer(3), .number(1.5)])
        ws.append([.text("pear"), .integer(5), .number(2.25)])
        wb.sheets[0] = ws
        return wb
    }

    /// A table added over a range takes its column names from the sheet's own header row, and comes back the same.
    // openpyxl: worksheet/tests/test_table.py::TestTable::test_ctor
    // openpyxl: worksheet/tests/test_table.py::TestTable::test_write
    // openpyxl: worksheet/tests/test_table.py::TestTable::test_path
    // openpyxl: worksheet/tests/test_table.py::TestTablePartList::test_ctor
    @Test func addingATableWritesAPartThatReadsBack() throws {
        var wb = Self.sales()
        let name = wb.sheets[0].addExcelTable(named: "売上 表", over: CellRange("A1:C3")!)
        #expect(name == "売上_表", "the name is sanitised into one Excel accepts")

        let data = try wb.data(as: .xlsx)
        let part = try Package.part("xl/tables/table1.xml", of: data)
        #expect(part.contains("name=\"売上_表\" displayName=\"売上_表\" ref=\"A1:C3\""))
        #expect(part.contains("<tableColumn id=\"1\" name=\"Item\"/>"))
        #expect(part.contains("<tableColumn id=\"3\" name=\"Price\"/>"))
        #expect(part.contains("<tableStyleInfo name=\"TableStyleMedium9\""))
        #expect(part.contains("<autoFilter ref=\"A1:C3\"/>"))

        // the four things a table needs: part, content type, sheet relationship, <tableParts>
        #expect(try Package.part("[Content_Types].xml", of: data).contains("/xl/tables/table1.xml"))
        let rels = try Package.part("xl/worksheets/_rels/sheet1.xml.rels", of: data)
        #expect(rels.contains("tables/table1.xml") && rels.contains("/relationships/table\""))
        let sheetXML = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(sheetXML.contains("<tableParts count=\"1\"><tablePart r:id="))
        let id = rels.components(separatedBy: "Id=\"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        for i in id { #expect(sheetXML.contains(i) || rels.contains("hyperlink"), "dangling \(i)") }

        let again = try Workbook(data: data).sheets[0]
        #expect(again.excelTables.count == 1)
        #expect(again.excelTables[0].name == "売上_表")
        #expect(again.excelTables[0].ref == CellRange("A1:C3"))
        #expect(again.excelTables[0].columns.map(\.name) == ["Item", "Qty", "Price"])
        #expect(again.excelTables[0].styleInfo == .default)
        #expect(again.excelTable(containing: CellRef("B2")!)?.name == "売上_表")
    }

    /// Blank and repeated header cells are repaired the way Excel repairs them, because it will not open a table
    /// with an unnamed or duplicated column.
    @Test func headerNamesAreMadeUniqueAndNonEmpty() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.append([.text("Item"), nil, .text("Item")])
        ws.append([.text("a"), .integer(1), .text("b")])
        wb.sheets[0] = ws
        wb.sheets[0].addExcelTable(named: "T", over: CellRange("A1:C2")!)
        #expect(wb.sheets[0].excelTables[0].columns.map(\.name) == ["Item", "Column2", "Item2"])
        #expect(wb.sheets[0].excelTables[0].validationError() == nil)
    }

    /// Totals rows, calculated columns and banding.
    // openpyxl: worksheet/tests/test_table.py::TestTableColumn::test_ctor
    // openpyxl: worksheet/tests/test_table.py::TestTableColumn::test_from_xml
    // openpyxl: worksheet/tests/test_table.py::TestTableInfo::test_ctor
    // openpyxl: worksheet/tests/test_table.py::TestTableFormula::test_ctor
    @Test func totalsAndCalculatedColumnsRoundTrip() throws {
        var wb = Self.sales()
        wb.sheets[0].append([.text("合計"), nil, nil])
        var table = ExcelTable(name: "Sales", ref: CellRange("A1:C4")!,
                               columns: [ExcelTableColumn(id: 1, name: "Item", totalsRowLabel: "合計"),
                                         ExcelTableColumn(id: 2, name: "Qty", totalsRowFunction: "sum"),
                                         ExcelTableColumn(id: 3, name: "Price", totalsRowFunction: "custom",
                                                          totalsRowFormula: "SUBTOTAL(109,Sales[Price])",
                                                          calculatedColumnFormula: "Sales[[#This Row],[Qty]]*2")],
                               totalsRowCount: 1,
                               styleInfo: TableStyleInfo(name: "TableStyleLight1", showFirstColumn: true,
                                                         showRowStripes: false, showColumnStripes: true))
        table.comment = "月次"
        wb.sheets[0].excelTables = [table]

        let data = try wb.data(as: .xlsx)
        let part = try Package.part("xl/tables/table1.xml", of: data)
        #expect(part.contains("totalsRowCount=\"1\"") && part.contains("comment=\"月次\""))
        #expect(part.contains("totalsRowLabel=\"合計\"") && part.contains("totalsRowFunction=\"sum\""))
        #expect(part.contains("<totalsRowFormula>SUBTOTAL(109,Sales[Price])</totalsRowFormula>"))
        #expect(part.contains("<calculatedColumnFormula>Sales[[#This Row],[Qty]]*2</calculatedColumnFormula>"))
        #expect(part.contains("showFirstColumn=\"1\"") && part.contains("showRowStripes=\"0\"") && part.contains("showColumnStripes=\"1\""))

        let again = try Workbook(data: data).sheets[0].excelTables[0]
        #expect(again == table)
        #expect(again.dataRows == 1...2, "the header and the totals row are not data")
    }

    /// A table the file format would refuse is reported, not written: Excel offers to repair such a workbook.
    @Test func anInvalidTableIsReportedRatherThanWritten() throws {
        var wb = Self.sales()
        // three columns of cells, two column names
        wb.sheets[0].excelTables = [ExcelTable(name: "Bad", ref: CellRange("A1:C3")!,
                                               columns: [ExcelTableColumn(id: 1, name: "Item"),
                                                         ExcelTableColumn(id: 2, name: "Qty")])]
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("covers 3 column(s) but names 2") })
        #expect(try !Package.part("xl/worksheets/sheet1.xml", of: result.data).contains("<tableParts"))
    }

    /// Table names are the workbook's, not the sheet's: the second claim on a name is reported.
    @Test func aDuplicatedNameIsReported() throws {
        var wb = Self.sales()
        wb.addSheet(named: "Other")
        wb.sheets[0].addExcelTable(named: "Sales", over: CellRange("A1:C3")!)
        wb.sheets[1]["A1"] = .text("Item")
        wb.sheets[1].excelTables = [ExcelTable(name: "Sales", ref: CellRange("A1:A1")!,
                                               columns: [ExcelTableColumn(id: 1, name: "Item")], headerRowCount: 1)]
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.message.contains("already has that name") })
        #expect(try Package.part("xl/tables/table1.xml", of: result.data).contains("name=\"Sales\""))
    }

    /// A table read from a file keeps its part path, its id and its relationship — and the attributes the model
    /// does not carry come back with it.
    @Test func aSourceTableKeepsItsIdentityAndUnmodelledAttributes() throws {
        var wb = Self.sales()
        wb.sheets[0].addExcelTable(named: "Sales", over: CellRange("A1:C3")!)
        let plain = try wb.data(as: .xlsx)
        let extended = try Package.repacking(plain, replacing: "xl/tables/table1.xml", with: Data(
            try Package.part("xl/tables/table1.xml", of: plain)
                .replacingOccurrences(of: "<autoFilter", with: "<autoFilter insertRow=\"1\" dataDxfId=\"7\" published=\"1\" placeholder=\"")
                .replacingOccurrences(of: "insertRow=\"1\" dataDxfId=\"7\" published=\"1\" placeholder=\"", with: "")
                .replacingOccurrences(of: " ref=\"A1:C3\" totalsRowShown", with: " ref=\"A1:C3\" insertRow=\"1\" dataDxfId=\"7\" totalsRowShown").utf8))

        var again = try Workbook(data: extended)
        #expect(again.sheets[0].excelTables[0].name == "Sales")
        again.sheets[0]["B2"] = .integer(9)                       // an edit elsewhere
        let out = try again.data(as: .xlsx)
        let part = try Package.part("xl/tables/table1.xml", of: out)
        #expect(part.contains("insertRow=\"1\"") && part.contains("dataDxfId=\"7\""), "unmodelled attributes come back")
        #expect(part.contains("id=\"1\""), "the id is the file's")
        #expect(try ZipArchive(data: out).entries.keys.filter { $0.hasPrefix("xl/tables/") }.count == 1)
    }

    /// Removing a table takes its part, its relationship and its `<tableParts>` entry with it.
    @Test func removingATableRemovesThePart() throws {
        var wb = Self.sales()
        wb.sheets[0].addExcelTable(named: "Sales", over: CellRange("A1:C3")!)
        var again = try Workbook(data: try wb.data(as: .xlsx))
        again.sheets[0].excelTables = []
        let out = try again.data(as: .xlsx)
        #expect(try !ZipArchive(data: out).entries.keys.contains { $0.hasPrefix("xl/tables/") })
        #expect(try !Package.part("xl/worksheets/sheet1.xml", of: out).contains("<tableParts"))
        #expect(try !ZipArchive(data: out).entries.keys.contains("xl/worksheets/_rels/sheet1.xml.rels"),
                "with the table gone the sheet has no relationships at all")
        #expect(try !Package.part("[Content_Types].xml", of: out).contains("xl/tables/"))
    }

    /// The table's own filter — the buttons in its header row — is inside the table part, not the sheet.
    @Test func theTablesOwnFilterLivesInThePart() throws {
        var wb = Self.sales()
        var table = ExcelTable(name: "Sales", ref: CellRange("A1:C3")!, headerRow: [.text("Item"), .text("Qty"), .text("Price")])
        table.filterColumns = [FilterColumn(column: 1, conditions: [FilterCondition(.greaterThan, "3")])]
        wb.sheets[0].excelTables = [table]
        let data = try wb.data(as: .xlsx)
        #expect(try Package.part("xl/tables/table1.xml", of: data).contains("<customFilter operator=\"greaterThan\" val=\"3\"/>"))
        #expect(try !Package.part("xl/worksheets/sheet1.xml", of: data).contains("<autoFilter"))
        #expect(try Workbook(data: data).sheets[0].excelTables[0].filterColumns == table.filterColumns)
    }

    /// Converting to a format without named tables says so.
    @Test func odsReportsTheLoss() throws {
        var wb = Self.sales()
        wb.sheets[0].addExcelTable(named: "Sales", over: CellRange("A1:C3")!)
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("named table") })
    }
}
