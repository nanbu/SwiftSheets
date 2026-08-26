#!/usr/bin/env python3
"""Second judge for Appendix B.20 — the cells that carry a style and no value.

Our own reader and the writer share a view of the format, so a round trip that passes proves they agree, not that
the file is right. numbers-parser (MIT, the reference reader) shares no code with either, and it is what says
whether the fills are really in the document. Numbers.app itself is the first opinion and is available here —
`numbers_app.py export <file> <out.pdf>` renders the bars; see Appendix B.20.

    python3 Tests/NumbersParity/verify_valueless_cells.py     # needs numbers-parser; runs the Swift test first

Exit 0 = the painted cells are there. Exit 1 = they are not. Exit 2 = the machine could not judge.
"""
import glob
import os
import pathlib
import subprocess
import sys
import warnings

warnings.simplefilter("ignore")
try:
    from numbers_parser import Document
except ImportError:
    print("cannot judge: numbers-parser is not installed (uv run --with numbers-parser python … )")
    sys.exit(2)

PKG = pathlib.Path(__file__).resolve().parents[2]
BAR = "70AD47"
failures = []


def expect(cond, what):
    if not cond:
        failures.append(what)


r = subprocess.run(["swift", "test", "--filter", "writesTheSampleTheOtherJudgeReads"],
                   cwd=PKG, capture_output=True, text=True)
if r.returncode != 0:
    print("cannot judge: the Swift test that writes the sample failed\n" + r.stdout[-2000:])
    sys.exit(2)

outdirs = sorted(glob.glob(os.path.join(os.environ.get("TMPDIR", "/tmp"), "swiftsheets-valueless-*")),
                 key=os.path.getmtime)
if not outdirs:
    print("cannot judge: the Swift test wrote no output directory")
    sys.exit(2)

path = pathlib.Path(outdirs[-1]) / "valueless-cells.numbers"
doc = Document(str(path))
table = doc.sheets[0].tables[0]

# the three bars, as the Swift test drew them: row r+1, columns 2+r … 4+r, colour and nothing else
painted, unpainted = [], []
for row in range(1, 4):
    for col in range(2 + row - 1, 4 + row):
        cell = table.cell(row, col)
        bg = getattr(getattr(cell, "style", None), "bg_color", None)
        # numbers-parser gives an RGB triple; compare on the hex the writer was given
        hexed = "%02X%02X%02X" % tuple(bg) if bg else None
        (painted if hexed == BAR else unpainted).append(f"r{row}c{col}={hexed}")

expect(not unpainted, f"{len(unpainted)} of {len(painted) + len(unpainted)} painted cells are absent or unpainted: {unpainted}")
expect(len(painted) == 9, f"expected 9 painted cells, found {len(painted)}")

# the values around them must be untouched
expect(table.cell(1, 0).value == "設計", f"A2 is {table.cell(1, 0).value!r}")
expect(table.cell(0, 0).value == "task", f"A1 is {table.cell(0, 0).value!r}")

# the 11pt cell (Appendix B.20, second defect): the size the model stated must be in the document, not inherited
size = getattr(getattr(table.cell(0, 2), "style", None), "font_size", None)
expect(size == 11, f"C1 asked for 11pt and numbers-parser reads {size}")

print(f"read {path.name} with numbers-parser {getattr(__import__('numbers_parser'), '__version__', '?')}")
print(f"  painted cells found: {len(painted)}")
print(f"  C1 font size: {size}")
if failures:
    print("\nFAILED:")
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("\nOK — the cells that carry only a style are in the document.")
