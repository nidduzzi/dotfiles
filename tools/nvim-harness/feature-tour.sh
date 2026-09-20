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

# Each scenario is: name | description | wait | expect | keys...
#
# `expect` is an extended regular expression the capture has to contain. It is
# what turns a scenario from "the editor drew something" into a check: eight
# scenarios drove keys that did nothing at all, and every one of them captured
# a frame and passed. Match on what the feature itself puts on the screen --
# a picker title, a message, the text a filter left behind -- not on chrome
# that would still be there if the key had been ignored.
#
# Keys are tmux send-keys arguments, sent in order with a pause between them.
SCENARIOS=(
  # -- discovery -------------------------------------------------------------
  "startup|Dashboard on an empty start|14|Neovim loaded|"
  "whichkey-leader|Key hints: leader menu|14|f ➜|Space|ff|lib.lua|Enter|Escape|Space"
  "whichkey-search|Key hints: the search group|14|w ➜|Space|ff|lib.lua|Enter|Escape|Space|s"
  "whichkey-goto|Key hints: the goto prefix|14|Move to|Space|ff|lib.lua|Enter|Escape|g"
  # -- finding files and text ------------------------------------------------
  "find-files|Search files|14|Files|Space|ff"
  "grep-code|Search file contents, documentation excluded|14|Grep \(code\)|Space|sg|validateToken"
  "grep-all|Search file contents, everything|14|Grep \(all\)|Space|sg|validateToken|M-S|all|Enter"
  "grep-docs|Search documentation only|14|Grep \(docs\)|Space|sg|validateToken|M-S|docs|Enter"
  "grep-word|Search the word under the cursor|14|Grep \(code\)|Space|ff|auth.js|Enter|:3|Enter|w|Space|sw"
  "grep-buffer|Search lines in the current buffer|14|Lines|Space|ff|auth.js|Enter|wait:3:Space|sb"
  "grep-open|Search across open buffers|14|Grep Buffers|Space|ff|auth.js|Enter|Space|ff|lib.lua|Enter|Space|sB"
  "grep-tree|Results grouped by file in Trouble|14|Snacks|Space|sg|validateToken|wait:3:C-t"
  "fuzzy-files|Fuzzy matching in the file picker|14|auth.js|Space|ff|athjs"
  "fuzzy-toggle|Grep, then C-g to fuzzy filter the results|14|README|Space|sg|validateToken|C-g|README"
  "fuzzy-path|Fuzzy filtering the results by path|14|src/|Space|sg|validateToken|C-g|src/"
  "regex-default|Regex is the default: token.*expiry matches, as ripgrep would|14|expiresAt|Space|sg|token.*expiry"
  "regex-toggle|a-r switches to fixed-string matching, shown by R in the title|14|0/0|Space|sg|M-r|token.*expiry"
  "filter-glob|Restrict the search to a path glob with a-G|14|Grep \(src/\*\*\)|Space|sg|validateToken|M-G|src/**|Enter"
  "filter-glob-not|Exclude a path glob, by prefixing it with !|14|Grep \(not src/\*\*\)|Space|sg|validateToken|M-G|!src/**|Enter"
  "filter-ext|Restrict the search to extensions with a-e|14|Grep \(ext:js\)|Space|sg|validateToken|M-e|js|Enter"
  "filter-choose|Choosing a filter preset from a list with a-S|14|Search filter|Space|sg|validateToken|M-S"
  "resume|Resume the last search|14|Grep \(code\)|Space|sg|validateToken|wait:2:Escape|Space|sR"
  "buffers|Buffer list|14|Buffers|Space|ff|lib.lua|Enter|Space|ff|app.py|Enter|Space|,"
  "recent|Recent files|14|Recent|Space|fr"
  "help-tags|Help tags|14|Help|Space|sh"
  "keymaps|Keymaps|14|Keymaps|Space|sk"
  "marks|Marks|14|Marks|Space|sm"
  "explorer|File tree explorer|14|Explorer|wait:2:Space|wait:3:e"
  "explorer-search|Searching inside the tree: i focuses the filter, the tree stays a tree|14|lib.lua|Space|e|i|lua"
  "explorer-search-deep|A filter matching inside nested directories, shown in place|14|openspec|Space|e|i|spec"
  "explorer-grep|Grep scoped to the directory under the cursor|14|validateToken|Space|e|j|j|Space|/|validateToken"
  # -- language servers ------------------------------------------------------
  "lsp-hover|Hover documentation|14|add: function|Space|ff|lib.lua|Enter|:8|Enter|ww|K"
  "lsp-refs|References|18|Lsp References|Space|ff|lib.lua|Enter|:8|Enter|ww|gr"
  "lsp-def|Definition|18|function M.add|Space|ff|lib.lua|Enter|:13|Enter|wwww|gd"
  "lsp-symbols|Document symbols|16|Lsp Symbols|Space|ff|lib.lua|Enter|Space|ss"
  "lsp-workspace-symbols|Workspace symbols|16|Lsp Workspace Symbols|Space|ff|lib.lua|Enter|Space|sS"
  "lsp-rename|Rename|16|New Name|Space|ff|lib.lua|Enter|:8|Enter|ww|Space|cr"
  "lsp-codeaction|Code actions|18|Code actions|Space|ff|broken.py|Enter|:9|Enter|ww|Space|ca"
  "lsp-diagnostics|Diagnostics for the buffer|16|imported but unused|Space|ff|broken.py|Enter|wait:4:Space|wait:3:xx"
  "lsp-diagnostics-search|Diagnostics picker|16|Diagnostics|Space|ff|broken.py|Enter|Space|sd"
  "lsp-line-diagnostic|Diagnostic for the line|16|Undefined name|Space|ff|broken.py|Enter|:5|Enter|Space|cd"
  "lsp-inlay|Inlay hints and signature help|14|a: number|Space|ff|lib.lua|Enter"
  "completion|Completion with documentation|16|Add two numbers together|Space|ff|lib.lua|Enter|GO|M.ad"
  "format|Formatting a badly formatted file|14|M.messy\(a, b\)|Space|ff|messy.lua|Enter|Space|cf"
  # -- git -------------------------------------------------------------------
  "git-signs|Git signs in a modified file|14|▎|Space|ff|login.js|Enter"
  "git-hunk|Git hunk preview|14|validateToken\(user\.token\);|Space|ff|login.js|Enter|:2|Enter|wait:3:Space|ghp"
  "git-blame|Git blame for the line|14|Git Log Line|Space|ff|login.js|Enter|:1|Enter|Space|gb"
  "git-status|Changed files|14|Git Status|Space|gs"
  "git-log|Commit log|14|Git Log|Space|gl"
  # -- editing ---------------------------------------------------------------
  "todo|TODO, FIXME and HACK comments|14|Todo Comments|Space|st"
  "yank-history|Yank ring history|14|Yank History|Space|ff|lib.lua|Enter|yy|Space|sy"
  "treesitter|Syntax highlighting|14|function validateToken|Space|ff|auth.js|Enter"
  "folds|Folded code|14|lines|Space|ff|auth.js|Enter|zM"
  "terminal|Terminal|14|terminal works|Space|ft|echo terminal works|Enter"
  "debug-ui|Debugger breakpoint and menu|14|➜|Space|ff|app.py|Enter|:5|Enter|Space|db|Space|d"
  # -- the editor itself -----------------------------------------------------
  "lazy|Plugin manager|14|lazy.nvim|Space|l"
  "mason|Tool installer|14|Language Filter|Space|cm"
  "colorscheme|Colourscheme picker|14|Colorschemes|Space|uC"
  "health|Which language servers this project provides|14|language servers|:checkhealth dotfiles|Enter"
  "notifications|Notification history|14|Notifications|Space|sg|validateToken|M-c|Escape|wait:2:Space|n"
)

echo "config:   $CONFIG_DIR ($APPNAME)"
echo "fixture:  $WORKDIR"
echo "output:   $OUT_DIR"
echo

declare -a CAPTURED=()
declare -a FAILURES=()

for scenario in "${SCENARIOS[@]}"; do
  IFS='|' read -r -a parts <<<"$scenario"
  name="${parts[0]}"
  desc="${parts[1]}"
  wait="${parts[2]}"
  expect="${parts[3]}"
  keys=("${parts[@]:4}")

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
    -t -I -e -w "$wait" -p 2 \
    -o "$ansi" \
    "${keys[@]}" >/dev/null 2>&1; then
    if sed -e 's/\x1b\[[0-9;]*m//g' "$ansi" | grep -qE -- "$expect"; then
      CAPTURED+=("$name|$desc")
      echo "captured"
    else
      echo "CAPTURED BUT EMPTY: nothing matching /$expect/"
      FAILURES+=("$name: no /$expect/")
    fi
  else
    echo "FAILED"
    FAILURES+=("$name: the driver gave up")
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

# A scenario that could not be captured, or captured a frame without what the
# feature puts on it, is a scenario that did not work. This used to print
# FAILED and exit 0 — so a broken key read the same as a clean run to anything
# checking the exit status. The contact sheet is still
# built either way, because the frames that did capture are worth looking at
# while the failure is being fixed.
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo
  echo "${#FAILURES[@]} of $((${#CAPTURED[@]} + ${#FAILURES[@]})) scenarios failed:"
  printf '  %s\n' "${FAILURES[@]}"
  exit 1
fi
