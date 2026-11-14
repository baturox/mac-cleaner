#!/bin/bash
# Installs the `mac-cleaner` command-line tool.
#
# Usage: scripts/install-cli.sh [--copy] [--prefix DIR] [--from FILE] [--uninstall]
#
#   --copy        copy the binary instead of symlinking it (always done when installing as root or into a
#                 folder you do not own: a root-owned link to a file you can rewrite would let anything
#                 running as you replace a program that others, or sudo, later run)
#   --prefix DIR  install into DIR (default: /usr/local/bin if writable, else ~/.local/bin; as root always
#                 /usr/local/bin)
#   --from FILE   the binary to install (default: the one inside an installed or freshly built app,
#                 or .build/release/mac-cleaner). A relative path is resolved against the current folder.
#   --uninstall   remove mac-cleaner from the install directory
#
# As root (sudo) this script never creates a folder inside a normal account's home and never installs into
# a folder that a normal account owns: either would leave root-owned files in a user's home, or a program
# that root later runs in a place that user can rewrite.
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
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-cli.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

AS_ROOT=0
[ "$(id -u)" = 0 ] && AS_ROOT=1

if [ -z "$PREFIX" ]; then
  if [ "$AS_ROOT" = 1 ]; then
    # Under sudo, $HOME is usually still the invoking user's home: never default into it.
    PREFIX=/usr/local/bin
  elif [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then PREFIX=/usr/local/bin; else PREFIX="$HOME/.local/bin"; fi
fi
TARGET="$PREFIX/mac-cleaner"

# The nearest folder at or above $1 that exists.
existing_ancestor() {
  local d="$1"
  while [ ! -d "$d" ]; do
    local up; up="$(dirname "$d")"
    [ "$up" = "$d" ] && break
    d="$up"
  done
  printf '%s' "$d"
}

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
[ -n "$FROM" ] && [ -f "$FROM" ] && [ -x "$FROM" ] || {
  echo "No mac-cleaner binary found. Run scripts/build-app.sh (or 'swift build -c release') first, or pass --from FILE." >&2
  exit 1
}
# A link must not depend on the folder this script happened to be started from.
FROM="$(cd "$(dirname "$FROM")" && pwd -P)/$(basename "$FROM")"

# Who are we, and whose folder is this (or, if it does not exist yet, the folder it would be created in)?
ANCESTOR="$(existing_ancestor "$PREFIX")"
ANCESTOR_OWNER="$(stat -f %u "$ANCESTOR")"
if [ "$AS_ROOT" = 1 ] && [ "$ANCESTOR_OWNER" != 0 ]; then
  if [ "$ANCESTOR" = "$PREFIX" ]; then
    echo "Refusing to install as root into $PREFIX: it belongs to a normal account (uid $ANCESTOR_OWNER), which could replace a program that root runs. Run this without sudo, or choose a root-owned --prefix such as /usr/local/bin." >&2
  else
    echo "Refusing to create $PREFIX as root: it would be a root-owned folder inside $ANCESTOR, which belongs to a normal account (uid $ANCESTOR_OWNER). Run this without sudo, or choose a root-owned --prefix such as /usr/local/bin." >&2
  fi
  exit 1
fi
mkdir -p "$PREFIX"
PREFIX_OWNER="$(stat -f %u "$PREFIX")"
if [ "$AS_ROOT" = 1 ] || [ "$PREFIX_OWNER" != "$(id -u)" ]; then
  if [ "$MODE" = link ]; then
    echo "Installing into a folder owned by another account (or as root): copying instead of linking."
  fi
  MODE=copy
fi

rm -f "$TARGET"
if [ "$MODE" = copy ]; then
  if [ "$AS_ROOT" = 1 ]; then
    # A regular root-owned file that only root can change. `install` copies the bytes; it does not run them.
    install -m 0755 -o root -g wheel "$FROM" "$TARGET"
  else
    install -m 0755 "$FROM" "$TARGET"
  fi
else
  ln -s "$FROM" "$TARGET"
fi
echo "Installed $TARGET ($MODE of $FROM)"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo "Note: $PREFIX is not on your PATH. Add this to your shell profile:  export PATH=\"$PREFIX:\$PATH\"" ;;
esac
if [ "$AS_ROOT" = 1 ]; then
  # Never run the freshly installed program as root: it came from a location a normal account may control.
  echo "Not running it as root. Check it yourself with:  mac-cleaner --version"
else
  "$TARGET" --version
fi
