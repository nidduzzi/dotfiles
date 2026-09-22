#!/usr/bin/env bash
# Every key lua/util/capabilities.lua claims is a key something answers to.
# The list is hand-kept on purpose; this checks the half a machine can: the
# first key of an entry is bound, globally or buffer-locally.
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
