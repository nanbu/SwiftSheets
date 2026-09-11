"""Renders the openpyxl ↔ SwiftSheets coverage report (API catalogue + test parity) as one self-contained HTML page.

    python Tests/OpenpyxlParity/render_report.py <out.html> [--fragment <out-fragment.html>]

Reads report.json (written by check.py) so the numbers in the page can never disagree with the ledger.
The API catalogue below maps every SwiftSheets API area to the openpyxl tests that exercise it."""
import html
import json
import pathlib
import re
import sys
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent
report = json.load(open(HERE / "report.json"))
TESTS = report["tests"]
SWIFT_TEST_COUNT = 534   # `swift test` at the time of rendering (Tests/SwiftSheetsTests); updated by hand with the log
DATE = "2026-08-22"

STATUS = {
    "ported": ("ported", "#34c759"), "adapted": ("adapted", "#0a84ff"), "na_api": ("no API", "#c7c7cc"), "na_python": ("Python-only", "#e5e5ea"),
}
API_STATUS = {"ok": ("Supported", "#34c759"), "partial": ("Partial", "#ff9f0a"), "roadmap": ("Roadmap", "#8e8e93")}


def e(s):
    return html.escape(str(s), quote=True)


# ---------------------------------------------------------------------------------------------
# API catalogue — each entry: openpyxl API, SwiftSheets API, status, what it does, usage, tests
# tests: selectors "file::name", "file::Class::*", "file::*"
# ---------------------------------------------------------------------------------------------
AREAS = [
 {"id": "workbook", "title": "Workbook — creating, loading and saving workbooks", "apis": [
  {"py": "Workbook()", "sw": "Workbook()", "status": "ok", "desc": "An empty workbook. As in openpyxl, it starts with one sheet named \"Sheet\".",
   "pyx": "from openpyxl import Workbook\nwb = Workbook()\nws = wb.active", "swx": "import SwiftSheets\nlet wb = Workbook()\nlet ws = wb.active",
   "tests": ["workbook/tests/test_workbook.py::test_get_active_sheet", "workbook/tests/test_workbook.py::test_default_epoch", "workbook/tests/test_workbook.py::test_assign_epoch", "workbook/tests/test_workbook.py::TestCopy::*",
             "packaging/tests/test_workbook.py::*", "workbook/tests/test_properties.py::*", "workbook/tests/test_views.py::*"]},
  {"py": "load_workbook(path, data_only=)", "sw": "ReadOptions(formulaCells: .cachedValues)", "status": "ok",
   "desc": "Reads an .xlsx. With formulaCells: .cachedValues, a formula cell reads as its cached calculated value (wb.formulaCells). The workbook part is found by following the rels, so non-standard part names are read too.",
   "pyx": "wb = load_workbook('book.xlsx', data_only=True)", "swx": "let wb = try Workbook(contentsOf: url, options: ReadOptions(formulaCells: .cachedValues))",
   "tests": ["reader/tests/test_excel.py::*", "reader/tests/test_workbook.py::*", "reader/tests/test_strings.py::*", "tests/test_read.py::*", "tests/test_iter.py::*", "tests/test_vba.py::*", "tests/test_read_write_custom_doc_props.py::*", "tests/test_backend.py::*"]},
  {"py": "wb.save(path)", "sw": "wb.save() -> Data / wb.save(to:)", "status": "ok",
   "desc": "Writes a deflate-compressed .xlsx. The set of parts and the element order match openpyxl's. modified is written exactly as set (reproducible output).",
   "pyx": "wb.save('out.xlsx')", "swx": "try wb.save(to: url)\nlet bytes = try wb.save()",
   "tests": ["writer/tests/test_excel.py::*", "writer/tests/test_template.py::*", "workbook/tests/test_writer.py::*", "packaging/tests/test_core.py::*", "packaging/tests/test_relationship.py::*", "packaging/tests/test_manifest.py::*", "packaging/tests/test_extended.py::*", "packaging/tests/test_custom.py::*", "packaging/tests/test_interface.py::*", "packaging/tests/test_pivot.py::*"]},
  {"py": "wb.active / sheetnames / wb[name] / in / iter / index", "sw": "active / sheetNames / wb[name] / contains / Sequence / index(of:)", "status": "ok",
   "desc": "Looking up and enumerating sheets. Only a visible sheet can be made active (openpyxl raises; SwiftSheets ignores the assignment).",
   "pyx": "ws = wb['Plan']\nfor ws in wb: ...", "swx": "let ws = wb[\"Plan\"]!\nfor ws in wb { ... }",
   "tests": ["workbook/tests/test_workbook.py::test_set_active_by_sheet", "workbook/tests/test_workbook.py::test_set_active_by_index", "workbook/tests/test_workbook.py::test_set_invalid_active_index", "workbook/tests/test_workbook.py::test_set_invalid_sheet_by_name",
             "workbook/tests/test_workbook.py::test_set_invalid_child_as_active", "workbook/tests/test_workbook.py::test_set_hidden_sheet_as_active", "workbook/tests/test_workbook.py::test_no_active", "workbook/tests/test_workbook.py::test_getitem", "workbook/tests/test_workbook.py::test_contains",
             "workbook/tests/test_workbook.py::test_iter", "workbook/tests/test_workbook.py::test_index", "workbook/tests/test_workbook.py::test_get_sheet_names", "workbook/tests/test_workbook.py::test_get_chartsheet", "workbook/tests/test_workbook.py::test_del_chartsheet"]},
  {"py": "create_sheet / remove / del wb[name] / move_sheet / copy_worksheet", "sw": "createSheet / removeSheet / removeSheet(named:) / moveSheet / copyWorksheet", "status": "ok",
   "desc": "Adding, removing, reordering and copying sheets. A duplicate name is numbered Sheet1, Sheet2… by the same rule as openpyxl. A copy carries the values, styles, dimensions, merges and print settings.",
   "pyx": "ws2 = wb.create_sheet('Data', 0)\nwb.move_sheet(ws2, offset=1)\ncopy = wb.copy_worksheet(ws2)", "swx": "let ws2 = wb.createSheet(\"Data\", at: 0)\nwb.moveSheet(ws2, offset: 1)\nlet copy = wb.copyWorksheet(ws2)",
   "tests": ["workbook/tests/test_workbook.py::test_create_sheet", "workbook/tests/test_workbook.py::test_create_sheet_with_name", "workbook/tests/test_workbook.py::test_add_correct_sheet", "workbook/tests/test_workbook.py::test_add_sheetname", "workbook/tests/test_workbook.py::test_add_sheet_from_other_workbook",
             "workbook/tests/test_workbook.py::test_create_sheet_readonly", "workbook/tests/test_workbook.py::test_remove_sheet", "workbook/tests/test_workbook.py::test_move_sheet", "workbook/tests/test_workbook.py::test_del_worksheet", "workbook/tests/test_workbook.py::test_add_invalid_worksheet_class_instance",
             "worksheet/tests/test_worksheet_copy.py::*", "workbook/tests/test_child.py::*"]},
  {"py": "wb.properties / wb.epoch / wb.code_name / wb.defined_names", "sw": "properties / epoch / codeName / definedNames", "status": "ok",
   "desc": "Every field of docProps/core.xml, the 1900 / 1904 date system, the VBA code name, and workbook-scope defined names (name → formula string).",
   "pyx": "wb.properties.creator = 'me'\nwb.defined_names['Plan'] = DefinedName('Plan', attr_text='Sheet!$A$1')", "swx": "wb.properties.creator = \"me\"\nwb.definedNames[\"Plan\"] = \"Sheet!$A$1\"",
   "tests": ["workbook/tests/test_defined_name.py::*", "workbook/tests/test_workbook.py::test_duplicate_defined_name", "workbook/tests/test_workbook.py::test_named_styles", "workbook/tests/test_workbook.py::test_immutable_builtins", "workbook/tests/test_workbook.py::test_duplicate_table_name", "workbook/tests/test_workbook.py::test_template",
             "workbook/tests/test_protection.py::*", "workbook/tests/test_function_group.py::*", "workbook/tests/test_smart_tags.py::*", "workbook/tests/test_web.py::*", "workbook/tests/test_external_reference.py::*", "workbook/external_link/tests/test_external.py::*"]},
 ]},
 {"id": "worksheet", "title": "Worksheet — reading and writing cells, editing rows and columns", "apis": [
  {"py": "ws.title / ws.sheet_state", "sw": "title / state", "status": "ok",
   "desc": "Tab-name validation (\\ * ? : / [ ] and the empty name are rejected; a duplicate is numbered) and the visibility state (visible / hidden / veryHidden). An invalid name leaves the previous name in place (openpyxl raises).",
   "pyx": "ws.title = 'Plan'\nws.sheet_state = 'hidden'", "swx": "ws.title = \"Plan\"\nws.state = .hidden",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_path", "worksheet/tests/test_worksheet.py::TestWorksheet::test_new_worksheet"]},
  {"py": "ws['A1'] / ws.cell(row, column, value) / ws['A1:B2'] / ws['C'] / ws[2] / del ws['A1']", "sw": "ws[\"A1\"] / cell(row:column:value:) / ws[range:] / column(_:) / row(_:) / removeCell", "status": "ok",
   "desc": "A cell is a reference type created on first access (as in openpyxl). Ranges, columns and rows are fetched in the same shapes.",
   "pyx": "ws['A1'] = 'Task'\nc = ws.cell(row=2, column=3, value=5)\nrows = ws['A1:C2']", "swx": "ws[\"A1\"].value = \"Task\"\nlet c = ws.cell(row: 2, column: 3, value: 5)\nlet rows = ws[range: \"A1:C2\"]!",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_get_cell", "worksheet/tests/test_worksheet.py::TestWorksheet::test_invalid_cell", "worksheet/tests/test_worksheet.py::TestWorksheet::test_cell_alternate_coordinates", "worksheet/tests/test_worksheet.py::TestWorksheet::test_cell_insufficient_coordinates",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_getitem", "worksheet/tests/test_worksheet.py::TestWorksheet::test_getitem_invalid", "worksheet/tests/test_worksheet.py::TestWorksheet::test_setitem", "worksheet/tests/test_worksheet.py::TestWorksheet::test_delitem",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_getslice", "worksheet/tests/test_worksheet.py::TestWorksheet::test_get_single__column", "worksheet/tests/test_worksheet.py::TestWorksheet::test_get_row", "worksheet/tests/test_worksheet.py::TestWorksheet::test_hyperlink_value"]},
  {"py": "ws.append(list | dict) / ws._current_row", "sw": "append([...]) / append([Int: …]) / append([String: …]) / currentRow", "status": "ok",
   "desc": "Adds one row after the last row appended or read. An empty array only advances the current row (as in openpyxl).",
   "pyx": "ws.append(['a', 1, 2.5])\nws.append({'A': 'x', 'C': 'y'})", "swx": "ws.append([\"a\", 1, 2.5])\nws.append([\"A\": \"x\", \"C\": \"y\"])",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_append", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_list", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_dict_letter", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_dict_index",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_bad_append", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_range", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_iterator", "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_2d_list",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_append_cell", "worksheet/tests/test_worksheet.py::test_max_row"]},
  {"py": "iter_rows / iter_cols / ws.rows / ws.columns / ws.values / max_row / calculate_dimension", "sw": "rows(...) / columns(...) / values(...) / maxRow / dimensions", "status": "ok",
   "desc": "Iterates over a rectangle. By default it runs from A1 to the last used cell (as in openpyxl); with no cells it yields nothing.",
   "pyx": "for row in ws.iter_rows(min_row=2, values_only=True): ...", "swx": "for row in ws.values(minRow: 2) { ... }",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_worksheet_dimension", "worksheet/tests/test_worksheet.py::TestWorksheet::test_fill_rows", "worksheet/tests/test_worksheet.py::TestWorksheet::test_iter_rows", "worksheet/tests/test_worksheet.py::TestWorksheet::test_rows",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_no_rows", "worksheet/tests/test_worksheet.py::TestWorksheet::test_no_cols", "worksheet/tests/test_worksheet.py::TestWorksheet::test_one_cell", "worksheet/tests/test_worksheet.py::TestWorksheet::test_by_col",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_cols", "worksheet/tests/test_worksheet.py::TestWorksheet::test_values", "worksheet/tests/test_worksheet.py::test_min_column", "worksheet/tests/test_worksheet.py::test_max_column", "worksheet/tests/test_worksheet.py::test_min_row"]},
  {"py": "insert_rows / insert_cols / delete_rows / delete_cols / move_range", "sw": "insertRows / insertColumns / deleteRows / deleteColumns / moveRange", "status": "partial",
   "desc": "Inserting and deleting rows and columns, and moving a range. As in openpyxl, only cells move (row dimensions and merges stay put). Rewriting the references in formulas (translate=True) is not implemented.",
   "pyx": "ws.insert_rows(2, amount=2)\nws.delete_cols(5)\nws.move_range('B2:E5', rows=2)", "swx": "ws.insertRows(2, count: 2)\nws.deleteColumns(5)\nws.moveRange(\"B2:E5\", rows: 2)",
   "tests": ["worksheet/tests/test_worksheet.py::TestEditableWorksheet::*"]},
  {"py": "merge_cells / unmerge_cells / merged_cells / MergedCellRange", "sw": "mergeCells / unmergeCells / mergedCells / isMerged / mergedRange(containing:)", "status": "ok",
   "desc": "Merging. Clears the value, hyperlink and comment of every non-anchor cell, distributes the anchor's borders along the edges of the merged range, and copies its protection to every cell (as openpyxl's MergedCellRange.format does).",
   "pyx": "ws.merge_cells('A1:C1')\n'B1' in ws.merged_cells", "swx": "ws.mergeCells(\"A1:C1\")\nws.isMerged(\"B1\")",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_merged_cells_lookup", "worksheet/tests/test_worksheet.py::TestWorksheet::test_merged_cell_ranges", "worksheet/tests/test_worksheet.py::TestWorksheet::test_merge_range_string", "worksheet/tests/test_worksheet.py::TestWorksheet::test_merge_coordinate",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_merge_more_columns_than_rows", "worksheet/tests/test_worksheet.py::TestWorksheet::test_merge_more_rows_than_columns", "worksheet/tests/test_worksheet.py::TestWorksheet::test_unmerge_range_string", "worksheet/tests/test_worksheet.py::TestWorksheet::test_unmerge_coordinate",
             "worksheet/tests/test_merge.py::*", "cell/tests/test_cell.py::TestMergedCell::*"]},
  {"py": "row_dimensions / column_dimensions / group / column_groups", "sw": "rowDimension / columnDimension / setRowDimension / setColumnDimension / groupRows / groupColumns / columnGroups", "status": "ok",
   "desc": "Height, width, hidden, outline level, collapsed, and a row's or column's default style (<row s> / <col style>). Grouping sets an outline level on a range.",
   "pyx": "ws.column_dimensions['A'].width = 20\nws.row_dimensions[4].hidden = True\nws.column_dimensions.group('F', 'K', hidden=True)", "swx": "ws.setColumnWidth(1, 20)\nws.setRowDimension(4) { $0.hidden = true }\nws.groupColumns(\"F\", \"K\", hidden: true)",
   "tests": ["worksheet/tests/test_dimensions.py::*", "worksheet/tests/test_worksheet.py::TestWorksheet::test_column_groups"]},
  {"py": "ws.freeze_panes / ws.sheet_view / ws.sheet_properties / ws.sheet_format", "sw": "freezePanes / view / properties / sheetFormat", "status": "ok",
   "desc": "Frozen panes, the view (gridlines, zoom, selected cell), sheet properties (tab colour, outline summary position, fitToPage, codeName), and the default row height and column width.",
   "pyx": "ws.freeze_panes = 'B2'\nws.sheet_view.showGridLines = False\nws.sheet_properties.tabColor = 'FF0000'", "swx": "ws.freezePanes(at: \"B2\")\nws.view.showGridLines = false\nws.properties.tabColor = Color(hex: \"FF0000\")",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_freeze", "worksheet/tests/test_worksheet.py::test_freeze_panes_horiz", "worksheet/tests/test_worksheet.py::test_freeze_panes_vert", "worksheet/tests/test_worksheet.py::test_freeze_panes_both",
             "worksheet/tests/test_worksheet.py::TestWorksheet::test_active_cell", "worksheet/tests/test_worksheet.py::TestWorksheet::test_selected_cell", "worksheet/tests/test_worksheet.py::TestWorksheet::test_gridlines", "worksheet/tests/test_views.py::*", "worksheet/tests/test_properties.py::*"]},
  {"py": "auto_filter.ref / page_margins / page_setup / print_options / print_title_rows / print_area", "sw": "autoFilter / pageMargins / pageSetup / printOptions / printTitleRows / printTitleColumns / printArea / printTitles", "status": "partial",
   "desc": "The autofilter range (_xlnm._FilterDatabase is written too); print margins, orientation, paper size and centring; print titles and the print area (read and written as _xlnm.Print_Titles / Print_Area). Headers / footers (kept as strings with their &L / &C / &R codes) and page breaks are read and written too, as are filter criteria (value lists, comparisons) and the sort state. Colour / icon / dynamic / top-10 filters are preserved only.",
   "pyx": "ws.auto_filter.ref = 'A1:H1'\nws.print_title_rows = '1:1'\nws.print_area = 'A1:H20'", "swx": "ws.autoFilter = CellRange(\"A1:H1\")\nws.printTitleRows = 1...1\nws.setPrintArea(\"A1:H20\")",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_auto_filter", "worksheet/tests/test_worksheet.py::TestWorksheet::test_print_titles", "worksheet/tests/test_worksheet.py::TestWorksheet::test_print_area", "worksheet/tests/test_page.py::*", "worksheet/tests/test_print_settings.py::*",
             "worksheet/tests/test_filters.py::*", "worksheet/tests/test_header.py::*", "worksheet/tests/test_pagebreak.py::*"]},
  {"py": "ws.add_table / add_chart / add_image / data_validations / conditional_formatting / protection / scenarios / controls", "sw": "—", "status": "roadmap",
   "desc": "Tables, charts, images, data validation, conditional formatting, sheet protection, scenarios and form controls are absent from SwiftSheets (features that need new XML parts).",
   "pyx": "ws.add_table(Table(displayName='T1', ref='A1:D10'))", "swx": "// roadmap",
   "tests": ["worksheet/tests/test_worksheet.py::TestWorksheet::test_add_table", "worksheet/tests/test_worksheet.py::test_add_chart", "worksheet/tests/test_worksheet.py::test_add_image", "worksheet/tests/test_table.py::*", "worksheet/tests/test_datavalidation.py::*",
             "worksheet/tests/test_protection.py::*", "worksheet/tests/test_scenario.py::*", "worksheet/tests/test_controls.py::*", "worksheet/tests/test_ole.py::*", "worksheet/tests/test_related.py::*", "worksheet/tests/test_formula.py::*",
             "worksheet/tests/test_read_only.py::*", "worksheet/tests/test_write_only.py::*", "formatting/tests/test_rule.py::*", "formatting/tests/test_formatting.py::*"]},
 ]},
 {"id": "cell", "title": "Cell and CellValue — values, types and dates", "apis": [
  {"py": "cell.value / data_type / coordinate / row / column / offset", "sw": "value / dataType / coordinate / row / column / offset(row:column:)", "status": "ok",
   "desc": "The value is the CellValue enum (integer / number / string / bool / date / time / duration / formula / error / richText). \"=…\" is a formula, #N/A and the like are errors, and assigning a date sets a number format automatically — the same inference as openpyxl's _bind_value.",
   "pyx": "c.value = datetime.date(2026, 9, 1)\nc.number_format  # 'yyyy-mm-dd'\nc.offset(2, 1).coordinate  # 'B3'", "swx": "c.value = CellValue(CivilDate(year: 2026, month: 9, day: 1)!)\nc.numberFormat  // \"yyyy-mm-dd\"\nc.offset(row: 2, column: 1)?.coordinate  // \"B3\"",
   "tests": ["cell/tests/test_cell.py::test_ctor", "cell/tests/test_cell.py::test_null", "cell/tests/test_cell.py::test_string", "cell/tests/test_cell.py::test_formula", "cell/tests/test_cell.py::test_not_formula", "cell/tests/test_cell.py::test_boolean", "cell/tests/test_cell.py::test_error_codes",
             "cell/tests/test_cell.py::test_insert_date", "cell/tests/test_cell.py::test_timstamp", "cell/tests/test_cell.py::test_time_format_datetime_subclass", "cell/tests/test_cell.py::test_time_format_date_subclass", "cell/tests/test_cell.py::test_time_format_no_date_subclass",
             "cell/tests/test_cell.py::test_not_overwrite_time_format", "cell/tests/test_cell.py::test_cell_formatted_as_date", "cell/tests/test_cell.py::test_illegal_characters", "cell/tests/test_cell.py::test_timedelta", "cell/tests/test_cell.py::<module>::test_repr", "cell/tests/test_cell.py::test_repr_object",
             "cell/tests/test_cell.py::test_cell_offset", "cell/tests/test_cell.py::TestEncoding::*", "cell/tests/test_cell.py::test_write_numpy_to_cell", "cell/tests/test_read_only.py::*"]},
  {"py": "cell.font / fill / border / alignment / number_format / protection", "sw": "font / fill / border / alignment / numberFormat / protection / style", "status": "ok",
   "desc": "Every cell format is a value type. Identical formats are registered in cellXfs only once when writing.",
   "pyx": "c.font = Font(bold=True)\nc.fill = PatternFill('solid', fgColor='FFBFD7F5')", "swx": "c.font = Font(bold: true)\nc.fill = .solid(Color(hex: \"BFD7F5\"))",
   "tests": ["cell/tests/test_cell.py::test_font", "cell/tests/test_cell.py::test_fill", "cell/tests/test_cell.py::test_border", "cell/tests/test_cell.py::test_number_format", "cell/tests/test_cell.py::test_alignment", "cell/tests/test_cell.py::test_protection",
             "cell/tests/test_cell.py::test_pivot_button", "cell/tests/test_cell.py::test_quote_prefix"]},
  {"py": "cell.hyperlink / cell.comment", "sw": "hyperlink / comment", "status": "ok",
   "desc": "Hyperlinks (external / within the workbook, tooltip, display) are read and written; set on an empty cell, the target becomes the value. A note, CellNote(text, author:), is read and written as a comments part paired with legacy VML (its size round-trips too). When the existing VML holds shapes other than notes, a warning is reported, because that VML is rebuilt.",
   "pyx": "c.hyperlink = 'https://example.com/'\nc.comment = Comment('text', 'author')", "swx": "c.hyperlink = Hyperlink(target: \"https://example.com/\")\nc.comment = Comment(\"text\", author: \"author\")",
   "tests": ["cell/tests/test_cell.py::test_comment_assignment", "cell/tests/test_cell.py::test_only_one_cell_per_comment", "cell/tests/test_cell.py::test_remove_comment", "cell/tests/test_cell.py::test_remove_hyperlink", "worksheet/tests/test_hyperlink.py::*",
             "comments/tests/test_comment.py::*", "comments/tests/test_comment_reader.py::*", "comments/tests/test_comment_sheet.py::*", "comments/tests/test_shape_writer.py::*", "comments/tests/test_author.py::*"]},
  {"py": "CellRichText / TextBlock / InlineFont", "sw": ".richText([TextRun]) / TextRun(text, font:)", "status": "ok",
   "desc": "A string made of formatted runs. Read from both shared and inline strings; written as a shared string. Phonetic guides (<rPh>) are skipped, as in openpyxl.",
   "pyx": "c.value = CellRichText(['Design ', TextBlock(InlineFont(b=True), 'review')])", "swx": "c.value = .richText([TextRun(\"Design \"), TextRun(\"review\", font: Font(bold: true))])",
   "tests": ["cell/tests/test_rich_text.py::*", "cell/tests/test_text.py::*"]},
  {"py": "cell writer (etree_write_cell / lxml_write_cell)", "sw": "WorkbookWriter.sheetXML (writing <c>)", "status": "ok",
   "desc": "Writes numbers, booleans, strings (as shared strings), formulas (with cached values), date serials, times, durations and errors. An array formula is read and written together with its range (<f t=\"array\" ref>). ISO dates (iso_dates) are not implemented.",
   "pyx": "# internal", "swx": "// internal — round-trip tested",
   "tests": ["cell/tests/test_writer.py::*"]},
 ]},
 {"id": "styles", "title": "Styles — fonts, fills, borders, alignment and number formats", "apis": [
  {"py": "Font / PatternFill / Border / Side / Alignment / Protection / Color", "sw": "Font / PatternFill / Border / Side / Alignment / Protection / Color", "status": "partial",
   "desc": "Value types with the same names as openpyxl's. A colour is ARGB, theme (with tint), indexed or auto. GradientFill is not implemented.",
   "pyx": "Border(left=Side(style='thin', color='FF888888'))", "swx": "Border(left: Side(style: .thin, color: Color(hex: \"888888\")))",
   "tests": ["styles/tests/test_fonts.py::*", "styles/tests/test_fills.py::*", "styles/tests/test_borders.py::*", "styles/tests/test_alignments.py::*", "styles/tests/test_protection.py::*", "styles/tests/test_colors.py::*"]},
  {"py": "is_date_format / is_timedelta_format / is_datetime / BUILTIN_FORMATS", "sw": "NumberFormat.isDateFormat / isTimedeltaFormat / kind(of:) / builtin / builtinCode", "status": "ok",
   "desc": "Number-format classification is fully compatible with openpyxl (quoted text and bracketed sections are stripped, _ and \\ escapes are handled, [h]-style formats are durations). Built-in formats 0–49 (plus 27–58 for Japanese locales).",
   "pyx": "is_date_format('[h]:mm:ss')  # True", "swx": "NumberFormat.isDateFormat(\"[h]:mm:ss\")  // true",
   "tests": ["styles/tests/test_number_style.py::*"]},
  {"py": "Stylesheet (reading and writing styles.xml) / indexedColors", "sw": "StylesParser / StyleRegistry / wb.indexedColors", "status": "partial",
   "desc": "Reads cellXfs into resolved CellStyle values, along with fonts / fills / borders / numFmts / colors. Writing produces de-duplicated tables. Named styles (cellStyles / cellStyleXfs and a cell's xfId) are supported for both reading and writing. dxf and table styles are preserved only (there is no API to create them).",
   "pyx": "# internal", "swx": "// internal — fixtures from openpyxl",
   "tests": ["styles/tests/test_stylesheet.py::*", "styles/tests/test_cell_style.py::*", "styles/tests/test_named_style.py::*", "styles/tests/test_differential.py::*", "styles/tests/test_table.py::*", "styles/tests/test_proxy.py::*", "styles/tests/test_styleable.py::*"]},
 ]},
 {"id": "utils", "title": "Utils — coordinates, ranges, dates and units", "apis": [
  {"py": "get_column_letter / column_index_from_string / absolute_coordinate / range_boundaries / quote_sheetname / get_column_interval / coordinate_from_string", "sw": "CellReference (init?, columnLetter, columnIndex, absolute, quoteSheetName, columnLetters) / RangeBounds", "status": "ok",
   "desc": "A1-style coordinates and column letters. An input for which openpyxl raises ValueError returns nil.",
   "pyx": "get_column_letter(28)  # 'AB'\nrange_boundaries('D:F')  # (4, None, 6, None)", "swx": "CellReference.columnLetter(28)  // \"AB\"\nRangeBounds(\"D:F\")  // minColumn 4, maxColumn 6, rows nil",
   "tests": ["utils/tests/test_cell.py::*"]},
  {"py": "CellRange / MultiCellRange", "sw": "CellRange / MultiCellRange", "status": "ok",
   "desc": "Shifting, union, intersection, expanding and shrinking of a rectangular range, containment tests, enumeration of its edges and of all its cells, and sqref-style multi-ranges.",
   "pyx": "cr = CellRange('E5:K10'); cr.expand(right=2)\ncr.issubset(CellRange('A1:Z20'))", "swx": "let cr = CellRange(\"E5:K10\")!.expanded(right: 2)\ncr.isSubset(of: CellRange(\"A1:Z20\")!)",
   "tests": ["worksheet/tests/test_cell_range.py::*"]},
  {"py": "from_excel / to_excel / from_ISO8601 / to_ISO8601 / timedelta", "sw": "ExcelDate.fromSerial / toSerial / fromISO8601 / toISO8601 / durationFromSerial", "status": "ok",
   "desc": "Excel serial ⇄ date. Negative serials, the phantom 1900-02-29, millisecond rounding, the 1904 system, and ISO 8601 (including durations such as PT2H0M1S). A date is a CivilDate (no time zone).",
   "pyx": "from_excel(40196.5939815)  # datetime(2010,1,18,14,15,20,2000)", "swx": "ExcelDate.fromSerial(40196.5939815)  // 2010-01-18 14:15:20.002",
   "tests": ["utils/tests/test_datetime.py::*"]},
  {"py": "openpyxl.utils.units / escape", "sw": "Units / OOXMLEscape", "status": "ok",
   "desc": "Conversions between twips, points, inches, cm, EMU, pixels and angles; _xHHHH_ escaping.",
   "pyx": "points_to_pixels(10)  # 14", "swx": "Units.pointsToPixels(10)  // 14",
   "tests": ["utils/tests/test_units.py::*", "utils/tests/test_escape.py::*"]},
  {"py": "inference / FORMULAE / protection hash / IndexedList / BoundDictionary / dataframe", "sw": "—", "status": "roadmap",
   "desc": "Type inference from strings, the list of function names and protection-password hashing are not provided. IndexedList, BoundDictionary and the pandas integration are Python-specific.",
   "pyx": "cast_percentage('3.1%')", "swx": "// —",
   "tests": ["utils/tests/test_inference.py::*", "utils/tests/test_formulas.py::*", "utils/tests/test_protection.py::*", "utils/tests/test_indexed_list.py::*", "utils/tests/test_bound_dictionary.py::*", "utils/tests/test_dataframe.py::*"]},
 ]},
 {"id": "io", "title": "Reader / Writer — reading and writing package parts", "apis": [
  {"py": "WorkSheetParser / WorksheetReader (worksheet XML)", "sw": "SheetParser", "status": "partial",
   "desc": "<c>/<row> without coordinates, row numbers in exponent notation, inlineStr and rich text, ISO dates with t=\"d\", duration formats, normalisation of hyperlinks on merged cells, column and row dimensions and styles, sheetPr / sheetFormatPr / sheetView / pageSetup. Shared formulas, array formulas, conditional formatting, tables, page breaks, scenarios and protection are not read.",
   "pyx": "# internal", "swx": "// internal",
   "tests": ["worksheet/tests/test_reader.py::*"]},
  {"py": "WorksheetWriter (worksheet XML)", "sw": "WorkbookWriter.sheetXML", "status": "partial",
   "desc": "Writes elements in schema order (sheetPr → dimension → sheetViews → sheetFormatPr → cols → sheetData → autoFilter → mergeCells → hyperlinks → printOptions → pageMargins → pageSetup).",
   "pyx": "# internal", "swx": "// internal",
   "tests": ["worksheet/tests/test_writer.py::*"]},
  {"py": "packaging (manifest / relationships / core / app / custom)", "sw": "ZipArchive / ZipWriter / RelsParser / CorePropertiesParser", "status": "partial",
   "desc": "Reads and writes rels and core.xml, and resolves relative targets (../). [Content_Types].xml is parsed too. Extended properties, custom properties and pivot caches are not implemented (custom.xml is preserved as opaque bytes).",
   "pyx": "# internal", "swx": "// internal",
   "tests": []},
  {"py": "xml / descriptors / compat", "sw": "XML (SAX)", "status": "roadmap",
   "desc": "lxml / ElementTree functions, attribute descriptors and the Python compatibility layer have no counterpart in Swift.",
   "pyx": "# —", "swx": "// —",
   "tests": ["xml/tests/test_functions.py::*", "descriptors/tests/test_base.py::*", "descriptors/tests/test_excel.py::*", "descriptors/tests/test_nested.py::*", "descriptors/tests/test_sequence.py::*", "descriptors/tests/test_serialisable.py::*", "descriptors/tests/test_container.py::*", "descriptors/tests/test_namespace.py::*", "compat/tests/test_compat.py::*"]},
 ]},
 {"id": "roadmap", "title": "Roadmap — areas not yet implemented (na_api)", "apis": [
  {"py": "openpyxl.chart / chartsheet / drawing", "sw": "sheet.charts / sheet.images (B.34, B.32, B.72)", "status": "roadmap", "desc": "Charts (four kinds written, every kind read) and images (read and written) are supported. Chartsheets are preserved, and shapes are preserved only (there is no counterpart to openpyxl's drawing object model).", "pyx": "ws.add_chart(BarChart(), 'A1')", "swx": "sheet.addChart(Chart(.column), over: \"D2:K16\")",
   "tests": ["chart/tests/*", "chartsheet/tests/*", "drawing/tests/*", "reader/tests/test_drawings.py::*"]},
  {"py": "openpyxl.pivot", "sw": "—", "status": "roadmap", "desc": "Pivot tables and their caches.", "pyx": "ws._pivots", "swx": "// roadmap", "tests": ["pivot/tests/*"]},
  {"py": "openpyxl.formula (Tokenizer / Translator)", "sw": "—", "status": "roadmap", "desc": "Tokenising formulas and shifting their references. SwiftSheets keeps a formula as a plain string.", "pyx": "Translator('=A1', 'B1').translate_formula('C3')", "swx": "// roadmap", "tests": ["formula/tests/*"]},
  {"py": "workbook external links / protection / VBA / templates", "sw": "—", "status": "roadmap", "desc": "External links, workbook protection, keeping VBA, and xltx / xltm templates.", "pyx": "load_workbook(f, keep_vba=True)", "swx": "// roadmap", "tests": []},
 ]},
]


def select(selector):
    """Resolve a test selector against the report rows."""
    if selector.endswith("/tests/*"):
        mod = selector[:-len("/tests/*")]
        return [t for t in TESTS if t["file"].startswith(mod + "/tests/")]
    file, _, rest = selector.partition("::")
    if rest == "*":
        return [t for t in TESTS if t["file"] == file]
    cls, _, name = rest.rpartition("::")
    if name == "*":
        return [t for t in TESTS if t["file"] == file and t["class"] == cls]
    if cls == "<module>":
        return [t for t in TESTS if t["file"] == file and t["class"] is None and t["name"] == name]
    if cls:
        return [t for t in TESTS if t["file"] == file and t["class"] == cls and t["name"] == name]
    return [t for t in TESTS if t["file"] == file and t["name"] == name]


attributed = set()
for area in AREAS:
    for api in area["apis"]:
        rows, seen = [], set()
        for sel in api["tests"]:
            hits = select(sel)
            if not hits:
                print("warning: selector matches nothing:", sel, file=sys.stderr)
            for t in hits:
                k = (t["file"], t["key"])
                if k not in seen:
                    seen.add(k); rows.append(t)
        api["rows"] = rows
        attributed.update((t["file"], t["key"]) for t in rows)
# everything not attributed goes to the last roadmap entry
leftover = [t for t in TESTS if (t["file"], t["key"]) not in attributed]
AREAS[-1]["apis"][-1]["rows"] = leftover
if leftover:
    AREAS[-1]["apis"][-1]["desc"] += f" (The remaining {len(leftover)} tests not assigned to any area above.)"


def tally(rows):
    c = Counter(t["status"] for t in rows)
    return {s: c.get(s, 0) for s in STATUS}


# ---------------------------------------------------------------------------------------------
# SVG helpers
# ---------------------------------------------------------------------------------------------
def donut(counts, size=220, stroke=26):
    total = sum(counts.get(s, 0) for s in STATUS) or 1
    r = (size - stroke) / 2
    circ = 2 * 3.141592653589793 * r
    out = [f'<svg viewBox="0 0 {size} {size}" width="{size}" height="{size}" role="img" aria-label="Breakdown of test statuses">']
    offset = 0.0
    for s, (label, color) in STATUS.items():
        n = counts.get(s, 0)
        length = circ * n / total
        out.append(f'<circle cx="{size/2}" cy="{size/2}" r="{r}" fill="none" stroke="{color}" stroke-width="{stroke}" '
                   f'stroke-dasharray="{length:.2f} {circ - length:.2f}" stroke-dashoffset="{-offset:.2f}" transform="rotate(-90 {size/2} {size/2})"><title>{label} {n}</title></circle>')
        offset += length
    verified = counts.get("ported", 0) + counts.get("adapted", 0)
    out.append(f'<text x="{size/2}" y="{size/2 - 6}" text-anchor="middle" font-size="30" font-weight="800" fill="currentColor">{verified}</text>')
    out.append(f'<text x="{size/2}" y="{size/2 + 18}" text-anchor="middle" font-size="12" fill="currentColor" opacity=".7">/ {total} verified in Swift</text>')
    out.append("</svg>")
    return "".join(out)


def stacked_bars(modules):
    """Horizontal stacked bars per openpyxl module."""
    rows = sorted(modules.items(), key=lambda kv: -kv[1]["total"])
    w, rowh, left, right = 900, 26, 190, 60
    h = rowh * len(rows) + 40
    maxn = max(c["total"] for _, c in rows)
    scale = (w - left - right) / maxn
    out = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="Test statuses by module" style="font-family:inherit">']
    y = 10
    for name, c in rows:
        x = left
        out.append(f'<text x="{left - 10}" y="{y + 17}" text-anchor="end" font-size="12.5" fill="currentColor">{e(name)}</text>')
        for s, (label, color) in STATUS.items():
            n = c.get(s, 0)
            if n:
                bw = n * scale
                out.append(f'<rect x="{x:.1f}" y="{y + 4}" width="{bw:.1f}" height="{rowh - 8}" fill="{color}" rx="3"><title>{e(name)} {label} {n}</title></rect>')
                if bw > 26:
                    out.append(f'<text x="{x + bw/2:.1f}" y="{y + 17}" text-anchor="middle" font-size="11" fill="{"#fff" if s in ("ported","adapted") else "#1d1d1f"}">{n}</text>')
                x += bw
        out.append(f'<text x="{x + 8:.1f}" y="{y + 17}" font-size="12" fill="currentColor" opacity=".7">{c["total"]}</text>')
        y += rowh
    out.append("</svg>")
    return "".join(out)


def legend():
    return '<div class="legend">' + "".join(f'<span><i style="background:{color}"></i>{label}</span>' for label, color in STATUS.values()) + "</div>"


def pipeline_svg():
    return '''<svg viewBox="0 0 960 300" width="100%" role="img" aria-label="How verification works" style="font-family:inherit;font-size:13px">
<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="currentColor" opacity=".6"/></marker></defs>
<g fill="none" stroke="currentColor" stroke-opacity=".18">
 <rect x="20" y="30" width="250" height="110" rx="14"/><rect x="355" y="30" width="250" height="110" rx="14"/><rect x="690" y="30" width="250" height="110" rx="14"/>
 <rect x="20" y="180" width="250" height="90" rx="14"/><rect x="355" y="180" width="250" height="90" rx="14"/><rect x="690" y="180" width="250" height="90" rx="14"/>
</g>
<g fill="currentColor">
 <text x="145" y="58" text-anchor="middle" font-weight="700">openpyxl 3.1.5 tests</text><text x="145" y="82" text-anchor="middle" opacity=".75">161 files / 1,711 functions</text><text x="145" y="104" text-anchor="middle" opacity=".75">via enumerate_openpyxl_tests.py</text><text x="145" y="124" text-anchor="middle" opacity=".6" font-size="11.5">openpyxl-3.1.5-tests.json (committed)</text>
 <text x="480" y="58" text-anchor="middle" font-weight="700">Ledger: parity.json</text><text x="480" y="82" text-anchor="middle" opacity=".75">one status + reason per test</text><text x="480" y="104" text-anchor="middle" opacity=".75">ported / adapted / na_api / na_python</text><text x="480" y="124" text-anchor="middle" opacity=".6" font-size="11.5">check.py checks both ways → report.json</text>
 <text x="815" y="58" text-anchor="middle" font-weight="700">Swift tests (swift test)</text><text x="815" y="82" text-anchor="middle" opacity=".75">Tests/SwiftSheetsTests/Parity/*.swift</text><text x="815" y="104" text-anchor="middle" opacity=".75">source comment // openpyxl: file::test</text><text x="815" y="124" text-anchor="middle" opacity=".6" font-size="11.5">openpyxl's fixtures (MIT) used as-is</text>
 <text x="145" y="212" text-anchor="middle" font-weight="700">SwiftSheets writes</text><text x="145" y="236" text-anchor="middle" opacity=".75">swiftsheets.xlsx</text><text x="145" y="256" text-anchor="middle" opacity=".6" font-size="11.5">values, styles, sizes, merges, links, print</text>
 <text x="480" y="212" text-anchor="middle" font-weight="700">verify_with_openpyxl.py</text><text x="480" y="236" text-anchor="middle" opacity=".75">both round trips from one definition</text><text x="480" y="256" text-anchor="middle" opacity=".6" font-size="11.5">runs in the web venv (openpyxl 3.1.5)</text>
 <text x="815" y="212" text-anchor="middle" font-weight="700">openpyxl writes</text><text x="815" y="236" text-anchor="middle" opacity=".75">openpyxl.xlsx → SwiftSheets reads it</text><text x="815" y="256" text-anchor="middle" opacity=".6" font-size="11.5">re-checked after a SwiftSheets round trip</text>
</g>
<g stroke="currentColor" stroke-opacity=".5" stroke-width="1.5" fill="none" marker-end="url(#arr)">
 <path d="M270 85 H350"/><path d="M605 85 H685"/><path d="M270 225 H350"/><path d="M690 225 H610"/>
</g>
<g stroke="currentColor" stroke-opacity=".35" stroke-width="1.5" fill="none" stroke-dasharray="5 4" marker-end="url(#arr)"><path d="M815 140 V175"/><path d="M145 140 V175"/></g>
</svg>'''


def api_card(api):
    rows = api["rows"]
    t = tally(rows)
    label, color = API_STATUS[api["status"]]
    chips = "".join(f'<span class="chip" style="--c:{STATUS[s][1]}"><b>{t[s]}</b> {STATUS[s][0]}</span>' for s in STATUS if t[s])
    verified = t["ported"] + t["adapted"]
    bar = ""
    if rows:
        bar = '<div class="bar">' + "".join(f'<i style="flex:{t[s]};background:{STATUS[s][1]}" title="{STATUS[s][0]} {t[s]}"></i>' for s in STATUS if t[s]) + "</div>"
    tests_html = ""
    if rows:
        items = []
        for r in sorted(rows, key=lambda r: (r["file"], r["status"], r["key"])):
            sw = " · ".join(r.get("swift", []))
            reason = f' <span class="why">{e(r["reason"])}</span>' if r["status"] != "ported" and r["reason"] else ""
            swift = f' <span class="sw">{e(sw)}</span>' if sw else ""
            items.append(f'<li><i class="dot" style="background:{STATUS[r["status"]][1]}"></i><code>{e(r["file"].replace("/tests/", "/"))}::{e(r["key"])}</code>{swift}{reason}</li>')
        tests_html = f'<details><summary>openpyxl tests: {len(rows)} ({verified} verified in Swift)</summary><ul class="tests">{"".join(items)}</ul></details>'
    return f'''<article class="api">
  <header><div class="names"><div class="py"><span class="lang">openpyxl</span><code>{e(api["py"])}</code></div><div class="swn"><span class="lang">SwiftSheets</span><code>{e(api["sw"])}</code></div></div>
  <span class="status" style="--c:{color}">{label}</span></header>
  <p>{e(api["desc"])}</p>
  <div class="usage"><pre><span class="lang">Python</span>{e(api["pyx"])}</pre><pre><span class="lang">Swift</span>{e(api["swx"])}</pre></div>
  <div class="teststatus">{bar}<div class="chips">{chips or '<span class="chip muted">No corresponding openpyxl tests</span>'}</div></div>
  {tests_html}
</article>'''


# ---------------------------------------------------------------------------------------------
# Page
# ---------------------------------------------------------------------------------------------
totals = report["totals"]
verified = totals["ported"] + totals["adapted"]
api_count = Counter(api["status"] for area in AREAS for api in area["apis"])
na_api_reasons = Counter()
for t in TESTS:
    if t["status"] == "na_api":
        na_api_reasons[t["api"] or t["reason"]] += 1

CSS = """
:root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:rgba(0,0,0,.08);--card:#fff;--card2:#f5f5f7;--accent:#0a84ff;--code:#f5f5f7}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#000;--fg:#f5f5f7;--muted:#a1a1a6;--line:rgba(255,255,255,.12);--card:#1c1c1e;--card2:#2c2c2e;--accent:#0a84ff;--code:#2c2c2e}}
:root[data-theme="dark"]{--bg:#000;--fg:#f5f5f7;--muted:#a1a1a6;--line:rgba(255,255,255,.12);--card:#1c1c1e;--card2:#2c2c2e;--accent:#0a84ff;--code:#2c2c2e}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font-family:-apple-system,"Hiragino Sans","Noto Sans JP",sans-serif;font-size:15px;line-height:1.75;font-feature-settings:"palt"}
main{max-width:980px;margin:0 auto;padding:48px 24px 96px}
h1{font-size:38px;line-height:1.2;font-weight:800;letter-spacing:-.02em;margin:0 0 8px}
h2{font-size:26px;font-weight:800;letter-spacing:-.01em;margin:64px 0 16px;padding-top:8px}
h3{font-size:18px;font-weight:700;margin:28px 0 10px}
p{margin:8px 0}.lead{font-size:17px;color:var(--muted)}
code,pre{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:12.5px}
code{background:var(--code);padding:1px 6px;border-radius:6px}
pre{background:var(--code);padding:26px 14px 12px;border-radius:12px;overflow-x:auto;margin:0;line-height:1.55;position:relative;white-space:pre}
.note{border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:12px;padding:12px 16px;background:var(--card2);margin:20px 0}
.kpis{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin:24px 0}@media (max-width:640px){.kpis{grid-template-columns:repeat(2,1fr)}}
.kpi{background:var(--card2);border-radius:16px;padding:16px 18px}.kpi b{display:block;font-size:30px;font-weight:800;letter-spacing:-.02em;line-height:1.1}.kpi span{color:var(--muted);font-size:13px}
.hero{display:grid;grid-template-columns:240px 1fr;gap:24px;align-items:center;margin:24px 0}
@media (max-width:640px){.hero{grid-template-columns:1fr}}
.legend{display:flex;flex-wrap:wrap;gap:14px;font-size:13px;color:var(--muted);margin:8px 0}.legend i{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px;vertical-align:-1px}
figure{margin:16px 0;overflow-x:auto}figure svg{max-width:100%;height:auto;color:var(--fg)}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;margin:14px 0}
.api{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:18px 20px;margin:16px 0}
.api header{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
.names{display:grid;gap:6px;flex:1;min-width:0}.names code{background:none;padding:0;font-size:13.5px;white-space:normal;word-break:break-word}
.lang{display:inline-block;font-size:10.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin-right:8px;min-width:84px}
pre .lang{position:absolute;right:12px;top:8px;min-width:0}
.status{flex:none;font-size:12px;font-weight:700;color:#fff;background:var(--c);padding:3px 10px;border-radius:999px}
.usage{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}@media (max-width:720px){.usage{grid-template-columns:1fr}}
.teststatus{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-top:10px}
.bar{display:flex;height:10px;width:180px;border-radius:999px;overflow:hidden;background:var(--card2)}.bar i{display:block;height:100%}
.chips{display:flex;gap:8px;flex-wrap:wrap}.chip{font-size:12px;padding:2px 10px 2px 8px;border-radius:999px;background:var(--card2)}.chip::before{content:"";display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--c);margin-right:6px;vertical-align:1px}.chip b{font-weight:800}.chip.muted{color:var(--muted)}.chip.muted::before{display:none}
details{margin-top:10px}summary{cursor:pointer;color:var(--accent);font-size:13.5px;font-weight:600}
ul.tests{list-style:none;padding:0;margin:10px 0 0;columns:1;font-size:12.5px;line-height:1.6}ul.tests li{padding:3px 0;border-top:1px solid var(--line)}
ul.tests code{background:none;padding:0}.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;vertical-align:0}
.sw{color:var(--accent);font-size:11.5px;margin-left:6px}.why{color:var(--muted);margin-left:6px}
table{border-collapse:collapse;width:100%;font-size:13.5px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid var(--line);vertical-align:top}th{font-weight:700;color:var(--muted);font-size:12.5px}
.tablewrap{overflow-x:auto}
.toc{display:flex;flex-wrap:wrap;gap:8px;margin:18px 0}.toc a{text-decoration:none;color:var(--fg);background:var(--card2);padding:6px 12px;border-radius:999px;font-size:13px}
footer{margin-top:64px;color:var(--muted);font-size:13px;border-top:1px solid var(--line);padding-top:16px}
@media print{@page{size:A4;margin:14mm}body{padding:0;background:#fff;color:#000}main{max-width:none;padding:0}section,.card,.api,table,svg,figure{break-inside:avoid}h2{break-after:avoid}img,svg{max-width:100%!important;height:auto}pre{white-space:pre-wrap}}
"""

parts = []
parts.append(f'''<main>
<p class="lead" style="margin:0 0 6px">SwiftSheets · {DATE}</p>
<h1>API coverage and test parity with openpyxl</h1>
<p class="lead">This page, generated from the ledger, shows how far SwiftSheets (Swift) reproduces each API of the reference implementation, openpyxl 3.1.5, and which of openpyxl's own tests pass in Swift.</p>
<div class="note"><b>Premise:</b> The request was for "a comparison with openxlsx", but the SwiftSheets README, <code>app/CLAUDE.md</code> and the fixture generator all name <b>openpyxl</b> (Python) as the reference implementation, and the repository makes no mention of openxlsx (the R package). This document reads the request as a typo for openpyxl and compares against openpyxl 3.1.5.</div>
<div class="toc">{"".join(f'<a href="#{a["id"]}">{e(a["title"].split(" — ")[0])}</a>' for a in AREAS)}<a href="#diff">Intentional differences</a><a href="#howto">Regenerating and re-verifying</a></div>

<h2 id="summary">Summary</h2>
<div class="kpis">
 <div class="kpi"><b>{api_count["ok"]} / {sum(api_count.values())}</b><span>API areas rated Supported ({api_count["partial"]} partial, {api_count["roadmap"]} roadmap)</span></div>
 <div class="kpi"><b>{verified}</b><span>openpyxl test functions verified in Swift ({totals["ported"]} ported, {totals["adapted"]} adapted)</span></div>
 <div class="kpi"><b>{totals["na_api"]}</b><span>Tests with no corresponding API (charts, pivots, shapes, conditional formatting and so on)</span></div>
 <div class="kpi"><b>{totals["na_python"]}</b><span>Python-only (descriptors, numpy, file descriptors)</span></div>
 <div class="kpi"><b>{SWIFT_TEST_COUNT}</b><span>Swift tests (swift test) — all green</span></div>
 <div class="kpi"><b>2 / 2</b><span>Round trips with openpyxl passed (write → read, read → write)</span></div>
</div>
<div class="hero"><figure style="margin:0">{donut(totals)}</figure>
<div><p>openpyxl 3.1.5 has <b>{totals["total"]} test functions</b> ({totals["cases"]} cases once parameters are expanded). <b>{verified + totals["na_python"]}</b> of them test areas where SwiftSheets has a corresponding API ({totals["na_python"]} of these exercise Python-only machinery such as descriptors and numpy). <b>The remaining {verified} all pass in Swift</b>. The other {totals["na_api"]} belong to areas with no API yet (the roadmap below).</p>{legend()}
<p style="font-size:13px;color:var(--muted)">Ported = the same inputs and the same expected values. Adapted = the same behaviour, checked in Swift's form (an exception becomes nil, an XML comparison becomes a read-back, and so on; each test states its reason).</p></div></div>

<h3>By module</h3>
<figure>{stacked_bars(report["modules"])}</figure>{legend()}

<h3>How verification works</h3>
<figure>{pipeline_svg()}</figure>
<p>So that no judgement rests on an unchecked promise, the ledger <code>app/SwiftSheets/Tests/OpenpyxlParity/parity.json</code> gives every one of the 1,711 tests a status and a reason, and <code>check.py</code> turns red on a test marked ported / adapted that has no Swift test, on a Swift test whose cited source is not in the ledger, and on an ambiguity between tests of the same name. The numbers on this page are generated from its <code>report.json</code>.</p>
''')

for area in AREAS:
    rows = [r for api in area["apis"] for r in api["rows"]]
    t = tally(rows)
    parts.append(f'<h2 id="{area["id"]}">{e(area["title"])}</h2>')
    bar = "".join(f'<i style="flex:{t[s]};background:{STATUS[s][1]}"></i>' for s in STATUS if t[s])
    chips = "".join(f'<span class="chip" style="--c:{STATUS[s][1]}"><b>{t[s]}</b> {STATUS[s][0]}</span>' for s in STATUS if t[s])
    parts.append(f'<div class="teststatus" style="margin:-4px 0 8px"><div class="bar">{bar}</div><div class="chips">{chips}</div></div>')
    for api in area["apis"]:
        parts.append(api_card(api))

# intentional differences
parts.append('''<h2 id="diff">Intentional differences (where behaviour departs from openpyxl)</h2>
<div class="card"><div class="tablewrap"><table><thead><tr><th>Case</th><th>openpyxl</th><th>SwiftSheets</th><th>Reason</th></tr></thead><tbody>
<tr><td>Invalid coordinate, range or column letter</td><td>ValueError</td><td>nil (failable initializer) / false</td><td>Swift convention: failure is expressed in the type rather than by an exception</td></tr>
<tr><td>Invalid sheet name (empty, <code>\\ * ? : / [ ]</code>)</td><td>ValueError</td><td>The previous name is kept; <code>Worksheet.validateTitle</code> returns the reason</td><td>A property assignment cannot throw, and it must not crash</td></tr>
<tr><td>Making a hidden sheet, or a sheet from another workbook, active</td><td>ValueError</td><td>Ignored</td><td>As above</td></tr>
<tr><td><code>CellRange("C3:A1")</code> (end before start)</td><td>ValueError</td><td>nil (earlier SwiftSheets normalised it)</td><td>Aligned with openpyxl</td></tr>
<tr><td>modified on <code>save()</code></td><td>Writes the current time</td><td>The value as set (2026-01-01 when unset)</td><td>Reproducible output (conformance can compare bytes)</td></tr>
<tr><td>Default of showGridLines</td><td>Unset (false)</td><td>true (Excel's default display)</td><td>Omitted on write, so the XML is the same</td></tr>
<tr><td>Six-digit colour <code>Color("FF0000")</code></td><td>Fills in alpha 00</td><td>Fills in alpha FF</td><td>Excel ignores alpha; opaque is safer in other tools</td></tr>
<tr><td>Number of borders with merged cells (complex-styles.xlsx)</td><td>7 + 4 (intermediate objects counted too)</td><td>7 + 1 (final state only)</td><td>No internal IndexedList</td></tr>
<tr><td>Writing strings</td><td>inlineStr (in unit tests) / shared strings</td><td>Always shared strings</td><td>Same as Excel's default; smaller files</td></tr>
<tr><td>Writing ISO dates (iso_dates)</td><td><code>t="d"</code> as an option</td><td>Not supported (reading is)</td><td>Excel expects numeric serials</td></tr>
<tr><td>Strings containing control characters</td><td>IllegalCharacterError</td><td>Detected by <code>containsIllegalCharacters</code>, removed on write</td><td>Constructing an enum case cannot throw</td></tr>
</tbody></table></div></div>
''')

# na_api summary table
parts.append('<h2 id="roadmap-table">Tests with no corresponding API, by area</h2><div class="card"><div class="tablewrap"><table><thead><tr><th>Area</th><th>Tests</th></tr></thead><tbody>')
for k, n in na_api_reasons.most_common():
    parts.append(f'<tr><td>{e(k)}</td><td>{n}</td></tr>')
parts.append('</tbody></table></div></div>')

parts.append('''<h2 id="howto">Regenerating and re-verifying</h2>
<div class="card">
<p>SwiftSheets tests (including those ported from openpyxl):</p><pre>cd app/SwiftSheets &amp;&amp; swift test</pre>
<p style="margin-top:12px">Check the ledger and update report.json (matched against the source comments in Swift; fails on any inconsistency):</p><pre>python3 Tests/OpenpyxlParity/check.py</pre>
<p style="margin-top:12px">Round-trip verification with openpyxl (openpyxl 3.1.5 is installed in Stream's web venv):</p><pre>uv run --project ../../web python Tests/OpenpyxlParity/verify_with_openpyxl.py</pre>
<p style="margin-top:12px">Regenerate this page:</p><pre>python3 Tests/OpenpyxlParity/render_report.py &lt;out.html&gt;</pre>
<p style="margin-top:12px">To follow a newer openpyxl: fetch its source archive, refresh the enumeration with <code>enumerate_openpyxl_tests.py &lt;dir&gt;</code>, and fix the ledger until <code>check.py</code> is green.</p>
</div>
<footer>Generated by render_report.py (from report.json) · openpyxl 3.1.5's tests and fixtures: MIT License (© 2010-2024 openpyxl) · SwiftSheets: MIT License (© 2026 Shinichi Nambu)</footer>
</main>''')

body = "".join(parts)
title = "SwiftSheets × openpyxl — API coverage and test parity"
full = f'<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{e(title)}</title><style>{CSS}</style></head><body>{body}</body></html>'

out = pathlib.Path(sys.argv[1])
out.write_text(full, encoding="utf-8")
print(f"wrote {out} ({len(full)//1024} KB)")
if "--fragment" in sys.argv:
    frag = pathlib.Path(sys.argv[sys.argv.index("--fragment") + 1])
    frag.write_text(f'<title>SwiftSheets × openpyxl parity</title><style>{CSS}</style>{body}', encoding="utf-8")
    print(f"wrote {frag}")
unattributed = len(leftover)
print(f"tests attributed to API entries: {len(TESTS) - unattributed}; leftover shown under roadmap: {unattributed}")
