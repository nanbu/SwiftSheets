"""Cross-checks the openpyxl parity ledger against the Swift test sources and emits a machine-readable report.

    python Tests/OpenpyxlParity/check.py            # verify, write report.json, exit 1 on inconsistencies
    python Tests/OpenpyxlParity/check.py --quiet

Inputs (all in this directory):
  openpyxl-<version>-tests.json  every test function in the openpyxl source tree (enumerate_openpyxl_tests.py)
  parity.json                    the curated status of every test: ported / adapted / na_api / na_python

Rules enforced:
  * every enumerated openpyxl test resolves to exactly one status (test entry > file default > module default)
  * every `ported` / `adapted` test has a Swift test carrying `// openpyxl: <file>::[<Class>::]<test>`
  * every provenance comment in the Swift tests resolves to an enumerated test marked ported / adapted
  * provenance for a test name that exists in several classes of one file must be class-qualified"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SWIFT_TESTS = ROOT / "Tests" / "SwiftSheetsTests"
STATUSES = ("ported", "adapted", "na_api", "na_python")

enum = json.load(open(next(HERE.glob("openpyxl-*-tests.json"))))
ledger = json.load(open(HERE / "parity.json"))
quiet = "--quiet" in sys.argv
problems = []

# ---- resolve statuses ---------------------------------------------------------------------------
rows = []
for f in enum["files"]:
    file_entry = ledger["files"].get(f["file"], {})
    module_entry = ledger["modules"].get(f["module"], {})
    for t in f["tests"]:
        key = f"{t['class']}::{t['name']}" if t["class"] else t["name"]
        entry = file_entry.get("tests", {}).get(key) or file_entry.get("tests", {}).get(t["name"])
        if entry is None:
            entry = {"status": file_entry.get("default"), "reason": file_entry.get("reason")} if file_entry.get("default") else \
                    {"status": module_entry.get("default"), "reason": module_entry.get("reason")}
        if isinstance(entry, str):
            entry = {"status": entry}
        status = entry.get("status")
        if status not in STATUSES:
            problems.append(f"no status for {f['file']}::{key}")
            status = "unresolved"
        rows.append({"file": f["file"], "module": f["module"], "class": t["class"], "name": t["name"], "key": key, "params": t["params"],
                     "status": status, "reason": entry.get("reason") or file_entry.get("reason") or module_entry.get("reason") or "",
                     "api": entry.get("api") or file_entry.get("api") or module_entry.get("api") or ""})

# ---- provenance comments in Swift ---------------------------------------------------------------
prov_re = re.compile(r"// openpyxl: (\S+?)::((?:(?:[A-Za-z_0-9]+|<module>)::)?)([A-Za-z_0-9]+)")
provenance = {}
for swift in sorted(SWIFT_TESTS.rglob("*.swift")):
    for m in prov_re.finditer(swift.read_text()):
        file, cls, name = m.group(1), m.group(2).rstrip(":"), m.group(3)
        provenance.setdefault((file, cls, name), []).append(swift.name)

by_file = {}
for r in rows:
    by_file.setdefault(r["file"], []).append(r)

covered = set()
for (file, cls, name), sources in provenance.items():
    candidates = [r for r in by_file.get(file, []) if r["name"] == name and (not cls or r["class"] == (None if cls == "<module>" else cls))]
    if not candidates:
        problems.append(f"provenance {file}::{cls + '::' if cls else ''}{name} ({', '.join(sources)}) matches no openpyxl test")
        continue
    if len(candidates) > 1:
        problems.append(f"provenance {file}::{name} is ambiguous (classes {[c['class'] for c in candidates]}) — qualify it with the class")
        continue
    r = candidates[0]
    if r["status"] not in ("ported", "adapted"):
        problems.append(f"{file}::{r['key']} has Swift test(s) {sources} but ledger status {r['status']}")
    covered.add((file, r["key"]))
    r["swift"] = sorted(set(sources))

for r in rows:
    if r["status"] in ("ported", "adapted") and (r["file"], r["key"]) not in covered:
        problems.append(f"{r['file']}::{r['key']} is marked {r['status']} but no Swift test carries its provenance comment")

# ---- report -------------------------------------------------------------------------------------
def tally(items):
    out = {s: 0 for s in STATUSES}
    out["total"] = len(items)
    out["cases"] = sum(i["params"] for i in items)
    for i in items:
        out[i["status"]] = out.get(i["status"], 0) + 1
    return out

modules = {}
for r in rows:
    modules.setdefault(r["module"], []).append(r)
report = {
    "openpyxl": enum["openpyxl"],
    "totals": tally(rows),
    "modules": {m: tally(items) for m, items in sorted(modules.items())},
    "files": {f: tally(items) for f, items in sorted(by_file.items())},
    "tests": rows,
    "problems": problems,
}
(HERE / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n")

if not quiet:
    t = report["totals"]
    print(f"openpyxl {enum['openpyxl']}: {t['total']} tests — ported {t['ported']}, adapted {t['adapted']}, na_api {t['na_api']}, na_python {t['na_python']}")
    for m, c in report["modules"].items():
        print(f"  {m:24s} {c['total']:4d}  ported {c['ported']:3d}  adapted {c['adapted']:3d}  na_api {c['na_api']:3d}  na_python {c['na_python']:3d}")
for p in problems:
    print("✘", p)
sys.exit(1 if problems else 0)
