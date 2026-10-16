#!/usr/bin/env bash
set -Eeuo pipefail

dotfiles_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
local_bashrc="$HOME/.bashrc"
shared_bashrc="${XDG_CONFIG_HOME:-$HOME/.config}/shell/bashrc"
shared_bashrc_source_line='source "${XDG_CONFIG_HOME:-$HOME/.config}/shell/bashrc"'
any_shared_bashrc_source_line='^[[:space:]]*(source|\.)[[:space:]].*shell/bashrc'

if [[ ! -r $shared_bashrc ]]; then
	echo "$shared_bashrc is missing. Run 'stow -R bash-omb' (or bash-basic) from $dotfiles_dir first." >&2
	exit 1
fi

repo_bashrc=
repo_bashrc_at_head=
committed_repo_bashrc=
current_repo_bashrc=
if [[ -L $local_bashrc ]]; then
	link_target=$(readlink "$local_bashrc")
	[[ $link_target == /* ]] || link_target="$HOME/$link_target"
	link_target_dir=$(cd -P "$(dirname "$link_target")" 2>/dev/null && pwd -P) || link_target_dir=$(dirname "$link_target")
	repo_bashrc="$link_target_dir/$(basename "$link_target")"

	if [[ $repo_bashrc != "$dotfiles_dir"/* ]]; then
		if [[ $repo_bashrc == */bash-*/.bashrc ]]; then
			echo "$local_bashrc links into another checkout. Run $(dirname "$(dirname "$repo_bashrc")")/tools/shell/install-local-bashrc.sh instead." >&2
		else
			echo "$local_bashrc links to $repo_bashrc, outside $dotfiles_dir. Replace it with a plain file, then run this again." >&2
		fi
		exit 1
	fi

	if [[ -f $repo_bashrc ]]; then
		repo_bashrc_at_head="HEAD:${repo_bashrc#"$dotfiles_dir"/}"
		committed_repo_bashrc=$(git -C "$dotfiles_dir" show "$repo_bashrc_at_head")
		current_repo_bashrc=$(<"$repo_bashrc")
		if [[ $current_repo_bashrc != "$committed_repo_bashrc"* ]]; then
			echo "$repo_bashrc was edited, not only appended to. Move your changes out of it, then run this again." >&2
			exit 1
		fi
	fi
fi

if [[ ! -L $local_bashrc && -f $local_bashrc ]] && grep -qE "$any_shared_bashrc_source_line" "$local_bashrc"; then
	echo "$local_bashrc already loads $shared_bashrc."
	exit 0
fi

lines_appended_to_repo_bashrc=${current_repo_bashrc#"$committed_repo_bashrc"}
repo_bashrc_needs_restoring=false
if [[ -n $repo_bashrc_at_head ]] && ! git -C "$dotfiles_dir" show "$repo_bashrc_at_head" | cmp -s - "$repo_bashrc"; then
	repo_bashrc_needs_restoring=true
fi

new_local_bashrc=$(mktemp "$local_bashrc.XXXXXX")
trap 'rm -f "$new_local_bashrc"' EXIT

existing_local_bashrc=/dev/null
if [[ ! -L $local_bashrc && -f $local_bashrc ]]; then
	cp -p "$local_bashrc" "$new_local_bashrc"
	existing_local_bashrc=$local_bashrc
else
	chmod 644 "$new_local_bashrc"
fi

{
	cat "$existing_local_bashrc"
	printf '\n'
	printf '%s\n' 'case $- in' '  *i*) ;;' '  *) return ;;' 'esac' "$shared_bashrc_source_line"
	printf '%s\n' "${lines_appended_to_repo_bashrc#$'\n'}"
} >"$new_local_bashrc"

mv -f "$new_local_bashrc" "$local_bashrc"
trap - EXIT

if [[ $repo_bashrc_needs_restoring == true ]]; then
	git -C "$dotfiles_dir" show "$repo_bashrc_at_head" >"$repo_bashrc"
	echo "Moved what was appended to $repo_bashrc into $local_bashrc, and restored $repo_bashrc."
fi
echo "$local_bashrc now loads $shared_bashrc. It belongs to this machine: installers can append to it freely."
