#!/usr/bin/env bash
# Find key batches that tmux would read as a key name rather than as text
# (DC/IC etc. resolve to key names, case-insensitively, before text).
#
# Usage:
#   check-key-names.sh [DIR ...]      default: this directory and the screens
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ROOT="${NVIM_TOUR_CONFIG:-$HERE/../../.worktrees/cfg}"
APPNAME="${NVIM_TOUR_APPNAME:-nvim-lazyvim}"

command -v tmux >/dev/null || { echo "tmux is required" >&2; exit 1; }

SOCKET="key-name-check-$$"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"' EXIT

tmux -L "$SOCKET" -f /dev/null new-session -d -x 60 -y 6 "cat -v"
sleep 0.5

emits_escape() {
  tmux -L "$SOCKET" send-keys -- "$1" 2>/dev/null || return 1
  sleep 0.25
  local seen
  seen="$(tmux -L "$SOCKET" capture-pane -p | tr -d '\n')"
  tmux -L "$SOCKET" send-keys C-u 2>/dev/null
  sleep 0.1
  [[ "$seen" == *'^['* ]]
}

REPORT="$(mktemp)"
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -f "$REPORT" "$REPORT.tokens" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"' EXIT

{
  grep -rhoE "'(keys:)?[A-Za-z][A-Za-z0-9?$-]{0,12}'" "$HERE"/*.sh |
    tr -d "'" | sed 's/^keys://'
  find "$CONFIG_ROOT/$APPNAME/tests/screen" -name '*.keys' -exec cat {} + 2>/dev/null |
    grep -v '^#' | grep -v '^[[:space:]]*$' | sed 's/^keys://'
} | tr ' ' '\n' | sort -u > "$REPORT.tokens"

while IFS= read -r token; do
  [[ -z "$token" ]] && continue
  case "$token" in
    Space|Enter|Escape|Tab|BSpace|BTab|Up|Down|Left|Right|Home|End|PageUp|PageDown|IC|DC|NPage|PPage) continue ;;
    C-*|M-*|S-*|F[0-9]|F1[0-2]) continue ;;
  esac

  if emits_escape "$token"; then
    printf '  %s is sent as a key by tmux, not as the characters\n' "$token" >> "$REPORT"
  fi
done < "$REPORT.tokens"

echo "checked $(wc -l < "$REPORT.tokens") batch spellings"
rm -f "$REPORT.tokens"
if [[ -s "$REPORT" ]]; then
  cat "$REPORT"
  echo
  echo "$(wc -l < "$REPORT") batch(es) would be sent as a key rather than as text."
  echo "The drivers send text with -l, so this is about how a batch reads:"
  echo "name the key deliberately, or keep it as text."
  exit 1
fi

echo "No batch collides with a tmux key name."
