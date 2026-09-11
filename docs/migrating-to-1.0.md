# Migrating to 1.0

Between 0.20 and 1.0 the public surface was reviewed against one set of naming rules and renamed to fit them, so
that what 1.0 freezes is consistent (spec Appendices B.46–B.68 and B.89). No compatibility aliases were kept:
almost every change below is a compile error at the line that has to change, and this page is the map from the
error to the new name. Upgrade across several releases at once by reading the sections from your version down.

**One change compiles and is not a rename: integer cell coordinates start at 1 since 0.23.0.** Read that section
first if your code does arithmetic on rows or columns.

## The change the compiler cannot find — coordinates start at 1 (0.23.0)

`CellRef(row: 1, column: 1)` is A1, `sheet[1, 2]` is B1, and `insertRows(at: 2)` inserts above row 2, as Excel's own
command does. Every integer that names a cell, row or column follows the sheet's numbering: `CellRef`, `CellRange`,
the subscripts, the row and column dimensions, insert and delete, groups, print titles, `autofitColumn`,
`append([Int: …])`, `Table.anchor`, `StreamedRow.index`, `CellRef.columnName(1)` (`"A"`) and
`CellRef.columnIndex("A")` (`1`). Positions in Swift collections stay 0-based: `workbook.sheets[0]`, pivot field
indices, the `table:` argument of a streaming read, and every returned array (`values(width:)` index 0 is column A).

`ws[r - 1, c - 1]` still compiles and now reads the row above; `array[cell.column]` still compiles and traps on the
last column. Search your code for `- 1` and `+ 1` next to a `CellRef`, a row or a column, and remove them. A write
to row 0 or column 0 stops with a message. `rowNumber` is gone (it is `row`), `FilterColumn.column` is
`columnOffset`, and `RangeView`'s relative subscript is `view[rowOffset:columnOffset:]`.

## After 0.26.0 — the last look before 1.0 (B.89)

- `SheetImage.Anchor.absolute(x:y:width:height:)` → `SheetImage.Anchor.absolute(CanvasRect)`; match with `case .absolute(let frame)`.
- `addSparkline(_:data:at:)` → `addSparkline(_:dataRange:at:)` (a `CellRef` twin exists), and `SparklineGroup.Sparkline(dataRange:location:)` → `SparklineGroup.Sparkline(dataRange:at:)`.
- `addTable(named:anchor:)` → `addTable(named:at:)`.
- `IconSet.Icon.set` → `IconSet.Icon.setName`; `DataBar.isGradient` → `DataBar.gradient`.
- `Alignment.wrapText` → `Alignment.wrapsText`; `Alignment.shrinkToFit` → `Alignment.shrinksToFit`.
- `PhoneticText.Run(_:start:end:)` → `PhoneticText.Run(_:over:)`, with the span as `range: Range<Int>`.
- No longer public: `CommentThread.mirrorPrefix`, `Chart.anchorOrFrameCells`, `Chart.Kind.drawable` (ask `isDrawable`), `Shape.Geometry.presets` (ask `isPreset`), `DataBar.usesExtension`.

## 0.25.0

- `Chart.Kind`, `SheetImage.Format` and `DateEpoch` are structs with static members instead of enums. The spellings are unchanged; a `switch` over one of them needs a `default`.

## 0.24.0 — the consistency pass (B.62–B.68)

**Labels and verbs.**

- `cell(at:)` → `cell(_:)` and `removeCell(at:)` → `removeCell(_:)`; `style(at:)` and `setStyle(at:_:)` keep their label.
- `CellRef.offset(rows:columns:)` → `CellRef.shifted(rows:columns:)`; `CellRange.shrunk(right:bottom:left:top:)` → `CellRange.shrunk(right:down:left:up:)`.
- `StreamingWriter(url:format:)` → `StreamingWriter(to:as:)`, and `codecs.streamingWriter(url:format:)` → `codecs.streamingWriter(to:as:)`.
- `codecs.streamingReader(data:)` → `codecs.streamingReader(_:)`; `SheetFormat.detect(from:)` → `SheetFormat.detect(_:)`, and `detect(from:filename:)` → `detect(_:filename:)`.

**Bool properties read as assertions.** The rule: `include…`, `allow…`, `show…`, `hide…`, `lock…`, `use…`, `link…`,
`fit…`, `refresh…`, `preserve…` and `count…` gain an `s`. File attributes are unchanged.

- `includeStyles` → `includesStyles`, `includeBOM` → `includesBOM`, `allowBlank` → `allowsBlank` (and the label of `list(choices:over:allowsBlank:)`).
- `preserveUnknownParts` → `preservesUnknownParts`, `countCells` → `countsCells`.
- `showGridLines` → `showsGridLines`, `showValue` → `showsValue`, `showFirstColumn` → `showsFirstColumn` (and the other five `show…` flags of `TableStyleInfo` / `PivotStyleInfo`).
- `showRowGrandTotals` → `showsRowGrandTotals`, `showColumnGrandTotals` → `showsColumnGrandTotals`, `showAll` → `showsAll`, `refreshOnLoad` → `refreshesOnLoad`.
- `showInputMessage` → `showsInputMessage`, `showErrorMessage` → `showsErrorMessage`, `hideDropDown` → `hidesDropDown`.
- `lockStructure` → `locksStructure`, `lockWindows` → `locksWindows`, `lockRevision` → `locksRevision`.
- `useWildcards` → `usesWildcards`, `useRegularExpressions` → `usesRegularExpressions`, `useFirstPageNumber` → `usesFirstPageNumber`, `linkToSourceData` → `linksToSourceData`, `fitToPage` → `fitsToPage`.

**One name per thing.**

- `values(in:)` → `rows(in:)`; `wb.sheets.names` → `wb.sheetNames`.
- `freezePanes(at: "B2")` and `freezePanesA1` → `freezePanes = CellRef("B2")`; `autoFilterA1` → `autoFilter = CellRange("A1:D9")`.
- `setPrintTitles(_:)` → `printTitlesFormula: String?`; `setPrintArea(_:)` → `printAreaFormula: String?` (nil when unset); `setPrintTitleRows(_:)` and `setPrintTitleColumns(_:)` → assign `printTitleRows` / `printTitleColumns` (a `ClosedRange<Int>`) or the formula.
- `CellRef.a1` and `CellRange.a1` → `address`; `absoluteA1` → `absoluteAddress`; `qualifiedA1` → `qualifiedAddress`; `Sheet.dimensions` → `Sheet.extentAddress`.
- `CivilDate(iso:)`, `TimeOfDay(iso:)` and `CivilDateTime(iso:)` → `CivilDateTime(iso8601:)` and the same label on the other two.
- `SheetView.sqref` → `SheetView.selectedRanges`.

**Swift types.**

- `hashValue: String?` on the protection types → `saltedHash`; `validationError() -> String?` → `validate() throws`.
- `ExcelDate.fromSerial` / `toSerial` → `CellValue(serial:epoch:)` / `serial(epoch:)`; `fromISO8601` / `toISO8601` → `CellValue(iso8601:)` / `iso8601`; `durationFromSerial` → `Duration(serialDays:)`.
- `Font.vertAlign` → `verticalAlignment: Font.VerticalAlignment?`; `Font.scheme`, `ConditionalFormattingRule.timePeriod`, `StructuredTableColumn.totalsRowFunction` and `DynamicFilter.kind` are enums instead of strings.
- `SheetFormatProperties.baseColWidth` → `baseColumnWidth`, `defaultColWidth` → `defaultColumnWidth`, `PivotLocation.firstDataCol` → `firstDataColumn`.
- No longer public: `CRC32`, `ZipInspection`, `TextEncodingSniffer`, `OOXMLEscape`, `Units`, `CellPixels`, `TextWidth`, `LegacyPasswordHash`, `ModernPasswordHash`, `Table.cleanMergedRange(_:)`, `WriteResult.suggest(from:target:options:)`, `Workbook.noteUnmodelledODFFeatures(_:)`, `UnopenableInput.probe(in:)`.

## 0.23.0 — names from Excel only where Excel owns them (B.54–B.61)

- The coordinate change above.
- `ReadOptions(dataOnly: true)` → `ReadOptions(formulaCells: .cachedValues)`, and the same on `StreamingReadOptions` and `Workbook`.
- `ExcelTable` → `StructuredTable` (with `structuredTables`, `addStructuredTable`, `structuredTable(containing:)` and `StructuredTableColumn`); `Cell.comment` → `Cell.note`; `Top10Filter` → `RankFilter`; `FilterColumn.top10` → `FilterColumn.rank`.
- Thirty-four openpyxl-style `NumberFormat` constants become eighteen that name a meaning (`number`, `numberTwoDecimals`, `percent`, `isoDate`, `time24`, `elapsed` …); a locale-shown built-in format is `NumberFormat.builtinCode(14)`. No format string changed.
- `CellValue.dataType` and `Cell.dataType` are gone — switch on the case; `pythonString` → `stringValue`; the global `Formula("=…")` → `CellValue.formula("=…")`.
- `Sheet.tabColor: String?` → `Sheet.tabColor: Color?` (`Color(hex: "1072BA")`).
- Abbreviations are words: `col` → `column`, `cols` → `columns`, `minCol` → `minColumn`, `maxCol` → `maxColumn`, across `CellRef`, `CellRange`, `RangeBounds` and `RangeView`.

## 0.22.0 — refusals by kind, and a verb for changing a style (B.52, B.53)

- A refusal that used to be `SheetError.unsupportedFeature(String)` has its own case: `unopenable(.encryptedOOXML)`, `unopenable(.encryptedODF)`, `unopenable(.encryptedNumbers)`, `unopenable(.legacyCompoundFile)`, `noCodec(for:)` and `unsupportedEncryption(detail:)`. An exhaustive `switch` over `SheetError` has these to answer for.
- `sheet.style("A1:D1") { … }` → `sheet.setStyle("A1:D1") { … }`; reading a style keeps `style`.
- An A1 string that does not parse stops at an entry point that changes something, and returns a default where it only reads. Validate strings that come from a person with `CellRef(_:)` / `CellRange(_:)`, which return nil.

## 0.21.0 — a row-by-row write saves only when it finishes (B.51)

- `StreamingWriter.close()` returns a `StreamingWriteResult` that must be used: `let result = try writer.close()`, or `_ = try writer.close()`.
- The destination is replaced only when `close()` completes; its directory must exist. After the first failed `append`, the writer saves nothing and further calls throw.

## 0.20.0 — the facade is the only way in (B.46–B.50)

- `CodecSet([XLSXCodec.self, CSVCodec.self])` → `CodecSet([.xlsx, .csv])`; the codec types themselves are internal to the package.
- `Workbook.convert(_:to: format, output: destination)` → `Workbook.convert(_:to:as:)`, and the same on `CodecSet`.
- `workbook.data(as:)` → `try workbook.write(as:).data`.
- An unused `WriteResult` is a warning: keep it, or write `_ = try workbook.write(to: url)`.
- `Workbook.preserved`, `Sheet.preserved` and the preservation types are internal; read `workbook.preservationSummary`.

The complete entries, with the reasons, are in the [CHANGELOG](../CHANGELOG.md); the decisions are in Appendix B of
the [implementation spec](https://nanbu.github.io/SwiftSheets/implementation-spec.html). What 1.0 promises from here
on is in [API stability](api-stability.md).
