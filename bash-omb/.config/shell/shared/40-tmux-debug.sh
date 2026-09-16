# Start the tmux server with logging, so that its next death explains itself.
#
# `tmux -vv` writes tmux-server-<pid>.log and tmux-client-<pid>.log into the
# process's current directory, so it cannot simply be aliased: every `tmux ls`
# would drop log files wherever you happened to be standing, and starting the
# server from a log directory would make new sessions open there. The server
# has to be started from the log directory while the client attaches from where
# you actually are.
#
#   tmux-debug          start a logged server if needed, then attach
#   tmux-debug-status   where the logs are, and whether logging is on
#   tmux-debug-off      go back to a normal server
#
# Logging costs disk: a busy server writes tens of megabytes an hour, because
# every escape sequence it parses is recorded. That is the point, but do not
# leave it on once the fault is understood.

tmux-debug() {
  local log_root="$HOME/.cache/tmux-crash"
  local run_dir="$log_root/run-$(date -u +%Y%m%d-%H%M%S)"

  if command tmux has-session 2>/dev/null; then
    echo "A tmux server is already running, and logging can only be turned on"
    echo "when the server starts. Detach, then:"
    echo
    echo "  tmux kill-server && tmux-debug"
    echo
    echo "Attaching to the existing server instead."
    command tmux attach
    return
  fi

  # Remember where you are before the subshell changes directory, or the new
  # session starts in the log directory instead of your work.
  local start_dir="$PWD"

  mkdir -p "$run_dir"

  # Record what the terminal claims to be. The fault only appears with a real
  # terminal attached, so which one it was matters when reading the log later.
  {
    echo "tmux: $(command tmux -V)"
    echo "TERM: ${TERM:-unset}"
    echo "TERM_PROGRAM: ${TERM_PROGRAM:-unset}"
    echo "SSH_CONNECTION: ${SSH_CONNECTION:-none}"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$run_dir/environment.txt"

  # Start the server from the log directory, but give the session the directory
  # you are standing in, so nothing opens in the log directory by mistake.
  (cd "$run_dir" && command tmux -vv new-session -d -s main -c "$start_dir") ||
    {
      echo "Could not start a logged tmux server" >&2
      return 1
    }

  ln -sfn "$run_dir" "$log_root/latest"
  echo "Logging this server to $run_dir"

  command tmux attach -t main
}

tmux-debug-status() {
  local log_root="$HOME/.cache/tmux-crash"
  local latest="$log_root/latest"

  if [[ ! -e "$latest" ]]; then
    echo "No logged tmux server has been started yet."
    return
  fi

  echo "Latest run: $(readlink -f "$latest")"
  du -sh "$(readlink -f "$latest")" 2>/dev/null
  echo
  cat "$(readlink -f "$latest")/environment.txt" 2>/dev/null
  echo
  if command tmux has-session 2>/dev/null; then
    local server_pid
    server_pid="$(command tmux display -p '#{pid}' 2>/dev/null)"
    if ls /proc/"$server_pid"/fd/* 2>/dev/null | head -1 >/dev/null &&
      grep -q -- "-vv" "/proc/$server_pid/cmdline" 2>/dev/null; then
      echo "The running server IS logging."
    else
      echo "The running server is NOT logging. Restart it with tmux-debug."
    fi
  else
    echo "No server is running."
  fi
}

tmux-debug-off() {
  echo "This kills the tmux server and every session on it."
  echo "Sessions are saved by tmux-resurrect, so continuum will restore them."
  read -r -p "Kill the server and start a normal one? [y/N] " reply
  case "$reply" in
    [yY]*)
      command tmux kill-server 2>/dev/null
      command tmux new-session -d -s main -c "$PWD"
      command tmux attach -t main
      ;;
    *) echo "Left alone." ;;
  esac
}

# What to read after a death. The server log's last lines name the escape
# sequence tmux was parsing when it stopped.
tmux-debug-last() {
  local latest="$HOME/.cache/tmux-crash/latest"
  [[ -e "$latest" ]] || { echo "No logged run yet."; return 1; }
  tail -n "${1:-40}" "$(readlink -f "$latest")"/tmux-server-*.log
}
