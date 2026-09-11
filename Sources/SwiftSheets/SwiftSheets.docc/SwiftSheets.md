# ``SwiftSheets``

A pure Swift spreadsheet library: one format-neutral model, one codec per format — XLSX, XLSM, CSV/TSV, ODS and
Apple Numbers.

## Overview

Open a file, change what you need, save. Everything you did not touch — charts, pivot caches, macros, styles —
comes out exactly as it went in, and every read and write answers with the list of what it could not keep.

```swift
import SwiftSheets

var workbook = try Workbook(contentsOf: URL(filePath: "monthly-report.xlsx"))
try workbook.editSheet(named: "Summary") { sheet in
    sheet["B4"] = 1_380_000
    sheet["B5"] = .formula("=B4/B3")
    sheet.setStyle("A1:D1") { $0.font.bold = true }
}
let result = try workbook.write(to: URL(filePath: "monthly-report.xlsx"))
print(result.warnings)          // what the format could not carry — never dropped in silence
```

This module is the umbrella: it re-exports `SheetCore` (the model, `CodecSet`, `StreamingReader`,
`StreamingWriter`) and the five codecs, and adds the conveniences that use every codec — `Workbook(contentsOf:)`,
`Workbook.read`, `Workbook.inspect`, `write(to:as:)`, `Workbook.convert`, `StreamingReader(contentsOf:)` and
`StreamingWriter(to:as:)`. An app that needs only some formats links `SheetCore` and the codecs it wants and
uses a `CodecSet` instead. Password-protected files are the separate `SheetDecrypt` and `SheetEncrypt` products.

The guides live beside the code, where they are compiled and checked:

- [Getting started](https://github.com/nanbu/SwiftSheets/blob/main/docs/getting-started.md) — from an empty package to a saved file.
- [Cookbook](https://github.com/nanbu/SwiftSheets/blob/main/docs/cookbook.md) — thirteen complete recipes, built and run by CI.
- [README](https://github.com/nanbu/SwiftSheets#readme) — the openpyxl ↔ SwiftSheets table, the Limits table, the Formats table.
- [The published documents](https://nanbu.github.io/SwiftSheets/) — the format support table, the spec feature matrix, the interoperability guide, the performance record and the implementation spec.

## Topics

### Opening and saving

- ``Workbook``
- ``ReadOptions``
- ``ReadResult``
- ``WriteOptions``
- ``WriteResult``
- ``SheetFormat``
- ``SheetError``
- ``ConversionWarning``

### The model

- ``Sheet``
- ``Table``
- ``Cell``
- ``CellValue``
- ``CellRef``
- ``CellRange``
- ``CellStyle``

### Row by row

- ``StreamingReader``
- ``StreamingWriter``
- ``CodecSet``
