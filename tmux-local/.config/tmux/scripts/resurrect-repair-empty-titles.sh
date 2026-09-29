#!/usr/bin/env bash
# Repair tmux-resurrect save lines for panes whose title was empty.
#
# resurrect writes each pane as tab-separated fields and reads them back with
# `IFS=$'\t' read`. A tab is whitespace to `read`, so an empty field between
# two tabs is dropped and every field after it moves one to the left. A pane
# with an empty title (a program set it to "" with an OSC 2 sequence) is saved
# with its path in the title column and its active flag in the path column.
# On restore the "path" is 0 or 1, which is not a directory, so the pane opens
# in $HOME, and the real path turns up as the pane's title. Still unfixed
# upstream as of cff343c.
#
# Run as @resurrect-hook-post-save-layout, which is handed the file just
# written. A shifted line is the one whose path column lacks the ":" prefix
# resurrect always puts on paths. It is rebuilt with the host name as title
# (tmux's own default, and never empty, so restore reads it back correctly)
# and its full command recomputed from the pane pid that ended up in the
# command column, the same way resurrect's default "ps" strategy does.
set -u

file=${1:-}
[[ -f $file ]] || exit 0

title=$(tmux display-message -p '#{host_short}' 2>/dev/null)
[[ -n $title ]] || title=$(hostname -s)

full_command() {
	ps -ao "ppid,args" | sed "s/^ *//" | grep "^$1 " | head -n 1 | cut -d' ' -f2-
}

tmp=$(mktemp "${file}.repair.XXXXXX") || exit 0
changed=0
while IFS= read -r line || [[ -n $line ]]; do
	IFS=$'\t' read -r -a f <<<"$line"
	# Shifted: title column holds the path, path column holds the active flag,
	# and the pane pid sits where the command name should be.
	if [[ ${f[0]:-} == pane && ${#f[@]} -ge 10 && ${f[6]} == :* && ${f[7]} != :* && ${f[9]} =~ ^[0-9]+$ ]]; then
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t:%s\n' \
			"${f[0]}" "${f[1]}" "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" \
			"$title" "${f[6]}" "${f[7]}" "${f[8]}" "$(full_command "${f[9]}")" >>"$tmp"
		changed=1
	else
		printf '%s\n' "$line" >>"$tmp"
	fi
done <"$file"

if ((changed)); then
	cat "$tmp" >"$file"
fi
rm -f "$tmp"
