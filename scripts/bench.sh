#!/bin/bash
# bench.sh — measure the library and write docs/performance.json (spec Appendix B.39.11).
#
#   scripts/bench.sh                  # the standard: 100 columns × 10,000 rows and × 100,000 rows (scripts/bench.py)
#   scripts/bench.sh --rows 10000     # one tier
#   scripts/bench.sh --self-test      # the guards decide as documented
#
# The work is scripts/bench.py; this entry point is the name the README, the page and the spec use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/bench.py" "$@"
