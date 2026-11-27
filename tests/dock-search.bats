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
	eventually shows a 'Shift+Tab work'
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

@test "shortcut help scrolls and returns to an unfinished literal search" {
	start_session 0 3
	title 0 'π > FIRST: Baseline scan'
	title 3 'π > MATCH: Fragment?'
	attach a 110 15
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	outer send-keys -l -t a '?'
	eventually shows a 'Keyboard shortcuts'
	shows a 'Find and open'
	outer send-keys -t a NPage
	eventually shows a 'Ctrl+t'
	outer send-keys -t a PPage
	eventually shows a 'Find and open'
	outer send-keys -t a End
	eventually shows a 'Multi-digit window'
	hides a 'Find and open'
	outer send-keys -t a Home
	eventually shows a 'Find and open'
	outer send-keys -t a End
	eventually shows a 'Multi-digit window'
	outer resize-window -t a -y 48
	eventually shows a 'Find and open'
	shows a 'Multi-digit window'
	outer send-keys -t a Escape
	eventually shows a '? help'
	outer send-keys -l -t a '/?'
	eventually hides a 'Baseline scan'
	shows a 'Fragment?'
	outer send-keys -t a F1
	eventually shows a 'Keyboard shortcuts'
	outer send-keys -t a C-t Enter z Escape
	eventually shows a 'Fragment?'
	hides a 'Baseline scan'
	hides a 'TRIAGE'
	is 0 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a Enter
	eventually is 3 inner display-message -p -t proof '#{window_index}'
}

@test "tmux prefix numbers and the window prompt work from the focused and hidden dock" {
	start_session 0 3 12
	title 0 'π > LAB: Review traces'
	title 3 'π > MID: Fit curve'
	title 12 'π > LAST: Collect samples'
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	outer send-keys -t a C-b 3
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	pick a f
	eventually shows a 'Shift+Tab work'
	outer send-keys -t a C-b "'"
	eventually shows a 'index'
	outer send-keys -t a 1 2 Enter
	eventually is 12 inner display-message -p -t proof '#{window_index}'
	pick a f
	eventually shows a 'Shift+Tab work'
	pick a l
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a C-b 3
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a C-b "'"
	eventually shows a 'index'
	outer send-keys -t a 1 2 Enter
	eventually is 12 inner display-message -p -t proof '#{window_index}'
	hides a 'NAVIGATOR'
}
