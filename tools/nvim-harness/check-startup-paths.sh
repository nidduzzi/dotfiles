#!/usr/bin/env bash
# The trust question appears on both ways into a project.
#
# There are two, and they are not the same startup: opening the editor and
# then a file, and naming the file on the command line. LazyVim loads its
# autocmds eagerly when a file is named and lazily when one is not, so a
# handler can exist on one path and be missing on the other --- which is how
# the first two versions of this prompt came to do nothing at all, silently.
#
# Usage:
#   check-startup-paths.sh [-c CONFIG_DIR] [-n APPNAME]
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

while getopts "c:n:" opt; do
  case "$opt" in
    c) CONFIG_DIR="$OPTARG" ;;
    n) APPNAME="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

# A repository of its own, so the answer does not depend on what this machine
# has been told about the fixture.
PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT

mkdir -p "$PROJECT/src"
printf 'local M = {}\nreturn M\n' > "$PROJECT/src/lib.lua"
git -C "$PROJECT" init -q -b main
git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@e.invalid -c user.name=t commit -qm init

asks() {
  "$HERE/nvim-drive.sh" \
    -c "$CONFIG_DIR" -n "$APPNAME" -d "$PROJECT" -I -w 60 -p 3 \
    "$@" 2>/dev/null |
    sed -e 's/\x1b\[[0-9;]*m//g' |
    grep -c "Trust this project" || true
}

status=0

# Named on the command line: the file is read during startup.
if [[ "$(asks -a src/lib.lua 'wait:5:ex:echo ""')" -eq 0 ]]; then
  echo "  a file named on the command line was not asked about"
  status=1
fi

# Opened afterwards, from the picker, which is the other way in.
if [[ "$(asks ' ff' 'lib.lua' 'wait:5:Enter')" -eq 0 ]]; then
  echo "  a file opened from the picker was not asked about"
  status=1
fi

# And nothing at all once the project is trusted.
# NVIM_APPNAME and XDG_CONFIG_HOME matter here: the trust store lives under
# stdpath("state"), which is per app name. Without them this writes to a
# different store and the editor under test never sees it.
env NVIM_APPNAME="$APPNAME" XDG_CONFIG_HOME="$CONFIG_DIR" \
  nvim --headless -u NONE \
  --cmd "set runtimepath+=$CONFIG_DIR/$APPNAME" \
  +"lua require('util.trust').allow('$PROJECT')" +qa 2>/dev/null

if [[ "$(asks -a src/lib.lua 'wait:5:ex:echo ""')" -ne 0 ]]; then
  echo "  a trusted project was asked about anyway"
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "Asked on both ways in, and silent once trusted."
fi
exit "$status"
