#!/usr/bin/env python3
"""The 200-column standard (spec Appendix B.39.11): the same operations as scripts/bench.sh, with the width fixed
at 200 columns and the rows at 5,000 / 50,000 / 500,000 — a million, ten million and a hundred million cells.

    scripts/bench.sh --grid                       # all three sizes; writes the "grid" of docs/performance.json
    scripts/bench-grid.py --rows 5000,50000       # a subset
    scripts/bench-grid.py --self-test             # the guards decide as documented

Every measurement is its own process, from a release build made fresh, exactly as bench.sh does. What is new is
that a size can be past what the machine can hold: a whole-model operation is measured only when its projected
peak (cells × 320 bytes — the largest per-cell peak in the million-cell record) fits in 60% of physical memory,
and an operation that writes a file only when the free disk is 1.5× the room it needs (the ODS streaming write
spills the rows uncompressed while it runs). Anything else is recorded as skipped, with the reason, so the
page never shows a blank where a number should be and never quotes a number the machine could not have made.
"""
import json, os, re, subprocess, sys, datetime, platform, shutil, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH_DIR = os.path.join(ROOT, "Benchmarks")
TARGET = os.path.join(ROOT, "docs", "performance.json")
COLUMNS = 200
SIZES = [5000, 50000, 500000]
BYTES_PER_CELL_PEAK = 320          # whole-model operations: the largest per-cell peak in the million-cell record
MEMORY_SHARE = 0.6
DISK_MARGIN = 1.5
# bytes of disk an operation needs per cell: the file it writes, plus what it holds on disk while writing
DISK_PER_CELL = {"write": 15, "streamWrite": 15, "writeSheets": 15, "edit": 30, "writeODS": 20, "streamWriteODS": 75,
                 "writeCSV": 25, "streamWriteCSV": 25, "writeNumbers": 60, "streamWriteNumbers": 60}
WHOLE_MODEL = {"build", "write", "read", "writeSheets", "readSheetsSerial", "readSheets", "edit",
               "writeODS", "readODS", "writeCSV", "readCSV", "writeNumbers", "readNumbers"}

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


def main(argv):
    if "--self-test" in argv:
        return self_test()
    sizes = SIZES
    if "--rows" in argv:
        sizes = [int(x) for x in argv[argv.index("--rows") + 1].split(",")]
    if "--no-build" not in argv:
        print("building the bench (release, from scratch)…", file=sys.stderr)
        shutil.rmtree(os.path.join(BENCH_DIR, ".build"), ignore_errors=True)
        subprocess.run("swift build -c release 2>&1 | tail -1 >&2", shell=True, cwd=BENCH_DIR, check=True)
    binary = os.path.join(BENCH_DIR, ".build", "release", "swiftsheets-bench")
    runs = []
    log_path = os.path.join(tempfile.gettempdir(), "swiftsheets-bench-grid.log")
    with open(log_path, "w", encoding="utf-8") as log:
        for rows in sizes:
            outdir = tempfile.mkdtemp(prefix="swiftsheets-grid-")
            try:
                print("=== %s columns × %s rows" % (COLUMNS, rows), file=sys.stderr)
                runs.append(measure(binary, rows, outdir, log))
            finally:
                shutil.rmtree(outdir, ignore_errors=True)
    with open(TARGET, encoding="utf-8") as fh:
        doc = json.load(fh)
    doc["grid"] = {
        "columns": COLUMNS, "date": datetime.date.today().isoformat(), "commit": sh("git rev-parse --short HEAD"),
        "memory_gb": round(int(sh("sysctl -n hw.memsize") or 0) / 2**30),
        "material": "synthetic, %d columns: the ten-column pattern of the million-cell record repeated across the width with the numbers offset per block; the text columns past the first block draw on a vocabulary of fifty" % COLUMNS,
        "runs": runs,
    }
    with open(TARGET, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    print("wrote", TARGET, file=sys.stderr)
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
    t("1 億マスの全載せは 8 GB の機械では測らない、と理由を言う", "6 割" in (decide("read", 100_000_000, 8 * gb, 100 * gb) or ""))
    t("1 億マスの逐次読みはメモリの検査を受けない", decide("streamRead", 100_000_000, 8 * gb, 100 * gb) is None)
    t("空きディスクが足りない書き出しは測らない、と理由を言う", "ディスク" in (decide("streamWriteODS", 100_000_000, 64 * gb, 5 * gb) or ""))
    t("空きディスクが足りていれば測る", decide("streamWriteODS", 100_000_000, 64 * gb, 20 * gb) is None)
    t("計画の材料はすべて先に作られる", all(needs is None or any(o == needs and n == name for o, n, _ in PLAN[:i]) for i, (op, name, needs) in enumerate(PLAN)))
    print("✅ self-test 全緑" if ok else "❌ self-test 赤")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
