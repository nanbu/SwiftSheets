# openpyxl test parity ledger

SwiftSheets follows openpyxl's behaviour, so openpyxl's own test suite is the yardstick. This directory keeps that
claim machine-checked instead of narrative.

| file | role |
|---|---|
| `enumerate_openpyxl_tests.py` | walks an openpyxl source tree and lists every test function → `openpyxl-<version>-tests.json` (committed, so the check runs offline) |
| `parity.json` | the curated status of every test: `ported` / `adapted` / `na_api` / `na_python`, with a reason and the API area it belongs to |
| `check.py` | resolves a status for every enumerated test, cross-checks `ported` / `adapted` entries against the `// openpyxl: <file>::[<Class>::]<test>` comments in `Tests/SwiftSheetsTests`, writes `report.json`, exits 1 on any inconsistency |
| `verify_with_openpyxl.py` | writes a workbook with SwiftSheets and reads it with openpyxl, then the reverse (needs a Python with openpyxl — the Stream web venv) |

Statuses:

- **ported** — the same inputs and expectations, in Swift.
- **adapted** — the same behaviour, checked in Swift's form: `nil` / `false` where openpyxl raises, round trips or
  substring checks where openpyxl diffs XML, value-type equality where openpyxl compares dicts. The reason says what differs.
- **na_api** — the feature does not exist in SwiftSheets yet (charts, pivots, conditional formatting, …). These are the roadmap.
- **na_python** — Python-only concepts (descriptors, numpy / pandas, file descriptors, `repr`).

Counting: one pytest function is one entry regardless of parametrization (a parametrized function maps to one
`@Test(arguments:)`); `cases` in the report counts the parameter sets.

To refresh against a newer openpyxl: download its source archive, run `enumerate_openpyxl_tests.py <dir>`, update
`parity.json` for new / renamed tests until `check.py` is green.
