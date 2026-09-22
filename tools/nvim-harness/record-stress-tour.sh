#!/usr/bin/env bash
# Usage:
#   record-stress-tour.sh [-o OUTDIR] [-r PROJECTS_DIR] [FILM ...]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUT="${TMPDIR:-/tmp}/nvim-stress-tour"
PROJECTS="${NVIM_STRESS_PROJECTS:-$HOME/Documents/projects}"
CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

while getopts "o:r:c:n:" opt; do
  case "$opt" in
    o) OUT="$OPTARG" ;;
    r) PROJECTS="$OPTARG" ;;
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ -d "$PROJECTS" ]] || { echo "No such directory: $PROJECTS" >&2; exit 2; }

WANTED=("$@")

wanted() {
  [[ ${#WANTED[@]} -eq 0 ]] && return 0
  local name="$1" pick
  for pick in "${WANTED[@]}"; do
    [[ "$name" == *"$pick"* ]] && return 0
  done
  return 1
}

mkdir -p "$OUT"

film_in() {
  local project="$1" name="$2" title="$3" blurb="$4"
  shift 4

  wanted "$name" || return 0
  [[ -d "$project" ]] || { echo "  $name  SKIPPED, no $project"; return 0; }

  # `|| true`: git exits nonzero when $project is not a repo, which under
  # pipefail would otherwise end the script here, silently.
  local tracked
  tracked="$(git -C "$project" ls-files 2>/dev/null | wc -l || true)"
  echo "  $name  ($(basename "$project"), $tracked files)"

  "$HERE/film.sh" -c "$CONFIG_ROOT" -n "$APPNAME" -d "$project" -t \
    -o "$OUT/$name" -T "$title" -w 90 -p 3 "$@" >/dev/null
  printf '%s\n\nRecorded against %s, %s tracked files.\n' \
    "$blurb" "$(basename "$project")" "$tracked" > "$OUT/$name/blurb.txt"
}

probe_line() {
  local project="$1" key="$2"
  awk -v want="$key" '$1 == want { $1 = ""; sub(/^ +/, ""); print }' \
    "$OUT/probes/$(basename "$project").stress" 2>/dev/null || true
}

run_probes() {
  local project="$1" name
  name="$(basename "$project")"
  mkdir -p "$OUT/probes"
  echo "  probes ($name)"
  "$HERE/run-probes.sh" -p "$project" -c "$CONFIG_ROOT" -n "$APPNAME" \
    -o "$OUT/probes/$name" > "$OUT/probes/$name.log" 2>&1 || true
  cp "$OUT/probes/$name/stress.txt" "$OUT/probes/$name.stress" 2>/dev/null || true
  cp "$OUT/probes/$name/perf.txt" "$OUT/probes/$name.perf" 2>/dev/null || true
}

PYTHON_PROJECT="$PROJECTS/label-studio"
C_PROJECT="$PROJECTS/crun"
DOCS_PROJECT="$PROJECTS/migml"

echo "Recording into $OUT"

for project in "$PYTHON_PROJECT" "$C_PROJECT" "$DOCS_PROJECT"; do
  [[ -d "$project" ]] && run_probes "$project"
done

film_in "$PYTHON_PROJECT" 01-grep-large \
  "Grepping five thousand files" \
  "The definition ranks above the tests that call it. Ordering is computed from treesitter, not from a list of filename patterns." \
  'Space' 'sg' 'def get_queryset'

film_in "$PYTHON_PROJECT" 02-files-large \
  "Finding a file among sixty thousand" \
  "Sixty thousand files on disk, five and a half thousand tracked. The picker filters the tracked ones." \
  'Space' 'ff' 'core/utils/params' 'Enter'

film_in "$PYTHON_PROJECT" 03-capabilities-large \
  "Everything this editor can do, in a large project" \
  "Nine hundred and eighty two entries, filtered as you type. The list is the same everywhere; the buffer-local half changes with the file." \
  'keys:Space ?' 'worktree' 'Tab' 'Tab'

film_in "$C_PROJECT" 04-grep-c \
  "The same key in a C project" \
  "No Python, no ruff, and the ranking works the same way because it asks treesitter rather than the file extension." \
  'Space' 'sg' 'container_create'

film_in "$DOCS_PROJECT" 05-docs-filter \
  "A project that is mostly documentation" \
  "Two hundred and ninety three markdown files against a hundred and twenty yaml. a-s cycles the filter so prose can be excluded, included, or searched on its own." \
  'Space' 'sg' 'workflow' 'M-s'

film_in "$PYTHON_PROJECT" 06-health \
  "What the editor says about this project" \
  "Which language servers this project provides, which it does not, and which keys were overwritten since startup." \
  ':checkhealth dotfiles' 'Enter'

echo
echo "Films in $OUT"
ls -1 "$OUT" | grep -v '^probes$' || true
echo
echo "Probe reports:"
for report in "$OUT"/probes/*.perf; do
  [[ -f "$report" ]] || continue
  echo "  $(basename "$report" .perf)"
  sed 's/^/    /' "$report"
done
