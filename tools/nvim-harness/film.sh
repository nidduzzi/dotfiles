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
#   -t        trust the project's .nvim.lua
#   -T TEXT   title for this film
#
# A batch written as `ex:<command>` is sent over RPC as an Ex command, which is
# the reliable way to set a scene before the part being demonstrated.
#
# A batch written as `keys:a b c` sends those keys together with no pause, for
# a sequence that has to arrive as one mapping rather than as separate presses.
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
TRUST=0
TITLE="Neovim"

while getopts "c:n:d:o:W:H:w:p:T:t" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    W) COLS="$OPTARG" ;;
    H) ROWS="$OPTARG" ;;
    w) BOOT_WAIT="$OPTARG" ;;
    p) KEY_WAIT="$OPTARG" ;;
    T) TITLE="$OPTARG" ;;
    t) TRUST=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }
command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

: "${WORKDIR:=$PWD}"
SOCKET="nvim-film-$$"
RPC="${TMPDIR:-/tmp}/nvim-film-$$.sock"

tm() { tmux -L "$SOCKET" "$@"; }
cleanup() {
  tm kill-server 2>/dev/null || true
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
  env ${APPNAME:+NVIM_APPNAME="$APPNAME"} ${CONFIG_DIR:+XDG_CONFIG_HOME="$CONFIG_DIR"} \
    nvim --headless -u NONE \
    +"lua vim.secure.trust({ action = 'allow', path = '$WORKDIR/.nvim.lua' })" \
    +qa 2>/dev/null || true
fi

launch="nvim"
[[ -n "$APPNAME" ]] && launch="NVIM_APPNAME=$APPNAME $launch"
[[ -n "$CONFIG_DIR" ]] && launch="XDG_CONFIG_HOME=$CONFIG_DIR $launch"

# Carry through what the agent backends read for their endpoint and key. The
# editor is started by tmux, which does not inherit this shell's environment,
# so without this Hermes falls back to whatever its config names and answers
# `HTTP 401: Unauthorized` — which the review then reported as "Nothing found",
# because a failed request and a clean function looked the same.
for name in CUSTOM_BASE_URL CUSTOM_API_KEY HERMES_ALLOW_PRIVATE_URLS \
            HERMES_INFERENCE_PROVIDER HERMES_INFERENCE_MODEL ANTHROPIC_API_KEY; do
  if [[ -n "${!name:-}" ]]; then
    launch="$name=$(printf '%q' "${!name}") $launch"
  fi
done
launch="env $launch --listen $RPC"

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

for batch in "$@"; do
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
    tm send-keys "${_keys[@]}"
    label="${batch#keys:}"
  else
    tm send-keys "$batch"
    label="$batch"
  fi
  sleep "$KEY_WAIT"
  capture "$label"
done

printf '%s\n' "$TITLE" > "$OUT/title.txt"
echo "$frame frames in $OUT"
echo "Build the page with:"
echo "  $HERE/build-film.py --dir $OUT --out $OUT/index.html"
