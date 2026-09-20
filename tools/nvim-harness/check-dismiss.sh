#!/usr/bin/env bash
# One press of the dismiss key closes what is open, and never the file.
#
# Every one of these passed on its own; the holes were all combinations. The
# debugger UI is six windows and the key did nothing in front of it, a
# terminal in a split did nothing, and a diff view owns its tab so closing one
# of its windows left the tab, the panel and the diff. See DECISIONS 31 and
# 32.
#
# Usage:
#   check-dismiss.sh [-c CONFIG_DIR] [-n APPNAME]
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

DISMISS_FILE="$HERE/fixture/broken.py" \
  DISMISS_OUT="$REPORT" \
  "$HERE/nvim-drive.sh" \
  -c "$CONFIG_DIR" -n "$APPNAME" -d "$HERE/fixture" \
  -t -I -w 90 -p 3 \
  "wait:90:ex:luafile $HERE/dismiss-combinations.lua" >/dev/null 2>&1 || true

[[ -s "$REPORT" ]] || { echo "the editor reported nothing at all" >&2; exit 1; }

# The file is python throughout: it is what was open at the start, and a key
# that closes the buffer you are working in is worse than one that does
# nothing.
status=0
while IFS= read -r line; do
  case "$line" in
    start*|end*)
      [[ "$line" == *"python"* ]] || { echo "the file went missing: $line"; status=1; }
      ;;
    *)
      after="${line##*after=}"
      opened="${line#* opened=}"
      opened="${opened%% after=*}"
      name="${line%% *}"
      if [[ "$after" != "python" ]]; then
        echo "  $name left something behind: $after"
        status=1
      elif [[ "$opened" == "python" ]]; then
        echo "  $name never opened anything, so the press proved nothing"
        status=1
      fi
      ;;
  esac
done < "$REPORT"

if [[ $status -eq 0 ]]; then
  echo "$(($(wc -l < "$REPORT") - 2)) things open, each closed by one press, file untouched."
fi
exit "$status"
