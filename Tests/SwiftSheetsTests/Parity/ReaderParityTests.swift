import Foundation
import Testing
@testable import SwiftSheets

@Suite struct WorksheetReaderParityTests {
    let wb = Workbook()
    /// openpyxl's parser fixture: style 29 / 30 are date formats, 30 is also a timedelta format.
    func styles() throws -> StylesParser {
        var xfs = ""
        for i in 0..<29 { xfs += "<xf numFmtId=\"\(i == 1 ? 14 : 0)\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>" }
        xfs += "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"46\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
        return try parseStyles("<cellXfs count=\"31\">\(xfs)</cellXfs>")
    }
    func sheet(_ xml: String, sst: [CellValue] = ["a"], dataOnly: Bool = false, epoch: DateEpoch = .windows1900, rels: [Relationship] = []) throws -> Worksheet {
        try parseSheet(xml, styles: try styles(), sst: sst, epoch: epoch, dataOnly: dataOnly, rels: rels, into: wb)
    }

    static let numberCases: [(String, Double)] = [("4.2", 4.2), ("-42.000", -42), ("0", 0), ("0.9999", 0.9999), ("99E-02", 0.99), ("4", 4), ("-1E3", -1000), ("1E-3", 0.001), ("2e+2", 200)]
    // openpyxl: worksheet/tests/test_reader.py::test_number_convesion
    @Test(arguments: numberCases)
    func numberConversion(_ value: String, _ expected: Double) throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><v>\(value)</v></c></row></sheetData>")
        #expect(ws["A1"].value?.doubleValue == expected)
        #expect((ws["A1"].value?.dataType == "n"))
    }

    static let dimensionCases: [(String, CellRange?)] = [("dimension.xml", CellRange(minColumn: 4, minRow: 1, maxColumn: 27, maxRow: 30)), ("no_dimension.xml", nil), ("invalid_dimension.xml", nil)]
    // openpyxl: worksheet/tests/test_reader.py::test_read_dimension
    @Test(arguments: dimensionCases)
    func readDimension(_ filename: String, _ expected: CellRange?) throws {
        let ws = try parseSheet(try openpyxlFixtureText("worksheet/\(filename)"), into: wb)
        #expect(ws.declaredDimension == expected)   // "1:113" (invalid) is not a cell range for SwiftSheets
    }

    // openpyxl: worksheet/tests/test_reader.py::test_col_width
    @Test func colWidth() throws {
        let ws = try parseSheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), into: wb)
        #expect(Set(ws.columnDimensions.keys) == ["A", "C", "E", "I", "G"])
        #expect(ws.columnDimension("A") == ColumnDimension(width: 31.1640625))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_hidden_col
    @Test func hiddenCol() throws {
        let ws = try sheet("<cols><col min=\"4\" max=\"4\" width=\"0\" hidden=\"1\" customWidth=\"1\"/></cols>")
        #expect(ws.columnDimensions["D"] == ColumnDimension(width: 0, hidden: true))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_styled_col
    @Test func styledCol() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"))
        let cd = ws.columnDimension("I")
        #expect(cd.width == 25 && cd.style != nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_dimensions
    @Test func rowDimensions() throws {
        let ws = try sheet("<sheetData><row r=\"2\" spans=\"1:6\" /></sheetData>")
        #expect(ws.rowDimensions[2] == nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_hidden_row
    @Test func hiddenRow() throws {
        let ws = try sheet("<sheetData><row r=\"2\" spans=\"1:4\" hidden=\"1\" /></sheetData>")
        #expect(ws.rowDimensions[2] == RowDimension(hidden: true))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_styled_row
    @Test func styledRow() throws {
        let ws = try sheet("<sheetData><row r=\"23\" s=\"28\" spans=\"1:8\" /></sheetData>")
        #expect(ws.rowDimensions[23]?.style != nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_read_row_with_exponent
    @Test func readRowWithExponent() throws {
        let ws = try sheet("<sheetData><row r=\"1.048573e6\" spans=\"1:8\" /></sheetData>")
        #expect(ws.currentRow == 1048573)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_invalid_row_number
    @Test func invalidRowNumber() throws {
        #expect(throws: SheetsError.self) { try sheet("<sheetData><row r=\"1.5\" spans=\"1:8\" /></sheetData>") }
    }

    // openpyxl: worksheet/tests/test_reader.py::test_formula
    @Test func formula() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><f>IF(TRUE, \"y\", \"n\")</f><v>y</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "f" && ws["A1"].value == .formula("=IF(TRUE, \"y\", \"n\")", cached: CellValueBox(.string("y"))))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_formula_data_only
    @Test func formulaDataOnly() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><f>1+2</f><v>3</v></c></row></sheetData>", dataOnly: true)
        #expect(ws["A1"].dataType == "n" && ws["A1"].value == .integer(3))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_string_formula_data_only
    @Test func stringFormulaDataOnly() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><f>IF(TRUE, \"y\", \"n\")</f><v>y</v></c></row></sheetData>", dataOnly: true)
        #expect(ws["A1"].dataType == "s" && ws["A1"].value == .string("y"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_number
    @Test func number() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "n" && ws["A1"].value == .integer(1))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_datetime
    @Test func datetime() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"d\"><v>2011-12-25T14:23:55</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "d" && ws["A1"].value == .date(CivilDateTime(date: CivilDate(year: 2011, month: 12, day: 25)!, time: TimeOfDay(hour: 14, minute: 23, second: 55))))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_timedelta
    @Test func timedelta() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"30\"><v>1.25</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "d" && ws["A1"].value == .duration(.seconds(86400 + 6 * 3600)))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_mac_date
    @Test func macDate() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"29\"><v>41184</v></c></row></sheetData>", epoch: .mac1904)
        #expect(ws["A1"].value == CellValue(CivilDate(year: 2016, month: 10, day: 3)!))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_out_of_range_datetime
    @Test(arguments: [-693595, 2958466]) func outOfRangeDatetime(_ value: Int) throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"29\"><v>\(value)</v></c></row></sheetData>")
        #expect(ws["A1"].value != nil)   // openpyxl warns and keeps going; SwiftSheets keeps the (proleptic) date
    }

    // openpyxl: worksheet/tests/test_reader.py::test_string
    @Test func string() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "s" && ws["A1"].value == .string("a"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_boolean
    @Test func boolean() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"b\"><v>1</v></c></row></sheetData>")
        #expect(ws["A1"].dataType == "b" && ws["A1"].value == .bool(true))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_inline_string
    @Test func inlineString() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" s=\"0\" t=\"inlineStr\"><is><t>ID</t></is></c></row></sheetData>")
        #expect(ws["A1"].dataType == "s" && ws["A1"].value == .string("ID"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_inline_richtext
    @Test func inlineRichtext() throws {
        let ws = try sheet("<sheetData><row r=\"2\"><c r=\"R2\" s=\"4\" t=\"inlineStr\"><is><r><rPr><sz val=\"8.0\"/></rPr><t xml:space=\"preserve\">11 de September de 2014</t></r></is></c></row></sheetData>")
        #expect(ws["R2"].value == .richText([TextRun("11 de September de 2014", font: Font(size: 8))]))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_parse_richtext
    @Test func parseRichtext() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><r><rPr><sz val=\"8.0\"/></rPr><t xml:space=\"preserve\">11 de September de 2014</t></r></is></c></row></sheetData>")
        #expect(ws["A1"].value?.stringValue == "11 de September de 2014")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_sheet_views
    @Test func sheetViews() throws {
        let ws = try sheet("""
        <sheetViews><sheetView tabSelected="1" zoomScale="200" zoomScaleNormal="200" zoomScalePageLayoutView="200" workbookViewId="0">
          <pane xSplit="5" ySplit="19" topLeftCell="F20" activePane="bottomRight" state="frozenSplit"/>
          <selection pane="topRight" activeCell="F1" sqref="F1"/><selection pane="bottomLeft" activeCell="A20" sqref="A20"/><selection pane="bottomRight" activeCell="E22" sqref="E22"/>
        </sheetView></sheetViews>
        """)
        #expect(ws.view.zoomScale == 200 && ws.view.activeCell == "E22" && ws.freezePanes?.description == "F20")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cell_without_coordinates
    @Test func cellWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c t=\"s\"><v>2</v></c><c t=\"s\"><v>4</v></c><c t=\"s\"><v>3</v></c><c t=\"s\"><v>6</v></c><c t=\"s\"><v>9</v></c></row></sheetData>",
                           sst: Array(repeating: .string("Whatever"), count: 10))
        #expect(ws.currentRow == 1 && ws.maxColumn == 5 && ws["E1"].value == .string("Whatever"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_and_cell_without_coordinates
    @Test func rowAndCellWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>2</v></c><c><v>4</v></c><c><v>3</v></c></row></sheetData>")
        #expect(ws.values() == [[2, 4, 3]] && ws.minRow == 1)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_and_cell_skipping_coordinates
    @Test func rowAndCellSkippingCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>1</v></c><c r=\"D1\"><v>2</v></c><c><v>3</v></c><c r=\"G1\"><v>4</v></c></row></sheetData>")
        #expect(ws.cells.count == 4 && ws["A1"].value == 1 && ws["D1"].value == 2 && ws["E1"].value == 3 && ws["G1"].value == 4)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_second_row_cell_index_without_coordinates
    @Test func secondRowCellIndexWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>2</v></c></row><row><c><v>2</v></c></row></sheetData>")
        #expect(ws["A2"].value == 2 && ws.maxRow == 2)
    }

    // openpyxl: worksheet/tests/test_reader.py::TestWorksheetParser::test_external_hyperlinks
    @Test func externalHyperlinks() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "http://test.com", mode: "External")
        let ws = try sheet("<hyperlinks><hyperlink display=\"http://test.com\" r:id=\"rId1\" ref=\"A1\"/></hyperlinks>", rels: [rel])
        #expect(ws.cells.values.filter { $0.hyperlink != nil }.count == 1)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_local_hyperlinks
    @Test func localHyperlinks() throws {
        let ws = try sheet("<hyperlinks><hyperlink ref=\"B4:B7\" location=\"'STP nn000TL-10, PKG 2.52'!A1\" display=\"STP 10000TL-10\"/></hyperlinks>")
        #expect(ws.cells.values.filter { $0.hyperlink != nil }.count == 1 && ws["B4"].hyperlink?.location == "'STP nn000TL-10, PKG 2.52'!A1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merge_cells
    @Test func mergeCells() throws {
        let ws = try sheet("<mergeCells><mergeCell ref=\"C2:F2\"/><mergeCell ref=\"B19:C20\"/><mergeCell ref=\"E19:G19\"/></mergeCells>")
        #expect(ws.mergedCells.map(\.coordinate) == ["C2:F2", "B19:C20", "E19:G19"])
    }

    // openpyxl: worksheet/tests/test_reader.py::test_sheet_properties
    @Test func sheetProperties() throws {
        let ws = try sheet("<sheetPr codeName=\"Sheet3\"><tabColor rgb=\"FF92D050\"/><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr/></sheetPr>")
        #expect(ws.properties.tabColor == .rgb("FF92D050") && ws.properties.codeName == "Sheet3")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_sheet_format
    @Test func sheetFormat() throws {
        let ws = try sheet("<sheetFormatPr defaultRowHeight=\"14.25\" baseColWidth=\"15\"/>")
        #expect(ws.sheetFormat.defaultRowHeight == 14.25 && ws.sheetFormat.baseColWidth == 15)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_auto_filter
    @Test func autoFilter() throws {
        let ws = try sheet("<autoFilter ref=\"A1:AK3237\"><sortState ref=\"A2:AM3269\"><sortCondition ref=\"B1:B3269\"/></sortState></autoFilter>")
        #expect(ws.autoFilter?.coordinate == "A1:AK3237")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cell
    @Test func cell() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws["C1"].value == .string("a"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merged
    @Test func merged() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.mergedCells.map(\.coordinate) == ["G18:H18", "G23:H24", "A18:B18"])
    }

    static let normalizeCases: [(String, String?)] = [("H18", "G18"), ("G18", "G18"), ("I18", nil), ("H23", "G23")]
    // openpyxl: worksheet/tests/test_reader.py::test_normalize_merged_cell_link
    @Test(arguments: normalizeCases)
    func normalizeMergedCellLink(_ input: String, _ expected: String?) throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.mergedRange(containing: CellReference(input)!)?.topLeft.description == expected)
    }

    // openpyxl: worksheet/tests/test_reader.py::TestWorksheetReader::test_external_hyperlinks
    @Test func primedExternalHyperlinks() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "../", mode: nil)
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30), rels: [rel])
        #expect(ws["A1"].hyperlink?.target == "../")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_internal_hyperlinks
    @Test func internalHyperlinks() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws["B4"].hyperlink?.location == "'STP nn000TL-10, PKG 2.52'!A1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merged_hyperlinks
    @Test func mergedHyperlinks() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.mergedCells.map(\.coordinate) == ["G18:H18", "G23:H24", "A18:B18"])
        #expect(ws["A18"].hyperlink?.display == "http://test.com" && ws["B18"].hyperlink == nil)
        // Link referencing H24 lands on G23, the top-left cell of the merged range
        #expect(ws["G23"].hyperlink?.tooltip == "openpyxl" && ws["H24"].hyperlink == nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cols
    @Test func cols() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.columnDimensions.count == 5)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_rows
    @Test func rows() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.rowDimensions.count == 7)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_properties
    @Test func properties() throws {
        let ws = try sheet(try openpyxlFixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .string("a"), count: 30))
        #expect(ws.pageMargins == PageMargins() && ws.pageSetup.orientation == .portrait && ws.sheetFormat.baseColWidth == 10 && ws.view.activeCell == "I1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_more_rows_than_cells
    @Test func moreRowsThanCells() throws {
        let ws = try parseSheet(try openpyxlFixtureText("worksheet/more_rows_than_cells.xml"), into: wb)
        #expect(ws.currentRow == 3)
    }
}

@Suite struct ExcelReaderParityTests {
    // openpyxl: reader/tests/test_excel.py::test_read_empty_file
    @Test func readEmptyFile() throws {
        #expect(throws: SheetsError.self) { try Workbook(data: try openpyxlFixture("reader/null_file.xlsx")) }
    }

    // openpyxl: reader/tests/test_excel.py::test_load_workbook_from_fileobj
    @Test func loadWorkbookFromFileobj() throws {
        _ = try Workbook(data: try openpyxlFixture("reader/empty_with_no_properties.xlsx"))   // no docProps: loads without exceptions
    }

    // openpyxl: reader/tests/test_excel.py::test_style_assignment
    @Test func styleAssignment() throws {
        let data = try openpyxlFixture("reader/complex-styles.xlsx")
        let wb = try Workbook(data: data)
        let sheet = try parseStyles(String(decoding: try ZipArchive(data: data).read("xl/styles.xml"), as: UTF8.self))
        #expect(Set(sheet.cellXfs.map(\.alignment)).count == 9 && sheet.fills.count == 6 && sheet.fonts.count == 8)
        // 7 + 4 borders: the top-left cell of each merged range gets a new border and the old ones are kept
        // openpyxl counts 7 + 4 borders because every intermediate `border +=` result of merged-range formatting is kept
        // in its border list; SwiftSheets has no such list, so only the distinct final borders are counted: 7 + 1.
        #expect(Set(sheet.borders).count == 7 && Set(sheet.borders).union(wb.active.cells.values.map(\.border)).count == 8)
        #expect(sheet.customNumberFormats.isEmpty && Set(sheet.cellXfs.map(\.protection)).count == 1)
    }

    // openpyxl: reader/tests/test_excel.py::test_read_stringio
    @Test func readStringio() {
        #expect(throws: SheetsError.self) { try Workbook(data: Data("certainly not a valid XSLX content".utf8)) }
    }

    // openpyxl: reader/tests/test_excel.py::test_ctor
    @Test func ctor() throws {
        let zip = try ZipArchive(data: try openpyxlFixture("reader/complex-styles.xlsx"))
        #expect(Set(zip.entries.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/_rels/workbook.xml.rels", "xl/workbook.xml", "xl/sharedStrings.xml", "xl/theme/theme1.xml",
                                          "xl/styles.xml", "xl/worksheets/sheet1.xml", "docProps/thumbnail.jpeg", "docProps/core.xml", "docProps/app.xml"])
    }

    // openpyxl: reader/tests/test_excel.py::test_read_strings
    @Test func readStrings() throws {
        let zip = try ZipArchive(data: try openpyxlFixture("reader/complex-styles.xlsx"))
        let p = SharedStringsParser(); try p.run(try zip.read("xl/sharedStrings.xml"), part: "sst")
        #expect(!p.strings.isEmpty)
    }

    // openpyxl: reader/tests/test_excel.py::test_read_workbook
    @Test func readWorkbook() throws {
        #expect(try Workbook(data: try openpyxlFixture("reader/complex-styles.xlsx")).sheetNames == ["Sheet1"])
    }

    // openpyxl: reader/tests/test_excel.py::test_read_workbook_hidden
    @Test func readWorkbookHidden() throws {
        let wb = try Workbook(data: try openpyxlFixture("reader/hidden_sheets.xlsx"))
        #expect(wb.sheetNames == ["Sheet", "Hidden", "VeryHidden"] && wb.worksheets[1].state == .hidden && wb.worksheets[2].state == .veryHidden)
    }
}

@Suite struct StringsReaderParityTests {
    func table(_ path: String) throws -> [CellValue] {
        let p = SharedStringsParser(); try p.run(try openpyxlFixture(path), part: path); return p.strings
    }

    // openpyxl: reader/tests/test_strings.py::test_read_string_table
    @Test func readStringTable() throws {
        #expect(try table("reader/sharedStrings.xml") == ["This is cell A1 in Sheet 1", "This is cell G5"])
    }

    // openpyxl: reader/tests/test_strings.py::test_empty_string
    @Test func emptyString() throws {
        #expect(try table("reader/sharedStrings-emptystring.xml") == ["Testing empty cell", ""])
    }

    // openpyxl: reader/tests/test_strings.py::test_formatted_string_table
    @Test func formattedStringTable() throws {
        var bold = Font(name: "Calibri", size: 11, bold: true, color: .theme(1)); bold.family = 2; bold.scheme = "minor"
        var boldU = bold; boldU.underline = .single
        #expect(try table("reader/shared-strings-rich.xml") == [
            "Welcome",
            .richText([TextRun("to the best "), TextRun("shop in ", font: bold), TextRun("town", font: boldU)]),
            "     let's play ",
        ])
    }
}

@Suite struct WorkbookReaderParityTests {
    // openpyxl: reader/tests/test_workbook.py::test_ctor
    @Test func ctor() throws {
        let p = WorkbookXMLParser()
        #expect(p.sheets.isEmpty && !p.date1904)
    }

    // openpyxl: reader/tests/test_workbook.py::test_parse_calendar
    @Test func parseCalendar() throws {
        let p = WorkbookXMLParser()
        try p.run(try openpyxlFixture("reader/workbook_1904.xml"), part: "workbook.xml")
        #expect(p.date1904)
    }

    // openpyxl: reader/tests/test_workbook.py::test_find_sheets
    @Test func findSheets() throws {
        let zip = try ZipArchive(data: try openpyxlFixture("reader/bug137.xlsx"))
        let p = WorkbookXMLParser(); try p.run(try zip.read("xl/workbook.xml"), part: "workbook.xml")
        let rels = try WorkbookReader.parseRels(zip, "xl/_rels/workbook.xml.rels")
        let found = p.sheets.map { s in (s.name, s.state, rels.first { $0.id == s.rId }?.target ?? "", rels.first { $0.id == s.rId }?.type.split(separator: "/").last.map(String.init) ?? "") }
        #expect(found.map { $0.0 } == ["Chart1", "Sheet1"] && found.map { $0.1 } == [.visible, .visible])
        #expect(found.map { "xl/" + $0.2 } == ["xl/chartsheets/sheet1.xml", "xl/worksheets/sheet1.xml"] && found.map { $0.3 } == ["chartsheet", "worksheet"])
    }

    // openpyxl: reader/tests/test_workbook.py::test_print_area_title
    @Test func printAreaTitle() throws {
        let wb = try Workbook(data: try openpyxlFixture("reader/print_settings.xlsx"))
        #expect(wb.definedNames.count == 2)
        let ws = wb["Sheet"]!
        #expect(ws.printTitleRows == 1...1 && ws.printTitles == "'Sheet'!$1:$1")
        #expect(ws.printAreaFormula == "'Sheet'!$A$1:$D$5,'Sheet'!$B$9:$F$14" && ws.definedNames.isEmpty)
    }

    // openpyxl: reader/tests/test_workbook.py::test_assign_names
    @Test func assignNames() throws {
        let wb = Workbook(); wb.createSheet("Sheet2")
        let p = WorkbookXMLParser()
        try p.run(Data("""
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><definedNames>
        <definedName name="GlobalRef">Sheet1!$A$1</definedName>
        <definedName name="Sheet0Ref" localSheetId="0">Sheet1!$A$3</definedName>
        <definedName name="Sheet1Ref" localSheetId="1">Sheet2!$A$1</definedName>
        <definedName name="Sheet0Value" localSheetId="0">3.33</definedName>
        <definedName name="Sheet1Value" localSheetId="1">14.4</definedName>
        <definedName name="GlobalValue">9.99</definedName>
        </definedNames></workbook>
        """.utf8), part: "wb")
        wb.definedNames = p.definedNames
        WorkbookReader.assignLocalNames(p.localNames, to: wb)
        #expect(Set(wb.definedNames.keys) == ["GlobalRef", "GlobalValue"] && Set(wb.active.definedNames.keys) == ["Sheet0Ref", "Sheet0Value"])
    }

    // openpyxl: reader/tests/test_workbook.py::test_name_invalid_index
    @Test func nameInvalidIndex() throws {
        let wb = Workbook()
        WorkbookReader.assignLocalNames([19: ["_xlnm.Print_Area": "'New Monthly Metals'!$B$1:$O$15"]], to: wb)
        #expect(wb.active.printArea.isEmpty)   // a name for a sheet that does not exist is dropped (openpyxl warns)
    }

    // openpyxl: reader/tests/test_workbook.py::test_book_views
    @Test func bookViews() throws {
        let zip = try ZipArchive(data: try openpyxlFixture("reader/bug137.xlsx"))
        let p = WorkbookXMLParser(); try p.run(try zip.read("xl/workbook.xml"), part: "workbook.xml")
        #expect(p.activeTab == 1)
    }
}

@Suite struct GenuineReadParityTests {
    static let generalStyleCases: [(String, String)] = [("A1", NumberFormat.general), ("A2", NumberFormat.dateXLSX14), ("A3", NumberFormat.number00), ("A4", NumberFormat.dateTime3), ("A5", NumberFormat.percentage00)]
    // openpyxl: tests/test_read.py::test_read_general_style
    @Test(arguments: generalStyleCases)
    func readGeneralStyle(_ cell: String, _ numberFormat: String) throws {
        let wb = try Workbook(data: try openpyxlFixture("genuine/empty-with-styles.xlsx"))
        #expect(wb["Sheet1"]![cell].numberFormat == numberFormat)
    }

    // openpyxl: tests/test_read.py::test_read_no_theme
    @Test func readNoTheme() throws {
        #expect(try Workbook(data: try openpyxlFixture("genuine/libreoffice_nrt.xlsx")).worksheets.count >= 1)
    }

    // openpyxl: tests/test_iter.py::test_nonstandard_name
    @Test func nonstandardName() throws {
        #expect(try Workbook(data: try openpyxlFixture("reader/nonstandard_workbook_name.xlsx")).sheetNames == ["Sheet1"])
    }

    // openpyxl: tests/test_iter.py::test_calculate_dimension
    @Test func calculateDimension() throws {
        let wb = try Workbook(data: try openpyxlFixture("genuine/sample.xlsx"))
        #expect(wb["Sheet2 - Numbers"]!.dimensions == "D1:AA30")
    }

    func sample() throws -> Workbook { try Workbook(data: try openpyxlFixture("genuine/sample.xlsx"), dataOnly: true) }

    // openpyxl: tests/test_iter.py::test_get_missing_cell
    @Test func getMissingCell() throws {
        #expect(try sample()["Sheet2 - Numbers"]!["A1"].value == nil)
    }

    // openpyxl: tests/test_iter.py::test_getitem
    @Test func getitem() throws {
        let ws = try sample()["Sheet1 - Text"]!
        #expect(ws.rows(maxRow: 1, maxColumn: 1)[0][0] === ws["A1"])
        #expect(ws.rows(maxRow: 30, maxColumn: 4).map { $0.map(\.coordinate) } == ws[range: "A1:D30"]!.map { $0.map(\.coordinate) })
    }

    // openpyxl: tests/test_iter.py::test_max_row
    @Test func maxRow() throws {
        #expect(try sample()["Sheet2 - Numbers"]!.maxRow == 30)
    }

    // openpyxl: tests/test_iter.py::test_max_column
    @Test(arguments: [("Sheet1 - Text", 7), ("Sheet2 - Numbers", 27), ("Sheet3 - Formulas", 4), ("Sheet4 - Dates", 3)])
    func maxColumn(_ sheetname: String, _ col: Int) throws {
        #expect(try sample()[sheetname]!.maxColumn == col)
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_text
    @Test func readFastIntegratedText() throws {
        let expected: [[CellValue?]] = [["This is cell A1 in Sheet 1", nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, nil],
                                        [nil, nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, "This is cell G5"]]
        let ws = try sample()["Sheet1 - Text"]!
        for (row, want) in zip(ws.values(), expected) { #expect(row == want) }
    }

    // openpyxl: tests/test_iter.py::test_read_single_cell_range
    @Test func readSingleCellRange() throws {
        #expect(try sample()["Sheet1 - Text"]!["A1"].value == .string("This is cell A1 in Sheet 1"))
    }

    // openpyxl: tests/test_iter.py::test_read_single_cell
    @Test func readSingleCell() throws {
        let ws = try sample()["Sheet1 - Text"]!
        let c1 = ws["A1"], c2 = ws["A1"]
        #expect(c1 === c2 && c1.value == c2.value && c1.value == .string("This is cell A1 in Sheet 1"))
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_numbers
    @Test func readFastIntegratedNumbers() throws {
        let ws = try sample()["Sheet2 - Numbers"]!
        #expect(ws[range: "D1:D30"]!.map { $0.map(\.value) } == (0..<30).map { [.integer($0 + 1)] })
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_numbers_2
    @Test func readFastIntegratedNumbers2() throws {
        let ws = try sample()["Sheet2 - Numbers"]!
        for (row, i) in zip(ws[range: "K1:K30"]!, 0..<30) { #expect(abs(row[0].value!.doubleValue! - Double(i + 1) / 100) < 1e-12) }
    }

    static let dateCases: [(String, CellValue)] = [
        ("A1", CellValue(CivilDate(year: 1973, month: 5, day: 20)!)),
        ("C1", .date(CivilDateTime(date: CivilDate(year: 1973, month: 5, day: 20)!, time: TimeOfDay(hour: 9, minute: 15, second: 2)))),
    ]
    // openpyxl: tests/test_iter.py::test_read_single_cell_date
    @Test(arguments: dateCases)
    func readSingleCellDate(_ coord: String, _ value: CellValue) throws {
        #expect(try sample()["Sheet4 - Dates"]![coord].value == value)
    }

    // openpyxl: tests/test_iter.py::test_read_boolean
    @Test(arguments: [("G9", true), ("G10", false)]) func readBoolean(_ coord: String, _ expected: Bool) throws {
        let cell = try sample()["Sheet2 - Numbers"]![coord]
        #expect(cell.coordinate == coord && cell.dataType == "b" && cell.value == .bool(expected))
    }

    static let formulaCases: [(Bool, CellValue)] = [(true, .integer(5)), (false, .formula("='Sheet2 - Numbers'!D5", cached: CellValueBox(.integer(5))))]
    // openpyxl: tests/test_iter.py::test_read_single_cell_formula
    @Test(arguments: formulaCases)
    func readSingleCellFormula(_ dataOnly: Bool, _ expected: CellValue) throws {
        let wb = try Workbook(data: try openpyxlFixture("genuine/sample.xlsx"), dataOnly: dataOnly)
        #expect(wb.dataOnly == dataOnly && wb["Sheet3 - Formulas"]!["D2"].value == expected)
    }

    // openpyxl: tests/test_iter.py::test_read_style_iter
    @Test func readStyleIter() throws {
        let wb = Workbook()
        let ft = Font(name: "Times New Roman", size: 15)
        wb.worksheets[0]["A1"].font = ft
        let back = try Workbook(data: try wb.save())
        #expect(back.worksheets[0]["A1"].font == ft)
    }

    // openpyxl: tests/test_iter.py::test_read_hyperlinks_read_only
    @Test func readHyperlinksReadOnly() throws {
        let ws = try parseSheet(try openpyxlFixtureText("reader/bug393-worksheet.xml"), sst: ["SOMETEXT"])
        #expect(ws["F2"].value == nil)
    }

    // openpyxl: tests/test_iter.py::test_read_with_missing_cells
    @Test func readWithMissingCells() throws {
        let ws = try parseSheet(try openpyxlFixtureText("reader/bug393-worksheet.xml"))
        let rows = ws.values()
        #expect(rows[1] == [nil, nil, 1, 2, 3] && rows[3] == [1, 2, nil, nil, 3])
    }

    // openpyxl: tests/test_iter.py::test_read_empty_sheet
    @Test func readEmptySheet() throws {
        let wb = try Workbook(data: try openpyxlFixture("genuine/empty.xlsx"))
        #expect(wb.active.rows().isEmpty)
    }

    // openpyxl: tests/test_iter.py::test_read_mac_date
    @Test func readMacDate() throws {
        let wb = try Workbook(data: try openpyxlFixture("genuine/mac_date.xlsx"))
        #expect(wb.active["A1"].value == CellValue(CivilDate(year: 2016, month: 10, day: 3)!))
    }

    // openpyxl: tests/test_iter.py::test_read_empty_rows
    @Test func readEmptyRows() throws {
        let ws = try parseSheet(try openpyxlFixtureText("reader/empty_rows.xml"))
        #expect(ws.rows().count == 7)   // rows start at 1 even though the first cell is in row 2
    }
}
