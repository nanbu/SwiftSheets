#!/bin/bash
# Builds the manual-verification samples (MAINTENANCE.md's release checklist):
#
#   openpyxl → seed .xlsx → LibreOffice → .ods (the source SwiftSheets reads) → SwiftSheets → .ods / .xlsx / .numbers
#
# Usage: scripts/make-verification-samples.sh [output directory]
# Requires: a Python with openpyxl, LibreOffice.app, Swift.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Desktop/SwiftSheets-verification-samples}"
PYTHON="${PYTHON:-python3}"
SOFFICE="${SOFFICE:-/Applications/LibreOffice.app/Contents/MacOS/soffice}"
mkdir -p "$OUT"

echo "1. seed workbook (openpyxl)"
"$PYTHON" Tests/FixtureGenerator/make_verification_samples.py "$OUT/00-seed-openpyxl.xlsx"

echo "2. LibreOffice → ODF"
[[ -x "$SOFFICE" ]] || { echo "LibreOffice not found at $SOFFICE"; exit 2; }
"$SOFFICE" -env:UserInstallation=file:///tmp/swiftsheets-lo-profile --headless --convert-to ods --outdir "$OUT" "$OUT/00-seed-openpyxl.xlsx" >/dev/null
mv "$OUT/00-seed-openpyxl.ods" "$OUT/01-source-libreoffice.ods"

echo "3. SwiftSheets → .ods / .xlsx / .numbers"
SWIFTSHEETS_SAMPLES_DIR="$OUT" swift test --filter VerificationSamplesTests 2>&1 | tail -3

echo "4. rendering PDFs for a quick visual check"
for f in "$OUT"/0[1234]-*; do
  "$SOFFICE" -env:UserInstallation=file:///tmp/swiftsheets-lo-profile --headless --convert-to pdf --outdir "$OUT/pdf" "$f" >/dev/null 2>&1 || echo "   (LibreOffice could not render $(basename "$f"))"
done

echo
echo "done: $OUT"
ls -la "$OUT"

cat > "$OUT/READ-ME-FIRST.md" <<'MDEOF'
# SwiftSheets 形式変換 検証サンプル

`scripts/make-verification-samples.sh` が生成。**LibreOffice が書いた ODF ファイルを SwiftSheets で開き、ODS / Excel /
Numbers の 3 形式へ書き出したもの**です。Excel と Numbers の実機確認（MAINTENANCE.md のリリース前チェックリスト）に使います。

| ファイル | 中身 |
|---|---|
| `00-seed-openpyxl.xlsx` | 素材（openpyxl が生成）。SwiftSheets は関与しない |
| `01-source-libreoffice.ods` | **入力**。LibreOffice が上を ODF へ変換したもの |
| `02-swiftsheets.ods` | SwiftSheets が 01 を読んで書いた ODS |
| `03-swiftsheets.xlsx` | SwiftSheets が 01 を読んで書いた Excel ブック |
| `04-swiftsheets.numbers` | SwiftSheets が 01 を読んで書いた Numbers 書類 |
| `conversion-report.md` | 変換時の警告一覧（何が落ちたか） |
| `pdf/` | 各ファイルを LibreOffice で PDF 化したもの（見た目の突き合わせ用） |

データは 5 シート構成の日本語の業務データです（売上明細・月次サマリ・社員名簿・書式見本・補足データ〈非表示〉）。

## Excel で `03-swiftsheets.xlsx` を開く

まず **「修復が必要です」ダイアログが出ないこと**。出たら不合格なので、その旨をお知らせください。

- [ ] シートが 5 枚（`補足データ` は非表示。右クリック →「再表示」で出る）
- [ ] 売上明細: A1:I1 が結合され濃紺の背景に白の太字、行 3 の見出しに**フィルターボタン**が出る
- [ ] 4 行目以降がスクロールしても見出しが残る（**A4 で枠固定**）
- [ ] 単価・金額が `¥1,234,567`、粗利率が `28.4%`、日付が `2026/4/3`、B2 が `2026年10月1日`
- [ ] 一行おきの薄い網掛け、表全体の**罫線**、合計行の上が二重線
- [ ] 粗利率 22% 未満が赤字＋ピンク、34% 超が緑字＋薄緑
- [ ] H 列と合計行が**数式**（数式バーに `=F4*G4` / `=SUM(H4:H21)`）。月次サマリは `SUMPRODUCT` と `IF` で再計算される
- [ ] 社員名簿: 社員番号 `0012` が文字列のまま（先頭の 0 が消えない）、メール列がリンク、備考が折り返し表示
- [ ] 書式見本: 表示形式・罫線 7 種・塗り 6 色・配置・フォント（游ゴシック / Menlo）・`𠮷野家`・絵文字・半角カナ
- [ ] 名前の定義に `売上範囲` がある（数式 → 名前の管理）

- [ ] 売上明細 B4 の**セルのメモ**が赤い三角つきで残っている（ポイントすると本文が出る）

## Numbers で `04-swiftsheets.numbers` を開く

まず **「書類を修復」と言われずに開くこと**、そして**開いたあと編集して保存できること**。

- [ ] シートが 5 枚、各シートに表が 1 つ（入力が ODS なので表名は Numbers 既定の `Table 1`）
- [ ] 日本語（漢字・かな・カナ・半角カナ・`𠮷`・絵文字）が化けていない
- [ ] 数値・日付・真偽値・経過時間が値として入っている（合計 22,532,800 など計算済みの値）
- [ ] A1:I1 などの**結合**、列幅・行高が反映されている
- [ ] 売上明細と月次サマリの 1〜3 行目がヘッダ行として固定されている

**既知の差（仕様どおり・付録 B.8）**: Numbers 書き出しは**書式（色・罫線・表示形式・フォント）を書きません**。
**数式は計算結果の値**として入ります（Numbers の数式アーカイブは生成しない）。**非表示シートは表示されます**。
つまり「データは合っているが見た目は素のまま」が期待値です。

## 既知の LibreOffice 側の問題（SwiftSheets の不具合ではありません）

- **Numbers ファイルをLibreOffice で開くとシート名が化ける**（`月次サマリ` → `月次サマ□`）。LibreOffice の Numbers
  インポータ（libetonyek）が 5 文字以上の日本語名を途中で切るためで、numbers-parser が書いた正規の Numbers 文書でも
  同じ化け方をします。ファイル内のバイト列は正しい UTF-8 です（Numbers と numbers-parser では正しく読めます）。
- **LibreOffice の xlsx→ods 変換は枠固定（ウィンドウ枠）を書き出しません**。そのため入力 `01` には枠固定が入って
  おらず、サンプルではスクリプトが再設定しています（`conversion-report.md` に記載）。

## LibreOffice で `02-swiftsheets.ods` を開く

自動検証済み（`swift test` の ODS スイート）ですが、目視でも確認できます。`pdf/01-source-libreoffice.pdf` と
`pdf/02-swiftsheets.pdf` を並べると差分が分かります。

## 不具合を見つけたら

`conversion-report.md` と、どのファイルのどのセル／シートかを添えてください。再現用の入力は
`01-source-libreoffice.ods` です。
MDEOF
echo "wrote $OUT/はじめにお読みください.md"
