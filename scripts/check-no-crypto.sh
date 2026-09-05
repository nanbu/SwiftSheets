#!/bin/sh
# Proves what the README promises about encryption code (spec Appendix B.39.9, Rev 4.29):
#
#   1. An executable linking only the plain products (SwiftSheets and what it re-exports) carries no symbol of
#      SheetDecrypt or SheetEncrypt, and none named AES / OOXMLEncryption / ODSEncryption / CompoundFile.
#   2. An executable linking SheetDecrypt as well carries nothing that encrypts: no SheetEncrypt symbol, no
#      encryptBlock / encryptCBC / encryptECB, no OOXMLEncryption.encrypt / ODSEncryption.encrypt / CompoundFile.write.
#   3. The same at the object level, where an executable's symbol table cannot mislead: an executable only links
#      the objects it references, so a module that held a cipher nobody called would still pass check 1. The six
#      plain modules' objects neither define nor reference any of those names; SheetDecrypt's define nothing that
#      encrypts.
#
# Before any of that, the executable that links everything is checked to CONTAIN the encrypting symbols — the
# positive control. If a rename or a change of mangling made the patterns match nothing, that is where this
# script fails, rather than passing three empty greps.
#
# Builds scripts/no-crypto (three executables against this checkout) into .build/no-crypto. Needs nm (binutils on
# Linux) and swift demangle; either missing is a failure, not a pass. Run from anywhere; exit 0 only when every
# check holds.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH="$ROOT/.build/no-crypto"
BIN="$SCRATCH/debug"
FIXTURE="$ROOT/Tests/SwiftSheetsTests/Fixtures/encrypted/agile.xlsx"

if command -v nm >/dev/null 2>&1; then NM=nm
elif command -v llvm-nm >/dev/null 2>&1; then NM=llvm-nm
else echo "check-no-crypto: neither nm nor llvm-nm is available — cannot judge, so failing" >&2; exit 2; fi
swift demangle --help >/dev/null 2>&1 || { echo "check-no-crypto: swift demangle is not available — cannot judge, so failing" >&2; exit 2; }

echo "building scripts/no-crypto (three executables) into .build/no-crypto"
swift build --package-path "$ROOT/scripts/no-crypto" --scratch-path "$SCRATCH" 2>&1 | tail -1

# The refusal message names SheetDecrypt, and on macOS clang labels a string literal with its own text
# (`l_.str.189.the ODF package is encrypted … SheetDecrypt …`). A literal is not code; those labels are dropped.
literals() { grep -vE '(^| )[lL]_\.str|(^| )\.L\.str|(^| )l___unnamed'; }
symbols() { "$NM" "$1" 2>/dev/null | literals | swift demangle; }
objects() {
    # every object of a module, defined and undefined symbols alike
    find "$BIN/$1.build" -name '*.o' -exec "$NM" {} \; 2>/dev/null | literals | swift demangle
}
# a name is a whole word: `legacyCompoundFile` (a case in SheetCore) is not `CompoundFile`, `AESTests` is not `AES`
CRYPTO_TYPES='\b(AES|OOXMLEncryption|ODSEncryption|CompoundFile)\b'
CRYPTO_MODULES='\b(SheetDecrypt|SheetEncrypt)\b'
ENCRYPTING='\bSheetEncrypt\b|\bencryptBlock\b|\bencryptCBC\b|\bencryptECB\b|OOXMLEncryption\.encrypt\(|ODSEncryption\.encrypt\(|CompoundFile\.write\('

failed=0
fail() { echo "  ✗ $1"; failed=1; }
pass() { echo "  ✓ $1"; }

echo "positive control: the executable that links everything"
FULL=$(symbols "$BIN/full")
for needle in 'OOXMLEncryption.encrypt(' 'ODSEncryption.encrypt(' 'CompoundFile.write(' 'AES.encryptBlock(' 'AES.decryptBlock(' 'OOXMLEncryption.decrypt(' 'ODSEncryption.decrypt('; do
    if printf '%s\n' "$FULL" | grep -qF "$needle"; then pass "full carries $needle"; else fail "full lacks $needle — the patterns cannot be trusted"; fi
done

echo "1. the plain products carry no cipher"
PLAIN=$(symbols "$BIN/plain")
hits=$(printf '%s\n' "$PLAIN" | grep -cE "$CRYPTO_MODULES|$CRYPTO_TYPES" || true)
if [ "$hits" -eq 0 ]; then pass "plain: no symbol of SheetDecrypt / SheetEncrypt / AES / OOXMLEncryption / ODSEncryption / CompoundFile"
else fail "plain: $hits crypto symbol(s):"; printf '%s\n' "$PLAIN" | grep -E "$CRYPTO_MODULES|$CRYPTO_TYPES" | head -5; fi

echo "2. SheetDecrypt carries nothing that encrypts"
DEC=$(symbols "$BIN/decrypt-only")
if printf '%s\n' "$DEC" | grep -qF 'OOXMLEncryption.decrypt('; then pass "decrypt-only: carries the decrypting side"; else fail "decrypt-only: lacks OOXMLEncryption.decrypt( — nothing was linked"; fi
hits=$(printf '%s\n' "$DEC" | grep -cE "$ENCRYPTING" || true)
if [ "$hits" -eq 0 ]; then pass "decrypt-only: no SheetEncrypt symbol, no encryptBlock / encryptCBC / encryptECB, no OOXMLEncryption.encrypt / ODSEncryption.encrypt / CompoundFile.write"
else fail "decrypt-only: $hits encrypting symbol(s):"; printf '%s\n' "$DEC" | grep -E "$ENCRYPTING" | head -5; fi

echo "3. the same at the object level"
for m in SheetCore SheetXLSX SheetCSV SheetODS SheetNumbers SwiftSheets; do
    OBJ=$(objects "$m")
    [ -n "$OBJ" ] || { fail "$m: no objects found under $BIN/$m.build"; continue; }
    hits=$(printf '%s\n' "$OBJ" | grep -cE "$CRYPTO_MODULES|$CRYPTO_TYPES" || true)
    if [ "$hits" -eq 0 ]; then pass "$m objects: define and reference no crypto symbol"
    else fail "$m objects: $hits crypto symbol(s):"; printf '%s\n' "$OBJ" | grep -E "$CRYPTO_MODULES|$CRYPTO_TYPES" | head -5; fi
done
OBJ=$(objects SheetDecrypt)
[ -n "$OBJ" ] || fail "SheetDecrypt: no objects found"
hits=$(printf '%s\n' "$OBJ" | grep -cE "$ENCRYPTING" || true)
if [ "$hits" -eq 0 ]; then pass "SheetDecrypt objects: define and reference nothing that encrypts"
else fail "SheetDecrypt objects: $hits encrypting symbol(s):"; printf '%s\n' "$OBJ" | grep -E "$ENCRYPTING" | head -5; fi

echo "4. and they behave: the protected fixture is refused by name without SheetDecrypt, opened with it"
if "$BIN/plain" "$FIXTURE" | grep -q "refused:.*SheetDecrypt"; then pass "plain refuses agile.xlsx and names SheetDecrypt"; else fail "plain did not refuse agile.xlsx by name"; fi
if "$BIN/decrypt-only" "$FIXTURE" swiftsheets | grep -q "read 1 sheet"; then pass "decrypt-only opens agile.xlsx with its password"; else fail "decrypt-only did not open agile.xlsx"; fi
if "$BIN/full" "$FIXTURE" swiftsheets | grep -q "reopened 1 sheet"; then pass "full protects and reopens"; else fail "full did not protect and reopen"; fi

[ "$failed" -eq 0 ] && echo "✅ no encryption code in the plain products; none that encrypts in SheetDecrypt" || { echo "❌ check-no-crypto failed"; exit 1; }
