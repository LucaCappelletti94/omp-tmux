#!/usr/bin/env bats

load helpers

pair_fixture() {
	start_session 0 3 7
	: "${session_id:?}"
	local target label
	for target in 0 3; do
		if [ "$target" = 0 ]; then label=alpha; else label=bravo; fi
		inner respawn-pane -k -t "proof:$target" "while printf '$label> '; do IFS= read -r reply || exit; printf '$label accepted [%s]\\n' \"\$reply\"; done"
	done
	title 0 'π > ALPHA: First endpoint'
	title 3 'π > BRAVO: Second endpoint'
	alpha_pane=$(inner display-message -p -t proof:0 '#{pane_id}')
	bravo_pane=$(inner display-message -p -t proof:3 '#{pane_id}')
	original_windows=$(source_windows)
	original_alpha=$(source_identity "$alpha_pane")
	original_bravo=$(source_identity "$bravo_pane")
	attach a 132 32
	eventually shows a 'alpha>'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	eventually shows a 'First endpoint'
	eventually shows a 'Second endpoint'
}

source_windows() { inner list-windows -t proof -F '#{window_index} #{window_id}'; }
source_identity() { inner display-message -p -t "$1" '#{window_id} #{pane_id} #{pane_pid}'; }

private_links() {
	local private
	while IFS= read -r private; do
		[ "$private" != "$session_id" ] || continue
		inner list-windows -t "$private" -F '#{window_id}' | paste -sd ',' -
	done < <(inner list-sessions -F '#{session_id}') | sort
}

open_pair() {
	outer send-keys -l -t a BRAVO
	eventually hides a 'First endpoint'
	eventually shows a 'Second endpoint'
	outer send-keys -t a C-p
	eventually shows a 'bravo>'
	eventually shows a 'alpha>'
	pair_window=$(inner display-message -p -t proof '#{window_id}')
	is 2 inner display-message -p -t "$pair_window" '#{window_panes}'
	is "$(printf '%s\n' "${original_alpha%% *}" "${original_bravo%% *}" | sort)" private_links
}

pair_orientation() {
	inner list-panes -t "$pair_window" -F '#{pane_left} #{pane_top}' | awk '
		NR == 1 { left = $1; top = $2 }
		NR == 2 && left != $1 && top == $2 { print "columns" }
		NR == 2 && left == $1 && top != $2 { print "rows" }'
}

pair_released() {
	eventually is "$session_id" inner list-sessions -F '#{session_id}'
	eventually is "$original_windows" source_windows
	is "$original_alpha" source_identity "$alpha_pane"
	is "$original_bravo" source_identity "$bravo_pane"
}

@test "a pair keeps two independent live prompts through focus cycles and layout changes" {
	pair_fixture
	open_pair
	is columns pair_orientation
	local focused first second
	focused=$(inner display-message -p -t proof '#{pane_id}')
	if inner capture-pane -p -t "$focused" | grep -qF 'alpha>'; then
		first=alpha
		second=bravo
	else
		first=bravo
		second=alpha
	fi
	outer send-keys -l -t a 'unfinished'
	eventually shows a "$first> unfinished"
	outer send-keys -t a C-b o
	eventually differs "$focused" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -l -t a 'other edit'
	eventually shows a "$second> other edit"
	outer send-keys -t a M-z
	eventually is 1 inner display-message -p -t "$pair_window" '#{window_zoomed_flag}'
	eventually shows a "$second> other edit"
	eventually hides a "$first> unfinished"
	outer send-keys -t a M-z
	eventually is 0 inner display-message -p -t "$pair_window" '#{window_zoomed_flag}'
	eventually shows a "$first> unfinished"
	outer send-keys -t a C-b Space
	eventually is rows pair_orientation
	eventually shows a "$first> unfinished"
	eventually shows a "$second> other edit"
	outer send-keys -t a Enter
	eventually shows a "$second accepted [other edit]"
	outer send-keys -t a C-b o
	eventually is "$focused" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a C-b Space
	eventually is columns pair_orientation
	outer send-keys -l -t a ' line'
	outer send-keys -t a Enter
	eventually shows a "$first accepted [unfinished line]"
	outer send-keys -t a BTab
	pair_released
	case $(inner display-message -p -t proof '#{window_index}') in 0 | 3) ;; *) return 1 ;; esac
	if ! shows a 'Shift+Tab work'; then outer send-keys -t a BTab; fi
	eventually shows a 'Shift+Tab work'
}

@test "native prefix selection leaves the requested numbered window active and retires both viewers" {
	pair_fixture
	open_pair
	outer send-keys -t a C-b 7
	eventually is 7 inner display-message -p -t proof '#{window_index}'
	pair_released
	is 7 inner display-message -p -t proof '#{window_index}'
}

@test "externally killing the paired window removes its private sessions and leaves the agents running" {
	pair_fixture
	open_pair
	inner kill-window -t "$pair_window"
	pair_released
}

@test "closing a paired source retires the viewers and preserves the remaining agent" {
	pair_fixture
	open_pair
	inner kill-window -t proof:3
	eventually is "$session_id" inner list-sessions -F '#{session_id}'
	eventually is "$(printf '%s\n' "$original_windows" | grep -v '^3 ')" source_windows
	is "$original_alpha" source_identity "$alpha_pane"
}

@test "pairing a window with itself leaves the dock available to choose a different agent" {
	pair_fixture
	outer send-keys -l -t a ALPHA
	eventually hides a 'Second endpoint'
	outer send-keys -t a C-p Escape
	eventually shows a 'Second endpoint'
	is "$session_id" inner list-sessions -F '#{session_id}'
	is "$original_windows" source_windows
	open_pair
}
