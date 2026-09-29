#!/usr/bin/env bash
set -u

save_file=${1:-}
[[ -f $save_file ]] || exit 0

placeholder_title=$(tmux display-message -p '#{host_short}' 2>/dev/null)
[[ -n $placeholder_title ]] || placeholder_title=$(hostname -s)

resurrect_save_script=$(tmux show-option -gqv @resurrect-save-script-path)
command_strategy=$(tmux show-option -gqv @resurrect-save-command-strategy)
[[ $command_strategy =~ ^[a-z_]+$ ]] || command_strategy="ps"
command_strategy_file=
if [[ $resurrect_save_script == /* ]]; then
	resurrect_dir=$(dirname "$(dirname "$resurrect_save_script")")
	command_strategy_file="$resurrect_dir/save_command_strategies/$command_strategy.sh"
fi

repaired_file=$(mktemp "$save_file.repair.XXXXXX") || exit 0
trap 'rm -f "$repaired_file"' EXIT

non_whitespace_separator=$'\x1f'
repaired_lines=0
while IFS= read -r line || [[ -n $line ]]; do
	IFS=$non_whitespace_separator read -r kind session window window_active window_flags pane_index \
		title path pane_active pane_command full_command extra_fields <<<"${line//$'\t'/$non_whitespace_separator}"

	if [[ $kind == pane && -z $extra_fields && $full_command == :* &&
		$title == :* && $path == [01] && $pane_command =~ ^[0-9]+$ ]]; then
		recovered_path=$title
		recovered_pane_active=$path
		recovered_pane_command=$pane_active
		recovered_pane_pid=$pane_command
		recomputed_full_command=
		if [[ -x $command_strategy_file ]]; then
			recomputed_full_command=$("$command_strategy_file" "$recovered_pane_pid" 2>/dev/null | head -n 1)
		fi
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t:%s\n' \
			"$kind" "$session" "$window" "$window_active" "$window_flags" "$pane_index" \
			"$placeholder_title" "$recovered_path" "$recovered_pane_active" "$recovered_pane_command" \
			"$recomputed_full_command" >>"$repaired_file"
		repaired_lines=$((repaired_lines + 1))
	else
		printf '%s\n' "$line" >>"$repaired_file"
	fi
done <"$save_file"

((repaired_lines > 0)) && mv -f "$repaired_file" "$save_file"
exit 0
