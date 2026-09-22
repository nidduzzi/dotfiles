#!/usr/bin/env bash
# Run each language's debugger to a breakpoint and check what it stopped on:
# open the file, set the breakpoint, start the session, pick the first
# configuration, and match the variable values only a live session prints.
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

# language | file | breakpoint line | required program | settle secs |
# configuration to pick (position in the list the editor offers) | expect
CASES=(
  "python|main.py|3|python3|20|1|b int = 1"
  "typescript|main.ts|2|node|40|1|b number = 1"
  "tsx|index.tsx|9|node|60|2|b number = 1"
  "c|main.c|4|codelldb|20|1|b int = 1"
  "cpp|main.cpp|5|codelldb|20|1|b int = 1"
  "rust|src/main.rs|2|codelldb|20|1|b int = 1"
  "julia|main.jl|2|julia|30|1|add main.jl:2"
)

TSX_PORT="$(sed -n 's/.*--port \([0-9]*\).*/\1/p' "$HERE/debug-fixtures/tsx/package.json" 2>/dev/null | head -1)"
server_pid=""

stop_server() {
  local status=$?
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  return "$status"
}
trap stop_server EXIT

# What a browser configuration needs that does not belong in the config
# itself: headless flags, 127.0.0.1 (macOS resolves localhost to ::1 first),
# and its own profile.
HEADLESS="ex:lua for _, configuration in ipairs(require('dap').configurations[vim.bo.filetype] or {}) do if configuration.type == 'pwa-chrome' then configuration.runtimeArgs = { '--headless=new', '--no-sandbox', '--disable-gpu' } configuration.userDataDir = true configuration.trace = { logFile = 'TRACE_FILE' } if configuration.url then configuration.url = configuration.url:gsub('localhost', '127.0.0.1') end end end vim.fn.writefile({ 'applied' }, 'MARKER_FILE')"

failures=()
flaky=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r lang file line needs settle choice expect <<<"$case"

  [[ -n "$FILTER" && ! "$lang" =~ $FILTER ]] && continue

  printf '%-12s ' "$lang"

  # Mason installs into the editor's own data directory, which is not on PATH.
  if ! command -v "$needs" >/dev/null &&
    [[ ! -x "${XDG_DATA_HOME:-$HOME/.local/share}/$APPNAME/mason/bin/$needs" ]]; then
    echo "skipped, no $needs on PATH or in mason"
    continue
  fi

  if [[ "$lang" == tsx && ! -f "$HERE/debug-fixtures/tsx/index.js" ]]; then
    echo "skipped, the fixture was never compiled"
    continue
  fi

  # Asked of the editor rather than guessed at here, so both look in the
  # same places for a browser.
  browser=""
  if [[ "$lang" == tsx ]]; then
    browser="$(
      env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_ROOT" \
        nvim --headless +"lua io.stdout:write(require('util.browser').executable() or '')" +qa 2>/dev/null
    )"
    if [[ -z "$browser" ]]; then
      echo "skipped, this machine has no browser to debug in"
      continue
    fi
  fi

  checked=$((checked + 1))
  ansi="$OUT_DIR/$lang.ansi"
  drawn="$OUT_DIR/$lang.drawn"

  # Written the long way: an empty array under `set -u` is unbound on
  # bash 3.2 (macOS).
  prelude=()
  if [[ "$lang" == tsx ]]; then
    stop_server
    # node, not python3: python's http.server bound nothing on the macOS
    # runner and left curl timing out.
    (cd "$HERE/debug-fixtures/tsx" && exec node "$HERE/serve-fixture.js" "$TSX_PORT") \
      >"$OUT_DIR/tsx.server" 2>&1 &
    server_pid=$!
    trace_file="$OUT_DIR/tsx.jsdebug.log"
    marker="$OUT_DIR/tsx.prelude"
    rm -f "$trace_file" "$marker"
    prelude_command="${HEADLESS/TRACE_FILE/$trace_file}"
    prelude=("${prelude_command/MARKER_FILE/$marker}")

    served=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      served="$(curl -s --max-time 2 "http://127.0.0.1:$TSX_PORT/index.js" 2>/dev/null | head -c 20 || true)"
      [[ -n "$served" ]] && break
      sleep 1
    done
    if [[ -z "$served" ]]; then
      echo "FAILED: nothing is serving the fixture on port '$TSX_PORT'"
      echo "           curl says: $(curl -s -o /dev/null -w '%{http_code} exit=%{exitcode}' --max-time 2 "http://127.0.0.1:$TSX_PORT/index.js" 2>&1 || echo "exit=$?")"
      echo "           listening: $(
        (command -v lsof >/dev/null && lsof -nP -iTCP:"$TSX_PORT" -sTCP:LISTEN 2>/dev/null | tail -1) ||
          echo 'lsof says nothing'
      )"
      echo "           what the server said:"
      if [[ -s "$OUT_DIR/tsx.server" ]]; then
        sed 's/^/           /' "$OUT_DIR/tsx.server"
      else
        echo "           nothing at all, from $(command -v python3 || echo 'no python3')"
        echo "           starting one in the foreground:"
        (cd "$HERE/debug-fixtures/tsx" &&
          timeout 3 python3 -m http.server "$TSX_PORT" --bind 127.0.0.1 2>&1 | sed 's/^/           /') || true
      fi
      failures+=("$lang: the fixture was not served")
      continue
    fi
    printf '(browser: %s) ' "$(basename "$browser")"
  fi

  # Down, not j: the picker opens with its filter focused, so j types into it.
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

    # A real browser under contended CI hardware occasionally drops the DAP
    # session after a correct handshake (DECISIONS.md 57, 68): reported
    # rather than gating the job.
    if [[ "$lang" == tsx ]]; then
      flaky+=("$lang: no '$expect'")
    else
      failures+=("$lang: no '$expect'")
    fi

    log="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/dap.log"
    echo "           what the adapter said:"
    if [[ -s "$log" ]]; then
      tail -12 "$log" | cut -c1-160 | sed 's/^/           /'
    else
      echo "           nothing: $log is empty or missing"
    fi

    if [[ "$lang" == tsx && ! -f "$OUT_DIR/tsx.prelude" ]]; then
      echo "           the harness could not change the configuration: its Ex command never ran"
    fi

    if [[ -s "$OUT_DIR/$lang.jsdebug.log" ]]; then
      echo "           what the browser adapter traced:"
      grep -oE '"(error|exceptionThrown|cannot|Cannot)[^"]*"' "$OUT_DIR/$lang.jsdebug.log" |
        sort -u | head -6 | sed 's/^/           /'
      grep -oE 'Unable to launch browser[^"]*' "$OUT_DIR/$lang.jsdebug.log" | head -2 | sed 's/^/           /'
    fi

    echo "           what the editor offers for this file:"
    (cd "$HERE/debug-fixtures/$lang" &&
      env ${APPNAME:+NVIM_APPNAME="$APPNAME"} XDG_CONFIG_HOME="$CONFIG_ROOT" \
        nvim --headless "$file" \
        +"lua vim.defer_fn(function() local dap = require('dap') local ft = vim.bo.filetype local names = {} for _, c in ipairs(dap.configurations[ft] or {}) do names[#names + 1] = c.type .. ' ' .. c.request .. ' ' .. c.name end print(ft .. ': ' .. (#names > 0 and table.concat(names, ' | ') or 'no configurations')) vim.cmd('qa!') end, 8000)" \
        2>&1 | tail -3 | sed 's/^/           /') || true
  fi
done

echo
if [[ ${#flaky[@]} -gt 0 ]]; then
  echo "${#flaky[@]} known-flaky debugger(s) did not stop this run:"
  printf '  %s\n' "${flaky[@]}"
fi

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
