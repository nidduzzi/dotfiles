#!/usr/bin/env bash
# Open the branch's editor in a project, without touching ~/.config/nvim.
#
# Usage:
#   try.sh [DIR] [nvim args ...]
set -Eeuo pipefail

CONFIG_DIR="${NVIM_TOUR_CONFIG:-$HOME/dotfiles/.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

if [[ ! -d "$CONFIG_DIR/$APPNAME" ]]; then
  echo "No configuration at $CONFIG_DIR/$APPNAME." >&2
  echo "Point NVIM_TOUR_CONFIG at the directory holding it, or make the link:" >&2
  echo "  mkdir -p $CONFIG_DIR && ln -s <the worktree> $CONFIG_DIR/$APPNAME" >&2
  exit 2
fi

WHERE="${1:-$PWD}"
[[ $# -gt 0 ]] && shift

cd "$WHERE"
exec env XDG_CONFIG_HOME="$CONFIG_DIR" NVIM_APPNAME="$APPNAME" nvim "$@"
