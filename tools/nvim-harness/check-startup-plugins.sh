#!/usr/bin/env bash
# What loads at startup, against what is supposed to: not how fast, but
# which plugins loaded before you asked for them.
#
# Usage:
#   check-startup-plugins.sh [-c CONFIG_DIR] [-n APPNAME] [-u]
#
#   -u  accept what it found, as the new baseline
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
EXPECTED="$HERE/expected-startup-plugins.txt"
UPDATE=0

while getopts "c:n:u" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    u) UPDATE=1 ;;
    *) exit 2 ;;
  esac
done

[[ -d "$HERE/fixture" ]] || "$HERE/make-fixture.sh" >/dev/null

REPORT="$(mktemp)"
FOUND="$(mktemp)"
trap 'rm -f "$REPORT" "$FOUND"' EXIT

PROBE_OUT="$REPORT" "$HERE/nvim-drive.sh" \
  -c "$CONFIG_DIR" -n "$APPNAME" -d "$HERE/fixture" \
  -t -I -w 60 -p 3 \
  "wait:5:ex:luafile $HERE/startup-plugins.lua" >/dev/null 2>&1 || true

[[ -s "$REPORT" ]] || { echo "the editor reported no plugins at all" >&2; exit 1; }

# LC_ALL=C: sort's order depends on locale, and a CI runner's C locale sorts
# capitals first while this machine ignores case.
tail -n +3 "$REPORT" | sed 's/^  //' | LC_ALL=C sort -u > "$FOUND"

if [[ "$UPDATE" -eq 1 ]]; then
  {
    grep '^#' "$EXPECTED"
    cat "$FOUND"
  } > "$EXPECTED.new"
  mv "$EXPECTED.new" "$EXPECTED"
  echo "baseline updated: $(wc -l < "$FOUND") plugins"
  exit 0
fi

if ! diff -u <(grep -v '^#' "$EXPECTED" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u) "$FOUND" > "$REPORT.diff"; then
  echo "What loads at startup has changed:"
  sed -n '3,$p' "$REPORT.diff" | sed 's/^/  /'
  echo
  echo "A + is a plugin that now loads before you ask for it."
  echo "check-startup-plugins.sh -u accepts it, once it is deliberate."
  rm -f "$REPORT.diff"
  exit 1
fi
rm -f "$REPORT.diff"

echo "$(head -1 "$REPORT"), all expected."
