#!/usr/bin/env bash
# Drive Neovim through its features and capture what each one draws.
#
# Reading a configuration tells you what should happen. This shows what does.
# Every scenario below starts a fresh Neovim in an isolated tmux, sends the
# keys, captures the pane and renders it, so a configuration change can be
# checked feature by feature rather than by opening the editor and trying to
# remember what used to work.
#
# Usage:
#   feature-tour.sh -c CONFIG_DIR -n APPNAME [-d WORKDIR] [-o OUT_DIR] [-f FILTER]
#
#   -c DIR    config directory, as XDG_CONFIG_HOME
#   -n NAME   NVIM_APPNAME
#   -d DIR    directory Neovim opens in. Default: the harness fixture.
#   -o DIR    where captures and the contact sheet are written.
#   -f REGEX  only run scenarios whose name matches.
#
# The result is OUT_DIR/index.html: every capture on one page, labelled.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR=""
APPNAME=""
WORKDIR="$HERE/fixture"
OUT_DIR="${TMPDIR:-/tmp}/nvim-feature-tour"
FILTER=""

while getopts "c:n:d:o:f:" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

[[ -n "$CONFIG_DIR" ]] || { echo "-c CONFIG_DIR is required" >&2; exit 2; }

mkdir -p "$OUT_DIR"

# A Neovim killed mid-scenario leaves a swap file behind, and the next run that
# opens the same file stops on a recovery prompt instead of showing the feature.
if [[ -n "$APPNAME" ]]; then
  swap_dir="${XDG_STATE_HOME:-$HOME/.local/state}/$APPNAME/swap"
  [[ -d "$swap_dir" ]] && rm -f "$swap_dir"/*
fi

# Each scenario is: name | description | wait | keys...
# Keys are tmux send-keys arguments, sent in order with a pause between them.
SCENARIOS=(
  "startup|Dashboard on an empty start|8|"
  "which-key|Leader menu, showing the top level groups|10|Space|ff|lib.lua|Enter|Escape|Space"
  "find-files|File picker|8|Space|ff"
  "grep-code|Grep with documentation excluded|8|Space|sg|validateToken"
  "grep-all|Grep including documentation|8|Space|sG|validateToken"
  "grep-docs|Grep documentation only|8|Space|sD|validateToken"
  "grep-tree|Grep results grouped by file in Trouble|8|Space|sg|validateToken|C-t"
  "buffers|Buffer list|12|Space|ff|lib.lua|Enter|Space|ff|app.py|Enter|Space|,"
  "recent|Recently opened files|8|Space|fr"
  "help-tags|Help tag search|8|Space|sh"
  "keymaps|Keymap search|8|Space|sk"
  "todo|TODO, FIXME and HACK comments|8|Space|st"
  "explorer|File tree explorer|8|Space|e"
  "treesitter|Syntax highlighting and inlay hints|12|Space|ff|auth.js|Enter"
  "lsp-hover|LSP hover documentation in Lua|14|Space|ff|lib.lua|Enter|/M.add|Enter|Escape|K"
  "lsp-diagnostics|Diagnostics list|16|Space|ff|broken.py|Enter|Space|xx"
  "lsp-symbols|Document symbols|16|Space|ff|lib.lua|Enter|Space|ss"
  "git-signs|Git signs in a modified file|10|Space|ff|login.js|Enter"
  "git-status|Changed files picker|10|Space|gs"
  "yank-history|Yank ring history|8|yy|Space|sy"
  "lazy|Plugin manager|10|Space|l"
  "mason|Language server installer|10|Space|cm"
  "terminal|Terminal split|10|Space|ft|echo terminal works|Enter"
  "colorscheme|Colourscheme picker|8|Space|uC"
  "completion|Completion menu in a Lua buffer|16|Space|ff|lib.lua|Enter|GO|M.ad"
  "format|Formatting a badly formatted file with <leader>cf|14|Space|ff|messy.lua|Enter|Space|cf"
  "lsp-refs|LSP references|18|Space|ff|lib.lua|Enter|:8|Enter|ww|gr"
  "health|External tool check|12|:checkhealth dotfiles|Enter"
)

echo "config:   $CONFIG_DIR ($APPNAME)"
echo "fixture:  $WORKDIR"
echo "output:   $OUT_DIR"
echo

declare -a CAPTURED=()

for scenario in "${SCENARIOS[@]}"; do
  IFS='|' read -r -a parts <<<"$scenario"
  name="${parts[0]}"
  desc="${parts[1]}"
  wait="${parts[2]}"
  keys=("${parts[@]:3}")

  # Drop the empty trailing field a scenario with no keys produces.
  [[ ${#keys[@]} -eq 1 && -z "${keys[0]}" ]] && keys=()

  if [[ -n "$FILTER" && ! "$name" =~ $FILTER ]]; then
    continue
  fi

  printf '%-16s %s ... ' "$name" "$desc"

  ansi="$OUT_DIR/$name.ansi"

  if "$HERE/nvim-drive.sh" \
    -c "$CONFIG_DIR" \
    ${APPNAME:+-n "$APPNAME"} \
    -d "$WORKDIR" \
    -t -e -w "$wait" -p 2 \
    -o "$ansi" \
    "${keys[@]}" >/dev/null 2>&1; then
    CAPTURED+=("$name|$desc")
    echo "captured"
  else
    echo "FAILED"
  fi
done

echo
echo "Building the contact sheet"

# One page holding every capture, so the whole configuration can be reviewed at
# once instead of opening two dozen files.
python3 "$HERE/build-contact-sheet.py" \
  --out "$OUT_DIR/index.html" \
  --title "Neovim feature tour" \
  --dir "$OUT_DIR" \
  "${CAPTURED[@]}"

echo
echo "Open $OUT_DIR/index.html"
