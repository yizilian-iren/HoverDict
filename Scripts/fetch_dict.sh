#!/bin/bash
#
# Download the ECDICT dictionary and build the slim Resources/ecdict.db that HoverDict
# bundles. The 125MB db is NOT committed to git (it exceeds GitHub's 100MB limit), so
# run this ONCE after cloning, before building the app.
#
# It downloads the official ECDICT SQLite release (~207MB), then rebuilds a compact db
# containing only single words + word/phonetic/translation (drops phrases and unused
# columns), which shrinks ~812MB → ~125MB.
#
#   ./Scripts/fetch_dict.sh           # build if missing
#   ./Scripts/fetch_dict.sh --force   # rebuild even if it exists
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$ROOT/Resources/ecdict.db"
URL="https://github.com/skywind3000/ECDICT/releases/download/1.0.28/ecdict-sqlite-28.zip"

if [[ -f "$OUT" && "${1:-}" != "--force" ]]; then
    echo "✅ $OUT already exists ($(du -h "$OUT" | cut -f1)). Use --force to rebuild."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading ECDICT SQLite (~207MB)…"
curl -L --fail -o "$TMP/ecdict-sqlite.zip" "$URL"

echo "==> Unzipping…"
unzip -o "$TMP/ecdict-sqlite.zip" -d "$TMP" >/dev/null
SRC="$TMP/stardict.db"
[[ -f "$SRC" ]] || { echo "error: stardict.db not found after unzip" >&2; exit 1; }

echo "==> Building slim dictionary (single words, non-empty translation)…"
mkdir -p "$ROOT/Resources"
rm -f "$OUT"
sqlite3 "$OUT" <<SQL
ATTACH '$SRC' AS src;
CREATE TABLE stardict (word TEXT COLLATE NOCASE PRIMARY KEY, phonetic TEXT, translation TEXT);
INSERT OR IGNORE INTO stardict (word, phonetic, translation)
  SELECT word, phonetic, translation FROM src.stardict
  WHERE translation IS NOT NULL AND translation != '' AND word NOT LIKE '% %';
CREATE INDEX idx_word ON stardict(word COLLATE NOCASE);
SQL
sqlite3 "$OUT" "VACUUM;"

COUNT="$(sqlite3 "$OUT" 'SELECT COUNT(*) FROM stardict;')"
echo ""
echo "✅ Built $OUT  ($(du -h "$OUT" | cut -f1), $COUNT words)"
echo "   Now build the app:  make app   (or  make run)"
