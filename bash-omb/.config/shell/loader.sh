# Load the shell configuration in three tiers, least specific first, so a later
# tier can always override an earlier one:
#
#   1. shared/   committed, applies to every machine
#   2. hosts/    committed, applies to one named machine
#   3. local/    never committed, throwaway settings for right now
#
# Tiers 1 and 2 are stowed out of the dotfiles repo. Tier 3 is a plain
# directory that the repo does not track at all, so nothing there can leak
# into a commit by accident.

__shell_config_home="${XDG_CONFIG_HOME:-$HOME/.config}/shell"

__shell_source_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  local fragment
  for fragment in "$dir"/*.sh; do
    # An unmatched glob stays literal, so check the file really exists.
    [[ -r "$fragment" ]] || continue
    # shellcheck source=/dev/null
    . "$fragment"
  done
}

__shell_source_dir "$__shell_config_home/shared"

# Host tier. `hostname -s` is not available everywhere, so fall back to the
# shell's own idea of the host name with any domain suffix removed.
__shell_host="$(hostname -s 2>/dev/null || echo "${HOSTNAME%%.*}")"
if [[ -r "$__shell_config_home/hosts/$__shell_host.sh" ]]; then
  # shellcheck source=/dev/null
  . "$__shell_config_home/hosts/$__shell_host.sh"
fi

__shell_source_dir "$__shell_config_home/local"

# Kept for machines set up before the local/ directory existed.
if [[ -r "$HOME/.bashrc_local" ]]; then
  # shellcheck source=/dev/null
  . "$HOME/.bashrc_local"
fi

unset -f __shell_source_dir
unset __shell_config_home __shell_host
