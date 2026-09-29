#!/usr/bin/env bash
set -u

save_file=${1:-}
[[ -f $save_file ]] || exit 0

placeholder_title=$(tmux display-message -p '#{host_short}' 2>/dev/null)
[[ -n $placeholder_title ]] || placeholder_title=$(hostname -s)

resurrect_scripts_dir=$(dirname "$(tmux show-option -gqv @resurrect-save-script-path)")
command_strategy=$(tmux show-option -gqv @resurrect-save-command-strategy)
command_strategy_file="$resurrect_scripts_dir/../save_command_strategies/${command_strategy:-ps}.sh"
[[ -x $command_strategy_file ]] || command_strategy_file="$resurrect_scripts_dir/../save_command_strategies/ps.sh"

repaired_file=$(mktemp "$save_file.repair.XXXXXX") || exit 0
trap 'rm -f "$repaired_file"' EXIT

repaired_lines=0
while IFS= read -r line || [[ -n $line ]]; do
	IFS=$'\t' read -r kind session window window_active window_flags pane_index path pane_active pane_command pane_pid _ <<<"$line"
	if [[ $kind == pane && $path == :* && $pane_active == [01] && $pane_pid =~ ^[0-9]+$ ]]; then
		full_command=$("$command_strategy_file" "$pane_pid" | head -n 1)
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t:%s\n' \
			"$kind" "$session" "$window" "$window_active" "$window_flags" "$pane_index" \
			"$placeholder_title" "$path" "$pane_active" "$pane_command" "$full_command" >>"$repaired_file"
		repaired_lines=$((repaired_lines + 1))
	else
		printf '%s\n' "$line" >>"$repaired_file"
	fi
done <"$save_file"

((repaired_lines > 0)) && mv -f "$repaired_file" "$save_file"
exit 0
