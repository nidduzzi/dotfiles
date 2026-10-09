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

shell_inert_command_pattern='^[A-Za-z0-9 ._/:=@%+-]+$'
non_whitespace_separator=$'\x1f'

rewritten_file=$(mktemp "$save_file.repair.XXXXXX") || exit 0
trap 'rm -f "$rewritten_file"' EXIT

rewritten_lines=0
while IFS= read -r line || [[ -n $line ]]; do
	IFS=$non_whitespace_separator read -r kind session window window_active window_flags pane_index \
		title path pane_active pane_command full_command extra_fields <<<"${line//$'\t'/$non_whitespace_separator}"
	line_rewritten=false

	if [[ $kind == pane && -z $extra_fields && $full_command == :* &&
		$title == :* && $path == [01] && $pane_command =~ ^[0-9]+$ ]]; then
		recovered_pane_pid=$pane_command
		pane_command=$pane_active
		pane_active=$path
		path=$title
		title=$placeholder_title
		recomputed_full_command=
		if [[ -x $command_strategy_file ]]; then
			recomputed_full_command=$("$command_strategy_file" "$recovered_pane_pid" 2>/dev/null | head -n 1)
		fi
		full_command=":$recomputed_full_command"
		line_rewritten=true
	fi

	if [[ $kind == pane && -z $extra_fields && $full_command == :* && $path == :* ]]; then
		restore_command=$(tmux display-message -p -t "=$session:$window.$pane_index" '#{@resurrect-restore-command}' 2>/dev/null)
		if [[ $restore_command =~ $shell_inert_command_pattern && ${restore_command%% *} == "$pane_command" ]]; then
			full_command=":$restore_command"
			line_rewritten=true
		fi
	fi

	if [[ $line_rewritten == true ]]; then
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$kind" "$session" "$window" "$window_active" "$window_flags" "$pane_index" \
			"$title" "$path" "$pane_active" "$pane_command" "$full_command" >>"$rewritten_file"
		rewritten_lines=$((rewritten_lines + 1))
	else
		printf '%s\n' "$line" >>"$rewritten_file"
	fi
done <"$save_file"

((rewritten_lines > 0)) && mv -f "$rewritten_file" "$save_file"
exit 0
