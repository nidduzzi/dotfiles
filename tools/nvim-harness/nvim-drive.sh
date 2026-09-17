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
# Each positional argument is one batch of keys in tmux send-keys syntax, sent
# in order with a pause between batches. Example:
#
#   nvim-drive.sh -c ~/dotfiles/neovim/.config -e -o out.ansi 'Space' 'sg' 'fn'
set -Eeuo pipefail

CONFIG_DIR=""
APPNAME=""
WORKDIR=""
SOCKET="nvim-harness"
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
tm -f /dev/null new-session -d -x "$COLS" -y "$ROWS" -c "$WORKDIR" "$launch"

sleep "$BOOT_WAIT"

for batch in "$@"; do
  tm send-keys "$batch"
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
