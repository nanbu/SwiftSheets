# API stability — what 1.0 promises

> **The policy 1.0 keeps** (spec Appendix B.95). It applies from the 1.0.0 tag onward.

## Versioning

SwiftSheets follows [Semantic Versioning](https://semver.org/). From 1.0:

- **Patch** (1.0.x): bug fixes, performance, documentation. No source-breaking change.
- **Minor** (1.x): additions — new types, members, formats, new cases of the error and warning enumerations — and a
  raised minimum Swift. Existing code keeps compiling and behaving the same, with the exceptions named on this page:
  a `switch` that lists every case of such an enumeration needs a `default:`, and a file that holds something the
  library could not read before may read differently.
- **Major** (2.0): anything that breaks source. Announced in the CHANGELOG one minor release ahead, with the old
  name deprecated and the new one available side by side for that release.

The version is `SwiftSheetsInfo.version`, stamped into every file the library writes, and a test keeps it equal
to the README's pin and the CHANGELOG's newest section.

## What is covered

The public surface of the products `SwiftSheets`, `SheetCore`, `SheetXLSX`, `SheetCSV`, `SheetODS`,
`SheetNumbers`, `SheetDecrypt` and `SheetEncrypt` — every `public` declaration and its documented behaviour:

- **The model.** `Workbook`, `Sheet`, `Table`, `Cell`, `CellValue`, `CellRef`, `CellRange`, the styles, and the
  sheet-level objects (validations, conditional formatting, structured tables, pivots, protection, images, charts,
  shapes …). Value types, `Sendable`, `Hashable` where declared.
- **The entry points.** `Workbook(contentsOf:)` / `read` / `inspect` / `write` / `convert`, `CodecSet`,
  `StreamingReader`, `StreamingWriter`, `SheetFormat.detect` / `probe`, and the `SheetDecrypt` / `SheetEncrypt`
  password variants.
- **The error and warning vocabulary.** The cases of `SheetError` and `UnopenableInput`, and the `kind` and
  `subject` of `ConversionWarning`. A new case or kind is a minor change, so a `switch` over them keeps a
  `default:`; a removed one is major.
- **The preservation promise (F3).** A part the model does not read is written back byte for byte when the file is
  saved in the same format.
- **The naming rules** of Appendix B.62–B.67 (typed / A1-string twins share labels, predicative Bools, one name per
  thing, Swift types over strings, internal tools are `package`).

## What is not covered

- **Anything `package` or internal.** The preservation store, the parsers, the ZIP and XML plumbing, the Numbers
  schema resources. Reaching them from outside is a compile error, on purpose (Appendix B.46, B.50, B.67).
- **The text of warning and error messages.** `message` and `description` are for people; match on `kind`,
  `subject` and the enum cases, not on the wording.
- **The exact bytes of a written file.** Two releases may write the same workbook differently (a rebuilt styles
  table, a reordered attribute) while both open identically in Excel, LibreOffice and Numbers. What is promised is
  what the file *means*, judged by those applications and by the parity scripts under `Tests/`.
- **Performance numbers.** They are measured and published, not promised; a release that regresses one says so in
  the CHANGELOG.
- **What a reader returns for the same file, in two cases.** Releases keep it, except that a minor release may read
  something the library could not read before (a chart kind that used to be preserved as bytes and is now modelled
  changes what `sheet.charts` returns and what a write warns about), listed under *Changed* in the CHANGELOG; and a
  patch release may correct a result that was wrong, listed under *Fixed*. Nothing else changes what a file reads as.

## Platforms and toolchains

macOS 14+, iOS 17+ and Linux are the platforms the whole suite runs on for every push; a platform CI does not run
on is not claimed (Appendix B.1). The minimum Swift is the one named in `Package.swift`; raising it is a minor
release, announced in the CHANGELOG. WebAssembly builds and runs as described in the README's Limits table; CI builds
the package for it on every push but does not run the suite there.

## Deprecation

A name that is going away is marked `@available(*, deprecated, renamed:)` in one minor release before the major
release that removes it, the CHANGELOG lists `old → new`, and `APIContractTests.everyRenameTheChangelogAnnouncesExistsInTheCode` checks that the
new name exists. Before 1.0 no aliases are kept; the compiler, with [Migrating to 1.0](migrating-to-1.0.md), is the migration guide.

## File formats

The formats each release reads and writes are in the README's Formats table and, feature by feature, in the
[spec feature matrix](https://nanbu.github.io/SwiftSheets/spec-feature-matrix.html). Numbers support follows the
[maintenance policy](../MAINTENANCE.md): tolerant reading of newer documents, an explicit `unsupportedVersion` only
when the schema cannot be read.
