# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/), with the pre-1.0 caveat that **minor versions may break the API**
until 1.0 (see [CONTRIBUTING](CONTRIBUTING.md)).

`SwiftSheetsInfo.version` is bumped in the release commit itself and is what the library stamps into the files it
writes, so the constant, the README's status line and the tag always name the same version.

## [Unreleased]

### Added

- **A list data validation and a Numbers pop-up menu are treated as the same thing**, because Numbers itself
  treats them so in both directions (measured: importing an Excel dropdown makes a pop-up menu, exporting a
  pop-up menu makes a strict inline-list dropdown). Reading a Numbers document turns each pop-up menu into a
  `.list` rule on `Sheet.dataValidations` — the choices as an inline list, spelt the way Numbers itself exports
  them — instead of a "control dropped" warning. Writing a `.list` rule whose choices are spelt in the rule
  (`"a,b,c"`) produces a real pop-up menu: Numbers opens the document without repair, offers the choices, and
  exports the rule back to Excel. A rule over empty entry rows grows the table to hold its menus; a whole-column
  rule stops at the table's edge, the way Numbers cuts one on import (measured), and the cut is reported.
  Range-sourced lists and the other validation kinds are dropped with a warning, as before — freezing a range
  into today's values would change what the rule means. Strictness and blank-allowance do not survive the trip
  because Numbers keeps every pop-up in one shape (measured with three differing rules). The corpus gains
  `popup-15.numbers`, made by Numbers 15.3.1 (spec Appendix B.24).

- **A pivot table is written to Numbers as a real Numbers pivot** — a live summary Numbers recomputes from the
  rows it is given — instead of being dropped with a warning. Measured against Numbers 15.3.1 on a workbook of
  seventeen pivots: all fifteen writable ones draw with every number right and not one assertion. What made it
  work was establishing what Numbers actually asks for as it loads, rather than comparing archives against one
  another: Numbers does not look a pivot's group-by up by the UUID written down, it **computes one from the
  table's own `table_id`** plus a sub-owner index, and ours were unrelated random UUIDs, so nothing was ever found
  and the summary drew as an empty shell. Three smaller faults followed from the same reading — the body cells
  carried formulas that evaluated to nothing and wiped their own values, a lane belonging to no group needs the
  sentinel UUID rather than a fresh one, and a pivot with no row fields lays out as one heading row over one body
  row (spec Appendix B.19).

  Written are pivots with **at most one row field, one column field and one summarised value**. Beyond that a
  Numbers pivot grows a sub-total row under every group, or two lanes on an axis that carries no group; those are
  dropped and named, as every pivot was before. Reading a Numbers file back gives the summary as an ordinary
  table, and that one-way loss is named in a warning too.

### Fixed

- **A workbook with a pivot table came out broken the second time it was saved — and the first time, if Excel had
  written it.** The pivot parts carry attributes the writer always emits itself (`applyNumberFormats`,
  `updatedVersion`, `createdVersion`, `saveData`, twelve more), but the reader's list of attributes it knows named
  only five of them, so the rest were remembered as "attributes the model cannot say" and written **a second time**
  on the next save. A repeated attribute is not well-formed XML: `XMLParser` stops with
  `NSXMLParserAttributeRedefinedError`, and Excel offers to repair the file. Our own reader then skipped the
  unreadable part with `try?`, so **the pivot table disappeared without a warning**. The writer now records the
  attribute names it actually wrote and puts back only the ones it did not write itself, so a name added to the
  writer later cannot drift out of step with a list kept somewhere else (spec Appendix B.22).
- **A part whose XML will not parse is now reported instead of being passed over.** `Workbook.read` of an `.xlsx`
  answers with a warning naming the part and what was skipped; `WorkbookReader.read` returns its warnings alongside
  the workbook, the way every other reader already did.
- **A pivot field's name was read and never written back**, so it came home as nothing on every XLSX round trip.
  The reader excluded `name` from the attributes it keeps verbatim (it has a home in the model) but the writer
  never emitted it.
- **Three things were dropped in silence on conversion**, found by checking each direction feature by feature
  against the warnings it returned:
  - array formulas written to Numbers — the anchor cell's formula travels, only the range it spilled over is lost,
    and that is now what the warning says;
  - protected ranges written to Numbers — they were folded into the sheet-protection warning, so a document that
    only had protected ranges was told nothing;
  - **a VBA project written to ODS or Numbers** — counted among "parts that cannot be carried", which made
    `WriteResult.suggest` propose `.xlsx`, a format that loses the macros just as thoroughly. Both writers now
    report it as a `.macros` loss and the suggestion is `.xlsm`.

- **`Workbook.convert` answered with half the trip.** It is the one call that never hands the workbook back, so
  the warnings the *read* made had nowhere else to surface — and a Numbers document's charts and cell controls are
  reported by the read and by nothing else, because they never reach the model for the write to report. Converting
  a document with a chart and eight cell controls to `.xlsx` came back saying **nothing at all**. The result now
  carries both halves, reading's first. `suggestion` is unchanged: which format would have kept more is a question
  about the write (spec Appendix B.23).
- **Every ODS conversion reported a calculation-setting loss, whether or not anything would behave differently.**
  The test was "do these settings differ from the model's own defaults", and LibreOffice writes its own defaults
  into every file it saves — `automatic-find-labels="false"`, `null-year="1950"`, an iteration threshold while
  iteration is off — none of which match ours. So a user who had set nothing was told something was lost, every
  time. The question is now **"will the destination read this document differently"**
  (`CalculationSettings.asAssumedOutsideODF` / `differences(from:)`), and a setting that is not in force — the
  iteration detail while iteration is off — is not counted. Each remaining difference gets its own sentence naming
  both ends (`a two-digit year starts its hundred years at 1950 here, and at 1930 there`) instead of one vague
  lump. A brand-new workbook and a LibreOffice file with nothing set both report nothing.

### Added

- `CrossFormatConversionTests` — the sweep behind the new interoperability document: every one of the nine
  direction pairs must answer each lost feature with a warning that names *that* feature, and three generations of
  the same document must stay well-formed and keep everything. Neither question had been asked before; both had
  something to say.
- `PreservationStore.hasVBAProject`, so a writer can name a macro loss for what it is.
- `CalculationSettings.asAssumedOutsideODF` and `differences(from:)` — what an application outside ODF does
  whatever the file says, and the settings that are in force here and would be read differently there.
- [docs/interoperability.html](https://nanbu.github.io/SwiftSheets/interoperability.html) — what happens to each
  format's own features when it is converted into the other two, the four possible outcomes, and the test that
  measures each claim.

### Changed

- **A font face the model states is now always written to Numbers, which changes how output looks.** The writer
  skipped any face equal to `Font.default.name` (Calibri, Excel's default) as "already the default", the same wrong
  baseline that made 11pt come out small in 0.7.2: the Numbers template defaults to HelveticaNeue, so a cell asking
  for Calibri was drawn in HelveticaNeue and said nothing about it. The model cannot tell "the caller asked for
  Calibri" from "the caller said nothing", so **every cell that carries a style is now written with an explicit
  Calibri** unless it names another face — Numbers documents this library writes will look like Excel's default
  rather than Numbers' own. A cell with no style at all is untouched and still inherits the template. This is a
  deliberate change of look — a pre-1.0 breaking change, listed under Changed rather than Fixed so it is not
  mistaken for a quiet bug fix.

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
