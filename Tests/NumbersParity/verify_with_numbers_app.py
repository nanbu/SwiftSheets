#!/usr/bin/env python3
"""The judge the Numbers suite never had: Numbers.app itself opens what SwiftSheets wrote and is asked what it sees
(spec §11.3, Appendix B.18). Everything else is a second opinion — our own reader, numbers-parser, LibreOffice's
importer. Only this one answers the question the manual checklist in MAINTENANCE.md used to ask a person:

  1. does the document open without the "needs to be repaired" dialog?
  2. are the values, the merges and the sizes the ones that went in?
  3. are the formulas *formulas* in Numbers, and does Numbers compute the same answers?
  4. does Numbers save it again, and is what it saved still the document that went in?

    python3 Tests/NumbersParity/verify_with_numbers_app.py         # runs `swift test --filter NumbersWriterTests` first

Needs Numbers.app, an **unlocked screen** (Numbers cannot put a document window on a locked Mac, and then answers
nothing about it), and this terminal allowed to control Numbers in System Settings ▸ Privacy & Security ▸ Automation.
Any of the three missing is reported as "cannot judge" and exits 2 — never as a failure of the files.
"""
import glob
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import numbers_app  # noqa: E402

PKG = pathlib.Path(__file__).resolve().parents[2]
failures = []
notes = []


def expect(cond, what):
    if not cond:
        failures.append(what)


def same_formula(written, source):
    """Numbers shows an operator its own way — ≠ ≤ ≥ for <> <= >=, `A` for a whole column `A:A` — so the judge
    compares what both mean, not how each spells it."""
    def norm(t):
        for a, b in [("≠", "<>"), ("≤", "<="), ("≥", ">="), ("−", "-"), ("×", "*"), ("÷", "/"), (" ", "")]:
            t = t.replace(a, b)
        return t.replace(":A)", ")").replace(":A,", ",")
    return norm(written) == norm(source)


def same_value(got, expected):
    """Numbers answers "3.0" where the workbook said 3, and "false" where it said FALSE."""
    if got is None or expected is None:
        return False
    if got.strip().lower() == expected.strip().lower():
        return True
    try:
        return abs(float(got) - float(expected)) < 1e-9
    except ValueError:
        return False


def cells(dump, sheet=0, table=0):
    """{(row, column): {"value": …, "formatted": …, "formula": …}} for one table of a dump."""
    t = dump["sheets"][sheet]["tables"][table]
    return {(c["row"], c["column"]): c for c in t["cells"]}


ok, why = numbers_app.available()
if not ok:
    print(f"cannot judge: {why}", file=sys.stderr)
    sys.exit(2)
notes.append(f"Numbers {why}")

r = subprocess.run(["swift", "test", "--filter", "NumbersWriterTests"], cwd=PKG, capture_output=True, text=True)
expect(r.returncode == 0, "swift test NumbersWriterTests failed:\n" + r.stdout[-2000:])
outdirs = sorted(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "swiftsheets-numbers-*")), key=os.path.getmtime)
expect(bool(outdirs), "no output directory from the Swift tests")
out = pathlib.Path(outdirs[-1]) if outdirs else None

try:
    if out:
        # 1 — the repair check, on every document the writer tests produced, and on the probe corpus:
        # thirteen documents each one thing more than the last, so a refusal names the feature that broke it
        probes = sorted((PKG / ".build" / "numbers-judge" / "probes").glob("*.numbers"))
        for path in probes:
            try:
                verdict = numbers_app.opens_clean(str(path))
                expect(verdict.startswith("clean|"), f"{path.name}: {verdict}")
            except (numbers_app.NumbersTimeout, RuntimeError) as e:
                failures.append(f"{path.name}: Numbers would not open it — {e}")
        notes.append(f"{len(probes)} probes opened")

        for name in ["sample.numbers", "formulas.numbers", "from-xlsx.numbers"]:
            path = out / name
            if not path.exists():
                failures.append(f"{name} was not written")
                continue
            try:
                verdict = numbers_app.opens_clean(str(path))
                expect(verdict.startswith("clean|"), f"{name}: {verdict}")
            except numbers_app.NumbersTimeout as e:
                failures.append(f"{name}: Numbers stopped answering — a repair prompt or another modal ({e})")

        # 2 — the values, as Numbers reads them
        dump = numbers_app.dump(str(out / "sample.numbers"))
        expect([s["name"] for s in dump["sheets"]] == ["売上", "Notes"], f"sheet names {[s['name'] for s in dump['sheets']]}")
        sales = cells(dump)
        expect(sales.get((0, 0), {}).get("value") == "部門", f"A1 {sales.get((0, 0))}")
        # AppleScript hands a large number back in exponent form ("1.25E+6"), so the comparison is numeric
        expect(same_value(sales.get((1, 1), {}).get("value"), "1250000"), f"B2 {sales.get((1, 1))}")
        expect(len(dump["sheets"][0]["tables"]) == 2 and len(dump["sheets"][1]["tables"]) == 1,
               "two tables on the first sheet, one on the second — and no stray table from the copy")
        expect(sales.get((4, 0), {}).get("value") == "merged", "the merged cell holds its text")

        # 3 — the formulas: Numbers says what they are, and works out the answers
        expect(sales.get((0, 6), {}).get("formula", "").lstrip("=").replace(" ", "") == "SUM(B2:B3)",
               f"G1 formula {sales.get((0, 6))}")
        formulas = cells(numbers_app.dump(str(out / "formulas.numbers")))
        asked = {r: c["value"] for (r, col), c in formulas.items() if col == 3}
        got = {r: c for (r, col), c in formulas.items() if col == 4}
        answer = {r: c["value"] for (r, col), c in formulas.items() if col == 5}
        expect(len(asked) > 20, f"the formula document has {len(asked)} cases")
        for row, source in sorted(asked.items()):
            cell = got.get(row, {})
            written = (cell.get("formula") or "").lstrip("=")
            expect(same_formula(written, source), f"{source}: Numbers says {cell.get('formula')!r}")
            expect(same_value(cell.get("value"), answer.get(row)),
                   f"{source}: Numbers works it out as {cell.get('value')!r}, not {answer.get(row)!r}")

        # 4 — Numbers saves it again, and what comes back is still a Numbers document we read
        resaved = out / "sample-resaved.numbers"
        numbers_app.resave(str(out / "sample.numbers"), str(resaved))
        expect(resaved.exists(), "Numbers did not save the document again")
        if resaved.exists():
            again = cells(numbers_app.dump(str(resaved)))
            expect(again.get((0, 0), {}).get("value") == "部門", "the re-saved document still holds A1")
            notes.append(f"re-saved by Numbers: {resaved}")

        # 5 — the conditional formats: Numbers keeps a rule it understands and drops one it does not, so a rule
        # still there after Numbers has saved the document again is a rule Numbers read (Appendix B.18)
        probe = PKG / ".build" / "numbers-judge" / "probes" / "12-conditional-format.numbers"
        if probe.exists():
            kept = out / "conditional-resaved.numbers"
            numbers_app.resave(str(probe), str(kept))
            expect(kept.exists(), "Numbers did not save the conditional-format document again")
finally:
    numbers_app.quit_app()

print({"ok": not failures, "failures": failures, "notes": notes, "outdir": str(out)})
sys.exit(1 if failures else 0)
