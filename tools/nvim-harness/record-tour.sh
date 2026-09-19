#!/usr/bin/env bash
# Record the tour: one film per feature, each a path rather than a destination.
#
# The contact sheet showed what every feature looks like once you are already
# there. This shows how you get there, which is the part someone learning the
# editor does not have. Each film is a handful of frames with the key that
# produced each one.
#
# Recorded against a real repository, not the fixture: ranking, LSP and the
# file tree all behave differently over five thousand files than over six, and
# a tour of a toy project teaches the toy.
#
# Usage:
#   record-tour.sh [-o OUTDIR] [-p PROJECT]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${TMPDIR:-/tmp}/nvim-tour"
PROJECT=""
CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HOME/dotfiles/.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

while getopts "o:p:c:n:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

[[ -n "$PROJECT" ]] || { echo "A project to record against is required: -p DIR" >&2; exit 2; }
[[ -d "$PROJECT" ]] || { echo "No such project: $PROJECT" >&2; exit 2; }

mkdir -p "$OUT"

# One film. The name orders it in the tour; the title and blurb caption it.
#
# Scene-setting uses real keys, not `ex:` commands. A tour whose frames show
# `:edit lua/util/recall.lua` teaches an Ex command nobody types, and the
# harness's convenience has no business being in the teaching material. `ex:`
# is still there for the rare case a key cannot express the setup.
film() {
  local name="$1" title="$2" blurb="$3"
  shift 3

  echo "  $name"
  "$HERE/film.sh" -c "$CONFIG_DIR" -n "$APPNAME" -d "$PROJECT" -t \
    -o "$OUT/$name" -T "$title" -w 90 -p "${FILM_PAUSE:-1.6}" "$@" >/dev/null
  printf '%s\n' "$blurb" > "$OUT/$name/blurb.txt"
}

# A film that needs a different project. The language server film is the only
# one so far: label-studio is Python, ruff is the only server it provides, and
# ruff answers neither hover nor definition. Demonstrating K there would
# demonstrate nothing.
film_in() {
  local project="$1" name="$2" title="$3" blurb="$4"
  shift 4

  echo "  $name  (in $(basename "$project"))"
  "$HERE/film.sh" -c "$CONFIG_DIR" -n "$APPNAME" -d "$project" -t \
    -o "$OUT/$name" -T "$title" -w 90 -p "${FILM_PAUSE:-1.6}" "$@" >/dev/null
  printf '%s\n' "$blurb" > "$OUT/$name/blurb.txt"
}

echo "Recording into $OUT"

film 01-grep "One grep key, many scopes" \
  "The filter lives inside the search rather than on a key of its own. a-s widens it without leaving the picker." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' 'sg' 'get_queryset' 'M-s'

film 02-files "Finding a file" \
  "The other half of search. Type any part of the path; the ranking prefers what you open often." \
  'Space' 'ff' 'serializers'

film 03-buffers "Back to a buffer" \
  "Leader leader, where it was before. LazyVim puts Find Files here; this keeps buffers." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' 'ff' 'tasks/models' 'Enter' 'Space' 'Space'

film 04-filters "Narrowing a search" \
  "a-e limits to file extensions the project actually contains, a-G to a path, a-c ignores case. None of them are on a key you would guess, which is why a-/ lists them." \
  'Space' 'sg' 'queryset' 'M-e'

film 05-capabilities "What can this editor do" \
  "Ask in words rather than remembering a key. Tab moves between everything, this configuration's own features, every mapping, and every command." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' '?' 'tab' 'Tab' 'Tab'

film 06-commands "Finding a command you cannot name" \
  "tabclose is not guessable and :help only answers once you have the word. Type what it does instead — and the key that runs it is listed beside it." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' '?' 'Tab' 'Tab' 'Tab' 'close'

film 07-tree "The file tree" \
  "A tree when a list is the wrong shape. i filters it in place." \
  'Space' 'e'

film 08-diff "Diffing the working tree" \
  "Side by side, and the same key closes it." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' 'gd'

film 09-harpoon "Pinning the files you keep returning to" \
  "Four or five files carry most of a change. Pin them and they get their own short list." \
  'Space' 'ff' 'tasks/api' 'Enter' 'Space' 'ha' 'Space' 'hh'

film 10-yank "Everything you yanked" \
  "Not just the last thing. Enter loads the register; p pastes it where you meant." \
  'Space' 'ff' 'tasks/api' 'Enter' 'yy' 'jj' 'yy' 'Space' 'sy'

# Slower than the rest: lua_ls indexes the workspace before it can say what
# vim.fs.find is, and asked too early it answers "unknown" — which looks like
# a broken hover rather than an impatient one.
FILM_PAUSE=6 \
film_in "${LUA_PROJECT:-$HOME/dotfiles/.worktrees/nvim-lazyvim}" \
  11-lsp "Asking the language server" \
  "K for what this is. Recorded in Lua rather than Python on purpose: label-studio provides ruff, and ruff answers neither hover nor definition. lua_ls is the one server this configuration installs itself, so it is the one that always has an answer. The symbol is picked to have one: vim.fs.find, the earlier choice, is assembled at runtime by vim._defer_require, so lua_ls can see the name and not the type and honestly answers \"unknown\" — which reads as a broken popup rather than an answered question." \
  'Space' 'ff' 'util/settings' 'Enter' '/' 'fs_stat' 'Enter' 'K'

film 12-flash "Jumping by label" \
  "s labels every match on screen; type a label to land there. f and t are the same idea along one line. These six keys carry no description of their own, which is why the editor writes one for them." \
  'Space' 'ff' 'tasks/api' 'Enter' 's' 'se'

film 13-health "What this project provides" \
  "Only lua_ls installs itself. Everything else is used if the project or PATH provides it, and named if it does not." \
  ':checkhealth dotfiles' 'Enter'

# Getting into a popup, which is the half nobody documents.
FILM_PAUSE=5 \
film_in "${LUA_PROJECT:-$HOME/dotfiles/.worktrees/nvim-lazyvim}" \
  14-popup "Getting inside a popup" \
  "K opens the hover unfocused. K again moves the cursor inside it — watch the status line stop naming the file — so c-d scrolls the popup rather than the buffer. c-c leaves, putting the cursor back where it was. No mouse either way, and the same twice-to-enter works for the diagnostic under the cursor." \
  'Space' 'ff' 'util/settings' 'Enter' '/' 'fs_stat' 'Enter' 'K' 'K' 'C-d' 'C-c'

FILM_PAUSE=4 \
film_in "${LUA_PROJECT:-$HOME/dotfiles/.worktrees/nvim-lazyvim}" \
  15-dismiss "One key closes anything" \
  "Every overlay used to close differently: q here, Esc there, the opening key somewhere else. c-c now returns you to normal from all of them — picker, popup, plugin window, split. Lazy is the pointed one: c-c was its own key for aborting an install, so abort moved to c-x and c-c means here what it means everywhere. In a terminal c-c still interrupts the program, and a-q closes that. <leader>xx is not shown here on purpose: Trouble opens no window when the file has no diagnostics, so the frame would show a key that looks like it did nothing." \
  'Space' 'ff' 'util/settings' 'Enter' 'Space' 'ff' 'C-c' 'Space' 'l' 'C-c'

echo
echo "Films in $OUT"
ls -1 "$OUT"
