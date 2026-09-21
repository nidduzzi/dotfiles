#!/usr/bin/env bash
# Record a feature as a sequence of frames, one per keystroke, with the key
# that produced each.
#
# A screenshot proves a feature exists. It does not show the path to it, which
# is the part someone learning the editor actually needs: which key, what
# happened next, and what the editor looked like while it happened. A contact
# sheet of sixty stills is a reference. A short film of six frames is a lesson.
#
# Nothing new is installed. The harness already captures a pane as ANSI, and
# ansi-to-html.py already renders that faithfully; this captures a frame after
# every key batch instead of once at the end, and build-film.py turns the
# sequence into a page you can step through.
#
# Run one at a time. Two recordings sharing an NVIM_APPNAME share Neovim's
# swap and shada directories, and the second one opens a file the first still
# holds: a film recorded that way ends on the dashboard with nothing in it. The
# tmux socket carries the process id, so the servers do not collide — the
# editor's own state still does.
#
# Usage:
#   film.sh [options] KEY_BATCH [KEY_BATCH ...]
#
# Options mirror nvim-drive.sh:
#   -c DIR    config directory        -n NAME  NVIM_APPNAME
#   -d DIR    working directory       -o DIR   where frames are written
#   -W COLS   pane width              -H ROWS  pane height
#   -w SECS   readiness timeout       -p SECS  pause after each batch
#   -P SECS   pause after a `slow:` batch, for a key that starts a request
#   -t        trust the project's .nvim.lua, inside this harness only
#   -F        trust one outside it, which runs Lua the project wrote
#   -I        start with -i NONE, so a remembered cursor cannot move the keys
#   -T TEXT   title for this film
#
# A batch written as `ex:<command>` is sent over RPC as an Ex command, which is
# the reliable way to set a scene before the part being demonstrated.
#
# A batch written as `keys:a b c` sends those keys together with no pause, for
# a sequence that has to arrive as one mapping rather than as separate presses.
#
# A batch written as `wait:<seconds>:<batch>` waits that long before the frame
# is captured, for anything the editor does not announce the end of.
#
# A batch written as `slow:<batch>` starts a request and waits for the answer
# instead of for the clock: the editor is asked over RPC whether the agent is
# still running, and the frame is captured once it is not. -P is the cap, not
# the wait.
#
# Both halves of that matter. A fixed pause was wrong in both directions — a
# local 35B answered a hint in 151 seconds against a 150 second pause, so the
# film recorded an empty screen and looked like a broken feature; and every
# faster answer sat idle for the rest of the pause, which is how a nine-film
# tour came to take two hours to record the eight frames that needed to wait.
# It composes: `slow:keys:Space ar` is both.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR=""
APPNAME=""
WORKDIR=""
OUT="${TMPDIR:-/tmp}/nvim-film"
COLS=120
ROWS=34
BOOT_WAIT=60
KEY_WAIT=1.5
SLOW_WAIT=""
TRUST=0
FORCE_TRUST=0
NO_SHADA=0
TITLE="Neovim"

while getopts "c:n:d:o:W:H:w:p:P:T:tFI" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    W) COLS="$OPTARG" ;;
    H) ROWS="$OPTARG" ;;
    w) BOOT_WAIT="$OPTARG" ;;
    p) KEY_WAIT="$OPTARG" ;;
    P) SLOW_WAIT="$OPTARG" ;;
    T) TITLE="$OPTARG" ;;
    t) TRUST=1 ;;
    F) FORCE_TRUST=1 ;;
    I) NO_SHADA=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

: "${SLOW_WAIT:=$KEY_WAIT}"

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

: "${WORKDIR:=$PWD}"
SOCKET="nvim-film-$$"
RPC="${TMPDIR:-/tmp}/nvim-film-$$.sock"

tm() { tmux -L "$SOCKET" "$@"; }

# tmux resolves an argument to a key name before treating it as text, and its
# key names are short: DC is Delete, IC is Insert, and `dc` matches DC without
# regard to case. `tmux send-keys dc` emits ^[[3~, so <leader>dc deleted a
# character instead of starting the debugger, silently.
#
# So a batch is sent literally unless it names a key. The names recognised here
# are the ones these scripts use; anything else is text.
is_key_name() {
  case "$1" in
    Space|Enter|Escape|Tab|BSpace|BTab|Up|Down|Left|Right|Home|End|PageUp|PageDown|IC|DC|NPage|PPage) return 0 ;;
    C-*|M-*|S-*|F[0-9]|F1[0-2]) return 0 ;;
    *) return 1 ;;
  esac
}

send_batch() {
  local key
  for key in "$@"; do
    if is_key_name "$key"; then
      tm send-keys "$key"
    else
      tm send-keys -l -- "$key"
    fi
  done
}

# Every process the pane's own shell ever spawned, root first. See
# nvim-drive.sh's cleanup() for why this exists and why it is one ps call
# and an awk walk rather than --ppid, which is GNU-only.
collect_descendants() {
  local root="$1"
  ps -A -o pid=,ppid= 2>/dev/null | awk -v root="$root" '
    { children[$2] = children[$2] " " $1 }
    function walk(p,   c, list, n, i) {
      list = children[p]
      n = split(list, c, " ")
      for (i = 1; i <= n; i++) {
        if (c[i] != "") {
          print c[i]
          walk(c[i])
        }
      }
    }
    END { walk(root) }
  '
}

cleanup() {
  # See nvim-drive.sh's cleanup() for what this is and how it was found: a
  # server-type DAP adapter (julia, js-debug's headless Chrome) is started
  # detached, in its own process group, and does not go down with the pane.
  local pane_pid descendants
  pane_pid="$(tm display-message -p '#{pane_pid}' 2>/dev/null || true)"
  descendants=""
  if [[ -n "$pane_pid" ]]; then
    descendants="$(collect_descendants "$pane_pid" || true)"
  fi

  tm kill-server 2>/dev/null || true
  # kill-server does not reliably take Neovim with it either -- $RPC is
  # unique to this one process (nvim-film-$$.sock), so this can only ever
  # match the Neovim this run itself started.
  pkill -f -- "--listen ${RPC:-nvim-film-not-set}" 2>/dev/null || true

  if [[ -n "$descendants" ]]; then
    echo "$descendants" | while IFS= read -r pid; do
      kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.3
    echo "$descendants" | while IFS= read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    done
  fi

  rm -f "$RPC" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
}
trap cleanup EXIT

mkdir -p "$OUT"
rm -f "$OUT"/frame-*.ansi "$OUT"/frames.tsv

if [[ -n "$APPNAME" ]]; then
  swap_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/swap"
  [[ -d "$swap_dir" ]] && rm -f "$swap_dir"/* || true
fi

if [[ "$TRUST" -eq 1 && -f "$WORKDIR/.nvim.lua" ]]; then
  # .nvim.lua is Lua the repository wrote, and trusting it runs it. Answered
  # here only for the fixture, which this repository generates.
  workdir_real="$(cd "$WORKDIR" && pwd)"
  if [[ "$workdir_real" == "$HERE"/* || "$FORCE_TRUST" -eq 1 ]]; then
    env ${APPNAME:+NVIM_APPNAME="$APPNAME"} ${CONFIG_DIR:+XDG_CONFIG_HOME="$CONFIG_DIR"} \
      nvim --headless -u NONE \
      +"lua vim.secure.trust({ action = 'allow', path = '$WORKDIR/.nvim.lua' })" \
      +qa 2>/dev/null || true
  else
    echo "Refusing to trust $workdir_real/.nvim.lua without -F." >&2
    exit 3
  fi
fi

launch="nvim"
[[ -n "$APPNAME" ]] && launch="NVIM_APPNAME=$APPNAME $launch"
[[ -n "$CONFIG_DIR" ]] && launch="XDG_CONFIG_HOME=$CONFIG_DIR $launch"

# Carry through what the agent backends read for their endpoint and key. The
# editor is started by tmux, which does not inherit this shell's environment,
# so without this Hermes falls back to whatever its config names and answers
# `HTTP 401: Unauthorized` — which the review then reported as "Nothing found",
# because a failed request and a clean function looked the same.
# ANTHROPIC_API_KEY is deliberately not forwarded. Nothing here drives an
# API, and a key in the environment is a key any program the editor starts can
# read — which is exactly how the project-binary canary captured one.
for name in CUSTOM_BASE_URL CUSTOM_API_KEY HERMES_ALLOW_PRIVATE_URLS \
            HERMES_INFERENCE_PROVIDER HERMES_INFERENCE_MODEL; do
  if [[ -n "${!name:-}" ]]; then
    launch="$name=$(printf '%q' "${!name}") $launch"
  fi
done
launch="env $launch --listen $RPC"
[[ "$NO_SHADA" -eq 1 ]] && launch="$launch -i NONE"

tm -f /dev/null new-session -d -x "$COLS" -y "$ROWS" -c "$WORKDIR" "$launch"

# Wait for the editor rather than guessing, as nvim-drive.sh does.
deadline=$((SECONDS + BOOT_WAIT))
ready=0
while (( SECONDS < deadline )); do
  if [[ -S "$RPC" ]] && nvim --server "$RPC" --remote-expr 'v:vim_did_enter' 2>/dev/null | grep -q '^1$'; then
    ready=1
    break
  fi
  sleep 0.2
done
[[ "$ready" -eq 1 ]] || { echo "Neovim did not become ready within ${BOOT_WAIT}s" >&2; exit 1; }

lazy_deadline=$((SECONDS + BOOT_WAIT))
while (( SECONDS < lazy_deadline )); do
  state=$(nvim --server "$RPC" --remote-expr \
    'luaeval("(package.loaded[\"lazy.core.loader\"] ~= nil and vim.g.lazy_did_setup == true) and 1 or 0")' 2>/dev/null)
  [[ "$state" == "1" ]] && break
  sleep 0.2
done

frame=0
capture() { # label
  local file
  file="$(printf '%s/frame-%03d.ansi' "$OUT" "$frame")"
  tm capture-pane -p -e -N -S 0 -E "$((ROWS - 1))" > "$file"
  printf '%s\t%s\n' "$(basename "$file")" "$1" >> "$OUT/frames.tsv"
  frame=$((frame + 1))
}

# The opening frame: what the editor looked like before anything was pressed.
capture "before"

# Wait until the agent has stopped running, or until the cap. Polled over RPC
# rather than slept, for the reason in the header.
await_agent() {
  local deadline=$((SECONDS + ${SLOW_WAIT%.*} + 1))
  # Let the key be seen before asking: a request that has not started yet
  # reports "not running", which is indistinguishable from one that finished.
  sleep 2
  while (( SECONDS < deadline )); do
    local state
    state=$(nvim --server "$RPC" --remote-expr \
      'luaeval("(pcall(require, \"util.agent\") and require(\"util.agent\").is_running()) and 1 or 0")' 2>/dev/null)
    [[ "$state" == "0" ]] && break
    sleep 1
  done
  # The answer arrives, then the window that shows it is opened on the next
  # tick. Capturing between the two records the buffer with nothing over it.
  sleep 1.5
}

for batch in "$@"; do
  wait_for="$KEY_WAIT"
  slow=0
  if [[ "$batch" == slow:* ]]; then
    slow=1
    batch="${batch#slow:}"
  elif [[ "$batch" == wait:* ]]; then
    # Wait a stated number of seconds before capturing, for something the
    # editor does not report as finished. `slow:` asks the agent whether it is
    # still working; a debugger has no such question to answer.
    wait_for="${batch#wait:}"
    wait_for="${wait_for%%:*}"
    batch="${batch#wait:*:}"
  fi

  if [[ "$batch" == ex:* ]]; then
    nvim --server "$RPC" --remote-expr "execute('${batch#ex:}')" >/dev/null 2>&1 || true
    label=":${batch#ex:}"
  elif [[ "$batch" == keys:* ]]; then
    # Several keys delivered together, with no pause between them. A leader
    # sequence sent as separate batches has seconds between its keys, and a
    # mapping split that far apart is not the mapping — `Space` then `?` a
    # second later is not <leader>?, it is a space and a reverse search.
    # Split on spaces with globbing off. Unquoted expansion looked simpler and
    # was wrong: `?` and `*` are key names to tmux and glob characters to the
    # shell, so `keys:Space ?` could expand to a filename before tmux saw it.
    set -f
    # shellcheck disable=SC2086
    read -r -a _keys <<< "${batch#keys:}"
    set +f
    send_batch "${_keys[@]}"
    label="${batch#keys:}"
  else
    send_batch "$batch"
    label="$batch"
  fi
  if [[ "$slow" -eq 1 ]]; then
    await_agent
  else
    sleep "$wait_for"
  fi
  capture "$label"
done

printf '%s\n' "$TITLE" > "$OUT/title.txt"
echo "$frame frames in $OUT"
echo "Build the page with:"
echo "  $HERE/build-film.py --dir $OUT --out $OUT/index.html"
