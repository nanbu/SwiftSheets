#!/bin/bash
# bench.sh — measure the library and write docs/performance.json (spec Appendix B.39.11).
#
#   scripts/bench.sh [rows]          # default 100000 rows × 10 columns = a million cells
#
# Every measurement runs in its own process (peak memory is a process's lifetime maximum), from a release build
# of Benchmarks/ made fresh (an incremental build once mixed stale parts into a measurement). The JSON carries the
# machine, the toolchain and the commit, so a number is never quoted without its provenance. The page
# docs/performance.html is generated from the JSON by scripts/build-performance-page.py, which also checks that the
# README quotes the same numbers.
set -euo pipefail
ROWS="${1:-100000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH="$ROOT/Benchmarks"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "building the bench (release, from scratch)…" >&2
rm -rf "$BENCH/.build"
(cd "$BENCH" && swift build -c release 2>&1 | tail -1 >&2)
B="$BENCH/.build/release/swiftsheets-bench"

run() { "$B" "$@" | tee -a "$OUT/lines.jsonl" >&2; }
X="$OUT/bench.xlsx"; O="$OUT/bench.ods"; C="$OUT/bench.csv"
run build "$ROWS" "$X"
run write "$ROWS" "$X"
run read "$ROWS" "$X"
run streamRead "$ROWS" "$X"
run streamWrite "$ROWS" "$OUT/stream.xlsx"
run edit "$ROWS" "$X"
run detect "$ROWS" "$X"
run inspect "$ROWS" "$X"
run writeODS "$ROWS" "$O"
run readODS "$ROWS" "$O"
run streamReadODS "$ROWS" "$O"
run writeCSV "$ROWS" "$C"
run readCSV "$ROWS" "$C"
run streamReadCSV "$ROWS" "$C"
run writeNumbers "$ROWS" "$OUT/bench.numbers"
run readNumbers "$ROWS" "$OUT/bench.numbers"
run streamReadNumbers "$ROWS" "$OUT/bench.numbers"

python3 - "$OUT/lines.jsonl" "$ROOT/docs/performance.json" "$ROWS" <<'PY'
import json, platform, re, subprocess, sys, datetime
lines, target, rows = sys.argv[1], sys.argv[2], int(sys.argv[3])
results = [json.loads(l) for l in open(lines, encoding="utf-8") if l.strip()]
def sh(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True).strip()
    except Exception: return ""
meta = {
    "date": datetime.date.today().isoformat(),
    "commit": sh("git rev-parse --short HEAD"),
    "rows": rows, "columns": 10, "cells": rows * 10,
    "machine": sh("sysctl -n machdep.cpu.brand_string") or platform.processor(),
    "memory_gb": round(int(sh("sysctl -n hw.memsize") or 0) / 2**30) if sh("sysctl -n hw.memsize") else None,
    "os": sh("sw_vers -productVersion") or platform.platform(),
    "swift": (sh("swift --version 2>&1 | head -1")),
    "material": "synthetic: a label, five integers, three decimals and a Japanese category per row; one sheet; no formatting",
    "library_version": re.search(r'version = "([^"]+)"', open("Sources/SheetCore/SwiftSheetsInfo.swift", encoding="utf-8").read()).group(1),
}
by = {r["op"]: r for r in results}
# the numbers the README quotes, by name, so a test can hold the README to them
readme = {
    "streaming_write_peak_mb": round(by["streamWrite"]["peakMB"]),
    "streaming_read_peak_mb": round(by["streamRead"]["peakMB"]),
    "streaming_read_ods_peak_mb": round(by["streamReadODS"]["peakMB"]),
    "streaming_read_numbers_peak_mb": round(by["streamReadNumbers"]["peakMB"]),
    "whole_model_read_peak_mb": round(by["read"]["peakMB"]),
}
json.dump({"meta": meta, "readme": readme, "results": results}, open(target, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("wrote", target)
PY
python3 "$ROOT/scripts/build-performance-page.py"
