# SwiftSheets

A Swift-idiomatic take on [openpyxl](https://openpyxl.readthedocs.io/)'s core API for reading and writing
`.xlsx` workbooks. Pure Swift — Foundation + the Compression framework only, no external dependencies.
macOS 14+ / iOS 17+ (works anywhere Foundation's `XMLParser` and `Compression` exist).

```swift
import SwiftSheets

// write
let wb = Workbook()
let ws = wb.active
ws.title = "Plan"
ws["A1"].value = "Task"
ws["B1"].value = CellValue(CivilDate(year: 2026, month: 9, day: 1)!)
ws["B1"].numberFormat = "yyyy/m/d"
ws["A1"].font = Font(bold: true)
ws["A1"].fill = .solid(Color(hex: "E8EDF3"))
ws.freezePanes(at: "A2")
ws.setColumnWidth(1, 36)
try wb.save(to: url)

// read
let book = try Workbook(contentsOf: url, dataOnly: true)   // dataOnly: formulas yield cached values, like openpyxl
for row in book["Plan"]!.values() { print(row) }
```

openpyxl is the behavioural reference: the same workbook read by both produces the same values and types
(`int` / `float` / `str` / `bool` / `datetime` / `time`), furigana runs (`<rPh>`) are ignored, rich-text runs are
exposed as `.richText`, the 1900 / 1904 epochs and the phantom 1900-02-29 are handled the same way.

## API coverage (openpyxl ↔ SwiftSheets)

| openpyxl | SwiftSheets | status |
|---|---|---|
| `Workbook()`, `load_workbook(path, data_only=)` | `Workbook()`, `Workbook(data:dataOnly:)`, `Workbook(contentsOf:)`, `wb.dataOnly` | ✅ |
| `wb.save(path)` | `wb.save() -> Data`, `wb.save(to:)` | ✅ (deflate-compressed; `modified` is written as set, not stamped) |
| `wb.active`, `wb.sheetnames`, `wb[name]`, `name in wb`, `for ws in wb`, `wb.index` | `active`, `sheetNames`, `wb[name]`, `contains`, `Sequence`, `index(of:)` | ✅ |
| `create_sheet`, `remove`, `del wb[name]`, `move_sheet`, `copy_worksheet` | `createSheet`, `removeSheet`, `removeSheet(named:)`, `moveSheet`, `copyWorksheet` | ✅ (titles deduped like openpyxl) |
| `wb.properties`, `wb.epoch`, `wb.code_name`, `wb.defined_names`, `ws.defined_names` | `properties`, `epoch`, `codeName`, `definedNames` (name → formula text), `ws.definedNames` | ✅ |
| `ws.title` validation (`\ * ? : / [ ]`, empty, duplicates) | `title` (invalid assignments keep the old name), `Worksheet.validateTitle`, `uniqueTitle` | ✅ |
| `ws.sheet_state` | `state` | ✅ |
| `ws["A1"]`, `ws.cell(row, column, value)`, `ws["A1:B2"]`, `ws["C"]`, `ws[2]`, `del ws["A1"]` | `ws["A1"]`, `cell(row:column:value:)`, `ws[range:]`, `column(_:)`, `row(_:)`, `removeCell` | ✅ |
| `ws.append` (list / dict by index / dict by letter), `ws._current_row` | `append([...])`, `append([Int: …])`, `append([String: …])`, `currentRow` | ✅ |
| `insert_rows`, `insert_cols`, `delete_rows`, `delete_cols`, `move_range` | `insertRows`, `insertColumns`, `deleteRows`, `deleteColumns`, `moveRange` | ✅ (formula translation: roadmap) |
| `iter_rows`, `iter_cols`, `ws.rows`, `ws.columns`, `ws.values`, `max_row`, `calculate_dimension` | `rows(...)`, `columns(...)`, `values(...)`, `maxRow`, `dimensions` | ✅ |
| `cell.value` types | `CellValue` (`integer` / `number` / `string` / `bool` / `date` / `time` / `duration` / `formula` / `error` / `richText`), `cell.dataType` | ✅ |
| date assignment sets a date format; `cell.is_date`; `cell.offset` | `value` didSet, `isDate`, `offset(row:column:)` | ✅ |
| `cell.font / fill / border / alignment / number_format / protection` | same names | ✅ (PatternFill; GradientFill: roadmap) |
| `cell.hyperlink` (sets the value of an empty cell) | `hyperlink` | ✅ |
| `cell.comment` | `comment` (`Comment(text, author)`) | ⚠️ held in memory and copied — not written (needs VML): roadmap |
| `ws.row_dimensions / column_dimensions` (height, width, hidden, outline_level, collapsed, `s`/style, thickTop/Bot) | `rowDimension(_:)`, `columnDimension(_:)`, setters, `RowDimension.style`, `ColumnDimension.style` | ✅ |
| `row_dimensions.group`, `column_dimensions.group`, `ws.column_groups` | `groupRows`, `groupColumns`, `columnGroups` | ✅ |
| `ws.merge_cells / unmerge_cells / merged_cells` (`MergedCellRange.format`) | `mergeCells`, `unmergeCells`, `mergedCells`, `isMerged`, `mergedRange(containing:)` | ✅ (non-anchor cells cleared, borders / protection propagated like openpyxl) |
| `ws.freeze_panes` | `freezePanes` / `freezePanes(at:)` | ✅ |
| `ws.sheet_properties` (tabColor, outlinePr, pageSetUpPr.fitToPage, codeName, filterMode) | `properties` | ✅ |
| `ws.sheet_view` (showGridLines, zoomScale, tabSelected, selection) | `view` | ✅ |
| `ws.sheet_format` | `sheetFormat` | ✅ |
| `ws.auto_filter.ref` (+ `_xlnm._FilterDatabase`) | `autoFilter` | ✅ (ref only; sort/filter conditions: roadmap) |
| `ws.page_margins`, `ws.page_setup`, `ws.print_options` | `pageMargins`, `pageSetup`, `printOptions` | ✅ |
| `ws.print_title_rows / print_title_cols / print_titles / print_area` | `printTitleRows`, `printTitleColumns`, `printTitles`, `printArea`, `setPrintArea`, `setPrintTitles` | ✅ (written as `_xlnm.Print_Titles` / `_xlnm.Print_Area`) |
| `CellRange` (shift, union, intersection, expand, shrink, issubset, edges, rows / cols / cells), `MultiCellRange` | `CellRange`, `MultiCellRange` | ✅ |
| `openpyxl.utils` (`get_column_letter`, `column_index_from_string`, `absolute_coordinate`, `range_boundaries`, `quote_sheetname`, `get_column_interval`) | `CellReference.columnLetter / columnIndex / absolute / quoteSheetName / columnLetters`, `RangeBounds` | ✅ |
| `openpyxl.utils.datetime` (`from_excel`, `to_excel`, `from_ISO8601`, `to_ISO8601`, timedelta) | `ExcelDate.fromSerial / toSerial / fromISO8601 / toISO8601 / durationFromSerial` | ✅ (same millisecond rounding and 1900-02-29 handling) |
| `openpyxl.utils.units`, `openpyxl.utils.escape` | `Units`, `OOXMLEscape` | ✅ |
| `is_date_format`, `is_timedelta_format`, `is_datetime`, `BUILTIN_FORMATS` | `NumberFormat.isDateFormat / isTimedeltaFormat / kind(of:) / builtin` | ✅ |
| `<colors><indexedColors>` | `wb.indexedColors` | ✅ |
| Named styles, `DifferentialStyle`, table styles | — | roadmap |
| Conditional formatting, data validation, sheet / workbook protection, header & footer, page breaks | — | roadmap |
| Charts, images, drawings, comments (file), chartsheets, tables, pivot tables, VBA, external links | — | roadmap |
| Formula tokenizer / translation, shared & array formulas | — (formulas are kept as text; `<f t="shared">` cells yield their cached value) | roadmap |
| Formula evaluation | — (never: openpyxl does not either) | — |
| `read_only` / `write_only` streaming modes | — (whole workbook in memory) | roadmap |

### openpyxl test parity

The openpyxl 3.1.5 test suite (1,711 test functions) is tracked test-by-test in
[`Tests/OpenpyxlParity/parity.json`](Tests/OpenpyxlParity/parity.json): every function is `ported` (same inputs
and expectations in Swift), `adapted` (same behaviour checked in Swift's form — nil instead of an exception,
round trips instead of XML diffs), `na_api` (the feature is on the roadmap above) or `na_python` (Python-only
concept). Ported Swift tests carry `// openpyxl: <file>::<test>` and `Tests/OpenpyxlParity/check.py` cross-checks
the ledger against them; `verify_with_openpyxl.py` writes a workbook with SwiftSheets and reads it back with
openpyxl (and vice versa). openpyxl's own fixture files are used where they apply (`Tests/SwiftSheetsTests/Fixtures/openpyxl`, MIT).

## Design notes

- **Dates have no time zone.** A date cell is a `CivilDate` / `CivilDateTime` (year-month-day [+ time]), never a
  `Foundation.Date`. Convert explicitly with `date(in:)` when you need an instant.
- **Reference types where openpyxl has them.** `Workbook`, `Worksheet`, `Cell` are classes: `ws["A1"].value = …` mutates
  the sheet, as in Python. Styles and values are value types.
- **Element order matters to Excel.** The writer emits worksheet parts in the schema order and keeps the two fills Excel
  requires first (`none`, `gray125`); styles are deduped into `cellXfs` like openpyxl's stylesheet.
- **No theme part.** Colors are written as explicit RGB; `theme` / `indexed` colors read from files are preserved as such.

## Concurrency

`Workbook`, `Worksheet` and `Cell` are plain (non-`Sendable`) reference types, like their openpyxl counterparts.
Build or read a workbook on one task and hand the resulting `Data` / values across isolation boundaries. A
`Sendable` audit is on the roadmap.

## Name

`SwiftSheets` — decided by the owner on 2026-08-22. Checked the same day: no existing GitHub project uses the exact name
(neighbours: SwiftySheets — a Google Sheets API client, SwiftSpreadsheet — a collection-view layout, SwiftSheet — a CSV
sharing tool). A trademark / name-collision check remains a pre-publish step.

## Development

```bash
swift test                                                        # self-contained fixtures in Tests/SwiftSheetsTests/Fixtures
python Tests/FixtureGenerator/make_fixtures.py                        # regenerate fixtures with openpyxl (the reference)
python Tests/OpenpyxlParity/check.py                                  # ledger ↔ Swift provenance cross-check, writes report.json
uv run --project ../../web python Tests/OpenpyxlParity/verify_with_openpyxl.py   # SwiftSheets ⇄ openpyxl round trips
```

## License

MIT — see [LICENSE](LICENSE).
