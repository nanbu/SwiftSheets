# SwiftSheets

[![CI](https://github.com/nanbu/SwiftSheets/actions/workflows/ci.yml/badge.svg)](https://github.com/nanbu/SwiftSheets/actions/workflows/ci.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-1d1d1f)](https://github.com/nanbu/SwiftSheets#limits)
[![License: MIT](https://img.shields.io/badge/License-MIT-248a3d)](https://github.com/nanbu/SwiftSheets/blob/main/LICENSE)

A pure Swift spreadsheet library with **one format-neutral model** and **one codec per file format**. Open an existing
workbook, change what you need, save — charts, pivot caches, VBA and everything else you did not touch come out exactly
as they went in. Foundation + the Compression framework only; no external dependencies. **Swift 6.2+ (Xcode 26+)**, macOS 14+ / iOS 17+ (Apple platforms only — see [Limits](#limits)).

The design is written down in [the implementation spec](https://nanbu.github.io/SwiftSheets/implementation-spec.html)
(Japanese; the spec is revised first, then the code), and what each format carries — measured, not claimed — is in
[the format support table](https://nanbu.github.io/SwiftSheets/format-support.html). Both are at
**<https://nanbu.github.io/SwiftSheets/>**.

```swift
import SwiftSheets

var wb = try Workbook(contentsOf: URL(filePath: "monthly-report.xlsx"))   // format detected from the bytes, not the extension
var sheet = wb.sheets["Summary"]!
sheet["B4"] = 1_380_000                       // Int / Double / Decimal / String / Bool / CivilDate literals and values
sheet["B5"] = Formula("=B4/B3")               // parsed into an AST; follows row inserts and sheet renames
sheet.style("A1:D1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "F5F5F7")) }
wb.sheets["Summary"] = sheet                  // value types: copy out, edit, put back
let result = try wb.write(to: URL(filePath: "monthly-report.xlsx"))   // charts, comments, VBA… untouched (F3)
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
    .package(url: "https://github.com/nanbu/SwiftSheets.git", from: "0.7.2")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])   // or SheetCore / SheetXLSX / SheetCSV
]
```

Status: **0.7.2** — all five formats are usable; the API may still change before 1.0. What changed in each release
is in [CHANGELOG.md](CHANGELOG.md). The version here is what the library writes into the files it generates, and a
test keeps the constant, this line and the pin above in step.

## Limits

Worth knowing before you point this at a very large or a very strange file. None of them is silent: a file that goes
past a limit comes back with a `degraded` warning, and a file that breaks a rule throws.

| | |
|---|---|
| Whole workbook in memory | `Workbook` holds every cell: reckon on 100–200 bytes each, so a million cells is a few hundred megabytes — the working size, not the file size. `StreamingReader` / `StreamingWriter` (XLSX only) walk a file row by row instead: measured over 750,000 cells, writing costs **+3 MB** whatever the row count and reading **+54 MB** (one sheet's expanded XML), against **+190 MB** for the whole model. They carry values and formatting and nothing else — no merges, no notes, no preservation. |
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
| ODS | ✅ | ✅ | F2 — values, formulas, styles, conditional formats, validations, print setup, tables, filters, pivots, merges, sizes, and the six things only ODF has; pictures / objects of a source ODS are not re-linked | P3 done |
| Numbers | ✅ values, formulas (as text, cross-table references included), cell formatting, number formats, conditional formats, pop-up menus as list validations, cell controls (checkbox, stepper, slider, rating), hyperlinks, formatting runs, notes, merges, sizes, several tables per sheet | ✅ values, formulas, cell formatting, number formats, conditional formats, inline-list validations as pop-up menus, cell controls, pivot tables (one field per axis), hyperlinks, formatting runs, notes, merges, sizes, several sheets / tables (template patch) | — (every write starts from the template) | P4 / P5 done, with cuts (below) |

`SheetFormat.detect(from:)` identifies all five from content. Numbers support is reverse-engineered (no public
specification) — see [NOTICE](NOTICE) for the provenance of the schema and [MAINTENANCE.md](MAINTENANCE.md) for keeping
up with new Numbers releases.

### ODS: what OpenDocument has that Excel has not

The comparison runs both ways. Six things OpenDocument says have no OOXML equivalent at all, and SwiftSheets reads
and writes every one of them (spec Appendix B.17): **label ranges** — headings a formula may name directly, so
`=SUM(Sales)` finds the column headed *Sales* without a defined name, which Excel could do until 2003 and OOXML
cannot write; the **consolidation definition**, which ODF stores in the document where Excel consolidates as a
one-off command and keeps nothing; the **detective's arrows**, which Excel draws and never saves; the
**calculation settings** that decide whether a search condition is a regular expression, whether it must match a
whole cell, and where the two-digit-year window starts — settings of the application in Excel, of the file in ODF;
the **date origin**, which ODF lets be any date; and a cell that knows **which currency** it holds as data rather
than only inside a format code. Writing such a workbook to any other format reports what goes.

The element and attribute names come from the OASIS ODF 1.3 RelaxNG schema, and LibreOffice re-saves a file
SwiftSheets wrote with all six still in it.

### ODS: what the conditional formats ride on

ODF 1.3 itself has one condition per cell style (`style:map`) and nothing at all for colour scales, data bars or
icon sets. Everything richer lives in LibreOffice's `calcext:` extension, which is what every current application
reads and writes. SwiftSheets **writes** `calcext:conditional-formats` only, and **reads** both — falling back to
`style:map` for a file that carries no `calcext:` block (a producer older than the extension). All eighteen rule
kinds survive a write and a read back, and LibreOffice rebuilds every one of them when it converts the file to
XLSX. Alongside them: data validations, the print setup (margins, orientation, scaling, headers and footers, page
breaks, print area and repeated title rows), sheet protection, array-formula ranges, named tables and what an
auto-filter lets through, and pivot tables as ODF data pilots. What ODF cannot say — scenarios (an ODF scenario is
a whole shadow sheet), unprotected windows inside a protected sheet, tab colours, formatting runs inside one cell —
is reported, never dropped in silence.

### Numbers: what is and is not there

- Read: every value kind (decimal128 numbers, text, rich text as plain text, dates, booleans, durations, errors),
  formulas rebuilt from Numbers' formula trees into XLSX-dialect text (cross-table references as `'Sheet::Table'!A1`),
  **cell formatting** (fonts, colours, fills, borders, alignment, wrapping) and **number formats**, hyperlinks,
  merges, row heights / column widths, hidden rows / columns, table positions as `Table.anchor`, header rows as
  `freezePanes`.
- Write: the empty document shipped with numbers-parser is the template (spec §11.1); the first sheet / table is
  patched in place, further sheets and tables are deep-copied subgraphs with fresh ids and UUIDs. Values, **cell
  formatting and number formats**, merges, sizes, header rows, **hyperlinks**, **formatting runs inside one cell**,
  **notes**, and **formulas as formula archives** — the tree is turned into the postfix node array Numbers
  evaluates, so a formula written from SwiftSheets is a formula in Numbers and it computes the answer, including
  one that reaches into another table (spec Appendix B.18). What has no example in the corpus is not invented: a
  **defined name**, a **function Numbers does not have**, a range over **whole columns** (`A:C`), and the
  **intersection / union** operators fall back to the cached value with a `degraded` warning naming what stopped it.
- **Conditional formatting** is read and written (spec Appendix B.18). A rule's condition is a `predicate_type`
  integer Apple left unnamed in the Protobuf, so the fourteen values were *observed*: a workbook with one rule kind
  per column, each carrying a parameter no other rule uses, was written as `.xlsx`, imported by Numbers 15.3.1 and
  saved back as `.numbers`, and each surviving rule matched to the column that produced it **by its parameter**.
  The fourteen are the eight comparisons (`>`, `≥`, `<`, `≤`, `=`, `≠`, between, not between), the four text rules
  (contains, does not contain, begins with, ends with), duplicate and unique. Colour scales, data bars, icon sets,
  top-n, above-average, blanks, errors, dates and free formulas are reported as dropped — the same eleven Numbers
  itself drops when it imports an Excel file.
- **A Numbers sheet is a canvas, not a grid.** Charts, images, shapes and text boxes stand on it beside the tables,
  and a cell can carry an interactive control. A **pop-up menu** is a `.list` data validation in the model's
  vocabulary: read back as one, and written out as a real menu when the rule spells its choices (`"a,b,c"`) — the
  same substitution Numbers itself makes in both directions when it imports and exports Excel files. The other
  four controls are `Cell.control` (`CellControl`): a **checkbox**, a **stepper**, a **slider** and a **star
  rating** are read with their dial's bounds and written back as real controls — Numbers, asked cell by cell over
  AppleScript, answers with the control's own name for every one. A control cell always holds a value (Numbers
  itself fills an untouched checkbox with false, a dial with its minimum, a rating with 0, and so does the
  writer). The objects on the canvas have no place in the model: they are reported as `dropped`.
- Everything else Numbers has no word for — range-sourced and numeric validations, named tables, auto-filters,
  sheet protection, scenarios, print setup, defined names, tab colours, outline grouping — is reported as a
  warning, and so is a pivot table beyond the one-field-per-axis shape Numbers pivots are written in. Nothing is
  dropped in silence.
- Judges: round trip through our own reader, numbers-parser reading our output
  (`Tests/NumbersParity/verify_with_numbers_parser.py`), LibreOffice's Numbers importer — and, since 2026-08-25,
  **Numbers.app itself** (`Tests/NumbersParity/verify_with_numbers_app.py`): it opens what we wrote, is asked what
  it sees, and is made to save it again. It earned its place immediately by rejecting a document the other three
  had passed — two defects in the sheet / table copy that only an application reading the package's own table of
  contents could see (Appendix B.18).
- Protobuf is handled by a dependency-free dynamic tree (`ProtoMessage`) driven by a machine-extracted schema;
  unknown fields round-trip byte for byte (`NumbersIWATests.fixturesRoundTripByteForByte`).

## Targets

| product | contents | depends on |
|---|---|---|
| `SheetCore` | `Workbook` → `Sheets` → `Sheet` → `[Table]` → `Cell` model, styles and differential styles, conditional formatting, named tables, pivot tables, protection and scenarios, `FormulaExpr` AST + parser / emitters (XLSX and ODS dialects), the `SpreadsheetCodec` contract, `PreservationStore`, ZIP / XML plumbing, CSV options | nothing |
| `SheetXLSX` | `XLSXCodec` / `XLSMCodec`, `StreamingReader` / `StreamingWriter` | SheetCore |
| `SheetCSV` | `CSVCodec` (RFC 4180 + real-world dialects; UTF-8 BOM auto-detection, explicit encodings) | SheetCore |
| `SheetODS` | `ODSCodec` (ODF 1.3; mimetype stored first, RLE rows / columns, OpenFormula via the AST's ODS dialect, conditional formats and validations, master pages, data pilots) | SheetCore |
| `SheetNumbers` | `NumbersCodec` (IWA: Snappy + dynamic Protobuf; schema / registry / function table / constants / font map as JSON resources) | SheetCore |
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
| `auto_filter.add_filter_column(...)`, `auto_filter.sortState` | `sheet.filterColumns`, `sheet.sortState` — value lists, comparisons, colour, icon, dynamic, top 10 and whole-month filters. Only the `<extLst>` extensions are kept as source XML (`sheet.hasUnmodelledFilters`) |
| `ws.oddHeader.left.text`, `ws.row_breaks`, `ws.col_breaks` | `sheet.headerFooter` (Excel's `&L`/`&C`/`&R` string, undecomposed), `sheet.rowBreaks`, `sheet.columnBreaks` |
| `ArrayFormula(ref, text)` | `sheet.table.arrayFormulas[anchor] = CellRange("A2:A4")` |
| `cell.value = '=SUM(A1:B2)'` | `sheet["C1"] = Formula("=SUM(A1:B2)")`; `value.formula?.rendered(as: .ods)` |
| `wb.defined_names`, `wb.properties` | `wb.definedNames`, `wb.metadata` |
| `get_column_letter(3)`, `column_index_from_string('C')` | `CellRef.columnName(2)`, `CellRef.columnIndex("C")` (0-based) |
| `openpyxl.utils.datetime`, `units`, `escape`, `is_date_format` | `ExcelDate`, `Units`, `OOXMLEscape`, `NumberFormat` |
| `cell.comment = Comment(text, author)` | `sheet[cell: "A1"].comment = CellNote(text, author:)` — written as the comments part plus its legacy VML |
| `ws.add_data_validation(DataValidation(...))` | `sheet.dataValidations = [.list("'Choices'!$A$2:$A$4", over: MultiCellRange("C4:C99")!)]` — read and written both ways; a rule with an attribute outside the schema keeps the file's own block (`sheet.hasUnmodelledValidations`). `hideDropDown` is named for what the inverted `showDropDown` attribute means |
| `ws.conditional_formatting.add(range, Rule(...))` | `sheet.addConditionalFormatting(.cellIs(.greaterThan, "100", paint: .highlight(fill: red)), over: "B2:B99")` — 17 rule kinds plus colour scales, data bars and icon sets; priorities renumbered 1…n over the sheet |
| `DifferentialStyle(...)`, `wb._differential_styles` | `DifferentialStyle` / `DifferentialFont`, `wb.differentialStyles` — every field optional, nil meaning "leave the cell as it is" |
| `PatternFill` / `GradientFill` | `Fill.pattern(_:)` / `Fill.gradient(_:)`; `.solid(_:)` and `.none` for the everyday cases |
| `ws.tables`, `Table(displayName:ref:)` | `sheet.excelTables`, `sheet.addExcelTable(named:over:)` — the part, its content type, its relationship and `<tableParts>` are all generated |
| `ws.protection`, `wb.security`, `ws.scenarios` | `sheet.protection`, `wb.protection`, `sheet.protectedRanges`, `sheet.scenarios` — named for what is **allowed**, since the file's own booleans say what is forbidden |
| `wb.custom_doc_props` | `wb.customProperties` — text, integers, numbers, booleans, dates and defined-name links (ODS keeps them as `meta:user-defined`) |
| pivot tables (`ws._pivots`) | `sheet.pivotTables`, `wb.addPivotTable(named:to:at:summarizing:on:rows:columns:values:)` — the layout is written, the numbers are not: the cache asks the application to refresh from the source range |
| charts / images | no API — preserved unchanged on a same-format write (F3), listed as `dropped` warnings when converting |
| `read_only` / `write_only` streaming | `StreamingReader(contentsOf:)` + `forEachRow(inSheet:)`, `StreamingWriter(url:sheetName:)` + `append(_:)` / `close()` — XLSX only, values and formatting only (see [Limits](#limits)) |

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
present, and the worksheet children are in schema order.

**Byte-identical applies to what the model does not read.** Charts, VBA, themes, images, drawings — anything the
codec leaves opaque — come out as the same bytes they went in as. What the model *does* read is rebuilt from the
model: conditional formatting, data validation, named tables, pivot tables and differential formats are the same
XML in meaning, not necessarily in bytes. Where an entry is addressed by index from elsewhere (a `dxf`, a
`cellStyleXf`), the source's own entries keep their positions and their original XML, and new ones are appended
after them. What makes it work:

- parts the codec does not interpret stay bytes in `Workbook.preserved` (with their relationships and content types);
- unknown children of `<workbook>`, `<worksheet>` and `<styleSheet>` are kept as XML fragments and re-emitted at their
  schema positions (`Sheet.preserved`);
- existing relationship ids, sheet ids and part paths are immutable — new ones are numbered after the maximum;
- `styles.xml` is rebuilt on top of the source's font / fill / border / numFmt tables so `cellStyleXfs`, `dxfs` and
  `tableStyles` (copied verbatim) keep their indices;
- `calcChain.xml` is always dropped and `fullCalcOnLoad` set, so the application recalculates;
- an element the model reads but cannot fully say — a data validation with a vendor attribute, a conditional format
  with an `<extLst>` — keeps the file's own block instead, and a flag on the sheet says so.

Reading reports its losses the same way writing does: `Workbook.read(contentsOf:)` answers with a `ReadResult`, and
`Workbook(contentsOf:)` leaves the same list on `wb.readWarnings`.

Known limits of the current preservation: `cm` / `vm` rich-value attributes and some `<sheetView>` attributes are not
carried over.

## Design notes

- **Dates have no time zone.** `CivilDate` / `CivilDateTime`, never `Foundation.Date` in the model; `CellValue(Date, in:)` converts explicitly.
- **Numbers keep openpyxl's int / float split.** `.integer(Int)` for integral file text, `.number(Decimal)` otherwise —
  the text of a number survives a round trip and `Decimal` fits Numbers' decimal128 later.
- **Formulas are trees.** Parse failures fall back to `.unparsed(text, dialect:)`, so a same-dialect round trip is
  lossless. The intersection operator is understood in both spellings (Excel's space, OpenFormula's `!`); external
  workbook references (`[1]Sheet!A1`) are carried as text rather than resolved.
- **Element order matters to Excel.** Generated and preserved elements are merged in schema order; the two mandatory
  fills come first; colours are explicit RGB (no theme part is generated — a source theme is preserved).
- **Sendable throughout.** Every model type is a `Sendable` value.

## Development

```bash
swift test                                                                 # model, formulas, preservation, CSV, parity, property, streaming and fuzz suites
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

## How this library is built

SwiftSheets is written with AI assistance — the owner decides and reviews, an AI agent does most of the typing —
and it will go on being built that way. It is said here because you are entitled to know how the code you are
depending on came to exist.

What that changes is nothing about the bar, and one thing about where the bar sits. Correctness here does not rest
on who typed the code; it rests on the same things it would have to rest on anyway:

- **The design is written down before the code.** The spec is revised first, and Appendix B records every
  implementation decision with the reason behind it — including the ones that were measured and then rejected.
- **Independent implementations are the judges.** openpyxl, LibreOffice, numbers-parser and Numbers.app read what
  SwiftSheets writes. A format is not called supported until something that did not come from this project agrees.
- **839 tests**, including a fuzz campaign over every reader, run on every push.
- **Nothing is dropped in silence.** Every read and every write answers with the list of what it could not keep.

The reverse is also true, and worth saying plainly: an AI-written library needs those checks *more* than a
hand-written one, because there is no author whose memory of the tricky parts can be consulted. That is why they
are there, and why a pull request that skips them is not accepted from anyone — see [CONTRIBUTING](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). openpyxl test fixtures are MIT (see `Tests/SwiftSheetsTests/Fixtures/openpyxl/NOTICE.md`).
