#!/usr/bin/env bash
# Record the agent tour: asking a coding agent without letting it write.
# Recorded against Hermes on a local model by default (free to re-record,
# and the weaker backend: no schema flag, answers come back as prose).
#
# AGENT_PAUSE caps the wait for an answer rather than padding it; only the
# keys that start a request use it (film.sh's `slow:` prefix).
#
# The endpoint and key come from the environment:
#   CUSTOM_BASE_URL  CUSTOM_API_KEY  HERMES_ALLOW_PRIVATE_URLS
#   HERMES_INFERENCE_PROVIDER  HERMES_INFERENCE_MODEL
#
# Usage:
#   record-agent-tour.sh -p PROJECT [-o OUTDIR] [FILM ...]
#
# Naming films records only those.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${TMPDIR:-/tmp}/nvim-agent-tour"
PROJECT=""
CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HOME/dotfiles/.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

BACKEND="hermes"

while getopts "o:p:c:n:b:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    p) PROJECT="$OPTARG" ;;
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    b) BACKEND="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ -n "$PROJECT" ]] || { echo "A project to record against is required: -p DIR" >&2; exit 2; }
[[ -d "$PROJECT" ]] || { echo "No such project: $PROJECT" >&2; exit 2; }

if [[ "$BACKEND" == "hermes" && -z "${CUSTOM_BASE_URL:-}" ]]; then
  echo "CUSTOM_BASE_URL is not set, so there is no model to ask." >&2
  echo "Source the environment that points Hermes at one first, or -b claude." >&2
  exit 2
fi

mkdir -p "$OUT"

# Switch the editor to the backend, the way anyone would: the key, the name,
# Enter. Every film does this fresh, since it is a session setting.
SWITCH=('Space' 'au' "$BACKEND" 'Enter')

OPEN=('Space' 'ff' 'core/utils/params' 'Enter')
AT_FUNCTION=('/' 'def int_from_request' 'Enter' '8j')

WANTED=("$@")

wanted() {
  [[ ${#WANTED[@]} -eq 0 ]] && return 0
  local name="$1" pick
  for pick in "${WANTED[@]}"; do
    [[ "$name" == *"$pick"* ]] && return 0
  done
  return 1
}

film() {
  local name="$1" title="$2" blurb="$3"
  shift 3

  wanted "$name" || return 0

  echo "  $name"
  "$HERE/film.sh" -c "$CONFIG_DIR" -n "$APPNAME" -d "$PROJECT" -t \
    -o "$OUT/$name" -T "$title" -w 90 \
    -p "${FILM_PAUSE:-2}" -P "${AGENT_PAUSE:-600}" "$@" >/dev/null
  printf '%s\n' "$blurb" > "$OUT/$name/blurb.txt"
}

echo "Recording into $OUT"
echo "Model: ${HERMES_INFERENCE_MODEL:-default} via ${HERMES_INFERENCE_PROVIDER:-default}"

film 00-settings "Which settings are in force, and from where" \
  "Every setting has four tiers, in the order the shell and tmux config already use: built in, then this machine's local.lua, then the project's .nvim.lua through vim.g, then whatever you set for this session. The panel names the value and the tier it came from, so \"which agent is answering\" is a question with an answer rather than a guess." \
  "${OPEN[@]}" 'Space' 'a?'

film 01-review "A review you have to type your way out of" \
  "Findings arrive as diagnostics, so ]d walks them and you fix them by typing, and a picker lists them because diagnostics answer \"what is wrong here\" and not \"what did it find\". The list truncates a finding to its column; Enter jumps to the line and the whole thing appears under it, wrapped. Nothing is applied, and there is no key here that edits a buffer." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ar' 'Enter'

film 02-scope "Widening what gets reviewed" \
  "The same shape as the grep filter: one key moves the scope out from this function to the file to only what you changed. It is a-s here rather than <leader>as, because the findings list owns the keyboard while it is open — <leader>as is the same thing from the buffer, once it is closed." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ar' 'slow:M-s'

film 03-hint-one "A hint that withholds the answer" \
  "The first rung names the class of problem and nothing else. No function, no library, no steps — the part where you work it out still has to happen." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ah'

film 04-hint-two "Pressing again for one rung more" \
  "Approach, then what to look up, then the signature. The ladder resets when you move somewhere else, so it measures how stuck you are here." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ah' 'Space' 'slow:ah'

film 05-lookup "Looking something up" \
  "The rung that makes you faster rather than the one that makes you think. Remembering an argument order was never the skill." \
  "${OPEN[@]}" "${SWITCH[@]}" 'Space' 'al' 'python bisect insort' 'slow:Enter'

# Recorded on a real ruff error (a genuine version mismatch in this checkout)
# rather than a clean function, so the panel demonstrates the explain-an-error
# half of this key, not the explain-this-code half.
film 06-explain "What this error means" \
  "With a diagnostic under the cursor it explains that instead, because that is almost always the question. <leader>cd puts the error on screen first, so what the agent was given is visible before what it answered. The diagnostic goes into the prompt with the surrounding lines — the agent runs with no tools and reads nothing itself, so everything it sees is assembled here." \
  'Space' 'ff' 'stats/models' 'Enter' '19G' "${SWITCH[@]}" 'Space' 'cd' 'Space' 'slow:ax'

film 07-switch "Choosing which agent answers" \
  "<leader>au lists the ones this machine can actually run — Codex is defined and absent from the list because it is not on PATH, since a CLI-driven agent has no API to fall back to. Claude Code, Hermes and Codex differ in how they go headless and how they are stopped from writing, and one that has not been shown to refuse a write is refused rather than warned about." \
  "${OPEN[@]}" 'Space' 'au'

film 08-cost "What it has cost" \
  "c-c closes the findings list first, because a picker owns the keyboard while it is open and <leader>a\$ typed into its filter box is two characters rather than a key. Then: real money on a hosted model, nothing on a local one, and either way visible rather than discovered later on a bill." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ar' 'C-c' 'Space' 'a$'

echo
echo "Films in $OUT"
ls -1 "$OUT"
