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
#   -a FILE   Open FILE as a command-line argument, which is a different
#             startup path from opening it once the editor is running.
#   -o FILE   Write the captured pane to FILE as well as stdout.
#   -e        Capture with ANSI escape sequences (needed for screenshots).
#   -k        Keep the tmux server alive after capturing, for manual poking.
#   A batch written as `wait:<seconds>:<batch>` waits that long after sending,
#   for anything the editor does not announce the end of.
#
#   -t        Trust the working directory's .nvim.lua before starting, so the
#             exrc prompt does not swallow the keys meant for the editor.
#   -F        Trust a .nvim.lua outside this harness. It is Lua the project
#             wrote, and trusting it runs it.
#   -I        Start with -i NONE, so nothing is read from or written to shada.
#             A run that remembers where the cursor was last time is a run
#             whose result depends on the run before it.
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

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

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


cleanup() {
  [[ "$KEEP" -eq 1 ]] && return 0
  tm kill-server 2>/dev/null || true
  # kill-server leaves the socket behind, and a run that leaves one file per
  # invocation in /tmp is a run that left 995 of them behind this session.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
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
# The project trust store, which is a separate decision from the .nvim.lua
# prompt: it is what lets a project's own programs run, and since gating git
# it is also what lets gitsigns attach and the diff and worktree keys work.
# -t means "this is the harness's own fixture", so it grants both.
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
  # .nvim.lua is Lua the repository wrote, and trusting it runs it. The prompt
  # Neovim shows is the only thing standing between a clone and that, so this
  # answers it only for the fixture, which this repository generates.
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
[[ "$NO_SHADA" -eq 1 ]] && launch="$launch -i NONE"

# A file on the command line is a different startup from opening one later:
# LazyVim loads its autocmds eagerly when argc is not zero, and lazily
# otherwise, so a handler can exist on one path and not the other. Three
# versions of the trust prompt were wrong about exactly that.
[[ -n "$OPEN_FILE" ]] && launch="$launch $(printf '%q' "$OPEN_FILE")"

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
  wait_for="$KEY_WAIT"
  if [[ "$batch" == wait:* ]]; then
    wait_for="${batch#wait:}"
    wait_for="${wait_for%%:*}"
    batch="${batch#wait:*:}"
  fi

  if [[ "$batch" == ex:* ]]; then
    # An Ex command, delivered over RPC instead of as keystrokes. Several `:`
    # commands sent as separate key batches concatenate into one command line
    # when a dashboard has focus, which fails with E5107 and leaves the editor
    # showing something other than what was asked for.
    nvim --server "$RPC" --remote-send "<C-\><C-N>" 2>/dev/null || true
    nvim --server "$RPC" --remote-expr "execute('${batch#ex:}')" >/dev/null 2>&1 || true
  elif [[ "$batch" == keys:* ]]; then
    # Several keys together, with no pause between them. A leader sequence sent
    # as separate batches has seconds between its keys, and a mapping split
    # that far apart is not the mapping — `Space` then `?` a second later is a
    # space and a reverse search, not <leader>?.
    # Split on spaces with globbing off. Unquoted expansion looked simpler and
    # was wrong: `?` and `*` are key names to tmux and glob characters to the
    # shell, so `keys:Space ?` could expand to a filename before tmux saw it.
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

# Capture when the screen has stopped moving.
#
# A float can exist before it has been drawn: a probe over RPC said the picker
# was open while the captured pane showed the file underneath it, three runs
# out of three. Waiting a fixed extra second only moves the race. Two
# identical captures in a row mean the editor has finished redrawing, and the
# loop gives up after a second and a half so a genuinely animated screen --- a
# spinner, a progress message --- still produces a frame.
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
