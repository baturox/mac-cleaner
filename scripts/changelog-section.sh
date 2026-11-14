#!/bin/bash
# Prints the CHANGELOG.md section for a version (without its heading).
# Usage: scripts/changelog-section.sh 0.1.0
# Exits 1 when the section is missing or empty.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: changelog-section.sh <version>}"

SECTION="$(awk -v v="$VERSION" '
  /^## \[/ {
    if (found) exit
    if (index($0, "## [" v "]") == 1) { found = 1; next }
  }
  found { print }
' "$ROOT/CHANGELOG.md")"

if [ -z "$(printf '%s' "$SECTION" | tr -d '[:space:]')" ]; then
  echo "CHANGELOG.md has no section (or an empty one) for version $VERSION" >&2
  exit 1
fi
printf '%s\n' "$SECTION"
