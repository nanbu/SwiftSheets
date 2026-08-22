import Foundation
import Testing
@testable import SwiftSheets

/// The worksheet XML SwiftSheets writes for `ws`, without the package around it.
func sheetXML(_ ws: Worksheet) -> String {
    WorkbookWriter.sheetXML(ws, epoch: ws.workbook?.epoch ?? .windows1900, styles: StyleRegistry(), strings: SharedStringTable()).xml
}

/// Parses a worksheet XML document (or a fragment) into a fresh sheet with the production parser.
func parseSheet(_ xml: String, styles: StylesParser = StylesParser(), sst: [CellValue] = [], epoch: DateEpoch = .windows1900, dataOnly: Bool = false,
                rels: [Relationship] = [], into wb: Workbook = Workbook()) throws -> Worksheet {
    let ws = Worksheet(title: "Sheet", workbook: wb)
    let doc = xml.contains("<worksheet") ? xml : "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\(xml)</worksheet>"
    try SheetParser(ws: ws, sst: sst, styles: styles, epoch: epoch, dataOnly: dataOnly, rels: rels).run(Data(doc.utf8), part: "sheet1.xml")
    return ws
}

@Suite struct WorksheetDimensionsParityTests {
    let wb = Workbook()

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
        wb.active.rowDimensions[1] = dim
        #expect(sheetXML(wb.active).contains("<row r=\"1\"\(attrs)>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_row_auto_assign
    @Test func rowAutoAssign() {
        #expect(wb.active.rowDimension(1) == RowDimension())   // reading a missing row yields the defaults
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
        wb.active.columnDimensions["A"] = dim
        #expect(sheetXML(wb.active).contains(xml))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_column_dimension
    @Test func columnDimension() {
        #expect(wb.active.columnDimension("A") == ColumnDimension())
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_reindex
    @Test func colReindex() {
        wb.active.setColumnDimension("D") { $0.width = 13 }
        #expect(sheetXML(wb.active).contains("<col min=\"4\" max=\"4\" width=\"13\" customWidth=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_width
    @Test func colWidth() {
        wb.active.setColumnDimension("A") { $0.width = 4 }
        #expect(sheetXML(wb.active).contains("<cols><col min=\"1\" max=\"1\" width=\"4\" customWidth=\"1\"/></cols>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_col_style
    @Test func colStyle() {
        var st = CellStyle(); st.font = Font(color: .rgb("FF0000"))
        wb.active.setColumnDimension("A") { $0.style = st; $0.width = 13 }
        #expect(sheetXML(wb.active).contains("<col min=\"1\" max=\"1\" width=\"13\" customWidth=\"1\" style=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_outline_cols
    @Test func outlineCols() {
        wb.active.setColumnDimension("B") { $0.outlineLevel = 1; $0.width = 13 }
        #expect(sheetXML(wb.active).contains("<col min=\"2\" max=\"2\" width=\"13\" customWidth=\"1\" outlineLevel=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_dimensions.py::TestColDimension::test_copy
    @Test func colCopy() {
        let cd1 = ColumnDimension(width: 2); var cd2 = cd1; cd2.width = 3
        #expect(cd1.width == 2 && cd2.width == 3)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_empty_col
    @Test func emptyCol() {
        wb.active.setColumnDimension("C") { _ in }
        #expect(!sheetXML(wb.active).contains("<cols>"))   // default dimensions are not written
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_range
    @Test func range() {
        wb.active.setColumnDimension("C") { $0.outlineLevel = 1 }
        #expect(wb.active.columnGroups == ["C:C"])
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_columns_simple
    @Test func groupColumnsSimple() {
        wb.active.groupColumns("A", "C", outlineLevel: 1)
        #expect(wb.active.columnGroups == ["A:C"] && wb.active.columnDimension("B").outlineLevel == 1)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_columns_collapse
    @Test func groupColumnsCollapse() {
        wb.active.groupColumns("A", "C", outlineLevel: 1, hidden: true)
        #expect(wb.active.columnDimension("A").hidden)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_no_cols
    @Test func noCols() { #expect(!sheetXML(wb.active).contains("<cols>")) }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_rows_simple
    @Test func groupRowsSimple() {
        wb.active.groupRows(1, 5, outlineLevel: 1)
        #expect(wb.active.rowDimensions.count == 5 && wb.active.rowDimension(1).outlineLevel == 1)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_group_rows_collapse
    @Test func groupRowsCollapse() {
        wb.active.groupRows(1, 10, outlineLevel: 1, hidden: true)
        #expect(wb.active.rowDimension(6).hidden)
    }

    // openpyxl: worksheet/tests/test_dimensions.py::test_no_rows
    @Test func noRows() { #expect(sheetXML(wb.active).contains("<sheetData></sheetData>")) }

    // openpyxl: worksheet/tests/test_dimensions.py::test_to_tree
    @Test func toTree() {
        wb.active.setColumnDimension("A") { $0.width = 5 }; wb.active.setColumnDimension("D") { _ in }
        #expect(sheetXML(wb.active).contains("<cols>"))
    }
}

@Suite struct WorksheetMergeParityTests {
    let wb = Workbook()
    var ws: Worksheet { wb.active }
    static let thin = Side(style: .thin, color: .rgb("000000")), double = Side(style: .double, color: .rgb("000000")), thick = Side(style: .thick, color: .rgb("000000"))
    static var startBorder: Border { Border(left: thick, right: thin, top: thick, bottom: double) }

    // openpyxl: worksheet/tests/test_merge.py::TestMergeCell::test_ctor
    @Test func mergeCellCtor() {
        ws.mergeCells("A1")
        #expect(sheetXML(ws).contains("<mergeCells count=\"1\"><mergeCell ref=\"A1\"/></mergeCells>"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_from_xml
    @Test func mergeCellFromXML() throws {
        let ws = try parseSheet("<mergeCells><mergeCell ref='A1' /></mergeCells>")
        #expect(ws.mergedCells == [CellRange("A1")!])
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergeCell::test_copy
    @Test func mergeCellCopy() {
        let a = CellRange("A1")!; let b = a
        #expect(a == b)
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergedCellRange::test_ctor
    @Test func mergedCellRangeCtor() {
        ws.mergeCells("A1:E4")
        #expect(ws.mergedRange(containing: CellReference("C2")!)?.topLeft.description == "A1")
    }

    // openpyxl: worksheet/tests/test_merge.py::test_get_borders
    @Test(arguments: ["C1", "A3", "C3"]) func getBorders(_ end: String) {
        ws["A1"].border = Border(left: Self.thick, top: Self.thick)
        ws[end].border = Border(right: Self.thin, bottom: Self.double)
        ws.mergeCells("A1:" + end)
        #expect(ws["A1"].border == Self.startBorder)
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_1x3
    @Test func format1x3() {
        ws["A1"].border = Self.startBorder
        ws.mergeCells("A1:C1")
        #expect(ws["B1"].border == Border(top: Self.thick, bottom: Self.double))
        #expect(ws["C1"].border == Border(right: Self.thin, top: Self.thick, bottom: Self.double))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_3x1
    @Test func format3x1() {
        ws["A1"].border = Self.startBorder
        ws.mergeCells("A1:A3")
        #expect(ws["A2"].border == Border(left: Self.thick, right: Self.thin))
        #expect(ws["A3"].border == Border(left: Self.thick, right: Self.thin, bottom: Self.double))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_3x3
    @Test func format3x3() {
        ws["A1"].border = Self.startBorder
        ws.mergeCells("A1:C3")
        let r = CellRange("A1:C3")!
        for ref in r.top { #expect(ws[ref].border.top == Self.thick) }
        for ref in r.bottom { #expect(ws[ref].border.bottom == Self.double) }
        for ref in r.left { #expect(ws[ref].border.left == Self.thick) }
        for ref in r.right { #expect(ws[ref].border.right == Self.thin) }
        #expect(ws["B2"].border == Border())
    }

    // openpyxl: worksheet/tests/test_merge.py::test_format_protection
    @Test func formatProtection() {
        ws["A1"].protection = Protection(locked: false, hidden: false)
        ws.mergeCells("A1:C1")
        #expect(ws["B1"].protection == Protection(locked: false, hidden: false) && ws["C1"].protection == Protection(locked: false, hidden: false))
        ws["D1"].protection = Protection(locked: true, hidden: true)
        ws.mergeCells("D1:F1")
        #expect(ws["E1"].protection == Protection(locked: true, hidden: true) && ws["F1"].protection == Protection(locked: true, hidden: true))
    }

    // openpyxl: worksheet/tests/test_merge.py::TestMergedCellRange::test_copy
    @Test func mergedCellRangeCopy() {
        ws.mergeCells("A1:J6")
        #expect(ws.mergedCells == [CellRange("A1:J6")!])
    }

    // openpyxl: worksheet/tests/test_merge.py::test_contains
    @Test func contains() {
        ws.mergeCells("B2:M20")
        #expect(ws.isMerged("D4"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_not_contained
    @Test func notContained() {
        ws.mergeCells("B2:M20")
        #expect(!ws.isMerged("A1"))
    }

    // openpyxl: worksheet/tests/test_merge.py::test_empty_side
    @Test func emptySide() {
        ws["A1"].border = Border(bottom: Side(style: .thin))
        ws.mergeCells("A1:C3")
        #expect(ws["C3"].border.bottom == Side(style: .thin))
    }
}

@Suite struct WorksheetHyperlinkParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlink::test_ctor
    @Test func ctor() {
        wb.active["A1"].hyperlink = Hyperlink(target: "http://test.com", display: "Link elsewhere")
        #expect(sheetXML(wb.active).contains("<hyperlink ref=\"A1\" r:id=\"rId1\" display=\"Link elsewhere\"/>"))
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlink::test_from_xml
    @Test func fromXML() throws {
        let rel = Relationship(id: "rId1", type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", target: "http://test.com", mode: "External")
        let ws = try parseSheet("<hyperlinks><hyperlink display=\"http://test.com\" r:id=\"rId1\" ref=\"A1\"/></hyperlinks>", rels: [rel], into: wb)
        #expect(ws["A1"].hyperlink == Hyperlink(target: "http://test.com", display: "http://test.com"))
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlinkList::test_ctor
    @Test func listCtor() {
        #expect(!sheetXML(wb.active).contains("<hyperlinks"))   // no links → no element
    }

    // openpyxl: worksheet/tests/test_hyperlink.py::TestHyperlinkList::test_from_xml
    @Test func listFromXML() throws {
        let ws = try parseSheet("<hyperlinks />", into: wb)
        #expect(ws.cells.values.allSatisfy { $0.hyperlink == nil })
    }
}

@Suite struct WorksheetPageParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_page.py::TestPageMargins::test_ctor
    @Test func pageMarginsCtor() {
        let pm = PageMargins()
        #expect(pm.bottom == 1 && pm.footer == 0.5 && pm.header == 0.5 && pm.left == 0.75 && pm.right == 0.75 && pm.top == 1)
    }

    // openpyxl: worksheet/tests/test_page.py::TestPageMargins::test_write
    @Test func pageMarginsWrite() {
        var pm = PageMargins(); pm.left = 2; pm.right = 2; pm.top = 2; pm.bottom = 2; pm.header = 1.5; pm.footer = 1.5
        wb.active.pageMargins = pm
        #expect(sheetXML(wb.active).contains("<pageMargins left=\"2\" right=\"2\" top=\"2\" bottom=\"2\" header=\"1.5\" footer=\"1.5\"/>"))
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
        let ws = wb.active
        #expect(ws.properties.fitToPage == nil)
        ws.properties.fitToPage = true
        #expect(ws.properties.fitToPage == true && sheetXML(ws).contains("<pageSetUpPr fitToPage=\"1\"/>"))
    }

    // openpyxl: worksheet/tests/test_page.py::TestPageSetup::test_write
    @Test func pageSetupWrite() {
        var p = PageSetup(); p.orientation = .landscape; p.paperSize = 3; p.fitToHeight = 0; p.fitToWidth = 1
        wb.active.pageSetup = p
        #expect(sheetXML(wb.active).contains("<pageSetup orientation=\"landscape\" paperSize=\"3\" fitToWidth=\"1\" fitToHeight=\"0\"/>"))
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
        wb.active.printOptions.horizontalCentered = true; wb.active.printOptions.verticalCentered = true
        #expect(sheetXML(wb.active).contains("<printOptions horizontalCentered=\"1\" verticalCentered=\"1\"/>"))
    }
}

@Suite struct WorksheetViewsParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_views.py::test_show_gridlines
    @Test(arguments: [(true, "<sheetView workbookViewId=\"0\">"), (false, "<sheetView workbookViewId=\"0\" showGridLines=\"0\">")])
    func showGridlines(_ value: Bool, _ result: String) {
        wb.active.view.showGridLines = value
        #expect(sheetXML(wb.active).contains(result))
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
        """, into: wb)
        #expect(ws.view.tabSelected && ws.view.zoomScale == 200 && ws.freezePanes?.description == "F20" && ws.view.activeCell == "E22")
    }

    // openpyxl: worksheet/tests/test_views.py::test_serialise
    @Test func serialise() {
        #expect(sheetXML(wb.active).contains("<sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView>"))
    }

    // openpyxl: worksheet/tests/test_views.py::test_ctor
    @Test func sheetViewsCtor() {
        #expect(sheetXML(wb.active).contains("<sheetViews><sheetView workbookViewId=\"0\"><selection activeCell=\"A1\" sqref=\"A1\"/></sheetView></sheetViews>"))
    }

    // openpyxl: worksheet/tests/test_views.py::test_from_xml
    @Test func sheetViewsFromXML() throws {
        let ws = try parseSheet("<sheetViews />", into: wb)
        #expect(ws.view == SheetView())
    }
}

@Suite struct WorksheetPropertiesParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_properties.py::test_ctor
    @Test func ctor() {
        var p = SheetProperties(); p.tabColor = Color(hex: "F0F0F0")
        #expect(p.summaryBelow && p.summaryRight && p.tabColor == .rgb("FFF0F0F0"))
    }

    // openpyxl: worksheet/tests/test_properties.py::test_write_properties
    @Test func writeProperties() {
        wb.active.properties.filterMode = false; wb.active.properties.tabColor = .rgb("FF123456"); wb.active.properties.fitToPage = false
        #expect(sheetXML(wb.active).contains("<sheetPr filterMode=\"0\"><tabColor rgb=\"FF123456\"/><outlinePr summaryBelow=\"1\" summaryRight=\"1\"/><pageSetUpPr fitToPage=\"0\"/></sheetPr>"))
    }

    // openpyxl: worksheet/tests/test_properties.py::test_parse_properties
    @Test func parseProperties() throws {
        let ws = try parseSheet(try openpyxlFixtureText("worksheet/sheetPr2.xml"), into: wb)
        #expect(ws.properties.filterMode == false && ws.properties.tabColor == .rgb("FF123456") && ws.properties.fitToPage == false)
    }
}

@Suite struct WorksheetPrintSettingsParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_from_string
    @Test func colRangeFromString() {
        wb.active.setPrintTitleColumns("$B:$E")
        #expect(wb.active.printTitleColumns == 2...5)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_str
    @Test func colRangeStr() {
        wb.active.printTitleColumns = 1...4
        #expect(wb.active.printTitles == "'Sheet'!$A:$D")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestColRange::test_eq
    @Test(arguments: ["$B:$E", "B:E"]) func colRangeEq(_ expected: String) {
        wb.active.setPrintTitleColumns(expected)
        #expect(wb.active.printTitleColumns == 2...5)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_from_string
    @Test func rowRangeFromString() {
        wb.active.setPrintTitleRows("$2:$6")
        #expect(wb.active.printTitleRows == 2...6)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_str
    @Test func rowRangeStr() {
        wb.active.printTitleRows = 1...4
        #expect(wb.active.printTitles == "'Sheet'!$1:$4")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestRowRange::test_eq
    @Test(arguments: ["$2:$7", "2:7"]) func rowRangeEq(_ expected: String) {
        wb.active.setPrintTitleRows(expected)
        #expect(wb.active.printTitleRows == 2...7)
    }

    static let titleCases: [(String, String)] = [
        ("'Sheet1'!$1:$2,$A:$A", "'Sheet1'!$1:$2,'Sheet1'!$A:$A"), ("'Sheet 1'!$A:$A", "'Sheet 1'!$A:$A"), ("Sheet1!$5:$17", "'Sheet1'!$5:$17"),
        ("Tabelle1!$J:$J,Tabelle1!$10:$10", "'Tabelle1'!$10:$10,'Tabelle1'!$J:$J"),
    ]
    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintTitles::test_from_string
    @Test(arguments: titleCases)
    func printTitlesFromString(_ value: String, _ expected: String) {
        let ws = wb.active
        ws.title = CellRange.splitSheetTitle(value.split(separator: ",").map(String.init)[0])!.title
        ws.setPrintTitles(value)
        #expect(ws.printTitles == expected)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintTitles::test_eq
    @Test func printTitlesEq() {
        wb.active.title = "Sheet 1"; wb.active.setPrintTitles("'Sheet 1'!$A:$A")
        #expect(wb.active.printTitles == "'Sheet 1'!$A:$A")
    }

    static let areaCases: [(String, Set<CellRange>)] = [
        ("Sheet1!$A$1:$E$15", [CellRange("A1:E15")!]), ("$A$1:$E$15", [CellRange("A1:E15")!]),
        ("'Blatt1'!$A$1:$F$14,'Blatt1'!$H$10:$I$17,Blatt1!$I$16:$K$25", [CellRange("A1:F14")!, CellRange("H10:I17")!, CellRange("I16:K25")!]),
        ("MySheet!#REF!", []), ("'C,D'!$A$1:$B$3", [CellRange("A1:B3")!]), ("Sheet!$A$1:$D$5,Sheet!$B$9:$F$14", [CellRange("A1:D5")!, CellRange("B9:F14")!]),
    ]
    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_from_string
    @Test(arguments: areaCases)
    func printAreaFromString(_ value: String, _ expected: Set<CellRange>) {
        wb.active.setPrintArea(value)
        #expect(Set(wb.active.printArea) == expected)
    }

    // openpyxl: worksheet/tests/test_print_settings.py::test_empty
    @Test func printAreaEmpty() { #expect(wb.active.printArea.isEmpty && wb.active.printAreaFormula == "") }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_str
    @Test func printAreaStr() {
        wb.active.setPrintArea("Sheet!$A$1:$D$5,Sheet!$B$9:$F$14")
        #expect(wb.active.printAreaFormula == "'Sheet'!$A$1:$D$5,'Sheet'!$B$9:$F$14")
    }

    // openpyxl: worksheet/tests/test_print_settings.py::TestPrintArea::test_eq
    @Test func printAreaEq() {
        wb.active.setPrintArea("Sheet1!$A$1:$E$15")
        #expect(wb.active.printAreaFormula == "'Sheet'!$A$1:$E$15")
    }
}

@Suite struct WorksheetCopyParityTests {
    let wb = Workbook()

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_ctor
    @Test func ctor() {
        let ws1 = wb.createSheet()
        let ws2 = wb.copyWorksheet(ws1)
        #expect(ws2.workbook === wb && ws2 !== ws1)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_merged_cell_copy
    @Test func mergedCellCopy() {
        let ws1 = wb.active
        ws1.mergeCells("A10:A11"); ws1.mergeCells("F20:J23")
        #expect(wb.copyWorksheet(ws1).mergedCells == ws1.mergedCells)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_value
    @Test func cellCopyValue() {
        wb.active["A1"].value = 4
        #expect(wb.copyWorksheet(wb.active)["A1"].value == .integer(4))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_style
    @Test func cellCopyStyle() {
        wb.active["A1"].font = Font(bold: true)
        #expect(wb.copyWorksheet(wb.active)["A1"].font == Font(bold: true))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_comment
    @Test func cellCopyComment() {
        wb.active["A1"].comment = Comment("A Comment", author: "Nobody")
        #expect(wb.copyWorksheet(wb.active)["A1"].comment == Comment("A Comment", author: "Nobody"))
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_cell_copy_hyperlink
    @Test func cellCopyHyperlink() {
        wb.active["A1"].hyperlink = Hyperlink(target: "http://www.example.com")
        #expect(wb.copyWorksheet(wb.active)["A1"].hyperlink?.target == "http://www.example.com")
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_row_dimensions
    @Test func copyRowDimensions() {
        wb.active.setRowDimension(4) { $0.height = 25 }
        #expect(wb.copyWorksheet(wb.active).rowDimension(4).height == 25)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_col_dimensions
    @Test func copyColDimensions() {
        wb.active.setColumnDimension("D") { $0.width = 25 }
        #expect(wb.copyWorksheet(wb.active).columnDimension("D").width == 25)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_page_margins
    @Test func copyPageMargins() {
        wb.active.pageMargins.top = 3
        #expect(wb.copyWorksheet(wb.active).pageMargins.top == 3)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_page_setup
    @Test func copyPageSetup() {
        wb.active.pageSetup.orientation = .landscape
        #expect(wb.copyWorksheet(wb.active).pageSetup == wb.active.pageSetup)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_print_options
    @Test func copyPrintOptions() {
        wb.active.printOptions.horizontalCentered = true
        #expect(wb.copyWorksheet(wb.active).printOptions.horizontalCentered)
    }

    // openpyxl: worksheet/tests/test_worksheet_copy.py::test_copy_worksheet
    @Test func copyWorksheet() throws {
        let wb = try Workbook(data: try openpyxlFixture("worksheet/copy_test.xlsx"))
        let ws1 = wb["original_sheet"]!
        let ws2 = wb.copyWorksheet(ws1)
        for (c1, c2) in zip(ws1.column("A"), ws2.column("A")) {
            #expect(c1.value == c2.value && c1.dataType == c2.dataType && c1.comment == c2.comment && c1.hyperlink == c2.hyperlink && c1.style == c2.style)
        }
        #expect(ws1.cells.count == ws2.cells.count)
    }
}
