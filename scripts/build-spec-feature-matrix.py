#!/usr/bin/env python3
"""形式ごとの機能対応表を作る — 出所は 1 つ、生成物は 2 つ。

    python3 scripts/build-spec-feature-matrix.py            # docs/ の HTML と YAML を作り直す
    python3 scripts/build-spec-feature-matrix.py --check    # 生成物が出所と一致するか（CI 向け・差分なら exit 1）

出所は scripts/spec-feature-matrix.json だけ。docs/spec-feature-matrix.html と
docs/spec-feature-matrix.yaml は生成物なので手で編集しない（2 か所を手で直すと必ずずれる）。
見た目は docs/format-support.html の <style> をそのまま借りる — 隣り合う文書の見た目が
勝手にずれないようにするため、ここへ複製はしない。

標準ライブラリだけで動く（外部の YAML ライブラリは使わない）。
"""
import json
import os
import re
import sys
import html
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "scripts", "spec-feature-matrix.json")
STYLE_FROM = os.path.join(ROOT, "docs", "format-support.html")
OUT_HTML = os.path.join(ROOT, "docs", "spec-feature-matrix.html")
OUT_YAML = os.path.join(ROOT, "docs", "spec-feature-matrix.yaml")

ORDER = ["full", "partial", "preserved", "none", "na", "unverified"]
CELL_CLASS = {"full": "y", "partial": "h", "preserved": "", "none": "n", "na": "", "unverified": "h"}
EVIDENCE_JA = {"measured": "実測", "code": "コード確認", "readme": "文書", "judge": "実機の審判"}


def e(s):
    return html.escape(str(s), quote=True)


def code(s):
    return "<code>%s</code>" % e(s)


def counts(fmt, side):
    return Counter(r[side] for a in fmt["areas"] for r in a["features"])


def rows_of(fmt):
    return sum(len(a["features"]) for a in fmt["areas"])


# ------------------------------------------------------------------ YAML
def q(s):
    """YAML の二重引用符つき文字列。JSON の文字列表記がそのまま使える。"""
    return json.dumps(s, ensure_ascii=False)


# UTF-8 の印（BOM）を YAML の先頭に置く。理由は表示側にある: HTML なら <meta charset> で名乗れるが、
# HTML でないテキストには名乗る場所が無く、ブラウザはサーバーの Content-Type を見る。GitHub Pages は
# .yaml を「text/yaml」（文字コードの指定なし）で返すので、ブラウザは Latin-1 と推測し、日本語が化ける。
# 先頭の BOM があればブラウザは UTF-8 と判定する。YAML 1.2 は先頭の BOM を明示的に許しており
# （§5.2 Character Encodings）、libyaml 系の実装は読み飛ばす（Ruby/Psych で確認済み）。
# **消さないこと** — 消すと公開ページから開いた読み手には文字化けして見える。
BOM = "\ufeff"


def emit_yaml(d):
    meta, out = d["meta"], []
    w = out.append
    w("# " + meta["title"])
    w("# 生成物。scripts/spec-feature-matrix.json を直して")
    w("# scripts/build-spec-feature-matrix.py を走らせること（手で編集しない）。")
    w("meta:")
    for k in ("title", "library_version", "as_of", "commit", "axis", "granularity", "caveat"):
        w("  %s: %s" % (k, q(meta[k])))
    w("  environments:")
    for x in meta["environments"]:
        w("    - %s" % q(x))
    w("  status_vocabulary:")
    for key, v in meta["status_vocabulary"].items():
        w("    %s:" % key)
        w("      symbol: %s" % q(v["symbol"]))
        w("      meaning: %s" % q(v["meaning"]))
    w("  evidence_types:")
    for key, v in meta["evidence_types"].items():
        w("    %s: %s" % (key, q(v)))
    w("  common_api:")
    for key, v in meta["common_api"].items():
        w("    %s: %s" % (key, q(v)))
    w("")
    w("formats:")
    for f in d["formats"]:
        w("  - id: %s" % q(f["id"]))
        w("    name: %s" % q(f["name"]))
        w("    spec:")
        w("      name: %s" % q(f["spec"]["name"]))
        w("      public: %s" % ("true" if f["spec"]["public"] else "false"))
        w("      note: %s" % q(f["spec"]["note"]))
        w("    totals:")
        for side in ("read", "write"):
            c = counts(f, side)
            w("      %s: {%s}" % (side, ", ".join("%s: %d" % (k, c[k]) for k in ORDER)))
        w("      rows: %d" % rows_of(f))
        w("    areas:")
        for a in f["areas"]:
            w("      - id: %s" % q(a["id"]))
            w("        name: %s" % q(a["name"]))
            w("        features:")
            for r in a["features"]:
                w("          - id: %s" % q(r["id"]))
                w("            name: %s" % q(r["name"]))
                w("            spec_anchor: %s" % q(r["spec_anchor"]))
                w("            read: %s" % q(r["read"]))
                w("            write: %s" % q(r["write"]))
                if r["api"]:
                    w("            api:")
                    for x in r["api"]:
                        w("              - %s" % q(x))
                else:
                    w("            api: []")
                w("            warning: %s" % (q(r["warning"]) if r["warning"] else "null"))
                w("            evidence: %s" % q(r["evidence"]))
                w("            note: %s" % (q(r["note"]) if r["note"] else "null"))
    return BOM + "\n".join(out) + "\n"


# ------------------------------------------------------------------ HTML
FIGURE = """<figure>
<svg viewBox="0 0 900 300" role="img" aria-label="1 つの機能が迎える 4 つの結末を並べた図">
  <rect x="0" y="10" width="210" height="132" rx="14" class="sv-card"/>
  <text x="20" y="42" class="sv-good" font-size="24">○</text>
  <text x="52" y="42" class="sv-tb">そのまま往復</text>
  <text x="20" y="70" class="sv-t2">モデルの言葉で読めて、</text>
  <text x="20" y="90" class="sv-t2">同じものが書き出される。</text>
  <text x="20" y="110" class="sv-t2">API がその機能を持つ。</text>
  <text x="20" y="130" class="sv-t3">例: セルの結合</text>

  <rect x="230" y="10" width="210" height="132" rx="14" class="sv-card"/>
  <text x="250" y="42" class="sv-warn" font-size="24">△</text>
  <text x="282" y="42" class="sv-tb">形を変えて通る</text>
  <text x="250" y="70" class="sv-t2">相手の形式が同じことを</text>
  <text x="250" y="90" class="sv-t2">言えないので、近いものに</text>
  <text x="250" y="110" class="sv-t2">置き換えて、必ず言う。</text>
  <text x="250" y="130" class="sv-t3">例: 表示形式の複数セクション</text>

  <rect x="460" y="10" width="210" height="132" rx="14" class="sv-card"/>
  <text x="480" y="42" class="sv-t" font-size="24">▣</text>
  <text x="512" y="42" class="sv-tb">触らずに残す</text>
  <text x="480" y="70" class="sv-t2">読み取って模型にはしないが、</text>
  <text x="480" y="90" class="sv-t2">同じ形式で保存すれば元の</text>
  <text x="480" y="110" class="sv-t2">バイトのまま残る（F3）。</text>
  <text x="480" y="130" class="sv-t3">例: グラフ・VBA・スパークライン</text>

  <rect x="690" y="10" width="210" height="132" rx="14" class="sv-card"/>
  <text x="710" y="42" class="sv-bad" font-size="24">×</text>
  <text x="742" y="42" class="sv-tb">落として、言う</text>
  <text x="710" y="70" class="sv-t2">通らない。ただし黙って</text>
  <text x="710" y="90" class="sv-t2">消えることはなく、必ず</text>
  <text x="710" y="110" class="sv-t2">警告として返ってくる。</text>
  <text x="710" y="130" class="sv-t3">例: Numbers の印刷設定</text>

  <rect x="0" y="170" width="900" height="106" rx="14" class="sv-soft"/>
  <text x="24" y="200" class="sv-tb">▣ が ○ と違うところ</text>
  <text x="24" y="226" class="sv-t2">同じ形式へ保存し直すかぎり完全に残りますが、モデルには言葉が無いので、API から触ることも、他の形式へ持っていくこともできません。</text>
  <text x="24" y="248" class="sv-t2">他の形式へ変換した瞬間に × と同じ扱いになり、そのとき初めて警告が出ます。だから「対応・未対応」の 2 択では言えず、</text>
  <text x="24" y="268" class="sv-t2">この表は 6 つの記号を使っています。</text>
</svg>
<figcaption>この表の記号。× と ▣ を分けたことが、この表の中心にあります。</figcaption>
</figure>"""


def status_cell(meta, value):
    sym = meta["status_vocabulary"][value]["symbol"]
    cls = CELL_CLASS[value]
    return '<td class="m%s">%s</td>' % ((" " + cls) if cls else "", e(sym))


def format_table(meta, f):
    out = ['<div class="tablewrap"><table>']
    out.append("<thead><tr><th>機能</th><th class=\"m\">読み</th><th class=\"m\">書き</th>"
               "<th>仕様の手がかり</th><th>対応する API</th><th>注（落ちるときに何を言うか・根拠）</th></tr></thead><tbody>")
    for a in f["areas"]:
        out.append('<tr class="group"><td colspan="6">%s</td></tr>' % e(a["name"]))
        for r in a["features"]:
            note = []
            if r["warning"]:
                note.append("<strong>言うこと</strong>: " + e(r["warning"]))
            if r["note"]:
                note.append(e(r["note"]))
            note.append('<span class="chip">%s</span>' % e(EVIDENCE_JA[r["evidence"]]))
            anchor = code(r["spec_anchor"]) if r["spec_anchor"] not in ("—", "") else "—"
            api = " ".join(code(x) for x in r["api"]) if r["api"] else "—"
            out.append("<tr><td>%s</td>%s%s<td>%s</td><td>%s</td><td>%s</td></tr>"
                       % (e(r["name"]), status_cell(meta, r["read"]), status_cell(meta, r["write"]),
                          anchor, api, " ".join(note)))
    out.append("</tbody></table></div>")
    return "\n".join(out)


def counts_table(d):
    out = ['<div class="tablewrap"><table>',
           "<thead><tr><th>形式</th><th>向き</th>"
           + "".join('<th class="m">%s</th>' % e(d["meta"]["status_vocabulary"][k]["symbol"]) for k in ORDER)
           + '<th class="m">行数</th></tr></thead><tbody>']
    for f in d["formats"]:
        total = rows_of(f)
        for side, label in (("read", "読み"), ("write", "書き")):
            c = counts(f, side)
            out.append("<tr><td>%s</td><td>%s</td>%s<td class=\"m\">%d</td></tr>"
                       % (e(f["name"]), label,
                          "".join('<td class="m">%d</td>' % c[k] for k in ORDER), total))
    out.append("</tbody></table></div>")
    return "\n".join(out)


def load_style():
    with open(STYLE_FROM, encoding="utf-8") as fh:
        m = re.search(r"<style>(.*?)</style>", fh.read(), re.S)
    if not m:
        sys.exit("❌ %s から <style> を取り出せません" % STYLE_FROM)
    return m.group(1)


def emit_html(d):
    meta = d["meta"]
    total = sum(rows_of(f) for f in d["formats"])
    unverified = [(f["name"], r["name"]) for f in d["formats"] for a in f["areas"]
                  for r in a["features"] if "unverified" in (r["read"], r["write"])]
    o = []
    w = o.append
    w('<!DOCTYPE html>\n<html lang="ja">\n<head>\n<meta charset="utf-8">')
    w('<meta name="viewport" content="width=device-width, initial-scale=1">')
    w("<title>形式ごとの機能対応表 — 仕様にある機能を、SwiftSheets はどこまで扱えるか"
      "（SwiftSheets %s）</title>" % e(meta["library_version"]))
    w("<style>%s</style>\n</head>\n<body>\n<main>" % load_style())
    w("<h1>形式ごとの機能対応表</h1>")
    w('<p class="lede">Excel・OpenDocument・Numbers それぞれの<strong>公開仕様が持っている機能</strong>を並べ、'
      "SwiftSheets が読めるか・書けるか・どの API で触るのかを %d 行にしたものです。"
      "隣の<a href=\"format-support.html\">形式ごとの対応表</a>が「モデルの 48 項目 → 3 形式」を測るのに対し、"
      "この表は<strong>逆向き</strong>に「形式の仕様 → SwiftSheets」を見ます。</p>" % total)
    w('<p class="meta">%s 時点 / SwiftSheets %s / 検証環境: %s</p>'
      % (e(meta["as_of"]), e(meta["library_version"]), e("・".join(meta["environments"]))))
    w('<hr class="rule">')

    w("<section>\n<h2>この表の向き</h2>")
    w("<p>%s</p>" % e(meta["axis"].replace("docs/format-support.html", "形式ごとの対応表")))
    w("<p>%s</p>" % e(meta["granularity"]))
    w('<div class="grid">')
    for f in d["formats"]:
        cr, cw = counts(f, "read"), counts(f, "write")
        w('<div class="card score"><div class="num">%d<small> 項目</small></div>'
          '<div class="lab">%s</div><div class="sub">読み ○%d △%d ▣%d ×%d ／ 書き ○%d △%d ▣%d ×%d<br>%s</div></div>'
          % (rows_of(f), e(f["name"]),
             cr["full"], cr["partial"], cr["preserved"], cr["none"],
             cw["full"], cw["partial"], cw["preserved"], cw["none"],
             "公開仕様あり" if f["spec"]["public"] else "<strong>公開仕様なし</strong> — ヘルプと観測で作りました"))
    w("</div>\n</section>")

    w("<section>\n<h2>記号は 6 つ — 「対応・未対応」の 2 択にしなかった理由</h2>")
    w("<p>同じ「未対応」でも、①モデルが言葉を持たないだけで保存すれば残るもの（▣）と、"
      "②本当に消えるもの（×）では、使う側にとっての意味がまるで違います。"
      "読みと書きも分けました — Numbers の配列数式は読めても書けず、フィルタは隠し行だけが読める、"
      "といった行が実際にあるからです。</p>")
    w(FIGURE)
    w('<div class="tablewrap"><table><thead><tr><th class="m">記号</th><th>意味</th></tr></thead><tbody>')
    for key, v in meta["status_vocabulary"].items():
        cls = CELL_CLASS[key]
        w('<tr><td class="m%s">%s</td><td>%s</td></tr>'
          % ((" " + cls) if cls else "", e(v["symbol"]), e(v["meaning"])))
    w("</tbody></table></div>")
    w("<p>%s</p>" % e(meta["caveat"]))
    w("</section>")

    w("<section>\n<h2>各行の根拠</h2>")
    w("<p>「対応しています」と書いた表はすぐ嘘になります。そこで各行の末尾に、"
      "その判定が<strong>どこから来たのか</strong>を付けました。</p>")
    w('<div class="tablewrap"><table><thead><tr><th>しるし</th><th>意味</th></tr></thead><tbody>')
    for key, v in meta["evidence_types"].items():
        w("<tr><td>%s</td><td>%s</td></tr>" % (e(EVIDENCE_JA[key]), e(v)))
    w("</tbody></table></div>")
    if unverified:
        w("<p><strong>正直な残り物</strong>: 実測していない行が %d 件あります"
          "（%s）。検体が手元に無いため、推測で ○ × を書かず <code>?</code> のままにしてあります。</p>"
          % (len(unverified), e("、".join("%s の%s" % (n.split("（")[0], r) for n, r in unverified))))
    w("</section>")

    w("<section>\n<h2>どの行にも共通する入口</h2>")
    w('<pre><code>%s</code></pre>'
      % e("読む:   " + meta["common_api"]["read"] + "\n"
          + "書く:   " + meta["common_api"]["write"] + "\n"
          + "見分ける: " + meta["common_api"]["detect"] + "\n"
          + "落としたものの受け取り方: " + meta["common_api"]["warnings"]))
    w("</section>")

    w("<section>\n<h2>件数</h2>")
    w(counts_table(d))
    w('<p class="meta">「—」はその形式に概念が無い行です。Numbers に「—」が多いのは能力差ではなく、'
      "Excel・OpenDocument 側の機能を並べた行に Numbers 側の対応物が無い、という意味です。</p>")
    w("</section>")

    for f in d["formats"]:
        w("<section>\n<h2>%s</h2>" % e(f["name"]))
        w("<p><strong>仕様</strong>: %s</p>" % e(f["spec"]["name"]))
        w("<p>%s</p>" % e(f["spec"]["note"]))
        w(format_table(meta, f))
        w("</section>")

    w("<section>\n<h2>この表を自分で確かめる</h2>")
    w("<p>〔実測〕の行は、リポジトリのテストがそのまま裏づけです。</p>")
    w("<pre><code>swift test --filter FormatSupport   # 48 項目を全形式へ書いて読み戻し、生存と警告の数を固定している\n"
      "swift test --filter CrossFormat     # 方向ごと（A → B）の点検\n"
      "swift test                          # 全部\n\n"
      "python3 scripts/build-spec-feature-matrix.py --check   # この表が出所と一致しているか</code></pre>")
    w("<p>表を直すときは <code>scripts/spec-feature-matrix.json</code> を直し、"
      "<code>python3 scripts/build-spec-feature-matrix.py</code> を走らせてください。"
      "この HTML と <a href=\"spec-feature-matrix.yaml\">同じ内容の YAML</a> は生成物です。</p>")
    w("<p class=\"meta\">YAML の先頭には UTF-8 の印（BOM）が入っています。HTML と違って文字コードを"
      "名乗る場所が無く、GitHub Pages は <code>text/yaml</code> を文字コードなしで返すため、"
      "印が無いとブラウザが日本語を化けさせるからです。YAML 1.2 が先頭の印を認めているので、"
      "読み込む側は今までどおりで構いません。</p>")
    w("</section>")

    w("<footer>")
    w("SwiftSheets — 形式ごとの機能対応表。SwiftSheets %s（commit %s）時点の実測とコード確認。<br>"
      % (e(meta["library_version"]), e(meta["commit"])))
    w("モデルの側から測った表は <a href=\"format-support.html\">形式ごとの対応表</a>、"
      "方向ごと（A → B）の挙動は <a href=\"interoperability.html\">相互運用ガイド</a> に。<br>")
    w("実装の判断とその理由は <code>docs/implementation-spec.html</code> の付録 B に。")
    w("</footer>")
    w("</main>\n</body>\n</html>")
    return "\n".join(o) + "\n"


# README.md と docs/index.html はこの表の行数を文章の中で名乗る。数は覚えるものではなく
# 確かめるものなので、--check がそこも見る（README の数字だけが古くなる事故を防ぐ）。
CLAIMS = [("README.md", r"\((\d+) rows;"), ("docs/index.html", r"(\d+) rows\.")]


def check_claims(total):
    stale = []
    for name, pattern in CLAIMS:
        path = os.path.join(ROOT, name)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
        except FileNotFoundError:
            stale.append("%s が見つかりません" % name)
            continue
        found = re.search(pattern, text)
        if not found:
            stale.append("%s が行数を名乗っていません（%s に一致する箇所がない）" % (name, pattern))
        elif int(found.group(1)) != total:
            stale.append("%s は %s 行と書いていますが、いまは %d 行です" % (name, found.group(1), total))
    return stale


def main():
    check = "--check" in sys.argv[1:]
    with open(SOURCE, encoding="utf-8") as fh:
        d = json.load(fh)
    products = [(OUT_YAML, emit_yaml(d)), (OUT_HTML, emit_html(d))]
    if check:
        stale = []
        for path, text in products:
            try:
                with open(path, encoding="utf-8") as fh:
                    current = fh.read()
            except FileNotFoundError:
                current = None
            if current != text:
                stale.append(os.path.relpath(path, ROOT))
        if stale:
            print("❌ 生成物が出所と一致しません: %s\n   python3 scripts/build-spec-feature-matrix.py "
                  "を走らせてください。" % ", ".join(stale), file=sys.stderr)
            return 1
        total = sum(rows_of(f) for f in d["formats"])
        wrong = check_claims(total)
        if wrong:
            print("❌ 行数を名乗っている文章が古いです:\n   - %s" % "\n   - ".join(wrong), file=sys.stderr)
            return 1
        print("✅ 生成物も、行数を名乗る文章も、出所と一致しています（%d 行）" % total)
        return 0
    for path, text in products:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("✅ %s（%d B）" % (os.path.relpath(path, ROOT), len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
