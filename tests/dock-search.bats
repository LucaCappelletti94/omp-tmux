#!/usr/bin/env bats

load helpers

@test "the dock searches as typed, edits paths and opens an exact window number" {
	start_session 0 3 12
	title 0 'π > LAB: Review batch 12'
	title 3 'π > PATH: Inspect run/fragment'
	title 12 'π > LAST: Collect samples'
	attach a 110 28
	work=$(inner display-message -p -t proof '#{pane_id}')
	outer send-keys -t a BTab
	eventually shows a 'Keyword or session ID'
	outer send-keys -t a Escape
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	eventually shows a 'Shift+Tab focus'
	shows a 'Keyword or session ID'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -l -t a 'RUN/FRAG'
	eventually shows a 'Inspect run/fragment'
	eventually hides a 'Review batch'
	outer send-keys -t a Escape
	eventually shows a 'Keyword or session ID'
	outer send-keys -l -t a '12x'
	eventually shows a 'No matches'
	outer send-keys -t a BSpace
	eventually shows a 'Collect samples'
	outer send-keys -t a Enter
	eventually is 12 inner display-message -p -t proof '#{window_index}'
}

@test "tmux prefix numbers and the window prompt work from the focused and hidden dock" {
	start_session 0 3 12
	title 0 'π > LAB: Review traces'
	title 3 'π > MID: Fit curve'
	title 12 'π > LAST: Collect samples'
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a C-b 3
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	pick a f
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a C-b "'"
	eventually shows a 'index'
	outer send-keys -t a 1 2 Enter
	eventually is 12 inner display-message -p -t proof '#{window_index}'
	pick a f
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a BTab
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a C-b 3
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a C-b "'"
	eventually shows a 'index'
	outer send-keys -t a 1 2 Enter
	eventually is 12 inner display-message -p -t proof '#{window_index}'
	hides a 'NAVIGATOR'
}
