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
#   -a N      attempts per scenario before it counts as failed. Default: 2.
#
# The result is OUT_DIR/index.html: every capture on one page, labelled.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR=""
APPNAME=""
WORKDIR="$HERE/fixture"
OUT_DIR="${TMPDIR:-/tmp}/nvim-feature-tour"
FILTER=""
ATTEMPTS=2

while getopts "c:n:d:o:f:a:" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    d) WORKDIR="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    f) FILTER="$OPTARG" ;;
    a) ATTEMPTS="$OPTARG" ;;
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
  "whichkey-leader|Key hints: leader menu|14|f ➜| ff|lib.lua|Enter|Escape|Space"
  "whichkey-search|Key hints: the search group|14|w ➜| ff|lib.lua|Enter|Escape| s"
  "whichkey-goto|Key hints: the goto prefix|14|Move to| ff|lib.lua|Enter|Escape|g"
  # -- finding files and text ------------------------------------------------
  "find-files|Search files|14|Files| ff"
  "grep-code|Search file contents, documentation excluded|14|Grep \(code\)| sg|validateToken"
  "grep-all|Search file contents, everything|14|Grep \(all\)| sg|validateToken|M-S|all|wait:2:Enter"
  "grep-docs|Search documentation only|14|Grep \(docs\)| sg|validateToken|M-S|docs|wait:2:Enter"
  "grep-word|Search the word under the cursor|14|Grep \(code\)| ff|auth.js|Enter|:3|Enter|w| sw"
  "grep-buffer|Search lines in the current buffer|14|Lines| ff|auth.js|Enter|wait:3: sb"
  "grep-open|Search across open buffers|14|Grep Buffers| ff|auth.js|Enter| ff|lib.lua|Enter| sB"
  "grep-tree|Results grouped by file in Trouble|14|Snacks| sg|validateToken|wait:10:C-t"
  "fuzzy-files|Fuzzy matching in the file picker|14|auth.js| ff|athjs"
  "fuzzy-toggle|Grep, then C-g to fuzzy filter the results|14|README| sg|validateToken|C-g|README"
  "fuzzy-path|Fuzzy filtering the results by path|14|src/| sg|validateToken|C-g|src/"
  "regex-default|Regex is the default: token.*expiry matches, as ripgrep would|14|expiresAt| sg|token.*expiry"
  "regex-toggle|a-r switches to fixed-string matching, shown by R in the title|14|0/0| sg|M-r|token.*expiry"
  "filter-glob|Restrict the search to a path glob with a-G|14|Grep \(src/\*\*\)| sg|validateToken|M-G|src/**|wait:2:Enter"
  "filter-glob-not|Exclude a path glob, by prefixing it with !|14|Grep \(not src/\*\*\)| sg|validateToken|M-G|!src/**|wait:2:Enter"
  "filter-ext|Restrict the search to extensions with a-e|14|Grep \(ext:js\)| sg|validateToken|M-e|js|wait:2:Enter"
  "filter-choose|Choosing a filter preset from a list with a-S|14|Search filter| sg|validateToken|M-S"
  "resume|Resume the last search|14|Grep \(code\)| sg|validateToken|wait:2:Escape| sR"
  "buffers|Buffer list|14|Buffers| ff|lib.lua|Enter| ff|app.py|Enter| ,"
  "recent|Recent files|14|Recent| fr"
  "help-tags|Help tags|14|Help| sh"
  "keymaps|Keymaps|14|Keymaps| sk"
  "marks|Marks|14|Marks| sm"
  "explorer|File tree explorer|14|Explorer|wait:3: e"
  "explorer-search|Searching inside the tree: i focuses the filter, the tree stays a tree|14|lib.lua| e|i|lua"
  "explorer-search-deep|A filter matching inside nested directories, shown in place|14|openspec|wait:3: e|i|wait:3:spec"
  "explorer-grep|Grep scoped to the directory under the cursor|14|validateToken| e|j|j| /|validateToken"
  # -- language servers ------------------------------------------------------
  "lsp-hover|Hover documentation|14|add: function| ff|lib.lua|Enter|:8|Enter|ww|K"
  "lsp-refs|References|18|Lsp References| ff|lib.lua|Enter|:8|Enter|ww|gr"
  "lsp-def|Definition|18|function M.add| ff|lib.lua|Enter|:13|Enter|wwww|gd"
  "lsp-symbols|Document symbols|16|Lsp Symbols| ff|lib.lua|Enter| ss"
  "lsp-workspace-symbols|Workspace symbols|16|Lsp Workspace Symbols| ff|lib.lua|Enter|wait:4: sS"
  "lsp-rename|Rename|16|New Name| ff|lib.lua|Enter|:8|Enter|ww| cr"
  "lsp-codeaction|Code actions|18|Code actions| ff|broken.py|Enter|:9|Enter|ww| ca"
  "lsp-diagnostics|Diagnostics for the buffer|16|imported but unused| ff|broken.py|Enter|wait:4: xx"
  "lsp-diagnostics-search|Diagnostics picker|16|Diagnostics| ff|broken.py|Enter| sd"
  "lsp-line-diagnostic|Diagnostic for the line|16|Undefined name| ff|broken.py|Enter|:5|Enter| cd"
  "lsp-inlay|Inlay hints and signature help|14|a: number| ff|lib.lua|wait:6:Enter|wait:2:j|wait:2:k"
  "completion|Completion with documentation|16|Add two numbers together| ff|lib.lua|Enter|GO|M.ad"
  "format|Formatting a badly formatted file|14|M.messy\(a, b\)| ff|messy.lua|Enter| cf"
  # -- git -------------------------------------------------------------------
  "git-signs|Git signs in a modified file|14|▎| ff|login.js|Enter"
  "git-hunk|Git hunk preview|14|validateToken\(user\.token\);| ff|login.js|Enter|:2|Enter|wait:3: ghp"
  "git-blame|Git blame for the line|14|Git Log Line| ff|login.js|Enter|:1|Enter| gb"
  "git-status|Changed files|14|Git Status| gs"
  "git-log|Commit log|14|Git Log| gl"
  # -- editing ---------------------------------------------------------------
  "todo|TODO, FIXME and HACK comments|14|Todo Comments| st"
  "yank-history|Yank ring history|14|Yank History| ff|lib.lua|Enter|yy| sy"
  "treesitter|Syntax highlighting|14|function validateToken| ff|auth.js|Enter"
  "folds|Folded code|14|lines| ff|auth.js|Enter|zM"
  "terminal|Terminal|14|terminal works| ft|echo terminal works|Enter"
  "debug-ui|Debugger breakpoint and menu|14|➜| ff|app.py|Enter|:5|Enter| db| d"
  # -- the editor itself -----------------------------------------------------
  "lazy|Plugin manager|14|lazy.nvim| l"
  "mason|Tool installer|14|Language Filter|wait:4: cm"
  "colorscheme|Colourscheme picker|14|Colorschemes| uC"
  "health|Which language servers this project provides|14|language servers|:checkhealth dotfiles|Enter"
  "notifications|Notification history|14|Notifications| sg|validateToken|M-c|Escape|wait:2: n"
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

  # Attempts, for the same reason Neovim's own screen tests retry: a language
  # server answers when it answers. A key that does nothing fails every
  # attempt, so this hides no defect -- it only stops a slow machine from
  # reading like a broken one.
  drove=0
  for attempt in $(seq "$ATTEMPTS"); do
    if "$HERE/nvim-drive.sh" \
      -c "$CONFIG_DIR" \
      ${APPNAME:+-n "$APPNAME"} \
      -d "$WORKDIR" \
      -t -I -e -w "$wait" -p 2 \
      -o "$ansi" \
      "${keys[@]}" >/dev/null 2>&1; then
      drove=1
      sed -e 's/\x1b\[[0-9;]*m//g' "$ansi" >"$OUT_DIR/$name.drawn"
      if grep -qE -- "$expect" "$OUT_DIR/$name.drawn"; then
        break
      fi
    else
      drove=0
    fi
  done

  if [[ "$drove" -eq 1 ]]; then
    # The stripped frame is kept when the pattern is missing. Reading the
    # .ansi afterwards proves nothing: the next run of that scenario
    # overwrites it, so an inspection minutes later can show the text the
    # check did not find.
    plain="$OUT_DIR/$name.drawn"

    if grep -qE -- "$expect" "$plain"; then
      rm -f "$plain"
      CAPTURED+=("$name|$desc")
      [[ "$attempt" -gt 1 ]] && echo "captured, on attempt $attempt" || echo "captured"
    else
      echo "CAPTURED BUT EMPTY after $ATTEMPTS attempt(s): nothing matching /$expect/, frame in $plain"
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
