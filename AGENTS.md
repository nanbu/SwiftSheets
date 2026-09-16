# AGENTS.md — conventions for coding agents

Rules for anyone (human or agent) changing this repository. This file points at the documents that own each rule;
it does not replace them. Read the one that covers what you are about to touch:

- [README.md](README.md) — what the library promises, the Limits table, formats and status.
- [CONTRIBUTING.md](CONTRIBUTING.md) — what is useful to send, the spec-first rule, the AI-assisted development bar.
- [MAINTENANCE.md](MAINTENANCE.md) — keeping Numbers support current; **cutting a release** (version bump and tag
  in one commit; the manual pre-release checklist).
- [SECURITY.md](SECURITY.md) — handling untrusted files.
- [docs/getting-started.md](docs/getting-started.md), [docs/cookbook.md](docs/cookbook.md) and [llms.txt](llms.txt) — how the
  library is used; the cookbook page is generated from `Examples/` (see below).
- The implementation spec (linked from the README) is revised **first**, then the code. A change that
  contradicts it revises the spec in the same pull request.

## Build and test

```bash
swift build
swift test --filter ODSCodecTests   # example: select suites affected by the change
swift test                          # full suite when the validation policy requires it
```

- Select local checks using [CONTRIBUTING.md — Validation](CONTRIBUTING.md#validation). Completion does not
  require a full suite for every change. Explain what each selected check verifies; broaden only for a new
  failure, a new change, or a concrete uncertainty about the affected behaviour. After checks pass, do not repeat
  or broaden them merely for reassurance. Report the checks run and any remaining limitations.
- Parity suites (`Tests/OpenpyxlParity`, `Tests/NumbersParity`) need Python packages (`openpyxl`,
  `numbers-parser`) and are skipped without them. Run relevant parity checks when XLSX/Numbers behaviour or
  fixture content exercised by those checks changes. Documentation, comments and author/path metadata changes
  alone do not require parity runs.
- `Tests/ExcelParity/verify_with_excel_app.py` drives Microsoft Excel itself over AppleScript to check sheet
  protection (Appendix B.31). It needs Excel, an unlocked screen and Automation permission, and reports
  "cannot judge" rather than a failure when it lacks them.
- `scripts/check-no-crypto.sh` proves what the README says about encryption code — the plain products link no
  cipher, `SheetDecrypt` nothing that encrypts — by building three small executables against the checkout and
  reading their symbol tables (with a positive control). CI runs it on macOS and Linux; run it after touching
  `Package.swift`, anything under `Sources/SheetDecrypt` or `Sources/SheetEncrypt`, or a refusal message.
- Performance is measured and checked on macOS only (`scripts/bench.sh`; the numbers in the README, the
  performance page and the spec). Measure on Linux only when asked to — the Linux CI job judges behaviour, not
  numbers. A memory figure is never reported alone: the same operation's time goes beside it (a table pairs the
  columns, a sentence pairs "15 MB, 4.4 s"), and a claim that time did not change comes from the old and the new
  build run alternately on the same machine at the same time, not from two records taken on different days.
- Tests that depend on local tools or fixtures (LibreOffice, generated ground-truth documents) must skip
  **visibly** via `.enabled(if:)` with a reason — never `guard … else { return }`, which counts a test that did
  nothing as a pass.
- Never skip, weaken, or delete a failing test to get green. If a test is wrong, say so and fix the test as its
  own change, with the reason in the commit message.

## Public-document and fixture hygiene

Run `python3 scripts/check-public-docs.py` and `python3 scripts/check-public-fixtures.py` before publishing
changes to documents or fixtures. CI runs both detectors and their `--self-test`s. Fixture checks reject real
home-directory paths and unexpected internal author fields without printing personal values. Licence attribution
and Git authorship are separate from workbook metadata; do not remove copyright notices to anonymise a fixture.

## The numeric floors (APIContractTests)

Numbers in the README are checked by tests, not remembered:

- **Version**: `SwiftSheetsInfo.version`, the README status line, the `from:` pin under Installation, and a
  CHANGELOG section must all agree.
- **Test count**: the README's "N+ tests" claim must equal the number of `@Test` declarations under `Tests/`,
  rounded down to the nearest hundred.

If `APIContractTests` goes red after your change, update the README or CHANGELOG to match reality — do not
weaken the test.

## The generated documents (docs/spec-feature-matrix.*)

`docs/spec-feature-matrix.html` and `docs/spec-feature-matrix.yaml` are **generated**. The source is
`scripts/spec-feature-matrix.json`; edit that and run `python3 scripts/build-spec-feature-matrix.py`. Never hand-edit
the two products — `--check` runs in CI and fails on any difference, and it also fails when the row count named in
README.md or docs/index.html no longer matches the source. Statuses in that table are `full` / `partial` /
`preserved` / `none` / `na` / `unverified`; `unverified` exists so a row nobody has measured is never guessed at.
The page borrows its `<style>` from `docs/format-support.html` at build time, so the sibling pages cannot drift apart.

## The interoperability guide (docs/interoperability.html)

`docs/interoperability.html` is generated from `docs/interoperability.json` by
`python3 scripts/build-interoperability-page.py`. Re-measure with `python3 scripts/measure-interoperability.py`;
it requires a successful nine-direction test run and rejects missing or duplicated records. Do not hand-edit
the page or infer new counts from old measurements. CI runs the page's `--check`.

## The cookbook (docs/cookbook.md)

`docs/cookbook.md` is **generated** from the recipe files under `Examples/Sources/swiftsheets-examples/Recipes`
by `python3 scripts/build-cookbook.py`; `--check` runs in CI. CI also builds the `Examples` package on both
platforms and runs every recipe on macOS, so a recipe that stops compiling or working fails the build. Add a
recipe as a file `NN-name.swift` whose first line is `// # Title`, register it in `main.swift`, and regenerate.

## The openpyxl parity ledger (Tests/OpenpyxlParity)

openpyxl's test suite is the yardstick for XLSX behaviour. Every ported or adapted test carries a
`// openpyxl: <file>::<test>` comment; `parity.json` records the status of every openpyxl test with a reason;
`check.py` cross-checks the two and must exit 0. When you port, adapt, or remove such a test, update the ledger
in the same change. Details in `Tests/OpenpyxlParity/README.md`.

## Commits and releases

- Conventional Commits (`feat:` `fix:` `docs:` `refactor:` `test:` `perf:` `chore:`), English, one logical
  change per commit.
- A release bumps the version and tags **that same commit** — the full procedure and the reasons are in
  MAINTENANCE.md ("Cutting a release"). Never leave a bumped version untagged.
- Warnings are part of the API: anything a format cannot carry is reported, never dropped silently. New
  behaviour arrives with a test that fails without it.
