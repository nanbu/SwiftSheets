#!/bin/bash
# Builds the manual-verification samples (MAINTENANCE.md's release checklist):
#
#   openpyxl → seed .xlsx → LibreOffice → .ods (the source SwiftSheets reads) → SwiftSheets → .ods / .xlsx / .numbers
#
# Usage: scripts/make-verification-samples.sh [output directory]
# Requires: LibreOffice.app, Swift, and openpyxl — which it will fetch through uv if the Python on PATH lacks it,
# so nothing has to be installed first.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Desktop/SwiftSheets-verification-samples}"
SOFFICE="${SOFFICE:-/Applications/LibreOffice.app/Contents/MacOS/soffice}"
mkdir -p "$OUT"

# A Python that can import openpyxl. Whatever is on PATH if it already can; otherwise uv, which fetches openpyxl
# into a throwaway environment and installs nothing. This used to say "any Python with openpyxl" and point at
# another project's virtual environment, which is a thing this repository cannot promise anyone has.
PY=("${PYTHON:-python3}")
if ! "${PY[@]}" -c 'import openpyxl' >/dev/null 2>&1; then
  if command -v uv >/dev/null 2>&1; then
    PY=(uv run --quiet --with openpyxl python)
    echo "0. openpyxl via uv (nothing installed)"
  else
    echo "openpyxl is not importable from ${PY[*]}, and uv is not installed to fetch it." >&2
    echo "Install either one, or set PYTHON to an interpreter that has openpyxl." >&2
    exit 2
  fi
fi

echo "1. seed workbook (openpyxl)"
"${PY[@]}" Tests/FixtureGenerator/make_verification_samples.py "$OUT/00-seed-openpyxl.xlsx"

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
# SwiftSheets conversion samples

Written by `scripts/make-verification-samples.sh`. **SwiftSheets opened the ODF file LibreOffice produced and wrote
it out in three formats — ODS, Excel and Numbers.** These are for the checks a person still has to make in Excel
and in Numbers (the release checklist in MAINTENANCE.md).

| file | what it is |
|---|---|
| `00-seed-openpyxl.xlsx` | the raw material, made by openpyxl. SwiftSheets had no part in it |
| `01-source-libreoffice.ods` | **the input**: LibreOffice's ODF conversion of the above |
| `02-swiftsheets.ods` | the ODS SwiftSheets wrote from 01 |
| `03-swiftsheets.xlsx` | the Excel workbook SwiftSheets wrote from 01 |
| `04-swiftsheets.numbers` | the Numbers document SwiftSheets wrote from 01 |
| `conversion-report.md` | every warning the conversion gave (what was lost) |
| `pdf/` | each file rendered to PDF by LibreOffice, for comparing appearance |

Five sheets — Sales, Monthly, Staff, Formats and Extra (hidden). **The cell contents are deliberately Japanese**:
that is how the sample proves the library carries the text, the fonts and the surrogate pairs unharmed.

## Open `03-swiftsheets.xlsx` in Excel

First: **no "we found a problem with some content" dialog**. If one appears, the sample has failed — please say so.

- [ ] five sheets (`Extra` is hidden; right-click ▸ Unhide to see it)
- [ ] Sales: A1:I1 merged, dark blue behind white bold text, and **filter buttons** on the headings in row 3
- [ ] the headings stay put when you scroll past row 4 (**frozen at A4**)
- [ ] unit price and amount read `¥1,234,567`, margin `28.4%`, dates `2026/4/3`, and B2 a long-form Japanese date
- [ ] alternating pale shading, **borders** over the whole table, a double rule above the total row
- [ ] margins under 22% in red on pink, over 34% in green on pale green
- [ ] column H and the total row are **formulas** (`=F4*G4` / `=SUM(H4:H21)` in the formula bar); Monthly
      recalculates through `SUMPRODUCT` and `IF`
- [ ] Staff: the id `0012` is still text (the leading zero survives), the mail column is a link, remarks wrap
- [ ] Formats: number formats, seven border kinds, six fills, alignment, fonts (Yu Gothic / Menlo), a surrogate
      pair, emoji and half-width kana
- [ ] the defined name `SalesRange` is there (Formulas ▸ Name Manager)
- [ ] the **note** on Sales!B4 is still there with its red triangle (hover to read it)

## Open `04-swiftsheets.numbers` in Numbers

First: **it opens without offering to repair the document**, and **you can edit it and save**.

- [ ] five sheets, one table each (the input is ODS, so the tables carry Numbers' default name `Table 1`)
- [ ] the Japanese text is undamaged — kanji, kana, half-width kana, the surrogate pair, emoji
- [ ] numbers, dates, booleans and durations are values, not text
- [ ] the merges (A1:I1 and the rest), the column widths and the row heights are as in Excel
- [ ] rows 1–3 of Sales and Monthly are frozen as header rows
- [ ] **cell formatting** — bold and coloured headings, fills, the fonts asked for, currency / percentage / date
      formats rather than bare numbers
- [ ] **the formulas are formulas** (click a cell in column H and look at the formula bar), and Numbers computes
      the same answers
- [ ] the **notes** are there, and the **links** in the Staff mail column work

**Known differences, by design** (spec Appendix B.18): Numbers has no hidden sheets, so `Extra` is visible. It has
no data validation, pivot tables, named tables, auto-filters, sheet protection, scenarios, print setup, defined
names, tab colours or outline grouping; each of those is listed in `conversion-report.md` rather than dropped in
silence. Of Excel's conditional-format kinds Numbers keeps fourteen and has no word for the other eleven (colour
scales, data bars, icon sets among them) — the same ones it drops when it imports an Excel file itself.

## Known LibreOffice problems (not SwiftSheets bugs)

- **A Numbers file opened in LibreOffice shows damaged sheet names** (`Monthly` is fine, but a Japanese name of
  five characters or more is cut short). LibreOffice's Numbers importer (libetonyek) does it to genuine Numbers
  documents too. The bytes in the file are correct UTF-8, and Numbers and numbers-parser read them correctly.
- **LibreOffice's xlsx→ods conversion does not write frozen panes.** The input `01` therefore has none, and the
  script sets them again for the sample (noted in `conversion-report.md`).

## Open `02-swiftsheets.ods` in LibreOffice

Already checked automatically (the ODS suite of `swift test`), but worth a look. Put
`pdf/01-source-libreoffice.pdf` beside `pdf/02-swiftsheets.pdf` to see any difference.

## If you find a problem

Send `conversion-report.md` and say which file, sheet and cell. The input to reproduce it with is
`01-source-libreoffice.ods`.
MDEOF
echo "wrote $OUT/READ-ME-FIRST.md"
