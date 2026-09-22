#!/usr/bin/env bash
# Check the keymaps of a Neovim config: collisions, duplicates, dead keys.
#
#   collision   a key that existed upstream and now does something else
#   shadowed    our mapping losing to a buffer-local one
#   duplicate   the same key bound twice; lazy.nvim keeps one and says nothing
#   dead        a key which is bound, appears in the hints, and does nothing
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
  local complaint
  complaint="$(mktemp)"

  "$HERE/nvim-drive.sh" -c "$1" -n "$2" -d "$WORKDIR" -t -e -w 24 -p 3 \
    'Space' 'ff' 'lib.lua' 'Enter' \
    ":lua vim.env.NVIM_KEYMAP_DUMP='$3' dofile('$HERE/keymap-dump.lua')" 'Enter' \
    >/dev/null 2>"$complaint" || true

  if [[ ! -s "$3" ]]; then
    echo "Could not dump keymaps for $2" >&2
    sed 's/^/  /' "$complaint" >&2
    rm -f "$complaint"
    return 1
  fi
  rm -f "$complaint"
}

echo "== collisions against stock LazyVim =="
dump "$BASELINE_DIR" "$BASELINE_APP" "$OUT/baseline.json"
dump "$CONFIG_DIR" "$APPNAME" "$OUT/current.json"

python3 "$HERE/keymap-collisions.py" \
  "$OUT/baseline.json" "$OUT/current.json" \
  --expected "$HERE/expected-collisions.txt" --quiet || status=1

echo
echo "== keys bound twice in this config =="
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

# Allowlist: a fixed substring per line, blank lines and # comments ignored,
# same shape as expected-collisions.txt.
ALLOWED="$HERE/expected-dead-keys.txt"

unexpected() {
  if [[ -f "$ALLOWED" ]]; then
    grep -vxF -f <(grep -v '^\s*#' "$ALLOWED" | grep -v '^\s*$') || true
  else
    cat
  fi
}

if [[ -s "$OUT/audit.txt" ]]; then
  # `|| true` on every grep: no match is the good outcome here, and grep
  # exits 1 on it, which set -e would otherwise treat as a failure.
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
  status=1
fi

echo
echo "reports in $OUT"
exit "$status"
