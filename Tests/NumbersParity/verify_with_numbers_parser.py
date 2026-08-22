#!/usr/bin/env python3
"""Reads documents written by SwiftSheets with numbers-parser (MIT, the reference reader) and checks the values
(spec §11.3 "cross-implementation verification"). Numbers.app itself is not available on the build machine, so this
and the self round trip are the automated judges; the manual checklist is in MAINTENANCE.md.

    python3 Tests/NumbersParity/verify_with_numbers_parser.py     # needs numbers-parser; runs `swift test --filter NumbersWriterTests` first
"""
import datetime as dt
import glob
import os
import pathlib
import subprocess
import sys
import warnings

warnings.simplefilter("ignore")
from numbers_parser import Document  # noqa: E402

PKG = pathlib.Path(__file__).resolve().parents[2]
failures = []


def expect(cond, what):
    if not cond:
        failures.append(what)


r = subprocess.run(["swift", "test", "--filter", "NumbersWriterTests"], cwd=PKG, capture_output=True, text=True)
expect(r.returncode == 0, "swift test NumbersWriterTests failed:\n" + r.stdout[-2000:])
outdirs = sorted(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "swiftsheets-numbers-*")), key=os.path.getmtime)
expect(bool(outdirs), "no output directory from the Swift tests")
out = pathlib.Path(outdirs[-1]) if outdirs else None

if out:
    doc = Document(str(out / "sample.numbers"))
    expect([s.name for s in doc.sheets] == ["売上", "Notes"], f"sheet names {[s.name for s in doc.sheets]}")
    sales = doc.sheets[0].tables
    expect([t.name for t in sales] == ["Sales", "Second"], f"table names {[t.name for t in sales]}")
    t = sales[0]
    expect(t.num_rows == 6 and t.num_cols == 8, f"size {t.num_rows}x{t.num_cols}")
    expect(t.cell(0, 0).value == "部門", "A1")
    expect(t.cell(1, 1).value == 1250000, f"B2 {t.cell(1, 1).value!r}")
    expect(abs(t.cell(1, 2).value - 0.125) < 1e-12, f"C2 {t.cell(1, 2).value!r}")
    expect(t.cell(1, 3).value == dt.datetime(2026, 9, 1), f"D2 {t.cell(1, 3).value!r}")
    expect(t.cell(2, 3).value == dt.datetime(2026, 9, 1, 13, 30), f"D3 {t.cell(2, 3).value!r}")
    expect(t.cell(1, 4).value is True and t.cell(2, 4).value is False, "E2/E3 booleans")
    expect(t.cell(1, 5).value == dt.timedelta(seconds=3661), f"F2 {t.cell(1, 5).value!r}")
    expect(t.cell(2, 1).value == -3.5, f"B3 {t.cell(2, 1).value!r}")
    expect(abs(t.cell(0, 6).value - 1249996.5) < 1e-6, f"G1 cached {t.cell(0, 6).value!r}")
    expect(t.cell(0, 7).value == 'quote "q" & <tag>\nline2', f"H1 {t.cell(0, 7).value!r}")
    expect(t.cell(4, 0).value == "merged" and [str(m) for m in t.merge_ranges] == ["A5:C6"], f"merge {t.merge_ranges}")
    expect(t.col_width(0) > t.col_width(1), "column A wider")
    expect(t.row_height(0) == 40, f"row height {t.row_height(0)}")
    expect(sales[1].cell(0, 0).value == "second table" and sales[1].cell(1, 1).value == 42, "second table")
    notes = doc.sheets[1].tables[0]
    expect(notes.cell(0, 0).value == "second sheet" and notes.cell(0, 1).value == 7, "second sheet")

    doc2 = Document(str(out / "from-xlsx.numbers"))
    expect([s.name for s in doc2.sheets] == ["Data", "Notes"], "converted sheet names")
    expect(doc2.sheets[0].tables[0].cell(2, 1).value == 5, "converted value")

print({"numbers_parser": __import__("numbers_parser").__version__ if hasattr(__import__("numbers_parser"), "__version__") else "?", "ok": not failures, "failures": failures, "outdir": str(out)})
sys.exit(1 if failures else 0)
