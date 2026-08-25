# MAINTENANCE — keeping Numbers support current (spec §10.3)

Apple does not promise compatibility of the Numbers file format between releases. Numbers support in SwiftSheets is
therefore a recurring maintenance item, not a one-off.

## Supported versions

The documents in `Tests/SwiftSheetsTests/Fixtures/numbers/` are the verified corpus; their `Metadata/BuildVersionHistory.plist`
entries name the Numbers versions they were produced by (currently Numbers 11–14 era files from numbers-parser's suite).
`Workbook.sourceInfo.version` reports the producing version of any file read.

## Read policy: tolerant by default

A file produced by a newer Numbers is **not** rejected. The reader goes as far as it can and reports what it could not
interpret as `ConversionWarning`s on the facade (`Workbook(contentsOf:)` keeps the workbook; `NumbersCodec.readWithWarnings`
exposes the warnings). A hard failure (`SheetError.unsupportedVersion` / `malformedPart`) always carries the
`BuildVersionHistory` string so the report can be matched to a Numbers release.

## When a new Numbers version ships

1. Create a small corpus with the new version: an empty document, one with several sheets and tables, one with every
   value type (number, text, date, duration, boolean, formula), one with merges. Keep them small; add them under
   `Tests/SwiftSheetsTests/Fixtures/numbers/` with the version in the file name.
2. Run `swift test --filter Numbers` and `python3 Tests/NumbersParity/verify_with_numbers_parser.py` (needs
   `pip install numbers-parser`). Failures point at either changed field numbers or new cell-storage flags.
3. Refresh the schema from a numbers-parser release that supports the new version:
   `scripts/extract-numbers-schema.py <path to numbers-parser checkout or site-packages>` regenerates
   `Sources/SheetNumbers/Resources/{schema,registry,functions,constants,fonts}.json`. Commit the regenerated files
   with the numbers-parser version in the commit message. (numbers-parser itself re-extracts the Protobuf definitions
   from the Numbers binary with its `make bootstrap` tooling — that is where new field numbers come from.)

   **The five files are not all at the same version right now.** `schema`, `registry` and `functions` came from
   numbers-parser 4.19.0; `constants` and `fonts` from 4.16.3, which is the newest release that installs on this
   Mac's Python 3.9. Regenerate all five together from 4.19.0 or later once a Python ≥ 3.10 is available:

   ```bash
   python3 -m venv /tmp/np && /tmp/np/bin/pip install numbers-parser && /tmp/np/bin/python scripts/extract-numbers-schema.py
   ```
4. If the write template must change (Numbers refuses the generated file), save a fresh empty document with the new
   Numbers, replace `Sources/SheetNumbers/Resources/empty.numbers`, and re-run the self round-trip and
   numbers-parser checks.
5. Record the verified range in this file and in Appendix B.8 of `docs/implementation-spec.html`.

## Manual checklist before a release (cannot be automated without Numbers.app / Excel)

Build the samples first:

```bash
scripts/make-verification-samples.sh ~/Desktop/SwiftSheets検証サンプル
```

It seeds a realistic Japanese workbook with openpyxl, has LibreOffice write it as ODF, then reads that ODF with
SwiftSheets and writes `.ods`, `.xlsx` and `.numbers` next to it, plus a warning report, PDF renderings and a
per-application checklist (`はじめにお読みください.md`).

- Open `03-swiftsheets.xlsx` in Excel: no "we found a problem with some content" dialog; formatting, filters,
  frozen panes, formulas, Japanese text and the hidden sheet are as the checklist describes.
- Open `04-swiftsheets.numbers` in Numbers: no "document needs repair" warning; values, merges and sizes are right;
  editing and saving works. Formulas are expected to be absent (Appendix B.8).
- **Cell formatting in Numbers (Rev 2.1, Appendix B.16) — the check with no judge on this machine.** The write side
  now creates style archives of its own (variations of the table's defaults, in `Index/DocumentStylesheet.iwa`, with
  the cross-component reference recorded in the package metadata). numbers-parser reads them back correctly and
  LibreOffice's Numbers importer opens the file, but **Numbers.app has not.** Open `04-swiftsheets.numbers` and
  confirm: bold and coloured header cells look as the checklist describes, background fills are there, the font is
  the one asked for (not a fallback), number formats show as currency / percentage / date rather than as plain
  numbers, and the document still saves without complaint.
- **The 1904 date origin** is written to the Numbers calculation engine as of Rev 2.2, and checked only by our own
  reader. If Numbers.app is to hand, open a workbook saved with `wb.epoch = .mac1904` and confirm the dates read the
  same there as in the source.
- **Conditional formatting is deliberately not written to Numbers** (Appendix B.16). If you have Numbers.app to
  hand, the one thing worth doing is the opposite direction: make a document *with* a conditional format, add it to
  `Tests/SwiftSheetsTests/Fixtures/numbers/`, and the `predicate_type` values become observable — which is the only
  thing standing between the current `dropped` warning and an implementation.
- Open `02-swiftsheets.ods` in LibreOffice as a second opinion (also covered by `swift test`).

### Pivot tables (Rev 2.0, Appendix B.15) — the same "no judge on this machine" problem as Numbers

**Decided 2026-08-24**: verify by hand before each release rather than acquiring a machine with Excel — the same
arrangement Numbers already runs under, and there is no reason to treat pivot tables differently.

SwiftSheets lays a pivot table out and asks the application to refresh it (`saveData="0" refreshOnLoad="1"`, no
record part). openpyxl reads the parts back and LibreOffice both renders and recomputes them, so the layout is
verified — but **Excel itself has not opened a pivot table SwiftSheets wrote**. Before a release, with a workbook
built by `Workbook.addPivotTable`:

- Open it in Excel: no "we found a problem with some content" dialog, and the pivot table shows the summary rather
  than an empty frame (Excel refreshes it on open).
- Change a source cell, hit Refresh: the pivot follows.
- Save from Excel and read the result back with SwiftSheets: the layout still parses and the cache is intact.

If Excel does complain, the likely culprits are the cache definition (`xl/pivotCache/pivotCacheDefinition*.xml`) and
the four-way wiring — part, content type, relationship, `<pivotCaches>` — not the layout part itself.
