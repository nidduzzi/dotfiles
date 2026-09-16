#!/usr/bin/env bash
# Run a tmux server that records enough to explain its own death.
#
# When the tmux server process dies, every session on that socket dies with it,
# and whatever half-drawn escape sequences were in flight are left on the
# terminal. That looks dramatic but says nothing about the cause. This wrapper
# starts a server with verbose logging and core dumps enabled, so the next
# occurrence leaves evidence behind instead of just a mess.
#
# Usage:
#   crash-capture.sh [-s SOCKET] [command ...]
#
#   -s SOCKET   socket name to use. Default: capture.
#
# With no command it starts a shell. Logs land in ~/.cache/tmux-crash/.
#
# Reading the evidence afterwards:
#   ls -t ~/.cache/tmux-crash/          newest run first
#   tail -50 ~/.cache/tmux-crash/<run>/tmux-server-*.log
#   coredumpctl list tmux              if systemd-coredump is installed
#   ls /var/crash/                     on Ubuntu, where apport writes
set -Eeuo pipefail

SOCKET="capture"
while getopts "s:" opt; do
  case "$opt" in
    s) SOCKET="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))

RUN_DIR="$HOME/.cache/tmux-crash/$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"

echo "Logging this tmux server to: $RUN_DIR"
echo

# tmux -vv writes tmux-server-<pid>.log and tmux-client-<pid>.log into the
# current directory, so start from the run directory.
cd "$RUN_DIR"

# Core dumps are usually off by default. This only affects processes started
# from this shell, and the core lands wherever /proc/sys/kernel/core_pattern
# points, which on Ubuntu is apport.
ulimit -c unlimited || echo "Could not raise the core dump limit." >&2

{
  echo "tmux version: $(tmux -V)"
  echo "socket: $SOCKET"
  echo "core_pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
  echo "core limit: $(ulimit -c)"
  echo "TERM outside tmux: ${TERM:-unset}"
  echo "TERM_PROGRAM: ${TERM_PROGRAM:-unset}"
  echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$RUN_DIR/environment.txt"

tmux -vv -L "$SOCKET" new-session "$@"
status=$?

{
  echo "exited: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "client exit status: $status"
} >>"$RUN_DIR/environment.txt"

echo
echo "Session ended (status $status). Evidence in $RUN_DIR:"
ls -la "$RUN_DIR"
exit "$status"
