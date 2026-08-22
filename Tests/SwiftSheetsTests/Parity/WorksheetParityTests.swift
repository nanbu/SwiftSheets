import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX

@Suite struct WorksheetParityTests {
    /// The active sheet of a fresh workbook ("Sheet1"). Value semantics: a local copy, mutated in the test body.
    static func freshSheet() -> Sheet { Workbook().activeSheet }

    /// openpyxl's `dummy_worksheet`: A1:H6 filled with each cell's own coordinate.
    static func dummyWorksheet() -> Sheet {
        var ws = freshSheet()
        for ref in CellRange("A1:H6")!.cells { ws[ref] = .text(ref.a1) }
        return ws
    }

    /// The references `ws.rows()` / `ws.columns()` iterate with no bounds: A1 through the extent (cells no longer know
    /// their position, so coordinate checks go through the range).
    static func defaultRange(_ ws: Sheet) -> CellRange? {
        ws.extent.map { CellRange(minRow: 0, minCol: 0, maxRow: $0.maxRow, maxCol: $0.maxCol) }
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_new_worksheet
    @Test func newWorksheet() {
        // PORT-NOTE: sheets are values and carry no back-reference to their workbook (`ws.workbook === wb`); membership
        // of the new sheet in the workbook is the nearest equivalent.
        var wb = Workbook()
        let i = wb.addSheet()
        #expect(wb.sheets.contains(wb.sheets[i].name))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_cell
    @Test func getCell() {
        let ws = Self.freshSheet()
        let ref = CellRef(row: 0, col: 0)
        #expect(ws[cell: ref] == Cell() && ref.a1 == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_invalid_cell
    @Test func invalidCell() {
        #expect(CellRef("A0") == nil && CellRef(row: -1, col: -1).a1 == "0")   // row / column before A1 are not addressable
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_worksheet_dimension
    @Test func worksheetDimension() {
        var ws = Self.freshSheet()
        #expect(ws.dimensions == "A1:A1")
        ws["B12"] = "AAA"
        #expect(ws.dimensions == "B12:B12")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_fill_rows
    @Test(arguments: [(1, 0, "A1"), (9, 2, "C9")]) func fillRows(_ row: Int, _ column: Int, _ coordinate: String) {
        var ws = Self.freshSheet()
        ws["A1"] = "first"; ws["C9"] = "last"
        #expect(ws.dimensions == "A1:C9")
        #expect(ws.rows().count == 9 && ws.rows()[row - 1].count == 3)
        #expect(Self.defaultRange(ws)?.rows[row - 1][column].a1 == coordinate)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_iter_rows
    @Test func iterRows() {
        let ws = Self.freshSheet()
        let expected = [["A1", "B1", "C1"], ["A2", "B2", "C2"], ["A3", "B3", "C3"], ["A4", "B4", "C4"]]
        let range = CellRange(minRow: 0, minCol: 0, maxRow: 3, maxCol: 2)
        #expect(range.rows.map { $0.map(\.a1) } == expected)
        #expect(ws.rows(in: range).map(\.count) == [3, 3, 3, 3])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_cell_alternate_coordinates
    @Test func cellAlternateCoordinates() {
        let ws = Self.freshSheet()
        let ref = CellRef(row: 7, col: 3)
        #expect(ws[cell: ref] == Cell() && ref.a1 == "D8")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_hyperlink_value
    @Test func hyperlinkValue() {
        var ws = Self.freshSheet()
        ws[cell: "A1"].hyperlink = Hyperlink(target: "http://test.com")
        #expect(ws["A1"] == .text("http://test.com"))
        ws["A1"] = "test"
        #expect(ws["A1"] == .text("test"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append
    @Test func append() {
        var ws = Self.freshSheet()
        ws.append(["value"])
        #expect(ws["A1"] == .text("value"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_list
    @Test func appendList() {
        var ws = Self.freshSheet()
        ws.append(["This is A1", "This is B1"])
        #expect(ws["A1"] == .text("This is A1") && ws["B1"] == .text("This is B1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_dict_letter
    @Test func appendDictLetter() {
        var ws = Self.freshSheet()
        ws.append(["A": "This is A1", "C": "This is C1"])
        #expect(ws["A1"] == .text("This is A1") && ws["C1"] == .text("This is C1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_dict_index
    @Test func appendDictIndex() {
        var ws = Self.freshSheet()
        ws.append([0: "This is A1", 2: "This is C1"])
        #expect(ws["A1"] == .text("This is A1") && ws["C1"] == .text("This is C1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_range
    @Test func appendRange() {
        var ws = Self.freshSheet()
        ws.append((0..<30).map { .integer($0) })
        #expect(ws["AD1"] == .integer(29))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_iterator
    @Test func appendIterator() {
        var ws = Self.freshSheet()
        ws.append(Array(sequence(first: 0) { $0 < 29 ? $0 + 1 : nil }).map { .integer($0) })
        #expect(ws["AD1"] == .integer(29))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_2d_list
    @Test func append2dList() {
        var ws = Self.freshSheet()
        ws.append(["This is A1", "This is B1"]); ws.append(["This is A2", "This is B2"])
        #expect(ws.values() == [[.text("This is A1"), .text("This is B1")], [.text("This is A2"), .text("This is B2")]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_append_cell
    @Test func appendCell() {
        var wb = Workbook()
        let i = wb.addSheet()
        wb.sheets[i]["A1"] = 25
        let other = wb.sheets[i]["A1"]
        var ws = wb.activeSheet
        ws.append([])
        ws.append([other])
        #expect(ws["A2"] == .integer(25))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_rows
    @Test func rows() {
        var ws = Self.freshSheet()
        ws["A1"] = "first"; ws["C9"] = "last"
        let rows = ws.rows()
        #expect(rows.count == 9 && rows[0][0] == .text("first") && Self.defaultRange(ws)?.rows[0][0].a1 == "A1" && rows[8][2] == .text("last"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_no_rows
    @Test func noRows() {
        let ws = Self.freshSheet()
        #expect(ws.rows().isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_no_cols
    @Test func noCols() {
        let ws = Self.freshSheet()
        #expect(ws.columns().isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_one_cell
    @Test func oneCell() {
        // PORT-NOTE: reading `ws["A1"]` no longer creates a cell; a cell carrying only formatting is the nearest
        // "present but empty" cell, and identity (`===`) becomes value equality of the `Cell` struct.
        var ws = Self.freshSheet()
        ws.style("A1") { $0.font.bold = true }
        let c = ws[cell: "A1"]
        #expect(c.value == nil && ws.rows() == [[nil]] && ws.columns() == [[nil]])
        #expect(ws.cells(in: ws.extent!) == [[c]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_by_col
    @Test func byCol() {
        let ws = Self.freshSheet()
        let c = ws["A1"]
        let cols = ws.columns(in: CellRange(minRow: 0, minCol: 0, maxRow: 0, maxCol: 0))
        #expect(cols.count == 1 && cols[0].count == 1 && cols[0][0] == c)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_cols
    @Test func cols() {
        var ws = Self.freshSheet()
        ws["A1"] = "first"; ws["C9"] = "last"
        let expected = [["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9"], ["B1", "B2", "B3", "B4", "B5", "B6", "B7", "B8", "B9"], ["C1", "C2", "C3", "C4", "C5", "C6", "C7", "C8", "C9"]]
        let cols = ws.columns()
        #expect(Self.defaultRange(ws)?.cols.map { $0.map(\.a1) } == expected && cols.count == 3)
        #expect(cols[0][0] == .text("first") && cols[2][8] == .text("last"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_values
    @Test func values() {
        var ws = Self.freshSheet()
        ws.append([1, 2, 3]); ws.append([4, 5, 6])
        #expect(ws.values() == [[1, 2, 3], [4, 5, 6]])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_auto_filter
    @Test func autoFilter() {
        var ws = Self.freshSheet()
        ws.autoFilter = CellRange("c1:g9")
        #expect(ws.autoFilter?.a1 == "C1:G9")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getitem
    @Test func getitem() {
        let ws = Self.freshSheet()
        let c = ws[cell: "A1"]
        #expect(CellRef("A1")?.a1 == "A1" && ws["A1"] == nil && ws[cell: "A1"] == c)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getitem_invalid
    @Test(arguments: [":", "A0", "1:", ":B"]) func getitemInvalid(_ key: String) {
        #expect(CellRef(key) == nil && CellRange(key) == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_setitem
    @Test func setitem() {
        var ws = Self.freshSheet()
        ws["A12"] = 5
        #expect(ws["A12"] == .integer(5))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delitem
    @Test func delitem() {
        var ws = Self.dummyWorksheet()
        #expect(ws.cell("A2") != nil)
        ws.removeCell("A2")
        #expect(ws.cell("A2") == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_getslice
    @Test func getslice() {
        var ws = Self.freshSheet()
        ws["B2"] = "cell"
        let block = CellRange("A1:B2")!
        let range = ws.cells(in: block)
        #expect(block.rows.map { $0.map(\.a1) } == [["A1", "B1"], ["A2", "B2"]] && range.count == 2 && range[1].count == 2 && range[1][1] == ws[cell: "B2"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_single__column
    @Test func getSingleColumn() {
        var ws = Self.freshSheet()
        let c1 = ws[0, 2]
        ws[1, 2] = 5
        let c2 = ws[1, 2]
        let col = ws.column("C")
        #expect(col.count == 2 && col[0] == c1 && col[1] == c2)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_get_row
    @Test func getRow() {
        var ws = Self.freshSheet()
        let a2 = ws[1, 0], b2 = ws[1, 1]
        ws[1, 2] = 5
        let c2 = ws[1, 2]
        let row = ws.row(1)
        #expect(row.count == 3 && row[0] == a2 && row[1] == b2 && row[2] == c2)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze
    @Test func freeze() {
        var ws = Self.freshSheet()
        ws.freezePanes = CellRef("b2")
        #expect(ws.freezePanes?.a1 == "B2")
        ws.freezePanes(at: "")
        #expect(ws.freezePanes == nil)
        ws.freezePanes(at: "C5")
        #expect(ws.freezePanes?.a1 == "C5")
        ws.freezePanes = CellRef("A1")
        #expect(ws.freezePanes == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merged_cells_lookup
    @Test func mergedCellsLookup() {
        var ws = Self.freshSheet()
        ws.merge("A1:N50")
        #expect(ws.isMerged("A1") && ws.isMerged("N50") && !ws.isMerged("A51") && !ws.isMerged("O1"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merged_cell_ranges
    @Test func mergedCellRanges() {
        let ws = Self.freshSheet()
        #expect(ws.merges.isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_range_string
    @Test func mergeRangeString() {
        var ws = Self.freshSheet()
        ws["A1"] = 1; ws["D4"] = 16
        #expect(ws.cell("D4") != nil)
        ws.merge("A1:D4")
        #expect(ws.merges.map(\.a1) == ["A1:D4"])
        #expect(ws[3, 3] == nil && ws.isMerged("D4") && ws.cell("A1")?.value == .integer(1))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_coordinate
    @Test func mergeCoordinate() {
        var ws = Self.freshSheet()
        ws.merge(CellRange(minRow: 0, minCol: 0, maxRow: 3, maxCol: 3))
        #expect(ws.merges.map(\.a1) == ["A1:D4"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_more_columns_than_rows
    @Test func mergeMoreColumnsThanRows() {
        var ws = Self.freshSheet()
        ws.merge(CellRange(minRow: 0, minCol: 0, maxRow: 1, maxCol: 3))
        #expect(ws.merges.map(\.a1) == ["A1:D2"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_merge_more_rows_than_columns
    @Test func mergeMoreRowsThanColumns() {
        var ws = Self.freshSheet()
        ws.merge(CellRange(minRow: 0, minCol: 0, maxRow: 3, maxCol: 1))
        #expect(ws.merges.map(\.a1) == ["A1:B4"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_unmerge_range_string
    @Test func unmergeRangeString() {
        var ws = Self.freshSheet()
        ws.merge("A1:D4")
        let removed = ws.unmerge("A1:D4")
        #expect(removed && ws.merges.isEmpty)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_unmerge_coordinate
    @Test func unmergeCoordinate() {
        var ws = Self.freshSheet()
        ws.merge("A1:D4")
        let removed = ws.unmerge(CellRange(minRow: 0, minCol: 0, maxRow: 3, maxCol: 3))
        #expect(removed && ws.merges.isEmpty && ws.cell("D4") == nil)
    }

    static let printTitleCases: [(String?, String?, String)] = [("1:4", nil, "'Sheet1'!$1:$4"), (nil, "A:F", "'Sheet1'!$A:$F"), ("1:2", "C:D", "'Sheet1'!$1:$2,'Sheet1'!$C:$D")]
    // openpyxl: worksheet/tests/test_worksheet.py::test_print_titles
    @Test(arguments: printTitleCases)
    func printTitles(_ rows: String?, _ cols: String?, _ titles: String) {
        var ws = Self.freshSheet()
        ws.setPrintTitleRows(rows); ws.setPrintTitleColumns(cols)
        #expect(ws.printTitles == titles)
    }

    static let printAreaCases: [(String?, String)] = [("A1:F5", "'Sheet1'!$A$1:$F$5"), ("$A$1:$F$5", "'Sheet1'!$A$1:$F$5"), (nil, ""), ("", "")]
    // openpyxl: worksheet/tests/test_worksheet.py::test_print_area
    @Test(arguments: printAreaCases)
    func printArea(_ cellRange: String?, _ result: String) {
        var ws = Self.freshSheet()
        ws.setPrintArea(cellRange)
        #expect(ws.printAreaFormula == result)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_active_cell
    @Test func activeCell() {
        let ws = Self.freshSheet()
        #expect(ws.view.activeCell == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_selected_cell
    @Test func selectedCell() {
        let ws = Self.freshSheet()
        #expect(ws.view.sqref == "A1")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_gridlines
    @Test func gridlines() {
        let ws = Self.freshSheet()
        #expect(ws.view.showGridLines)   // SwiftSheets defaults to Excel's "shown"; openpyxl leaves the attribute unset
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_column_groups
    @Test func columnGroups() {
        var ws = Self.freshSheet()
        ws.setColumnDimension("A") { _ in }; ws.setColumnDimension("F") { _ in }
        ws.groupColumns("F", "K")
        #expect(ws.columnGroups == ["F:K"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_horiz
    @Test func freezePanesHoriz() {
        var ws = Self.freshSheet()
        ws.freezePanes(at: "A4")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, sink: WarningSink()).xml
        // openpyxl (and Excel) omit a zero split and make the single remaining pane active
        #expect(xml.contains("<pane ySplit=\"3\" topLeftCell=\"A4\" activePane=\"bottomLeft\" state=\"frozen\"/>"))
        #expect(xml.contains("<selection pane=\"bottomLeft\""))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_vert
    @Test func freezePanesVert() {
        var ws = Self.freshSheet()
        ws.freezePanes(at: "D1")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, sink: WarningSink()).xml
        #expect(xml.contains("<pane xSplit=\"3\" topLeftCell=\"D1\" activePane=\"topRight\" state=\"frozen\"/>"))
        #expect(xml.contains("<selection pane=\"topRight\""))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_freeze_panes_both
    @Test func freezePanesBoth() {
        var ws = Self.freshSheet()
        ws.freezePanes(at: "D4")
        let xml = WorkbookWriter.sheetXML(ws, epoch: .windows1900, styles: StyleRegistry(), strings: SharedStringTable(), preserve: false, isActive: false, sink: WarningSink()).xml
        #expect(xml.contains("<pane xSplit=\"3\" ySplit=\"3\" topLeftCell=\"D4\" activePane=\"bottomRight\" state=\"frozen\"/>"))
        #expect(xml.contains("<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/><selection pane=\"bottomRight\" activeCell=\"A1\" sqref=\"A1\"/>"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_min_column
    @Test func minColumn() {
        // PORT-NOTE: `extent` is nil for an empty sheet (the old `minColumn` answered 1 = column A); the A1 default
        // origin that `dimensions` reports is the equivalent.
        let ws = Self.freshSheet()
        #expect(ws.extent == nil && CellRange(ws.dimensions)?.minCol == 0)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_max_column
    @Test func maxColumn() {
        var ws = Self.freshSheet()
        ws["F1"] = 10; ws["F2"] = 32; ws["F3"] = "=F1+F2"; ws["A4"] = "=A1+A2+A3"
        #expect(ws.columnCount == 6)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_min_row
    @Test func minRow() {
        // PORT-NOTE: as `minColumn` — nil extent on an empty sheet; the A1 origin of `dimensions` stands for the old 1.
        let ws = Self.freshSheet()
        #expect(ws.extent == nil && CellRange(ws.dimensions)?.minRow == 0)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_max_row
    @Test func maxRow() {
        var ws = Self.freshSheet()
        ws.append([]); ws.append([5]); ws.append([]); ws.append([4])
        #expect(ws.rowCount == 4)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_row_down
    @Test func moveRowDown() {
        var ws = Self.dummyWorksheet()
        #expect(ws.rowCount == 6)
        ws.insertRows(at: 4, count: 1)
        #expect(ws.rowCount == 7 && ws.row(4) == [CellValue?](repeating: nil, count: 8))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_col_right
    @Test func moveColRight() {
        var ws = Self.dummyWorksheet()
        #expect(ws.columnCount == 8)
        ws.insertColumns(at: 2, count: 2)
        #expect(ws.columnCount == 10 && ws.column("D") == [CellValue?](repeating: nil, count: 6))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_row_up
    @Test func moveRowUp() {
        var ws = Self.dummyWorksheet()
        ws.deleteRows(at: 2, count: 1)
        #expect(ws.rowCount == 5 && ws.column("A") == ["A1", "A2", "A4", "A5", "A6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_insert_rows
    @Test func insertRows() {
        var ws = Self.dummyWorksheet()
        ws.insertRows(at: 1, count: 2)
        #expect(ws.rowCount == 8 && ws.nextAppendRow == 8 && ws.row(1) == [CellValue?](repeating: nil, count: 8))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_insert_cols
    @Test func insertCols() {
        var ws = Self.dummyWorksheet()
        ws.insertColumns(at: 2)
        #expect(ws.columnCount == 9 && ws.column("G") == ["F1", "F2", "F3", "F4", "F5", "F6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_rows
    @Test func deleteRows() {
        var ws = Self.dummyWorksheet()
        ws.deleteRows(at: 1, count: 3)
        #expect(ws.rowCount == 3 && ws.nextAppendRow == 3 && ws.column("B") == ["B1", "B5", "B6"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_deleta_all_rows
    @Test func deleteAllRows() {
        // PORT-NOTE: the old `maxRow` answered 1 for an empty sheet; `rowCount` answers 0 (same sheet state, the
        // documented empty value). `currentRow == 0` maps to `nextAppendRow == 0` unchanged.
        var ws = Self.dummyWorksheet()
        ws.deleteRows(at: 0, count: 6)
        #expect(ws.rowCount == 0 && ws.nextAppendRow == 0)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_cols
    @Test func deleteCols() {
        var ws = Self.dummyWorksheet()
        ws.deleteColumns(at: 4, count: 2)
        #expect(ws.columnCount == 6 && ws.row(2) == ["A3", "B3", "C3", "D3", "G3", "H3"])
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_missing_cols
    @Test func deleteMissingCols() {
        var ws = Self.dummyWorksheet()
        ws.removeCell("H2")
        ws.deleteColumns(at: 6)
        #expect(ws["G2"] == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_missing_rows
    @Test func deleteMissingRows() {
        var ws = Self.dummyWorksheet()
        ws.removeCell("B4")
        ws.deleteRows(at: 2)
        #expect(ws["B3"] == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_remainder
    @Test(arguments: [(1, 3, 6, [4]), (2, 3, 6, [4, 5]), (3, 3, 6, [4, 5, 6]), (4, 3, 6, [4, 5, 6]), (5, 3, 6, [5, 6]), (6, 3, 6, [6]), (6, 1, 6, [6])])
    func remainder(_ idx: Int, _ offset: Int, _ maxVal: Int, _ remainder: [Int]) {
        // PORT-NOTE: openpyxl's `_gutter` (the old `Worksheet.gutter`) was an internal helper naming the rows that
        // `delete_rows` must clear because its overwrite-based move leaves them stale; `Table.shift` rebuilds the cell
        // dictionary, so no such helper exists. The test keeps the table and checks the observable guarantee the
        // gutter existed for: after deleting `offset` rows at `idx` (1-based) from `maxVal` filled rows, the
        // `remainder` rows are exactly the emptied tail (row before it, when inside the deleted zone, holds the moved
        // last row).
        var ws = Self.freshSheet()
        for r in 1...maxVal { ws[r - 1, 0] = .integer(r) }
        ws.deleteRows(at: idx - 1, count: offset)
        #expect(remainder.allSatisfy { ws[$0 - 1, 0] == nil })
        #expect(ws.rowCount == remainder.first! - 1)
        if remainder.first! - 1 >= idx { #expect(ws[remainder.first! - 2, 0] == .integer(maxVal)) }
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_last_col
    @Test func deleteLastCol() {
        var ws = Self.dummyWorksheet()
        ws.deleteColumns(at: 7)
        #expect(ws.columnCount == 7 && ws["H8"] == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_delete_last_row
    @Test func deleteLastRow() {
        var ws = Self.dummyWorksheet()
        ws.deleteRows(at: 5)
        #expect(ws.rowCount == 5 && ws["A6"] == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_cell
    @Test func moveCell() {
        // PORT-NOTE: `moveCell` no longer exists; `moveRange` of a single-cell range is the equivalent, and the
        // coordinate check reads the rebased range it returns (cells do not know their position).
        var ws = Self.dummyWorksheet()
        let moved = ws.moveRange(CellRange(CellRef(row: 0, col: 0)), rows: 3, cols: 6)
        #expect(ws["G4"] == .text("A1") && moved?.a1 == "G4" && ws["A1"] == nil)
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_translated_fomula
    @Test func moveTranslatedFormula() {
        // PORT-NOTE: `moveCell` → `moveRange` of a single-cell range (see `moveCell`).
        var ws = Self.dummyWorksheet()
        ws["G4"] = "=SUM(G1:G3)"
        ws.moveRange(CellRange(CellRef(row: 3, col: 6)), rows: 1, cols: 2)
        #expect(ws["I5"] == Formula("=SUM(G1:G3)"))   // translate=False only: formulas are never rewritten
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_nothing
    @Test func moveNothing() {
        var ws = Self.dummyWorksheet()
        _ = ws.moveRange("B2:E5")
        #expect(ws["B2"] == .text("B2"))
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_down
    @Test func moveRangeDown() {
        var ws = Self.dummyWorksheet()
        let cr = ws.moveRange(CellRange("B2:E5")!, rows: 2)
        #expect(ws["B4"] == .text("B2") && cr?.a1 == "B4:E7")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_up
    @Test func moveRangeUp() {
        var ws = Self.dummyWorksheet()
        let cr = ws.moveRange(CellRange("B4:E5")!, rows: -2)
        #expect(ws["B2"] == .text("B4") && cr?.a1 == "B2:E3")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_right
    @Test func moveRangeRight() {
        var ws = Self.dummyWorksheet()
        let cr = ws.moveRange(CellRange("B2:E5")!, cols: 2)
        #expect(ws["D2"] == .text("B2") && cr?.a1 == "D2:G5")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_left
    @Test func moveRangeLeft() {
        var ws = Self.dummyWorksheet()
        let cr = ws.moveRange(CellRange("D2:E5")!, cols: -2)
        #expect(ws["B2"] == .text("D2") && cr?.a1 == "B2:C5")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_empty_range
    @Test func moveEmptyRange() {
        var ws = Self.dummyWorksheet()
        let cr = ws.moveRange(CellRange("A7:E15")!, rows: -2)
        #expect(ws["A6"] == nil && cr?.a1 == "A5:E13")
    }

    // openpyxl: worksheet/tests/test_worksheet.py::test_move_range_from_string
    @Test func moveRangeFromString() {
        var ws = Self.dummyWorksheet()
        _ = ws.moveRange("B2:E5", rows: 2)
        #expect(ws["B4"] == .text("B2"))
    }
}

@Suite struct CellRangeParityTests {
    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_ctor
    @Test func ctor() {
        let cr = CellRange(minRow: 0, minCol: 0, maxRow: 6, maxCol: 4)
        #expect(cr.minCol == 0 && cr.minRow == 0 && cr.maxCol == 4 && cr.maxRow == 6 && cr.a1 == "A1:E7")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_dict
    @Test func dict() {
        let cr = CellRange("Sheet1!A1:E7")!
        #expect(cr.a1 == "A1:E7" && cr.minCol == 0 && cr.minRow == 0 && cr.maxCol == 4 && cr.maxRow == 6)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_max_row_too_small
    @Test func maxRowTooSmall() { #expect(CellRange("A4:B1") == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_max_col_too_small
    @Test func maxColTooSmall() { #expect(CellRange("F1:B5") == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_from_string
    @Test(arguments: [("Sheet1!$A$1:B4", "Sheet1", "A1:B4"), ("A1:B4", nil, "A1:B4")] as [(String, String?, String)])
    func fromString(_ rangeString: String, _ title: String?, _ coord: String) {
        let cr = CellRange(rangeString)
        #expect(cr?.a1 == coord && cr?.sheet == title)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_repr
    @Test func repr() { #expect(CellRange("Sheet1!$A$1:B4")?.qualifiedA1 == "'Sheet1'!A1:B4") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_str
    @Test func str() {
        #expect(CellRange("'Sheet 1'!$A$1:B4")?.qualifiedA1 == "'Sheet 1'!A1:B4")
        #expect(CellRange("A1")?.qualifiedA1 == "A1")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_eq
    @Test func eq() { #expect(CellRange("'Sheet 1'!$A$1:B4") == CellRange("'Sheet 1'!$A$1:B4")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_ne
    @Test func ne() { #expect(CellRange("'Sheet 1'!$A$1:B4") != CellRange("Sheet1!$A$1:B4")) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_copy
    @Test func copy() {
        let cr1 = CellRange("Sheet1!$A$1:B4")!
        var cr2 = cr1; cr2.maxRow = 8
        #expect(cr1.maxRow == 3)   // value semantics: a copy is independent
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shift
    @Test func shift() {
        var cr = CellRange("A1:B4")!
        cr.shift(rows: 2, cols: 1)
        #expect(cr.a1 == "B3:C6")
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shift_negative
    @Test func shiftNegative() { #expect(CellRange("A1:B4")!.shifted(rows: 2, cols: -1) == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_union
    @Test func union() {
        let u = CellRange("A1:D4")!.union(CellRange("E5:K10")!)
        #expect(u?.a1 == "A1:K10" && u?.minCol == 0 && u?.maxCol == 10 && u?.maxRow == 9)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_no_union
    @Test func noUnion() { #expect(CellRange("Sheet1!A1:D4")!.union(CellRange("Sheet2!E5:K10")!) == nil) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_expand
    @Test func expand() { #expect(CellRange("E5:K10")!.expanded(right: 2, down: 2, left: 1, up: 2).a1 == "D3:M12") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_shrink
    @Test func shrink() { #expect(CellRange("E5:K10")!.shrunk(right: 2, bottom: 2, left: 1, top: 2)?.a1 == "F7:I8") }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_size
    @Test func size() {
        let size = CellRange("E5:K10")!.size
        #expect(size.rows == 6 && size.cols == 7)
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_intersection
    @Test func intersection() { #expect(CellRange("E5:K10")!.intersection(CellRange("D2:F7")!)?.a1 == "E5:F7") }

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
        #expect(!CellRange(r1)!.isOnDifferentSheet(from: CellRange(r2)!) || CellRange(r2)!.sheet == nil)
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
        #expect(cr.top.map(\.a1) == ["A1", "B1", "C1"] && cr.bottom.map(\.a1) == ["A3", "B3", "C3"])
        #expect(cr.left.map(\.a1) == ["A1", "A2", "A3"] && cr.right.map(\.a1) == ["C1", "C2", "C3"])
    }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_rows
    @Test func rows() { #expect(CellRange("A1:B3")!.rows.map { $0.map(\.a1) } == [["A1", "B1"], ["A2", "B2"], ["A3", "B3"]]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_cols
    @Test func cols() { #expect(CellRange("A1:B3")!.cols.map { $0.map(\.a1) } == [["A1", "A2", "A3"], ["B1", "B2", "B3"]]) }

    // openpyxl: worksheet/tests/test_cell_range.py::TestCellRange::test_cells
    @Test func cells() { #expect(CellRange("A1:B3")!.cells.map(\.a1) == ["A1", "B1", "A2", "B2", "A3", "B3"]) }
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
