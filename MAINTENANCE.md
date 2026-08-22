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
   `Sources/SheetNumbers/Resources/{schema,registry,functions}.json`. Commit the regenerated files with the
   numbers-parser version in the commit message. (numbers-parser itself re-extracts the Protobuf definitions from the
   Numbers binary with its `make bootstrap` tooling — that is where new field numbers come from.)
4. If the write template must change (Numbers refuses the generated file), save a fresh empty document with the new
   Numbers, replace `Sources/SheetNumbers/Resources/empty.numbers`, and re-run the self round-trip and
   numbers-parser checks.
5. Record the verified range in this file and in Appendix B.8 of `docs/implementation-spec.html`.

## Manual checklist before a release (cannot be automated without Numbers.app)

- Open each generated fixture in Numbers: no "document needs repair" warning, values display, editing and saving works.
- Open the same files in LibreOffice (libetonyek importer) as a second opinion.
