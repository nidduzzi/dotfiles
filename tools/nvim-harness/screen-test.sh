#!/usr/bin/env bash
# Drive a key sequence and compare the resulting screen against a committed one.
#
# Usage:
#   screen-test.sh [-d TESTS_DIR] [-c CONFIG] [-n APPNAME] [-u] [NAME ...]
#
#   -u   rewrite the .expected files from what was drawn
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
TESTS_DIR="$CONFIG_ROOT/$APPNAME/tests/screen"
NORMALISE="$HERE/screen-normalise.sed"
UPDATE=0

while getopts "d:c:n:u" opt; do
  case "$opt" in
    d) TESTS_DIR="$OPTARG" ;;
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    u) UPDATE=1 ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

[[ -d "$TESTS_DIR" ]] || { echo "Not a directory: $TESTS_DIR" >&2; exit 2; }
[[ -f "$NORMALISE" ]] || { echo "Missing $NORMALISE" >&2; exit 2; }

read_directive() {
  local file="$1" name="$2" fallback="$3" value
  value="$(sed -n "s/^# *$name: *//p" "$file" | head -1)"
  printf '%s' "${value:-$fallback}"
}

read_batches() {
  grep -v '^#' "$1" | grep -v '^[[:space:]]*$'
}

normalise() {
  sed -f "$NORMALISE" | sed "s/\\b$BRANCH\\b/BRANCH/g"
}

capture() {
  local keys_file="$1" out="$2" workdir size cols rows
  workdir="$(read_directive "$keys_file" dir "$HERE/fixture")"
  size="$(read_directive "$keys_file" size "100x24")"
  cols="${size%x*}"
  rows="${size#*x}"

  [[ -d "$workdir" ]] || { echo "No such directory: $workdir" >&2; return 1; }
  BRANCH="$(git -C "$workdir" branch --show-current 2>/dev/null || echo NO_BRANCH)"

  local batches=()
  mapfile -t batches < <(read_batches "$keys_file")

  "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$workdir" \
    -t -w 90 -p 2 -W "$cols" -H "$rows" \
    "${batches[@]}" 2>/dev/null | normalise > "$out"
}

selected() {
  if [[ $# -gt 0 ]]; then
    local name
    for name in "$@"; do
      printf '%s\n' "$TESTS_DIR/$name.keys"
    done
  else
    find "$TESTS_DIR" -name '*.keys' | sort
  fi
}

failed=0
checked=0

while IFS= read -r keys_file; do
  [[ -f "$keys_file" ]] || { echo "No such test: $keys_file" >&2; failed=$((failed + 1)); continue; }

  name="$(basename "$keys_file" .keys)"
  expected="$TESTS_DIR/$name.expected"
  actual="$(mktemp)"

  printf '%-28s ' "$name"
  capture "$keys_file" "$actual"
  checked=$((checked + 1))

  if [[ "$UPDATE" -eq 1 ]]; then
    mv "$actual" "$expected"
    echo "updated"
    continue
  fi

  if [[ ! -f "$expected" ]]; then
    mv "$actual" "$expected"
    echo "created"
    continue
  fi

  if diff -q "$expected" "$actual" >/dev/null; then
    echo "ok"
    rm -f "$actual"
  else
    echo "CHANGED"
    diff -u --label "$name.expected" --label "$name.drawn" "$expected" "$actual" || true
    rm -f "$actual"
    failed=$((failed + 1))
  fi
done < <(selected "$@")

echo
if [[ "$checked" -eq 0 ]]; then
  echo "No screen tests under $TESTS_DIR."
  exit 1
fi

if [[ "$failed" -gt 0 ]]; then
  echo "$failed of $checked screens differ. Re-run with -u to accept them."
  exit 1
fi

echo "$checked screen(s) match."
