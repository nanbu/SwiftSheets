# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/), with the pre-1.0 caveat that **minor versions may break the API**
until 1.0 (see [CONTRIBUTING](CONTRIBUTING.md)).

`SwiftSheetsInfo.version` is bumped in the release commit itself and is what the library stamps into the files it
writes, so the constant, the README's status line and the tag always name the same version.

## [0.7.2] — 2026-08-27

### Fixed

- **A cell that carried a style and no value was dropped from a Numbers document without a word.** A sheet draws
  with exactly those cells — a Gantt bar, a weekend column, a legend swatch are colour and nothing else — and the
  writer skipped them before it ever reached the fill, so the drawing arrived blank and nothing was reported. It is
  the one thing this library promises never to do. Found from Stream, whose Gantt lost 66 of a 70-row sample's
  cells; Numbers 15.3.1 rendered the result as an empty grid and now draws the whole staircase. `.xlsx` and `.ods`
  were never affected.
- **A font size of exactly 11pt was drawn a point small in Numbers.** The writer skipped any size equal to
  `Font.default.size` (Calibri 11, Excel's default) as "already the default", but the Numbers template it writes
  into defaults to HelveticaNeue 10, so the omitted 11 was not inherited back. A size the model states is now
  always written. 10pt and 12pt were never affected, which is why this hid for so long.

### Changed

- **The Numbers.app judge could answer about the wrong document.** It picks a document up through `front document`,
  so a window left from an earlier call was what a later call reported on. Two documents byte-identical in their
  archives answered differently, and a run asked to save one saved another. The judge now clears the previous
  document and, more importantly, refuses to report at all when the name it gets back is not the one it asked
  about. Readings taken before 2026-08-26 should be read in that light. It also checks that the application
  answering really is Apple's Numbers, by signature rather than by the bundle identifier it claims. Test tooling
  only — nothing in the library changed (see MAINTENANCE.md).

## [0.7.1] — 2026-08-26

### Fixed

- **A Numbers sheet's charts, images and shapes, and a cell's interactive controls, were dropped without a word.**
  A Numbers sheet is a canvas: the reader took the tables off it and discarded everything else silently, which is
  the one thing this library promises never to do. They are now reported as `dropped` warnings on `.objects` —
  reading them is a separate, larger question. The corpus gained its first fixture that is not all tables
  (`chart-and-control-15.numbers`, Numbers 15.3.1), which is how this was found and how it stays fixed.

## [0.7.0] — 2026-08-26

The release the README has been describing. Everything below landed after the `0.6.0` tag was cut and had never
been published under a version — reason enough for this release on its own.

### Added

- **ODS conditional formatting, data validation, print setup, protection, tables and pivots.** All eighteen rule
  kinds round-trip; LibreOffice rebuilds every one when it converts to XLSX. Written as LibreOffice's
  `calcext:conditional-formats`, read from both that and ODF 1.3's own `style:map`.
- **The six things only OpenDocument has** — label ranges, the consolidation definition, the detective's arrows,
  the file-level calculation settings, a free date origin, and a cell that knows its own currency. Read and
  written; reported as lost when writing to any other format.
- **ODS row groups and rich text** inside a single cell.
- **Numbers cell formatting and number formats**, in both directions — fonts, colours, fills, borders, alignment,
  wrapping. The write side creates style archives of its own.
- **Numbers formulas as formulas.** The formula tree is turned into the postfix node array Numbers evaluates, so a
  formula written from SwiftSheets computes its answer in Numbers — including one that reaches into another table.
  What has no example in the corpus (defined names, unknown functions, whole-column ranges, intersection / union)
  falls back to the cached value with a `degraded` warning naming what stopped it.
- **Numbers conditional formatting.** The fourteen `predicate_type` values Apple left unnamed were observed, not
  guessed, by round-tripping one rule kind per column through Numbers 15.3.1.
- **Numbers hyperlinks, formatting runs, notes**, and the 1904 date origin.
- **`docs/format-support.html`** — what each format actually carries, across 46 features, measured rather than
  claimed, and checked by `FormatSupportTests` so the table cannot drift from the code.
- **Numbers.app as a fourth external judge** (`Tests/NumbersParity/verify_with_numbers_app.py`). It opens what
  SwiftSheets wrote, is asked what it sees, and is made to save it again. It rejected a document the other three
  judges had passed.
- **Continuous integration** — build and test on macOS for every push and pull request.
- **Published documents** at <https://nanbu.github.io/SwiftSheets/>; the two design documents used to be readable
  only by downloading the repository.

### Fixed

- A decorative `%` in a Numbers number format (`0"%"`) was read back as a real percentage, multiplying values by
  100. Reported by a user of the library.
- Numbers refused documents SwiftSheets wrote with more than one sheet or table: two defects in the copied
  subgraph's table of contents and ordering, which only an application reading the package's own index could see.
- Adding a hyperlink to a cell turned its value into text.
- A style applied to a whole cell was read back as an in-cell formatting run.

### Performance

- Numbers writing: **28 s → 2 s**.

## [0.6.0] — 2026-08-24

- The nine features openpyxl had and SwiftSheets did not (spec Appendix B.15): named styles, cell notes, the
  intersection operator in both dialects, array-formula ranges, header/footer, page breaks, auto-filter conditions
  and sort state, and the data-validation write API.
- Encrypted packages and legacy `.xls` now throw `unsupportedFeature` rather than looking corrupt.
- Property-based tests and a fuzz campaign; a formula-parser crash and a round-trip fixed-point break found and fixed.
- A second or later table on one sheet was silently dropped when writing XLSX / ODS / CSV — now a `dropped` warning.
- `SheetNumbers` resources moved to `.process`, which had been breaking codesign on iOS.
- The repository became a public one: contribution policy, security policy, issue forms.

## [0.3.0] — 2026-08-23

- **Breaking:** the API was settled before 1.0 (spec Appendix B.11) — reading answers with a `ReadResult`, ranges
  became lazy views, and the discriminations were unified.
- Five families of crash on malformed input closed, and a cap put on decompression (spec §12).
- Memory: a `Cell` no longer carries its own style — **496 → 24 bytes**; temporary copies removed from read and write.
- ODS merges could disappear, and a merge covering the whole sheet crashed the writer.

## [0.2.1] — 2026-08-22

- Numbers judged our documents "damaged", and Excel asked to repair our XLSX. Both were missing pieces, now written.

## [0.2.0] — 2026-08-22

- `SheetODS` and `SheetNumbers` targets — the first ODS and Numbers support (spec Appendix B.8), with `NOTICE`
  and `MAINTENANCE.md` recording where the Numbers schema comes from.
- ODS auto-filters; East Asian number formats named explicitly in code.

## [0.1.0] — 2026-08-22

- First public version: `SheetCore`, `SheetXLSX`, `SheetCSV` and the `SwiftSheets` facade — the format-neutral
  model, XLSX / XLSM round-trip preservation (F3), CSV / TSV, the formula AST, and the openpyxl parity ledger.

---

### On the missing 0.4.0 and 0.5.0

Both existed as working version numbers in the source tree while the features of 0.6.0 were being written, and
neither was ever tagged or released. Nothing is missing from the history: the work they carried is listed under
0.6.0 above. They are skipped here rather than invented after the fact.

[0.7.2]: https://github.com/nanbu/SwiftSheets/compare/0.7.1...0.7.2
[0.7.1]: https://github.com/nanbu/SwiftSheets/compare/0.7.0...0.7.1
[0.7.0]: https://github.com/nanbu/SwiftSheets/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/nanbu/SwiftSheets/compare/0.3.0...0.6.0
[0.3.0]: https://github.com/nanbu/SwiftSheets/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/nanbu/SwiftSheets/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/nanbu/SwiftSheets/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/nanbu/SwiftSheets/releases/tag/0.1.0
