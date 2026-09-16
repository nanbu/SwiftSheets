# Contributing

SwiftSheets 1.x has a stable public API and a single maintainer. That shapes what is useful to send.
Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Most useful right now

**A file that round-trips wrong.** For whole-workbook XLSX/XLSM saves in the same format, uninterpreted parts are preserved byte for byte
and modelled content retains its meaning. ODS reconstructs supported content; Numbers regenerates from a template.
See the README's [Formats](README.md#formats) table for the boundaries of each promise. If a chart, a pivot cache, a style, or a formula changes when you open and save a workbook, that is the
highest-value report — attach the smallest file that reproduces it, and say which application produced it and which
one you opened the result in.

**A file that crashes or hangs.** Malformed and adversarial packages are in scope: the reader is expected to throw or
degrade, never to abort. See [SECURITY.md](SECURITY.md) if the file came from somewhere untrusted.

**A limit that bit you.** The [Limits](README.md#limits) table is deliberately short and explicit. If you hit one and
the message did not tell you what happened, that is a bug in the message.

## Before opening a pull request

Open an issue first. Additions must follow the [1.x stability policy](docs/api-stability.md); source-breaking
changes require a major release and a migration path. The design is written down before the code — the spec is
[the implementation spec](https://nanbu.github.io/SwiftSheets/implementation-spec.html), and Appendix B records the decisions and
the reasons behind them. A change that contradicts the spec needs the spec revised in the same pull request.

Select checks using the validation policy below, and include the commands and results in the pull request.

Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `perf:`, `chore:`), one logical
change per commit.

## Validation

Run the smallest set of checks that verifies the affected behaviour. A full local test run is not required simply
because a file changed or a task is being completed. Classify the actual effect, not the filename: a comment in
shared infrastructure is still a comment-only change.

| Change | Local validation |
|---|---|
| Documentation or comments | Check changed links and document consistency; run affected generators' `--check` commands. Run contract/table tests only when their asserted documentation changes. No Swift build or full suite for prose alone. |
| Workbook author/path metadata only | Run fixture metadata checks and verify that other archive entry payloads are unchanged. Run tests that depend on the changed metadata; unrelated codec and parity suites are unnecessary. |
| Fixture cells, formulas, styles or package structure | Run suites that consume the changed content, plus relevant independent parity checks when they exercise that content. A full suite is unnecessary when the impact is bounded. |
| A local implementation or test change | Build affected targets as needed and run relevant regression suites. An output-only test helper is checked through its owning suite. Run independent parity checks for changed format behaviour. |
| Shared model, ZIP/XML/formula infrastructure behaviour; changes across several codecs; broad refactoring | Run the full suite when the affected behaviour crosses suite boundaries. |
| Impact cannot be bounded, or a release is being cut | Run the full suite. For uncertain impact, first state the concrete uncertainty and why narrower checks cannot resolve it. Follow MAINTENANCE.md for release checks. |

Changes to validation scripts require checks of the affected detector, including its self-test where available;
they do not automatically require the library's full suite. Do not add tests that merely repeat prose or mirror
a reversible metadata substitution.

After the selected checks pass, stop testing unless further edits, failures or unresolved impact justify another
run. Reuse results for the same unchanged inputs. Full-suite CI on macOS/Linux remains the pull-request and main
integration check; a green CI run does not require an additional identical local run. Report local checks and CI
results separately, and describe unavailable judges or untested behaviour honestly.

## AI-assisted development

This library is written with AI assistance and will continue to be. Pull requests written the same way are welcome
— the bar does not move either way, and it is the same bar for everyone:

- the spec is revised in the same pull request when the change contradicts it;
- the checks selected under [Validation](#validation) pass, and new behaviour arrives with a test that fails without it;
- a claim about what another application does is backed by that application, not by recollection — the parity
  scripts under `Tests/OpenpyxlParity` and `Tests/NumbersParity` exist for exactly this;
- you have read what you are sending and can answer questions about it.

The last one is the only one worth spelling out. A patch nobody has read is not reviewable, and "the model wrote
it" is not an answer to "why does this branch exist". Say in the pull request which parts you verified and how.

## Language

Issues and pull requests in English or Japanese are equally welcome. Everything in the repository — the README, the
implementation spec, the guides, the API and every symbol name — is English.

## Scope

macOS 14+, iOS 17+ and Linux, plus WebAssembly within the README's WASI limits; no package dependencies, and no format
that cannot be verified against an independent implementation. CI runs the suite on macOS and Linux and builds every
product for WASI. It does not execute the suite on iOS or WASI. Proposals that change any of those three are worth discussing in an
issue, but expect the bar to be high — they are the reasons the library stays small.
