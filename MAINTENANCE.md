# MAINTENANCE — keeping Numbers support current (spec §10.3)

Apple does not promise compatibility of the Numbers file format between releases. Numbers support in SwiftSheets is
therefore a recurring maintenance item, not a one-off.

## Supported versions

The documents in `Tests/SwiftSheetsTests/Fixtures/numbers/` are the verified corpus; their `Metadata/BuildVersionHistory.plist`
entries name the Numbers versions they were produced by — Numbers 11–14 era files from numbers-parser's suite, plus
four written by **Numbers 15.3.1** (`conditional-formats-15`, `links-notes-15` on 2026-08-25;
`chart-and-control-15` on 2026-08-26; `popup-15` on 2026-08-27, from an openpyxl workbook holding three list
validations — text, numeric and strict — each over a filled and an empty cell). Theme images and previews are
stripped from those four, which Numbers does not need to open them and which would otherwise make each file half
a megabyte.

**Keep at least one document in the corpus that is not all tables.** Until `chart-and-control-15` was added, every
fixture held tables and nothing else, so the reader had never been shown a chart or a cell control — and the fact
that it discarded both without a word went unnoticed through four external judges. That fixture was made by writing
an `.xlsx` with a chart and a list validation (openpyxl) and having Numbers import and re-save it:

```bash
python3 Tests/NumbersParity/numbers_app.py   # numbers_app.resave(<xlsx>, <numbers>)
zip -d <out>.numbers 'Data/PresetImageFill*' 'preview*.jpg'   # 665 KB → 112 KB; Numbers still opens it
```

`resave` occasionally fails with `-600` ("no such process"): `open` reaching LaunchServices while Numbers is still
shutting down from the previous document. `_launch_open` already retries once, which absorbs it most of the time —
if a run still fails there, run it again rather than looking for a fault in the file.

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

   **All five are at numbers-parser 4.19.0** (regenerated 2026-08-25 with the Python 3.11 at
   `~/.local/bin/python3.11`; `constants` and `fonts` had lagged at 4.16.3, the newest release that installs on
   this Mac's system Python 3.9). Regenerate all five together:

   ```bash
   ~/.local/bin/python3.11 -m venv /tmp/np && /tmp/np/bin/pip install numbers-parser && /tmp/np/bin/python scripts/extract-numbers-schema.py
   ```

4. If the write template must change (Numbers refuses the generated file), save a fresh empty document with the new
   Numbers, replace `Sources/SheetNumbers/Resources/empty.numbers`, and re-run the self round-trip and
   numbers-parser checks.

   **Measured on 2026-08-25 and decided against by the owner on 2026-08-26** (spec Appendix B.18): a template saved by Numbers 15.3.1 passes
   every automated check and opens in Numbers, but **formulas stop being calculated** — a formula cell whose result
   the source never cached comes up empty. The current template was written by an older Numbers, and Numbers
   recalculates a document of an older version when it opens it; it trusts one of its own. Moving to a new template
   means generating the dependency records first. The condition in this step — Numbers refusing the generated
   file — is not met, so the template stays.
5. Record the verified range in this file and in Appendix B.8 of `docs/implementation-spec.html`.

## Numbers.app is a judge now (2026-08-25, spec Appendix B.18)

Most of the checklist below used to need a person because there was no Numbers on this Mac. There is one now
(Numbers 15.3.1), and the checks it can make are a script:

```bash
python3 Tests/NumbersParity/verify_with_numbers_app.py     # opens, reads, computes, saves again
python3 Tests/NumbersParity/numbers_app.py open .build/numbers-judge/probes/09-two-sheets.numbers
```

It answers "cannot judge" (exit 2) rather than failing when the machine, not the file, is the problem. Four things
about the machine matter, all of them found the hard way:

- **Automation permission.** System Settings ▸ Privacy & Security ▸ Automation — the terminal must be allowed to
  control Numbers. macOS asks once, on screen; until someone clicks, every call times out.
- **The screen must be unlocked.** Numbers cannot put a document window on a locked Mac and then answers nothing
  about that document — indistinguishable from a broken file, so the script names it.
- **Numbers is sandboxed.** It cannot read `$TMPDIR`; documents are staged into `.build/numbers-judge/` and opened
  through `open -a` (LaunchServices), which hands the sandbox the right to read them. AppleScript's own `open`
  does not.
- **It has to be Apple's Numbers.** A bundle identifier is a claim a bundle makes about itself, and LaunchServices
  resolves claims: anything whose Info.plist says `com.apple.Numbers` is what `tell application id` would drive.
  So `available()` takes the resolved **path** and reads the signature on it — an authority only Apple can sign
  under is the proof — and anything else is "cannot judge", named with the path it found. The identifier alone
  would not do: an ad-hoc signature takes the identifier it is given, `com.apple.Numbers` included.

  Worth knowing before that check ever reads as an alarm: **this Mac's genuine Numbers 15.3.1 is installed at
  `/Applications/Numbers Creator Studio.app`** (Mac App Store, 2026-08-05). The bundle is named after the base
  `CFBundleDisplayName` while every `.lproj` localises the name back to "Numbers", which is why Finder, the Dock
  and `kMDItemDisplayName` all say "Numbers". Not a path to whitelist, and not an impostor — checked 2026-08-26
  against the Mac App Store receipt, Apple's `com.apple.private.*` entitlements, `version.plist`
  (`ProjectName = Numbers`) and Apple's own lookup service for its App Store id.

  ```bash
  python3 Tests/NumbersParity/numbers_app.py which   # the bundle that answers, and what proved it — launches nothing
  ```

**It has to answer about the document it was asked about.** Numbers picks a document up through `front document`,
so a window left from an earlier call is what a later call reports on — and a Numbers ended with `killall -9` puts
its whole last session *back* on the next launch. Measured on 2026-08-26: two documents byte-identical in their
archives answered differently, and a run asked to save one document saved another. Every reading taken before that
date should be read with this in mind. Two things stop it, and the second is the one that matters:

- `_clean_slate` closes any open document before each one is opened — **only when Numbers is already running**, so
  the judge does not pay for a quit and a relaunch per document. Quitting and relaunching each time was measured at
  **2–3× the wall clock and failed one run in two** (`-43`, no document); closing alone runs in **~50 s against
  ~67 s** for no clearing at all, over the same eighteen probes.
- `_verify_answered` compares the name Numbers replies with against the name it was handed, and raises rather than
  reporting. **A mismatch is a failed measurement, never a fact about the file** — which is the whole point: the
  cheap slate can in principle miss, and this cannot.

`NumbersProbeTests` writes a corpus of thirteen documents into `.build/numbers-judge/probes`, each one thing more
than the last, starting from the template itself. When Numbers refuses one, the first refusal names the feature
that broke it — which is how the two copy defects in Appendix B.18 were found.

## Cutting a release

The tag is the only thing a user of the library ever sees. It drifted once — `0.6.0` stayed where it was while
thirty-nine commits of ODS and Numbers work landed on top of it, so anyone following the README's
`from: "0.6.0"` fetched a build without any of it, for two days. The rule that prevents a repeat:

**Bump the version in the release commit, and tag that commit.** In one commit:

1. `SwiftSheetsInfo.version` — the constant the library stamps into every file it writes;
2. `README.md` — the `Status: **x.y.z**` line **and** the `from: "x.y.z"` pin under Installation;
3. `CHANGELOG.md` — a `## [x.y.z]` section and its compare link at the bottom;
4. `docs/format-support.html` — the version in its `<title>`. Not covered by the test below, and it was missed once.

`APIContractTests.theReadmeSaysTheVersionTheLibraryWrites` fails if any of the three disagrees, so this is checked
rather than remembered. Then, once CI is green on that commit:

```bash
git tag -a x.y.z -m "x.y.z"
git push origin x.y.z
gh release create x.y.z --title "vx.y.z" --notes-file <(...)   # notes come from the CHANGELOG section
```

Tag an unreleased version only when you mean to release it: a version number living in the source tree without a
tag is how 0.4.0 and 0.5.0 came to exist and never ship.

## Manual checklist before a release (what still needs a person, or Excel)

Build the samples first:

```bash
scripts/make-verification-samples.sh ~/Desktop/SwiftSheets-verification-samples
```

It seeds a realistic Japanese workbook with openpyxl, has LibreOffice write it as ODF, then reads that ODF with
SwiftSheets and writes `.ods`, `.xlsx` and `.numbers` next to it, plus a warning report, PDF renderings and a
per-application checklist (`READ-ME-FIRST.md`, written in Japanese for the maintainer who runs it).

- Open `03-swiftsheets.xlsx` in Excel: no "we found a problem with some content" dialog; formatting, filters,
  frozen panes, formulas, Japanese text and the hidden sheet are as the checklist describes.
- Open `04-swiftsheets.numbers` in Numbers: no "document needs repair" warning; values, merges and sizes are right;
  editing and saving works, and **the formulas are formulas** (Appendix B.18 — they used to be absent). The
  automated judge covers the same ground on its own fixtures; this one is the realistic Japanese workbook.
- **Cell formatting in Numbers (Rev 2.1, Appendix B.16) — the check with no judge on this machine.** The write side
  now creates style archives of its own (variations of the table's defaults, in `Index/DocumentStylesheet.iwa`, with
  the cross-component reference recorded in the package metadata). numbers-parser reads them back correctly and
  LibreOffice's Numbers importer opens the file, but **Numbers.app has not.** Open `04-swiftsheets.numbers` and
  confirm: bold and coloured header cells look as the checklist describes, background fills are there, the font is
  the one asked for (not a fallback), number formats show as currency / percentage / date rather than as plain
  numbers, and the document still saves without complaint. **This is the one part the script cannot judge** — it can
  read values and formulas out of Numbers, but not what a cell looks like.
- **The 1904 date origin** is written to the Numbers calculation engine as of Rev 2.2, and checked only by our own
  reader. If Numbers.app is to hand, open a workbook saved with `wb.epoch = .mac1904` and confirm the dates read the
  same there as in the source.
- **Conditional formatting is read and written** as of Appendix B.18. The fourteen `predicate_type` values were
  observed, not guessed — the recipe is worth keeping for the next unnamed integer: build a workbook in `.xlsx`
  with one rule kind per column and **a parameter no other rule uses**, have Numbers import and save it with
  `numbers_app.resave`, and match each surviving rule to its column by that parameter. Numbers keeps fourteen of
  Excel's twenty-five kinds; the eleven it drops on import are the eleven SwiftSheets reports as dropped.
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
