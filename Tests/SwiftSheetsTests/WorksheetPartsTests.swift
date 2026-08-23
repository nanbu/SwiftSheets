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

    /// A filter kind the model does not carry keeps the file's own XML — a half-understood filter would change
    /// which rows Excel shows.
    // openpyxl: worksheet/tests/test_filters.py::TestColorFilter::test_from_xml
    @Test func exoticFilterKindsAreKeptVerbatim() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:A5")
        let plain = try wb.data(as: .xlsx)
        let withColour = try Package.repacking(plain, replacing: "xl/worksheets/sheet1.xml", with: Data(
            try Package.part("xl/worksheets/sheet1.xml", of: plain)
                .replacingOccurrences(of: "<autoFilter ref=\"A1:A5\"/>",
                                      with: "<autoFilter ref=\"A1:A5\"><filterColumn colId=\"0\"><colorFilter dxfId=\"0\"/></filterColumn></autoFilter>").utf8))

        let read = try Workbook(data: withColour)
        #expect(read.sheets[0].hasUnmodelledFilters)
        #expect(read.sheets[0].autoFilter == CellRange("A1:A5"))
        let out = try Package.part("xl/worksheets/sheet1.xml", of: try read.data(as: .xlsx))
        #expect(out.contains("<colorFilter dxfId=\"0\"/>"))
        #expect(out.components(separatedBy: "<autoFilter").count == 2)   // exactly one, not one generated and one kept
    }

    /// ODS writes the range but not what it lets through, and says so.
    @Test func odsSaysItDropsTheConditions() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].autoFilter = CellRange("A1:A5")
        wb.sheets[0].filterColumns = [FilterColumn(column: 0, values: ["1"])]
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.message.contains("auto-filter conditions") })
        #expect(try Workbook(data: result.data).sheets[0].autoFilter == CellRange("A1:A5"))
    }
}
