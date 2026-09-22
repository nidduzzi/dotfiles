#!/usr/bin/env bash
# Drive an isolated Neovim instance inside a dedicated tmux server and capture
# what it renders.
#
# Usage:
#   nvim-drive.sh [options] [keys ...]
#
# Options:
#   -c DIR    Neovim config directory (sets XDG_CONFIG_HOME).
#   -n NAME   NVIM_APPNAME.
#   -d DIR    Working directory Neovim opens in. Default: the current directory.
#   -s NAME   tmux socket name. Default: nvim-harness.
#   -W COLS   Pane width.  Default: 120.
#   -H ROWS   Pane height. Default: 40.
#   -w SECS   Seconds to wait for readiness before sending keys. Default: 3.
#   -p SECS   Seconds to wait after each key batch. Default: 1.
#   -a FILE   Open FILE as a command-line argument (a different startup path
#             from opening it once running).
#   -o FILE   Write the captured pane to FILE as well as stdout.
#   -e        Capture with ANSI escape sequences (needed for screenshots).
#   -k        Keep the tmux server alive after capturing.
#   -t        Trust the working directory's .nvim.lua before starting.
#   -F        Trust a .nvim.lua outside this harness (runs Lua the project wrote).
#   -I        Start with -i NONE (no shada read/write).
#
#   A batch `wait:<seconds>:<batch>` waits that long after sending.
#   A batch `ex:<command>` is delivered over RPC as an Ex command.
#   A batch `keys:a b c` sends those keys together with no pause between them.
#
# -w is a readiness timeout, not a delay: the editor is asked over its own RPC
# socket, and keys go the moment it says yes.
set -Eeuo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_DIR=""
APPNAME=""
WORKDIR=""
SOCKET="nvim-harness-$$"
COLS=120
ROWS=40
BOOT_WAIT=3
KEY_WAIT=1
OUTFILE=""
CAPTURE_ANSI=0
KEEP=0
OPEN_FILE=""
TRUST=0
FORCE_TRUST=0
NO_SHADA=0

while getopts "a:c:n:d:s:W:H:w:p:o:ektIF" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    s) SOCKET="$OPTARG" ;;
    W) COLS="$OPTARG" ;;
    H) ROWS="$OPTARG" ;;
    w) BOOT_WAIT="$OPTARG" ;;
    p) KEY_WAIT="$OPTARG" ;;
    o) OUTFILE="$OPTARG" ;;
    e) CAPTURE_ANSI=1 ;;
    k) KEEP=1 ;;
    a) OPEN_FILE="$OPTARG" ;;
    t) TRUST=1 ;;
    I) NO_SHADA=1 ;;
    F) FORCE_TRUST=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# tmux runs the editor inside WORKDIR, so a relative CONFIG_DIR resolves
# against the project instead.
[[ -n "$CONFIG_DIR" ]] && CONFIG_DIR="$(cd "$CONFIG_DIR" && pwd)"
[[ -n "$WORKDIR" ]] && WORKDIR="$(cd "$WORKDIR" && pwd)"

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

tm() { tmux -L "$SOCKET" "$@"; }

# tmux resolves an argument to a key name (DC, IC, ...) before treating it as
# text, case-insensitively -- `tmux send-keys dc` emits ^[[3~, not "dc".
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

# Every process the pane's shell spawned, root first. One ps call plus an awk
# walk, not --ppid, which is GNU-only and would not run on debuggers-macos.
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
  [[ "$KEEP" -eq 1 ]] && return 0

  # A server-type DAP adapter (julia, js-debug's headless Chrome) is started
  # detached, in its own process group, so it survives the pane dying --
  # snapshot descendants before kill-server, since afterwards they are
  # reparented to init with nothing tying them back to this run.
  local pane_pid descendants
  pane_pid="$(tm display-message -p '#{pane_pid}' 2>/dev/null || true)"
  descendants=""
  if [[ -n "$pane_pid" ]]; then
    descendants="$(collect_descendants "$pane_pid" || true)"
  fi

  tm kill-server 2>/dev/null || true
  # Belt and braces: kill-server does not reliably take Neovim itself down.
  # $RPC is unique to this process, so this can only match our own Neovim.
  pkill -f -- "--listen ${RPC:-nvim-drive-not-set}" 2>/dev/null || true

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

  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  [[ -n "${RPC:-}" ]] && rm -f "$RPC"
}
trap cleanup EXIT

tm kill-server 2>/dev/null || true

# A killed Neovim leaves a swap file, and the next run on the same file stops
# at a recovery prompt instead of showing the feature under test.
if [[ -n "$APPNAME" ]]; then
  swap_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/swap"
  [[ -d "$swap_dir" ]] && rm -f "$swap_dir"/*
fi

: "${WORKDIR:=$PWD}"

# The .nvim.lua trust prompt appears before the editor is ready, so it has to
# be answered up front rather than by the keys this script sends. -t grants
# both the exrc trust and the project trust store (gitsigns, diff, worktree).
if [[ "$TRUST" -eq 1 ]]; then
  workdir_real="$(cd "$WORKDIR" && pwd)"
  if [[ "$workdir_real" == "$HARNESS"/* || "$FORCE_TRUST" -eq 1 ]]; then
    env ${APPNAME:+NVIM_APPNAME="$APPNAME"} ${CONFIG_DIR:+XDG_CONFIG_HOME="$CONFIG_DIR"} \
      nvim --headless -u NONE \
      --cmd "set runtimepath+=${CONFIG_DIR:-$HOME/.config}/${APPNAME:-nvim}" \
      +"lua require('util.trust').allow('$WORKDIR')" \
      +qa 2>/dev/null || echo "Could not trust $WORKDIR" >&2
  fi
fi

if [[ "$TRUST" -eq 1 && -f "$WORKDIR/.nvim.lua" ]]; then
  workdir_real="$(cd "$WORKDIR" && pwd)"
  if [[ "$workdir_real" == "$HARNESS"/* || "$FORCE_TRUST" -eq 1 ]]; then
    env ${APPNAME:+NVIM_APPNAME="$APPNAME"} ${CONFIG_DIR:+XDG_CONFIG_HOME="$CONFIG_DIR"} \
      nvim --headless -u NONE \
      +"lua vim.secure.trust({ action = 'allow', path = '$WORKDIR/.nvim.lua' })" \
      +qa 2>/dev/null || echo "Could not pre-trust $WORKDIR/.nvim.lua" >&2
  else
    echo "Refusing to trust $workdir_real/.nvim.lua without -F." >&2
    echo "It is Lua from that project, and trusting it runs it." >&2
    exit 3
  fi
fi

launch="nvim"
[[ -n "$APPNAME" ]] && launch="NVIM_APPNAME=$APPNAME $launch"
[[ -n "$CONFIG_DIR" ]] && launch="XDG_CONFIG_HOME=$CONFIG_DIR $launch"

# The agent backends' endpoint/key, which tmux does not inherit from this
# shell. ANTHROPIC_API_KEY is deliberately not forwarded: nothing here drives
# that API, and a key in the environment is one any program the editor starts
# can read.
for name in CUSTOM_BASE_URL CUSTOM_API_KEY HERMES_ALLOW_PRIVATE_URLS \
            HERMES_INFERENCE_PROVIDER HERMES_INFERENCE_MODEL; do
  if [[ -n "${!name:-}" ]]; then
    launch="$name=$(printf '%q' "${!name}") $launch"
  fi
done
launch="env $launch"

RPC="${TMPDIR:-/tmp}/nvim-drive-$$.sock"
rm -f "$RPC"
launch="$launch --listen $RPC"
[[ "$NO_SHADA" -eq 1 ]] && launch="$launch -i NONE"

# argc affects when LazyVim wires its autocmds up (eager vs lazy), so opening
# a file on the command line is a different startup path from opening it later.
[[ -n "$OPEN_FILE" ]] && launch="$launch $(printf '%q' "$OPEN_FILE")"

tm -f /dev/null new-session -d -x "$COLS" -y "$ROWS" -c "$WORKDIR" "$launch"

# Two readiness signals: vim.g.dotfiles_ready (this config, once keys are
# wired) and plain v:vim_did_enter (a stock LazyVim baseline, which never
# sets the former) -- the second is accepted after half the timeout.
ready=0
deadline=$((SECONDS + BOOT_WAIT))
patient_until=$((SECONDS + BOOT_WAIT / 2))
while (( SECONDS < deadline )); do
  if [[ -S "$RPC" ]]; then
    if nvim --server "$RPC" --remote-expr 'v:vim_did_enter == 1 && get(g:, "dotfiles_ready", v:false) == v:true' 2>/dev/null | grep -q '^1$'; then
      ready=1
      break
    fi
    if (( SECONDS >= patient_until )) &&
      nvim --server "$RPC" --remote-expr 'v:vim_did_enter' 2>/dev/null | grep -q '^1$'; then
      ready=1
      break
    fi
  fi
  sleep 0.2
done

if [[ "$ready" -ne 1 ]]; then
  echo "Neovim did not become ready within ${BOOT_WAIT}s" >&2
  exit 1
fi

# vim_did_enter fires before lazy.nvim finishes; wait for it too, and give up
# quietly if this configuration does not use lazy.
lazy_deadline=$((SECONDS + BOOT_WAIT))
while (( SECONDS < lazy_deadline )); do
  state=$(nvim --server "$RPC" --remote-expr \
    'luaeval("(package.loaded[\"lazy.core.loader\"] ~= nil and vim.g.lazy_did_setup == true) and 1 or 0")' 2>/dev/null)
  [[ "$state" == "1" ]] && break
  sleep 0.2
done

for batch in "$@"; do
  wait_for="$KEY_WAIT"
  if [[ "$batch" == wait:* ]]; then
    wait_for="${batch#wait:}"
    wait_for="${wait_for%%:*}"
    batch="${batch#wait:*:}"
  fi

  if [[ "$batch" == ex:* ]]; then
    # Delivered over RPC, not as keystrokes: several `:` batches sent as
    # separate keystrokes can concatenate into one command line. The command
    # is embedded in a Vimscript string; a literal quote is escaped by
    # doubling it.
    quoted="${batch#ex:}"
    quoted="${quoted//\'/\'\'}"
    nvim --server "$RPC" --remote-send "<C-\><C-N>" 2>/dev/null || true
    if ! nvim --server "$RPC" --remote-expr "execute('$quoted')" >/dev/null 2>&1; then
      # Fallback to typed keys: the RPC call fails silently on some
      # platforms (macOS), and every Ex command sent that way was dropped.
      tm send-keys -l ":${batch#ex:}"
      tm send-keys Enter
    fi
  elif [[ "$batch" == keys:* ]]; then
    # Several keys with no pause between them, for a mapping that only fires
    # when its keys arrive together. `set -f`: `?`/`*` are glob characters to
    # the shell and key names to tmux.
    set -f
    # shellcheck disable=SC2086
    read -r -a _keys <<< "${batch#keys:}"
    set +f
    send_batch "${_keys[@]}"
  else
    send_batch "$batch"
  fi
  sleep "$wait_for"
done

# Capture once the screen stops moving: a float can exist before it is drawn,
# so two identical captures in a row are the signal, not a fixed extra sleep.
grab() {
  if [[ "$CAPTURE_ANSI" -eq 1 ]]; then
    tm capture-pane -p -e -N -S 0 -E "$((ROWS - 1))"
  else
    tm capture-pane -p -N -S 0 -E "$((ROWS - 1))"
  fi
}

capture=$(grab)
for _ in 1 2 3 4 5 6; do
  sleep 0.25
  settled=$(grab)
  [[ "$settled" == "$capture" ]] && break
  capture=$settled
done

printf '%s\n' "$capture"
[[ -n "$OUTFILE" ]] && printf '%s\n' "$capture" >"$OUTFILE"

if [[ "$KEEP" -eq 1 ]]; then
  echo "tmux server kept alive. Attach with: tmux -L $SOCKET attach" >&2
  echo "Kill it with: tmux -L $SOCKET kill-server" >&2
fi
