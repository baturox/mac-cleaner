#!/bin/bash
# Installs the `mac-cleaner` command-line tool.
#
# Usage: scripts/install-cli.sh [--copy] [--prefix DIR] [--from FILE] [--uninstall]
#
#   --copy        copy the binary instead of symlinking it
#   --prefix DIR  install into DIR (default: /usr/local/bin if writable, else ~/.local/bin)
#   --from FILE   the binary to install (default: the one inside an installed or freshly built app,
#                 or .build/release/mac-cleaner)
#   --uninstall   remove mac-cleaner from the install directory
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=link
PREFIX=""
FROM=""
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --copy) MODE=copy ;;
    --prefix) PREFIX="${2:?--prefix needs a directory}"; shift ;;
    --from) FROM="${2:?--from needs a file}"; shift ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-cli.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$PREFIX" ]; then
  if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then PREFIX=/usr/local/bin; else PREFIX="$HOME/.local/bin"; fi
fi
TARGET="$PREFIX/mac-cleaner"

if [ "$UNINSTALL" = 1 ]; then
  rm -f "$TARGET"
  echo "Removed $TARGET"
  exit 0
fi

if [ -z "$FROM" ]; then
  for candidate in "/Applications/Mac Cleaner.app/Contents/Resources/bin/mac-cleaner" \
                   "$ROOT/dist/Mac Cleaner.app/Contents/Resources/bin/mac-cleaner" \
                   "$ROOT/.build/release/mac-cleaner"; do
    if [ -x "$candidate" ]; then FROM="$candidate"; break; fi
  done
fi
[ -n "$FROM" ] && [ -x "$FROM" ] || {
  echo "No mac-cleaner binary found. Run scripts/build-app.sh (or 'swift build -c release') first, or pass --from FILE." >&2
  exit 1
}

mkdir -p "$PREFIX"
rm -f "$TARGET"
if [ "$MODE" = copy ]; then cp "$FROM" "$TARGET"; else ln -s "$FROM" "$TARGET"; fi
echo "Installed $TARGET ($MODE of $FROM)"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "Note: $PREFIX is not on your PATH. Add this to your shell profile:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
"$TARGET" --version
