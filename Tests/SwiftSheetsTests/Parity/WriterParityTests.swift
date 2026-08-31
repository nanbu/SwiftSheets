import Foundation
#if canImport(FoundationXML)
import FoundationXML   // where Foundation is split, the XML parser lives in its own module
#endif
import Testing
@testable import SheetCore
@testable import SheetXLSX

@Suite struct WorksheetWriterParityTests {
    // openpyxl: worksheet/tests/test_writer.py::test_setup
    @Test func setup() {
        let ws = Workbook().sheets[0]
        #expect(ws.cells.values.allSatisfy { $0.hyperlink == nil && $0.comment == nil })
    }

    // openpyxl: worksheet/tests/test_writer.py::test_properties
    @Test func properties() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<sheetPr><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr/></sheetPr>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_dimensions
    @Test func dimensions() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<dimension ref=\"A1:A1\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_format
    @Test func format() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<sheetFormatPr baseColWidth=\"8\" defaultRowHeight=\"15\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_views
    @Test func views() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView></sheetViews>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_cols
    @Test func cols() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("A") { $0.width = 5 }
        #expect(sheetXML(ws).contains("<cols><col min=\"1\" max=\"1\" width=\"5\" customWidth=\"1\"/></cols>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_write_top
    @Test func writeTop() {
        let xml = sheetXML(Workbook().sheets[0])
        let top = "<sheetPr><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr/></sheetPr><dimension ref=\"A1:A1\"/><sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView></sheetViews><sheetFormatPr baseColWidth=\"8\" defaultRowHeight=\"15\"/>"
        #expect(xml.contains(top) && xml.range(of: top)!.upperBound == xml.range(of: "<sheetData>")!.lowerBound)   // and in this order
    }

    // openpyxl: worksheet/tests/test_writer.py::test_filter
    @Test func filter() {
        var ws = Workbook().sheets[0]
        ws.autoFilter = CellRange("A1:A10")
        #expect(sheetXML(ws).contains("</sheetData><autoFilter ref=\"A1:A10\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_merged_cells
    @Test func mergedCells() {
        var ws = Workbook().sheets[0]
        ws.merge("A1:B2")
        #expect(sheetXML(ws).contains("<mergeCells count=\"1\"><mergeCell ref=\"A1:B2\"/></mergeCells>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_hyperlinks
    @Test func hyperlinks() {
        var ws = Workbook().sheets[0]
        ws["A1"] = "test"; ws[cell: "A1"].hyperlink = Hyperlink(target: "http://test.com")
        let part = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, comments: nil, sink: WarningSink())
        #expect(part.xml.contains("<hyperlinks><hyperlink ref=\"A1\" r:id=\"rId1\"/></hyperlinks>"))
        #expect(part.rels == "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"http://test.com\" TargetMode=\"External\"/></Relationships>")
    }

    // openpyxl: worksheet/tests/test_writer.py::test_print
    @Test func print() {
        var ws = Workbook().sheets[0]
        ws.printOptions.headings = true
        #expect(sheetXML(ws).contains("<printOptions headings=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_margins
    @Test func margins() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<pageMargins left=\"0.75\" right=\"0.75\" top=\"1\" bottom=\"1\" header=\"0.5\" footer=\"0.5\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_page_setup
    @Test func pageSetup() {
        var ws = Workbook().sheets[0]
        ws.pageSetup.orientation = .portrait
        #expect(sheetXML(ws).contains("<pageSetup orientation=\"portrait\"/>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_write_tail
    @Test func writeTail() {
        #expect(sheetXML(Workbook().sheets[0]).hasSuffix("</sheetData><pageMargins left=\"0.75\" right=\"0.75\" top=\"1\" bottom=\"1\" header=\"0.5\" footer=\"0.5\"/></worksheet>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_row_dimensons
    @Test func rowDimensions() {
        var ws = Workbook().sheets[0]
        ws["A10"] = "test"
        ws.setRowDimension(9) { $0.height = 20 }; ws.setRowDimension(1) { $0.height = 30 }
        let xml = sheetXML(ws)
        #expect(xml.range(of: "<row r=\"2\"")!.lowerBound < xml.range(of: "<row r=\"10\"")!.lowerBound && xml.contains("<row r=\"2\" ht=\"30\" customHeight=\"1\"></row>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_rows_sort
    @Test func rowsSort() {
        var ws = Workbook().sheets[0]
        for c in ["F1", "B1", "A1", "D1", "E1", "C1"] { ws[c] = 1 }
        #expect(sheetXML(ws).contains("<row r=\"1\"><c r=\"A1\"><v>1</v></c><c r=\"B1\"><v>1</v></c><c r=\"C1\"><v>1</v></c><c r=\"D1\"><v>1</v></c><c r=\"E1\"><v>1</v></c><c r=\"F1\"><v>1</v></c></row>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_write_rows
    @Test func writeRows() {
        var ws = Workbook().sheets[0]
        ws["F1"] = 10
        ws.setRowDimension(0) { $0.height = 20 }; ws.setRowDimension(1) { $0.height = 30 }
        #expect(sheetXML(ws).contains("<sheetData><row r=\"1\" ht=\"20\" customHeight=\"1\"><c r=\"F1\"><v>10</v></c></row><row r=\"2\" ht=\"30\" customHeight=\"1\"></row></sheetData>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_write_row
    @Test func writeRow() {
        var ws = Workbook().sheets[0]
        ws["A10"] = 15
        #expect(sheetXML(ws).contains("<row r=\"10\"><c r=\"A10\"><v>15</v></c></row>"))
    }

    // openpyxl: worksheet/tests/test_writer.py::test_write_sheet
    @Test func writeSheet() {
        var ws = Workbook().sheets[0]
        ws["A10"] = 15; ws[cell: "A10"].hyperlink = Hyperlink(target: "http://www.example.com")
        let expected = "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            + "<sheetPr><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr/></sheetPr><dimension ref=\"A10:A10\"/>"
            + "<sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView></sheetViews><sheetFormatPr baseColWidth=\"8\" defaultRowHeight=\"15\"/>"
            + "<sheetData><row r=\"10\"><c r=\"A10\"><v>15</v></c></row></sheetData>"
            + "<hyperlinks><hyperlink ref=\"A10\" r:id=\"rId1\"/></hyperlinks>"
            + "<pageMargins left=\"0.75\" right=\"0.75\" top=\"1\" bottom=\"1\" header=\"0.5\" footer=\"0.5\"/></worksheet>"
        #expect(sheetXML(ws) == expected)
    }
}

@Suite struct ExcelWriterParityTests {
    // openpyxl: writer/tests/test_excel.py::test_worksheet
    @Test func worksheet() throws {
        let zip = try ZipArchive(data: try XLSXCodec.write(Workbook()).data)
        #expect(zip.contains("xl/worksheets/sheet1.xml"))
        #expect(String(decoding: try zip.read("[Content_Types].xml"), as: UTF8.self).contains("PartName=\"/xl/worksheets/sheet1.xml\""))
    }

    // openpyxl: writer/tests/test_excel.py::test_write_empty_workbook
    @Test func writeEmptyWorkbook() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty_book-\(UUID().uuidString).xlsx")
        try XLSXCodec.write(Workbook()).data.write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    // openpyxl: writer/tests/test_excel.py::test_modified
    @Test func modified() throws {
        var wb = Workbook()
        let modified = Date(timeIntervalSince1970: 1_305_800_595)   // 2011-05-19 10:23:15
        wb.metadata.modified = modified
        let data = try XLSXCodec.write(wb).data
        // openpyxl stamps "now" on save; SwiftSheets keeps the value as set so output is reproducible
        let back = try XLSXCodec.read(data).workbook
        #expect(wb.metadata.modified == modified && back.metadata.modified == modified)
    }
}

@Suite struct PackagingCoreParityTests {
    static func sample() -> DocumentProperties {
        var p = DocumentProperties()
        p.keywords = "one, two, three"; p.created = Date(timeIntervalSince1970: 1_270_153_800); p.modified = Date(timeIntervalSince1970: 1_270_476_330)
        p.lastPrinted = Date(timeIntervalSince1970: 1_413_282_600); p.category = "The category"; p.contentStatus = "The status"; p.creator = "TEST_USER"
        p.lastModifiedBy = "SOMEBODY"; p.revision = "0"; p.version = "2.5"; p.description = "The description"; p.identifier = "The identifier"
        p.language = "The language"; p.subject = "The subject"; p.title = "The title"
        return p
    }

    // openpyxl: packaging/tests/test_core.py::test_ctor
    @Test func ctor() {
        let xml = WorkbookWriter.coreXML(Self.sample())
        for piece in ["<dc:creator>TEST_USER</dc:creator>", "<dc:title>The title</dc:title>", "<dc:description>The description</dc:description>", "<dc:subject>The subject</dc:subject>",
                      "<dc:identifier>The identifier</dc:identifier>", "<dc:language>The language</dc:language>",
                      "<dcterms:created xsi:type=\"dcterms:W3CDTF\">2010-04-01T20:30:00Z</dcterms:created>", "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">2010-04-05T14:05:30Z</dcterms:modified>",
                      "<cp:lastModifiedBy>SOMEBODY</cp:lastModifiedBy>", "<cp:category>The category</cp:category>", "<cp:contentStatus>The status</cp:contentStatus>", "<cp:version>2.5</cp:version>",
                      "<cp:revision>0</cp:revision>", "<cp:keywords>one, two, three</cp:keywords>", "<cp:lastPrinted>2014-10-14T10:30:00Z</cp:lastPrinted>"] {
            #expect(xml.contains(piece), "missing \(piece)")
        }
    }

    // openpyxl: packaging/tests/test_core.py::test_from_tree
    @Test func fromTree() throws {
        let p = CorePropertiesParser()
        try p.run(try openpyxlFixture("packaging/core.xml"), part: "core.xml")
        #expect(p.props == Self.sample())
    }

    // openpyxl: packaging/tests/test_core.py::test_qualified_datetime
    @Test func qualifiedDatetime() {
        var p = DocumentProperties(); p.created = Date(timeIntervalSince1970: 1_437_395_400.123456)   // 2015-07-20T12:30:00.123456
        #expect(WorkbookWriter.coreXML(p).contains("<dcterms:created xsi:type=\"dcterms:W3CDTF\">2015-07-20T12:30:00Z</dcterms:created>"))   // whole seconds only
    }

    // openpyxl: packaging/tests/test_core.py::test_settable_times
    @Test func settableTimes() {
        var p = DocumentProperties()
        let created = Date(timeIntervalSince1970: -28_502_716_584), modified = Date(timeIntervalSince1970: -9_566_154_898)
        p.created = created; p.modified = modified
        #expect(p.created == created && p.modified == modified)
    }
}

@Suite struct PackagingRelationshipParityTests {
    static let rels = """
    <Relationships>
      <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/chartsheet" Target="chartsheets/sheet1.xml"/>
      <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>
      <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    // openpyxl: packaging/tests/test_relationship.py::test_ctor
    @Test func ctor() throws {
        let p = RelsParser()
        try p.run(Data("<Relationships><Relationship Id=\"4\" Target=\"drawings.xml\" TargetMode=\"external\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing\"/></Relationships>".utf8), part: "rels")
        let rel = p.rels[0]
        #expect(rel.id == "4" && rel.target == "drawings.xml" && rel.targetMode == "external" && rel.type.hasSuffix("/drawing"))
    }

    // openpyxl: packaging/tests/test_relationship.py::test_sequence
    @Test func sequence() throws {
        var wb = Workbook(); wb.addSheet()
        let rels = String(decoding: try ZipArchive(data: try XLSXCodec.write(wb).data).read("xl/_rels/workbook.xml.rels"), as: UTF8.self)
        #expect(rels.contains("<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\""))
    }

    // openpyxl: packaging/tests/test_relationship.py::test_read
    @Test func read() throws {
        let p = RelsParser(); try p.run(Data(Self.rels.utf8), part: "rels")
        #expect(p.rels.count == 5)
    }

    // openpyxl: packaging/tests/test_relationship.py::test_to_dict
    @Test func toDict() throws {
        let p = RelsParser(); try p.run(Data(Self.rels.utf8), part: "rels")
        #expect(Set(p.rels.map(\.id)) == ["rId3", "rId2", "rId1", "rId4", "rId5"])
    }

    static let dependentCases: [(String, [String])] = [
        ("xl/_rels/workbook.xml.rels", ["xl/theme/theme1.xml", "xl/worksheets/sheet1.xml", "xl/chartsheets/sheet1.xml", "xl/sharedStrings.xml", "xl/styles.xml"]),
        ("xl/chartsheets/_rels/sheet1.xml.rels", ["xl/drawings/drawing1.xml"]),
    ]
    // openpyxl: packaging/tests/test_relationship.py::test_get_dependents
    @Test(arguments: dependentCases)
    func getDependents(_ filename: String, _ expected: [String]) throws {
        let zip = try ZipArchive(data: try openpyxlFixture("packaging/bug137.xlsx"))
        let rels = try WorkbookReader.parseRels(zip, filename)
        let base = filename.replacingOccurrences(of: "_rels/", with: "").split(separator: "/").dropLast().joined(separator: "/")
        #expect(rels.map { WorkbookReader.resolvePart($0.target, relativeTo: base) } == expected)
    }

    // openpyxl: packaging/tests/test_relationship.py::test_get_external_link
    @Test func getExternalLink() throws {
        let zip = try ZipArchive(data: try openpyxlFixture("packaging/hyperlink.xlsx"))
        #expect(try WorkbookReader.parseRels(zip, "xl/worksheets/_rels/sheet1.xml.rels").map(\.target) == ["http://www.readthedocs.org"])
    }
}

@Suite struct PackagingWorkbookParityTests {
    // openpyxl: packaging/tests/test_workbook.py::test_ctor
    @Test func ctor() throws {
        let xml = String(decoding: try ZipArchive(data: try XLSXCodec.write(Workbook()).data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"") && xml.contains("<workbookPr/>"))
    }

    // openpyxl: packaging/tests/test_workbook.py::test_from_xml
    @Test func fromXML() throws {
        let p = WorkbookXMLParser(); try p.run(Data("<workbook />".utf8), part: "wb")
        #expect(p.sheets.isEmpty && !p.date1904 && p.definedNames.isEmpty && p.codeName == nil)
    }

    // openpyxl: packaging/tests/test_workbook.py::test_read_workbook_code_name
    @Test func readWorkbookCodeName() throws {
        let p = WorkbookXMLParser(); try p.run(try openpyxlFixture("packaging/workbook_russian_code_name.xml"), part: "wb")
        #expect(p.codeName == "\u{42d}\u{442}\u{430}\u{41a}\u{43d}\u{438}\u{433}\u{430}")
    }
}
