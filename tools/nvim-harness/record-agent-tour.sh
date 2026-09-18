#!/usr/bin/env bash
# Record the agent tour: asking a coding agent without letting it write.
#
# Recorded against Hermes pointed at a local model rather than Claude, for two
# reasons. It costs nothing, so the tour can be re-recorded as often as it
# needs to be. And it is the weaker of the two backends — no schema flag, so
# the findings come back as prose to be parsed, and a minute per answer rather
# than a couple of seconds — so a tour that holds up here holds up on the other
# one.
#
# AGENT_PAUSE is a cap rather than a pause: film.sh waits for the answer and
# gives up after it. It is generous because a whole-file review on a local 35B
# ran past 150 seconds, and a cap that expires captures the spinner — which
# reads as a feature that does nothing rather than one that is still thinking.
#
# The long wait applies only to the keys that start a request. A 35B on a
# local card answers a review in about a minute, and a shorter pause captures
# the spinner rather than the answer — but a pause that long on every key made
# a nine-film tour spend two hours to record the eight frames that needed it.
# film.sh's `slow:` prefix marks those. Claude returns in two or three seconds
# and needs neither.
#
# The endpoint and key come from the environment, never from this file:
#   CUSTOM_BASE_URL  CUSTOM_API_KEY  HERMES_ALLOW_PRIVATE_URLS
#   HERMES_INFERENCE_PROVIDER  HERMES_INFERENCE_MODEL
#
# Usage:
#   record-agent-tour.sh -p PROJECT [-o OUTDIR] [FILM ...]
#
# Naming films records only those, which is how a single one gets re-recorded
# after a fix without paying for the other eight. It is also how the tour gets
# recorded at all on a busy machine: each film is minutes long, and a run that
# is killed halfway leaves nothing.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${TMPDIR:-/tmp}/nvim-agent-tour"
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
shift $((OPTIND - 1))

[[ -n "$PROJECT" ]] || { echo "A project to record against is required: -p DIR" >&2; exit 2; }
[[ -d "$PROJECT" ]] || { echo "No such project: $PROJECT" >&2; exit 2; }

if [[ -z "${CUSTOM_BASE_URL:-}" ]]; then
  echo "CUSTOM_BASE_URL is not set, so there is no model to ask." >&2
  echo "Source the environment that points Hermes at one first." >&2
  exit 2
fi

mkdir -p "$OUT"

# Switch the editor to Hermes for the whole tour, the way anyone would: the
# key that opens the agent picker, the name typed into it, Enter. An earlier
# version set the Lua field directly, which recorded a line nobody types and
# taught the harness's shortcut rather than the editor's key.
#
# Every film starts a fresh editor, so every film has to do it. That is not
# padding: the switch is a session setting, and a tour that hid it would leave
# "which agent is answering this" unanswered in every frame.
SWITCH=('Space' 'au' 'hermes' 'Enter')

# Scene setting, in keys. <leader>ff finds the file, / finds the function, 8j
# puts the cursor inside it.
OPEN=('Space' 'ff' 'core/utils/params' 'Enter')
AT_FUNCTION=('/' 'def int_from_request' 'Enter' '8j')

# Names given on the command line, if any. Empty means all of them.
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

film 06-explain "What this error means" \
  "With a diagnostic under the cursor it explains that instead, because that is almost always the question." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ax'

film 07-switch "Choosing which agent answers" \
  "<leader>au lists the ones this machine can actually run — Codex is defined and absent from the list because it is not on PATH, since a CLI-driven agent has no API to fall back to. Claude Code, Hermes and Codex differ in how they go headless and how they are stopped from writing, and one that has not been shown to refuse a write is refused rather than warned about." \
  "${OPEN[@]}" 'Space' 'au'

film 08-cost "What it has cost" \
  "c-c closes the findings list first, because a picker owns the keyboard while it is open and <leader>a\$ typed into its filter box is two characters rather than a key. Then: real money on a hosted model, nothing on a local one, and either way visible rather than discovered later on a bill." \
  "${OPEN[@]}" "${AT_FUNCTION[@]}" "${SWITCH[@]}" 'Space' 'slow:ar' 'C-c' 'Space' 'a$'

echo
echo "Films in $OUT"
ls -1 "$OUT"
