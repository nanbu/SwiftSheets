#!/usr/bin/env python3
"""The performance record (spec Appendix B.39.11, Rev 4.30): every operation the library offers, measured at the
two sizes of the standard — 100 columns × 10,000 rows (a million cells: a data-heavy everyday file) and
100 columns × 100,000 rows (ten million cells: a large one) — and written to docs/performance.json. The README's
numbers are the first tier's; the page docs/performance.html shows both.

    scripts/bench.sh                     # both tiers; rebuilds the bench in release first
    scripts/bench.sh --rows 10000        # one tier (a subset is recorded as such — the page says which)
    scripts/bench.sh --no-page           # write the JSON without regenerating the page
    scripts/bench.sh --self-test         # the guards decide as documented
    scripts/bench.sh --from-log <path>   # rebuild the JSON from a run's log (its JSON lines, in plan order) without measuring again

Every measurement is its own process (peak memory is a process's lifetime maximum), from a release build made
fresh (an incremental build once mixed stale parts into a measurement). A size can be past what a machine can
hold: a whole-model operation is measured only when its projected peak (cells × 320 bytes — the largest per-cell
peak seen in the million-cell record) fits in 60% of physical memory, and an operation that writes a file only
when the free disk is 1.5× the room it needs (the ODS streaming write spills the rows uncompressed while it
runs). Anything else is recorded as skipped, with the reason, so the page never shows a blank where a number
should be and never quotes a number the machine could not have made. Both tiers fit an 8 GB machine; the guards
stay for a smaller one.

Readers are measured on the whole-model writer's file (the file an application writes) and again on the
streaming writer's — the second reading is what found the piece-boundary fault of Rev 4.28 — and the record
keeps both, labelled by file; nothing picks one silently.
"""
import json, os, re, subprocess, sys, datetime, platform, shutil, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(ROOT, "Benchmarks")
TARGET = os.path.join(ROOT, "docs", "performance.json")
COLUMNS = 100
SIZES = [10_000, 100_000]
README_TIER = 10_000            # the tier the README's numbers come from
BYTES_PER_CELL_PEAK = 320          # whole-model operations: the largest per-cell peak in the million-cell record
MEMORY_SHARE = 0.6
DISK_MARGIN = 1.5
# bytes of disk an operation needs per cell: the file it writes, plus what it holds on disk while writing
DISK_PER_CELL = {"write": 15, "streamWrite": 15, "writeSheets": 15, "edit": 30, "writeODS": 20, "streamWriteODS": 75,
                 "writeCSV": 25, "streamWriteCSV": 25, "writeNumbers": 60, "streamWriteNumbers": 60}
WHOLE_MODEL = {"build", "write", "read", "writeSheets", "readSheetsSerial", "readSheets", "edit",
               "writeODS", "readODS", "writeCSV", "readCSV", "writeNumbers", "readNumbers"}
# the operations that take a file: measured on the whole-model writer's file and again on the streaming writer's
READERS = {"read", "streamRead", "readODS", "streamReadODS", "readCSV", "streamReadCSV", "readNumbers",
           "streamReadNumbers", "detect", "inspect", "readSheetsSerial", "readSheets", "edit"}

# (op, file, needs) in an order that lets each format's files go as soon as their readers are done
PLAN = [
    ("build", "bench.xlsx", None),
    ("write", "bench.xlsx", None), ("read", "bench.xlsx", "write"), ("streamRead", "bench.xlsx", "write"),
    ("edit", "bench.xlsx", "write"), ("detect", "bench.xlsx", "write"), ("inspect", "bench.xlsx", "write"),
    ("streamWrite", "stream.xlsx", None), ("streamRead", "stream.xlsx", "streamWrite"),
    ("detect", "stream.xlsx", "streamWrite"), ("inspect", "stream.xlsx", "streamWrite"),
    ("writeSheets", "sheets.xlsx", None), ("readSheetsSerial", "sheets.xlsx", "writeSheets"), ("readSheets", "sheets.xlsx", "writeSheets"),
    ("writeODS", "bench.ods", None), ("readODS", "bench.ods", "writeODS"), ("streamReadODS", "bench.ods", "writeODS"),
    ("streamWriteODS", "stream.ods", None), ("streamReadODS", "stream.ods", "streamWriteODS"),
    ("writeCSV", "bench.csv", None), ("readCSV", "bench.csv", "writeCSV"), ("streamReadCSV", "bench.csv", "writeCSV"),
    ("streamWriteCSV", "stream.csv", None), ("streamReadCSV", "stream.csv", "streamWriteCSV"),
    ("writeNumbers", "bench.numbers", None), ("readNumbers", "bench.numbers", "writeNumbers"), ("streamReadNumbers", "bench.numbers", "writeNumbers"),
    ("streamWriteNumbers", "stream.numbers", None), ("streamReadNumbers", "stream.numbers", "streamWriteNumbers"),
]


def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True).strip()
    except Exception:
        return ""


def decide(op, cells, memory_bytes, free_bytes):
    """None when the operation may run; otherwise the reason it is not measured on this machine."""
    if op in WHOLE_MODEL:
        need = cells * BYTES_PER_CELL_PEAK
        if need > memory_bytes * MEMORY_SHARE:
            return "見込みピーク %.1f GB が実メモリ %d GB の 6 割を超える" % (need / 2**30, round(memory_bytes / 2**30))
    if op in DISK_PER_CELL:
        need = cells * DISK_PER_CELL[op] * DISK_MARGIN
        if need > free_bytes:
            return "空きディスク %.1f GB では足りない（%.1f GB 要る）" % (free_bytes / 2**30, need / 2**30)
    return None


def measure(binary, rows, outdir, log):
    cells = rows * COLUMNS
    memory = int(sh("sysctl -n hw.memsize") or 0)
    results, skipped, done, files = [], [], {}, {}
    env = dict(os.environ, SWIFTSHEETS_BENCH_COLUMNS=str(COLUMNS))
    seen = set()
    for op, name, needs in PLAN:
        # a file's readers are done once the plan moves on to another file: let it go, the disk is small
        for other in list(files):
            if other != name and other not in [n for _, n, _ in PLAN[PLAN.index((op, name, needs)):]]:
                try: os.remove(files.pop(other))
                except OSError: pass
        key = (op, name)
        if key in seen:
            continue
        seen.add(key)
        if needs and not done.get((needs, name)):
            skipped.append({"op": op, "file": name, "reason": "%s を測っていないので材料が無い" % needs}); continue
        reason = decide(op, cells, memory, shutil.disk_usage(outdir).free)
        if reason:
            skipped.append({"op": op, "file": name, "reason": reason})
            print("skip %-20s %s" % (op, reason), file=sys.stderr)
            continue
        path = os.path.join(outdir, name)
        proc = subprocess.run([binary, op, str(rows), path], env=env, capture_output=True, text=True)
        if proc.returncode != 0:
            skipped.append({"op": op, "file": name, "reason": "落ちた: " + proc.stderr.strip()[-200:]})
            print("FAIL %-20s %s" % (op, proc.stderr.strip()[-200:]), file=sys.stderr)
            continue
        line = json.loads(proc.stdout.strip().splitlines()[-1])
        line["file"] = name
        results.append(line)
        done[key] = True
        files[name] = path
        print(proc.stdout.strip().splitlines()[-1], file=log, flush=True)
        print(proc.stdout.strip().splitlines()[-1], file=sys.stderr)
    return {"rows": rows, "cells": cells, "results": results, "skipped": skipped}


def readme_numbers(tier):
    """The numbers the README quotes, by name, so a test can hold the README to them — read off the whole-model
    writer's file, the file an application writes."""
    def peak(op):
        # a reader has two measurements, one per file; a writer's file is its own output, whatever its name
        hit = next((r for r in tier["results"] if r["op"] == op and not (op in READERS and r.get("file", "").startswith("stream"))), None)
        if hit is None:
            sys.exit("❌ the README needs %s at %s rows and it was not measured" % (op, tier["rows"]))
        return round(hit["peakMB"])
    return {
        "streaming_write_peak_mb": peak("streamWrite"),
        "streaming_write_ods_peak_mb": peak("streamWriteODS"),
        "streaming_write_numbers_peak_mb": peak("streamWriteNumbers"),
        "streaming_read_peak_mb": peak("streamRead"),
        "streaming_read_ods_peak_mb": peak("streamReadODS"),
        "streaming_read_numbers_peak_mb": peak("streamReadNumbers"),
        "whole_model_read_peak_mb": peak("read"),
        "read_8_sheets_serial_peak_mb": peak("readSheetsSerial"),
        "read_8_sheets_parallel_peak_mb": peak("readSheets"),
    }


def main(argv):
    if "--self-test" in argv:
        return self_test()
    sizes = SIZES
    if "--rows" in argv:
        sizes = [int(x) for x in argv[argv.index("--rows") + 1].split(",")]
    if "--from-log" in argv:
        return write_record(tiers_from_log(argv[argv.index("--from-log") + 1]), argv)
    if "--no-build" not in argv:
        print("building the bench (release, from scratch)…", file=sys.stderr)
        shutil.rmtree(os.path.join(BENCH_DIR, ".build"), ignore_errors=True)
        subprocess.run("swift build -c release 2>&1 | tail -1 >&2", shell=True, cwd=BENCH_DIR, check=True)
    binary = os.path.join(BENCH_DIR, ".build", "release", "swiftsheets-bench")
    tiers = []
    log_path = os.path.join(tempfile.gettempdir(), "swiftsheets-bench.log")
    with open(log_path, "w", encoding="utf-8") as log:
        for rows in sizes:
            outdir = tempfile.mkdtemp(prefix="swiftsheets-bench-")
            try:
                print("=== %s columns × %s rows" % (COLUMNS, rows), file=sys.stderr)
                tiers.append(measure(binary, rows, outdir, log))
            finally:
                shutil.rmtree(outdir, ignore_errors=True)
    return write_record(tiers, argv)


def tiers_from_log(path):
    """The tiers of a run, from its log: one JSON line per measured plan entry, in plan order, under a
    "=== N columns × R rows" heading per tier; skipped entries print "skip <op> <reason>" and are recorded as such."""
    tiers, tier, plan = [], None, []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        m = re.match(r"=== (\d+) columns × (\d+) rows", line)
        if m:
            tier = {"rows": int(m.group(2)), "cells": int(m.group(2)) * int(m.group(1)), "results": [], "skipped": []}
            tiers.append(tier); plan = list(PLAN)
            continue
        if tier is None or not plan:
            continue
        if line.startswith("skip "):
            op, name, _ = plan.pop(0)
            tier["skipped"].append({"op": op, "file": name, "reason": line[len("skip "):].split(None, 1)[1]})
        elif line.startswith("{"):
            op, name, _ = plan.pop(0)
            entry = json.loads(line)
            if entry["op"] != op:
                sys.exit("❌ the log is not in plan order: expected %s, found %s" % (op, entry["op"]))
            entry["file"] = name
            tier["results"].append(entry)
    return tiers


def write_record(tiers, argv):
    version = re.search(r'version = "([^"]+)"', open(os.path.join(ROOT, "Sources", "SheetCore", "SwiftSheetsInfo.swift"), encoding="utf-8").read()).group(1)
    memsize = sh("sysctl -n hw.memsize")
    meta = {
        "date": datetime.date.today().isoformat(),
        "commit": sh("git rev-parse --short HEAD"),
        "columns": COLUMNS, "tiers": [t["rows"] for t in tiers], "readme_tier": README_TIER,
        "machine": sh("sysctl -n machdep.cpu.brand_string") or platform.processor(),
        "memory_gb": round(int(memsize) / 2**30) if memsize else None,
        "os": sh("sw_vers -productVersion") or platform.platform(),
        "swift": sh("swift --version 2>&1 | head -1"),
        "material": "synthetic, %d columns: a label, five integers, three decimals and a Japanese category, repeated across the width with the numbers offset per block; the text columns past the first block draw on a vocabulary of fifty; one sheet; no formatting" % COLUMNS,
        "library_version": version,
    }
    doc = {"meta": meta, "tiers": tiers}
    first = next((t for t in tiers if t["rows"] == README_TIER), None)
    if first is not None:
        doc["readme"] = readme_numbers(first)
    else:
        print("⚠️ the %s-row tier was not measured: the README's numbers are left as they were" % README_TIER, file=sys.stderr)
        try:
            with open(TARGET, encoding="utf-8") as fh:
                doc["readme"] = json.load(fh).get("readme", {})
        except FileNotFoundError:
            doc["readme"] = {}
    with open(TARGET, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print("wrote", TARGET, file=sys.stderr)
    if "--no-page" not in argv:
        subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "build-performance-page.py")], check=True)
    return 0


def self_test():
    ok = True
    def t(name, cond):
        nonlocal ok
        print("  %s %s" % ("✅" if cond else "❌", name)); ok = ok and cond
    gb = 2**30
    t("100 万マスの全載せは 8 GB の機械で測る", decide("read", 1_000_000, 8 * gb, 100 * gb) is None)
    t("1,000 万マスの全載せは 8 GB の機械で測る（3.2 GB < 4.8 GB）", decide("read", 10_000_000, 8 * gb, 100 * gb) is None)
    t("1,000 万マスの全載せは 4 GB の機械では測らない、と理由を言う", "6 割" in (decide("read", 10_000_000, 4 * gb, 100 * gb) or ""))
    t("1,000 万マスの逐次読みはメモリの検査を受けない", decide("streamRead", 10_000_000, 4 * gb, 100 * gb) is None)
    t("空きディスクが足りない書き出しは測らない、と理由を言う", "ディスク" in (decide("streamWriteODS", 10_000_000, 8 * gb, 1 * gb) or ""))
    t("空きディスクが足りていれば測る", decide("streamWriteODS", 10_000_000, 8 * gb, 2 * gb) is None)
    t("計画の材料はすべて先に作られる", all(needs is None or any(o == needs and n == name for o, n, _ in PLAN[:i]) for i, (op, name, needs) in enumerate(PLAN)))
    numbers = readme_numbers({"rows": 1, "results": [
        {"op": op, "file": "stream.x" if op.startswith("streamWrite") else "bench.x", "peakMB": 1.4}
        for op in ["streamWrite", "streamWriteODS", "streamWriteNumbers", "streamRead", "streamReadODS", "streamReadNumbers", "read", "readSheetsSerial", "readSheets"]]
        + [{"op": "streamRead", "file": "stream.x", "peakMB": 9}]})
    t("README の読みの数字は全載せで書いたファイルの読みから採る", numbers["streaming_read_peak_mb"] == 1)
    t("README の書きの数字は、その書きが作ったファイルの名前によらず採る", numbers["streaming_write_peak_mb"] == 1)
    print("✅ self-test 全緑" if ok else "❌ self-test 赤")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
