#!/usr/bin/env python3
"""Generate the current guide from the asserting conversion record. --check does not write."""
import html
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
d = json.loads((ROOT / 'docs/interoperability.json').read_text())
e = html.escape
meta = d['meta']; rows = d['directions']
version = json.loads((ROOT / 'scripts/spec-feature-matrix.json').read_text())['meta']['library_version']
if meta['library_version'] != version:
    raise SystemExit('Interoperability measurement is not for the current release; re-measure it')
formats = {'xlsx', 'ods', 'numbers'}
if len(rows) != 9 or {(r['from'], r['to']) for r in rows} != {(a, b) for a in formats for b in formats}:
    raise SystemExit('The measurement must contain each of nine directions exactly once')
style = re.search(r'<style>(.*?)</style>', (ROOT / 'docs/format-support.html').read_text(), re.S).group(1)
parts = [f'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Interoperability guide — Excel, ODS and Numbers (SwiftSheets {e(meta['library_version'])})</title>
<style>{style}</style></head><body><main>
<h1>Interoperability guide — Excel, ODS and Numbers</h1>
<p class="lede">Conversions carry supported values and features through a common model. Inspect both read and write warnings before accepting a converted file.</p>
<p class="meta">Measured {e(meta['measured'])} / SwiftSheets {e(meta['library_version'])} / {e(meta['scope'])}.</p>
<section><h2>How to read this measurement</h2>
<p>The kitchen-sink workbook is first saved in each format and read back to form the source file. Each source is then
written to all three destinations. A feature lost before the source file was created is not counted as a loss of this
conversion. A zero here is not a guarantee that arbitrary files, opaque parts or visual layout survive.</p>
<p>The probe detects 48 features, including presence of a formula, style, validation or print setting. It is binary:
features rewritten in another shape can be absent from this profile without every aspect being dropped.
For example, a Numbers pivot reads as an ordinary summary table, and a quote formula can become a cached value.
One warning can describe several losses; warnings can also describe degradation without a binary loss.</p>
<p>See the <a href="spec-feature-matrix.html">feature matrix</a> for separate read/write capabilities,
and <a href="format-support.html">format support</a> for per-feature restrictions.
Charts, images and shapes have dedicated tests and are not part of this 48-feature kitchen-sink profile.</p></section>
<section><h2>All nine directions</h2><div class="tablewrap"><table>
<thead><tr><th>Source → destination</th><th>Source features detected</th><th>Features no longer detected</th><th>Write warnings</th><th>Suggested format</th></tr></thead><tbody>''']
for r in rows:
    parts.append(f"<tr><td>{e(r['from'])} → {e(r['to'])}</td><td>{r['sourceFeatures']} / {r['featureCount']}</td><td>{len(r['lost'])}</td><td>{len(r['warnings'])}</td><td>{e(r['suggestion']) or '—'}</td></tr>")
parts += ['</tbody></table></div></section><section><h2>Losses and warnings by direction</h2>']
for r in rows:
    parts.append(f"<details><summary>{e(r['from'])} → {e(r['to'])}</summary><p>Features no longer detected: {e(', '.join(r['lost'])) or 'none'}.</p><ul>")
    parts.extend(f'<li>{e(w)}</li>' for w in r['warnings'])
    if not r['warnings']: parts.append('<li>No write warnings for this probe.</li>')
    parts.append('</ul></details>')
parts += ['''</section><section><h2>Current conversion boundaries</h2>
<ul><li>ODS supports rich text, validations, conditional formatting and supported chart/shape types. Pivots are written
as data-pilot layouts for the opening application to recalculate. Unsupported objects are reported.</li>
<li>Numbers supports rich text and run hyperlinks, inline-list validations as pop-up menus, cell controls,
several pivot fields per axis with one summarised value, supported canvas objects and some print settings.
A pivot summary reads as an ordinary table. Arrays, protected ranges, defined names and unsupported settings have
explicit restrictions in the feature matrix.</li>
<li>Only one table per sheet is representable in XLSX/ODS; extra Numbers tables are reported as dropped.
Cell controls become their selected values. Supported Numbers canvas objects can be converted; unsupported types
are reported rather than described as absent from the format.</li></ul></section>
<section><h2>Saving in the same format</h2><div class="tablewrap"><table>
<tr><th>Format</th><th>Preservation boundary</th></tr>
<tr><td>XLSX / XLSM</td><td>Whole-workbook same-format saves retain uninterpreted parts byte for byte (F3).
Modelled content is regenerated with equivalent meaning; VBA requires XLSM. This is not identical ZIP output.</td></tr>
<tr><td>ODS</td><td>Supported content, including pictures and supported charts/shapes, is reconstructed (F2).
Some opaque embedded objects remain unlinked and are reported. This is not full opaque-part preservation.</td></tr>
<tr><td>Numbers</td><td>Every save starts from the template. Supported content is regenerated; no F3 preservation.</td></tr>
</table></div><p>Streaming carries values and formatting and has no opaque-part preservation.</p></section>
<section><h2>Verification and reproducibility</h2>
<p><code>CrossFormatConversionTests.everyLossIsNamedByItsOwnWarning</code> asserts named warnings for all nine
conversions. The three-generation tests check that repeated saves keep detected features and well-formed XML.
The measurement collector requires a successful test run and all nine records before replacing its source.</p>
<pre><code>python3 scripts/measure-interoperability.py
python3 scripts/build-interoperability-page.py
python3 scripts/build-interoperability-page.py --check
swift test --filter CrossFormatConversionTests
swift test --filter FormatSupportTests</code></pre>
<p>Library round trips do not prove application rendering. Independent checks are provided by
<code>Tests/OpenpyxlParity/verify_with_openpyxl.py</code>,
<code>Tests/NumbersParity/verify_with_numbers_parser.py</code> and
<code>Tests/NumbersParity/verify_with_numbers_app.py</code>; see <a href="../MAINTENANCE.md">maintenance</a>
for requirements and visual release checks. An unavailable judge is not a pass.</p>
<p>Historical defects and the 2026-08-27 sweep are recorded in the dated appendices of the
<a href="implementation-spec.html">implementation spec</a> (B.22–B.23). They do not describe today's capability limits.</p></section>''',
f'<footer>Toolchain: {e(meta["swift"])}<br>Measurement base commit: {e(meta["commit"])} (working-tree changes may be present).</footer>',
'<script type="application/json" id="measurement">' + json.dumps(d, ensure_ascii=False).replace('<', '\\u003c') + '</script>',
'</main></body></html>']
page = '\n'.join(parts) + '\n'
p = ROOT / 'docs/interoperability.html'
if '--check' in sys.argv:
    if not p.exists() or p.read_text() != page: raise SystemExit('Interoperability page differs from its measurement; regenerate it')
    print('Interoperability page matches its complete nine-direction measurement')
else:
    p.write_text(page)
    print('Generated docs/interoperability.html')
