# Environment that is true on every machine this repo is cloned to.
# Anything that names a host, a mount point or a cluster belongs in
# ~/.config/shell/hosts/<hostname>.sh instead.

# Preferred editor for local and remote sessions.
export EDITOR='nvim'
export VISUAL='nvim'

# Neovim installed from the upstream tarball rather than a package manager.
if [[ -d /opt/nvim ]]; then
  export PATH="$PATH:/opt/nvim"
fi

# User binaries take precedence over system ones, without stacking duplicates
# every time a subshell re-reads this file.
BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) export PATH="$BINDIR:$PATH" ;;
esac
unset BINDIR
