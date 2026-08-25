import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Four things a worksheet says that SwiftSheets used to keep only as opaque XML (or lose): the range an array
/// formula fills, printed headers and footers, manual page breaks, and the printer-settings link on `<pageSetup>`.
/// The first and the last were the last two entries of the README's "known limits of the current preservation".
@Suite struct WorksheetPartsTests {
    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path))
    }

    // MARK: - Array formulas

    @Test func arrayFormulaRangesSurvive() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1; wb.sheets[0]["B1"] = 2; wb.sheets[0]["C1"] = 3
        wb.sheets[0]["A2"] = .formula(FormulaExpr.parse("=TRANSPOSE(A1:C1)"), cached: .integer(1))
        wb.sheets[0].table.arrayFormulas[CellRef("A2")!] = CellRange("A2:A4")!

        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx))
        #expect(xml.contains("<f t=\"array\" ref=\"A2:A4\">TRANSPOSE(A1:C1)</f>"))

        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0].table.arrayFormulas[CellRef("A2")!] == CellRange("A2:A4"))
        #expect(again.sheets[0]["A2"]?.formula?.text == "=TRANSPOSE(A1:C1)")
        // an ordinary formula is still ordinary
        #expect(again.sheets[0].table.arrayFormulas[CellRef("A1")!] == nil)
    }

    // MARK: - Header and footer

    // openpyxl: worksheet/tests/test_header.py::TestHeaderFooterItem::test_write
    // openpyxl: worksheet/tests/test_header.py::TestHeaderFooter::test_from_xml
    @Test func headerAndFooterRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0].headerFooter.oddHeader = "&L四半期報告&C&P / &N"
        wb.sheets[0].headerFooter.oddFooter = "&R&F"
        wb.sheets[0].headerFooter.evenHeader = "&Leven"
        wb.sheets[0].headerFooter.firstHeader = "&Cfirst"
        wb.sheets[0].headerFooter.differentOddEven = true
        wb.sheets[0].headerFooter.differentFirst = true
        wb.sheets[0].headerFooter.scaleWithDoc = false

        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx))
        #expect(xml.contains("<headerFooter differentOddEven=\"1\" differentFirst=\"1\" scaleWithDoc=\"0\">"))
        #expect(xml.contains("<oddHeader>&amp;L四半期報告&amp;C&amp;P / &amp;N</oddHeader>"))
        // …and after <pageSetup>, where the schema puts it
        #expect(xml.range(of: "<pageMargins")!.lowerBound < xml.range(of: "<headerFooter")!.lowerBound)

        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0].headerFooter == wb.sheets[0].headerFooter)
    }

    // openpyxl: worksheet/tests/test_header.py::TestHeaderFooter::test_bool
    // openpyxl: worksheet/tests/test_pagebreak.py::TestRowBreak::test_no_brks
    @Test func anEmptyHeaderFooterWritesNothing() throws {
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try Workbook().data(as: .xlsx))
        #expect(!xml.contains("headerFooter"))
    }

    // MARK: - Page breaks

    // openpyxl: worksheet/tests/test_pagebreak.py::TestRowBreak::test_to_tree
    // openpyxl: worksheet/tests/test_pagebreak.py::TestColBreak::test_to_tree
    @Test func pageBreaksRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].rowBreaks = [10, 20]
        wb.sheets[0].columnBreaks = [3]

        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx))
        #expect(xml.contains("<rowBreaks count=\"2\" manualBreakCount=\"2\"><brk id=\"10\" max=\"16383\" man=\"1\"/><brk id=\"20\" max=\"16383\" man=\"1\"/></rowBreaks>"))
        #expect(xml.contains("<colBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"3\" max=\"1048575\" man=\"1\"/></colBreaks>"))

        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0].rowBreaks == [10, 20])
        #expect(again.sheets[0].columnBreaks == [3])
    }

    // MARK: - pageSetup r:id

    /// The printer-settings part travels as an opaque part; before this the `r:id` that tied it to the sheet did
    /// not, so the part was still in the package with nothing pointing at it.
    @Test func printerSettingsStayLinked() throws {
        let wb = try Workbook(data: try Self.fixture("preservation/printer-settings.xlsx"))
        let id = try #require(wb.sheets[0].preserved.pageSetupRelationshipId)
        let data = try wb.data(as: .xlsx)
        let path = try #require(wb.sheets[0].preserved.partPath)
        let sheetXML = try Package.part(path, of: data)
        let rels = try Package.part(WorkbookReader.relsPath(of: path), of: data)
        #expect(sheetXML.contains("<pageSetup") && sheetXML.contains("r:id=\"\(id)\""))
        #expect(rels.contains("Id=\"\(id)\"") && rels.contains("printerSettings1.bin"))
        #expect(try Workbook(data: data).sheets[0].preserved.pageSetupRelationshipId == id)
        // the part itself is still there, byte for byte
        let before = try ZipInspection(data: try Self.fixture("preservation/printer-settings.xlsx"))
        #expect(try ZipInspection(data: data).entry(named: "xl/printerSettings/printerSettings1.bin")
                == before.entry(named: "xl/printerSettings/printerSettings1.bin"))
    }
}

/// Auto-filter conditions and the sort state. Before this the range was in the model and the conditions were kept
/// only as source XML — readable by nobody, and lost on conversion. The exotic filter kinds (colour, icon, dynamic,
/// top 10, date groups) are still kept verbatim rather than half-modelled.
@Suite struct AutoFilterConditionTests {
    // openpyxl: worksheet/tests/test_filters.py::TestFilterColumn::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestFilters::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestFilters::test_write_filters
    // openpyxl: worksheet/tests/test_filters.py::TestCustomFilters::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestCustomFilter::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestSortState::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestSortCondition::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestAutoFilter::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestAutoFilter::test_add_filter_column
    // openpyxl: worksheet/tests/test_filters.py::TestAutoFilter::test_add_sort_condition
    @Test func valuesAndComparisonsRoundTrip() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        for r in 0..<5 { sheet[r, 0] = .text("r\(r)"); sheet[r, 1] = .integer(r) }
        sheet.autoFilter = CellRange("A1:B5")
        sheet.filterColumns = [
            FilterColumn(column: 0, values: ["r1", "r3"], includesBlanks: true),
            FilterColumn(column: 1, conditions: [FilterCondition(.greaterThan, "1"), FilterCondition(.lessThanOrEqual, "4")],
                         matchesAllConditions: true, buttonHidden: true),
        ]
        sheet.sortState = SortState(range: CellRange("A2:B5")!, conditions: [SortCondition(range: CellRange("B2:B5")!, descending: true)])
        wb.sheets[0] = sheet

        let xml = try Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx))
        #expect(xml.contains("<filterColumn colId=\"0\"><filters blank=\"1\"><filter val=\"r1\"/><filter val=\"r3\"/></filters></filterColumn>"))
        #expect(xml.contains("<filterColumn colId=\"1\" hiddenButton=\"1\"><customFilters and=\"1\"><customFilter operator=\"greaterThan\" val=\"1\"/><customFilter operator=\"lessThanOrEqual\" val=\"4\"/></customFilters></filterColumn>"))
        #expect(xml.contains("<sortState ref=\"A2:B5\"><sortCondition descending=\"1\" ref=\"B2:B5\"/></sortState>"))

        let again = try Workbook(data: try wb.data(as: .xlsx)).sheets[0]
        #expect(again.autoFilter == CellRange("A1:B5"))
        #expect(again.filterColumns == sheet.filterColumns)
        #expect(again.sortState == sheet.sortState)
        #expect(!again.hasUnmodelledFilters)
    }

    /// The kinds beyond a value list and comparisons — colour, icon, top 10, dynamic, whole months — are read into
    /// the model and written back from it.
    // openpyxl: worksheet/tests/test_filters.py::TestColorFilter::test_ctor
    // openpyxl: worksheet/tests/test_filters.py::TestColorFilter::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestIconFilter::test_ctor
    // openpyxl: worksheet/tests/test_filters.py::TestIconFilter::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestTop10::test_ctor
    // openpyxl: worksheet/tests/test_filters.py::TestTop10::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestDynamicFilter::test_ctor
    // openpyxl: worksheet/tests/test_filters.py::TestDynamicFilter::test_from_xml
    // openpyxl: worksheet/tests/test_filters.py::TestDateGroupItem::test_ctor
    // openpyxl: worksheet/tests/test_filters.py::TestDateGroupItem::test_from_xml
    @Test func theExoticFilterKindsRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:F9")
        wb.sheets[0].filterColumns = [
            FilterColumn(column: 0, colorFilter: ColorFilter(differentialStyleID: 0)),
            FilterColumn(column: 1, iconFilter: IconFilter(iconSet: "3TrafficLights1", iconID: 2)),
            FilterColumn(column: 2, top10: Top10Filter(count: 5, top: false, percent: true, boundary: 3)),
            FilterColumn(column: 3, dynamicFilter: DynamicFilter(kind: "aboveAverage", value: 2.5)),
            FilterColumn(column: 4, dateGroups: [DateGroup(grouping: .month, year: 2026, month: 3)], calendarType: "japan"),
            FilterColumn(column: 5, values: ["x"], buttonShown: false),
        ]
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("<colorFilter dxfId=\"0\"/>"))
        #expect(xml.contains("<iconFilter iconSet=\"3TrafficLights1\" iconId=\"2\"/>"))
        #expect(xml.contains("<top10 top=\"0\" percent=\"1\" val=\"5\" filterVal=\"3\"/>"))
        #expect(xml.contains("<dynamicFilter type=\"aboveAverage\" val=\"2.5\"/>"))
        #expect(xml.contains("<dateGroupItem year=\"2026\" month=\"3\" dateTimeGrouping=\"month\"/>"))
        #expect(xml.contains("calendarType=\"japan\"") && xml.contains("showButton=\"0\""))
        let again = try Workbook(data: data).sheets[0]
        #expect(!again.hasUnmodelledFilters)
        #expect(again.filterColumns == wb.sheets[0].filterColumns)
    }

    /// A column can filter only one way. Setting two says so instead of writing a file Excel offers to repair.
    @Test func twoKindsOnOneColumnAreReported() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:A5")
        wb.sheets[0].filterColumns = [FilterColumn(column: 0, values: ["x"], top10: Top10Filter(count: 3))]
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("one way") })
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: result.data)
        #expect(xml.contains("<filter val=\"x\"/>") && !xml.contains("<top10"))
    }

    /// The filter extensions Excel keeps in `<extLst>` are still beyond the model: such an `<autoFilter>` is written
    /// back as the file had it, because a half-understood filter would change which rows Excel shows.
    @Test func filterExtensionsAreKeptVerbatim() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:A5")
        let plain = try wb.data(as: .xlsx)
        let withExtension = try Package.repacking(plain, replacing: "xl/worksheets/sheet1.xml", with: Data(
            try Package.part("xl/worksheets/sheet1.xml", of: plain)
                .replacingOccurrences(of: "<autoFilter ref=\"A1:A5\"/>",
                                      with: "<autoFilter ref=\"A1:A5\"><extLst><ext uri=\"{XYZ}\"/></extLst></autoFilter>").utf8))

        let read = try Workbook(data: withExtension)
        #expect(read.sheets[0].hasUnmodelledFilters)
        #expect(read.sheets[0].autoFilter == CellRange("A1:A5"))
        let out = try Package.part("xl/worksheets/sheet1.xml", of: try read.data(as: .xlsx))
        #expect(out.contains("<ext uri=\"{XYZ}\"/>"))
        #expect(out.components(separatedBy: "<autoFilter").count == 2)   // exactly one, not one generated and one kept
    }

    /// ODS carries the range *and* what it lets through, as the filter of a database range.
    @Test func odsCarriesTheFilterConditions() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:B5")
        wb.sheets[0].filterColumns = [
            FilterColumn(column: 0, values: ["1"]),
            FilterColumn(column: 1, conditions: [FilterCondition(.greaterThan, "2")]),
        ]
        let result = try wb.write(as: .ods)
        #expect(!result.warnings.contains { $0.message.contains("auto-filter") })
        let read = try Workbook(data: result.data).sheets[0]
        #expect(read.autoFilter == CellRange("A1:B5"))
        #expect(read.filterColumns == wb.sheets[0].filterColumns)
    }

    /// A filter kind ODF has no word for is dropped, and the write says so.
    @Test func odsSaysItDropsAColourFilter() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:A5")
        var column = FilterColumn(column: 0)
        column.colorFilter = ColorFilter(differentialStyleID: 0)
        wb.sheets[0].filterColumns = [column]
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("colour, icon, dynamic") })
    }
}

/// docProps/custom.xml — the fields an organisation puts on a workbook beside author and title.
@Suite struct CustomDocumentPropertyTests {
    // openpyxl: packaging/tests/test_custom.py::TestCustomDocumentProperty::test_ctor
    // openpyxl: packaging/tests/test_custom.py::TestCustomDocumentProperty::test_from_xml
    // openpyxl: packaging/tests/test_custom.py::TestCustomDocumentProperyList::test_ctor
    // openpyxl: packaging/tests/test_custom.py::TestCustomDocumentProperyList::test_from_xml
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_string
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_int
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_float
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_bool
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_datetime
    // openpyxl: packaging/tests/test_custom.py::TestTypedPropertyList::test_link
    @Test func everyTypeRoundTripsThroughXLSX() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.customProperties = [
            CustomDocumentProperty(name: "管理番号", "A-1234"),
            CustomDocumentProperty(name: "改訂", 7),
            CustomDocumentProperty(name: "掛率", 0.85),
            CustomDocumentProperty(name: "社外秘", true),
            CustomDocumentProperty(name: "承認日", Date(timeIntervalSince1970: 1_780_000_000)),
            .linked(name: "担当", to: "Owner"),
        ]
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("docProps/custom.xml", of: data)
        #expect(xml.contains("<vt:lpwstr>A-1234</vt:lpwstr>"))
        #expect(xml.contains("<vt:i4>7</vt:i4>"))
        #expect(xml.contains("<vt:r8>0.85</vt:r8>"))
        #expect(xml.contains("<vt:bool>1</vt:bool>"))
        #expect(xml.contains("<vt:filetime>"))
        #expect(xml.contains("linkTarget=\"Owner\""))
        #expect(xml.contains("pid=\"2\"") && xml.contains("pid=\"7\""), "numbered from 2")

        let again = try Workbook(data: data)
        #expect(again.customProperties.names == wb.customProperties.names)
        #expect(again.customProperties["管理番号"] == .text("A-1234"))
        #expect(again.customProperties["改訂"] == .integer(7))
        #expect(again.customProperties["掛率"] == .number(0.85))
        #expect(again.customProperties["社外秘"] == .bool(true))
        #expect(again.customProperties["承認日"] == .date(Date(timeIntervalSince1970: 1_780_000_000)))
        #expect(again.customProperties["担当"] == .link("Owner"))
    }

    /// No properties, no part — and nothing in the content types or the package relationships pointing at one.
    @Test func noPropertiesNoPart() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        let data = try wb.data(as: .xlsx)
        #expect(!(try ZipArchive(data: data).entries.keys.contains("docProps/custom.xml")))
        #expect(try !Package.part("[Content_Types].xml", of: data).contains("custom.xml"))
        #expect(try !Package.part("_rels/.rels", of: data).contains("custom.xml"))
    }

    /// The part is written once — a file read with one and written back must not end up with two zip entries.
    @Test func aSourcePartIsReplacedRatherThanDoubled() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.customProperties = [CustomDocumentProperty(name: "管理番号", "A-1")]
        var again = try Workbook(data: try wb.data(as: .xlsx))
        again.customProperties["管理番号"] = .text("A-2")
        let data = try again.data(as: .xlsx)
        #expect(try ZipArchive(data: data).entries.keys.filter { $0 == "docProps/custom.xml" }.count == 1)
        #expect(try Package.part("docProps/custom.xml", of: data).contains("A-2"))
        let rels = try Package.part("_rels/.rels", of: data)
        #expect(rels.components(separatedBy: "docProps/custom.xml").count == 2)
    }

    /// ODF's own free-form fields say the same thing, so a conversion keeps them.
    @Test func odsKeepsThemAsUserDefinedMetadata() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.customProperties = [CustomDocumentProperty(name: "管理番号", "A-1234"),
                               CustomDocumentProperty(name: "改訂", 7),
                               CustomDocumentProperty(name: "社外秘", true)]
        let result = try wb.write(as: .ods)
        let again = try Workbook(data: result.data)
        #expect(again.customProperties["管理番号"] == .text("A-1234"))
        #expect(again.customProperties["改訂"] == .integer(7))
        #expect(again.customProperties["社外秘"] == .bool(true))
    }

    /// A linked property has no ODF equivalent; the substitution is reported rather than made in silence.
    @Test func odsReportsALinkedProperty() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.customProperties = [.linked(name: "担当", to: "Owner")]
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.kind == .substituted && $0.message.contains("担当") })
    }
}
