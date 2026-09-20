#!/usr/bin/env bash
# Run each language's debugger to a breakpoint and check what it stopped on.
#
# The tour captures the debugger UI, and a breakpoint sign in the margin is all
# it asserts: the same frame is drawn when the adapter never starts. This drives
# the whole way -- open the file, set the breakpoint, start the session, pick
# the first configuration -- and matches on the variable values the adapter
# reported, which nothing but a live session can put on the screen.
#
# Usage:
#   check-debuggers.sh [-c CONFIG] [-n APPNAME] [-f REGEX] [-o OUT_DIR]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
OUT_DIR="${TMPDIR:-/tmp}/nvim-debuggers"
FILTER=""

while getopts "c:n:f:o:" opt; do
  case "$opt" in
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

# language | file | breakpoint line | the program that must be on PATH | expect
#
# `expect` is matched against the stopped frame. Every one of them names a
# value the adapter computed -- the arguments the call was made with, or the
# stack it stopped in -- so a frame drawn without a session cannot match.
# language | file | breakpoint line | the program that must be there |
# seconds to wait for the session | expect
#
# The wait is per language because they do not start alike: js-debug brings up
# a server and a bootloader before the program runs, and on a cold runner that
# took longer than the frame was captured after.
CASES=(
  "python|main.py|3|python3|20|b int = 1"
  "typescript|main.ts|2|node|40|b number = 1"
  "c|main.c|4|codelldb|20|b int = 1"
  "cpp|main.cpp|5|codelldb|20|b int = 1"
  "rust|src/main.rs|2|codelldb|20|b int = 1"
  "julia|main.jl|2|julia|30|add main.jl:2"
)

failures=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r lang file line needs settle expect <<<"$case"

  [[ -n "$FILTER" && ! "$lang" =~ $FILTER ]] && continue

  printf '%-12s ' "$lang"

  # Mason installs the adapters into the editor's own data directory, which is
  # not on PATH: looking only there said codelldb was missing on a machine
  # where three languages debugged fine.
  if ! command -v "$needs" >/dev/null &&
    [[ ! -x "${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME/mason/bin/$needs" ]]; then
    echo "skipped, no $needs on PATH or in mason"
    continue
  fi

  checked=$((checked + 1))
  ansi="$OUT_DIR/$lang.ansi"
  drawn="$OUT_DIR/$lang.drawn"

  if ! "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$HERE/debug-fixtures/$lang" \
    -t -I -e -w $((settle + 40)) -p 2 -o "$ansi" \
    ' ff' "$file" Enter ":$line" Enter ' db' \
    'wait:3: dc' 'wait:8:Enter' "wait:$settle:" >/dev/null 2>&1; then
    echo "FAILED: the driver gave up"
    failures+=("$lang: the driver gave up")
    continue
  fi

  sed -e 's/\x1b\[[0-9;]*m//g' "$ansi" >"$drawn"

  if grep -qF -- "$expect" "$drawn"; then
    echo "stopped at $file:$line"
  else
    echo "NEVER STOPPED: nothing matching '$expect', frame in $drawn"
    failures+=("$lang: no '$expect'")

    # A session that never starts leaves the breakpoint sign and nothing else.
    # nvim-dap writes every exchange with the adapter to its log, and an
    # adapter that died before speaking says so there. The notification that
    # carried the same news had faded long before the frame was captured.
    log="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/dap.log"
    echo "           what the adapter said:"
    if [[ -s "$log" ]]; then
      tail -12 "$log" | cut -c1-160 | sed 's/^/           /'
    else
      echo "           nothing: $log is empty or missing"
    fi
  fi
done

echo
if [[ ${#failures[@]} -gt 0 ]]; then
  echo "${#failures[@]} of $checked debugger(s) did not stop:"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
# A run where every language was skipped passes while measuring nothing, which
# is the failure this whole harness exists to stop.
if [[ "$checked" -eq 0 ]]; then
  echo "No debugger was checked: none of the adapters are installed." >&2
  exit 1
fi
echo "$checked debugger(s) stopped where they were told to."
