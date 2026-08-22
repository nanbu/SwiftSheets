# SwiftSheets

A pure Swift spreadsheet library with **one format-neutral model** and **one codec per file format**. Open an existing
workbook, change what you need, save — charts, pivot caches, VBA and everything else you did not touch come out exactly
as they went in. Foundation + the Compression framework only; no external dependencies. macOS 14+ / iOS 17+ (Apple platforms only — see [Limits](#limits)).

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
print(wb.readWarnings)                        // …and whatever the file held that the model cannot say
```

Both directions answer with a result — `Workbook.read(contentsOf:)` returns a `ReadResult` (workbook + warnings), and
`wb.write(to:)` a `WriteResult` (bytes + warnings + a suggested format when the losses are serious). The convenience
`Workbook(contentsOf:)` keeps the warnings on `readWarnings`, so nothing is ever dropped in silence.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nanbu/SwiftSheets.git", from: "0.2.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])   // or SheetCore / SheetXLSX / SheetCSV
]
```

Status: **0.3.0** — all five formats are usable; the API may still change before 1.0 (see the roadmap below). The
version here is what the library writes into the files it generates, and a test keeps the two in step.

## Limits

Worth knowing before you point this at a very large or a very strange file. None of them is silent: a file that goes
past a limit comes back with a `degraded` warning, and a file that breaks a rule throws.

| | |
|---|---|
| Whole workbook in memory | No streaming reader or writer yet (roadmap). Reckon on 100–200 bytes per cell — a million cells is a few hundred megabytes, and that is the working size, not the file size. |
| Cell budget | A read stops at `ReadOptions.cellLimit` cells (default 1,000,000) and says so. ODS run-length compression can otherwise describe seventeen billion cells in a kilobyte of XML. |
| Formula nesting | 64 levels, Excel's own limit. Deeper formulas are kept verbatim and written back unchanged, but they do not follow row inserts and are not translated between dialects. |
| ZIP64 | Not supported: packages over 4 GB, or with more than 65,535 parts, are reported as `corruptedContainer`. |
| Apple platforms only | The ZIP layer uses Apple's Compression framework, so there is no Linux or visionOS build today (the spec's §1.1 goal; recorded as a deviation in Appendix B.1). |
| Encrypted files | Not decrypted. A password-protected package is recognised for what it is and throws `unsupportedFeature`, not `corruptedContainer` — as does a legacy `.xls`, which is a different format, not a broken one. |

## Formats

| format | read | write | round-trip preservation | status |
|---|---|---|---|---|
| XLSX | ✅ | ✅ | ✅ F3 — uninterpreted parts re-packed byte for byte, ids kept | P1 done |
| XLSM | ✅ | ✅ | ✅ VBA kept as opaque bytes (never run); dropped with a warning when writing .xlsx | P2 done |
| CSV / TSV | ✅ | ✅ | — (values only by definition) | P1 done |
| ODS | ✅ | ✅ | F2 — values, formulas, styles, merges, sizes; pictures / objects of a source ODS are not re-linked | P3 done |
| Numbers | ✅ values, formulas (as text), merges, sizes, several tables per sheet | ✅ values, merges, sizes, several sheets / tables (template patch) | — (every write starts from the template) | P4 / P5 done, with cuts (below) |

`SheetFormat.detect(from:)` identifies all five from content. Numbers support is reverse-engineered (no public
specification) — see [NOTICE](NOTICE) for the provenance of the schema and [MAINTENANCE.md](MAINTENANCE.md) for keeping
up with new Numbers releases.

### Numbers: what is and is not there

- Read: every value kind (decimal128 numbers, text, rich text as plain text, dates, booleans, durations, errors),
  formulas rebuilt from Numbers' formula trees into XLSX-dialect text (cross-table references as `'Sheet::Table'!A1`),
  merges, row heights / column widths, hidden rows / columns, table positions as `Table.anchor`, header rows as
  `freezePanes`. Cell formatting (fonts, fills, number formats) is **not** read yet (F1 fidelity).
- Write: the empty document shipped with numbers-parser is the template (spec §11.1); the first sheet / table is
  patched in place, further sheets and tables are deep-copied subgraphs with fresh ids and UUIDs. Values, merges,
  sizes, header rows. **Formulas are written as their cached value** with a `degraded` warning — Numbers' formula
  archives are not generated (the reference implementation cannot either, and without Numbers.app on the build
  machine a generated archive could not be validated). Formatting is not written (`degraded` warning, once per table).
- Judges: round trip through our own reader, numbers-parser reading our output
  (`Tests/NumbersParity/verify_with_numbers_parser.py`), and LibreOffice's Numbers importer. **Numbers.app itself
  has not opened these files** — that check is on the release checklist in MAINTENANCE.md.
- Protobuf is handled by a dependency-free dynamic tree (`ProtoMessage`) driven by a machine-extracted schema;
  unknown fields round-trip byte for byte (`NumbersIWATests.fixturesRoundTripByteForByte`).

## Targets

| product | contents | depends on |
|---|---|---|
| `SheetCore` | `Workbook` → `Sheets` → `Sheet` → `[Table]` → `Cell` model, styles, `FormulaExpr` AST + parser / emitters (XLSX and ODS dialects), the `SpreadsheetCodec` contract, `PreservationStore`, ZIP / XML plumbing, CSV options | nothing |
| `SheetXLSX` | `XLSXCodec` / `XLSMCodec` | SheetCore |
| `SheetCSV` | `CSVCodec` (RFC 4180 + real-world dialects; UTF-8 BOM auto-detection, explicit encodings) | SheetCore |
| `SheetODS` | `ODSCodec` (ODF 1.3; mimetype stored first, RLE rows / columns, OpenFormula via the AST's ODS dialect) | SheetCore |
| `SheetNumbers` | `NumbersCodec` (IWA: Snappy + dynamic Protobuf; schema / registry / function table as JSON resources) | SheetCore |
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
| `load_workbook(path)` / `data_only=True` | `Workbook(contentsOf:)` / `ReadOptions(dataOnly: true)`; `Workbook.read(contentsOf:)` for the warnings too |
| `keep_vba=True` | not needed — VBA is always preserved |
| `Workbook()`, `wb.save(path)` | `Workbook()`, `wb.write(to:)` → `WriteResult` (`@discardableResult`) |
| `wb.sheetnames`, `wb['Sales']`, `wb.active` | `wb.sheetNames`, `wb.sheets["Sales"]`, `wb.activeSheet` |
| `create_sheet`, `remove`, `copy_worksheet`, `move_sheet` | `addSheet(named:at:)`, `removeSheet(named:)`, `duplicateSheet(named:as:)`, `moveSheet(named:to:)` |
| `ws.title = 'New'` | `wb.sheets[0].name = "New"` (formulas referring to the sheet follow) |
| `ws['A1'].value`, `ws['A1'] = 42`, `ws.cell(row=1, column=2)` | `sheet["A1"]`, `sheet["A1"] = 42`, `sheet[0, 1]` |
| `cell.font = Font(bold=True)` | `sheet.style("A1") { $0.font.bold = true }` or `sheet[cell: "A1"].font.bold = true` |
| `wb.add_named_style(NamedStyle(...))`, `cell.style = 'Title'` | `wb.addNamedStyle(NamedStyle(...))`, `sheet[cell: "A1"].style = style.applied` (`CellStyle.namedStyle` is the link) |
| `ws.iter_rows(values_only=True)`, `ws.values` | `sheet.rows(in: "A2:D100")`, `sheet.values(in:)` |
| `ws['A1':'C3']` | `sheet.range("A1:C3")` — a lazy view: rows on demand, cells shared, nothing materialised |
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
| `cell.comment = Comment(text, author)` | `sheet[cell: "A1"].comment = CellNote(text, author:)` — written as the comments part plus its legacy VML |
| charts / images / conditional formatting / data validation / pivots | no API — preserved unchanged on a same-format write (F3), listed as `dropped` warnings when converting |
| `read_only` / `write_only` streaming | — (whole workbook in memory; see [Limits](#limits)) |

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

Reading reports its losses the same way writing does: `Workbook.read(contentsOf:)` answers with a `ReadResult`, and
`Workbook(contentsOf:)` leaves the same list on `wb.readWarnings`.

Known limits of the current preservation: `cm` / `vm` rich-value attributes and `pageSetup r:id` are not carried over
(the referenced parts are); array-formula ranges are read as plain formulas.

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
swift test                                                                 # model, formulas, preservation, CSV, parity, property and fuzz suites
SWIFTSHEETS_FUZZ_ROUNDS=20000 swift test --filter Fuzz                     # a longer fuzz campaign (seeds via SWIFTSHEETS_FUZZ_SEEDS)
python3 Tests/FixtureGenerator/make_fixtures.py                           # regenerate openpyxl-made fixtures (any Python with openpyxl)
python3 Tests/FixtureGenerator/make_preservation_fixtures.py              # chart / table / VBA fixtures
python3 Tests/FixtureGenerator/make_encrypted_fixtures.py                 # encrypted / legacy fixtures (openpyxl, msoffcrypto-tool, LibreOffice)
python3 Tests/OpenpyxlParity/check.py                                      # ledger ↔ Swift provenance cross-check (no dependencies)
python3 Tests/OpenpyxlParity/verify_with_openpyxl.py                       # SwiftSheets ⇄ openpyxl round trips (needs openpyxl)
python3 Tests/NumbersParity/dump_with_numbers_parser.py                    # refresh <fixture>.expected.json from numbers-parser
python3 Tests/NumbersParity/verify_with_numbers_parser.py                  # numbers-parser reads what SwiftSheets wrote
python3 scripts/extract-numbers-schema.py                                 # regenerate the Numbers schema resources from numbers-parser
/Applications/LibreOffice.app/Contents/MacOS/soffice --headless --convert-to pdf out.xlsx   # the machine judge for "opens cleanly"
```

## Name

`SwiftSheets` — plural, the way Apple names frameworks whose subject is a countable thing (Charts, Contacts, Photos)
and the way Swift packages name their products (swift-collections → `Collections`). The spec's working title was the
singular "SwiftSheet", which is also taken on GitHub by an unrelated CSV-sharing tool; a handful of unrelated toy
repositories (≤ 1 star) share the plural name. Decided by the owner on 2026-08-22.

## License

MIT — see [LICENSE](LICENSE). openpyxl test fixtures are MIT (see `Tests/SwiftSheetsTests/Fixtures/openpyxl/NOTICE.md`).
