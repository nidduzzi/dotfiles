#!/usr/bin/env bash
# Compile every Lua file in a Neovim config with Neovim's own Lua; report which
# fail. luac is not always installed.
#
# Usage:
#   check-syntax.sh [CONFIG_DIR]
#
# Defaults to $NVIM_TOUR_CONFIG/$NVIM_TOUR_APPNAME. The resolved path and file
# count are printed so a wrong tree is visible rather than inferred.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"
CONFIG_DIR="${1:-$CONFIG_ROOT/$APPNAME}"

[[ -d "$CONFIG_DIR" ]] || { echo "Not a directory: $CONFIG_DIR" >&2; exit 2; }

echo "Checking $(cd "$CONFIG_DIR" && pwd)"

command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

failed=0
checked=0
require_files=1

while IFS= read -r -d '' file; do
  checked=$((checked + 1))
  # loadfile compiles without executing, so a file with side effects is safe.
  result="$(nvim --headless --clean \
    -c "lua local f, err = loadfile('$file') io.write(f and 'ok' or ('FAIL: ' .. tostring(err)))" \
    -c "qa" 2>/dev/null)"

  if [[ "$result" == ok ]]; then
    continue
  fi

  failed=$((failed + 1))
  printf '%s\n  %s\n' "${file#"$CONFIG_DIR"/}" "$result"
# -L: the config is reached through a symlink (.worktrees/cfg), and without
# -L find walks nothing and reports nothing.
done < <(find -L "$CONFIG_DIR" -name '*.lua' -not -path '*/.git/*' -not -path '*/.tests/*' -print0 | sort -z)

echo
if [[ "$checked" -eq 0 && "$require_files" -eq 1 ]]; then
  echo "No Lua files under $CONFIG_DIR."
  echo "That is a wrong path, not a clean tree. Nothing was checked."
  exit 1
fi

if [[ "$failed" -eq 0 ]]; then
  echo "All $checked Lua file(s) compile."
else
  echo "$failed of $checked Lua file(s) failed to compile."
  exit 1
fi
