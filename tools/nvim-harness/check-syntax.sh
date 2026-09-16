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
# Defaults to the Neovim config in this repository. Exit status is 1 if any
# file fails to compile.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${1:-$HERE/../../neovim/.config/nvim}"

[[ -d "$CONFIG_DIR" ]] || { echo "Not a directory: $CONFIG_DIR" >&2; exit 2; }

command -v nvim >/dev/null || { echo "nvim is required" >&2; exit 1; }

failed=0
checked=0

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
done < <(find "$CONFIG_DIR" -name '*.lua' -not -path '*/.git/*' -print0 | sort -z)

echo
if [[ "$failed" -eq 0 ]]; then
  echo "All $checked Lua file(s) compile."
else
  echo "$failed of $checked Lua file(s) failed to compile."
  exit 1
fi
