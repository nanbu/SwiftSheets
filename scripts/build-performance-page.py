#!/usr/bin/env python3
"""速さの記録を 1 つの出所から作る — 出所は docs/performance.json、生成物は docs/performance.html。

    scripts/bench.sh                                  # 計測して docs/performance.json を書き、このスクリプトを呼ぶ
    python3 scripts/build-performance-page.py         # JSON からページを作り直す
    python3 scripts/build-performance-page.py --check # ページが JSON と一致し、README の数字も JSON と一致するか（CI 向け）

数字は覚えるものではなく確かめるもの（付録 B.39.11）。README の Limits の行が名乗る数字
（逐次書き・逐次読み xlsx / ods / numbers・全載せ・8 シートを 1 枚ずつ／同時に読んだピーク MB）は JSON の "readme" に
名前つきで置き、--check が README の文章と突き合わせる。見た目は docs/format-support.html の <style> を借りる（隣の文書と勝手にずれないため）。
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
    "build": ("模型を組み立てる", "Workbook に 100 万マスを入れる（ファイルなし）"),
    "write": ("書き出し（xlsx）", "模型 → .xlsx"),
    "read": ("読み込み（xlsx）", ".xlsx → 模型、全マスの合計"),
    "streamRead": ("逐次読み（xlsx）", "StreamingReader で 1 行ずつ、全マスの合計"),
    "streamWrite": ("逐次書き（xlsx）", "StreamingWriter で 1 行ずつ"),
    "writeSheets": ("書き出し（xlsx・8 シート）", "同じ 100 万マスを 8 シートに分けた模型 → .xlsx"),
    "readSheetsSerial": ("読み込み（xlsx・8 シート・1 枚ずつ）", "ReadOptions(concurrency: 1)、全マスの合計"),
    "readSheets": ("読み込み（xlsx・8 シート・同時）", "既定（シートを同時に読む）、全マスの合計"),
    "edit": ("開いて 1 マス直して保存", ".xlsx → 模型 → .xlsx"),
    "detect": ("形式の判定", "SheetFormat.detect(contentsOf:)、1 回あたり"),
    "inspect": ("読む前の問い合わせ", "Workbook.inspect(contentsOf:)"),
    "writeODS": ("書き出し（ods）", "模型 → .ods"),
    "readODS": ("読み込み（ods）", ".ods → 模型"),
    "streamReadODS": ("逐次読み（ods）", "StreamingReader で 1 行ずつ、全マスの合計"),
    "writeCSV": ("書き出し（csv）", "模型 → .csv"),
    "readCSV": ("読み込み（csv）", ".csv → 模型（型の推定つき）"),
    "streamReadCSV": ("逐次読み（csv）", "CSVStreamingReader で 1 行ずつ"),
    "writeNumbers": ("書き出し（numbers）", "模型 → .numbers"),
    "readNumbers": ("読み込み（numbers）", ".numbers → 模型、全マスの合計"),
    "streamReadNumbers": ("逐次読み（numbers）", "StreamingReader で 1 行ずつ、全マスの合計"),
}


def e(s):
    return html.escape(str(s), quote=True)


def load_style():
    with open(STYLE_FROM, encoding="utf-8") as fh:
        m = re.search(r"<style>(.*?)</style>", fh.read(), re.S)
    if not m:
        sys.exit("❌ %s から <style> を取り出せません" % STYLE_FROM)
    return m.group(1)


def fmt_sec(sec):
    if sec >= 0.01:
        return "%.2f 秒" % sec
    if sec >= 0.0005:
        return "%.1f ミリ秒" % (sec * 1000)
    return "1 ミリ秒未満"


def render(doc):
    meta, results = doc["meta"], doc["results"]
    out = []
    w = out.append
    w("<!DOCTYPE html>\n<html lang=\"ja\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
    w("<title>速さの記録 — 100 万マスの読み書きにかかる時間とメモリ（SwiftSheets %s）</title>" % e(meta.get("library_version", "")))
    w("<style>%s</style>\n</head>\n<body>\n<main>" % load_style())
    w("<h1>速さの記録</h1>")
    w("<p class=\"lead\">%s 列 × %s 行 ＝ %s マスの合成データで、読み書きにかかる時間とピークメモリを測った値。"
      "この数字は覚えたものでなく <code>scripts/bench.sh</code> が測ったもので、README が名乗る数字はこのページの出所と機械で照合される。</p>"
      % (e(meta["columns"]), e("{:,}".format(meta["rows"])), e("{:,}".format(meta["cells"]))))
    w("<table><thead><tr><th>計測</th><th>時間</th><th>ピークメモリ</th><th>何をしたか</th></tr></thead><tbody>")
    for r in results:
        label, what = LABELS.get(r["op"], (r["op"], ""))
        note = r.get("note", "")
        extra = ""
        m = re.search(r"modelMB=([\d.]+)", note)
        if m:
            extra = "（うち模型 %s MB）" % m.group(1)
        w("<tr><td>%s</td><td>%s</td><td>%s MB%s</td><td>%s</td></tr>" % (e(label), e(fmt_sec(r["sec"])), e(r["peakMB"]), e(extra), e(what)))
    w("</tbody></table>")
    w("<h2>計測の条件</h2><ul>")
    w("<li>日付: %s、コミット: <code>%s</code></li>" % (e(meta["date"]), e(meta["commit"])))
    w("<li>機械: %s、メモリ %s GB、%s</li>" % (e(meta["machine"]), e(meta.get("memory_gb", "?")), e(meta["os"])))
    w("<li>ツールチェーン: %s、release ビルド</li>" % e(meta["swift"]))
    w("<li>素材: %s。<strong>合成データの数字は合成データの数字</strong>で、書式や図の多い実務のブックはこれより重い。</li>" % e(meta["material"]))
    w("<li>ピークメモリはプロセス生涯の最大値（<code>ru_maxrss</code>）。だから計測は 1 つずつ別のプロセスで走らせる。</li>")
    w("</ul>")
    w("<h2>自分の機械で測るには</h2>")
    w("<pre><code>scripts/bench.sh            # 100 万マス。Benchmarks/ を release で作り直して測り、docs/performance.json を書く\n"
      "scripts/bench.sh 10000      # 小さめに\n"
      "python3 scripts/build-performance-page.py --check   # このページと README の数字が出所と一致しているか</code></pre>")
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
            problems.append("README の Limits の行に **%d MB**（%s）が無い" % (value, key))
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
                    print("❌ 生成物が出所と一致しません: docs/performance.html（python3 scripts/build-performance-page.py を走らせてください）")
                    ok = False
        except FileNotFoundError:
            print("❌ docs/performance.html が無い")
            ok = False
        for p in readme_claims(doc):
            print("❌ " + p)
            ok = False
        if not ok:
            sys.exit(1)
        print("✅ 速さの記録のページも README の数字も、出所と一致しています")
        return
    with open(OUT_HTML, "w", encoding="utf-8") as fh:
        fh.write(page)
    print("✅ docs/performance.html（%d B）" % len(page.encode("utf-8")))
    for p in readme_claims(doc):
        print("⚠️ " + p)


if __name__ == "__main__":
    main()
