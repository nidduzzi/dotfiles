#!/usr/bin/env bash
set -Eeuo pipefail

# The GNOME choices that stow cannot carry, because they live in dconf and not
# in a file under $HOME. Only the keys named here are written: dconf write
# leaves the rest of the database alone.
#
# PaperWM keeps a long restore-keybinds blob and similar bookkeeping under its
# own path. That is runtime state, so it is deliberately not listed.
#
#   Super+V   opens the GPaste history. GNOME's notification panel gave up
#             Super+V (it keeps Super+M), and PaperWM's centre-vertically moved
#             to Super+Shift+V.
#   Super+O   never reached PaperWM (GNOME's rotation lock defaults to that
#             key, the likely cause), so PaperWM's barf-out lives on Super+Alt+O.
settings=(
	"/org/gnome/shell/keybindings/toggle-message-tray|['<Super>m']"
	"/org/gnome/GPaste/show-history|'<Super>v'"
	"/org/gnome/shell/extensions/paperwm/keybindings/center-vertically|['<Super><Shift>v']"
	"/org/gnome/shell/extensions/paperwm/keybindings/barf-out|['<Super><Alt>o']"
)

# Turned on when installed. Installing them is not done here: GPaste and
# appindicator come from dnf, PaperWM from its source or extensions.gnome.org.
extensions=(
	appindicatorsupport@rgcjonas.gmail.com
	GPaste@gnome-shell-extensions.gnome.org
	paperwm@paperwm.github.com
	fresh-web-wallpaper@framagit.org
)

dry_run=false
case ${1:-} in
	-n | --dry-run) dry_run=true ;;
	'') ;;
	*)
		echo "usage: ${0##*/} [-n|--dry-run]" >&2
		exit 2
		;;
esac

for tool in dconf gsettings; do
	if ! command -v "$tool" >/dev/null; then
		echo "$tool is missing, so there is nothing to apply here." >&2
		exit 1
	fi
done

run() {
	if [[ $dry_run == true ]]; then
		printf 'would run:'
		printf ' %q' "$@"
		printf '\n'
	else
		"$@"
	fi
}

for entry in "${settings[@]}"; do
	key=${entry%%|*}
	value=${entry#*|}
	echo "$key = $value"
	run dconf write "$key" "$value"
done

extension_dirs=(
	"${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions"
	/usr/share/gnome-shell/extensions
)
enabled=$(gsettings get org.gnome.shell enabled-extensions)
new_enabled=$enabled
for uuid in "${extensions[@]}"; do
	installed=false
	for dir in "${extension_dirs[@]}"; do
		[[ -d $dir/$uuid ]] && installed=true
	done
	if [[ $installed == false ]]; then
		echo "not installed, skipped: $uuid"
	elif [[ $new_enabled == *"'$uuid'"* ]]; then
		echo "already enabled: $uuid"
	else
		echo "enabling: $uuid"
		if [[ $new_enabled == '@as []' || $new_enabled == '[]' ]]; then
			new_enabled="['$uuid']"
		else
			new_enabled="${new_enabled%]}, '$uuid']"
		fi
	fi
done
if [[ $new_enabled != "$enabled" ]]; then
	run gsettings set org.gnome.shell enabled-extensions "$new_enabled"
	echo "Log out and back in so GNOME Shell loads what was just enabled."
fi
