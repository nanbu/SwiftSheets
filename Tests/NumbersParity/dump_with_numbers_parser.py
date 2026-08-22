#!/usr/bin/env python3
"""Dumps what numbers-parser (MIT — the reference reader) sees in each fixture to <name>.expected.json, so the Swift
reader can be compared against it offline (spec §11.3 / §12.2 "cross-implementation verification").

    python3 Tests/NumbersParity/dump_with_numbers_parser.py          # needs: pip install numbers-parser

Values: text → str, numbers → float, bool → bool, dates → "YYYY-MM-DDTHH:MM:SS", durations → seconds (float),
errors → "#ERROR", empty / merged-away cells → null. Formulas are the text numbers-parser renders (its own dialect).
"""
import json
import pathlib
import warnings

warnings.simplefilter("ignore")
from numbers_parser import Document  # noqa: E402
from numbers_parser.cell import BoolCell, DateCell, DurationCell, EmptyCell, ErrorCell, MergedCell, NumberCell, RichTextCell, TextCell  # noqa: E402

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE.parents[0] / "SwiftSheetsTests" / "Fixtures" / "numbers"


def value(c):
    if isinstance(c, (EmptyCell, MergedCell)):
        return None
    if isinstance(c, ErrorCell):
        return "#ERROR"
    if isinstance(c, BoolCell):
        return bool(c.value)
    if isinstance(c, DateCell):
        return c.value.strftime("%Y-%m-%dT%H:%M:%S")
    if isinstance(c, DurationCell):
        return c.value.total_seconds()
    if isinstance(c, NumberCell):
        return float(c.value)
    if isinstance(c, (TextCell, RichTextCell)):
        return str(c.value)
    return str(c.value)


for path in sorted(FIXTURES.glob("*.numbers")):
    doc = Document(str(path))
    out = {"sheets": []}
    for sheet in doc.sheets:
        s = {"name": sheet.name, "tables": []}
        for table in sheet.tables:
            cells = {}
            for row in table.rows():
                for c in row:
                    if isinstance(c, (EmptyCell, MergedCell)):
                        continue
                    entry = {"v": value(c)}
                    if getattr(c, "formula", None):
                        entry["f"] = c.formula
                    cells[f"{c.row},{c.col}"] = entry
            s["tables"].append({"name": table.name, "rows": table.num_rows, "cols": table.num_cols,
                                "merges": [str(r) for r in (table.merge_ranges or [])],   # A1 form, e.g. "B3:D3"
                                "cells": cells})
        out["sheets"].append(s)
    (FIXTURES / (path.stem + ".expected.json")).write_text(json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    print(path.name, sum(len(t["cells"]) for s in out["sheets"] for t in s["tables"]), "cells")
