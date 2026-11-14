#!/bin/bash
# Fills packaging/homebrew/mac-cleaner.rb with the current VERSION and the DMG checksum from
# dist/SHA256SUMS (run scripts/package.sh first).
#
# Usage: scripts/update-cask.sh [-o OUTPUT]
#   -o OUTPUT   where to write the cask (default: dist/mac-cleaner.rb). Copy it to
#               Casks/mac-cleaner.rb in your tap repository (baturox/homebrew-tap).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="dist/mac-cleaner.rb"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="${2:?-o needs a path}"; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "update-cask.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

VERSION="$(tr -d '[:space:]' < VERSION)"
[ -f dist/SHA256SUMS ] || { echo "dist/SHA256SUMS not found; run scripts/package.sh first." >&2; exit 1; }
SHA="$(awk -v f="MacCleaner-$VERSION.dmg" '$2 == f { print $1 }' dist/SHA256SUMS)"
[ -n "$SHA" ] || { echo "No checksum for MacCleaner-$VERSION.dmg in dist/SHA256SUMS." >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256__/$SHA/g" packaging/homebrew/mac-cleaner.rb > "$OUT"
echo "Wrote $OUT (version $VERSION, sha256 $SHA)"
