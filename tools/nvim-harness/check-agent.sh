#!/usr/bin/env bash
# Ask a real agent, in a real editor, and check what came back. Not a CI
# gate: it spends real requests on a hosted model. Run after touching
# lua/util/agent, beside agent-canary.sh.
#
# Usage:
#   check-agent.sh [-c CONFIG] [-n APPNAME] [-d PROJECT] [-f REGEX] [-o OUT_DIR]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
PROJECT="$HERE/fixture"
OUT_DIR="${TMPDIR:-/tmp}/nvim-agent-check"
FILTER=""

while getopts "c:n:d:f:o:" opt; do
  case "$opt" in
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) PROJECT="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

# name | wait | expect | keys...
# expect is something only a real answer produces, not the window opening.
CASES=(
  "review|60|[0-9]  [A-Z][a-z]| ff|buggy.lua|Enter|:10|Enter| ar"
  "explain|50|a-q closes| ff|buggy.lua|Enter|:17|Enter| ax"
  "lookup|50|a-q closes| ff|buggy.lua|Enter| al|python bisect insort|Enter"
)

failures=()
checked=0

for case in "${CASES[@]}"; do
  IFS='|' read -r -a parts <<<"$case"
  name="${parts[0]}"
  wait="${parts[1]}"
  expect="${parts[2]}"
  keys=("${parts[@]:3}")

  [[ -n "$FILTER" && ! "$name" =~ $FILTER ]] && continue

  printf '%-10s ' "$name"
  checked=$((checked + 1))

  ansi="$OUT_DIR/$name.ansi"
  drawn="$OUT_DIR/$name.drawn"

  if ! "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$PROJECT" \
    -t -I -e -w 40 -p 2 -o "$ansi" \
    "${keys[@]}" "wait:$wait:" >/dev/null 2>&1; then
    echo "FAILED: the driver gave up"
    failures+=("$name: the driver gave up")
    continue
  fi

  sed -e 's/\x1b\[[0-9;]*m//g' "$ansi" >"$drawn"

  if grep -qE -- "$expect" "$drawn"; then
    echo "answered"
  else
    echo "NO ANSWER: nothing matching /$expect/, frame in $drawn"
    failures+=("$name: no /$expect/")
  fi
done

echo
if [[ ${#failures[@]} -gt 0 ]]; then
  echo "${#failures[@]} of $checked agent flow(s) did not answer:"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
echo "$checked agent flow(s) answered."
