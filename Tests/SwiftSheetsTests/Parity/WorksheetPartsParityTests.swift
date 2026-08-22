import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

/// The worksheet XML SwiftSheets writes for `ws`, without the package around it (fresh style / string tables, no
/// preserved fragments, not the active tab — so the output matches a stand-alone sheet).
func sheetXML(_ ws: Sheet, epoch: DateEpoch = .windows1900) -> String {
    WorkbookWriter.sheetXML(ws, epoch: epoch, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, sink: WarningSink()).xml
}

/// Parses a worksheet XML document (or a fragment) into a fresh sheet with the production parser.
func parseSheet(_ xml: String, name: String = "Sheet", styles: StylesParser = StylesParser(), sst: [CellValue] = [], epoch: DateEpoch = .windows1900,
                dataOnly: Bool = false, rels: [Relationship] = []) throws -> Sheet {
    let doc = xml.contains("<worksheet") ? xml : "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(xml)</worksheet>"
    let p = SheetParser(name: name, sst: sst, styles: styles, epoch: epoch, dataOnly: dataOnly, rels: rels)
    try p.run(Data(doc.utf8), part: "sheet1.xml")
    return p.sheet
}

@Suite struct WorksheetDimensionsParityTests {
    // openpyxl: worksheet/tests/test_dimensions.py::test_dimension_interface
    @Test func dimensionInterface() {
        let d = RowDimension(hidden: true, outlineLevel: 1)
        #expect(d.hidden && d.outlineLevel == 1 && !d.collapsed && d.height == nil)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_repr
    @Test func repr() {
        let d = RowDimension(collapsed: true)
        #expect(d == RowDimension(hidden: false, outlineLevel: 0, collapsed: true) && !d.isDefault)
    }

    static let rowCases: [(RowDimension, String)] = [
        (RowDimension(height: 1), " ht=\"1\" customHeight=\"1\""), ({ var d = RowDimension(); d.thickBottom = true; return d }(), " thickBot=\"1\""), ({ var d = RowDimension(); d.thickTop = true; return d }(), " thickTop=\"1\""),
    ]
    // openpyxl: worksheet/tests/test_dimensions.py::test_row_dimension
    @Test(arguments: rowCases)
    func rowDimension(_ dim: RowDimension, _ attrs: String) {
        var ws = Workbook().sheets[0]
        ws.rowDimensions[0] = dim
        #expect(sheetXML(ws).contains("<row r=\"1\"\(attrs)>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_row_auto_assign
    @Test func rowAutoAssign() {
        let ws = Workbook().sheets[0]
        #expect(ws.rowDimension(0) == RowDimension())   // reading a missing row yields the defaults
    }

    // openpyxl: worksheet/tests/test_dimensions.py::TestRowDimension::test_copy
    @Test func rowCopy() {
        let rd1 = RowDimension(height: 2); var rd2 = rd1; rd2.height = 3
        #expect(rd1.height == 2 && rd2.height == 3)
    }

    static let colCases: [(ColumnDimension, String)] = [(ColumnDimension(width: 1), "<col min=\"1\" max=\"1\" width=\"1\" customWidth=\"1\"/>"), (ColumnDimension(bestFit: true), "<col min=\"1\" max=\"1\" bestFit=\"1\"/>")]
    // openpyxl: worksheet/tests/test_dimensions.py::test_col_dimensions
    @Test(arguments: colCases)
    func colDimensions(_ dim: ColumnDimension, _ xml: String) {
        var ws = Workbook().sheets[0]
        ws.columnDimensions[0] = dim
        #expect(sheetXML(ws).contains(xml))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_column_dimension
    @Test func columnDimension() {
        let ws = Workbook().sheets[0]
        #expect(ws.columnDimension("A") == ColumnDimension())
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_reindex
    @Test func colReindex() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("D") { $0.width = 13 }
        #expect(sheetXML(ws).contains("<col min=\"4\" max=\"4\" width=\"13\" customWidth=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_width
    @Test func colWidth() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("A") { $0.width = 4 }
        #expect(sheetXML(ws).contains("<cols><col min=\"1\" max=\"1\" width=\"4\" customWidth=\"1\"/></cols>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_style
    @Test func colStyle() {
        var ws = Workbook().sheets[0]
        var st = CellStyle(); st.font = Font(color: .rgb("FF0000"))
        ws.setColumnDimension("A") { $0.style = st; $0.width = 13 }
        #expect(sheetXML(ws).contains("<col min=\"1\" max=\"1\" width=\"13\" customWidth=\"1\" style=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_outline_cols
    @Test func outlineCols() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("B") { $0.outlineLevel = 1; $0.width = 13 }
        #expect(sheetXML(ws).contains("<col min=\"2\" max=\"2\" width=\"13\" customWidth=\"1\" outlineLevel=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::TestColDimension::test_copy
    @Test func colCopy() {
        let cd1 = ColumnDimension(width: 2); var cd2 = cd1; cd2.width = 3
        #expect(cd1.width == 2 && cd2.width == 3)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_empty_col
    @Test func emptyCol() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("C") { _ in }
        #expect(!sheetXML(ws).contains("<cols>"))   // default dimensions are not written
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_range
    @Test func range() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("C") { $0.outlineLevel = 1 }
        #expect(ws.columnGroups == ["C:C"])
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_columns_simple
    @Test func groupColumnsSimple() {
        var ws = Workbook().sheets[0]
        ws.groupColumns("A", "C", outlineLevel: 1)
        #expect(ws.columnGroups == ["A:C"] && ws.columnDimension("B").outlineLevel == 1)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_columns_collapse
    @Test func groupColumnsCollapse() {
        var ws = Workbook().sheets[0]
        ws.groupColumns("A", "C", outlineLevel: 1, hidden: true)
        #expect(ws.columnDimension("A").hidden)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_no_cols
    @Test func noCols() { #expect(!sheetXML(Workbook().sheets[0]).contains("<cols>")) }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_rows_simple
    @Test func groupRowsSimple() {
        var ws = Workbook().sheets[0]
        ws.groupRows(0...4, outlineLevel: 1)
        #expect(ws.rowDimensions.count == 5 && ws.rowDimension(0).outlineLevel == 1)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_rows_collapse
    @Test func groupRowsCollapse() {
        var ws = Workbook().sheets[0]
        ws.groupRows(0...9, outlineLevel: 1, hidden: true)
        #expect(ws.rowDimension(5).hidden)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_no_rows
    @Test func noRows() { #expect(sheetXML(Workbook().sheets[0]).contains("<sheetData></sheetData>")) }

    // openpyxl: worksheet/tests/test_dimensions.py::test_to_tree
    @Test func toTree() {
        var ws = Workbook().sheets[0]
        ws.setColumnDimension("A") { $0.width = 5 }; ws.setColumnDimension("D") { _ in }
        #expect(sheetXML(ws).contains("<cols>"))
    }
}

@Suite struct WorksheetMergeParityTests {
    static let thin = Side(style: .thin, color: .rgb("000000")), double = Side(style: .double, color: .rgb("000000")), thick = Side(style: .thick, color: .rgb("000000"))
    static var startBorder: Border { Border(left: thick, right: thin, top: thick, bottom: double) }

    // openpyxl: worksheet/tests/test_merge.py::TestMergeCell::test_ctor
    @Test func mergeCellCtor() {
        var ws = Workbook().sheets[0]
        ws.merge("A1")
        #expect(sheetXML(ws).contains("<mergeCells count=\"1\"><mergeCell ref=\"A1\"/></mergeCells>"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_from_xml
    @Test func mergeCellFromXML() throws {
        let ws = try parseSheet("<mergeCells><mergeCell ref='A1' /></mergeCells>")
        #expect(ws.merges == [CellRange("A1")!])
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergeCell::test_copy
    @Test func mergeCellCopy() {
        let a = CellRange("A1")!; let b = a
        #expect(a == b)
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergedCellRange::test_ctor
    @Test func mergedCellRangeCtor() {
        var ws = Workbook().sheets[0]
        ws.merge("A1:E4")
        #expect(ws.mergedRange(containing: CellRef("C2")!)?.topLeft.a1 == "A1")
    }

    // openpyxl: worksheet/tests/test_merge.py::test_get_borders
    @Test(arguments: ["C1", "A3", "C3"]) func getBorders(_ end: String) {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].border = Border(left: Self.thick, top: Self.thick)
        ws[cell: end].border = Border(right: Self.thin, bottom: Self.double)
        ws.merge("A1:" + end)
        #expect(ws[cell: "A1"].border == Self.startBorder)
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_1x3
    @Test func format1x3() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].border = Self.startBorder
        ws.merge("A1:C1")
        #expect(ws[cell: "B1"].border == Border(top: Self.thick, bottom: Self.double))
        #expect(ws[cell: "C1"].border == Border(right: Self.thin, top: Self.thick, bottom: Self.double))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_3x1
    @Test func format3x1() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].border = Self.startBorder
        ws.merge("A1:A3")
        #expect(ws[cell: "A2"].border == Border(left: Self.thick, right: Self.thin))
        #expect(ws[cell: "A3"].border == Border(left: Self.thick, right: Self.thin, bottom: Self.double))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_3x3
    @Test func format3x3() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].border = Self.startBorder
        ws.merge("A1:C3")
        let r = CellRange("A1:C3")!
        for ref in r.top { #expect(ws[cell: ref].border.top == Self.thick) }
        for ref in r.bottom { #expect(ws[cell: ref].border.bottom == Self.double) }
        for ref in r.left { #expect(ws[cell: ref].border.left == Self.thick) }
        for ref in r.right { #expect(ws[cell: ref].border.right == Self.thin) }
        #expect(ws[cell: "B2"].border == Border())
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_protection
    @Test func formatProtection() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].protection = Protection(locked: false, hidden: false)
        ws.merge("A1:C1")
        #expect(ws[cell: "B1"].protection == Protection(locked: false, hidden: false) && ws[cell: "C1"].protection == Protection(locked: false, hidden: false))
        ws[cell: "D1"].protection = Protection(locked: true, hidden: true)
        ws.merge("D1:F1")
        #expect(ws[cell: "E1"].protection == Protection(locked: true, hidden: true) && ws[cell: "F1"].protection == Protection(locked: true, hidden: true))
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergedCellRange::test_copy
    @Test func mergedCellRangeCopy() {
        var ws = Workbook().sheets[0]
        ws.merge("A1:J6")
        #expect(ws.merges == [CellRange("A1:J6")!])
    }

    // openpyxl: worksheet/tests/test_merge.py::test_contains
    @Test func contains() {
        var ws = Workbook().sheets[0]
        ws.merge("B2:M20")
        #expect(ws.isMerged("D4"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_not_contained
    @Test func notContained() {
        var ws = Workbook().sheets[0]
        ws.merge("B2:M20")
        #expect(!ws.isMerged("A1"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_empty_side
    @Test func emptySide() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].border = Border(bottom: Side(style: .thin))
        ws.merge("A1:C3")
        #expect(ws[cell: "C3"].border.bottom == Side(style: .thin))
    }
}

@Suite struct WorksheetHyperlinkParityTests {
    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlink::test_ctor
    @Test func ctor() {
        var ws = Workbook().sheets[0]
        ws[cell: "A1"].hyperlink = Hyperlink(target: "http://test.com", display: "Link elsewhere")
        #expect(sheetXML(ws).contains("<hyperlink ref=\"A1\" r:id=\"rId1\" display=\"Link elsewhere\"/>"))
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlink::test_from_xml
    @Test func fromXML() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "http://test.com", targetMode: "External")
        let ws = try parseSheet("<hyperlinks><hyperlink display=\"http://test.com\" r:id=\"rId1\" ref=\"A1\"/></hyperlinks>", rels: [rel])
        #expect(ws[cell: "A1"].hyperlink == Hyperlink(target: "http://test.com", display: "http://test.com"))
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlinkList::test_ctor
    @Test func listCtor() {
        #expect(!sheetXML(Workbook().sheets[0]).contains("<hyperlinks"))   // no links → no element
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlinkList::test_from_xml
    @Test func listFromXML() throws {
        let ws = try parseSheet("<hyperlinks />")
        #expect(ws.cells.values.allSatisfy { $0.hyperlink == nil })
    }
}

@Suite struct WorksheetPageParityTests {
    // openpyxl: worksheet/tests/test_page.py::TestPageMargins::test_ctor
    @Test func pageMarginsCtor() {
        let pm = PageMargins()
        #expect(pm.bottom == 1 && pm.footer == 0.5 && pm.header == 0.5 && pm.left == 0.75 && pm.right == 0.75 && pm.top == 1)
    }

    // openpyxl: worksheet/tests/test_page.py::TestPageMargins::test_write
    @Test func pageMarginsWrite() {
        var ws = Workbook().sheets[0]
        var pm = PageMargins(); pm.left = 2; pm.right = 2; pm.top = 2; pm.bottom = 2; pm.header = 1.5; pm.footer = 1.5
        ws.pageMargins = pm
        #expect(sheetXML(ws).contains("<pageMargins left=\"2\" right=\"2\" top=\"2\" bottom=\"2\" header=\"1.5\" footer=\"1.5\"/>"))
    }

    // openpyxl: worksheet/tests/test_page.py::TestPageSetup::test_ctor
    @Test func pageSetupCtor() {
        var p = PageSetup()
        #expect(p == PageSetup())
        p.scale = 1; p.orientation = .default
        #expect(p.scale == 1 && p.orientation == .default && p.paperSize == nil)
    }

    // openpyxl: worksheet/tests/test_page.py::test_fitToPage
    @Test func fitToPage() {
        var ws = Workbook().sheets[0]
        #expect(ws.properties.fitToPage == nil)
        ws.properties.fitToPage = true
        #expect(ws.properties.fitToPage == true && sheetXML(ws).contains("<pageSetUpPr fitToPage=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_page.py::TestPageSetup::test_write
    @Test func pageSetupWrite() {
        var ws = Workbook().sheets[0]
        var p = PageSetup(); p.orientation = .landscape; p.paperSize = 3; p.fitToHeight = 0; p.fitToWidth = 1
        ws.pageSetup = p
        #expect(sheetXML(ws).contains("<pageSetup orientation=\"landscape\" paperSize=\"3\" fitToWidth=\"1\" fitToHeight=\"0\"/>"))
    }

    // openpyxl: worksheet/tests/test_page.py::TestPrintOptions::test_ctor
    @Test func printOptionsCtor() {
        var p = PrintOptions()
        #expect(p == PrintOptions())
        p.horizontalCentered = true; p.verticalCentered = true
        #expect(p.horizontalCentered && p.verticalCentered)
    }

    // openpyxl: worksheet/tests/test_page.py::TestPrintOptions::test_write
    @Test func printOptionsWrite() {
        var ws = Workbook().sheets[0]
        ws.printOptions.horizontalCentered = true; ws.printOptions.verticalCentered = true
        #expect(sheetXML(ws).contains("<printOptions horizontalCentered=\"1\" verticalCentered=\"1\"/>"))
    }
}

@Suite struct WorksheetViewsParityTests {
    // openpyxl: worksheet/tests/test_views.py::test_show_gridlines
    @Test(arguments: [(true, "<sheetView workbookViewId=\"0\">"), (false, "<sheetView workbookViewId=\"0\" showGridLines=\"0\">")])
    func showGridlines(_ value: Bool, _ result: String) {
        var ws = Workbook().sheets[0]
        ws.view.showGridLines = value
        #expect(sheetXML(ws).contains(result))
    }

    // openpyxl: worksheet/tests/test_views.py::test_parse
    @Test func parse() throws {
        let ws = try parseSheet("""
        <sheetViews><sheetView tabSelected="1" zoomScale="200" zoomScaleNormal="200" zoomScalePageLayoutView="200" workbookViewId="0">
          <pane xSplit="5" ySplit="19" topLeftCell="F20" activePane="bottomRight" state="frozenSplit"/>
          <selection pane="topRight" activeCell="F1" sqref="F1"/>
          <selection pane="bottomLeft" activeCell="A20" sqref="A20"/>
          <selection pane="bottomRight" activeCell="E22" sqref="E22"/>
        </sheetView></sheetViews>
        """)
        #expect(ws.view.tabSelected && ws.view.zoomScale == 200 && ws.freezePanes?.a1 == "F20" && ws.view.activeCell == "E22")
    }

    // openpyxl: worksheet/tests/test_views.py::test_serialise
    @Test func serialise() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView>"))
    }

    // openpyxl: worksheet/tests/test_views.py::test_ctor
    @Test func sheetViewsCtor() {
        #expect(sheetXML(Workbook().sheets[0]).contains("<sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView></sheetViews>"))
    }

    // openpyxl: worksheet/tests/test_views.py::test_from_xml
    @Test func sheetViewsFromXML() throws {
        let ws = try parseSheet("<sheetViews />")
        #expect(ws.view == SheetView())
    }
}

@Suite struct WorksheetPropertiesParityTests {
    // openpyxl: worksheet/tests/test_properties.py::test_ctor
    @Test func ctor() {
        var p = SheetProperties(); p.tabColor = Color(hex: "F0F0F0")
        #expect(p.summaryBelow && p.summaryRight && p.tabColor == .rgb("FFF0F0F0"))
    }

    // openpyxl: worksheet/tests/test_properties.py::test_write_properties
    @Test func writeProperties() {
        var ws = Workbook().sheets[0]
        ws.properties.filterMode = false; ws.properties.tabColor = .rgb("FF123456"); ws.properties.fitToPage = false
        #expect(sheetXML(ws).contains("<sheetPr filterMode=\"0\"><tabColor rgb=\"FF123456\"/><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr fitToPage=\"0\"/></sheetPr>"))
    }

    // openpyxl: worksheet/tests/test_properties.py::test_parse_properties
    @Test func parseProperties() throws {
        let ws = try parseSheet(try openpyxlFixtureText("worksheet/sheetPr2.xml"))
        #expect(ws.properties.filterMode == false && ws.properties.tabColor == .rgb("FF123456") && ws.properties.fitToPage == false)
    }
}

@Suite struct WorksheetPrintSettingsParityTests {
    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_from_string
    @Test func colRangeFromString() {
        var ws = Workbook().sheets[0]
        ws.setPrintTitleColumns("$B:$E")
        #expect(ws.printTitleColumns == 1...4)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_str
    @Test func colRangeStr() {
        var ws = Workbook().sheets[0]
        ws.printTitleColumns = 0...3
        #expect(ws.printTitles == "'Sheet1'!$A:$D")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_eq
    @Test(arguments: ["$B:$E", "B:E"]) func colRangeEq(_ expected: String) {
        var ws = Workbook().sheets[0]
        ws.setPrintTitleColumns(expected)
        #expect(ws.printTitleColumns == 1...4)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_from_string
    @Test func rowRangeFromString() {
        var ws = Workbook().sheets[0]
        ws.setPrintTitleRows("$2:$6")
        #expect(ws.printTitleRows == 1...5)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_str
    @Test func rowRangeStr() {
        var ws = Workbook().sheets[0]
        ws.printTitleRows = 0...3
        #expect(ws.printTitles == "'Sheet1'!$1:$4")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_eq
    @Test(arguments: ["$2:$7", "2:7"]) func rowRangeEq(_ expected: String) {
        var ws = Workbook().sheets[0]
        ws.setPrintTitleRows(expected)
        #expect(ws.printTitleRows == 1...6)
    }

    static let titleCases: [(String, String)] = [
        ("'Sheet1'!$1:$2,$A:$A", "'Sheet1'!$1:$2,'Sheet1'!$A:$A"), ("'Sheet 1'!$A:$A", "'Sheet 1'!$A:$A"), ("Sheet1!$5:$17", "'Sheet1'!$5:$17"),
        ("Tabelle1!$J:$J,Tabelle1!$10:$10", "'Tabelle1'!$10:$10,'Tabelle1'!$J:$J"),
    ]
    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintTitles::test_from_string
    @Test(arguments: titleCases)
    func printTitlesFromString(_ value: String, _ expected: String) {
        var wb = Workbook()
        wb.sheets[0].name = CellRange.splitSheetName(value.split(separator: ",").map(String.init)[0])!.sheet
        wb.sheets[0].setPrintTitles(value)
        #expect(wb.sheets[0].printTitles == expected)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintTitles::test_eq
    @Test func printTitlesEq() {
        var wb = Workbook()
        wb.sheets[0].name = "Sheet 1"; wb.sheets[0].setPrintTitles("'Sheet 1'!$A:$A")
        #expect(wb.sheets[0].printTitles == "'Sheet 1'!$A:$A")
    }

    static let areaCases: [(String, Set<CellRange>)] = [
        ("Sheet1!$A$1:$E$15", [CellRange("A1:E15")!]), ("$A$1:$E$15", [CellRange("A1:E15")!]),
        ("'Blatt1'!$A$1:$F$14,'Blatt1'!$H$10:$I$17,Blatt1!$I$16:$K$25", [CellRange("A1:F14")!, CellRange("H10:I17")!, CellRange("I16:K25")!]),
        ("MySheet!#REF!", []), ("'C,D'!$A$1:$B$3", [CellRange("A1:B3")!]), ("Sheet!$A$1:$D$5,Sheet!$B$9:$F$14", [CellRange("A1:D5")!, CellRange("B9:F14")!]),
    ]
    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_from_string
    @Test(arguments: areaCases)
    func printAreaFromString(_ value: String, _ expected: Set<CellRange>) {
        var ws = Workbook().sheets[0]
        ws.setPrintArea(value)
        #expect(Set(ws.printArea) == expected)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::test_empty
    @Test func printAreaEmpty() {
        let ws = Workbook().sheets[0]
        #expect(ws.printArea.isEmpty && ws.printAreaFormula == "")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_str
    @Test func printAreaStr() {
        var ws = Workbook().sheets[0]
        ws.setPrintArea("Sheet!$A$1:$D$5,Sheet!$B$9:$F$14")
        #expect(ws.printAreaFormula == "'Sheet1'!$A$1:$D$5,'Sheet1'!$B$9:$F$14")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_eq
    @Test func printAreaEq() {
        var ws = Workbook().sheets[0]
        ws.setPrintArea("Sheet1!$A$1:$E$15")
        #expect(ws.printAreaFormula == "'Sheet1'!$A$1:$E$15")
    }
}

@Suite struct WorksheetCopyParityTests {
    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_ctor
    @Test func ctor() {
        // PORT-NOTE: sheets are values without a workbook back-reference, so `ws2.workbook === wb && ws2 !== ws1`
        // becomes "the copy is a distinct sheet that lives in the workbook": a new index and a name of its own.
        var wb = Workbook()
        let i = wb.addSheet()
        let j = wb.duplicateSheet(named: wb.sheets[i].name)
        #expect(j != nil && j != i && wb.sheets.contains("Sheet Copy"))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_merged_cell_copy
    @Test func mergedCellCopy() {
        var wb = Workbook()
        wb.sheets[0].merge("A10:A11"); wb.sheets[0].merge("F20:J23")
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].merges == wb.sheets[0].merges)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_value
    @Test func cellCopyValue() {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 4
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j]["A1"] == .integer(4))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_style
    @Test func cellCopyStyle() {
        var wb = Workbook()
        wb.sheets[0][cell: "A1"].font = Font(bold: true)
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j][cell: "A1"].font == Font(bold: true))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_comment
    @Test func cellCopyComment() {
        var wb = Workbook()
        wb.sheets[0][cell: "A1"].comment = CellNote("A Comment", author: "Nobody")
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j][cell: "A1"].comment == CellNote("A Comment", author: "Nobody"))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_hyperlink
    @Test func cellCopyHyperlink() {
        var wb = Workbook()
        wb.sheets[0][cell: "A1"].hyperlink = Hyperlink(target: "http://www.example.com")
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j][cell: "A1"].hyperlink?.target == "http://www.example.com")
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_row_dimensions
    @Test func copyRowDimensions() {
        var wb = Workbook()
        wb.sheets[0].setRowDimension(3) { $0.height = 25 }
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].rowDimension(3).height == 25)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_col_dimensions
    @Test func copyColDimensions() {
        var wb = Workbook()
        wb.sheets[0].setColumnDimension("D") { $0.width = 25 }
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].columnDimension("D").width == 25)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_page_margins
    @Test func copyPageMargins() {
        var wb = Workbook()
        wb.sheets[0].pageMargins.top = 3
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].pageMargins.top == 3)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_page_setup
    @Test func copyPageSetup() {
        var wb = Workbook()
        wb.sheets[0].pageSetup.orientation = .landscape
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].pageSetup == wb.sheets[0].pageSetup)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_print_options
    @Test func copyPrintOptions() {
        var wb = Workbook()
        wb.sheets[0].printOptions.horizontalCentered = true
        let j = wb.duplicateSheet(named: "Sheet1")!
        #expect(wb.sheets[j].printOptions.horizontalCentered)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_worksheet
    @Test func copyWorksheet() throws {
        var wb = try XLSXCodec.read(try openpyxlFixture("worksheet/copy_test.xlsx"))
        let ws1 = wb.sheets["original_sheet"]!
        let ws2 = wb.sheets[wb.duplicateSheet(named: "original_sheet")!]
        // PORT-NOTE: `column("A")` now yields values, so the cells of column A are fetched by reference to compare their parts.
        for r in 0..<ws1.rowCount {
            let ref = CellRef(row: r, col: 0)
            let c1 = ws1.cell(at: ref), c2 = ws2.cell(at: ref)
            #expect(c1?.value == c2?.value && c1?.dataType == c2?.dataType && c1?.comment == c2?.comment && c1?.hyperlink == c2?.hyperlink && c1?.style == c2?.style)
        }
        #expect(ws1.cells.count == ws2.cells.count)
    }
}
