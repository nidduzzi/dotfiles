#!/usr/bin/env bash
# Record a feature as a sequence of frames, one per keystroke, with the key
# that produced each -- a short film rather than a single screenshot.
#
# Run one at a time. Two recordings sharing an NVIM_APPNAME share Neovim's
# swap and shada, and the second opens a file the first still holds.
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
#   -I        start with -i NONE
#   -T TEXT   title for this film
#
#   `ex:<command>`   sent over RPC as an Ex command
#   `keys:a b c`     sent together with no pause, for a mapping that needs its
#                    keys to arrive as one
#   `wait:<secs>:<batch>`  waits that long before the frame is captured
#   `slow:<batch>`   waits for the agent to stop answering (polled over RPC)
#                    instead of a fixed pause, capped by -P
#
# Composable: `slow:keys:Space ar` is both.
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

# See nvim-drive.sh: tmux resolves DC/IC etc. as key names before text.
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

# See nvim-drive.sh's collect_descendants() -- one ps call plus an awk walk,
# not --ppid, which is GNU-only.
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
  # See nvim-drive.sh's cleanup(): a server-type DAP adapter is started
  # detached and does not go down with the pane.
  local pane_pid descendants
  pane_pid="$(tm display-message -p '#{pane_pid}' 2>/dev/null || true)"
  descendants=""
  if [[ -n "$pane_pid" ]]; then
    descendants="$(collect_descendants "$pane_pid" || true)"
  fi

  tm kill-server 2>/dev/null || true
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

# The agent backends' endpoint/key, which tmux does not inherit. Not
# forwarded: ANTHROPIC_API_KEY (nothing here drives that API).
for name in CUSTOM_BASE_URL CUSTOM_API_KEY HERMES_ALLOW_PRIVATE_URLS \
            HERMES_INFERENCE_PROVIDER HERMES_INFERENCE_MODEL; do
  if [[ -n "${!name:-}" ]]; then
    launch="$name=$(printf '%q' "${!name}") $launch"
  fi
done
launch="env $launch --listen $RPC"
[[ "$NO_SHADA" -eq 1 ]] && launch="$launch -i NONE"

tm -f /dev/null new-session -d -x "$COLS" -y "$ROWS" -c "$WORKDIR" "$launch"

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

capture "before"

# Polled over RPC rather than slept: a fixed pause was wrong in both
# directions (a local model answering in 151s against a 150s cap, and every
# faster answer sitting idle for the rest of it).
await_agent() {
  local deadline=$((SECONDS + ${SLOW_WAIT%.*} + 1))
  # A request that has not started yet also reports "not running" --
  # give it a moment before asking.
  sleep 2
  while (( SECONDS < deadline )); do
    local state
    state=$(nvim --server "$RPC" --remote-expr \
      'luaeval("(pcall(require, \"util.agent\") and require(\"util.agent\").is_running()) and 1 or 0")' 2>/dev/null)
    [[ "$state" == "0" ]] && break
    sleep 1
  done
  sleep 1.5
}

for batch in "$@"; do
  wait_for="$KEY_WAIT"
  slow=0
  if [[ "$batch" == slow:* ]]; then
    slow=1
    batch="${batch#slow:}"
  elif [[ "$batch" == wait:* ]]; then
    wait_for="${batch#wait:}"
    wait_for="${wait_for%%:*}"
    batch="${batch#wait:*:}"
  fi

  if [[ "$batch" == ex:* ]]; then
    nvim --server "$RPC" --remote-expr "execute('${batch#ex:}')" >/dev/null 2>&1 || true
    label=":${batch#ex:}"
  elif [[ "$batch" == keys:* ]]; then
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
