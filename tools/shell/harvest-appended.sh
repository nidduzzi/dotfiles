#!/usr/bin/env bash
# Move anything an installer appended to the shared .bashrc into a tier where
# it belongs, and leave the shared file clean again.
#
# ~/.bashrc is a symlink into the dotfiles repo, so `curl | sh` installers that
# append their setup lines are writing into config that every machine shares.
# The append guard at the bottom of .bashrc marks where that starts. This
# script cuts everything after the marker and writes it to the chosen tier.
#
# Usage:
#   harvest-appended.sh              # move to the local tier (never committed)
#   harvest-appended.sh --host       # move to this machine's committed tier
#   harvest-appended.sh --show       # print what was appended, change nothing
set -Eeuo pipefail

MARKER='# >>> appended-below-here >>>'
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASHRC="$DOTFILES_DIR/bash-omb/.bashrc"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/shell"
HOST="$(hostname -s 2>/dev/null || echo "${HOSTNAME%%.*}")"

mode="local"
case "${1:-}" in
  --host) mode="host" ;;
  --show) mode="show" ;;
  "") ;;
  *)
    echo "Unknown option: $1" >&2
    exit 2
    ;;
esac

[[ -f "$BASHRC" ]] || { echo "Not found: $BASHRC" >&2; exit 1; }

marker_line=$(grep -nF "$MARKER" "$BASHRC" | head -1 | cut -d: -f1 || true)
[[ -n "$marker_line" ]] || { echo "Append guard marker missing from $BASHRC" >&2; exit 1; }

appended=$(tail -n "+$((marker_line + 1))" "$BASHRC")

# Only whitespace after the marker means there is nothing to harvest.
if [[ -z "${appended//[[:space:]]/}" ]]; then
  echo "Nothing appended. Shared .bashrc is clean."
  exit 0
fi

if [[ "$mode" == "show" ]]; then
  echo "Appended after the guard in $BASHRC:"
  echo "---"
  printf '%s\n' "$appended"
  exit 0
fi

if [[ "$mode" == "host" ]]; then
  dest="$DOTFILES_DIR/bash-omb/.config/shell/hosts/$HOST.sh"
  note="committed, machine $HOST"
else
  dest="$CONFIG_HOME/local/90-harvested.sh"
  note="never committed"
fi

mkdir -p "$(dirname "$dest")"
{
  printf '\n# Harvested from ~/.bashrc on %s.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$appended"
} >>"$dest"

# Truncate the shared file back to the marker.
head -n "$marker_line" "$BASHRC" >"$BASHRC.harvest-tmp"
mv "$BASHRC.harvest-tmp" "$BASHRC"

echo "Moved $(printf '%s\n' "$appended" | grep -c . || true) line(s) to:"
echo "  $dest   ($note)"
echo "Shared .bashrc is clean again. Open a new shell to pick up the change."
