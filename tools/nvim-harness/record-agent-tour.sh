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
# The pause is long because the model is: a 35B on a local card answers a
# review in about a minute, and a shorter pause captures the spinner rather
# than the answer. Claude returns in two or three seconds and does not need it.
#
# The endpoint and key come from the environment, never from this file:
#   CUSTOM_BASE_URL  CUSTOM_API_KEY  HERMES_ALLOW_PRIVATE_URLS
#   HERMES_INFERENCE_PROVIDER  HERMES_INFERENCE_MODEL
#
# Usage:
#   record-agent-tour.sh -p PROJECT [-o OUTDIR]
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

[[ -n "$PROJECT" ]] || { echo "A project to record against is required: -p DIR" >&2; exit 2; }
[[ -d "$PROJECT" ]] || { echo "No such project: $PROJECT" >&2; exit 2; }

if [[ -z "${CUSTOM_BASE_URL:-}" ]]; then
  echo "CUSTOM_BASE_URL is not set, so there is no model to ask." >&2
  echo "Source the environment that points Hermes at one first." >&2
  exit 2
fi

mkdir -p "$OUT"

# Switch the editor to Hermes for the whole tour. The backend is a setting, and
# this is what setting it looks like.
SWITCH='ex:lua require("util.agent").config.backend = "hermes"'

film() {
  local name="$1" title="$2" blurb="$3"
  shift 3

  echo "  $name"
  "$HERE/film.sh" -c "$CONFIG_DIR" -n "$APPNAME" -d "$PROJECT" -t \
    -o "$OUT/$name" -T "$title" -w 90 -p "${FILM_PAUSE:-70}" "$@" >/dev/null
  printf '%s\n' "$blurb" > "$OUT/$name/blurb.txt"
}

echo "Recording into $OUT"
echo "Model: ${HERMES_INFERENCE_MODEL:-default} via ${HERMES_INFERENCE_PROVIDER:-default}"

film 01-review "A review you have to type your way out of" \
  "Findings arrive as diagnostics, so ]d walks them and you fix them by typing. Nothing is applied, and there is no key here that edits a buffer." \
  'ex:edit label_studio/core/utils/params.py' 'ex:call search("def int_from_request")' 'ex:normal! 8j' "$SWITCH" 'Space' 'ar'

film 02-scope "Widening what gets reviewed" \
  "The same shape as the grep filter: one key, and a-s moves the scope out from this function to the file to only what you changed." \
  'ex:edit label_studio/core/utils/params.py' 'ex:call search("def int_from_request")' 'ex:normal! 8j' "$SWITCH" 'Space' 'ar' 'M-s'

film 03-hint-one "A hint that withholds the answer" \
  "The first rung names the class of problem and nothing else. No function, no library, no steps — the part where you work it out still has to happen." \
  'ex:edit label_studio/core/utils/params.py' "$SWITCH" 'ex:call search("def int_from_request")' 'ex:normal! 8j' 'Space' 'ah'

film 04-hint-two "Pressing again for one rung more" \
  "Approach, then what to look up, then the signature. The ladder resets when you move somewhere else, so it measures how stuck you are here." \
  'ex:edit label_studio/core/utils/params.py' "$SWITCH" 'ex:call search("def int_from_request")' 'ex:normal! 8j' 'Space' 'ah' 'Space' 'ah'

film 05-lookup "Looking something up" \
  "The rung that makes you faster rather than the one that makes you think. Remembering an argument order was never the skill." \
  'ex:edit label_studio/core/utils/params.py' "$SWITCH" 'Space' 'al' 'python bisect insort' 'Enter'

film 06-explain "What this error means" \
  "With a diagnostic under the cursor it explains that instead, because that is almost always the question." \
  'ex:edit label_studio/core/utils/params.py' "$SWITCH" 'ex:call search("def int_from_request")' 'ex:normal! 8j' 'Space' 'ax'

film 07-switch "Choosing which agent answers" \
  "Claude Code, Hermes and Codex differ in how they go headless and how they are stopped from writing. One that has not been shown to refuse a write is refused, not warned about." \
  'ex:edit label_studio/core/utils/params.py' 'Space' 'au'

film 08-cost "What it has cost" \
  "Real money on a hosted model, nothing on a local one, and either way visible rather than discovered later on a bill." \
  'ex:edit label_studio/core/utils/params.py' 'ex:call search("def int_from_request")' 'ex:normal! 8j' "$SWITCH" 'Space' 'ar' 'Space' 'a$'

echo
echo "Films in $OUT"
ls -1 "$OUT"
