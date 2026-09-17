#!/usr/bin/env bash
# Drive an isolated Neovim instance inside a dedicated tmux server and capture
# what it renders. The tmux server uses its own socket name, so a crash or a
# stray key never touches the user's real sessions.
#
# Usage:
#   nvim-drive.sh [options] [keys ...]
#
# Options:
#   -c DIR    Neovim config directory to run against (sets XDG_CONFIG_HOME).
#   -n NAME   NVIM_APPNAME, so several configs can coexist under one config dir.
#   -d DIR    Working directory Neovim opens in. Default: the current directory.
#   -s NAME   tmux socket name. Default: nvim-harness.
#   -W COLS   Pane width.  Default: 120.
#   -H ROWS   Pane height. Default: 40.
#   -w SECS   Seconds to wait after startup before sending keys. Default: 3.
#   -p SECS   Seconds to wait after each key batch. Default: 1.
#   -o FILE   Write the captured pane to FILE as well as stdout.
#   -e        Capture with ANSI escape sequences (needed for screenshots).
#   -k        Keep the tmux server alive after capturing, for manual poking.
#   -t        Trust the working directory's .nvim.lua before starting, so the
#             exrc prompt does not swallow the keys meant for the editor.
#
# -w is now a timeout rather than a delay: the editor is asked whether it is
# ready, over its own RPC socket, and the keys go the moment it says yes.
#
# A batch written as `ex:<command>` is delivered over RPC as an Ex command
# rather than as keystrokes, which is the reliable way to do anything that
# would otherwise depend on which window happens to have focus.
#
# Each positional argument is one batch of keys in tmux send-keys syntax, sent
# in order with a pause between batches. Example:
#
#   nvim-drive.sh -c ~/dotfiles/neovim/.config -e -o out.ansi 'Space' 'sg' 'fn'
set -Eeuo pipefail

CONFIG_DIR=""
APPNAME=""
WORKDIR=""
# Unique per run: two runs sharing a socket kill each other's server, and the
# dump that results looks like a regression rather than a collision. That cost
# three "unexpected: 54" results that were not real.
SOCKET="nvim-harness-$$"
COLS=120
ROWS=40
BOOT_WAIT=3
KEY_WAIT=1
OUTFILE=""
CAPTURE_ANSI=0
KEEP=0
TRUST=0

while getopts "c:n:d:s:W:H:w:p:o:ekt" opt; do
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
    t) TRUST=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

tm() { tmux -L "$SOCKET" "$@"; }

cleanup() {
  [[ "$KEEP" -eq 1 ]] && return 0
  tm kill-server 2>/dev/null || true
  [[ -n "${RPC:-}" ]] && rm -f "$RPC"
}
trap cleanup EXIT

# A fresh server every run, so state never leaks between captures.
tm kill-server 2>/dev/null || true

# Each run kills Neovim rather than quitting it, which leaves a swap file
# behind. The next run that opens the same file would then stop at a recovery
# prompt and capture that instead of the feature under test.
if [[ -n "$APPNAME" ]]; then
  swap_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/swap"
  [[ -d "$swap_dir" ]] && rm -f "$swap_dir"/*
fi

: "${WORKDIR:=$PWD}"

# Neovim asks once before running a project's .nvim.lua. That prompt appears
# before the editor is ready, so any keys this script sends would answer the
# prompt instead of reaching the editor. Record the trust decision up front.
if [[ "$TRUST" -eq 1 && -f "$WORKDIR/.nvim.lua" ]]; then
  env ${APPNAME:+NVIM_APPNAME="$APPNAME"} ${CONFIG_DIR:+XDG_CONFIG_HOME="$CONFIG_DIR"} \
    nvim --headless -u NONE \
    +"lua vim.secure.trust({ action = 'allow', path = '$WORKDIR/.nvim.lua' })" \
    +qa 2>/dev/null || echo "Could not pre-trust $WORKDIR/.nvim.lua" >&2
fi

launch="nvim"
[[ -n "$APPNAME" ]] && launch="NVIM_APPNAME=$APPNAME $launch"
[[ -n "$CONFIG_DIR" ]] && launch="XDG_CONFIG_HOME=$CONFIG_DIR $launch"
launch="env $launch"

# -f /dev/null keeps the harness server away from the user's tmux config, whose
# passthrough and plugin settings are themselves under test elsewhere.
# An RPC socket, so readiness can be asked rather than guessed at. This is the
# whole point of the rewrite: `sleep 50` is not a readiness check, and every
# time it was wrong the keys went somewhere else — into the dashboard, which
# has its own single-key bindings, or into normal mode, where `main` is a
# mark, an append and two motions rather than a search query. That produced
# four wrong diagnoses before anyone suspected the harness.
RPC="${TMPDIR:-/tmp}/nvim-drive-$$.sock"
rm -f "$RPC"
launch="$launch --listen $RPC"

tm -f /dev/null new-session -d -x "$COLS" -y "$ROWS" -c "$WORKDIR" "$launch"

# Ask the editor whether it is ready, up to BOOT_WAIT seconds.
ready=0
deadline=$((SECONDS + BOOT_WAIT))
while (( SECONDS < deadline )); do
  if [[ -S "$RPC" ]] && nvim --server "$RPC" --remote-expr 'v:vim_did_enter' 2>/dev/null | grep -q '^1$'; then
    ready=1
    break
  fi
  sleep 0.2
done

if [[ "$ready" -ne 1 ]]; then
  echo "Neovim did not become ready within ${BOOT_WAIT}s" >&2
  exit 1
fi

# vim_did_enter fires before lazy.nvim has finished, and a key sent in that
# window reaches a half-built editor. Wait for the plugin manager to settle
# too, and give up quietly if this configuration does not use lazy.
lazy_deadline=$((SECONDS + BOOT_WAIT))
while (( SECONDS < lazy_deadline )); do
  state=$(nvim --server "$RPC" --remote-expr \
    'luaeval("(package.loaded[\"lazy.core.loader\"] ~= nil and vim.g.lazy_did_setup == true) and 1 or 0")' 2>/dev/null)
  [[ "$state" == "1" ]] && break
  sleep 0.2
done

for batch in "$@"; do
  if [[ "$batch" == ex:* ]]; then
    # An Ex command, delivered over RPC instead of as keystrokes. Several `:`
    # commands sent as separate key batches concatenate into one command line
    # when a dashboard has focus, which fails with E5107 and leaves the editor
    # showing something other than what was asked for.
    nvim --server "$RPC" --remote-send "<C-\><C-N>" 2>/dev/null || true
    nvim --server "$RPC" --remote-expr "execute('${batch#ex:}')" >/dev/null 2>&1 || true
  else
    tm send-keys "$batch"
  fi
  sleep "$KEY_WAIT"
done

if [[ "$CAPTURE_ANSI" -eq 1 ]]; then
  capture=$(tm capture-pane -p -e -N -S 0 -E "$((ROWS - 1))")
else
  capture=$(tm capture-pane -p -N -S 0 -E "$((ROWS - 1))")
fi

printf '%s\n' "$capture"
[[ -n "$OUTFILE" ]] && printf '%s\n' "$capture" >"$OUTFILE"

if [[ "$KEEP" -eq 1 ]]; then
  echo "tmux server kept alive. Attach with: tmux -L $SOCKET attach" >&2
  echo "Kill it with: tmux -L $SOCKET kill-server" >&2
fi
