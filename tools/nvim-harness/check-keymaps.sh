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

# Both of these used to print and move on, so a dead key and a clean run were
# the same exit status. They are faults like the other two, and they fail here
# now, with an allowlist for the ones that are someone else's decision.
#
# The allowlist is matched as a fixed substring of the reported line, one per
# line, blank lines and # comments ignored — the same shape as
# expected-collisions.txt, and the same rule: every entry needs a reason.
ALLOWED="$HERE/expected-dead-keys.txt"

# Drop the allowed lines out of a report, leaving what is news.
unexpected() {
  if [[ -f "$ALLOWED" ]]; then
    grep -vxF -f <(grep -v '^\s*#' "$ALLOWED" | grep -v '^\s*$') || true
  else
    cat
  fi
}

if [[ -s "$OUT/audit.txt" ]]; then
  # Vim's own undescribed built-ins are hidden from the hints, so they are not
  # the fault this is looking for.
  # `|| true` on every grep: finding nothing is the good outcome here, and a
  # grep that matches nothing exits 1, which under `set -e` killed the script
  # before it could say so.
  dead="$( { grep -E "DEAD|EMPTY|names code" "$OUT/audit.txt" || true; } | { grep -v "Plug" || true; } | unexpected)"
  if [[ -n "$dead" ]]; then
    printf '%s\n' "$dead"
    echo
    echo "$(printf '%s\n' "$dead" | wc -l) key(s) are bound, appear in the hints, and do nothing"
    echo "or describe nothing. Fix them, or add them to $(basename "$ALLOWED") with a reason."
    status=1
  else
    echo "none"
  fi

  echo
  echo "== single keys a plugin took over without describing =="
  # flash.nvim takes f, F, t and T. They answer to nothing — not which-key, not
  # the capability list — so "what does t do" had no answer in the editor.
  taken="$( { grep -E "^TAKEN" "$OUT/audit.txt" || true; } | unexpected)"
  if [[ -n "$taken" ]]; then
    printf '%s\n' "$taken"
    echo
    echo "A single key was taken over without a description. Describe it, or add"
    echo "it to $(basename "$ALLOWED") with a reason."
    status=1
  else
    echo "none"
  fi
else
  echo "audit did not run"
  # An audit that did not run has proven nothing, which is not the same as
  # having found nothing.
  status=1
fi

echo
echo "reports in $OUT"
exit "$status"
