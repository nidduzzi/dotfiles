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

# Git Bash hands out /d/a/… paths, and a native Windows Neovim cannot open
# one: `luafile /d/a/…` is E484, which is a hit-enter prompt, which is a
# headless editor that never exits. cygpath is what Git Bash ships for this.
to_editor_path() {
  if command -v cygpath >/dev/null; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

SCRIPT="$(to_editor_path "$HERE/debug-headless.lua")"
CONFIG_FOR_EDITOR="$(to_editor_path "$CONFIG_ROOT")"

# language | file | breakpoint line | the program that must be there |
# seconds to wait for the session | expect
#
# The browser case is here too: serving a page and starting a browser is a few
# lines rather than a terminal, and it is the one case Windows could not
# otherwise check at all. It gets more time than the rest: a real browser
# launching under CI load is the slowest thing any of these cases starts.
CASES=(
  "python|main.py|3|python3|40|main.py:3"
  "typescript|main.ts|2|node|40|main.ts:2"
  "tsx|index.tsx|9|node|75|index.tsx:9"
  "c|main.c|4|codelldb|40|main.c:4"
  "cpp|main.cpp|5|codelldb|40|main.cpp:5"
  "rust|src/main.rs|2|codelldb|40|main.rs:2"
  "julia|main.jl|2|julia|40|main.jl:2"
)

OUT="${TMPDIR:-/tmp}/nvim-debuggers-headless"
mkdir -p "$OUT"

# The port the fixture's own dev script names, which is where the editor's
# browser configuration looks: both read it from that one package.json.
TSX_PORT="$(sed -n 's/.*--port \([0-9]*\).*/\1/p' "$HERE/debug-fixtures/tsx/package.json" 2>/dev/null | head -1)"
server_pid=""

# The status is carried through by hand: an EXIT trap whose last command
# succeeds hands that success to the caller.
stop_server() {
  local status=$?
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  return "$status"
}
trap stop_server EXIT

failures=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r lang file line needs settle expect <<<"$case"

  # The browser configuration is the second the editor offers for a .tsx file,
  # because a .tsx file is never simply run.
  choice=1
  [[ "$lang" == tsx ]] && choice=2

  [[ -n "$FILTER" && ! "$lang" =~ $FILTER ]] && continue

  printf '%-12s ' "$lang"

  # Where mason keeps its programs is the editor's decision, and it is a
  # different directory on Windows -- looking under ~/.local/share there found
  # nothing and skipped every case.
  if [[ -z "${MASON_BIN:-}" ]]; then
    MASON_BIN="$(
      env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_FOR_EDITOR" \
        nvim --headless +"lua io.stdout:write(vim.fn.stdpath('data') .. '/mason/bin') io.stdout:flush()" +qa 2>/dev/null
    )"
  fi

  if ! command -v "$needs" >/dev/null && ! ls "$MASON_BIN/$needs"* >/dev/null 2>&1; then
    echo "skipped, no $needs on PATH or in mason"
    continue
  fi

  if [[ ! -d "$HERE/debug-fixtures/$lang" ]]; then
    echo "skipped, no fixture: run make-debug-fixtures.sh"
    continue
  fi

  # The browser case brings its own page and its own browser, and skips when
  # either is missing rather than blaming the debugger for it.
  browser_env=()
  if [[ "$lang" == tsx ]]; then
    if [[ ! -f "$HERE/debug-fixtures/tsx/index.js" ]]; then
      echo "skipped, the fixture was never compiled"
      continue
    fi

    browser="$(
      env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_FOR_EDITOR" \
        nvim --headless +"lua io.stdout:write(require('util.browser').executable() or '') io.stdout:flush()" +qa 2>/dev/null
    )"
    if [[ -z "$browser" ]]; then
      echo "skipped, this machine has no browser to debug in"
      continue
    fi

    stop_server
    (cd "$HERE/debug-fixtures/tsx" && exec node "$HERE/serve-fixture.js" "$TSX_PORT") \
      >"$OUT/tsx.server" 2>&1 &
    server_pid=$!

    served=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      served="$(curl -s --max-time 2 "http://127.0.0.1:$TSX_PORT/index.js" 2>/dev/null | head -c 20 || true)"
      [[ -n "$served" ]] && break
      sleep 1
    done
    if [[ -z "$served" ]]; then
      echo "FAILED: nothing is serving the fixture on port '$TSX_PORT'"
      failures+=("$lang: the fixture was not served")
      continue
    fi

    browser_env=(DEBUG_BROWSER_HEADLESS=1)
    printf '(browser: %s) ' "$(basename "$browser")"
  fi

  checked=$((checked + 1))

  # No prompts, and nothing to type into one: a hit-enter prompt in a headless
  # editor blocks the loop that would otherwise time this out, and the Windows
  # job sat in one until CI gave up on the whole run.
  #
  # The editor's own exit status decides, not the shape of what it printed:
  # "stopped at main.py:3, expected main.py:99" starts the same way a pass
  # does, and a check that reads only the first two words passes it.
  answered="$OUT/$lang.said"
  if (
    cd "$HERE/debug-fixtures/$lang" &&
      DEBUG_LINE="$line" DEBUG_EXPECT="$expect" DEBUG_SETTLE="${DEBUG_SETTLE:-$settle}" \
        DEBUG_CHOICE="$choice" \
        env ${browser_env[@]+"${browser_env[@]}"} \
        ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_FOR_EDITOR" \
        nvim --headless --cmd 'set nomore' --cmd 'set shortmess+=atToOF' \
          "$file" +"luafile $SCRIPT" >"$answered" 2>&1 </dev/null
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
