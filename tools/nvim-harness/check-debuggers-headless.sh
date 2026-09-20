#!/usr/bin/env bash
# The same debuggers, without a terminal to drive.
#
# check-debuggers.sh is the check worth having: it presses the keys a person
# presses and reads the frame a person reads. It needs tmux, which Windows does
# not have, so the adapters went unchecked on the platform most likely to break
# them. This asks nvim-dap directly instead -- start this configuration, stop
# on this line -- and runs anywhere Neovim does.
#
# What it gives up: the keymap, the picker, and the variables pane. What it
# keeps: whether the adapter exists, starts, finds the program and stops where
# it was told to.
#
# Usage:
#   check-debuggers-headless.sh [-c CONFIG] [-n APPNAME] [-f REGEX]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
FILTER=""

while getopts "c:n:f:" opt; do
  case "$opt" in
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd)"

# language | file | breakpoint line | the program that must be there | expect
#
# The browser case is not here: it needs a page to be served and a browser to
# be started, which check-debuggers.sh does and this deliberately does not.
CASES=(
  "python|main.py|3|python3|main.py:3"
  "typescript|main.ts|2|node|main.ts:2"
  "c|main.c|4|codelldb|main.c:4"
  "cpp|main.cpp|5|codelldb|main.cpp:5"
  "rust|src/main.rs|2|codelldb|main.rs:2"
  "julia|main.jl|2|julia|main.jl:2"
)

OUT="${TMPDIR:-/tmp}/nvim-debuggers-headless"
mkdir -p "$OUT"

failures=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r lang file line needs expect <<<"$case"

  [[ -n "$FILTER" && ! "$lang" =~ $FILTER ]] && continue

  printf '%-12s ' "$lang"

  if ! command -v "$needs" >/dev/null &&
    [[ ! -x "${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME/mason/bin/$needs" ]]; then
    echo "skipped, no $needs on PATH or in mason"
    continue
  fi

  if [[ ! -d "$HERE/debug-fixtures/$lang" ]]; then
    echo "skipped, no fixture: run make-debug-fixtures.sh"
    continue
  fi

  checked=$((checked + 1))

  # The editor's own exit status decides, not the shape of what it printed:
  # "stopped at main.py:3, expected main.py:99" starts the same way a pass
  # does, and a check that reads only the first two words passes it.
  answered="$OUT/$lang.said"
  if (
    cd "$HERE/debug-fixtures/$lang" &&
      DEBUG_LINE="$line" DEBUG_EXPECT="$expect" DEBUG_SETTLE="${DEBUG_SETTLE:-40}" \
        env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_ROOT" \
        nvim --headless "$file" +"luafile $HERE/debug-headless.lua" >"$answered" 2>&1
  ); then
    # -o, because a notice about a missing language server arrives without a
    # newline and the answer ends up appended to it.
    echo "$(grep -oE 'stopped at [^ ,]+' "$answered" | head -1)"
  else
    said="$(grep -oE 'stopped at .*|never stopped: .*|no configuration[^.]*|no nvim-dap.*' "$answered" | head -1)"
    echo "FAILED: ${said:-the editor said nothing}"
    failures+=("$lang: ${said:-nothing}")
  fi
done

echo
if [[ ${#failures[@]} -gt 0 ]]; then
  echo "${#failures[@]} of $checked debugger(s) did not stop:"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi

if [[ "$checked" -eq 0 ]]; then
  echo "No debugger was checked: none of the adapters are installed." >&2
  exit 1
fi
echo "$checked debugger(s) stopped where they were told to."
