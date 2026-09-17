#!/usr/bin/env bash
# Check the keymaps of a Neovim config: collisions, duplicates, dead keys.
#
# Four faults, all of which shipped here before anything looked for them:
#
#   collision   a key that existed upstream and now does something else, taken
#               without noticing. <leader>sD silently replaced workspace
#               diagnostics; <leader>xq replaced the quickfix list.
#   shadowed    our own mapping losing to a buffer-local one, so the key does
#               something other than what the config says. <leader>cA lost to
#               LazyVim's Source Action.
#   duplicate   the same key bound twice inside this config. lazy.nvim keeps
#               one of them and says nothing.
#   dead        a key which is bound, appears in the hints, and does nothing.
#
# Usage:
#   check-keymaps.sh [-c CONFIG_DIR] [-n APPNAME] [-b BASELINE_DIR] [-B BASELINE_APP]
#
# The baseline is a stock LazyVim, so the difference is what this config did.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HERE/../../.worktrees/cfg"
APPNAME="nvim-lazyvim"
BASELINE_DIR="$HERE/trials"
BASELINE_APP="lazyvim-snacks"
WORKDIR="$HERE/fixture"
OUT="${TMPDIR:-/tmp}/nvim-keymap-check"

while getopts "c:n:b:B:d:o:" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    b) BASELINE_DIR="$OPTARG" ;;
    B) BASELINE_APP="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

mkdir -p "$OUT"
status=0

dump() { # config dir, appname, output
  "$HERE/nvim-drive.sh" -c "$1" -n "$2" -d "$WORKDIR" -t -e -w 24 -p 3 \
    'Space' 'ff' 'lib.lua' 'Enter' \
    ":lua vim.env.NVIM_KEYMAP_DUMP='$3' dofile('$HERE/keymap-dump.lua')" 'Enter' \
    >/dev/null 2>&1 || true
  [[ -s "$3" ]] || { echo "Could not dump keymaps for $2" >&2; return 1; }
}

echo "== collisions against stock LazyVim =="
dump "$BASELINE_DIR" "$BASELINE_APP" "$OUT/baseline.json"
dump "$CONFIG_DIR" "$APPNAME" "$OUT/current.json"

python3 "$HERE/keymap-collisions.py" \
  "$OUT/baseline.json" "$OUT/current.json" \
  --expected "$HERE/expected-collisions.txt" --quiet || status=1

echo
echo "== keys bound twice in this config =="
# Two specs binding the same key: lazy.nvim keeps one and reports nothing.
config_lua="$(dirname "$CONFIG_DIR")/nvim-lazyvim"
[[ -d "$config_lua" ]] || config_lua="$CONFIG_DIR/$APPNAME"

python3 "$HERE/duplicate-keys.py" "$config_lua/lua" || status=1

echo
echo "== dead keys and keys that describe nothing =="
NVIM_KEYMAP_AUDIT="$OUT/audit.txt" "$HERE/nvim-drive.sh" \
  -c "$CONFIG_DIR" -n "$APPNAME" -d "$WORKDIR" -t -e -w 24 -p 3 \
  'Space' 'ff' 'lib.lua' 'Enter' \
  ":lua vim.env.NVIM_KEYMAP_AUDIT='$OUT/audit.txt' dofile('$HERE/keymap-audit.lua')" 'Enter' \
  >/dev/null 2>&1 || true

if [[ -s "$OUT/audit.txt" ]]; then
  # Vim's own undescribed built-ins are hidden from the hints, so they are not
  # the fault this is looking for.
  grep -E "DEAD|EMPTY|names code" "$OUT/audit.txt" | grep -v "Plug" || echo "none"
else
  echo "audit did not run"
fi

echo
echo "reports in $OUT"
exit "$status"
