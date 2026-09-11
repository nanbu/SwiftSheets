#!/usr/bin/env python3
"""The performance record, built from one source: docs/performance.json is the source, docs/performance.html the product.

    scripts/bench.sh                                  # measures, writes docs/performance.json, then calls this script
    python3 scripts/build-performance-page.py         # rebuilds the page from the JSON
    python3 scripts/build-performance-page.py --check # the page matches the JSON and the README's numbers match it too (for CI)

Numbers are checked, not remembered (Appendix B.39.11). The record keeps the two tiers of the standard (100 columns x 10,000 rows
and x 100,000 rows) in one list, "tiers", in the JSON; the numbers the README's Limits row quotes (the peak MB of the streaming
write for xlsx / ods / numbers, the streaming read for xlsx / ods / numbers, the whole model, and eight sheets read one at a time
and side by side) are placed by name under "readme" from the first tier, and --check holds the README's text to them. The look is
borrowed from the <style> of docs/format-support.html, so the two pages cannot drift apart.
"""
import json
import os
import re
import sys
import html

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "docs", "performance.json")
STYLE_FROM = os.path.join(ROOT, "docs", "format-support.html")
OUT_HTML = os.path.join(ROOT, "docs", "performance.html")
README = os.path.join(ROOT, "README.md")

LABELS = {
    "build": ("Build the model", "put every cell into a Workbook (no file)"),
    "write": ("Write (xlsx)", "model -> .xlsx"),
    "read": ("Read (xlsx)", ".xlsx -> model, then sum every cell"),
    "streamRead": ("Streaming read (xlsx)", "StreamingReader, row by row, then sum every cell"),
    "streamWrite": ("Streaming write (xlsx)", "StreamingWriter, row by row"),
    "writeSheets": ("Write (xlsx, 8 sheets)", "the same cells split across 8 sheets, model -> .xlsx"),
    "readSheetsSerial": ("Read (xlsx, 8 sheets, one at a time)", "ReadOptions(concurrency: 1), then sum every cell"),
    "readSheets": ("Read (xlsx, 8 sheets, side by side)", "the default (sheets read concurrently), then sum every cell"),
    "edit": ("Open, change one cell, save", ".xlsx -> model -> .xlsx"),
    "detect": ("Format detection", "SheetFormat.detect(contentsOf:), per call"),
    "inspect": ("Inspect before reading", "Workbook.inspect(contentsOf:)"),
    "writeODS": ("Write (ods)", "model -> .ods"),
    "readODS": ("Read (ods)", ".ods -> model"),
    "streamReadODS": ("Streaming read (ods)", "StreamingReader, row by row, then sum every cell"),
    "streamWriteODS": ("Streaming write (ods)", "StreamingWriter, row by row"),
    "writeCSV": ("Write (csv)", "model -> .csv"),
    "readCSV": ("Read (csv)", ".csv -> model (with type inference)"),
    "streamReadCSV": ("Streaming read (csv)", "CSVStreamingReader, row by row"),
    "streamWriteCSV": ("Streaming write (csv)", "CSVStreamingWriter, row by row"),
    "writeNumbers": ("Write (numbers)", "model -> .numbers"),
    "readNumbers": ("Read (numbers)", ".numbers -> model, then sum every cell"),
    "streamReadNumbers": ("Streaming read (numbers)", "StreamingReader, row by row, then sum every cell"),
    "streamWriteNumbers": ("Streaming write (numbers)", "StreamingWriter, row by row"),
}


def e(s):
    return html.escape(str(s), quote=True)


def load_style():
    with open(STYLE_FROM, encoding="utf-8") as fh:
        m = re.search(r"<style>(.*?)</style>", fh.read(), re.S)
    if not m:
        sys.exit("❌ no <style> could be taken from %s" % STYLE_FROM)
    return m.group(1)


def fmt_sec(sec):
    if sec >= 0.01:
        return "%.2f s" % sec
    if sec >= 0.0005:
        return "%.1f ms" % (sec * 1000)
    return "under 1 ms"


READERS_OF_A_FILE = {"read", "streamRead", "readODS", "streamReadODS", "readCSV", "streamReadCSV", "readNumbers",
                     "streamReadNumbers", "detect", "inspect", "readSheetsSerial", "readSheets", "edit"}


def row_key(r):
    """One row per operation — and a second row for a reader measured on the streaming writer's file, labelled so,
    since nothing picks one of the two silently (Appendix B.39.11, Rev 4.30)."""
    return (r["op"], r["op"] in READERS_OF_A_FILE and r.get("file", "").startswith("stream"))


def render(doc):
    meta, tiers = doc["meta"], doc["tiers"]
    out = []
    w = out.append
    sizes = " / ".join("{:,} rows".format(t["rows"]) for t in tiers)
    w("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
    w("<title>The performance record — time and memory to read and write %s columns x %s (SwiftSheets %s)</title>" % (e(meta["columns"]), e(sizes), e(meta.get("library_version", ""))))
    w("<style>%s</style>\n</head>\n<body>\n<main>" % load_style())
    w("<h1>The performance record</h1>")
    w("<p class=\"lead\">The time and peak memory of reading and writing synthetic data at a fixed width of %s columns and %s (%s) — the standard of Appendix B.39.11. "
      "These numbers are not remembered but measured by <code>scripts/bench.sh</code>; the numbers the README quotes are those of the %s-row tier, and they are checked by machine against this page's source. "
      "A cell that could not be measured says why — an operation this machine's physical memory or free disk cannot hold is decided against, and recorded, before it can fall over.</p>"
      % (e(meta["columns"]), e(sizes), e(" / ".join("{:,} cells".format(t["cells"]) for t in tiers)), e("{:,}".format(meta.get("readme_tier", tiers[0]["rows"])))))
    w("<div style=\"overflow-x:auto\"><table><thead><tr><th>Measurement</th>")
    for t in tiers:
        w("<th colspan=\"2\">{:,} rows ({:,} cells)</th>".format(t["rows"], t["cells"]))
    w("</tr><tr><th>What was done</th>" + "".join("<th>Time</th><th>Peak memory</th>" for _ in tiers) + "</tr></thead><tbody>")
    keys = []
    for t in tiers:
        for r in t["results"] + t.get("skipped", []):
            k = row_key(r)
            if k not in keys: keys.append(k)
    for op, streamed in keys:
        label, what = LABELS.get(op, (op, ""))
        if streamed: label += " (the streaming writer's file)"
        w("<tr><td>%s<br><small>%s</small></td>" % (e(label), e(what)))
        for t in tiers:
            hit = next((r for r in t["results"] if row_key(r) == (op, streamed)), None)
            if hit:
                extra = ""
                m = re.search(r"modelMB=([\d.]+)", hit.get("note", ""))
                if m: extra = "<br><small>of which the model: %s MB</small>" % e(m.group(1))
                w("<td>%s</td><td>%s MB%s</td>" % (e(fmt_sec(hit["sec"])), e(hit["peakMB"]), extra))
            else:
                skip = next((r for r in t.get("skipped", []) if row_key(r) == (op, streamed)), None)
                w("<td colspan=\"2\"><small>not measurable (%s)</small></td>" % e(skip["reason"] if skip else "not measured"))
        w("</tr>")
    w("</tbody></table></div>")
    w("<h2>Conditions of measurement</h2><ul>")
    w("<li>Date: %s, commit: <code>%s</code></li>" % (e(meta["date"]), e(meta["commit"])))
    w("<li>Machine: %s, %s GB of memory, %s</li>" % (e(meta["machine"]), e(meta.get("memory_gb", "?")), e(meta["os"])))
    w("<li>Toolchain: %s, release build</li>" % e(meta["swift"]))
    w("<li>Material: %s. <strong>Synthetic data gives synthetic numbers</strong>: a real workbook, heavy with formatting and drawings, is heavier than this.</li>" % e(meta["material"]))
    w("<li>Peak memory is the process's lifetime maximum (<code>ru_maxrss</code>), which is why every measurement runs in a process of its own.</li>")
    w("<li>A reading figure is taken on the file the whole-model writer wrote (the file an application writes). The figure taken on the streaming writer's file is shown separately, in the row marked \"the streaming writer's file\".</li>")
    w("</ul>")
    w("<h2>Measuring on your own machine</h2>")
    w("<pre><code>scripts/bench.sh                # both tiers: rebuilds Benchmarks/ in release, measures, writes docs/performance.json\n"
      "scripts/bench.sh --rows 10000   # one tier only\n"
      "python3 scripts/build-performance-page.py --check   # this page and the README's numbers match the source</code></pre>")
    w("</main>\n</body>\n</html>\n")
    return "\n".join(out)


def readme_claims(doc):
    """The README quotes the numbers by name; each must appear as **N MB** in the Limits row."""
    with open(README, encoding="utf-8") as fh:
        text = fh.read()
    row = next((l for l in text.splitlines() if l.startswith("| Whole workbook in memory |")), "")
    problems = []
    for key, value in doc["readme"].items():
        if "**%d MB**" % value not in row:
            problems.append("the README's Limits row lacks **%d MB** (%s)" % (value, key))
    return problems


def main():
    check = "--check" in sys.argv[1:]
    with open(SOURCE, encoding="utf-8") as fh:
        doc = json.load(fh)
    page = render(doc)
    if check:
        ok = True
        try:
            with open(OUT_HTML, encoding="utf-8") as fh:
                if fh.read() != page:
                    print("❌ the product does not match the source: docs/performance.html (run python3 scripts/build-performance-page.py)")
                    ok = False
        except FileNotFoundError:
            print("❌ docs/performance.html is missing")
            ok = False
        for p in readme_claims(doc):
            print("❌ " + p)
            ok = False
        if not ok:
            sys.exit(1)
        print("✅ the performance record's page and the README's numbers both match the source")
        return
    with open(OUT_HTML, "w", encoding="utf-8") as fh:
        fh.write(page)
    print("✅ docs/performance.html (%d B)" % len(page.encode("utf-8")))
    for p in readme_claims(doc):
        print("⚠️ " + p)


if __name__ == "__main__":
    main()
