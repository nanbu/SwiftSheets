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
