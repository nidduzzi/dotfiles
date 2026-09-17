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
  # -- discovery -------------------------------------------------------------
  "startup|Dashboard on an empty start|8|"
  "whichkey-leader|Key hints: leader menu|12|Space|ff|lib.lua|Enter|Escape|Space"
  "whichkey-search|Key hints: the search group|12|Space|ff|lib.lua|Enter|Escape|Space|s"
  "whichkey-goto|Key hints: the goto prefix|12|Space|ff|lib.lua|Enter|Escape|g"
  # -- finding files and text ------------------------------------------------
  "find-files|Search files|8|Space|ff"
  "grep-code|Search file contents, documentation excluded|8|Space|sg|validateToken"
  "grep-all|Search file contents, everything|8|Space|sG|validateToken"
  "grep-docs|Search documentation only|8|Space|sO|validateToken"
  "grep-word|Search the word under the cursor|12|Space|ff|auth.js|Enter|:3|Enter|w|Space|sw"
  "grep-buffer|Search lines in the current buffer|12|Space|ff|auth.js|Enter|Space|sb"
  "grep-open|Search across open buffers|14|Space|ff|auth.js|Enter|Space|ff|lib.lua|Enter|Space|sB"
  "grep-tree|Results grouped by file in Trouble|8|Space|sg|validateToken|C-t"
  "fuzzy-files|Fuzzy matching in the file picker|10|Space|ff|athjs"
  "fuzzy-toggle|Grep, then C-g to fuzzy filter the results|12|Space|sg|validateToken|C-g|README"
  "fuzzy-path|Fuzzy filtering the results by path|12|Space|sg|validateToken|C-g|src/"
  "regex-default|Regex is the default: token.*expiry matches, as ripgrep would|12|Space|sg|token.*expiry"
  "regex-toggle|a-r switches to fixed-string matching, shown by R in the title|14|Space|sg|M-r|token.*expiry"
  "filter-glob|Restrict the search to a path glob with a-G|14|Space|sg|validateToken|M-G|src/**|Enter"
  "filter-glob-not|Exclude a path glob, by prefixing it with !|14|Space|sg|validateToken|M-G|!src/**|Enter"
  "filter-ext|Restrict the search to extensions with a-e|14|Space|sg|validateToken|M-e|js|Enter"
  "filter-choose|Choosing a filter preset from a list with a-p|12|Space|sg|validateToken|M-p"
  "resume|Resume the last search|14|Space|sg|validateToken|Escape|Space|sR"
  "buffers|Buffer list|12|Space|ff|lib.lua|Enter|Space|ff|app.py|Enter|Space|,"
  "recent|Recent files|8|Space|fr"
  "help-tags|Help tags|8|Space|sh"
  "keymaps|Keymaps|8|Space|sk"
  "marks|Marks|8|Space|sm"
  "explorer|File tree explorer|8|Space|e"
  "explorer-search|Searching inside the tree: i focuses the filter, the tree stays a tree|12|Space|e|i|lua"
  "explorer-search-deep|A filter matching inside nested directories, shown in place|12|Space|e|i|spec"
  "explorer-grep|Grep scoped to the directory under the cursor|14|Space|e|j|j|Space|/|validateToken"
  # -- language servers ------------------------------------------------------
  "lsp-hover|Hover documentation|14|Space|ff|lib.lua|Enter|:8|Enter|ww|K"
  "lsp-refs|References|18|Space|ff|lib.lua|Enter|:8|Enter|ww|gr"
  "lsp-def|Definition|18|Space|ff|lib.lua|Enter|:13|Enter|wwww|gd"
  "lsp-symbols|Document symbols|16|Space|ff|lib.lua|Enter|Space|ss"
  "lsp-workspace-symbols|Workspace symbols|16|Space|ff|lib.lua|Enter|Space|sS"
  "lsp-rename|Rename|16|Space|ff|lib.lua|Enter|:8|Enter|ww|Space|cr"
  "lsp-codeaction|Code actions|18|Space|ff|broken.py|Enter|:9|Enter|ww|Space|ca"
  "lsp-diagnostics|Diagnostics for the buffer|16|Space|ff|broken.py|Enter|Space|xx"
  "lsp-diagnostics-search|Diagnostics picker|16|Space|ff|broken.py|Enter|Space|sd"
  "lsp-line-diagnostic|Diagnostic for the line|16|Space|ff|broken.py|Enter|:5|Enter|Space|cd"
  "lsp-inlay|Inlay hints and signature help|14|Space|ff|lib.lua|Enter"
  "completion|Completion with documentation|16|Space|ff|lib.lua|Enter|GO|M.ad"
  "format|Formatting a badly formatted file|14|Space|ff|messy.lua|Enter|Space|cf"
  # -- git -------------------------------------------------------------------
  "git-signs|Git signs in a modified file|10|Space|ff|login.js|Enter"
  "git-hunk|Git hunk preview|14|Space|ff|login.js|Enter|G|Space|ghp"
  "git-blame|Git blame for the line|14|Space|ff|login.js|Enter|:1|Enter|Space|gb"
  "git-status|Changed files|10|Space|gs"
  "git-log|Commit log|10|Space|gl"
  # -- editing ---------------------------------------------------------------
  "todo|TODO, FIXME and HACK comments|8|Space|st"
  "yank-history|Yank ring history|10|Space|ff|lib.lua|Enter|yy|Space|sy"
  "treesitter|Syntax highlighting|12|Space|ff|auth.js|Enter"
  "folds|Folded code|12|Space|ff|auth.js|Enter|zM"
  "terminal|Terminal|10|Space|ft|echo terminal works|Enter"
  "debug-ui|Debugger breakpoint and menu|14|Space|ff|app.py|Enter|:5|Enter|Space|db|Space|d"
  # -- the editor itself -----------------------------------------------------
  "lazy|Plugin manager|10|Space|l"
  "mason|Tool installer|10|Space|cm"
  "colorscheme|Colourscheme picker|8|Space|uC"
  "health|Which language servers this project provides|14|:checkhealth dotfiles|Enter"
  "notifications|Notification history|10|Space|snh"
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
