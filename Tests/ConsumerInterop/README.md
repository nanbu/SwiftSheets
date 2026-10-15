# Consumer interoperability specimen

`generate_fixture.py` creates `Fixtures/interop/consumer-contract.xlsx` entirely from synthetic constants.
Regenerate from the repository root with `python3 Tests/ConsumerInterop/generate_fixture.py`.
The specimen has no author, filesystem paths, or private workbook data.

It combines 2.5-point EMU offsets, all three anchor kinds, a hidden row, a two-level group with rotation and
reflection, Japanese and mixed-format runs, theme font references, body insets, an effect, XLDAPR true and false
records in a relationship-resolved nonstandard part path, a spill reference, and a related opaque binary part.

| Judge | Command / scope | What it establishes |
|---|---|---|
| Codec and source preservation | `swift test --filter ConsumerInteropTests` | Readable drawing/array information and unchanged drawing, metadata and opaque bytes after an unrelated edit |
| Independent reader | `python3 Tests/ConsumerInterop/verify_with_openpyxl.py` (openpyxl 3.1.5) | Formula storage, array ranges and cached values through openpyxl; source structure through Python XML; both source and SwiftSheets output |
| Viewport image | Unverified here | Belongs to the rendering application's acceptance suite |
| Native Excel recalculation | Unverified by the automated tests above | Requires Excel opening without repair and recalculating; cached values and independent-reader checks do not establish this |

The Swift export test visibly skips unless the independent-reader script supplies its output directory.
The script also checks a newly created dynamic-array workbook, including the metadata SwiftSheets generated.
Set `SWIFTSHEETS_CONSUMER_INTEROP_DIR` to an output directory to keep both generated workbooks for a native
application check; otherwise the script removes its temporary outputs after verification.
openpyxl does not model grouped shapes; XML checks do not claim visual equivalence. The sample is not a measured
claim of full DrawingML support, and does not change the generated interoperability or feature-support counts.
