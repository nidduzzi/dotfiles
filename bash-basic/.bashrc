case $- in
  *i*) ;;
  *) return ;;
esac
__dotfiles_stub=$(readlink "${BASH_SOURCE[0]}" || printf '%s' "${BASH_SOURCE[0]}")
[[ $__dotfiles_stub == /* ]] || __dotfiles_stub="$(dirname "${BASH_SOURCE[0]}")/$__dotfiles_stub"
source "$(dirname "$__dotfiles_stub")/.config/shell/bashrc"
unset __dotfiles_stub
