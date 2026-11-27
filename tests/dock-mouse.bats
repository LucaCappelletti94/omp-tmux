#!/usr/bin/env bats

load helpers

@test "one click on a wrapped description opens its live prompt directly from work" {
	start_session 0 3
	inner set -t proof mouse on
	title 0 'π > HOME: Source prompt'
	title 3 'π > TARGET: Long measurement description for a second line marker'
	work=$(inner display-message -p -t proof:0 '#{pane_id}')
	target=$(inner display-message -p -t proof:3 '#{pane_id}')
	terminal=$(inner display-message -p -t "$target" '#{pane_tty}')
	for line in {1..75}; do printf 'Old scan %03d\r\n' "$line"; done >"$terminal"
	printf 'TARGET PROMPT> ' >"$terminal"
	inner copy-mode -t "$target" \; send-keys -t "$target" -X history-top
	attach a 110 22
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	eventually shows a 'second line marker'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	line=$(dock_line "$dock" 'second line marker')
	[ "$line" -gt "$(dock_line "$dock" 'Long measurement')" ]
	outer send-keys -t a Escape
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	left_click a 12 "$line"
	eventually is "$target" inner display-message -p -t proof '#{pane_id}'
	eventually shows a 'TARGET PROMPT>'
	is 0 inner display-message -p -t "$target" '#{pane_in_mode}'
	eventually shows a 'NAVIGATOR'
	is "$dock" inner show-options -qv -t proof @omp_dock_pane
}

@test "a focused dock accepts compact clicks with tmux mouse off and ignores clicks through help" {
	start_session 0 3 8
	title 0 'π > CONTROL: Source agent'
	title 3 'π > FIRST: A matching sample'
	title 8 'π > SECOND: Another matching sample'
	target=$(inner display-message -p -t proof:8 '#{pane_id}')
	attach a 110 22
	outer send-keys -t a BTab
	eventually shows a 'Source agent'
	eventually shows a 'Shift+Tab work'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	outer send-keys -t a Tab
	outer send-keys -l -t a 'matching'
	eventually hides a 'CONTROL'
	line=$(dock_line "$dock" SECOND)
	[ -n "$line" ]
	outer send-keys -t a F1
	eventually shows a 'Keyboard shortcuts'
	left_click a 9 "$line"
	outer send-keys -t a F1
	eventually shows a 'SECOND'
	left_click a 1 "$line"
	outer send-keys -t a F1
	eventually shows a 'Keyboard shortcuts'
	is "$dock" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a F1
	eventually shows a 'SECOND'
	left_click a 9 "$line"
	eventually is "$target" inner display-message -p -t proof '#{pane_id}'
	is off inner show-options -gv mouse
}
