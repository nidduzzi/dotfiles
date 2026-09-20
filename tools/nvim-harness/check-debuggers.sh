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

# language | file | breakpoint line | the program that must be there |
# seconds to wait for the session | which configuration to pick | expect
#
# `expect` is matched against the stopped frame. Every one of them names a
# value the adapter computed -- the arguments the call was made with, or the
# stack it stopped in -- so a frame drawn without a session cannot match.
#
# The wait is per language because they do not start alike: js-debug brings up
# a server and a bootloader before the program runs, and on a cold runner that
# took longer than the frame was captured after.
#
# The configuration is picked by position in the list the editor offers. 1 runs
# the file; a .tsx file is never run, so 2 opens a browser on the dev server,
# which is how a component is really debugged -- the browser runs compiled
# JavaScript and the source map puts the stop back on the line you wrote.
CASES=(
  "python|main.py|3|python3|20|1|b int = 1"
  "typescript|main.ts|2|node|40|1|b number = 1"
  "tsx|index.tsx|9|node|60|2|b number = 1"
  "c|main.c|4|codelldb|20|1|b int = 1"
  "cpp|main.cpp|5|codelldb|20|1|b int = 1"
  "rust|src/main.rs|2|codelldb|20|1|b int = 1"
  "julia|main.jl|2|julia|30|1|add main.jl:2"
)

# The port the TSX fixture's dev script names, which is where the editor's
# browser configuration looks: both read it from that one package.json.
TSX_PORT="$(sed -n 's/.*--port \([0-9]*\).*/\1/p' "$HERE/debug-fixtures/tsx/package.json" 2>/dev/null | head -1)"
server_pid=""

# The status is carried through by hand: an EXIT trap whose last command
# succeeds hands that success to the caller, and this one turned a script that
# died on its first case into a step CI called green.
stop_server() {
  local status=$?
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  return "$status"
}
trap stop_server EXIT

# A browser the debugger starts wants a screen, and there is none here. The
# harness says so rather than the configuration, because a person debugging a
# component wants to watch the page.
# Two things the harness changes about a browser configuration, neither of
# which belongs in the configuration itself: a browser started here has no
# screen to draw on, and the address is pinned to the one the fixture's server
# is listening on -- on macOS `localhost` resolves to ::1 first, where nothing
# answers, and the page never loaded.
HEADLESS="ex:lua for _, configuration in ipairs(require('dap').configurations[vim.bo.filetype] or {}) do if configuration.type == 'pwa-chrome' then configuration.runtimeArgs = { '--headless=new', '--no-sandbox', '--disable-gpu' } if configuration.url then configuration.url = configuration.url:gsub('localhost', '127.0.0.1') end end end"

failures=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r lang file line needs settle choice expect <<<"$case"

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

  # The browser runs compiled JavaScript, and make-debug-fixtures.sh compiles
  # it only where a TypeScript compiler was found. Without it the page loads
  # nothing, the breakpoint stays provisional, and the gate would report that
  # as a debugger that did not stop.
  if [[ "$lang" == tsx && ! -f "$HERE/debug-fixtures/tsx/index.js" ]]; then
    echo "skipped, the fixture was never compiled"
    continue
  fi

  # Asked of the editor rather than guessed at here, so the gate and the
  # configuration are looking for the same browser in the same places.
  if [[ "$lang" == tsx ]] && [[ -z "$(
    env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_ROOT" \
      nvim --headless +"lua io.stdout:write(require('util.browser').executable() or '')" +qa 2>/dev/null
  )" ]]; then
    echo "skipped, this machine has no browser to debug in"
    continue
  fi

  checked=$((checked + 1))
  ansi="$OUT_DIR/$lang.ansi"
  drawn="$OUT_DIR/$lang.drawn"

  # The page a browser configuration opens has to be served by something, and
  # the fixture's own dev script is a plain static server.
  # Written the long way because macOS ships bash 3.2, where an empty array
  # under `set -u` is an unbound variable rather than nothing at all.
  prelude=()
  if [[ "$lang" == tsx ]]; then
    stop_server
    (cd "$HERE/debug-fixtures/tsx" && exec python3 -m http.server "$TSX_PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
    server_pid=$!
    prelude=("$HEADLESS")
  fi

  # Down, not j: the picker opens with its filter focused, so j is a letter
  # typed into the filter -- which matched nothing, selected nothing, and left
  # no session and no log to say why.
  picks=()
  for ((pick = 1; pick < choice; pick++)); do
    picks+=(Down)
  done

  if ! "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$HERE/debug-fixtures/$lang" \
    -t -I -e -w $((settle + 40)) -p 2 -o "$ansi" \
    ' ff' "$file" Enter ":$line" Enter ' db' ${prelude[@]+"${prelude[@]}"} \
    'wait:3: dc' 'wait:6:' ${picks[@]+"${picks[@]}"} Enter "wait:$settle:" >/dev/null 2>&1; then
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

    # An empty log means nothing ever spoke to an adapter, which is a question
    # about the configurations the editor offers rather than about the
    # debugger. Ask it directly, without a terminal in the way.
    echo "           what the editor offers for this file:"
    (cd "$HERE/debug-fixtures/$lang" &&
      env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_ROOT" \
        nvim --headless "$file" \
        +"lua vim.defer_fn(function() local dap = require('dap') local ft = vim.bo.filetype local names = {} for _, c in ipairs(dap.configurations[ft] or {}) do names[#names + 1] = c.type .. ' ' .. c.request .. ' ' .. c.name end print(ft .. ': ' .. (#names > 0 and table.concat(names, ' | ') or 'no configurations')) vim.cmd('qa!') end, 8000)" \
        2>&1 | tail -3 | sed 's/^/           /') || true
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
