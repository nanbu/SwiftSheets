# SwiftSheets

A pure Swift spreadsheet library with **one format-neutral model** and **one codec per file format**. Open an existing
workbook, change what you need, save — charts, pivot caches, VBA and everything else you did not touch come out exactly
as they went in. Foundation + the Compression framework only; no external dependencies. macOS 14+ / iOS 17+.

The design is written down in [docs/implementation-spec.html](docs/implementation-spec.html) (Japanese; the spec is
revised first, then the code).

```swift
import SwiftSheets

var wb = try Workbook(contentsOf: URL(filePath: "月次報告.xlsx"))   // format detected from the bytes, not the extension
var sheet = wb.sheets["集計"]!
sheet["B4"] = 1_380_000                       // Int / Double / Decimal / String / Bool / CivilDate literals and values
sheet["B5"] = Formula("=B4/B3")               // parsed into an AST; follows row inserts and sheet renames
sheet.style("A1:D1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "F5F5F7")) }
wb.sheets["集計"] = sheet                       // value types: copy out, edit, put back
let result = try wb.write(to: URL(filePath: "月次報告.xlsx"))   // charts, comments, VBA… untouched (F3)
print(result.warnings)                        // whatever the format could not express — never dropped silently
```

## Formats

| format | read | write | round-trip preservation | status |
|---|---|---|---|---|
| XLSX | ✅ | ✅ | ✅ F3 — uninterpreted parts re-packed byte for byte, ids kept | P1 done |
| XLSM | ✅ | ✅ | ✅ VBA kept as opaque bytes (never run); dropped with a warning when writing .xlsx | P2 done |
| CSV / TSV | ✅ | ✅ | — (values only by definition) | P1 done |
| ODS | detection only | — | — | roadmap P3 |
| Numbers | detection only | — | — | roadmap P4 / P5 |

`SheetFormat.detect(from:)` identifies all five from content; reading ODS / Numbers throws `SheetError.unsupportedFeature`.

## Targets

| product | contents | depends on |
|---|---|---|
| `SheetCore` | `Workbook` → `Sheets` → `Sheet` → `[Table]` → `Cell` model, styles, `FormulaExpr` AST + parser / emitters (XLSX and ODS dialects), the `SpreadsheetCodec` contract, `PreservationStore`, ZIP / XML plumbing, CSV options | nothing |
| `SheetXLSX` | `XLSXCodec` / `XLSMCodec` | SheetCore |
| `SheetCSV` | `CSVCodec` (RFC 4180 + real-world dialects; UTF-8 BOM auto-detection, explicit encodings) | SheetCore |
| `SwiftSheets` | everything plus the facade: `Workbook(contentsOf:)`, `write(to:as:)`, `data(as:)`, `Workbook.convert` | all of the above |

## Model in one paragraph

Everything is a value type. `Workbook.sheets` is a collection addressable by index or name; a `Sheet` holds one or
more `Table`s (exactly one for XLSX / ODS — the sheet forwards the whole cell API to it, so `tables` only matters for
Numbers later). A `Cell` is a `CellValue?` plus `CellStyle`, hyperlink and note. Integer coordinates are **0-based**
(`CellRef(row:col:)`, `sheet[0, 1]`); A1 strings are the only 1-based form. Values carry meaning, never representation:
`.text`, `.integer`, `.number(Decimal)`, `.bool`, `.date(CivilDateTime)` (no time zone), `.time`, `.duration`,
`.formula(FormulaExpr, cached:)`, `.error`, `.richText`.

## openpyxl ↔ SwiftSheets

openpyxl is the behavioural reference: the same file read by both yields the same values and types, `<rPh>` furigana
is ignored, rich text is exposed as runs, 1900 / 1904 epochs and the phantom 1900-02-29 behave the same. The API is
Swift's: value types, `throws` for failure, warnings for degradation, typed values.

| openpyxl | SwiftSheets |
|---|---|
| `load_workbook(path)` / `data_only=True` | `Workbook(contentsOf:)` / `ReadOptions(dataOnly: true)` |
| `keep_vba=True` | not needed — VBA is always preserved |
| `Workbook()`, `wb.save(path)` | `Workbook()`, `wb.write(to:)` → `WriteResult` (`@discardableResult`) |
| `wb.sheetnames`, `wb['Sales']`, `wb.active` | `wb.sheetNames`, `wb.sheets["Sales"]`, `wb.activeSheet` |
| `create_sheet`, `remove`, `copy_worksheet`, `move_sheet` | `addSheet(named:at:)`, `removeSheet(named:)`, `duplicateSheet(named:as:)`, `moveSheet(named:to:)` |
| `ws.title = 'New'` | `wb.sheets[0].name = "New"` (formulas referring to the sheet follow) |
| `ws['A1'].value`, `ws['A1'] = 42`, `ws.cell(row=1, column=2)` | `sheet["A1"]`, `sheet["A1"] = 42`, `sheet[0, 1]` |
| `cell.font = Font(bold=True)` | `sheet.style("A1") { $0.font.bold = true }` or `sheet[cell: "A1"].font.bold = true` |
| `ws.iter_rows(values_only=True)`, `ws.values` | `sheet.rows(in: "A2:D100")`, `sheet.values(in:)` |
| `ws.append([...])` | `sheet.append([...])` |
| `ws.max_row` | `sheet.extent` (`CellRange?`, nil when empty) / `sheet.rowCount` |
| `insert_rows`, `delete_rows`, `insert_cols`, `delete_cols` | `insertRows(at:count:)`, … — formula references follow (openpyxl's do not) |
| `merge_cells`, `unmerge_cells`, `merged_cells.ranges` | `merge(_:)`, `unmerge(_:)`, `merges` |
| `column_dimensions['A'].width = 18`, `row_dimensions[1].height = 24` | `setWidth(18, ofColumn: "A")`, `setHeight(24, ofRow: 0)` |
| `freeze_panes`, `auto_filter.ref`, print titles / area, page setup | `freezePanes` (`CellRef?`), `autoFilter`, `printTitleRows`, `printArea`, `pageSetup`, … |
| `cell.value = '=SUM(A1:B2)'` | `sheet["C1"] = Formula("=SUM(A1:B2)")`; `value.formula?.rendered(as: .ods)` |
| `wb.defined_names`, `wb.properties` | `wb.definedNames`, `wb.metadata` |
| `get_column_letter(3)`, `column_index_from_string('C')` | `CellRef.columnName(2)`, `CellRef.columnIndex("C")` (0-based) |
| `openpyxl.utils.datetime`, `units`, `escape`, `is_date_format` | `ExcelDate`, `Units`, `OOXMLEscape`, `NumberFormat` |
| charts / images / conditional formatting / data validation / comments / pivots | no API — preserved unchanged on a same-format write (F3), listed as `dropped` warnings when converting |
| `read_only` / `write_only` streaming | — (whole workbook in memory) |

### openpyxl test parity

openpyxl 3.1.5's test suite (1,711 functions) is tracked test by test in
[`Tests/OpenpyxlParity/parity.json`](Tests/OpenpyxlParity/parity.json) — `ported`, `adapted`, `na_api` or `na_python`,
each with a reason. Ported Swift tests carry `// openpyxl: <file>::<test>`; `check.py` cross-checks the ledger against
them, and `verify_with_openpyxl.py` writes with SwiftSheets and reads with openpyxl (and back). openpyxl's fixture files
are used where they apply (`Tests/SwiftSheetsTests/Fixtures/openpyxl`, MIT).

## Round-trip preservation (F3)

The first test of the project (`PreservationTests.editOneCellKeepsEverythingElse`) opens a workbook with a chart, a
table, conditional formatting, data validation, comments and a defined name, edits one cell, saves, and checks that
every opaque part is byte-identical, every `r:id` still resolves, `[Content_Types].xml` declares exactly the parts
present, and the worksheet children are in schema order. What makes it work:

- parts the codec does not interpret stay bytes in `Workbook.preserved` (with their relationships and content types);
- unknown children of `<workbook>`, `<worksheet>` and `<styleSheet>` are kept as XML fragments and re-emitted at their
  schema positions (`Sheet.preserved`);
- existing relationship ids, sheet ids and part paths are immutable — new ones are numbered after the maximum;
- `styles.xml` is rebuilt on top of the source's font / fill / border / numFmt tables so `cellStyleXfs`, `dxfs` and
  `tableStyles` (copied verbatim) keep their indices;
- `calcChain.xml` is always dropped and `fullCalcOnLoad` set, so the application recalculates.

Known limits of the current preservation: a cell's named-style link (`xfId`), `cm` / `vm` rich-value attributes and
`pageSetup r:id` are not carried over (the referenced parts are); array-formula ranges are read as plain formulas.

## Design notes

- **Dates have no time zone.** `CivilDate` / `CivilDateTime`, never `Foundation.Date` in the model; `CellValue(Date, in:)` converts explicitly.
- **Numbers keep openpyxl's int / float split.** `.integer(Int)` for integral file text, `.number(Decimal)` otherwise —
  the text of a number survives a round trip and `Decimal` fits Numbers' decimal128 later.
- **Formulas are trees.** Parse failures fall back to `.unparsed(text, dialect:)`, so a same-dialect round trip is
  lossless; the intersection operator (space) is the known gap.
- **Element order matters to Excel.** Generated and preserved elements are merged in schema order; the two mandatory
  fills come first; colours are explicit RGB (no theme part is generated — a source theme is preserved).
- **Sendable throughout.** Every model type is a `Sendable` value.

## Development

```bash
swift test                                                                 # model, formulas, preservation, CSV, parity suites
uv run --project ../Stream/web python Tests/FixtureGenerator/make_fixtures.py                # regenerate openpyxl-made fixtures
uv run --project ../Stream/web python Tests/FixtureGenerator/make_preservation_fixtures.py   # chart / table / VBA fixtures
python3 Tests/OpenpyxlParity/check.py                                      # ledger ↔ Swift provenance cross-check
uv run --project ../Stream/web python Tests/OpenpyxlParity/verify_with_openpyxl.py   # SwiftSheets ⇄ openpyxl round trips
/Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf out.xlsx   # the machine judge for "opens cleanly"
```

## Name

`SwiftSheets` — decided by the owner on 2026-08-22 (the spec's working title was "SwiftSheet"). No existing GitHub
project uses the exact name (neighbours: SwiftySheets, SwiftSpreadsheet, SwiftSheet). A trademark / Swift Package
Index collision check remains a pre-publish step.

## License

MIT — see [LICENSE](LICENSE). openpyxl test fixtures are MIT (see `Tests/SwiftSheetsTests/Fixtures/openpyxl/NOTICE.md`).
