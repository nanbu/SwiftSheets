# Contributing

SwiftSheets is pre-1.0 and has a single maintainer. That shapes what is useful to send.

## Most useful right now

**A file that round-trips wrong.** The library's core promise is that anything you did not touch comes out exactly as
it went in. If a chart, a pivot cache, a style, or a formula changes when you open and save a workbook, that is the
highest-value report — attach the smallest file that reproduces it, and say which application produced it and which
one you opened the result in.

**A file that crashes or hangs.** Malformed and adversarial packages are in scope: the reader is expected to throw or
degrade, never to abort. See [SECURITY.md](SECURITY.md) if the file came from somewhere untrusted.

**A limit that bit you.** The [Limits](README.md#limits) table is deliberately short and explicit. If you hit one and
the message did not tell you what happened, that is a bug in the message.

## Before opening a pull request

Open an issue first. The API is still moving before 1.0, and the design is written down before the code — the spec is
[`docs/implementation-spec.html`](docs/implementation-spec.html) (Japanese), and Appendix B records the decisions and
the reasons behind them. A change that contradicts the spec needs the spec revised in the same pull request.

```bash
swift build
swift test
```

Both must pass. Parity suites under `Tests/OpenpyxlParity` and `Tests/NumbersParity` need Python packages
(`openpyxl`, `numbers-parser`) and are skipped without them; run them if your change touches XLSX or Numbers.

Commits follow Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `perf:`, `chore:`), one logical
change per commit.

## Language

Issues and pull requests in English or Japanese are equally welcome. The design spec is Japanese; the README, the API,
and all symbol names are English.

## Scope

Apple platforms only (the ZIP layer uses Apple's Compression framework), no external dependencies, and no format that
cannot be verified against an independent implementation. Proposals that change any of those three are worth
discussing in an issue, but expect the bar to be high — they are the reasons the library stays small.
