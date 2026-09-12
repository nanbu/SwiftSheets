# SwiftSheets

[![CI](https://github.com/nanbu/SwiftSheets/actions/workflows/ci.yml/badge.svg)](https://github.com/nanbu/SwiftSheets/actions/workflows/ci.yml)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%2B%20%7C%20iOS%2017%2B%20%7C%20Linux-1d1d1f)](https://github.com/nanbu/SwiftSheets#limits)
[![License: MIT](https://img.shields.io/badge/License-MIT-248a3d)](https://github.com/nanbu/SwiftSheets/blob/main/LICENSE)

A pure Swift spreadsheet library with **one format-neutral model** and **one codec per file format**. Open an existing
workbook, change what you need, save — charts, pivot caches, VBA and everything else you did not touch come out exactly
as they went in. Foundation only; no package dependencies — bytes are folded by whichever DEFLATE the machine already
has (Apple's Compression framework, or the system zlib). **Swift 6.2+ (Xcode 26+)**, macOS 14+ / iOS 17+, Linux, and WebAssembly (wasm32-wasi, with the swift.org toolchain's Wasm SDK; see the Limits table) —
the same suite runs on all of them, on every push.

The design is written down in [the implementation spec](https://nanbu.github.io/SwiftSheets/implementation-spec.html)
(the spec is revised first, then the code), and what each format carries — measured, not claimed — is in
[the format support table](https://nanbu.github.io/SwiftSheets/format-support.html). The same question from the other
side — every feature each format's own specification names, how far this library carries it, and the API for each — is
[the spec feature matrix](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.html) (196 rows; read and write kept
apart, and also published as [YAML](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.yaml)). All are at
**<https://nanbu.github.io/SwiftSheets/>**.

```swift
import SwiftSheets

var wb = try Workbook(contentsOf: URL(filePath: "monthly-report.xlsx"))   // format detected from the bytes, not the extension
try wb.editSheet(named: "Summary") { sheet in // sheets are value types; this edits one in place — nothing to put back
    sheet["B4"] = 1_380_000                   // Int / Double / Decimal / String / Bool / CivilDate literals and values
    sheet["B5"] = .formula("=B4/B3")          // parsed into an AST; follows row inserts and sheet renames
    sheet.setStyle("A1:D1") { $0.font.bold = true; $0.fill = .solid(Color(hex: "F5F5F7")) }
}                                             // a closure that throws leaves the workbook untouched; a missing name is loud
var sheet = wb.sheets["Summary"]!             // the classic way still works…
sheet["B6"] = "October"
wb.sheets["Summary"] = sheet                  // …value types: copy out, edit, put back
let result = try wb.write(to: URL(filePath: "monthly-report.xlsx"))   // charts, comments, VBA… untouched (F3)
print(result.warnings)                        // whatever the format could not express — never dropped silently
print(wb.readWarnings)                        // …and whatever the file held that the model cannot say
```

Both directions answer with a result — `Workbook.read(contentsOf:)` returns a `ReadResult` (workbook + warnings), and
`wb.write(to:)` a `WriteResult` (bytes + warnings + a suggested format when the losses are serious). The convenience
`Workbook(contentsOf:)` keeps the warnings on `readWarnings`, so nothing is ever dropped in silence.

File writes and conversions warn at compile time if their result is unused. Inspect `result.warnings`, or use
`_ = try wb.write(to: url)` to explicitly ignore the result. A file write has already saved when it returns;
to review losses before saving, call `wb.write(as:)`, inspect the result, then save that same `result.data`
with `try result.data.write(to: url, options: .atomic)`. Include `wb.readWarnings` when reviewing earlier read losses.

For bytes only, use `try wb.write(as: .xlsx).data` (or add `password:` with `SheetEncrypt`).
The former `data(as:)` conveniences have been removed; retain the `WriteResult` to inspect warnings and suggestions.

Convert with `try Workbook.convert(source, to: destination, as: .csv)` or
`try codecs.convert(source, to: destination, as: .csv)`. The format is required, even when the destination has
an extension. The former `to: format, output: destination` labels have been removed.

Writing row by row — for a file with more rows than memory — saves the same way, at the end:

```swift
let result = try CodecSet.all.withStreamingWriter(to: url, as: .xlsx, sheetName: "Sales") { writer in
    try writer.append([.text("Item"), .text("Quantity")])
    for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
}                                             // it returned, so the file is saved; had it thrown, nothing would be
print(result.warnings)
```

The rows go into a temporary file beside the destination, which is replaced only once the file is complete, in every
format. A row that fails, a closure that throws, a writer let go of: whatever was already at that path is untouched.
Opening one by hand still works — `StreamingWriter(to:)`, then `append(_:)`, then `close()`, which returns the same
result and must be called — and `cancel()` throws the rows away.

**Guides.** [Getting started](docs/getting-started.md) takes you from an empty package to a saved file;
the [cookbook](docs/cookbook.md) is thirteen complete recipes that CI compiles and runs (the page is generated
from [`Examples/`](Examples)); [API stability](docs/api-stability.md) says what 1.0 will promise; [migrating to 1.0](docs/migrating-to-1.0.md)
maps every rename since 0.20 to its new name; [llms.txt](llms.txt) is the
short map written for AI coding agents.

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nanbu/SwiftSheets.git", from: "0.27.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])   // or SheetCore / SheetXLSX / SheetCSV
]
```

**Only some formats.** An app that links, say, `SheetXLSX`, `SheetODS` and `SheetNumbers` — no CSV, no umbrella — has
the same entry points the umbrella has: open, inspect before reading, write, convert, read and write row by row. They
are methods of a `CodecSet` of the codecs it links; the umbrella's `Workbook(contentsOf:)` and friends are
`CodecSet.all`'s under older names. A file of a format the set lacks is refused by name, with the product to link
(spec Appendix B.44). A format is named by the `Codec` value its product publishes — `.xlsx` and `.xlsm` come with
`SheetXLSX`, `.ods` with `SheetODS`, `.numbers` with `SheetNumbers`, `.csv` with `SheetCSV` — so a format whose
product an app does not link is a compile error at the line that names it, not a surprise at run time (B.50).

```swift
import SheetCore   // and SheetXLSX, SheetODS, SheetNumbers
let codecs = CodecSet([.xlsx, .xlsm, .ods, .numbers])
let summary = try codecs.inspect(contentsOf: url)        // sheets and declared cells, before any cell is read
let workbook = try codecs.read(contentsOf: url).workbook
let reader = try codecs.streamingReader(contentsOf: url)
```

**Encryption code.** The SwiftSheets, SheetCore, SheetXLSX, SheetODS, SheetCSV and SheetNumbers products contain no
encryption code (hash functions only, for sheet-protection password checks). Decrypting protected files lives solely
in `SheetDecrypt`, which contains no encryption (writing) code; encrypting lives solely in `SheetEncrypt`. An app that
links only the plain products can declare that it carries no cipher, and one that adds `SheetDecrypt` that it only
decrypts; CI reads both promises off the symbol tables on every push (`scripts/check-no-crypto.sh`, spec Appendix
B.39.9).

Status: **0.27.0** — all five formats are usable; the API may still change before 1.0. What changed in each release
is in [CHANGELOG.md](CHANGELOG.md). The version here is what the library writes into the files it generates, and a
test keeps the constant, this line and the pin above in step.

## Limits

Worth knowing before you point this at a very large or a very strange file. None of them is silent: a file that goes
past a limit comes back with a `degraded` warning, and a file that breaks a rule throws.

| | |
|---|---|
| Whole workbook in memory | `Workbook` holds every cell: reckon on 100–200 bytes each, so a million cells is a few hundred megabytes — the working size, not the file size. `StreamingReader` walks a file of any format row by row instead — XLSX, ODS, Numbers and delimited text through one call — and `StreamingWriter` writes the same way in every format: measured at 100 columns × 10,000 rows, a million cells ([the performance record](https://nanbu.github.io/SwiftSheets/performance.html) has the machine, the date, every other number, and the same operations at 100,000 rows — ten million cells), writing peaks at **11 MB** for XLSX and **22 MB** for ODS (its one part puts the styles before the rows, so the rows wait on disk until the end) whatever the row count, and at **26 MB** for Numbers (its string list, which grows with the distinct strings: 62 MB at ten million cells); reading peaks at **13 MB** for XLSX (most of it the shared-string table, which every reader must hold), **14 MB** for ODS and **25 MB** for Numbers (its string list and index). The reader holds one expanded piece of at most a mebibyte and reads the file in place rather than mapping it, so none of this grows with the file: at ten million cells ODS is still 16 MB, and what XLSX (35 MB) and Numbers (61 MB) add is the strings they must hold — against **216 MB** for the whole model. They carry values and formatting and nothing else — no merges, no notes, no preservation. A workbook of several sheets is parsed side by side when it is large enough — the same million cells in eight sheets: **232 MB** and 0.7 s against **141 MB** and 1.4 s one sheet at a time — and `ReadOptions.concurrency` caps or disables it, which also caps what it adds in memory. |
| Cell budget | None by default. A read holds every cell it finds; set `ReadOptions.cellLimit` for input you do not trust, and reading stops there with a `truncated` warning naming the sheet — in XLSX, ODS, Numbers and delimited text alike, with one budget for the workbook even when its sheets are parsed side by side. ODS run-length compression can describe seventeen billion cells in a kilobyte of XML, and an XLSX or Numbers package inside the package limits can still hold hundreds of millions. The row-by-row readers hold no cells and ignore it. |
| Formula nesting | 64 levels, Excel's own limit. Deeper formulas are kept verbatim and written back unchanged, but they do not follow row inserts and are not translated between dialects. |
| Hostile packages | What a package declares about itself is bounded before any of it is expanded: at most 100,000 parts, 16 GiB expanded in total, a thousandfold expansion for any part over 16 MiB, and no two parts sharing bytes. Past any of these the file is reported as `corruptedContainer`; `ReadOptions.limits` raises them for a package you know. ZIP64 (parts past 4 GB, more than 65,535 parts) is read and written. |
| WebAssembly | Builds and runs under WASI (wasm32-wasi) with the swift.org toolchain and its Wasm SDK of the same version — Xcode's Swift has no WebAssembly backend. WASI has no zlib, so DEFLATE there is a pure Swift route: reading is a complete inflater, writing is stored blocks (valid DEFLATE that compresses nothing, so files are larger). One thread: the XLSX sheets are read one after another. The Numbers codec's schema and template are read from a directory the host mounts at `/SwiftSheets_SheetNumbers.resources/`. Verified with node's WASI and in a browser (spec Appendix B.45); not part of CI. Writing a file row by row is refused there (`unsupportedFeature`): that save renames a temporary file over the destination, and the rename has not been run under a WASI runtime (spec Appendix B.51). Writing a workbook whole is unaffected. |
| visionOS | Not built or tested. Nothing in the library is Apple-only any more — DEFLATE comes from the system zlib where Apple's Compression framework is absent, and the hashes (SHA-512 for sheet protection) are written out rather than taken from CryptoKit, as is the cipher in the separate `SheetDecrypt` / `SheetEncrypt` products — but a platform nobody runs the suite on is not a platform this README claims (spec Appendix B.1). Linux is claimed because CI runs the whole suite there on every push. |
| Encrypted files | Recognised and refused by name by the plain products, which contain no cipher: a protected file read there throws `unopenable(.encryptedOOXML)` (or `.encryptedODF`, `.encryptedNumbers`) saying it is encrypted and, in the message, that `SheetDecrypt` opens it. Opening one is the `SheetDecrypt` product — `Workbook(contentsOf:password:)`, `StreamingReader(contentsOf:password:)`, or `SheetDecrypt.decrypt` for the plain package — for Excel's agile encryption (AES-256, SHA-512 — what Excel 2010 and later write) and ODF 1.2 / 1.3 package encryption (AES-CBC, PBKDF2 — what LibreOffice writes); a wrong password throws `wrongPassword`. Protecting one is the `SheetEncrypt` product — `wb.write(to:password:)` or `SheetEncrypt.encrypt`. Excel 2007's older "standard" encryption and ODF 1.1's Blowfish form are refused with `unsupportedEncryption` — a password cannot open them, so asking again does not help; a password-protected Numbers document and a legacy `.xls` are refused as `unopenable`. A format the `CodecSet` has no codec for is `noCodec(for:)`, which carries the format and, through `SheetFormat.productName`, the product to link. |

## Formats

| format | read | write | round-trip preservation | status |
|---|---|---|---|---|
| XLSX | ✅ | ✅ | ✅ F3 — uninterpreted parts re-packed byte for byte, ids kept | P1 done |
| XLSM | ✅ | ✅ | ✅ VBA kept as opaque bytes (never run); dropped with a warning when writing .xlsx | P2 done |
| CSV / TSV | ✅ | ✅ | — (values only by definition) | P1 done |
| ODS | ✅ | ✅ | F2 — values, formulas, styles, conditional formats, validations, print setup, tables, filters, pivots, merges, sizes, the six things only ODF has, pictures and charts (read from a source ODS and written back as fresh parts; embedded objects other than charts are carried unlinked) | P3 done |
| Numbers | ✅ values, formulas (as text, cross-table references included), cell formatting, number formats, conditional formats, pop-up menus as list validations, cell controls (checkbox, stepper, slider, rating), hyperlinks, formatting runs, notes, merges, sizes, several tables per sheet | ✅ values, formulas, cell formatting, number formats, conditional formats, inline-list validations as pop-up menus, cell controls, pivot tables (several fields per axis, one summarised value), hyperlinks, formatting runs, notes, merges, sizes, several sheets / tables (template patch) | — (every write starts from the template) | P4 / P5 done, with cuts (below) |

`SheetFormat.detect(_:)` identifies all five from content, and `SheetFormat.detect(contentsOf:)` does the same for a file without reading it — the first four bytes, the ZIP directory at the end and one small entry, whatever the file's size. `SheetFormat.probe` answers in one call whether a file is a spreadsheet, something the library recognises but will not open (encrypted, or a legacy `.xls`) and why, or nothing it knows. A Numbers document saved as a folder opens like its single-file twin. Numbers support is reverse-engineered (no public
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
a whole shadow sheet), unprotected windows inside a protected sheet, formatting runs inside one cell —
is reported, never dropped in silence.

### Numbers: what is and is not there

- Read: every value kind (decimal128 numbers, text, rich text as plain text, dates, booleans, durations, errors),
  formulas rebuilt from Numbers' formula trees into XLSX-dialect text (cross-table references as `'Sheet::Table'!A1`),
  array-formula spreads read back as the anchor's formula plus its `arrayFormulas` range,
  **cell formatting** (fonts, colours, fills, borders, alignment, wrapping) and **number formats**, hyperlinks,
  merges, row heights / column widths, hidden rows / columns — the rows a **Numbers filter** hides included
  (the filter's rules are dropped out loud, the same trade Numbers itself makes when it exports to Excel) —
  table positions as `Table.anchor`, header rows as `freezePanes`. A **category grouping** comes back as the
  flat rows plus a warning naming the grouped columns; a **stock-quote cell** is a plain `STOCK` formula in
  current Numbers and reads as one (spec Appendix B.29).
- Write: the empty document shipped with numbers-parser is the template (spec §11.1); the first sheet / table is
  patched in place, further sheets and tables are deep-copied subgraphs with fresh ids and UUIDs. Values, **cell
  formatting and number formats**, merges, sizes, header rows, **hyperlinks**, **formatting runs inside one cell**,
  **notes**, and **formulas as formula archives** — the tree is turned into the postfix node array Numbers
  evaluates, so a formula written from SwiftSheets is a formula in Numbers and it computes the answer, including
  one that reaches into another table (spec Appendix B.18). What has no example in the corpus is not invented: a
  **defined name**, a **function Numbers does not have**, a range over **whole columns** (`A:C`), and the
  **intersection / union** operators fall back to the cached value with a `degraded` warning naming what stopped it.
- The **quote functions** (`STOCK`, `STOCKH`, `CURRENCY`, `CURRENCYH`, `CURRENCYCONVERT`, `CURRENCYCODE`) round-trip
  with Numbers — written as formulas, fetched anew when the document opens. Excel and OpenFormula have no spelling
  for them, so those writers put the fetched value in the formula's place and say so, the same substitution Numbers
  itself applies when it exports to Excel (spec Appendix B.27).
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
  writer). Pictures, shapes and text boxes on the canvas are read into `sheet.images` / `sheet.shapes` and written
  back as canvas objects at a point (a cell anchor is placed against the first table); a shape other than a
  rectangle is drawn as one and said so. Charts are read from and written to the canvas too — kind, title, legend
  and each series' ranges, through the chart's own formulas — and Numbers exports the written chart to Excel
  intact. A table stands at an exact point (`Table.position`). Movies and groups have no place in the model and
  are reported.
- Everything else Numbers has no word for — range-sourced and numeric validations, named tables, auto-filters,
  sheet protection, scenarios, the print area, title rows and page breaks (orientation, margins, scale and the
  header / footer are carried), defined names, tab colours, outline grouping — is reported as a
  warning, and so is the second and every further summarised value of a pivot table (the value lanes of a rebuilt
  Numbers pivot share one placeholder id, so only the first survives the trip — spec Appendix B.28). Nothing is
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
| `SheetCore` | `Workbook` → `Sheets` → `Sheet` → `[Table]` → `Cell` model, styles and differential styles, conditional formatting, named tables, pivot tables, protection and scenarios, `FormulaExpr` AST + parser / emitters (XLSX and ODS dialects), ZIP / XML plumbing, CSV options — and `CodecSet`, the facade over whichever codecs an app links, chosen by `Codec` value (`read`, `inspect`, `write`, `convert`, `streamingReader`, `streamingWriter`), with `StreamingReader` / `StreamingWriter`, the one shape rows come in and go out | nothing |
| `SheetXLSX` | `Codec.xlsx` / `Codec.xlsm` — Excel's workbook and its macro-enabled form, read, written and walked row by row through `CodecSet` | SheetCore |
| `SheetCSV` | `Codec.csv` — RFC 4180 + real-world dialects; UTF-8 BOM auto-detection, explicit encodings | SheetCore |
| `SheetODS` | `Codec.ods` — ODF 1.3; mimetype stored first, RLE rows / columns, OpenFormula via the AST's ODS dialect, conditional formats and validations, master pages, data pilots | SheetCore |
| `SheetNumbers` | `Codec.numbers` — IWA: Snappy + dynamic Protobuf; schema / registry / function table / constants / font map as JSON resources | SheetCore |
| `SwiftSheets` | everything: `CodecSet.all` and its conveniences — `Workbook(contentsOf:)`, `Workbook.inspect`, `write(to:as:)`, `write(as:)`, `Workbook.convert`, `StreamingReader(contentsOf:)` / `StreamingWriter(to:)` for any format | all of the above |
| `SheetDecrypt` | `decrypt(_:password:)` and `Workbook(contentsOf:password:)` / `Workbook.inspect(…password:)` / `StreamingReader(contentsOf:password:)`: AES's inverse cipher, key derivation, the compound file's reader, the OOXML / ODF package forms opened. No encryption (writing) code | SwiftSheets |
| `SheetEncrypt` | `encrypt(_:as:password:)` and `wb.write(to:password:)` / `write(as:password:)`: the cipher, salts, the compound file written. Re-exports SheetDecrypt | SheetDecrypt |

## Model in one paragraph

Everything is a value type. `Workbook.sheets` is a collection addressable by index or name; a `Sheet` holds one or
more `Table`s (exactly one for XLSX / ODS — the sheet forwards the whole cell API to it, so `tables` only matters for
Numbers later). A `Cell` is a `CellValue?` plus `CellStyle`, hyperlink and note. Integer coordinates are the numbers
the sheet shows: `CellRef(row: 1, column: 2)` and `sheet[1, 2]` are B1, exactly as `"B1"` is. Only positions in
Swift collections (`workbook.sheets[0]`, the arrays `rows(in:)` returns) count from 0. Values carry meaning, never representation:
`.text`, `.integer`, `.number(Decimal)`, `.bool`, `.date(CivilDateTime)` (no time zone), `.time`, `.duration`,
`.formula(FormulaExpr, cached:)`, `.error`, `.richText`.

## openpyxl ↔ SwiftSheets

openpyxl is the behavioural reference: the same file read by both yields the same values and types, rich text is
exposed as runs, 1900 / 1904 epochs and the phantom 1900-02-29 behave the same (one deliberate step past it: `<rPh>`
furigana, which openpyxl skips, is read and written as `Cell.phonetic`). The API is
Swift's: value types, `throws` for failure, warnings for degradation, typed values.

| openpyxl | SwiftSheets |
|---|---|
| `load_workbook(path)` / `data_only=True` | `Workbook(contentsOf:)` / `ReadOptions(formulaCells: .cachedValues)`; `Workbook.read(contentsOf:)` for the warnings too |
| (no equivalent) | `Workbook.inspect(contentsOf:)` — the sheets, how many cells each declares, what the package expands to and who wrote it, before any cell is read; `InspectOptions(countsCells: true)` counts what is really there. How to choose a `ReadOptions.cellLimit` for a file you do not trust |
| `keep_vba=True` | not needed — VBA is always preserved |
| `Workbook()`, `wb.save(path)` | `Workbook()`, `wb.write(to:)` → `WriteResult` (inspect its warnings) |
| `wb.sheetnames`, `wb['Sales']`, `wb.active` | `wb.sheetNames`, `wb.sheets["Sales"]`, `wb.activeSheet` |
| `create_sheet`, `remove`, `copy_worksheet`, `move_sheet` | `addSheet(named:at:)`, `removeSheet(named:)`, `duplicateSheet(named:as:)`, `moveSheet(named:to:)` |
| (no equivalent — reference types have no write-back to forget) | `wb.editSheet(named: "Sales") { sheet in … }` — scoped editing: applied when the closure returns, discarded whole when it throws, `SheetError.sheetNotFound` when the name is absent |
| `ws.title = 'New'` | `wb.sheets[0].name = "New"` (formulas referring to the sheet follow) |
| `ws['A1'].value`, `ws['A1'] = 42`, `ws.cell(row=1, column=2)` | `sheet["A1"]`, `sheet["A1"] = 42`, `sheet[1, 2]` |
| `cell.font = Font(bold=True)` | `sheet.setStyle("A1") { $0.font.bold = true }` or `sheet[cell: "A1"].font.bold = true` |
| `wb.add_named_style(NamedStyle(...))`, `cell.style = 'Title'` | `wb.addNamedStyle(NamedStyle(...))`, `sheet[cell: "A1"].style = style.applied` (`CellStyle.namedStyle` is the link) |
| `ws.iter_rows(values_only=True)`, `ws.values` | `sheet.rows(in: "A2:D100")` |
| `ws['A1':'C3']` | `sheet.range("A1:C3")` — a lazy view: rows on demand, cells shared, nothing materialised |
| `ws.append([...])` | `sheet.append([...])` |
| `ws.max_row` | `sheet.extent` (`CellRange?`, nil when empty) / `sheet.rowCount` |
| `insert_rows`, `delete_rows`, `insert_cols`, `delete_cols` | `insertRows(at:count:)`, … — formula references follow (openpyxl's do not) |
| `merge_cells`, `unmerge_cells`, `merged_cells.ranges` | `merge(_:)`, `unmerge(_:)`, `merges` |
| `column_dimensions['A'].width = 18`, `row_dimensions[1].height = 24` | `setWidth(18, ofColumn: "A")`, `setHeight(24, ofRow: 0)`. `autofitColumns()` sizes columns to their content (XlsxWriter's width table; East Asian text measured double) — openpyxl has no autofit |
| `freeze_panes`, `auto_filter.ref`, print titles / area, page setup | `freezePanes` (`CellRef?`), `autoFilter`, `printTitleRows`, `printArea`, `pageSetup`, … |
| `auto_filter.add_filter_column(...)`, `auto_filter.sortState` | `sheet.filterColumns`, `sheet.sortState` — value lists, comparisons, colour, icon, dynamic, top 10 and whole-month filters. Only the `<extLst>` extensions are kept as source XML (`sheet.hasUnmodelledFilters`) |
| `ws.oddHeader.left.text`, `ws.row_breaks`, `ws.col_breaks` | `sheet.headerFooter` (Excel's `&L`/`&C`/`&R` string, undecomposed), `sheet.rowBreaks`, `sheet.columnBreaks` |
| `ArrayFormula(ref, text)` | `sheet.table.arrayFormulas[anchor] = CellRange("A2:A4")` |
| `cell.value = '=SUM(A1:B2)'` | `sheet["C1"] = .formula("=SUM(A1:B2)")`; `value.formula?.rendered(as: .ods)` |
| `wb.defined_names`, `wb.properties` | `wb.definedNames`, `wb.metadata` |
| `get_column_letter(3)`, `column_index_from_string('C')` | `CellRef.columnName(3)`, `CellRef.columnIndex("C")` (1 = A) |
| `openpyxl.utils.datetime`, `is_date_format` | `CellValue(serial:epoch:)` / `.serial(epoch:)` / `CellValue(iso8601:)` / `.iso8601`, `NumberFormat` |
| `cell.comment = Comment(text, author)` | `sheet[cell: "A1"].note = CellNote(text, author:)` — written as the comments part plus its legacy VML |
| `ws.add_data_validation(DataValidation(...))` | `sheet.dataValidations = [.list("'Choices'!$A$2:$A$4", over: MultiCellRange("C4:C99")!)]`, or `.list(choices: ["Todo", "Doing", "Done"], over:)` for the choices themselves (nil when they cannot be an inline list) — read and written both ways; a rule with an attribute outside the schema keeps the file's own block (`sheet.hasUnmodelledValidations`). `hidesDropDown` is named for what the inverted `showDropDown` attribute means |
| `ws.conditional_formatting.add(range, Rule(...))` | `sheet.addConditionalFormatting(.cellIs(.greaterThan, "100", paint: .highlight(fill: red)), over: "B2:B99")` — 17 rule kinds plus colour scales, data bars and icon sets; priorities renumbered 1…n over the sheet |
| `DifferentialStyle(...)`, `wb._differential_styles` | `DifferentialStyle` / `DifferentialFont`, `wb.differentialStyles` — every field optional, nil meaning "leave the cell as it is" |
| `PatternFill` / `GradientFill` | `Fill.pattern(_:)` / `Fill.gradient(_:)`; `.solid(_:)` and `.none` for the everyday cases |
| `ws.tables`, `Table(displayName:ref:)` | `sheet.structuredTables`, `sheet.addStructuredTable(named:over:)` — the part, its content type, its relationship and `<tableParts>` are all generated |
| `ws.protection`, `wb.security`, `ws.scenarios` | `sheet.protection`, `wb.protection`, `sheet.protectedRanges`, `sheet.scenarios` — named for what is **allowed**, since the file's own booleans say what is forbidden. `setModernPassword(_:)` generates the SHA-512 hash Excel 2010+ verifies (the legacy 16-bit hash stays on `setPassword(_:)`) |
| `wb.custom_doc_props` | `wb.customProperties` — text, integers, numbers, booleans, dates and defined-name links (ODS keeps them as `meta:user-defined`) |
| `load_workbook(path)` on a protected file (openpyxl cannot; msoffcrypto-tool decrypts first) | `Workbook(contentsOf: url, password: "…")` with `import SheetDecrypt` / `wb.write(to: url, password: "…")` with `import SheetEncrypt` — XLSX / XLSM as Excel's agile encryption, ODS as ODF package encryption; the plain products refuse a protected file by name; judged by msoffcrypto-tool and an independent ODF decryptor |
| pivot tables (`ws._pivots`) | `sheet.pivotTables`, `wb.addPivotTable(named:to:at:summarizing:on:rows:columns:values:)` — the layout is written, the numbers are not: the cache asks the application to refresh from the source range |
| `ws.add_image(Image(path), 'B2')` | `sheet.addImage(try SheetImage(data:), at: "B2", sizing: .resizeCellToFit)` / `addImage(_:over: "B2:D6")` — PNG / JPEG / GIF, format and pixel size read from the bytes; a sheet that already carries a drawing (a chart) gets the anchors spliced in, everything there staying byte for byte. Charts: `sheet.addChart(Chart(.column), over: "D2:K16")` — column / bar / line / pie with series, title and legend (`chart.addSeries(values: "B2:B13", categories: "A2:A13", name:)`; unqualified ranges gain the sheet name and absolute dollars). Other kinds and charts already in a file: preserved unchanged (F3), `dropped` warnings when converting. Shapes and text boxes: `sheet.addShape(Shape(.rightArrow), over: "F2:H4")`, `sheet.addTextBox("note", over: "B8:E10")` — a preset geometry with text, one font, a fill and an outline, read from and written into XLSX and ODS |
| `read_only` / `write_only` streaming | `StreamingReader(contentsOf:)` + `forEachRow(inSheet:)` or `for try await row in reader.rows(inSheet:)` — one reader for XLSX, ODS, Numbers and delimited text, the format detected from the bytes; a Numbers sheet's second and later tables by `table:`. Values and formatting only (see [Limits](#limits)). `CodecSet.all.withStreamingWriter(to:as:) { writer in … }` writes the same way — XLSX, ODS, Numbers or delimited text, the format from the path's extension or `as:` — and the destination is replaced only when the file is complete, so a failed write leaves it as it was. `StreamingWriter(to:sheetName:)` + `append(_:)` / `close()` opens one by hand; the result of `close()` says what the format could not carry |
| (no equivalent) | `ReadOptions(concurrency: 1)` — read the sheets of an XLSX workbook one at a time; left unsaid, a workbook of two or more sheets whose parts expand to 4 MiB or more is parsed side by side, up to one sheet per core, and `concurrency: n` caps it at `n`. The cap is also the ceiling on the memory a side-by-side read adds |
| `load_workbook(path, read_only=True)` then one sheet | `ReadOptions(sheets: .named(["Summary"]))` — only the named sheets are parsed; an XLSX sheet left out is carried as the bytes it arrived in and written back unchanged, an ODS / Numbers one comes back empty and the write says so |

### openpyxl test parity

openpyxl 3.1.5's test suite (1,711 functions) is tracked test by test in
[`Tests/OpenpyxlParity/parity.json`](Tests/OpenpyxlParity/parity.json) — `ported`, `adapted`, `na_api` or `na_python`,
each with a reason. Ported Swift tests carry `// openpyxl: <file>::<test>`; `check.py` cross-checks the ledger against
them, and `verify_with_openpyxl.py` writes with SwiftSheets and reads with openpyxl (and back). openpyxl's fixture files
are used where they apply (`Tests/SwiftSheetsTests/Fixtures/openpyxl`, MIT).

## Round-trip preservation (F3)

`workbook.preservationSummary` is a read-only snapshot of `sourceFormat`, `opaquePartCount` and
`hasVBAProject`, obtained without expanding any parts. The count excludes XML fragments and modelled objects;
it is not a complete inventory or a promise about what a target format can retain. Use the write result's
warnings for conversion losses. Raw parts, XML, relationships and source style tables are package-internal;
there is no public replacement for editing or deleting individual preserved parts.

`sheet.contentState` distinguishes `.grid` (including new and empty sheets), `.unread` (a worksheet excluded by
`ReadOptions.sheets`) and `.nonGrid` (for example, a chart sheet). It follows the sheet through renaming and
moving, independently of `sheet.state` (visibility). Adding cells does not clear `.unread` or `.nonGrid`; the
existing write-back warnings still apply. `.grid` does not promise a complete read: check
`workbook.readWarnings` for limits and other losses. A chart sheet left out of the selection stays `.nonGrid` —
the workbook relationship names its kind, so nothing has to be parsed to know it. `duplicateSheet` gives the
copy its own preservation, so duplicating an unread or non-grid sheet yields a plain `.grid` holding the cells
the model had; the source bytes are written once, under the original sheet.


The first test of the project (`PreservationTests.editOneCellKeepsEverythingElse`) opens a workbook with a chart, a
table, conditional formatting, data validation, comments and a defined name, edits one cell, saves, and checks that
every opaque part is byte-identical, every `r:id` still resolves, `[Content_Types].xml` declares exactly the parts
present, and the worksheet children are in schema order.

**Byte-identical applies to what the model does not read, and to what it read but did not change.** VBA, SmartArt,
the theme — anything the codec leaves opaque — comes out as the same bytes; so do a sheet's pictures, charts, shapes
and text boxes, which are read into `sheet.images` / `sheet.charts` / `sheet.shapes` (spec Appendices B.72, B.75) and
re-packed byte for byte until one of them is changed or removed, when the drawing is rebuilt from the model and
whatever it held that the model cannot say (SmartArt, a group of shapes) is reported as dropped. Charts, VBA, themes, images, drawings — anything the
codec leaves opaque — come out as the same bytes they went in as. What the model *does* read is rebuilt from the
model: conditional formatting, data validation, named tables, pivot tables and differential formats are the same
XML in meaning, not necessarily in bytes. Where an entry is addressed by index from elsewhere (a `dxf`, a
`cellStyleXf`), the source's own entries keep their positions and their original XML, and new ones are appended
after them. What makes it work:

- parts the codec does not interpret stay bytes in the package-internal `Workbook.preserved` (with their relationships and content types);
- unknown children of `<workbook>`, `<worksheet>` and `<styleSheet>` are kept as XML fragments and re-emitted at their
  schema positions (the package-internal `Sheet.preserved`);
- existing relationship ids, sheet ids and part paths are immutable — new ones are numbered after the maximum;
- `styles.xml` is rebuilt on top of the source's font / fill / border / numFmt tables so `cellStyleXfs`, `dxfs` and
  `tableStyles` (copied verbatim) keep their indices;
- `calcChain.xml` is always dropped and `fullCalcOnLoad` set, so the application recalculates;
- an element the model reads but cannot fully say — a data validation with a vendor attribute, a conditional format
  with an `<extLst>` — keeps the file's own block instead, and a flag on the sheet says so.

Reading reports its losses the same way writing does: `Workbook.read(contentsOf:)` answers with a `ReadResult`, and
`Workbook(contentsOf:)` leaves the same list on `wb.readWarnings`.

Known limits of the current preservation: `cm` / `vm` rich-value attributes and a few `<sheetView>` attributes
(`showFormulas`, `colorId`, the per-kind zoom scales) are not carried over.

## Design notes

- **Dates have no time zone.** `CivilDate` / `CivilDateTime`, never `Foundation.Date` in the model; `CellValue(Date, in:)` converts explicitly.
- **Numbers keep openpyxl's int / float split.** `.integer(Int)` for integral file text, `.number(Decimal)` otherwise —
  the text of a number survives a round trip and `Decimal` fits Numbers' decimal128 later.
- **Formulas are trees.** Parse failures fall back to `.unparsed(text, dialect:)`, so a same-dialect round trip is
  lossless. The intersection operator is understood in both spellings (Excel's space, OpenFormula's `!`); external
  workbook references (`[1]Sheet!A1`) are carried as text rather than resolved.
- **Element order matters to Excel.** Generated and preserved elements are merged in schema order; the two mandatory
  fills come first; a source theme is preserved as bytes until `wb.theme` is changed, and a new workbook's theme part
  is generated from `wb.theme` (Excel's Office theme when nil). `wb.rgb(of:)` resolves a theme or indexed colour to
  RGB, and the ODS and Numbers writers draw that RGB rather than defaulting to black.
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
python3 Tests/ExcelParity/verify_with_excel_app.py                         # Excel itself unlocks what SwiftSheets locked (Appendix B.31)
python3 scripts/extract-numbers-schema.py                                 # regenerate the Numbers schema resources from numbers-parser
python3 scripts/build-spec-feature-matrix.py                              # rebuild docs/spec-feature-matrix.{html,yaml} from scripts/spec-feature-matrix.json (--check in CI)
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
- **1,200+ tests**, including a fuzz campaign over every reader, run on every push — a test keeps this floor
  within a hundred of the count.
- **Nothing is dropped in silence.** Every read and every write answers with the list of what it could not keep.

The reverse is also true, and worth saying plainly: an AI-written library needs those checks *more* than a
hand-written one, because there is no author whose memory of the tricky parts can be consulted. That is why they
are there, and why a pull request that skips them is not accepted from anyone — see [CONTRIBUTING](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). openpyxl test fixtures are MIT (see `Tests/SwiftSheetsTests/Fixtures/openpyxl/NOTICE.md`).
