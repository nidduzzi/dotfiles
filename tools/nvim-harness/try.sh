#!/usr/bin/env bash
# Open the branch's editor, in a project, without touching ~/.config/nvim.
#
# The configuration under test is a worktree, reached through an
# XDG_CONFIG_HOME that contains one symlink named after NVIM_APPNAME. That
# keeps state separate too: plugins, shada and swap all live under
# ~/.local/share/nvim-lazyvim rather than mixing with the everyday editor's.
#
# This is the same pair of environment variables every script in here uses to
# drive the editor, so what you get by hand is what the films recorded.
#
# Usage:
#   try.sh [DIR] [nvim args ...]    open DIR, or the current directory
#
# The agent's endpoint comes from the environment, as everywhere else:
#   CUSTOM_BASE_URL  CUSTOM_API_KEY  HERMES_ALLOW_PRIVATE_URLS
#   HERMES_INFERENCE_PROVIDER  HERMES_INFERENCE_MODEL
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
