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
| `Workbook()`, `load_workbook(path, data_only=)` | `Workbook()`, `Workbook(data:dataOnly:)`, `Workbook(contentsOf:)` | ✅ |
| `wb.save(path)` | `wb.save() -> Data`, `wb.save(to:)` | ✅ (deflate-compressed) |
| `wb.active`, `wb.sheetnames`, `wb[name]`, `create_sheet`, `remove` | `active`, `sheetNames`, `wb[name]`, `createSheet`, `removeSheet` | ✅ |
| `wb.properties`, `wb.epoch`, `wb.defined_names` | `properties`, `epoch`, `definedNames` | ✅ (defined names: name → formula text) |
| `ws.title`, `ws.sheet_state` | `title`, `state` | ✅ |
| `ws["A1"]`, `ws.cell(row, column, value)` | `ws["A1"]`, `cell(row:column:value:)` | ✅ |
| `ws.append`, `ws.delete_rows` | `append`, `deleteRows` | ✅ (`insert_rows`, `delete_cols`: roadmap) |
| `ws.iter_rows(values_only=)`, `max_row`, `dimensions` | `rows(...)`, `values(...)`, `maxRow`, `dimensions` | ✅ |
| `cell.value` types | `CellValue` (`integer` / `number` / `string` / `bool` / `date` / `time` / `formula` / `error` / `richText`) | ✅ |
| `cell.font / fill / border / alignment / number_format / protection` | same names | ✅ (PatternFill; GradientFill: roadmap) |
| `cell.hyperlink` | `hyperlink` | ✅ |
| `cell.comment` | `comment` | ⚠️ held in memory only — not written (needs VML): roadmap |
| `ws.row_dimensions / column_dimensions` (height, width, hidden, outline_level, collapsed, column `fill`/style) | `rowDimension(_:)`, `columnDimension(_:)`, setters, `ColumnDimension.style` | ✅ |
| `ws.merge_cells / unmerge_cells / merged_cells` | `mergeCells`, `unmergeCells`, `mergedCells` | ✅ |
| `ws.freeze_panes` | `freezePanes` | ✅ |
| `ws.sheet_properties` (tabColor, outlinePr) | `properties` | ✅ |
| `ws.sheet_view` (showGridLines, zoomScale) | `view` | ✅ |
| `ws.auto_filter.ref` | `autoFilter` | ✅ (ref only; sort/filter conditions: roadmap) |
| `ws.page_margins`, `ws.page_setup` | `pageMargins`, `pageSetup` | ✅ (basic) |
| `ws.print_title_rows` | `printTitleRows` | ⚠️ not yet written |
| Named styles, `DifferentialStyle` | — | roadmap |
| Conditional formatting, data validation | — | roadmap |
| Charts, images, drawings | — | roadmap |
| Pivot tables, tables (`ws.add_table`) | — | roadmap |
| Formula evaluation | — (never: openpyxl does not either) | — |
| `read_only` / `write_only` streaming modes | — (whole workbook in memory) | roadmap |
| `openpyxl.utils` (`get_column_letter`, `column_index_from_string`, `from_excel`, `to_excel`) | `CellReference.columnLetter / columnIndex`, `ExcelDate.fromSerial / toSerial` | ✅ |

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
swift test                                   # self-contained fixtures in Tests/SwiftSheetsTests/Fixtures
python Tests/FixtureGenerator/make_fixtures.py   # regenerate fixtures with openpyxl (the reference)
```

## License

MIT — see [LICENSE](LICENSE).
