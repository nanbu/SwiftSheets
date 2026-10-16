# Maintenance — Numbers compatibility and releases

## Supported Numbers generations

The reader is verified against Numbers major generations 11–15. The checked-in corpus includes upstream
numbers-parser documents and locally generated Numbers 15.3.1 documents. See
[the fixture provenance ledger](Tests/SwiftSheetsTests/Fixtures/numbers/PROVENANCE.md) for each file's origin.
`SourceInfo.isVerifiedVersion` describes the declared generation, not a guarantee that every feature is supported.

## Reading newer documents

A newer Numbers generation is not rejected solely because of its version. Reading proceeds as far as possible,
and `Workbook.read(contentsOf:)` / `CodecSet.read(contentsOf:)` return warnings. `Workbook(contentsOf:)` retains
these on `readWarnings`. The producing version is optional: `workbook.sourceInfo?.version`.
Malformed required parts and unreadable containers throw `SheetError`; an unknown generation is reported as a warning.
The feature matrix documents which Numbers content is read and written.

## When a new Numbers version ships

1. Save an empty document, multiple sheets/tables, all value kinds, formulas, merges, styles and canvas objects
   with the new version. Add small fixtures and record their provenance. Inspect metadata before committing.
2. Run `swift test --filter Numbers` and `python3 Tests/NumbersParity/verify_with_numbers_parser.py`.
3. Refresh all five schema resources together from a numbers-parser release supporting that generation:

   ```bash
   python3 -m venv .build/numbers-schema-venv
   .build/numbers-schema-venv/bin/python -m pip install 'numbers-parser==4.19.0'
   .build/numbers-schema-venv/bin/python scripts/extract-numbers-schema.py
   ```

   The current resources were extracted from numbers-parser 4.19.0. Replace the pin when adopting a newer release,
   and record the version in the commit and provenance documentation. The extractor also accepts a source or
   site-packages directory containing `numbers_parser`.
4. Replace `Sources/SheetNumbers/Resources/empty.numbers` only if the current template no longer opens.
   The older template intentionally triggers Numbers' recalculation. A template saved by Numbers 15.3.1 opened
   but did not calculate uncached formulas (Appendix B.18). A newer template requires dependency records first;
   opening successfully alone is insufficient. Run both the parser and application judges after replacement.
5. Update the verified generation range and the current policy in the implementation spec.

## Application judges

```bash
python3 Tests/NumbersParity/numbers_app.py which
python3 Tests/NumbersParity/verify_with_numbers_app.py
python3 Tests/ExcelParity/verify_with_excel_app.py
```

Numbers/Excel must be installed, the screen unlocked, and the invoking terminal allowed under System Settings →
Privacy & Security → Automation. The scripts report exit 2 (cannot judge) when the environment is unavailable;
that is not a pass. Documents are staged under `.build/` and opened through LaunchServices so sandboxed apps
can read them. The Numbers judge verifies the resolved app's Apple signature and the document name it answers
about; a mismatch invalidates the measurement. Do not force-quit an application or rely on a window from an
earlier probe. Close unrelated documents before running the judges.

`NumbersProbeTests` writes the incremental corpus under `.build/numbers-judge/probes`. Canvas and chart tests
also ask Numbers to save written content again. Visual appearance still requires the manual checklist below.

## Cutting a release

Bump the version and tag that same release commit. In the commit, update:

1. `Sources/SheetCore/SwiftSheetsInfo.swift`.
2. README status and installation pin; the getting-started installation pin.
3. CHANGELOG release section and compare link.
4. Versioned titles of handwritten published pages, and the implementation spec's current release/revision header.
5. Generated document sources: `scripts/spec-feature-matrix.json` and `docs/performance.json`.
   Regenerate with `scripts/build-spec-feature-matrix.py` and `scripts/build-performance-page.py`.
6. Re-measure the interoperability record with `scripts/measure-interoperability.py`, then regenerate its page
   with `scripts/build-interoperability-page.py`. Keep measurement dates and tool versions distinct from page versions.

Run `swift build`, `swift test`, the generated-page `--check` commands, and `python3 Tests/OpenpyxlParity/check.py`.
Complete the manual checklist and require green CI on the release commit. Do not hand-edit generated pages.

```bash
git tag -a x.y.z -m "x.y.z"
git push origin x.y.z
gh release create x.y.z --title "vx.y.z" --notes-file /path/to/release-notes.md
```

Use release notes taken from the corresponding CHANGELOG section. Never move a published tag to incorporate
later fixes. Documentation corrections after 1.0.0 belong to subsequent commits and the next patch release.

## Manual checklist before a release (what still needs a person, or Excel)

Build the samples first:

```bash
scripts/make-verification-samples.sh ~/Desktop/SwiftSheets-verification-samples
```

It seeds a realistic Japanese workbook with openpyxl, has LibreOffice write it as ODF, then reads that ODF with
SwiftSheets and writes `.ods`, `.xlsx` and `.numbers` next to it, plus a warning report, PDF renderings and a
per-application checklist (`READ-ME-FIRST.md`, for the maintainer who runs it).

- Open `03-swiftsheets.xlsx` in Excel: no "we found a problem with some content" dialog; formatting, filters,
  frozen panes, formulas, Japanese text and the hidden sheet are as the checklist describes.
- Open `04-swiftsheets.numbers` in Numbers: no "document needs repair" warning; values, merges and sizes are right;
  editing and saving works, and **the formulas are formulas** (Appendix B.18 — they used to be absent). The
  automated judge covers the same ground on its own fixtures; this one is the realistic Japanese workbook.
- **Cell formatting in Numbers (Appendices B.16, B.98–B.99).** Numbers 15.3.1 application-level tests check
  written font colours, date literals and Japanese yen. Visual checks still matter: open `04-swiftsheets.numbers`
  and confirm bold headers, background fills, typefaces, borders and currency / percentage / date rendering.
  The value/formula judge does not prove the complete visual layout.
- **The 1904 date origin** is written to the Numbers calculation engine as of Rev 2.2, and checked only by our own
  reader. If Numbers.app is to hand, open a workbook saved with `wb.epoch = .mac1904` and confirm the dates read the
  same there as in the source.
- **Conditional formatting is read and written** as of Appendix B.18. The fourteen `predicate_type` values were
  observed, not guessed — the recipe is worth keeping for the next unnamed integer: build a workbook in `.xlsx`
  with one rule kind per column and **a parameter no other rule uses**, have Numbers import and save it with
  `numbers_app.resave`, and match each surviving rule to its column by that parameter. Numbers keeps fourteen of
  Excel's twenty-five kinds; the eleven it drops on import are the eleven SwiftSheets reports as dropped.
- **Furigana (Appendix B.70) — verified in Excel for Mac on 2026-09-16.** The Excel-made JIS specimen contains
  `<rPh>` reading spans on five labels, including two separate spans in `変換前`. Point
  `SWIFTSHEETS_EXCEL_FURIGANA_GROUND_TRUTH` at that workbook and run `ExcelGroundTruthTests`; the sibling rewrite
  must keep every run and open in Excel without repair. Home → Phonetic Guide → Show must display readings on both
  `JIS関数` and `変換前`. The advanced-content specimen separately checks a display-only `<phoneticPr>`.
- **SmartArt (Appendices B.75 and B.103) — verified in Excel for Mac on 2026-09-16.** The Excel-made five-node
  SmartArt and a grouped pair of shapes survived while SwiftSheets changed a threaded comment in the same sheet;
  Excel opened the rewrite without repair and drew both objects. Repeat with the opt-in ground-truth test below.
- **Threaded comments (Appendices B.80 and B.103) — verified in Excel for Mac on 2026-09-16.** An Excel-made
  comment and reply read as one thread, its Japanese compatibility note stayed hidden from `Cell.note`, and a reply
  added by SwiftSheets appeared in Excel with both people. The check also caught duplicate threaded-comment
  relationships and workbook extension elements emitted out of order; both made Excel reject the file.
  Run `SWIFTSHEETS_EXCEL_GROUND_TRUTH=/path/to/excel-made-features.xlsx swift test --filter ExcelGroundTruthTests`,
  then open the sibling `excel-made-features.roundtrip.xlsx` in Excel and require no repair dialog.
- **Links on runs of text (Appendix B.81).** Open a workbook written here with two links in one cell in Numbers
  and confirm both open their targets; put two links into one cell in Numbers, save, and confirm
  `sheet["A1"]` reads as rich text with a link on each run. `RunHyperlinkTests` covers the round trip through
  this library's own writer and reader.
- **Pictures, shapes and text boxes in Numbers (Appendix B.83).** `NumbersCanvasTests` already has Numbers open a
  document written here, save it again and hand the picture's bytes and the text box's text back — what it cannot
  say is how it looks. Open `.build/numbers-judge/probes/19-canvas.numbers` and confirm the picture sits at B2 at
  its own size, the text box reads "Boxed by SwiftSheets" over B4:D5, and the shape at F2:G4 is filled `#FF3366`
  with the word "Shape" on it.
- **Charts and shapes in Numbers (Appendices B.87, B.88).** `NumbersChartTests` has Numbers save a written
  column chart again and export it to Excel; `NumbersCanvasTests` has it keep the ten drawn geometries. What no test
  can say is how they look: open `.build/numbers-judge/probes/20-chart.numbers` and confirm the chart shows two
  series over three months with the title "Sales by month", and `19-canvas.numbers` for the ellipse, the arrows
  and the diamond next to the rectangle.
- Open `02-swiftsheets.ods` in LibreOffice as a second opinion (also covered by `swift test`).

### Pivot tables (Rev 4.93, Appendices B.15 and B.102)

**Verified in Excel for Mac on 2026-09-16**; repeat this check before each release.

SwiftSheets lays a pivot table out and asks the application to refresh it (`saveData="0" refreshOnLoad="1"`, no
record part). Every generated pivot field nevertheless needs an `<item t="default"/>`; without it Excel for Mac
quit while opening the workbook. openpyxl reads the parts back and LibreOffice both renders and recomputes them.
Before a release, with a workbook built by `Workbook.addPivotTable`:

- Open it in Excel: no "we found a problem with some content" dialog, and the pivot table shows the summary rather
  than an empty frame (Excel refreshes it on open).
- Change a source cell, hit Refresh: the pivot follows.
- Save from Excel and read the result back with SwiftSheets: the layout still parses and the cache is intact.

If Excel does complain, the likely culprits are the cache definition (`xl/pivotCache/pivotCacheDefinition*.xml`) and
the four-way wiring — part, content type, relationship, `<pivotCaches>` — plus the default item in each generated
`<pivotField>`.
