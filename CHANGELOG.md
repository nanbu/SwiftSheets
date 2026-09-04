# Changelog

Notable changes per release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [SemVer](https://semver.org/), with the pre-1.0 caveat that **minor versions may break the API**
until 1.0 (see [CONTRIBUTING](CONTRIBUTING.md)).

`SwiftSheetsInfo.version` is bumped in the release commit itself and is what the library stamps into the files it
writes, so the constant, the README's status line and the tag always name the same version.

## [0.16.0] — 2026-09-05

### Added

- **Pictures written into ODS** (spec Appendix B.43). `addImage(_:at:sizing:)` and `addImage(_:over:)` — the
  same calls that place a picture in an XLSX — now write it into an ODS document: one part under `Pictures/`
  per picture, named in the manifest with its media type, and a `draw:frame` in the anchor cell sized in
  centimetres from the pixel size (96 dpi). A picture over a range names the cell past its far corner as its
  end, which LibreOffice reads as an anchor that resizes with its cells and stretches the picture over the
  range. The ODS writer no longer reports pictures as dropped; the pictures of a source ODS are still carried
  unlinked, as before. Reading is unchanged: the ODS reader skips `draw:frame`, so a picture written this way
  does not come back through it — the feature matrix says so.

## [0.15.0] — 2026-09-05

### Added

- **One streaming writer for every format** (spec Appendix B.42). `StreamingWriter(url:)` in the `SwiftSheets`
  module takes the format from the path's extension, as `Workbook.write(to:)` does, or from `format:`, and
  writes rows as they arrive whether the file is XLSX / XLSM, ODS, Numbers or delimited text; `addSheet(named:)`,
  `append(_:)` and `close()` are the same for all of them, and `warnings` says what the format could not carry.
  Behind it stand `XLSXStreamingWriter`, the new `ODSStreamingWriter` and `NumbersStreamingWriter`, and
  `CSVStreamingWriter`, each usable on its own.
- **ODS row by row.** An ODS document is one part whose styles come before its tables, so the rows are turned
  into XML as they arrive (registering the styles they wear) and set aside — in memory while small, on disk once
  not — and `close()` writes the head, the styles and then each sheet's rows a piece at a time. Memory stays a
  few megabytes whatever the row count; the disk holds the rows once until the end. Over a million cells:
  4.2 s and 22 MB.
- **Numbers row by row.** A tile of 256 rows is packed and written into the file the moment it fills and let
  go; what waits for the end is the table model, the string list (one entry per distinct text), the style list
  and a row header of about a dozen bytes per row. A formula is written as its cached value, rich text as plain
  text, and links, notes and cell controls are dropped — each counted in `warnings`. A tile's rows are written
  at one width, so the table is as wide as its widest row and a row wider than the tiles already written is
  refused: give the first row every column the table will need. Over a million cells: 10.3 s and
  60 MB.
- `XLSXStreamingWriter` writes a macro-enabled package (`.xlsm`, with no macros in it) on request, which is what
  the umbrella does for an `.xlsm` path.

### Changed

- **`SheetXLSX.StreamingWriter` is `XLSXStreamingWriter`**, the pair of `XLSXStreamingReader`. Anyone importing
  `SwiftSheets` keeps writing `StreamingWriter(url:sheetName:)` — the umbrella writer of that name takes the
  same arguments and writes XLSX for an `.xlsx` path — and gains the other formats; anyone importing `SheetXLSX`
  alone renames.

### Fixed

- **The rows an ODS write sets aside on disk are read back with `read(2)`.** `TextSpill` read them back through
  `FileHandle`, which on Darwin keeps what it has read resident: the streaming ODS write's peak grew with the
  row count (42 MB at 20,000 rows, 123 MB at 100,000) although the rows were on disk. One reused buffer and
  `read(2)` bring it to 23 MB whatever the row count, and the whole-workbook ODS write, which spills the same
  way, drops by 30 MB.

## [0.14.0] — 2026-09-05

### Added

- **Sheets read side by side** (spec Appendix B.41). An XLSX / XLSM workbook's sheets are parsed at the same
  time once the shared strings and the style table are in — the model, the warnings and the first error come
  out in sheet order exactly as before. It happens on its own when there are at least two sheets and their
  parts expand to 4 MiB or more between them, a size the ZIP directory already states; `ReadOptions.concurrency`
  caps it (`1` reads one sheet at a time, `n` at most `n` at once, and does so even for a small workbook). The
  number is also the handle on memory: what reading side by side adds is the working room of the sheets in
  flight, never more than that many. Over a million cells in eight sheets: 2.7 s and
  145 MB one at a time, 1.2 s and 257 MB side by side; a one-sheet workbook
  reads as it did. ODS and Numbers ignore the option (one part; read from an index).

### Changed

- The performance record was taken again at the parallel-read commit; the README's Limits row quotes it. The
  ODS row-by-row read's peak moves between about 40 and 70 MB from one run to the next (the same code, the
  same file — when the expanded pieces are let go is not deterministic), and the record quotes the run it made.

### Fixed

- **A part naming an encoding nobody decodes is refused before the parser sees it.** The UTF-8 check that
  keeps Foundation's libxml2-backed parser from trapping on an element name (spec Appendix B.38) let through
  any part whose declaration named another encoding, on the grounds that the parser decodes those itself. It
  does when it knows the name; a name it does not know — a fuzzed declaration — it reports and carries on
  with the bytes as they are, and the same trap took the Linux CI down. The exemption is now the list of
  8-bit encodings libxml2 decodes; any other name is `malformedPart`, and a declared UTF-16 on 8-bit bytes is
  checked as UTF-8, which is how the parser reads it. The fuzz suite can leave the mutant it is reading on
  disk (`SWIFTSHEETS_FUZZ_KEEP_DIR`), so the next trap hands back its cause.
- **The Snappy decoder keeps its state in plain locals and caps a block's declared length at 256 MiB.** It was
  rewritten for the trap above before the crashed thread had been read — the decoder was not the cause — and
  the rewrite stays: every index is checked before use, and the decoder is fuzzed on its own
  (`SnappyFuzzTests`) apart from any document.

## [0.13.0] — 2026-09-05

### Added

- **One streaming reader for every format** (spec Appendix B.40). `StreamingReader(contentsOf:)` in the
  `SwiftSheets` module detects the format the way `Workbook(contentsOf:)` does and walks the file row by row
  whether it is XLSX / XLSM, ODS, Numbers or delimited text; `forEachRow(inSheet:)`, `rows(inSheet:)` and
  `forEachRow(inSheet:valuesOnly:)` read the same for all of them, and the rows come back as the same
  `StreamedRow`. Behind it stand `XLSXStreamingReader`, the new `ODSStreamingReader` and `NumbersStreamingReader`,
  and `CSVStreamingReader`, each usable on its own. A Numbers sheet's second and later tables are reached with
  `table:` (0 is the first, the one `Sheet.table` is), and `tableCount(inSheet:)` says how many there are; for
  any other format a table other than 0 is an error rather than an empty walk.
- **ODS row by row.** The body is expanded a piece at a time and the table asked for is walked as it goes by;
  the tables before it are skipped as subtrees and the ones after it are never read. A row the file writes once
  with `number-rows-repeated` is delivered that many times, as the whole-workbook reader expands it, and runs of
  empty rows past the padding threshold are not. The cell-text rules of ODF (paragraphs, runs, white space,
  links, notes) now live in one place, `ODSCellText`, that both readers share. Over a million cells: 4.3 s and
  42 MB, against 4.0 s and 233 MB for the whole model.
- **Numbers row by row, from an index rather than a decoded tree.** `NumbersObjectIndex` reads every part's
  archive headers once, decodes objects on demand, and lets go of the parts that hold nothing but tiles (the
  256-row blocks a table's cells live in), expanding each again only when a walk reaches it. Over a million
  cells: 1.6 s and 85 MB, against 2.6 s and 323 MB for the whole model.
- **ODS carries the workbook structure lock** (spec Appendix B.40.4): `wb.protection.lockStructure` is written as
  `office:spreadsheet table:structure-protected="true"` (ODF 1.3 §9.1.2) and read back; LibreOffice keeps it
  when it re-saves the file. The key is not carried — ODF's is a digest of another kind than Excel's — and the
  window lock, the revision lock and the passwords, which ODF has no spelling for, are still reported. The
  feature matrix had this row as "no concept in ODF", which was wrong.
- **XLSX carries iteration and full precision** (spec Appendix B.40.4): `<calcPr iterate iterateCount
  iterateDelta fullPrecision>` is read into `CalculationSettings` and written from it, so a workbook that
  iterates its circular references keeps doing so across a save, and one converted from ODS keeps the setting
  instead of a warning that wrongly called it OpenDocument-only. The rest of `<calcPr>` (`calcMode`, `refMode`,
  …) travels through a same-format save in `PreservationStore.calcPrAttributes`.
- **A million-cell Numbers document is on the performance record** for the first time: writing 8.0 s and
  413 MB, reading 2.6 s and 323 MB, row by row 1.6 s and 85 MB.

### Changed

- **`SheetXLSX.StreamingReader` is `XLSXStreamingReader`.** Anyone importing `SwiftSheets` keeps writing
  `StreamingReader(contentsOf:)` and gains the other formats; anyone importing `SheetXLSX` alone renames. No
  alias is kept, since one would make the name ambiguous under the umbrella import. `StreamedRow`,
  `StreamedCell` and `StreamingReadOptions` moved to `SheetCore`.
- **Numbers reads twice as fast.** Half the time of a million-cell read went into turning each cell's
  decimal128 into a `Decimal` by fourteen multiplications and a round trip through text; a significand that fits
  in 64 bits (nearly every number a spreadsheet holds) now goes straight in, and whether it is a whole number is
  decided on the integers. The general road stays for wider significands, and a test holds the two to the same
  answer at the edges. Over a million cells, reading 5.9 → 2.6 s; over a hundred thousand, 0.58 → 0.29 s.
- The feature matrix says ZIP64 is read and written (it has been since 0.12.0; the row still said "none") and
  has a row-by-row-reading row for ODS and Numbers as well as XLSX.

## [0.12.0] — 2026-09-05

### Added

- **ZIP64** (spec Appendix B.39.1). Packages with a part past 4 GB, or more than 65,535 parts, are read and
  written; the ZIP64 records are written only when a package needs them. The container reader takes its bytes
  from a source that can be a buffer, a mapped file, or a file read in pieces with positioned reads, and never
  asks for the whole file. An entry can be expanded a piece at a time (`ZipEntryStream`), and copied into
  another package still compressed, without expanding it.
- **Limits on what a package may declare about itself** (`ZipLimits`, `ReadOptions.limits`): at most 100,000
  parts, 16 GiB expanded in total, a thousandfold expansion for any part over 16 MiB, no two parts sharing bytes,
  and expansion that stops at exactly the size an entry declares — the shapes a decompression bomb takes. A
  package past any of them is `corruptedContainer`; the limits can be raised for a package you know.

- **Ask before reading** (spec Appendix B.39.3). `Workbook.inspect(contentsOf:)` answers with the sheets a
  file declares, how many cells each says it holds, what the package expands to and who wrote it — without
  making a single cell. XLSX reads the head of each sheet part for its `<dimension>`; ODS walks its content
  once as bytes and multiplies the run-length counts instead of expanding them; Numbers reads each table's
  own row and column counts. `InspectOptions(countCells: true)` walks the markup and counts what is really
  there. This is how a reader of untrusted files chooses a `ReadOptions.cellLimit`.

- **The bench is public** (spec Appendix B.39.11). `Benchmarks/` is a package that measures the checkout it
  sits in; `scripts/bench.sh` runs each measurement in its own process from a fresh release build and writes
  `docs/performance.json` with the machine, toolchain and commit; `scripts/build-performance-page.py` turns it
  into [the performance record](https://nanbu.github.io/SwiftSheets/performance.html), and its `--check` runs in
  CI so the README's numbers cannot drift from what was measured. Over a million synthetic cells at this
  release: reading 2.8 s and 221 MB (was 5.7 s and 256 MB), streaming reads 1.9 s and 23 MB (was 5.1 s and
  61 MB), writing 1.7 s and 258 MB (was 2.0 s and 360 MB), ODS reads 3.9 s (was 13.0 s), ODS writes 313 MB
  (was 641 MB).
- **Read only the sheets you ask for** (spec Appendix B.39.10). `ReadOptions(sheets: .named([…]))` or
  `.indices([…])` parses those sheets and no other. An XLSX sheet left out is carried as the bytes it arrived
  in and written back unchanged — the writer keeps the shared-string table and the cell formats at their
  original indices so the untouched sheet still finds them — and reported as `degraded`; an ODS or Numbers
  sheet left out comes back empty, and writing such a workbook reports it as `dropped`.
- **Delimited text one record at a time**: `CSVStreamingReader` (`forEachRow`, or `for try await row in
  reader.rows()`) decodes and parses the file in 256 KiB pieces; `CSVStreamingWriter` puts each record straight
  into the file.
- **Rows as a sequence**: `for try await row in reader.rows(inSheet:)` on `StreamingReader` pulls the sheet one
  piece at a time as the loop asks, and stops reading when the loop does. `forEachRow` stays.
- **Password-protected files are read and written** (spec Appendix B.39.9). `ReadOptions.password` opens an
  Excel workbook protected the way Excel 2010 and later do it (ECMA-376 agile encryption: AES in CBC mode under
  a key derived by SHA-1 / SHA-256 / SHA-512, the package integrity checked by HMAC) and an OpenDocument
  package encrypted as ODF 1.2 / 1.3 say (AES-CBC per entry, PBKDF2 from a SHA-1 / SHA-256 start key);
  `WriteOptions.password` writes the same forms with what Excel and LibreOffice themselves use (AES-256 and
  SHA-512 over 100,000 rounds; AES-256 with PBKDF2 over 1,024 rounds per entry). A wrong password is
  `SheetError.wrongPassword`; the older forms — Excel 2007's "standard" encryption, RC4, ODF 1.1's Blowfish, a
  password-protected Numbers document — are named and refused. The arithmetic (AES, SHA-1, SHA-256, SHA-512,
  HMAC, PBKDF2, the OLE compound file) is written out in `SheetCore`, checked against the standards' own
  vectors, and judged from outside: msoffcrypto-tool decrypts what this library protects, and an independent
  ODF decryptor built on the `cryptography` library does the same for ODS.
- **Detection without reading the file** (spec Appendix B.39.4). `SheetFormat.detect(contentsOf:)` reads the
  first four bytes, the ZIP directory at the end of the file and one small entry — under 16 KiB for a workbook
  of any size, and never the file itself. `SheetFormat.probe` answers in one call: a spreadsheet of some
  format, a file the library recognises but will not open (encrypted OOXML, ODF or Numbers, or a legacy
  `.xls`) and why, or nothing it knows. A Numbers document saved as a folder (a package with `Index.zip`) is
  detected, read and inspected; it used to fail with "is a directory". Text is judged as bytes now, without
  decoding a window into a string first.

### Changed

- **No cell ceiling by default** (spec Appendix B.39.2). `ReadOptions.cellLimit` used to stop a read at a
  million cells; it now defaults to no limit, and is there to be set by a reader of untrusted input. How many
  cells are worth holding is the caller's decision.
- **Parts a reader does not interpret travel folded** (spec Appendix B.39.7). A chart, an image, a pivot cache,
  a VBA project is kept as the compressed bytes the package held, and a same-format write copies them as they
  lie: never expanded, never folded again, byte for byte in the literal sense. `PreservationStore.opaqueParts`
  expands them only when read; `opaquePartNames` and `opaquePartCount` answer without expanding.
- **The readers no longer hold a part either** (spec Appendix B.39.8). A sheet part, the shared-string table
  and an ODS body are expanded 256 KiB at a time and scanned as they arrive; what straddles a piece boundary
  is carried to the next piece and nothing else is kept. Over a million cells the streaming reader peaks at
  23 MB instead of 61 (the shared strings are most of it), the ordinary read at 221 MB instead of 254 (the
  model itself is 203), an ODS read at 233 MB instead of 318. A test holds the reader to a couple of pieces.
- **The writers no longer hold a sheet's XML.** Rows go to the compressor 64 KiB at a time; the ODS body, which
  has to exist before the styles it registers can be written, is kept in pieces and spilled to a temporary file
  past 8 MiB. Over a million cells: writing peaks at 258 MB instead of 360 (the model itself is 203), ODS
  writing at 313 MB instead of 641, and opening a workbook with charts, editing one cell and saving it takes
  3.8 s and 288 MB instead of 6.9 s and 397 MB.
- **The XML inside a package is read by a byte-level scanner of the library's own** (spec Appendix B.39.6),
  not by Foundation's parser: names are compared as bytes, strings are made straight from UTF-8, and a
  preserved subtree is the source bytes themselves rather than a re-serialisation. Every reader keeps its
  contract — the same three events, from the same handler protocol — and every XML part of the fixture corpus
  yields an identical event stream from both engines. Parts in UTF-16 or another declared encoding still go to
  Foundation, and `-DSWIFTSHEETS_FOUNDATION_XML` puts everything back on it; CI runs the suite that way too.
  Over a million cells, back to back on the same machine: reading 5.5 → 2.6 s, streaming reads 4.6 → 1.8 s,
  ODS reads 13.9 → 3.7 s.
- **Faster without changing a byte of any file** (spec Appendix B.39.5): whether a number under a format is
  a date is decided once per format rather than once per cell; a cell's style index is looked up by the
  shared style object it points at rather than by hashing the style; the streaming writer hands rows to the
  compressor 64 KiB at a time; ODS paragraphs and Numbers' Snappy blocks skip the copies they used to make.
  Over a million cells, measured back to back on the same machine: reading 5.6 → 4.2 s, streaming reads
  5.1 → 3.2 s, writing 2.0 → 1.7 s.
- CRC-32 is computed by zlib (0.001 s over a 33 MB part where the Swift loop took 0.09 s), and the one-shot
  compressor no longer copies its output to trim it.

## [0.11.2] — 2026-09-04

### Changed

- **Nothing Apple-only is left in the library** (spec Appendix B.38). DEFLATE — ZIP's method 8 — now goes through
  one seam, `Deflate`, with two implementations behind it: Apple's Compression framework where it exists, and the
  system zlib otherwise (`Sources/CZlib` is a module map over the `zlib.h` that is already on the machine; SwiftPM
  resolves nothing new). SHA-512, which sheet protection needs, is written out in `SheetCore` rather than taken from
  CryptoKit — Excel's default hundred thousand iterations cost 0.29 s in a release build, and the digests are checked
  against FIPS 180-4's published vectors and against CryptoKit itself. `XMLParser` is imported from `FoundationXML`
  where Foundation is split. The ZIP container code itself is unchanged.
- **Linux is supported.** CI runs the whole suite on it — 944 tests, nothing excluded — as well as twice on macOS,
  once over each DEFLATE. Getting there took the Linux job three verdicts: two expressions its type checker would not
  solve, and then a crash that was not ours to make but was ours to avoid (below). visionOS stays unclaimed: nothing
  blocks it, but nobody runs the suite on it.

### Fixed

- **XML whose bytes are not valid UTF-8 is reported as a malformed part, instead of costing the caller their process**
  (spec Appendix B.38). Where Foundation's XML parser is the one built on libxml2, an element name carrying such bytes
  does not come back as a parse error — the process traps inside the parser while that name is turned into a `String`.
  Parts are now checked before the parser sees them, and the error names the byte. A part that says it is something
  else — by a byte-order mark, or by naming an encoding in its declaration — goes through untouched. The specimen a
  fuzz campaign found is kept as a fixture. Reported upstream as
  [swiftlang/swift-corelibs-foundation#5536](https://github.com/swiftlang/swift-corelibs-foundation/pull/5536); the
  check stays regardless, since a machine with an older Swift keeps the fault.

## [0.11.1] — 2026-08-31

### Fixed

- `scripts/make-verification-samples.sh` fetches openpyxl through **uv** when the Python on PATH lacks it, instead
  of requiring a virtual environment belonging to another project. The release checklist's sample workbook could
  not be built on this machine, and that is how the defect below went unnoticed.

### Fixed

- **A cell style on any sheet after the first no longer produces a `.numbers` document Numbers.app refuses to
  open** (spec Appendix B.37). Numbers follows a reference into another component through the package metadata,
  so a crossing the metadata does not declare is one it cannot follow — and it refuses the document without
  saying why. The styles a copied sheet's table names live in the stylesheet component, and their crossings were
  never recorded: a copied sheet's own component is only *queued* while that sheet is written
  (`flushComponents` runs once, at the end, because re-walking the metadata per object turned a one-second write
  into a two-minute one), so `componentID(forObject:)` answered nil and the registration was skipped altogether.
  The first sheet is patched into the template, whose component already exists — which is exactly why a style on
  sheet 1 was fine and the same style on sheet 2 was not. Crossings are now collected while the sheets are
  written and registered once every component exists, and one that still has nowhere to go is reported instead
  of dropped.
  Found by running MAINTENANCE.md's release checklist end to end for the first time, which became possible in
  this release because the sample script now fetches openpyxl through uv. Every other reader — numbers-parser,
  LibreOffice, our own — read the broken document happily; only Numbers objected, which is why nineteen probes
  and four judges had not caught it. `19-style-on-second-sheet` is the probe that would have, and
  `NumbersCrossingTests` pins the invariant without needing Numbers.app, so CI catches a repeat.

## [0.11.0] — 2026-08-31

### Fixed

- **A Numbers form is no longer dropped in silence** (spec Appendix B.36). A form is Numbers' data-entry view —
  built on an iPhone or an iPad, sitting in the tab bar beside the sheets, and filling in a table that already
  exists somewhere else. The reader kept only the tabs whose archive was a plain sheet and passed over everything
  else without a word, so a two-tab document came back as one sheet and no warning. The form is still not turned
  into a sheet — it holds no values of its own, and an empty sheet in the model is a lie the writer would copy —
  but it is now reported, naming **the form and the table typing into it fills in**, so a reader knows both what
  went and what did not. A tab of any other kind is named by its archive type on the same path.
  The fixture (`Fixtures/numbers/form-15.numbers`) is the maintainer's own, made on an iPhone: a form cannot be
  made on a Mac, and this project does not invent specimens.
  **The feature matrix now has no `unverified` rows** — all 191 are backed by a measurement or by the code.


- **The published documents no longer keep their numbers by remembering** — three had already drifted.
  `docs/format-support.html` and `docs/interoperability.html` still named SwiftSheets **0.7.2** in their titles,
  three releases behind; `docs/index.html` said the format support table covers 47 features when it covers 48;
  and the format support page said the kitchen-sink workbook returns **6** warnings for Excel and **9** for ODS
  when the measurement says 7 and 10. All four are corrected, and none of them can drift again:
  `APIContractTests.everyPublishedDocumentNamesTheCurrentVersion` checks the version in every `docs/*.html`
  title, and `FormatSupportTests.thePublishedTableSaysWhatTheMeasurementSays` reads the published table itself —
  every ○ and every × in its 44 rows must agree with what the 48-feature measurement found, along with the three
  scores and the three warning counts. △ ("goes through in another shape") is left to the page, since a binary
  probe cannot adjudicate it. Both checks were confirmed to go red when a mark or a version is edited by hand.


- **A chart sheet is no longer turned into a worksheet, silently** (spec Appendix B.35). SpreadsheetML lets a
  workbook carry a chart sheet — a chart that owns a whole tab — beside its worksheets. The reader parsed every
  sheet the workbook declared as a worksheet, so a chart sheet arrived as a sheet with no cells and **no
  warning**; writing the workbook back then put a `<worksheet>` root into the chart sheet's part, changed its
  content type to worksheet and changed the workbook relationship to `/worksheet`, while the part path still said
  `chartsheets/`. A package that contradicted itself, produced without a word. LibreOffice opened it and drew
  three pages where Excel's original drew two.
  `SheetPreservation.foreignSheet` (`ForeignSheet`) now carries such a sheet as it arrived — the part byte for
  byte, with the content type and relationship type the package gave it — and reading one is reported
  (`degraded`), because "no cells" without a warning reads as "the sheet was empty" rather than "this sheet is
  not a grid". Cells written into one are reported as dropped, since the part is written back unchanged. Dialog
  sheets and macro sheets take the same path. The fixture is Microsoft Excel's own work, built over AppleScript
  by `Tests/FixtureGenerator/make_chartsheet_fixture.py`, and LibreOffice is the judge: it now draws the same
  number of pages for what we wrote as for Excel's original.
  Found while filling in a row the new spec feature matrix had deliberately left marked `unverified`.

### Added

- **A feature matrix read from the specifications** —
  [docs/spec-feature-matrix.html](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.html), and the same
  content as [YAML](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.yaml). The existing format support
  table starts from the model's 48 features and measures what each format keeps; this one starts from what
  each format's own specification names — 191 rows, Excel 78 / ODS 56 / Numbers 57 — and says how far the
  library carries each, with the API for it. Read and write are separate columns, because a single one would
  be untrue: Numbers array formulas are read but not written, and a Numbers filter reads back as hidden rows
  with its rules dropped. Six statuses rather than two, because "unsupported" hides a real difference —
  `preserved` (the model has no word for it, but a same-format save returns it byte for byte, and a conversion
  drops it with a warning) is not the same thing as `none`. Two rows are marked `unverified` rather than
  guessed at: Excel chart sheets and Numbers form sheets, neither of which has a specimen to measure.
  Both documents are generated from `scripts/spec-feature-matrix.json` by
  `scripts/build-spec-feature-matrix.py`; CI runs it with `--check`, which also fails when the row count named
  in README.md or docs/index.html no longer matches the source. Numbers, again, are checked rather than
  remembered.

### Changed

- **Excel itself now judges sheet protection** (spec Appendix B.31). The modern SHA-512 password shipped in
  0.9.0 was verified against an independent Python implementation; it has now been verified against the
  application that has to accept it. `Tests/ExcelParity/verify_with_excel_app.py` drives Microsoft Excel
  (16.112.2) over AppleScript and reads each document's state: protected on open, **still protected after a
  wrong password**, unlocked after the right one. Three probes pass — an ASCII password, a Japanese one (the
  UTF-16LE path) and one on the workbook's structure — each carrying the modern hash alone, so no pass can be
  credited to the legacy sixteen-bit hash. No library code changed; this is the measurement the appendix was
  waiting for.

## [0.10.0] — 2026-08-28

### Added

- **Charts can be built now** (spec Appendix B.34, the fourth and final step of the MIT-adoption plan): column,
  bar, line and pie — the four kinds that carry most real work. `Chart(.column, title:)`,
  `chart.addSeries(values:categories:name:)`, `sheet.addChart(_:over:)`. Series ranges may skip the sheet name;
  the writer qualifies them with the host sheet and makes them absolute, since chart references accept nothing
  less. A chart rides the same drawing part as pictures: a sheet whose source file already carries a drawing gets
  the graphic-frame anchor spliced in after the preserved bytes, and chart parts, relationship ids and shape ids
  are numbered after the existing maxima. A chart with no series is not invented — counted and reported. ODS,
  Numbers and CSV count the charts they cannot hold. The XML structure was learned from libxlsxwriter's chart.c
  (BSD-2, consulted; no code copied — see NOTICE). Judged by openpyxl (all four kinds read back with their types,
  titles, series names and qualified references — the line chart with both series) and LibreOffice (all four
  render in the converted PDF: rising bars, horizontal bars, two crossing lines, six slices). Confirmed in
  real Excel by the maintainer (2026-08-28, read-only licence): the written workbook opens cleanly.

## [0.9.0] — 2026-08-28

### Added

- **Columns can size themselves to their content now** (spec Appendix B.33, the third step of the MIT-adoption
  plan). `autofitColumns(maxWidth:)` / `autofitColumn(_:maxWidth:)` measure every cell the way Excel draws it —
  text through XlsxWriter's per-character pixel table for Calibri 11 (BSD-2, translated — see NOTICE), numbers
  seven pixels a digit, TRUE 31 px and FALSE 36, formulas by their cached value — add the 7 px padding and the
  16 px filter button where one sits, and write the column width, capped at Excel's 255 characters. A column the
  caller already made wider only ever grows. One departure from the source, documented: East Asian wide
  characters measure 16 px, not the source's blanket 8, so Japanese text is not folded in half. An approximation
  by nature — the true width depends on the default font — and says so in its documentation.

- **Pictures can be placed on a sheet now** (spec Appendix B.32, the second step of the MIT-adoption plan).
  `SheetImage(data:)` reads the format (PNG, JPEG, GIF) and pixel size from the bytes; `addImage(_:at:sizing:)`
  pins one to a cell (`.original`, `.scaled`, `.fitCell`, or XLKit's `.resizeCellToFit`, which shapes the column
  and row to the image at the moment of the call) and `addImage(_:over:)` stretches one across a range. A sheet
  with no drawing part gets a freshly generated one; a sheet whose source file already carries a drawing — a
  chart, older pictures — gets the new anchors spliced into the preserved bytes, everything already there staying
  byte for byte, relationship ids numbered after the existing maximum. ODS, Numbers and CSV report the pictures
  they cannot hold, counted, never silently. Judged by openpyxl (both anchors read back at the right cells and
  sizes, the neighbouring chart intact) and LibreOffice. Adapted from XLKit and XlsxReaderWriter (both MIT — see
  NOTICE).

- **The modern sheet-protection password can be generated now** (spec Appendix B.31, the first step of the
  MIT-adoption plan). `setModernPassword(_:spinCount:salt:)` on `SheetProtection`, `WorkbookProtection` and
  `ProtectedRange` computes the iterated SHA-512 hash Excel 2010+ verifies (ECMA-376 §18.2.29: 16 random salt
  bytes, UTF-16LE, spin count 100,000 by default, the 0-based iteration counter appended little-endian each
  round), and `modernPasswordMatches(_:)` checks a password against whatever the file carries. The scheme itself
  is public as `ModernPasswordHash`, next to `LegacyPasswordHash`. Adapted from XLKit (MIT — see NOTICE);
  verified against an independent Python-hashlib implementation with pinned vectors, including a non-ASCII
  password. SHA-512 comes from CryptoKit, so SheetCore's framework list grows by one Apple framework and the
  package still has zero SwiftPM dependencies. `setPassword(_:)` keeps its legacy meaning untouched.

## [0.8.0] — 2026-08-28

### Added

- **A sheet can be edited in one scope now** (spec Appendix B.30, a maintainer proposal reviewed and adopted):
  `wb.editSheet(named:_:)` / `editSheet(at:_:)` hand the sheet to a closure and the changes are in the workbook
  the moment it returns — no copy to put back, so no edit is lost to a forgotten write-back. The edit is a
  transaction: a closure that throws leaves the workbook exactly as it was, which a reference-type model cannot
  offer without a hand-written deep copy. A name the workbook does not have throws the new
  `SheetError.sheetNotFound(name:)` rather than editing nothing in silence — the model layer's first throwing
  API, and a deliberate line: lookups (`wb.sheets["X"]`) stay Optional, an operation that cannot be performed is
  loud (pre-1.0 note: an exhaustive `switch` over `SheetError` gains a case). A rename inside the closure keeps
  the usual rules — validation, de-duplication, formulas follow. The single-statement path
  (`wb.sheets["Sales"]?["A1"] = 1`) keeps its copy-free in-place behaviour. The proposal's second stage, a
  `~Copyable` edit-session type, was declined: a session outliving its scope can commit stale edits over a
  restructured workbook, and the closure form rules that out at compile time.

- **The last three silent readers have voices now** (spec Appendix B.29, from three documents the maintainer built
  in Numbers' own UI — AppleScript has no vocabulary for any of them). A **Numbers filter** keeps its effect and
  names its loss: the rows it hides come back as hidden rows — measured row-for-row identical to Numbers' own
  Excel export, which also drops the rules — and the dropped rules are counted out loud. A **category grouping**
  comes back as the flat rows plus a warning naming the grouped columns (Numbers' own export bakes the grouped
  look into extra label rows and a shifted grid — a change of data this library does not copy). A
  **stock-quote cell** turns out to be a plain `STOCK` formula in current Numbers, already carried since the
  quote-function work; the quote-table variant's attribute pop-up menus are dropped out loud as on any second
  table. The **switched-off states** were measured too, on two more hand-made documents: turning a filter off empties
  the hidden-state list and keeps the rules in their off state; turning categories off flips `is_enabled` alone,
  the grouped columns and the tree staying whole. Neither retained set-up has a place in the model, so both are
  dropped out loud — and Numbers' own Excel export drops both without a trace. A **sort order** (a fifth hand-made document; the
  Sort panel has no on/off switch) reads the same way: applying a sort reorders the stored rows themselves, so
  the data comes back already sorted, and the remembered rules are dropped out loud, named by their columns —
  Numbers' own Excel export writes no sortState either. The corpus gains `category-15.numbers`,
  `category-off-15.numbers`, `filter-15.numbers`, `filter-off-15.numbers`, `sort-15.numbers` and
  `stockcell-15.numbers`.

- **A Numbers pivot now takes several fields on either axis** (spec Appendix B.28): two row fields, two column
  fields, three-deep nesting, mixed shapes — written as the real thing, with each group's own subtotal lane after
  its members and a grand-total lane last, one group-by per column-field prefix, and node UUIDs shared by value
  path across every tree. Numbers 15.3.1 drew every shape — the seventeen-pivot probe workbook included — with
  every number right and zero coordinate assertions, judged against the documents Numbers itself wrote for the
  same workbooks. **Of several summarised values the first is kept and the rest are dropped, out loud**: the value
  lanes of a rebuilt pivot all share one placeholder id and cannot be told apart, a document this writer builds is
  always rebuilt on open, and every arrangement measured (value order, invented lane ids, the body formulas
  Numbers itself writes) drew one value or none — Numbers' own two-value document survives only because it is
  never rebuilt. The corpus gains `pivot-mixed-15.numbers` (a both-axes, two-row-field pivot Numbers built).

- **The quote functions — `STOCK`, `STOCKH`, `CURRENCY`, `CURRENCYH`, `CURRENCYCONVERT`, `CURRENCYCODE` — have a
  settled mapping now** (spec Appendix B.27). Reading a Numbers document keeps the formula with the fetched value
  as its cache (an error stays an error); writing Numbers keeps the formula, and Numbers fetches a fresh quote on
  open (judged on 15.3.1). Excel and OpenFormula have no spelling for any of the six, so the XLSX and ODS writers
  now put the fetched value in the formula's place and say so — the same substitution Numbers itself applies when
  it exports to Excel (measured: the six flattened, `=E2*2+1` beside them kept). A quote formula with no cached
  value goes out as an empty cell rather than a wrong one. The corpus gains `stock-15.numbers`, seeded from the
  maintainer's own hand-made STOCK document.

- **An array formula in a Numbers document comes home with its range.** Numbers spreads an imported Excel array
  formula as the anchor's own formula plus an unnamed spill function (`337(anchor)`) on every covered cell; the
  reader now recognises that shape structurally, reads the covered cells as their values, and reconstructs
  `Table.arrayFormulas` — so converting such a document to `.xlsx` carries a real ranged array formula, and the
  "function id 337 is unknown" warnings are gone. The **write side stays as it was, now with a measured reason**:
  the spill function does not survive Numbers' load-time recalculation — even Numbers' own spread, version-faked
  old so the load recalculates it, loses its values on open — and every document written from the old-version
  template is recalculated by design (the template trade-off approved 2026-08-26). The warning says so now.
  Also measured and settled: **Numbers itself discards an Excel auto-filter on import** (no filter rules, hidden
  rows un-hidden), so there is no Numbers-sanctioned mapping to copy and the auto-filter warning stands. The
  corpus gains `array-15.numbers` (spec Appendix B.26).

- **The four remaining Numbers cell controls — checkbox, stepper, slider and star rating — are a word in the
  model now**: `CellControl` on `Cell.control`, read from and written to Numbers with the dial's bounds
  (minimum / maximum / increment). The sample the wiring was measured from was built by Numbers 15.3.1 itself,
  driven over AppleScript (`set format of range … to checkbox` and friends), since no Excel import can produce a
  control; and the acceptance judge asks Numbers the same way — every control cell of a SwiftSheets-written
  document answers `checkbox` / `stepper` / `slider` / `rating` to an AppleScript `format of cell` query.
  Two rules of Numbers' own carry over: cells wearing the same control share one list entry, and **a control
  cell always holds a value** — Numbers fills an untouched checkbox with false, a dial with its minimum, a
  rating with 0, and the writer does the same, so a control put on an empty cell reads back with that resting
  value rather than nil. A control on a value of the wrong kind (a checkbox on text) keeps the value and drops
  the control with a warning; writing `.xlsx` or `.ods` keeps the value and names the lost control — neither
  format has one. The format-support table grows its 47th row (セルの制御 — Numbers ○, Excel and ODS ×), and the
  corpus gains `controls-15.numbers` (spec Appendix B.25).

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

- **The README's test count is a machine-checked floor now.** The hand-written "839 tests" was 57 behind the day
  it was checked, and drifting further with every commit; the line says "800+ tests" instead, and a contract test
  (`APIContractTests.theReadmeSaysHowManyTestsThereAre`) pins that floor to the number of `@Test` declarations
  under `Tests/`, rounded down to the nearest hundred — the same recipe that keeps the version pin in step.
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

[0.16.0]: https://github.com/nanbu/SwiftSheets/compare/0.15.0...0.16.0
[0.15.0]: https://github.com/nanbu/SwiftSheets/compare/0.14.0...0.15.0
[0.14.0]: https://github.com/nanbu/SwiftSheets/compare/0.13.0...0.14.0
[0.13.0]: https://github.com/nanbu/SwiftSheets/compare/0.12.0...0.13.0
[0.12.0]: https://github.com/nanbu/SwiftSheets/compare/0.11.2...0.12.0
[0.11.2]: https://github.com/nanbu/SwiftSheets/compare/0.11.1...0.11.2
[0.11.1]: https://github.com/nanbu/SwiftSheets/compare/0.11.0...0.11.1
[0.11.0]: https://github.com/nanbu/SwiftSheets/compare/0.10.0...0.11.0
[0.10.0]: https://github.com/nanbu/SwiftSheets/compare/0.9.0...0.10.0
[0.9.0]: https://github.com/nanbu/SwiftSheets/compare/0.8.0...0.9.0
[0.8.0]: https://github.com/nanbu/SwiftSheets/compare/0.7.2...0.8.0
[0.7.2]: https://github.com/nanbu/SwiftSheets/compare/0.7.1...0.7.2
[0.7.1]: https://github.com/nanbu/SwiftSheets/compare/0.7.0...0.7.1
[0.7.0]: https://github.com/nanbu/SwiftSheets/compare/0.6.0...0.7.0
[0.6.0]: https://github.com/nanbu/SwiftSheets/compare/0.3.0...0.6.0
[0.3.0]: https://github.com/nanbu/SwiftSheets/compare/0.2.1...0.3.0
[0.2.1]: https://github.com/nanbu/SwiftSheets/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/nanbu/SwiftSheets/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/nanbu/SwiftSheets/releases/tag/0.1.0
