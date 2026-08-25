#!/usr/bin/env python3
"""The Excel-feature sweep (spec Appendix B.18).

One workbook exercises every feature the format-support table measures. It is written twice — once as `.numbers`
by SwiftSheets, once as `.xlsx` — and Numbers is asked to import the `.xlsx` and save it as `.numbers` too. The
two documents are then compared **feature by feature**, which answers the question the table claims to answer:
for each Excel feature, does what SwiftSheets writes carry as much as what Numbers itself keeps on import?

    python3 Tests/NumbersParity/compare_excel_import_with_numbers.py

Needs Numbers.app, an unlocked screen and automation permission (see numbers_app.py), and numbers-parser.
Run `swift test --filter NumbersProbeTests` first, or let this script do it.
"""
import pathlib
import subprocess
import sys
import warnings

warnings.simplefilter("ignore")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import numbers_app  # noqa: E402

PKG = pathlib.Path(__file__).resolve().parents[2]
PROBES = PKG / ".build" / "numbers-judge" / "probes"
GROUND = PKG / ".build" / "numbers-judge" / "ground"


def features(path):
    """What one Numbers document actually holds, counted from its archives."""
    from numbers_parser.containers import ObjectStore
    store = ObjectStore(pathlib.Path(path))
    objects = store._objects
    def name(o):
        return type(o).DESCRIPTOR.full_name
    out = {"sheets": 0, "tables": 0, "cells with a value": 0, "formulas": 0, "conditional-format rules": 0,
           "rich text (links and runs)": 0, "notes": 0, "merges": 0, "number formats": 0, "cell styles": 0}
    lists = {1: "strings", 2: "number formats", 3: "formulas", 8: "rich text (links and runs)",
             9: "conditional-format rules", 10: "notes", 4: "cell styles"}
    for o in objects.values():
        n = name(o)
        if n == "TN.SheetArchive":
            out["sheets"] += 1
        elif n == "TST.TableModelArchive":
            out["tables"] += 1
            out["merges"] += len(o.merge_region_map.cell_range) if o.base_data_store.merge_region_map.identifier and \
                hasattr(o, "merge_region_map") else 0
        elif n == "TST.TableDataList" and o.listType in lists and lists[o.listType] in out:
            out[lists[o.listType]] += len(o.entries)
        elif n == "TST.MergeRegionMapArchive":
            out["merges"] += len(o.cell_range)
    return out


def main():
    ok, why = numbers_app.available()
    if not ok:
        print(f"cannot judge: {why}", file=sys.stderr)
        return 2
    if not (PROBES / "15-kitchen-sink.numbers").exists() or not (PROBES / "15-kitchen-sink.xlsx").exists():
        subprocess.run(["swift", "test", "--filter", "NumbersProbeTests"], cwd=PKG, check=False,
                       capture_output=True, text=True)
    ours = PROBES / "15-kitchen-sink.numbers"
    excel = PROBES / "15-kitchen-sink.xlsx"
    if not ours.exists() or not excel.exists():
        print("the probe corpus is missing; run swift test --filter NumbersProbeTests", file=sys.stderr)
        return 2

    GROUND.mkdir(parents=True, exist_ok=True)
    theirs = GROUND / "kitchen-sink-by-numbers.numbers"
    failures = []
    try:
        verdict = numbers_app.opens_clean(str(ours))
        if not verdict.startswith("clean|"):
            failures.append(f"Numbers would not open what SwiftSheets wrote: {verdict}")
        numbers_app.resave(str(excel), str(theirs))
    finally:
        numbers_app.quit_app()
    if not theirs.exists():
        failures.append("Numbers did not import the Excel file")
        print({"ok": False, "failures": failures})
        return 1

    a, b = features(ours), features(theirs)
    width = max(len(k) for k in a)
    print(f"{'feature':<{width}}  {'SwiftSheets → .numbers':>22}  {'Excel → Numbers':>16}")
    for key in a:
        mark = "" if a[key] >= b[key] else "   ← Numbers keeps more"
        print(f"{key:<{width}}  {a[key]:>22}  {b[key]:>16}{mark}")
        if a[key] < b[key]:
            failures.append(f"{key}: SwiftSheets writes {a[key]}, Numbers' own import keeps {b[key]}")
    print()
    print({"ok": not failures, "failures": failures, "ours": str(ours), "theirs": str(theirs)})
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
