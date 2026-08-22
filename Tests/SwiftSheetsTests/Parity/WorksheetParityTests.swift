import Foundation
import Testing
@testable import SwiftSheets

@Suite struct WorksheetParityTests {
    let wb = Workbook()
    var ws: Worksheet { wb.active }

    /// openpyxl's `dummy_worksheet`: A1:H6 filled with each cell's own coordinate.
    func dummyWorksheet() -> Worksheet {
        for row in ws.rows(minRow: 1, maxRow: 6, minColumn: 1, maxColumn: 8) { for c in row { c.value = .string(c.coordinate) } }
        return ws
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_new_worksheet
    @Test func newWorksheet() {
        #expect(wb.createSheet().workbook === wb)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_cell
    @Test func getCell() {
        #expect(ws.cell(row: 1, column: 1).coordinate == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_invalid_cell
    @Test func invalidCell() {
        #expect(CellReference("A0") == nil && CellReference(column: 0, row: 0).description == "0")   // row / column 0 are not addressable
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_worksheet_dimension
    @Test func worksheetDimension() {
        #expect(ws.dimensions == "A1:A1")
        ws["B12"].value = "AAA"
        #expect(ws.dimensions == "B12:B12")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_fill_rows
    @Test(arguments: [(1, 0, "A1"), (9, 2, "C9")]) func fillRows(_ row: Int, _ column: Int, _ coordinate: String) {
        ws["A1"].value = "first"; ws["C9"].value = "last"
        #expect(ws.dimensions == "A1:C9")
        #expect(ws.rows()[row - 1][column].coordinate == coordinate)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_iter_rows
    @Test func iterRows() {
        let expected = [["A1", "B1", "C1"], ["A2", "B2", "C2"], ["A3", "B3", "C3"], ["A4", "B4", "C4"]]
        #expect(ws.rows(minRow: 1, maxRow: 4, minColumn: 1, maxColumn: 3).map { $0.map(\.coordinate) } == expected)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_cell_alternate_coordinates
    @Test func cellAlternateCoordinates() {
        #expect(ws.cell(row: 8, column: 4).coordinate == "D8")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_hyperlink_value
    @Test func hyperlinkValue() {
        ws["A1"].hyperlink = Hyperlink(target: "http://test.com")
        #expect(ws["A1"].value == .string("http://test.com"))
        ws["A1"].value = "test"
        #expect(ws["A1"].value == .string("test"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append
    @Test func append() {
        ws.append(["value"])
        #expect(ws["A1"].value == .string("value"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_list
    @Test func appendList() {
        ws.append(["This is A1", "This is B1"])
        #expect(ws["A1"].value == .string("This is A1") && ws["B1"].value == .string("This is B1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_dict_letter
    @Test func appendDictLetter() {
        ws.append(["A": "This is A1", "C": "This is C1"])
        #expect(ws["A1"].value == .string("This is A1") && ws["C1"].value == .string("This is C1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_dict_index
    @Test func appendDictIndex() {
        ws.append([1: "This is A1", 3: "This is C1"])
        #expect(ws["A1"].value == .string("This is A1") && ws["C1"].value == .string("This is C1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_range
    @Test func appendRange() {
        ws.append((0..<30).map { .integer($0) })
        #expect(ws["AD1"].value == .integer(29))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_iterator
    @Test func appendIterator() {
        ws.append(Array(sequence(first: 0) { $0 < 29 ? $0 + 1 : nil }).map { .integer($0) })
        #expect(ws["AD1"].value == .integer(29))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_2d_list
    @Test func append2dList() {
        ws.append(["This is A1", "This is B1"]); ws.append(["This is A2", "This is B2"])
        #expect(ws.values() == [[.string("This is A1"), .string("This is B1")], [.string("This is A2"), .string("This is B2")]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_cell
    @Test func appendCell() {
        let other = wb.createSheet()["A1"]; other.value = 25
        ws.append([])
        ws.append([other.value])
        #expect(ws["A2"].value == .integer(25))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_rows
    @Test func rows() {
        ws["A1"].value = "first"; ws["C9"].value = "last"
        let rows = ws.rows()
        #expect(rows.count == 9 && rows[0][0].value == .string("first") && rows[0][0].coordinate == "A1" && rows[8][2].value == .string("last"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_no_rows
    @Test func noRows() {
        #expect(ws.rows().isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_no_cols
    @Test func noCols() {
        #expect(ws.columns().isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_one_cell
    @Test func oneCell() {
        let c = ws["A1"]
        #expect(ws.rows().map { $0.map { $0 === c } } == [[true]] && ws.columns().map { $0.map { $0 === c } } == [[true]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_by_col
    @Test func byCol() {
        let c = ws["A1"]
        let cols = ws.columns(minRow: 1, maxRow: 1, minColumn: 1, maxColumn: 1)
        #expect(cols.count == 1 && cols[0].count == 1 && cols[0][0] === c)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_cols
    @Test func cols() {
        ws["A1"].value = "first"; ws["C9"].value = "last"
        let expected = [["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9"], ["B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B9"], ["C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9"]]
        let cols = ws.columns()
        #expect(cols.map { $0.map(\.coordinate) } == expected && cols.count == 3)
        #expect(cols[0][0].value == .string("first") && cols[2][8].value == .string("last"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_values
    @Test func values() {
        ws.append([1, 2, 3]); ws.append([4, 5, 6])
        #expect(ws.values() == [[1, 2, 3], [4, 5, 6]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_auto_filter
    @Test func autoFilter() {
        ws.autoFilter = CellRange("c1:g9")
        #expect(ws.autoFilter?.coordinate == "C1:G9")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getitem
    @Test func getitem() {
        let c = ws["A1"]
        #expect(c.coordinate == "A1" && ws["A1"].value == nil && ws["A1"] === c)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getitem_invalid
    @Test(arguments: [":", "A0", "1:", ":B"]) func getitemInvalid(_ key: String) {
        #expect(CellReference(key) == nil && CellRange(key) == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_setitem
    @Test func setitem() {
        ws["A12"].value = 5
        #expect(ws["A12"].value == .integer(5))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delitem
    @Test func delitem() {
        let ws = dummyWorksheet()
        #expect(ws.existingCell("A2") != nil)
        ws.removeCell("A2")
        #expect(ws.existingCell("A2") == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getslice
    @Test func getslice() {
        ws["B2"].value = "cell"
        let range = ws[range: "A1:B2"]!
        #expect(range.map { $0.map(\.coordinate) } == [["A1", "B1"], ["A2", "B2"]] && range[1][1] === ws["B2"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_single__column
    @Test func getSingleColumn() {
        let c1 = ws.cell(row: 1, column: 3), c2 = ws.cell(row: 2, column: 3, value: 5)
        let col = ws.column("C")
        #expect(col.count == 2 && col[0] === c1 && col[1] === c2)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_row
    @Test func getRow() {
        let a2 = ws.cell(row: 2, column: 1), b2 = ws.cell(row: 2, column: 2), c2 = ws.cell(row: 2, column: 3, value: 5)
        let row = ws.row(2)
        #expect(row.count == 3 && row[0] === a2 && row[1] === b2 && row[2] === c2)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze
    @Test func freeze() {
        ws.freezePanes = ws["b2"].reference
        #expect(ws.freezePanes?.description == "B2")
        ws.freezePanes(at: "")
        #expect(ws.freezePanes == nil)
        ws.freezePanes(at: "C5")
        #expect(ws.freezePanes?.description == "C5")
        ws.freezePanes = ws["A1"].reference
        #expect(ws.freezePanes == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merged_cells_lookup
    @Test func mergedCellsLookup() {
        ws.mergeCells("A1:N50")
        #expect(ws.isMerged("A1") && ws.isMerged("N50") && !ws.isMerged("A51") && !ws.isMerged("O1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merged_cell_ranges
    @Test func mergedCellRanges() {
        #expect(ws.mergedCells.isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_range_string
    @Test func mergeRangeString() {
        ws["A1"].value = 1; ws["D4"].value = 16
        #expect(ws.existingCell("D4") != nil)
        ws.mergeCells("A1:D4")
        #expect(ws.mergedCells.map(\.coordinate) == ["A1:D4"])
        #expect(ws.cell(row: 4, column: 4).value == nil && ws.isMerged("D4") && ws.existingCell("A1")?.value == .integer(1))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_coordinate
    @Test func mergeCoordinate() {
        ws.mergeCells(startRow: 1, startColumn: 1, endRow: 4, endColumn: 4)
        #expect(ws.mergedCells.map(\.coordinate) == ["A1:D4"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_more_columns_than_rows
    @Test func mergeMoreColumnsThanRows() {
        ws.mergeCells(startRow: 1, startColumn: 1, endRow: 2, endColumn: 4)
        #expect(ws.mergedCells.map(\.coordinate) == ["A1:D2"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_more_rows_than_columns
    @Test func mergeMoreRowsThanColumns() {
        ws.mergeCells(startRow: 1, startColumn: 1, endRow: 4, endColumn: 2)
        #expect(ws.mergedCells.map(\.coordinate) == ["A1:B4"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_unmerge_range_string
    @Test func unmergeRangeString() {
        ws.mergeCells("A1:D4")
        #expect(ws.unmergeCells("A1:D4") && ws.mergedCells.isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_unmerge_coordinate
    @Test func unmergeCoordinate() {
        ws.mergeCells("A1:D4")
        #expect(ws.unmergeCells(startRow: 1, startColumn: 1, endRow: 4, endColumn: 4))
        #expect(ws.mergedCells.isEmpty && ws.existingCell("D4") == nil)
    }

    static let printTitleCases: [(String?, String?, String)] = [("1:4", nil, "'Sheet'!$1:$4"), (nil, "A:F", "'Sheet'!$A:$F"), ("1:2", "C:D", "'Sheet'!$1:$2,'Sheet'!$C:$D")]
    // openpyxl: worksheet/tests/test_worksheet.py::test_print_titles
    @Test(arguments: printTitleCases)
    func printTitles(_ rows: String?, _ cols: String?, _ titles: String) {
        ws.setPrintTitleRows(rows); ws.setPrintTitleColumns(cols)
        #expect(ws.printTitles == titles)
    }

    static let printAreaCases: [(String?, String)] = [("A1:F5", "'Sheet'!$A$1:$F$5"), ("$A$1:$F$5", "'Sheet'!$A$1:$F$5"), (nil, ""), ("", "")]
    // openpyxl: worksheet/tests/test_worksheet.py::test_print_area
    @Test(arguments: printAreaCases)
    func printArea(_ cellRange: String?, _ result: String) {
        ws.setPrintArea(cellRange)
        #expect(ws.printAreaFormula == result)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_active_cell
    @Test func activeCell() {
        #expect(ws.view.activeCell == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_selected_cell
    @Test func selectedCell() {
        #expect(ws.view.sqref == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_gridlines
    @Test func gridlines() {
        #expect(ws.view.showGridLines)   // SwiftSheets defaults to Excel's "shown"; openpyxl leaves the attribute unset
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_column_groups
    @Test func columnGroups() {
        ws.setColumnDimension("A") { _ in }; ws.setColumnDimension("F") { _ in }
        ws.groupColumns("F", "K")
        #expect(ws.columnGroups == ["F:K"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_horiz
    @Test func freezePanesHoriz() {
        ws.freezePanes(at: "A4")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable()).xml
        #expect(xml.contains("<pane xSplit=\"0\" ySplit=\"3\" topLeftCell=\"A4\" activePane=\"bottomRight\" state=\"frozen\"/>"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_vert
    @Test func freezePanesVert() {
        ws.freezePanes(at: "D1")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable()).xml
        #expect(xml.contains("<pane xSplit=\"3\" ySplit=\"0\" topLeftCell=\"D1\" activePane=\"bottomRight\" state=\"frozen\"/>"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_both
    @Test func freezePanesBoth() {
        ws.freezePanes(at: "D4")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable()).xml
        #expect(xml.contains("<pane xSplit=\"3\" ySplit=\"3\" topLeftCell=\"D4\" activePane=\"bottomRight\" state=\"frozen\"/>"))
        #expect(xml.contains("<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/><selection pane=\"bottomRight\" activeCell=\"A1\" sqref=\"A1\"/>"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_min_column
    @Test func minColumn() {
        #expect(ws.minColumn == 1)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_max_column
    @Test func maxColumn() {
        ws["F1"].value = 10; ws["F2"].value = 32; ws["F3"].value = "=F1+F2"; ws["A4"].value = "=A1+A2+A3"
        #expect(ws.maxColumn == 6)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_min_row
    @Test func minRow() {
        #expect(ws.minRow == 1)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_max_row
    @Test func maxRow() {
        ws.append([]); ws.append([5]); ws.append([]); ws.append([4])
        #expect(ws.maxRow == 4)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_row_down
    @Test func moveRowDown() {
        let ws = dummyWorksheet()
        #expect(ws.maxRow == 6)
        ws.insertRows(5, count: 1)
        #expect(ws.maxRow == 7 && ws.row(5).map(\.value) == [CellValue?](repeating: nil, count: 8))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_col_right
    @Test func moveColRight() {
        let ws = dummyWorksheet()
        #expect(ws.maxColumn == 8)
        ws.insertColumns(3, count: 2)
        #expect(ws.maxColumn == 10 && ws.column("D").map(\.value) == [CellValue?](repeating: nil, count: 6))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_row_up
    @Test func moveRowUp() {
        let ws = dummyWorksheet()
        ws.deleteRows(3, count: 1)
        #expect(ws.maxRow == 5 && ws.column("A").map(\.value) == ["A1", "A2", "A4", "A5", "A6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_insert_rows
    @Test func insertRows() {
        let ws = dummyWorksheet()
        ws.insertRows(2, count: 2)
        #expect(ws.maxRow == 8 && ws.currentRow == 8 && ws.row(2).map(\.value) == [CellValue?](repeating: nil, count: 8))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_insert_cols
    @Test func insertCols() {
        let ws = dummyWorksheet()
        ws.insertColumns(3)
        #expect(ws.maxColumn == 9 && ws.column("G").map(\.value) == ["F1", "F2", "F3", "F4", "F5", "F6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_rows
    @Test func deleteRows() {
        let ws = dummyWorksheet()
        ws.deleteRows(2, count: 3)
        #expect(ws.maxRow == 3 && ws.currentRow == 3 && ws.column("B").map(\.value) == ["B1", "B5", "B6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_deleta_all_rows
    @Test func deleteAllRows() {
        let ws = dummyWorksheet()
        ws.deleteRows(1, count: 6)
        #expect(ws.maxRow == 1 && ws.currentRow == 0)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_cols
    @Test func deleteCols() {
        let ws = dummyWorksheet()
        ws.deleteColumns(5, count: 2)
        #expect(ws.maxColumn == 6 && ws.row(3).map(\.value) == ["A3", "B3", "C3", "D3", "G3", "H3"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_missing_cols
    @Test func deleteMissingCols() {
        let ws = dummyWorksheet()
        ws.removeCell("H2")
        ws.deleteColumns(7)
        #expect(ws["G2"].value == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_missing_rows
    @Test func deleteMissingRows() {
        let ws = dummyWorksheet()
        ws.removeCell("B4")
        ws.deleteRows(3)
        #expect(ws["B3"].value == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_remainder
    @Test(arguments: [(1, 3, 6, [4]), (2, 3, 6, [4, 5]), (3, 3, 6, [4, 5, 6]), (4, 3, 6, [4, 5, 6]), (5, 3, 6, [5, 6]), (6, 3, 6, [6]), (6, 1, 6, [6])])
    func remainder(_ idx: Int, _ offset: Int, _ maxVal: Int, _ remainder: [Int]) {
        #expect(Worksheet.gutter(idx, offset, maxVal) == remainder)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_last_col
    @Test func deleteLastCol() {
        let ws = dummyWorksheet()
        ws.deleteColumns(8)
        #expect(ws.maxColumn == 7 && ws["H8"].value == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_last_row
    @Test func deleteLastRow() {
        let ws = dummyWorksheet()
        ws.deleteRows(6)
        #expect(ws.maxRow == 5 && ws["A6"].value == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_cell
    @Test func moveCell() {
        let ws = dummyWorksheet()
        ws.moveCell(row: 1, column: 1, rowOffset: 3, columnOffset: 6)
        let cell = ws["G4"]
        #expect(cell.value == .string("A1") && cell.coordinate == "G4" && ws["A1"].value == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_translated_fomula
    @Test func moveTranslatedFormula() {
        let ws = dummyWorksheet()
        ws["G4"].value = "=SUM(G1:G3)"
        ws.moveCell(row: 4, column: 7, rowOffset: 1, columnOffset: 2)
        #expect(ws["I5"].value == .formula("=SUM(G1:G3)", cached: nil))   // translate=False only: formulas are never rewritten
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_nothing
    @Test func moveNothing() {
        let ws = dummyWorksheet()
        _ = ws.moveRange("B2:E5")
        #expect(ws["B2"].value == .string("B2"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_down
    @Test func moveRangeDown() {
        let ws = dummyWorksheet()
        let cr = ws.moveRange(CellRange("B2:E5")!, rows: 2)
        #expect(ws["B4"].value == .string("B2") && cr.coordinate == "B4:E7")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_up
    @Test func moveRangeUp() {
        let ws = dummyWorksheet()
        let cr = ws.moveRange(CellRange("B4:E5")!, rows: -2)
        #expect(ws["B2"].value == .string("B4") && cr.coordinate == "B2:E3")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_right
    @Test func moveRangeRight() {
        let ws = dummyWorksheet()
        let cr = ws.moveRange(CellRange("B2:E5")!, columns: 2)
        #expect(ws["D2"].value == .string("B2") && cr.coordinate == "D2:G5")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_left
    @Test func moveRangeLeft() {
        let ws = dummyWorksheet()
        let cr = ws.moveRange(CellRange("D2:E5")!, columns: -2)
        #expect(ws["B2"].value == .string("D2") && cr.coordinate == "B2:C5")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_empty_range
    @Test func moveEmptyRange() {
        let ws = dummyWorksheet()
        let cr = ws.moveRange(CellRange("A7:E15")!, rows: -2)
        #expect(ws["A6"].value == nil && cr.coordinate == "A5:E13")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_from_string
    @Test func moveRangeFromString() {
        let ws = dummyWorksheet()
        _ = ws.moveRange("B2:E5", rows: 2)
        #expect(ws["B4"].value == .string("B2"))
    }
}

@Suite struct CellRangeParityTests {
    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_ctor
    @Test func ctor() {
        let cr = CellRange(minColumn: 1, minRow: 1, maxColumn: 5, maxRow: 7)
        #expect(cr.minColumn == 1 && cr.minRow == 1 && cr.maxColumn == 5 && cr.maxRow == 7 && cr.coordinate == "A1:E7")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_dict
    @Test func dict() {
        let cr = CellRange("Sheet1!A1:E7")!
        #expect(cr.coordinate == "A1:E7" && cr.bounds == (1, 1, 5, 7))
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_max_row_too_small
    @Test func maxRowTooSmall() { #expect(CellRange("A4:B1") == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_max_col_too_small
    @Test func maxColTooSmall() { #expect(CellRange("F1:B5") == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_from_string
    @Test(arguments: [("Sheet1!$A$1:B4", "Sheet1", "A1:B4"), ("A1:B4", nil, "A1:B4")] as [(String, String?, String)])
    func fromString(_ rangeString: String, _ title: String?, _ coord: String) {
        let cr = CellRange(rangeString)
        #expect(cr?.coordinate == coord && cr?.title == title)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_repr
    @Test func repr() { #expect(CellRange("Sheet1!$A$1:B4")?.qualified == "'Sheet1'!A1:B4") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_str
    @Test func str() {
        #expect(CellRange("'Sheet 1'!$A$1:B4")?.qualified == "'Sheet 1'!A1:B4")
        #expect(CellRange("A1")?.qualified == "A1")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_eq
    @Test func eq() { #expect(CellRange("'Sheet 1'!$A$1:B4") == CellRange("'Sheet 1'!$A$1:B4")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_ne
    @Test func ne() { #expect(CellRange("'Sheet 1'!$A$1:B4") != CellRange("Sheet1!$A$1:B4")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_copy
    @Test func copy() {
        let cr1 = CellRange("Sheet1!$A$1:B4")!
        var cr2 = cr1; cr2.maxRow = 9
        #expect(cr1.maxRow == 4)   // value semantics: a copy is independent
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shift
    @Test func shift() {
        var cr = CellRange("A1:B4")!
        cr.shift(rows: 2, columns: 1)
        #expect(cr.coordinate == "B3:C6")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shift_negative
    @Test func shiftNegative() { #expect(CellRange("A1:B4")!.shifted(rows: 2, columns: -1) == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_union
    @Test func union() {
        let u = CellRange("A1:D4")!.union(CellRange("E5:K10")!)
        #expect(u?.coordinate == "A1:K10" && u?.minColumn == 1 && u?.maxColumn == 11 && u?.maxRow == 10)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_no_union
    @Test func noUnion() { #expect(CellRange("Sheet1!A1:D4")!.union(CellRange("Sheet2!E5:K10")!) == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_expand
    @Test func expand() { #expect(CellRange("E5:K10")!.expanded(right: 2, down: 2, left: 1, up: 2).coordinate == "D3:M12") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shrink
    @Test func shrink() { #expect(CellRange("E5:K10")!.shrunk(right: 2, bottom: 2, left: 1, top: 2)?.coordinate == "F7:I8") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_size
    @Test func size() { #expect(CellRange("E5:K10")!.size == (7, 6)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_intersection
    @Test func intersection() { #expect(CellRange("E5:K10")!.intersection(CellRange("D2:F7")!)?.coordinate == "E5:F7") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_no_intersection
    @Test func noIntersection() { #expect(CellRange("A1:F5")!.intersection(CellRange("M5:P17")!) == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_isdisjoint_order
    @Test func isdisjointOrder() {
        let cr1 = CellRange("E5:K10")!, cr2 = CellRange("A1:C12")!
        #expect(cr1.isDisjoint(with: cr2) == cr2.isDisjoint(with: cr1))
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_isdisjoint_by_col
    @Test func isdisjointByCol() { #expect(CellRange("E5:K10")!.isDisjoint(with: CellRange("A5:C10")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_isdisjoint_by_row
    @Test func isdisjointByRow() { #expect(CellRange("E5:K10")!.isDisjoint(with: CellRange("E12:K12")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_isdisjoint_in_both
    @Test func isdisjointInBoth() { #expect(CellRange("A1:B2")!.isDisjoint(with: CellRange("D4")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_is_not_disjoint
    @Test func isNotDisjoint() { #expect(!CellRange("E5:K10")!.isDisjoint(with: CellRange("D2:F7")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_is_not_disjoint_in_both
    @Test func isNotDisjointInBoth() { #expect(!CellRange("A1:D4")!.isDisjoint(with: CellRange("B2:C3")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_issubset
    @Test func issubset() { #expect(CellRange("F6:J8")!.isSubset(of: CellRange("E5:K10")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_is_not_subset
    @Test func isNotSubset() { #expect(!CellRange("D4:M8")!.isSubset(of: CellRange("E5:K10")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_issuperset
    @Test func issuperset() { #expect(CellRange("E5:K10")!.isSuperset(of: CellRange("F6:J8")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_is_not_superset
    @Test func isNotSuperset() { #expect(!CellRange("E5:K10")!.isSuperset(of: CellRange("A1:D4")!)) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_contains
    @Test func contains() { #expect(CellRange("A1:F10")!.contains("B3")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_doesnt_contain
    @Test func doesntContain() { #expect(!CellRange("A1:F10")!.contains("M1")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_check_title
    @Test(arguments: [("Sheet1!A1:B4", "Sheet1!D5:E5"), ("Sheet1!A1:B4", "D5:E5")]) func checkTitle(_ r1: String, _ r2: String) {
        #expect(!CellRange(r1)!.isOnDifferentSheet(from: CellRange(r2)!) || CellRange(r2)!.title == nil)
        #expect(CellRange(r1)!.union(CellRange(r2)!) != nil)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_different_worksheets
    @Test(arguments: [("A1:B4", "Sheet1!D5:E5"), ("Sheet1!A1:B4", "Sheet2!D5:E5")]) func differentWorksheets(_ r1: String, _ r2: String) {
        #expect(CellRange(r1)!.isOnDifferentSheet(from: CellRange(r2)!) && CellRange(r1)!.union(CellRange(r2)!) == nil)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_lt
    @Test func lt() { #expect(CellRange("A2:F4")! < CellRange("A1:F5")!) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_gt
    @Test func gt() { #expect(CellRange("A1:F5")! > CellRange("A2:F4")!) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_edge_cells
    @Test func edgeCells() {
        let cr = CellRange("A1:C3")!
        #expect(cr.top.map(\.description) == ["A1", "B1", "C1"] && cr.bottom.map(\.description) == ["A3", "B3", "C3"])
        #expect(cr.left.map(\.description) == ["A1", "A2", "A3"] && cr.right.map(\.description) == ["C1", "C2", "C3"])
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_rows
    @Test func rows() { #expect(CellRange("A1:B3")!.rows.map { $0.map(\.description) } == [["A1", "B1"], ["A2", "B2"], ["A3", "B3"]]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_cols
    @Test func cols() { #expect(CellRange("A1:B3")!.cols.map { $0.map(\.description) } == [["A1", "A2", "A3"], ["B1", "B2", "B3"]]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_cells
    @Test func cells() { #expect(CellRange("A1:B3")!.cells.map(\.description) == ["A1", "B1", "A2", "B2", "A3", "B3"]) }
}

@Suite struct MultiCellRangeParityTests {
    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_ctor
    @Test func ctor() {
        let cr = CellRange("A1")!
        #expect(MultiCellRange([cr]).ranges == [cr])
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_from_string
    @Test func fromString() { #expect(MultiCellRange("A1 B2:B5")?.ranges == [CellRange("A1")!, CellRange("B2:B5")!]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_add_coord
    @Test func addCoord() {
        var cells = MultiCellRange([CellRange("A1")!]); cells.add("B2")
        #expect(cells.ranges == [CellRange("A1")!, CellRange("B2")!])
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_add_cell_range
    @Test func addCellRange() {
        var cells = MultiCellRange([CellRange("A1")!]); cells.add(CellRange("B2")!)
        #expect(cells.ranges == [CellRange("A1")!, CellRange("B2")!])
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_iadd
    @Test func iadd() {
        var cells = MultiCellRange(); cells.add("A1")
        #expect(cells.description == "A1")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_avoid_duplicates
    @Test func avoidDuplicates() {
        var cells = MultiCellRange("A1:D4")!; cells.add("A3")
        #expect(cells.description == "A1:D4")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_repr
    @Test func repr() { #expect(MultiCellRange([CellRange("a1")!, CellRange("B2")!]).description == "A1 B2") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_contains
    @Test func contains() { #expect(MultiCellRange([CellRange("A1:E4")!]).contains("C3")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_doesnt_contain
    @Test func doesntContain() { #expect(!MultiCellRange("A1:D5")!.contains("F6")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_eq
    @Test func eq() { #expect(MultiCellRange("A1:D4 E5")?.description == "A1:D4 E5") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_ne
    @Test func ne() { #expect(MultiCellRange("A1") != MultiCellRange("B4")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_empty
    @Test func empty() { #expect(MultiCellRange().isEmpty) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_not_empty
    @Test func notEmpty() { #expect(!MultiCellRange("A1")!.isEmpty) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_remove
    @Test func remove() {
        var cells = MultiCellRange("A1:D4")!
        let removed = cells.remove("A1:D4")
        #expect(removed && cells.isEmpty)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_remove_invalid
    @Test func removeInvalid() {
        var cells = MultiCellRange("A1:D4")!
        let removed = cells.remove("A1")
        #expect(!removed)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_iter
    @Test func iter() { #expect(MultiCellRange("A1")!.sorted == [CellRange("A1")!]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestMultiCellRange::test_copy
    @Test func copy() {
        let r1 = MultiCellRange("A1")!
        var r2 = r1; r2.add("B2")
        #expect(r1.ranges.count == 1 && r2.ranges.count == 2)
    }
}
