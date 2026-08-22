import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

// PORT-NOTE: the original file used the shared `parseSheet` / `parseStyles` / `openpyxlFixture` helpers that live in
// WorksheetPartsParityTests.swift / StylesParityTests.swift. Those files are ported concurrently, so this file carries
// its own copies in a private namespace (no top-level names that could clash with theirs).
private enum ReaderParity {
    static func fixture(_ path: String) throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        let file = parts.last!
        let dot = file.lastIndex(of: ".")!
        let url = Bundle.module.url(forResource: String(file[..<dot]), withExtension: String(file[file.index(after: dot)...]),
                                    subdirectory: (["Fixtures", "openpyxl"] + parts.dropLast()).joined(separator: "/"))!
        return try Data(contentsOf: url)
    }

    static func fixtureText(_ path: String) throws -> String { String(decoding: try fixture(path), as: UTF8.self) }

    /// Parses a styles.xml document (or a fragment wrapped in `<styleSheet>`) with the production parser.
    static func styles(_ xml: String) throws -> StylesParser {
        let p = StylesParser()
        let doc = xml.contains("<styleSheet") || xml.contains("<x:styleSheet") ? xml : "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\(xml)</styleSheet>"
        try p.run(Data(doc.utf8), part: "styles.xml")
        return p
    }

    /// Parses a worksheet XML document (or a fragment) into a fresh sheet with the production parser.
    static func sheet(_ xml: String, styles: StylesParser = StylesParser(), sst: [CellValue] = [], epoch: DateEpoch = .windows1900, dataOnly: Bool = false,
                      rels: [Relationship] = []) throws -> Sheet {
        let doc = xml.contains("<worksheet") ? xml : "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(xml)</worksheet>"
        let p = SheetParser(name: "Sheet", sst: sst, styles: styles, epoch: epoch, dataOnly: dataOnly, rels: rels)
        try p.run(Data(doc.utf8), part: "sheet1.xml")
        return p.sheet
    }
}

@Suite struct WorksheetReaderParityTests {
    /// openpyxl's parser fixture: style 29 / 30 are date formats, 30 is also a timedelta format.
    func styles() throws -> StylesParser {
        var xfs = ""
        for i in 0..<29 { xfs += "<xf numFmtId=\"\(i == 1 ? 14 : 0)\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>" }
        xfs += "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/><xf numFmtId=\"46\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
        return try ReaderParity.styles("<cellXfs count=\"31\">\(xfs)</cellXfs>")
    }
    func sheet(_ xml: String, sst: [CellValue] = ["a"], dataOnly: Bool = false, epoch: DateEpoch = .windows1900, rels: [Relationship] = []) throws -> Sheet {
        try ReaderParity.sheet(xml, styles: try styles(), sst: sst, epoch: epoch, dataOnly: dataOnly, rels: rels)
    }

    static let numberCases: [(String, Double)] = [("4.2", 4.2), ("-42.000", -42), ("0", 0), ("0.9999", 0.9999), ("99E-02", 0.99), ("4", 4), ("-1E3", -1000), ("1E-3", 0.001), ("2e+2", 200)]
    // openpyxl: worksheet/tests/test_reader.py::test_number_convesion
    @Test(arguments: numberCases)
    func numberConversion(_ value: String, _ expected: Double) throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><v>\(value)</v></c></row></sheetData>")
        #expect(ws["A1"]?.doubleValue == expected)
        #expect((ws["A1"]?.dataType == "n"))
    }

    static let dimensionCases: [(String, CellRange?)] = [("dimension.xml", CellRange(minRow: 0, minCol: 3, maxRow: 29, maxCol: 26)), ("no_dimension.xml", nil), ("invalid_dimension.xml", nil)]
    // openpyxl: worksheet/tests/test_reader.py::test_read_dimension
    @Test(arguments: dimensionCases)
    func readDimension(_ filename: String, _ expected: CellRange?) throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("worksheet/\(filename)"))
        #expect(ws.declaredDimension == expected)   // "1:113" (invalid) is not a cell range for SwiftSheets
    }

    // openpyxl: worksheet/tests/test_reader.py::test_col_width
    @Test func colWidth() throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"))
        #expect(Set(ws.columnDimensions.keys) == [0, 2, 4, 8, 6])   // A, C, E, I, G
        #expect(ws.columnDimension("A") == ColumnDimension(width: 31.1640625))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_hidden_col
    @Test func hiddenCol() throws {
        let ws = try sheet("<cols><col min=\"4\" max=\"4\" width=\"0\" hidden=\"1\" customWidth=\"1\"/></cols>")
        #expect(ws.columnDimensions[3] == ColumnDimension(width: 0, hidden: true))   // D
    }

    // openpyxl: worksheet/tests/test_reader.py::test_styled_col
    @Test func styledCol() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"))
        let cd = ws.columnDimension("I")
        #expect(cd.width == 25 && cd.style != nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_dimensions
    @Test func rowDimensions() throws {
        let ws = try sheet("<sheetData><row r=\"2\" spans=\"1:6\" /></sheetData>")
        #expect(ws.rowDimensions[1] == nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_hidden_row
    @Test func hiddenRow() throws {
        let ws = try sheet("<sheetData><row r=\"2\" spans=\"1:4\" hidden=\"1\" /></sheetData>")
        #expect(ws.rowDimensions[1] == RowDimension(hidden: true))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_styled_row
    @Test func styledRow() throws {
        let ws = try sheet("<sheetData><row r=\"23\" s=\"28\" spans=\"1:8\" /></sheetData>")
        #expect(ws.rowDimensions[22]?.style != nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_read_row_with_exponent
    @Test func readRowWithExponent() throws {
        let ws = try sheet("<sheetData><row r=\"1.048573e6\" spans=\"1:8\" /></sheetData>")
        #expect(ws.nextAppendRow == 1048573)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_invalid_row_number
    @Test func invalidRowNumber() throws {
        #expect(throws: SheetError.self) { try sheet("<sheetData><row r=\"1.5\" spans=\"1:8\" /></sheetData>") }
    }

    // openpyxl: worksheet/tests/test_reader.py::test_formula
    @Test func formula() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><f>IF(TRUE, \"y\", \"n\")</f><v>y</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "f" && ws["A1"] == .formula(FormulaExpr.parse("=IF(TRUE, \"y\", \"n\")"), cached: .text("y")))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_formula_data_only
    @Test func formulaDataOnly() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><f>1+2</f><v>3</v></c></row></sheetData>", dataOnly: true)
        #expect(ws[cell: "A1"].dataType == "n" && ws["A1"] == .integer(3))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_string_formula_data_only
    @Test func stringFormulaDataOnly() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"str\"><f>IF(TRUE, \"y\", \"n\")</f><v>y</v></c></row></sheetData>", dataOnly: true)
        #expect(ws[cell: "A1"].dataType == "s" && ws["A1"] == .text("y"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_number
    @Test func number() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "n" && ws["A1"] == .integer(1))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_datetime
    @Test func datetime() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"d\"><v>2011-12-25T14:23:55</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "d" && ws["A1"] == .date(CivilDateTime(date: CivilDate(year: 2011, month: 12, day: 25)!, time: TimeOfDay(hour: 14, minute: 23, second: 55))))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_timedelta
    @Test func timedelta() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"30\"><v>1.25</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "d" && ws["A1"] == .duration(.seconds(86400 + 6 * 3600)))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_mac_date
    @Test func macDate() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"29\"><v>41184</v></c></row></sheetData>", epoch: .mac1904)
        #expect(ws["A1"] == CellValue(CivilDate(year: 2016, month: 10, day: 3)!))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_out_of_range_datetime
    @Test(arguments: [-693595, 2958466]) func outOfRangeDatetime(_ value: Int) throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"n\" s=\"29\"><v>\(value)</v></c></row></sheetData>")
        #expect(ws["A1"] != nil)   // openpyxl warns and keeps going; SwiftSheets keeps the (proleptic) date
    }

    // openpyxl: worksheet/tests/test_reader.py::test_string
    @Test func string() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "s" && ws["A1"] == .text("a"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_boolean
    @Test func boolean() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"b\"><v>1</v></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "b" && ws["A1"] == .bool(true))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_inline_string
    @Test func inlineString() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" s=\"0\" t=\"inlineStr\"><is><t>ID</t></is></c></row></sheetData>")
        #expect(ws[cell: "A1"].dataType == "s" && ws["A1"] == .text("ID"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_inline_richtext
    @Test func inlineRichtext() throws {
        let ws = try sheet("<sheetData><row r=\"2\"><c r=\"R2\" s=\"4\" t=\"inlineStr\"><is><r><rPr><sz val=\"8.0\"/></rPr><t xml:space=\"preserve\">11 de September de 2014</t></r></is></c></row></sheetData>")
        #expect(ws["R2"] == .richText([TextRun("11 de September de 2014", font: Font(size: 8))]))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_parse_richtext
    @Test func parseRichtext() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><r><rPr><sz val=\"8.0\"/></rPr><t xml:space=\"preserve\">11 de September de 2014</t></r></is></c></row></sheetData>")
        #expect(ws["A1"]?.textValue == "11 de September de 2014")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_sheet_views
    @Test func sheetViews() throws {
        let ws = try sheet("""
        <sheetViews><sheetView tabSelected="1" zoomScale="200" zoomScaleNormal="200" zoomScalePageLayoutView="200" workbookViewId="0">
          <pane xSplit="5" ySplit="19" topLeftCell="F20" activePane="bottomRight" state="frozenSplit"/>
          <selection pane="topRight" activeCell="F1" sqref="F1"/><selection pane="bottomLeft" activeCell="A20" sqref="A20"/><selection pane="bottomRight" activeCell="E22" sqref="E22"/>
        </sheetView></sheetViews>
        """)
        #expect(ws.view.zoomScale == 200 && ws.view.activeCell == "E22" && ws.freezePanes?.a1 == "F20")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cell_without_coordinates
    @Test func cellWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row r=\"1\"><c t=\"s\"><v>2</v></c><c t=\"s\"><v>4</v></c><c t=\"s\"><v>3</v></c><c t=\"s\"><v>6</v></c><c t=\"s\"><v>9</v></c></row></sheetData>",
                           sst: Array(repeating: .text("Whatever"), count: 10))
        #expect(ws.nextAppendRow == 1 && ws.columnCount == 5 && ws["E1"] == .text("Whatever"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_and_cell_without_coordinates
    @Test func rowAndCellWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>2</v></c><c><v>4</v></c><c><v>3</v></c></row></sheetData>")
        #expect(ws.values() == [[2, 4, 3]] && ws.extent?.minRow == 0)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_row_and_cell_skipping_coordinates
    @Test func rowAndCellSkippingCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>1</v></c><c r=\"D1\"><v>2</v></c><c><v>3</v></c><c r=\"G1\"><v>4</v></c></row></sheetData>")
        #expect(ws.cells.count == 4 && ws["A1"] == 1 && ws["D1"] == 2 && ws["E1"] == 3 && ws["G1"] == 4)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_second_row_cell_index_without_coordinates
    @Test func secondRowCellIndexWithoutCoordinates() throws {
        let ws = try sheet("<sheetData><row><c><v>2</v></c></row><row><c><v>2</v></c></row></sheetData>")
        #expect(ws["A2"] == 2 && ws.rowCount == 2)
    }

    // openpyxl: worksheet/tests/test_reader.py::TestWorksheetParser::test_external_hyperlinks
    @Test func externalHyperlinks() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "http://test.com", targetMode: "External")
        let ws = try sheet("<hyperlinks><hyperlink display=\"http://test.com\" r:id=\"rId1\" ref=\"A1\"/></hyperlinks>", rels: [rel])
        #expect(ws.cells.values.filter { $0.hyperlink != nil }.count == 1)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_local_hyperlinks
    @Test func localHyperlinks() throws {
        let ws = try sheet("<hyperlinks><hyperlink ref=\"B4:B7\" location=\"'STP nn000TL-10, PKG 2.52'!A1\" display=\"STP 10000TL-10\"/></hyperlinks>")
        #expect(ws.cells.values.filter { $0.hyperlink != nil }.count == 1 && ws[cell: "B4"].hyperlink?.location == "'STP nn000TL-10, PKG 2.52'!A1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merge_cells
    @Test func mergeCells() throws {
        let ws = try sheet("<mergeCells><mergeCell ref=\"C2:F2\"/><mergeCell ref=\"B19:C20\"/><mergeCell ref=\"E19:G19\"/></mergeCells>")
        #expect(ws.merges.map(\.a1) == ["C2:F2", "B19:C20", "E19:G19"])
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
        #expect(ws.autoFilter?.a1 == "A1:AK3237")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cell
    @Test func cell() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws["C1"] == .text("a"))
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merged
    @Test func merged() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.merges.map(\.a1) == ["G18:H18", "G23:H24", "A18:B18"])
    }

    static let normalizeCases: [(String, String?)] = [("H18", "G18"), ("G18", "G18"), ("I18", nil), ("H23", "G23")]
    // openpyxl: worksheet/tests/test_reader.py::test_normalize_merged_cell_link
    @Test(arguments: normalizeCases)
    func normalizeMergedCellLink(_ input: String, _ expected: String?) throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.mergedRange(containing: CellRef(input)!)?.topLeft.a1 == expected)
    }

    // openpyxl: worksheet/tests/test_reader.py::TestWorksheetReader::test_external_hyperlinks
    @Test func primedExternalHyperlinks() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "../", targetMode: nil)
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30), rels: [rel])
        #expect(ws[cell: "A1"].hyperlink?.target == "../")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_internal_hyperlinks
    @Test func internalHyperlinks() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws[cell: "B4"].hyperlink?.location == "'STP nn000TL-10, PKG 2.52'!A1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_merged_hyperlinks
    @Test func mergedHyperlinks() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.merges.map(\.a1) == ["G18:H18", "G23:H24", "A18:B18"])
        #expect(ws[cell: "A18"].hyperlink?.display == "http://test.com" && ws[cell: "B18"].hyperlink == nil)
        // Link referencing H24 lands on G23, the top-left cell of the merged range
        #expect(ws[cell: "G23"].hyperlink?.tooltip == "openpyxl" && ws[cell: "H24"].hyperlink == nil)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_cols
    @Test func cols() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.columnDimensions.count == 5)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_rows
    @Test func rows() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.rowDimensions.count == 7)
    }

    // openpyxl: worksheet/tests/test_reader.py::test_properties
    @Test func properties() throws {
        let ws = try sheet(try ReaderParity.fixtureText("worksheet/complex-styles-worksheet.xml"), sst: Array(repeating: .text("a"), count: 30))
        #expect(ws.pageMargins == PageMargins() && ws.pageSetup.orientation == .portrait && ws.sheetFormat.baseColWidth == 10 && ws.view.activeCell == "I1")
    }

    // openpyxl: worksheet/tests/test_reader.py::test_more_rows_than_cells
    @Test func moreRowsThanCells() throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("worksheet/more_rows_than_cells.xml"))
        #expect(ws.nextAppendRow == 3)
    }
}

@Suite struct ExcelReaderParityTests {
    // openpyxl: reader/tests/test_excel.py::test_read_empty_file
    @Test func readEmptyFile() throws {
        #expect(throws: SheetError.self) { try XLSXCodec.read(try ReaderParity.fixture("reader/null_file.xlsx")) }
    }

    // openpyxl: reader/tests/test_excel.py::test_load_workbook_from_fileobj
    @Test func loadWorkbookFromFileobj() throws {
        _ = try XLSXCodec.read(try ReaderParity.fixture("reader/empty_with_no_properties.xlsx"))   // no docProps: loads without exceptions
    }

    // openpyxl: reader/tests/test_excel.py::test_style_assignment
    @Test func styleAssignment() throws {
        let data = try ReaderParity.fixture("reader/complex-styles.xlsx")
        let wb = try XLSXCodec.read(data)
        let sheet = try ReaderParity.styles(String(decoding: try ZipArchive(data: data).read("xl/styles.xml"), as: UTF8.self))
        #expect(Set(sheet.cellXfs.map(\.alignment)).count == 9 && sheet.fills.count == 6 && sheet.fonts.count == 8)
        // 7 + 4 borders: the top-left cell of each merged range gets a new border and the old ones are kept
        // openpyxl counts 7 + 4 borders because every intermediate `border +=` result of merged-range formatting is kept
        // in its border list; SwiftSheets has no such list, so only the distinct final borders are counted: 7 + 1.
        #expect(Set(sheet.borders).count == 7 && Set(sheet.borders).union(wb.activeSheet.cells.values.map(\.border)).count == 8)
        #expect(sheet.customNumberFormats.isEmpty && Set(sheet.cellXfs.map(\.protection)).count == 1)
    }

    // openpyxl: reader/tests/test_excel.py::test_read_stringio
    @Test func readStringio() {
        #expect(throws: SheetError.self) { try XLSXCodec.read(Data("certainly not a valid XSLX content".utf8)) }
    }

    // openpyxl: reader/tests/test_excel.py::test_ctor
    @Test func ctor() throws {
        let zip = try ZipArchive(data: try ReaderParity.fixture("reader/complex-styles.xlsx"))
        #expect(Set(zip.entries.keys) == ["[Content_Types].xml", "_rels/.rels", "xl/_rels/workbook.xml.rels", "xl/workbook.xml", "xl/sharedStrings.xml", "xl/theme/theme1.xml",
                                          "xl/styles.xml", "xl/worksheets/sheet1.xml", "docProps/thumbnail.jpeg", "docProps/core.xml", "docProps/app.xml"])
    }

    // openpyxl: reader/tests/test_excel.py::test_read_strings
    @Test func readStrings() throws {
        let zip = try ZipArchive(data: try ReaderParity.fixture("reader/complex-styles.xlsx"))
        let p = SharedStringsParser(); try p.run(try zip.read("xl/sharedStrings.xml"), part: "sst")
        #expect(!p.strings.isEmpty)
    }

    // openpyxl: reader/tests/test_excel.py::test_read_workbook
    @Test func readWorkbook() throws {
        #expect(try XLSXCodec.read(try ReaderParity.fixture("reader/complex-styles.xlsx")).sheetNames == ["Sheet1"])
    }

    // openpyxl: reader/tests/test_excel.py::test_read_workbook_hidden
    @Test func readWorkbookHidden() throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("reader/hidden_sheets.xlsx"))
        #expect(wb.sheetNames == ["Sheet", "Hidden", "VeryHidden"] && wb.sheets[1].state == .hidden && wb.sheets[2].state == .veryHidden)
    }
}

@Suite struct StringsReaderParityTests {
    func table(_ path: String) throws -> [CellValue] {
        let p = SharedStringsParser(); try p.run(try ReaderParity.fixture(path), part: path); return p.strings
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
        try p.run(try ReaderParity.fixture("reader/workbook_1904.xml"), part: "workbook.xml")
        #expect(p.date1904)
    }

    // openpyxl: reader/tests/test_workbook.py::test_find_sheets
    @Test func findSheets() throws {
        let zip = try ZipArchive(data: try ReaderParity.fixture("reader/bug137.xlsx"))
        let p = WorkbookXMLParser(); try p.run(try zip.read("xl/workbook.xml"), part: "workbook.xml")
        let rels = try WorkbookReader.parseRels(zip, "xl/_rels/workbook.xml.rels")
        let found = p.sheets.map { s in (s.name, s.state, rels.first { $0.id == s.rId }?.target ?? "", rels.first { $0.id == s.rId }?.type.split(separator: "/").last.map(String.init) ?? "") }
        #expect(found.map { $0.0 } == ["Chart1", "Sheet1"] && found.map { $0.1 } == [.visible, .visible])
        #expect(found.map { "xl/" + $0.2 } == ["xl/chartsheets/sheet1.xml", "xl/worksheets/sheet1.xml"] && found.map { $0.3 } == ["chartsheet", "worksheet"])
    }

    // openpyxl: reader/tests/test_workbook.py::test_print_area_title
    @Test func printAreaTitle() throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("reader/print_settings.xlsx"))
        #expect(wb.definedNames.count == 2)
        let ws = wb.sheets["Sheet"]!
        #expect(ws.printTitleRows == 0...0 && ws.printTitles == "'Sheet'!$1:$1")
        #expect(ws.printAreaFormula == "'Sheet'!$A$1:$D$5,'Sheet'!$B$9:$F$14" && ws.definedNames.isEmpty)
    }

    // openpyxl: reader/tests/test_workbook.py::test_assign_names
    @Test func assignNames() throws {
        var wb = Workbook(); wb.addSheet(named: "Sheet2")
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
        WorkbookReader.assignLocalNames(p.localNames, to: &wb)
        #expect(Set(wb.definedNames.keys) == ["GlobalRef", "GlobalValue"] && Set(wb.activeSheet.definedNames.keys) == ["Sheet0Ref", "Sheet0Value"])
    }

    // openpyxl: reader/tests/test_workbook.py::test_name_invalid_index
    @Test func nameInvalidIndex() throws {
        var wb = Workbook()
        WorkbookReader.assignLocalNames([19: ["_xlnm.Print_Area": "'New Monthly Metals'!$B$1:$O$15"]], to: &wb)
        #expect(wb.activeSheet.printArea.isEmpty)   // a name for a sheet that does not exist is dropped (openpyxl warns)
    }

    // openpyxl: reader/tests/test_workbook.py::test_book_views
    @Test func bookViews() throws {
        let zip = try ZipArchive(data: try ReaderParity.fixture("reader/bug137.xlsx"))
        let p = WorkbookXMLParser(); try p.run(try zip.read("xl/workbook.xml"), part: "workbook.xml")
        #expect(p.activeTab == 1)
    }
}

@Suite struct GenuineReadParityTests {
    static let generalStyleCases: [(String, String)] = [("A1", NumberFormat.general), ("A2", NumberFormat.dateXLSX14), ("A3", NumberFormat.number00), ("A4", NumberFormat.dateTime3), ("A5", NumberFormat.percentage00)]
    // openpyxl: tests/test_read.py::test_read_general_style
    @Test(arguments: generalStyleCases)
    func readGeneralStyle(_ cell: String, _ numberFormat: String) throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("genuine/empty-with-styles.xlsx"))
        #expect(wb.sheets["Sheet1"]![cell: cell].numberFormat == numberFormat)
    }

    // openpyxl: tests/test_read.py::test_read_no_theme
    @Test func readNoTheme() throws {
        #expect(try XLSXCodec.read(try ReaderParity.fixture("genuine/libreoffice_nrt.xlsx")).sheets.count >= 1)
    }

    // openpyxl: tests/test_iter.py::test_nonstandard_name
    @Test func nonstandardName() throws {
        #expect(try XLSXCodec.read(try ReaderParity.fixture("reader/nonstandard_workbook_name.xlsx")).sheetNames == ["Sheet1"])
    }

    // openpyxl: tests/test_iter.py::test_calculate_dimension
    @Test func calculateDimension() throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("genuine/sample.xlsx"))
        #expect(wb.sheets["Sheet2 - Numbers"]!.dimensions == "D1:AA30")
    }

    func sample() throws -> Workbook { try XLSXCodec.read(try ReaderParity.fixture("genuine/sample.xlsx"), options: ReadOptions(dataOnly: true)) }

    // openpyxl: tests/test_iter.py::test_get_missing_cell
    @Test func getMissingCell() throws {
        #expect(try sample().sheets["Sheet2 - Numbers"]!["A1"] == nil)
    }

    // openpyxl: tests/test_iter.py::test_getitem
    @Test func getitem() throws {
        let ws = try sample().sheets["Sheet1 - Text"]!
        // PORT-NOTE: openpyxl checks that `ws[row][col] is ws["A1"]` (object identity). Cells are values now, so the
        // nearest equivalent is equality of the whole Cell reached through both paths; coordinates come from the
        // range's refs because cells no longer know their position.
        #expect(ws.cells(in: CellRange(minRow: 0, minCol: 0, maxRow: 0, maxCol: 0))[0][0] == ws[cell: "A1"])
        #expect(CellRange(minRow: 0, minCol: 0, maxRow: 29, maxCol: 3).rows.map { $0.map(\.a1) } == CellRange("A1:D30")!.rows.map { $0.map(\.a1) })
        #expect(ws.cells(in: CellRange(minRow: 0, minCol: 0, maxRow: 29, maxCol: 3)) == ws.cells(in: CellRange("A1:D30")!))
    }

    // openpyxl: tests/test_iter.py::test_max_row
    @Test func maxRow() throws {
        #expect(try sample().sheets["Sheet2 - Numbers"]!.rowCount == 30)
    }

    // openpyxl: tests/test_iter.py::test_max_column
    @Test(arguments: [("Sheet1 - Text", 7), ("Sheet2 - Numbers", 27), ("Sheet3 - Formulas", 4), ("Sheet4 - Dates", 3)])
    func maxColumn(_ sheetname: String, _ col: Int) throws {
        #expect(try sample().sheets[sheetname]!.columnCount == col)
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_text
    @Test func readFastIntegratedText() throws {
        let expected: [[CellValue?]] = [["This is cell A1 in Sheet 1", nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, nil],
                                        [nil, nil, nil, nil, nil, nil, nil], [nil, nil, nil, nil, nil, nil, "This is cell G5"]]
        let ws = try sample().sheets["Sheet1 - Text"]!
        for (row, want) in zip(ws.values(), expected) { #expect(row == want) }
    }

    // openpyxl: tests/test_iter.py::test_read_single_cell_range
    @Test func readSingleCellRange() throws {
        #expect(try sample().sheets["Sheet1 - Text"]!["A1"] == .text("This is cell A1 in Sheet 1"))
    }

    // openpyxl: tests/test_iter.py::test_read_single_cell
    @Test func readSingleCell() throws {
        let ws = try sample().sheets["Sheet1 - Text"]!
        // PORT-NOTE: openpyxl asserts `ws["A1"] is ws["A1"]` (identity). Cells are values now; two reads compare equal.
        let c1 = ws[cell: "A1"], c2 = ws[cell: "A1"]
        #expect(c1 == c2 && c1.value == c2.value && c1.value == .text("This is cell A1 in Sheet 1"))
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_numbers
    @Test func readFastIntegratedNumbers() throws {
        let ws = try sample().sheets["Sheet2 - Numbers"]!
        #expect(ws.rows(in: "D1:D30") == (0..<30).map { [.integer($0 + 1)] })
    }

    // openpyxl: tests/test_iter.py::test_read_fast_integrated_numbers_2
    @Test func readFastIntegratedNumbers2() throws {
        let ws = try sample().sheets["Sheet2 - Numbers"]!
        for (row, i) in zip(ws.rows(in: "K1:K30"), 0..<30) { #expect(abs(row[0]!.doubleValue! - Double(i + 1) / 100) < 1e-12) }
    }

    static let dateCases: [(String, CellValue)] = [
        ("A1", CellValue(CivilDate(year: 1973, month: 5, day: 20)!)),
        ("C1", .date(CivilDateTime(date: CivilDate(year: 1973, month: 5, day: 20)!, time: TimeOfDay(hour: 9, minute: 15, second: 2)))),
    ]
    // openpyxl: tests/test_iter.py::test_read_single_cell_date
    @Test(arguments: dateCases)
    func readSingleCellDate(_ coord: String, _ value: CellValue) throws {
        #expect(try sample().sheets["Sheet4 - Dates"]![coord] == value)
    }

    // openpyxl: tests/test_iter.py::test_read_boolean
    @Test(arguments: [("G9", true), ("G10", false)]) func readBoolean(_ coord: String, _ expected: Bool) throws {
        // PORT-NOTE: openpyxl checks `cell.coordinate == coord`; cells no longer know their position, so the
        // coordinate check is on the CellRef used to reach the cell (its A1 text round-trips).
        let ref = CellRef(coord)!
        let cell = try sample().sheets["Sheet2 - Numbers"]![cell: ref]
        #expect(ref.a1 == coord && cell.dataType == "b" && cell.value == .bool(expected))
    }

    static let formulaCases: [(Bool, CellValue)] = [(true, .integer(5)), (false, .formula(FormulaExpr.parse("='Sheet2 - Numbers'!D5"), cached: .integer(5)))]
    // openpyxl: tests/test_iter.py::test_read_single_cell_formula
    @Test(arguments: formulaCases)
    func readSingleCellFormula(_ dataOnly: Bool, _ expected: CellValue) throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("genuine/sample.xlsx"), options: ReadOptions(dataOnly: dataOnly))
        #expect(wb.dataOnly == dataOnly && wb.sheets["Sheet3 - Formulas"]!["D2"] == expected)
    }

    // openpyxl: tests/test_iter.py::test_read_style_iter
    @Test func readStyleIter() throws {
        var wb = Workbook()
        let ft = Font(name: "Times New Roman", size: 15)
        wb.sheets[0][cell: "A1"].font = ft
        let back = try XLSXCodec.read(try XLSXCodec.write(wb).data)
        #expect(back.sheets[0][cell: "A1"].font == ft)
    }

    // openpyxl: tests/test_iter.py::test_read_hyperlinks_read_only
    @Test func readHyperlinksReadOnly() throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("reader/bug393-worksheet.xml"), sst: ["SOMETEXT"])
        #expect(ws["F2"] == nil)
    }

    // openpyxl: tests/test_iter.py::test_read_with_missing_cells
    @Test func readWithMissingCells() throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("reader/bug393-worksheet.xml"))
        let rows = ws.values()
        #expect(rows[1] == [nil, nil, 1, 2, 3] && rows[3] == [1, 2, nil, nil, 3])
    }

    // openpyxl: tests/test_iter.py::test_read_empty_sheet
    @Test func readEmptySheet() throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("genuine/empty.xlsx"))
        #expect(wb.activeSheet.rows().isEmpty)
    }

    // openpyxl: tests/test_iter.py::test_read_mac_date
    @Test func readMacDate() throws {
        let wb = try XLSXCodec.read(try ReaderParity.fixture("genuine/mac_date.xlsx"))
        #expect(wb.activeSheet["A1"] == CellValue(CivilDate(year: 2016, month: 10, day: 3)!))
    }

    // openpyxl: tests/test_iter.py::test_read_empty_rows
    @Test func readEmptyRows() throws {
        let ws = try ReaderParity.sheet(try ReaderParity.fixtureText("reader/empty_rows.xml"))
        #expect(ws.rows().count == 7)   // rows start at 1 even though the first cell is in row 2
    }
}
