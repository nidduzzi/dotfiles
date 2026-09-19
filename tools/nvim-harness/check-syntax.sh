#!/usr/bin/env bash
# Parse every Lua file in a Neovim config, and say which ones do not compile.
#
# A configuration file with a syntax error does not announce itself. lazy.nvim
# skips the spec, Neovim starts, and everything looks fine except that the
# settings in that file are silently absent. That is exactly how a stray
# comment marker went unnoticed here: the editor worked, the language servers
# it configured simply never loaded.
#
# `luac` is not always installed, so this uses Neovim's own Lua to compile each
# file without running it.
#
# Usage:
#   check-syntax.sh [CONFIG_DIR]
#
# Defaults to the configuration under development, which is what every other
# script here means by "the config": $NVIM_TOUR_CONFIG/$NVIM_TOUR_APPNAME.
#
# It used to default to neovim/.config/nvim, the stow'd everyday config. That
# is a different tree with different files, so running this bare reported on
# code nobody was editing — twenty-one files compiling cleanly while the
# thirty-three being changed went unchecked. A gate pointed at the wrong tree
# is worse than no gate, because it answers.
#
# The resolved path and the file count are printed for that reason: a wrong
# tree should be visible in the output rather than inferred from a number.
#
# Exit status is 1 if any file fails to compile.
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

# A gate that passes without checking anything is the failure this script was
# just fixed for. Finding no files means the path is wrong, not that the code
# is clean.
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
# -L because the config is reached through a symlink: .worktrees/cfg holds one
# link per NVIM_APPNAME. Without it find walks nothing, reports nothing, and
# the script says every one of zero files compiled.
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
