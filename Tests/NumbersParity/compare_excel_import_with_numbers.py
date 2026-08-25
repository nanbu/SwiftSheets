#!/usr/bin/env python3
"""The Excel-feature sweep (spec Appendix B.18).

One workbook exercises every feature the format-support table measures. It is written twice — once as `.numbers`
by SwiftSheets, once as `.xlsx` — and Numbers is asked to import the `.xlsx` and save it as `.numbers` too. The
two documents are then compared **cell by cell**, which answers the question the table claims to answer: for each
Excel feature, does what SwiftSheets writes carry as much as what Numbers itself keeps on import?

Counting list entries would not answer it — Numbers keeps one entry per cell where SwiftSheets keeps one per
distinct thing, so the same document shows thirteen number formats there and two here. The entry counts are
printed at the end as information, not as a score.

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


def cells(path):
    """What one Numbers document says cell by cell — the value as text, and the formula if there is one."""
    from numbers_parser import Document
    out = {}
    doc = Document(str(path))
    for si, sheet in enumerate(doc.sheets):
        for ti, table in enumerate(sheet.tables):
            for r in range(table.num_rows):
                for c in range(table.num_cols):
                    cell = table.cell(r, c)
                    value, formula = cell.value, cell.formula
                    if value is None and formula is None:
                        continue
                    out[(si, ti, r, c)] = (f"{value}", formula)
    return out


def lists(path):
    """How many entries each of a table's lists holds. Informative only: Numbers keeps one entry per cell where
    SwiftSheets keeps one per distinct thing, so a smaller number here is not a smaller document."""
    from numbers_parser.containers import ObjectStore
    kinds = {1: "strings", 2: "number formats", 3: "formulas", 4: "cell styles",
             8: "rich text (links and runs)", 9: "conditional-format rules", 10: "notes"}
    out = dict.fromkeys(kinds.values(), 0)
    merges = 0
    for o in ObjectStore(pathlib.Path(path))._objects.values():
        name = type(o).DESCRIPTOR.full_name
        if name == "TST.TableDataList" and o.listType in kinds:
            out[kinds[o.listType]] += len(o.entries)
        elif name == "TST.MergeRegionMapArchive":
            merges += len(o.cell_range)
    out["merges"] = merges
    return out


# Numbers spreads an array formula over the cells it covers, each carrying an internal "this came from there"
# function (id 337, which numbers-parser renders as UNDEFINED!). SwiftSheets writes the anchor only — the
# format-support table says so, and lists array formulas as lost to Numbers.
def is_array_spill(formula):
    return bool(formula) and formula.startswith("UNDEFINED!")


def main():
    ours = PROBES / "15-kitchen-sink.numbers"
    theirs = GROUND / "kitchen-sink-by-numbers.numbers"
    ok, why = numbers_app.available()
    if not ok and ours.exists() and theirs.exists():
        # the comparison itself needs no application: both documents are already on disk from a previous run
        print(f"note: Numbers cannot be driven ({why}); comparing the documents from the last run", file=sys.stderr)
    elif not ok:
        print(f"cannot judge: {why}", file=sys.stderr)
        return 2
    if ok and (not ours.exists() or not (PROBES / "15-kitchen-sink.xlsx").exists()):
        subprocess.run(["swift", "test", "--filter", "NumbersProbeTests"], cwd=PKG, check=False,
                       capture_output=True, text=True)
    excel = PROBES / "15-kitchen-sink.xlsx"
    failures = []
    if ok:
        if not ours.exists() or not excel.exists():
            print("the probe corpus is missing; run swift test --filter NumbersProbeTests", file=sys.stderr)
            return 2
        GROUND.mkdir(parents=True, exist_ok=True)
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

    ours_cells, theirs_cells = cells(ours), cells(theirs)
    mismatch, we_keep_more, they_keep_more, computed = [], [], [], 0
    for key in sorted(set(ours_cells) | set(theirs_cells)):
        mine, other = ours_cells.get(key), theirs_cells.get(key)
        where = "sheet {} table {} r{} c{}".format(*key)
        if other and is_array_spill(other[1]) and mine is None:
            continue                                     # the spill of an array formula; published as lost
        if mine is None:
            they_keep_more.append(f"{where}: {other[0]!r}")
        elif other is None:
            we_keep_more.append(f"{where}: {mine[0]!r}")
        elif mine[0] != other[0]:
            # a formula we wrote without a cached value: Numbers works it out when it opens the document, and
            # the reference reader only reports what is stored. Not a difference in what the document says.
            if mine[1] and mine[0] == "None":
                computed += 1
            else:
                mismatch.append(f"{where}: value {mine[0]!r} vs {other[0]!r}")
        elif (mine[1] or "") != (other[1] or "") and not is_array_spill(other[1]):
            mismatch.append(f"{where}: formula {mine[1]!r} vs {other[1]!r}")

    if we_keep_more:
        print(f"\nours keeps, Numbers' own import lost ({len(we_keep_more)}):")
        for line in we_keep_more[:10]:
            print("  " + line)
    if they_keep_more:
        print(f"\nNumbers' own import keeps, ours does not ({len(they_keep_more)}) — read these against the")
        print("format-support table, which names what Numbers cannot be given:")
        for line in they_keep_more[:10]:
            print("  " + line)
        if len(they_keep_more) > 10:
            print(f"  …and {len(they_keep_more) - 10} more")
    if computed:
        print(f"\n{computed} formula cell(s) hold no stored value here; Numbers works them out when it opens the document")
    failures += mismatch

    a, b = lists(ours), lists(theirs)
    width = max(len(k) for k in a)
    print(f"\n{'list':<{width}}  {'SwiftSheets → .numbers':>22}  {'Excel → Numbers':>16}   (entry counts, not a score)")
    for key in a:
        print(f"{key:<{width}}  {a[key]:>22}  {b[key]:>16}")
    print(f"\ncells compared: {len(set(ours_cells) | set(theirs_cells))}; "
          f"values or formulas that disagree: {len(mismatch)}")
    print({"ok": not failures, "failures": failures[:12], "ours": str(ours), "theirs": str(theirs)})
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
