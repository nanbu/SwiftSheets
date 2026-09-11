# Getting started with SwiftSheets

SwiftSheets reads and writes XLSX, XLSM, CSV / TSV, ODS and Apple Numbers through **one format-neutral model**:
a `Workbook` of `Sheet`s of cells. Open a file, change what you need, save — everything you did not touch comes
out as it went in. This page gets you from an empty package to a saved file in ten minutes; the
[cookbook](cookbook.md) has thirteen complete, compiled recipes for what comes next.

## 1. Add the package

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/nanbu/SwiftSheets.git", from: "0.26.0")
],
targets: [
    .target(name: "App", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])
]
```

`SwiftSheets` is the umbrella: every format, and the `Workbook(contentsOf:)` conveniences. An app that wants only
some formats links `SheetCore` plus the codecs it needs (`SheetXLSX`, `SheetCSV`, `SheetODS`, `SheetNumbers`)
and uses a `CodecSet` — see [Link only the formats you need](cookbook.md#link-only-the-formats-you-need).
Password-protected files are the separate `SheetDecrypt` / `SheetEncrypt` products, so the plain products carry
no cipher.

Requirements: Swift 6.2 (Xcode 26), macOS 14+ / iOS 17+ / Linux. No package dependencies.

## 2. Open, read, edit, save

```swift
import SwiftSheets

var workbook = try Workbook(contentsOf: URL(filePath: "monthly-report.xlsx"))   // format detected from the bytes

let summary = workbook.sheets["Summary"]!          // sheets by name or index; value types
print(summary["B3"])                               // CellValue? — .integer(1500000)
print(summary["B3"]?.numberValue)                  // Decimal? — works for integers, numbers and cached formulas
print(summary.rows(in: "A1:B5"))                   // [[CellValue?]]

try workbook.editSheet(named: "Summary") { sheet in   // edits in place; a throw leaves the workbook untouched
    sheet["B4"] = 1_380_000
    sheet["B5"] = .formula("=B4/B3")
    sheet["A7"] = "Updated"
    sheet.setStyle("A1:B1") { $0.font.bold = true }
}

let result = try workbook.write(to: URL(filePath: "monthly-report.xlsx"))
print(result.warnings)                             // what the format could not carry — never dropped in silence
```

Three things to know about the model:

- **Coordinates are the numbers the sheet shows.** `sheet["B3"]`, `sheet[3, 2]` and `sheet[CellRef(row: 3, column: 2)]`
  are the same cell. Only positions in Swift collections (`workbook.sheets[0]`, the arrays `rows(in:)` returns)
  count from 0.
- **Values carry meaning, not representation.** `.text`, `.integer`, `.number(Decimal)`, `.bool`, `.date(CivilDateTime)`
  (no time zone), `.time`, `.duration`, `.formula(FormulaExpr, cached:)`, `.error`, `.richText`. Literals work:
  `sheet["A1"] = 42`, `= "text"`, `= true`, `= 3.5`.
- **Everything is a value type and `Sendable`.** Copy a sheet out, edit it, put it back — or use `editSheet` and
  skip the putting back.

## 3. Create a file from nothing

```swift
var workbook = Workbook()                          // one empty sheet, "Sheet1"
workbook.sheets[0].name = "Sales"
workbook.editSheet(at: 0) { sheet in
    sheet.append(["Region", "Units"])              // rows go under the last row
    sheet.append(["North", 120])
    sheet.append(["South", 95])
    sheet["B4"] = .formula("=SUM(B2:B3)")
    sheet.setStyle("B2:B4") { $0.numberFormat = "#,##0" }
    sheet.freezePanes = CellRef("A2")
    sheet.autofitColumns()
}
_ = try workbook.write(to: URL(filePath: "sales.ods"))   // the extension picks the format; or write(to:as:)
```

## 4. Convert between formats

```swift
let result = try Workbook.convert(URL(filePath: "in.xlsx"), to: URL(filePath: "out.ods"), as: .ods)
for warning in result.warnings { print(warning) }   // e.g. a feature Excel has and ODS has not
```

Or write to bytes and decide afterwards: `let r = try workbook.write(as: .numbers)`, then look at `r.warnings` and
`r.suggestion` (set when the losses are serious and another format would carry more) before saving `r.data`.
The [interoperability guide](https://nanbu.github.io/SwiftSheets/interoperability.html) shows what happens to
each format's own features in every direction.

## 5. Warnings and errors

Two channels, on purpose:

| what | how it reaches you |
|---|---|
| The file could not be opened, or a rule was broken | a thrown `SheetError` — `unrecognizedFormat`, `corruptedContainer`, `malformedPart`, `unopenable(.encryptedOOXML …)`, `noCodec(for:)`, `sheetNotFound`, `wrongPassword` … |
| The file opened, but something could not be kept | `ConversionWarning`s on the result: `ReadResult.warnings` (or `workbook.readWarnings` after `Workbook(contentsOf:)`) and `WriteResult.warnings`. Each has a `kind` (`dropped`, `degraded`, `substituted`), a `subject`, the sheet and cell when known, and a message |

Nothing is dropped in silence: a limit that stops a read, a feature a format lacks, a formula a dialect cannot
spell — all come back as a warning. `Workbook.write(to:)` warns at compile time if you discard its result.

## 6. Big files

`Workbook` holds every cell (reckon on 100–200 bytes each). For files larger than that:

```swift
// read row by row — one call for XLSX, ODS, Numbers and delimited text
let reader = try StreamingReader(contentsOf: url)
try reader.forEachRow(inSheet: "Data") { row in
    for cell in row.cells { /* cell.ref, cell.value */ }
}

// write row by row — the destination is replaced only once the file is complete
let result = try CodecSet.all.withStreamingWriter(to: url, as: .xlsx, sheetName: "Data") { writer in
    for record in records { try writer.append([.text(record.name), .integer(record.count)]) }
}

// ask before reading — for a file you do not trust
let summary = try Workbook.inspect(contentsOf: url)      // sheets, declared cells, expanded size, producer
var options = ReadOptions(); options.cellLimit = 1_000_000
let read = try Workbook.read(contentsOf: url, options: options)
```

The numbers — seconds and megabytes for a million and ten million cells — are in the
[performance record](https://nanbu.github.io/SwiftSheets/performance.html), and the
[Limits](../README.md#limits) table in the README says what each mode does and does not carry.

## 7. Where to go next

- [Cookbook](cookbook.md) — thirteen compiled, running recipes: reports, conversion logs, macros, streaming,
  Shift_JIS CSV, validation and conditional formatting, pictures and charts, errors.
- [README](../README.md) — the openpyxl ↔ SwiftSheets table (every entry point side by side with the library
  used as the behavioural reference), the Limits table, the Formats table.
- [Format support table](https://nanbu.github.io/SwiftSheets/format-support.html) and
  [spec feature matrix](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.html) — what each format carries,
  measured, and the API for each feature (also as [YAML](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.yaml)).
- [Implementation spec](https://nanbu.github.io/SwiftSheets/implementation-spec.html) — the design, and
  Appendix B: every implementation decision and the reason behind it.
- [Migrating to 1.0](migrating-to-1.0.md) — for code written against 0.2x: every rename, and why `- 1` next to a row is now a bug.
- [llms.txt](../llms.txt) — the short map of the library written for AI coding agents.
