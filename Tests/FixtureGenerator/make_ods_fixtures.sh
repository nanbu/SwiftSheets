#!/bin/sh
# Regenerates the LibreOffice-generated ODS corpus (spec §12.1) from the XLSX fixtures:
#   Tests/SwiftSheetsTests/Fixtures/ods/styled.ods              ← Fixtures/styled.xlsx
#   Tests/SwiftSheetsTests/Fixtures/ods/charts-and-friends.ods  ← Fixtures/preservation/charts-and-friends.xlsx
# Requires LibreOffice at /Applications/LibreOffice.app. Run from the package root.
set -e
SOFFICE=/Applications/LibreOffice.app/Contents/MacOS/soffice
FIX=Tests/SwiftSheetsTests/Fixtures
OUT=$FIX/ods
PROFILE=$(mktemp -d)/profile
mkdir -p "$OUT"
"$SOFFICE" -env:UserInstallation=file://"$PROFILE" --headless --convert-to ods --outdir "$OUT" \
    "$FIX/styled.xlsx" "$FIX/preservation/charts-and-friends.xlsx"
ls -l "$OUT"
