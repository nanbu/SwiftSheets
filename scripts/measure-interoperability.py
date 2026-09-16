#!/usr/bin/env python3
"""Run the asserting nine-direction suite and save its opt-in measurement, never a failed/partial run."""
import datetime
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
env = dict(os.environ, SWIFTSHEETS_INTEROPERABILITY_RECORD='1')
run = subprocess.run(['swift', 'test', '--filter', 'CrossFormatConversionTests.everyLossIsNamedByItsOwnWarning'],
                     cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
if run.returncode:
    print(run.stdout)
    raise SystemExit(run.returncode)
prefix = 'SWIFTSHEETS_INTEROPERABILITY '
rows = [json.loads(line.split(prefix, 1)[1]) for line in run.stdout.splitlines() if prefix in line]
formats = {'xlsx', 'ods', 'numbers'}
if len(rows) != 9 or {(r['from'], r['to']) for r in rows} != {(a, b) for a in formats for b in formats}:
    raise SystemExit('Measurement missing, duplicated or incomplete; record not updated')
if any(r['featureCount'] != 48 for r in rows):
    raise SystemExit('Unexpected probe size; review the page before recording')
version = json.loads((ROOT / 'scripts/spec-feature-matrix.json').read_text())['meta']['library_version']
record = {'meta': {'library_version': version, 'measured': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
                  'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                  'scope': 'Synthetic 48-feature whole-workbook write/read probe; library reader, not an application rendering measurement'},
          'directions': sorted(rows, key=lambda r: (r['from'], r['to']))}
(ROOT / 'docs/interoperability.json').write_text(json.dumps(record, indent=2, ensure_ascii=False) + '\n')
print('Recorded all nine asserting conversion measurements in docs/interoperability.json')
