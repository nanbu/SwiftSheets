# AGENTS.md — conventions for coding agents

Rules for anyone (human or agent) changing this repository. This file points at the documents that own each rule;
it does not replace them. Read the one that covers what you are about to touch:

- [README.md](README.md) — what the library promises, the Limits table, formats and status.
- [CONTRIBUTING.md](CONTRIBUTING.md) — what is useful to send, the spec-first rule, the AI-assisted development bar.
- [MAINTENANCE.md](MAINTENANCE.md) — keeping Numbers support current; **cutting a release** (version bump and tag
  in one commit; the manual pre-release checklist).
- [SECURITY.md](SECURITY.md) — handling untrusted files.
- The implementation spec (Japanese, linked from the README) is revised **first**, then the code. A change that
  contradicts it revises the spec in the same pull request.

## Build and test

```bash
swift build
swift test                          # full suite — definitive, run before calling anything done
swift test --filter ODSCodecTests   # narrow while iterating
```

- Parity suites (`Tests/OpenpyxlParity`, `Tests/NumbersParity`) need Python packages (`openpyxl`,
  `numbers-parser`) and are skipped without them. Run them if your change touches XLSX or Numbers.
- `Tests/ExcelParity/verify_with_excel_app.py` drives Microsoft Excel itself over AppleScript to check sheet
  protection (Appendix B.31). It needs Excel, an unlocked screen and Automation permission, and reports
  "cannot judge" rather than a failure when it lacks them.
- Tests that depend on local tools or fixtures (LibreOffice, generated ground-truth documents) must skip
  **visibly** via `.enabled(if:)` with a reason — never `guard … else { return }`, which counts a test that did
  nothing as a pass.
- Never skip, weaken, or delete a failing test to get green. If a test is wrong, say so and fix the test as its
  own change, with the reason in the commit message.

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
