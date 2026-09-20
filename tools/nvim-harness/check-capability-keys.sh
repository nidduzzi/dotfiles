#!/usr/bin/env bash
# Every key the capability list claims is a key something answers to.
#
# lua/util/capabilities.lua is kept by hand on purpose — generating it would
# list every mapping in the editor, which is the haystack it exists to avoid.
# A hand-kept list drifts, and this is the half a machine can check: the first
# key of an entry is a global or buffer-local mapping, and either it is bound
# or the entry describes a feature that has moved.
#
# Usage:
#   check-capability-keys.sh [-c CONFIG_DIR] [-n APPNAME]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

while getopts "c:n:" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

[[ -d "$HERE/fixture" ]] || "$HERE/make-fixture.sh" >/dev/null

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

CAPABILITY_KEYS_FILE="$HERE/fixture/lib.lua" \
  CAPABILITY_KEYS_OUT="$REPORT" \
  "$HERE/nvim-drive.sh" \
  -c "$CONFIG_DIR" -n "$APPNAME" -d "$HERE/fixture" \
  -t -I -w 60 -p 3 \
  "wait:12:ex:luafile $HERE/capability-keys.lua" >/dev/null 2>&1 || true

[[ -s "$REPORT" ]] || { echo "the capability list reported nothing at all" >&2; exit 1; }

if grep -q '^UNBOUND ' "$REPORT"; then
  echo "The capability list offers keys nothing is bound to:"
  grep '^UNBOUND ' "$REPORT" | sed 's/^UNBOUND /  /'
  exit 1
fi

echo "$(wc -l < "$REPORT") capability keys, all bound."
