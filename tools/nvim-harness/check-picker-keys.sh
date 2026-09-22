#!/usr/bin/env bash
# 1. Every key the feature tour presses inside a picker is bound to something
#    (a captured frame proves the editor drew, not that the key did anything).
# 2. Every key this config takes from snacks is in expected-picker-overrides.txt.
#
# Usage:
#   check-picker-keys.sh [-c CONFIG_DIR] [-n APPNAME]
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

KEYS="$(mktemp)"
trap 'rm -f "$KEYS"' EXIT

PICKER_KEYS_OUT="$KEYS" \
  XDG_CONFIG_HOME="$CONFIG_DIR" \
  NVIM_APPNAME="$APPNAME" \
  nvim --headless \
  -c 'lua require("lazy").load({ plugins = { "snacks.nvim" } })' \
  -c "luafile $HERE/picker-keys.lua" \
  -c qa >/dev/null 2>&1

[[ -s "$KEYS" ]] || { echo "the picker reported no keys at all" >&2; exit 1; }

status=0

# Keys the tour presses that nothing answers to: only the ones a picker could
# plausibly own (modifier combos).
driven=()
while IFS= read -r line; do
  driven+=("$line")
done < <(
  grep -oE '"[a-z-]+\|[^|]*\|[0-9]+\|[^"]*"' "$HERE/feature-tour.sh" |
    tr -d '"' | tr '|' '\n' |
    sed 's/^wait:[0-9]*://' |
    grep -E '^[MC]-.$' | sort -u
)

unbound=()
for key in "${driven[@]}"; do
  # tmux spells a modifier M-x/C-x; snacks spells it <M-x>/<C-x>.
  bracketed="<${key}>"
  if ! grep -qiF "bound input $bracketed" "$KEYS" && ! grep -qiF "bound list $bracketed" "$KEYS"; then
    unbound+=("$key")
  fi
done

if [[ ${#unbound[@]} -gt 0 ]]; then
  echo "The tour presses these inside a picker, and nothing is bound to them:"
  printf '  %s\n' "${unbound[@]}"
  status=1
fi

allowed="$HERE/expected-picker-overrides.txt"
undeclared="$(
  grep '^override ' "$KEYS" |
    grep -vxFf <(grep -v '^#' "$allowed" | grep -v '^[[:space:]]*$') || true
)"

if [[ -n "$undeclared" ]]; then
  echo "These picker keys already meant something to snacks:"
  echo "$undeclared" | sed 's/^/  /'
  echo
  echo "Add a line to $(basename "$allowed") if that is deliberate."
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "$(grep -c '^bound ' "$KEYS") picker keys, $(grep -c '^override ' "$KEYS") of them taken from snacks, all declared."
  echo "${#driven[@]} key(s) the tour presses inside a picker are bound."
fi

exit "$status"
