#!/usr/bin/env bash
# Try to crash a tmux server with sixel graphics, without risking real work.
#
# Symptom being chased: launching Neovim inside tmux kills the tmux server, so
# every session on it dies at once and the terminal is left showing raw sixel.
# A tmux built with sixel support parses image data itself, and a crash in that
# parser takes down the server process, which is why unrelated sessions die too.
#
# This script runs against its own socket name, so a crash here cannot touch
# the sessions you are working in.
#
# Usage:
#   sixel-crash-repro.sh [-p on|off] [-n COUNT] [-w WIDTH] [-h HEIGHT]
#
#   -p  allow-passthrough setting to test. Default: on.
#   -n  how many images to send. Default: 40.
#   -w  image width in pixels.  Default: 800.
#   -h  image height in pixels. Default: 600.
set -Eeuo pipefail

SOCKET="sixel-repro"
PASSTHROUGH="on"
COUNT=40
WIDTH=800
HEIGHT=600

while getopts "p:n:w:h:" opt; do
  case "$opt" in
    p) PASSTHROUGH="$OPTARG" ;;
    n) COUNT="$OPTARG" ;;
    w) WIDTH="$OPTARG" ;;
    h) HEIGHT="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

tm() { tmux -L "$SOCKET" "$@"; }

cleanup() { tm kill-server 2>/dev/null || true; }
trap cleanup EXIT

echo "tmux: $(tmux -V)"
if strings "$(command -v tmux)" 2>/dev/null | grep -qx 'sixel_parse'; then
  echo "build: compiled WITH sixel support (tmux parses image data itself)"
else
  echo "build: no sixel support (image data is passed through untouched)"
fi
echo "allow-passthrough: $PASSTHROUGH"
echo "sending $COUNT sixel images of ${WIDTH}x${HEIGHT}"
echo

tm kill-server 2>/dev/null || true
# The first window just sleeps. Without it, a pane that finishes would end the
# session and shut the server down on purpose, which looks exactly like a crash
# from the outside and would make this script report a false positive.
tm -f /dev/null new-session -d -x 200 -y 50 "sleep 86400"
tm set -g allow-passthrough "$PASSTHROUGH"
tm set -g remain-on-exit on

server_pid=$(tm display -p '#{pid}')
echo "server pid: $server_pid"

payload=$(mktemp)
trap 'rm -f "$payload"; cleanup' EXIT

# Build one sixel image and wrap it for tmux passthrough. In a passthrough
# sequence every ESC in the payload must be doubled, or tmux ends the sequence
# early and the rest paints onto the terminal as text.
python3 - "$WIDTH" "$HEIGHT" >"$payload" <<'PY'
import sys

width, height = int(sys.argv[1]), int(sys.argv[2])
bands = max(1, height // 6)

out = ["\x1bPq", f'"1;1;{width};{height}']
for band in range(bands):
    out.append("#%d;2;%d;%d;%d" % (band % 16, band % 100, (band * 3) % 100, (band * 7) % 100))
    out.append("#%d" % (band % 16))
    out.append("~" * width)
    out.append("$-")
out.append("\x1b\\")
image = "".join(out)

# tmux passthrough wrapper: ESC P tmux ; <payload with ESC doubled> ESC \
sys.stdout.write("\x1bPtmux;" + image.replace("\x1b", "\x1b\x1b") + "\x1b\\")
PY

echo "payload: $(wc -c <"$payload") bytes"

for i in $(seq 1 "$COUNT"); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo
    echo "RESULT: server died after $((i - 1)) image(s). Crash reproduced."
    exit 1
  fi
  # The bytes have to come out of a program running in the pane, because that
  # is the only path tmux parses. Writing them to the pane's stdin instead
  # would just hand them to the shell as keystrokes and test nothing. Each
  # image goes to a throwaway window so the session itself always survives.
  tm new-window -d "cat '$payload'; sleep 86400" 2>/dev/null || true
  sleep 0.3
  tm kill-window -t '{end}' 2>/dev/null || true
done

sleep 1
if kill -0 "$server_pid" 2>/dev/null; then
  echo
  echo "RESULT: server survived $COUNT image(s)."
  exit 0
fi

echo
echo "RESULT: server died after the final image. Crash reproduced."
exit 1
