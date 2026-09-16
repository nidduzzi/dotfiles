#!/usr/bin/env bash
# Try to kill a tmux server by starting Neovim in it, repeatedly.
#
# The reported trigger is specific: the server dies while Neovim is starting,
# never once Neovim is up, and never with other programs. Neovim's startup is
# also the only time it interrogates the terminal, with DA1, DA2, XTVERSION,
# XTGETTCAP, an OSC 11 background query and a kitty keyboard query. tmux parses
# both those queries and the terminal's replies, so that is where to look.
#
# This runs against its own socket name, so a death here cannot touch real
# sessions. It uses the real tmux and Neovim configuration on purpose: a
# reproduction with -f /dev/null would be testing something else.
#
# Usage:
#   nvim-startup-repro.sh [-n RUNS] [-w SECS] [-e on|off] [-k] [-f TMUX_CONF]
#
#   -n RUNS   how many times to start Neovim. Default: 20.
#   -w SECS   seconds to let Neovim start before killing it. Default: 4.
#   -e on|off override the extended-keys setting for the run.
#   -k        kill Neovim and reuse the server, instead of a fresh server each
#             run. Closer to "open, quit, open again", which is when it bites.
#   -f CONF   tmux config to use. Default: the real ~/.tmux.conf.
set -Eeuo pipefail

SOCKET="nvim-crash-repro"
RUNS=20
WAIT=4
EXTENDED_KEYS=""
REUSE=0
TMUX_CONF="$HOME/.tmux.conf"

while getopts "n:w:e:kf:" opt; do
  case "$opt" in
    n) RUNS="$OPTARG" ;;
    w) WAIT="$OPTARG" ;;
    e) EXTENDED_KEYS="$OPTARG" ;;
    k) REUSE=1 ;;
    f) TMUX_CONF="$OPTARG" ;;
    *) exit 2 ;;
  esac
done

LOG_DIR="$HOME/.cache/tmux-crash/nvim-repro-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

tm() { tmux -L "$SOCKET" "$@"; }

cleanup() { tm kill-server 2>/dev/null || true; }
trap cleanup EXIT

echo "tmux:   $(tmux -V)"
echo "nvim:   $(nvim --version | head -1)"
echo "config: $TMUX_CONF"
echo "logs:   $LOG_DIR"
echo "runs:   $RUNS, $([[ $REUSE -eq 1 ]] && echo 'one server reused' || echo 'fresh server each run')"
echo

start_server() {
  tm kill-server 2>/dev/null || true
  # -vv makes the server log every escape sequence it parses, which is the
  # evidence needed if it dies mid-startup.
  (cd "$LOG_DIR" && tmux -vv -L "$SOCKET" -f "$TMUX_CONF" new-session -d -x 200 -y 50 "sleep 86400")
  sleep 2
  [[ -n "$EXTENDED_KEYS" ]] && tm set -g extended-keys "$EXTENDED_KEYS"
  tm display -p '#{pid}'
}

server_pid="$(start_server)"
echo "server pid: $server_pid"
echo "extended-keys: $(tm show -gv extended-keys 2>/dev/null)"
echo

for i in $(seq 1 "$RUNS"); do
  if [[ "$REUSE" -eq 0 && "$i" -gt 1 ]]; then
    server_pid="$(start_server)"
  fi

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "run $i: server already gone before starting Neovim"
    break
  fi

  printf 'run %2d: starting nvim ... ' "$i"
  tm new-window -d "nvim" 2>/dev/null || true
  sleep "$WAIT"

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "SERVER DIED"
    echo
    echo "Last lines of the server log:"
    tail -40 "$LOG_DIR"/tmux-server-*.log 2>/dev/null
    echo
    echo "Full logs kept in $LOG_DIR"
    exit 1
  fi

  # Quit Neovim the way a person would, so the next run starts from the same
  # state the report describes: opened, quit, opened again.
  tm send-keys -t '{end}' Escape 2>/dev/null || true
  tm send-keys -t '{end}' ':qa!' Enter 2>/dev/null || true
  sleep 1

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "SERVER DIED (while quitting)"
    tail -40 "$LOG_DIR"/tmux-server-*.log 2>/dev/null
    exit 1
  fi

  echo "survived"
done

echo
echo "RESULT: server survived $RUNS Neovim start(s)."
echo "Logs in $LOG_DIR"
