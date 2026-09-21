#!/usr/bin/env bash
# Drive a key sequence and compare the resulting screen against a committed one.
#
# Usage:
#   screen-test.sh [-d TESTS_DIR] [-c CONFIG] [-n APPNAME] [-u] [NAME ...]
#
#   -u   rewrite the .expected files from what was drawn
#   -l   also run tests marked `# needs: lsp`
#   -t N attempts before a screen is called changed. Default 3.
#
# Per-test directives, as `# name: value` lines in the .keys file:
#   dir, size, needs, attempts, pause
#
# A screen is asserted to eventually match, not to match on the first try, the
# way Neovim's own Screen:expect retries until its timeout. Diagnostics and
# hover arrive when the language server answers, which is not on a schedule.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
TESTS_DIR="$CONFIG_ROOT/$APPNAME/tests/screen"
# Python rather than sed: \b, \| and \{n,\} are GNU extensions and macOS
# ships the BSD one, where the branch was never replaced and the statusline
# never collapsed -- so every screen differed for reasons that had nothing to
# do with the editor.
NORMALISE="$HERE/screen-normalise.py"
UPDATE=0
WITH_LSP=0
ATTEMPTS=3

while getopts "d:c:n:ult:" opt; do
  case "$opt" in
    d) TESTS_DIR="$OPTARG" ;;
    c) CONFIG_ROOT="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    u) UPDATE=1 ;;
    l) WITH_LSP=1 ;;
    t) ATTEMPTS="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

CONFIG_ROOT="$(cd "$CONFIG_ROOT" && pwd)"

# A panel that prints a path wraps where the path ends, and the path is a
# different length on every machine. Reached through a fixed-length link, it
# wraps in the same place everywhere.
STABLE_CONFIG=/tmp/nvim-screen-cfg
rm -f "$STABLE_CONFIG"
ln -sfn "$CONFIG_ROOT" "$STABLE_CONFIG"
CONFIG_ROOT="$STABLE_CONFIG"

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
  python3 "$NORMALISE" \
    --project "$WORKDIR_REAL" --project "$WORKDIR_TILDE" \
    --config "$CONFIG_REAL" --config "$CONFIG_GIVEN" --config "$CONFIG_TILDE" \
    --branch "$BRANCH"
}

capture() {
  local keys_file="$1" out="$2" workdir size cols rows
  workdir="$(read_directive "$keys_file" dir "$HERE/fixture")"
  size="$(read_directive "$keys_file" size "100x24")"
  cols="${size%x*}"
  rows="${size#*x}"

  [[ -d "$workdir" ]] || { echo "No such directory: $workdir" >&2; return 1; }
  BRANCH="$(git -C "$workdir" branch --show-current 2>/dev/null || echo NO_BRANCH)"
  WORKDIR_REAL="$(cd "$workdir" && pwd)"
  CONFIG_REAL="$(cd "$CONFIG_ROOT" && pwd)"
  CONFIG_GIVEN="$CONFIG_ROOT"
  # Built by hand rather than with a pattern substitution: the escaped tilde
  # in the replacement survives as a backslash on bash 3.2, which is what
  # macOS ships, and the home-shortened path then matched nothing at all.
  WORKDIR_TILDE="$WORKDIR_REAL"
  CONFIG_TILDE="$CONFIG_GIVEN"
  [[ "$WORKDIR_REAL" == "$HOME"/* ]] && WORKDIR_TILDE="~${WORKDIR_REAL#"$HOME"}"
  [[ "$CONFIG_GIVEN" == "$HOME"/* ]] && CONFIG_TILDE="~${CONFIG_GIVEN#"$HOME"}"

  local pause
  pause="$(read_directive "$keys_file" pause 2)"

  # Read line by line rather than with mapfile, which is a bash 4 builtin and
  # macOS ships bash 3.2: there the script died on this line with
  # "mapfile: command not found" and no screen was ever compared.
  local batches=()
  local batch
  while IFS= read -r batch; do
    batches+=("$batch")
  done < <(read_batches "$keys_file")

  "$HERE/nvim-drive.sh" \
    -c "$CONFIG_ROOT" -n "$APPNAME" -d "$workdir" \
    -t -I -w 90 -p "$pause" -W "$cols" -H "$rows" \
    ${batches[@]+"${batches[@]}"} 2>/dev/null | normalise > "$out"
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

  needs="$(read_directive "$keys_file" needs "")"
  if [[ "$needs" == "lsp" && "$WITH_LSP" -ne 1 ]]; then
    echo "skipped, needs a language server (-l to run)"
    rm -f "$actual"
    continue
  fi

  checked=$((checked + 1))

  if [[ "$UPDATE" -eq 1 || ! -f "$expected" ]]; then
    capture "$keys_file" "$actual"
    mv "$actual" "$expected"
    [[ "$UPDATE" -eq 1 ]] && echo "updated" || echo "created"
    continue
  fi

  attempts="$(read_directive "$keys_file" attempts "$ATTEMPTS")"
  matched=0
  for attempt in $(seq 1 "$attempts"); do
    capture "$keys_file" "$actual"
    if diff -q "$expected" "$actual" >/dev/null; then
      matched=1
      [[ "$attempt" -eq 1 ]] && echo "ok" || echo "ok, on attempt $attempt"
      break
    fi
  done

  if [[ "$matched" -eq 0 ]]; then
    echo "CHANGED, after $attempts attempts"
    diff -u --label "$name.expected" --label "$name.drawn" "$expected" "$actual" || true
    cp "$actual" "$TESTS_DIR/$name.drawn"
    failed=$((failed + 1))
  fi
  rm -f "$actual"
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
