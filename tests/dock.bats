#!/usr/bin/env bats
# shellcheck disable=SC2154 # root, helper, socket and session_id come from helpers.bash

load helpers

@test "Shift+Tab opens, focuses and hides the dock while plain Tab switches views" {
	start_session 0 1
	title 1 'π > LAB: Analyze spectra'
	attach a 110 28
	work=$(inner display-message -p -t proof '#{pane_id}')
	outer send-keys -H -t a 1b 5b 5a
	eventually shows a 'Shift+Tab hide'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	[ "$work" != "$dock" ]
	outer send-keys -t a Escape
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a BTab
	eventually is "$dock" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a Tab
	eventually shows a 'COMPACT'
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a BTab
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	eventually is 0 inner display-message -p -t "$work" '#{pane_left}'
	outer send-keys -t a BTab
	eventually shows a 'NAVIGATOR'
}

@test "Shift+Tab reaches the application in a session without an OMP window" {
	start_session 0
	inner respawn-pane -k -t proof:0 'stty raw -echo; printf "Waiting for key"; dd bs=1 count=3 2>/dev/null | od -An -tx1; sleep 600'
	new_session other 0
	inner select-pane -t other:0 -T 'π > FOREIGN: Separate session'
	attach a 110 28
	eventually shows a 'Waiting for key'
	outer send-keys -t a BTab
	eventually shows a '1b 5b 5a'
}

@test "a working spinner moves between title updates and retains its priority flag" {
	start_session 0
	title 0 'π ⠋ SPINJOB: Measure spectra'
	work=$(inner display-message -p -t proof:0 '#{pane_id}')
	inner set-option -w -t proof:0 @omp_priority high
	attach a 110 28
	pick a f
	eventually shows a 'NAVIGATOR'
	eventually shows a '⠙^'
	eventually shows a '⠹^'
	inner set-option -p -t "$work" @omp_state 'done' \; select-pane -t "$work" -T 'π > SPINJOB: Measure spectra'
	eventually shows a '✓^'
}

@test "the dock opens focused, returns to the same work pane and follows window switches" {
	start_session 0 1
	attach a 110 28
	title 0 'π > 🧪 LAB: Compare spectra'
	title 1 'π ! REVIEW: Check peak assignments'
	inner split-window -vd -t proof:0 'sleep 600'
	original=$(inner display-message -p -t proof:0 '#{pane_id}')
	second=$(inner display-message -p -t proof:1 '#{pane_id}')
	pick a l
	eventually shows a 'Compare spectra'
	eventually shows a 'Check peak assignments'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	[ "$(inner display-message -p -t "$dock" '#{pane_left}')" = 0 ]
	[ "$(inner display-message -p -t "$original" '#{pane_left}')" -gt 20 ]
	[ "$(height)" = off ]
	outer send-keys -t a Down Escape
	eventually is "$original" inner display-message -p -t proof '#{pane_id}'
	pick a f
	eventually is "$dock" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a Escape
	eventually is "$original" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a C-b 1
	eventually is "$second" inner display-message -p -t proof '#{pane_id}'
	eventually shows a 'Check peak assignments'
	eventually is 1 inner display-message -p -t "$dock" '#{window_index}'
	[ "$(inner display-message -p -t "$second" '#{pane_left}')" -gt 20 ]
	outer resize-window -t a -x 85 -y 17
	eventually shows a 'Compare spectra'
	pick a l
	eventually is 0 inner display-message -p -t "$second" '#{pane_left}'
	is off height
	hides a '1:REVIEW'
	[ "$(inner display-message -p -t proof:0 '#{window_panes}')" = 2 ]
}

@test "a hidden navigator keeps the grid off through publication, reload and detach until Show the bar" {
	start_session 0 1 2 3 4
	title 0 'π > LAB: Local experiment'
	new_session other 0 1 2 3 4
	attach a 80 24
	attach b 80 24 other
	eventually row_contains a 3 1 '4:w4'
	eventually row_contains b 3 1 '4:w4'
	# A detach worker can already hold the native-row publication when the dock opens.
	printf 'window 0\n' | "$helper" plan 5 20 | "$helper" render "$session_id" "$(request)" shown >"$BATS_TEST_TMPDIR/pending"
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	menu a
	hides a 'Show the bar'
	outer send-keys -t a Escape
	eventually hides a 'omp-tmux agents'
	outer send-keys -t a BTab
	eventually is 1 inner display-message -p -t proof:0 '#{window_panes}'
	inner source-file "$BATS_TEST_TMPDIR/pending"
	is off height
	choice=$(inner display-message -p -t proof '#{@omp_layout_request}')
	inner detach-client -s proof
	eventually is 1 clients
	inner source-file "$root/omp-tmux.conf"
	"$helper" refresh-all "$socket"
	is off height
	attach c 80 24
	outer resize-window -t b: -x 132 -y 30
	eventually row_contains b 1 0 '4:w4'
	is off height
	is "$choice" inner display-message -p -t proof '#{@omp_layout_request}'
	menu c
	shows c 'Show the bar'
	outer send-keys -t c s
	eventually row_contains c 3 1 '4:w4'
	row_contains b 1 0 '4:w4'
}

@test "focus opens the dock, Tab toggles descriptions, and arrows choose the window Enter opens" {
	start_session 0 1 2
	title 0 'π > LAB: Compare spectra'
	title 1 'π > REVIEW: Check peaks'
	title 2 'π > QUEUE: Collect samples'
	attach a 110 28
	second=$(inner display-message -p -t proof:1 '#{pane_id}')
	pick a f
	eventually shows a 'NAVIGATOR'
	eventually shows a 'Compare spectra'
	outer send-keys -t a Tab
	eventually shows a 'COMPACT'
	hides a 'Compare spectra'
	shows a 'LAB'
	shows a 'REVIEW'
	outer send-keys -t a Tab
	eventually shows a 'Compare spectra'
	outer send-keys -t a Down Down Up
	outer send-keys -t a Enter
	eventually is "$second" inner display-message -p -t proof '#{pane_id}'
}

@test "list and search include only OMP windows in this session, even when an agent is in a background split" {
	start_session 0 1 2 3
	title 0 'π > LOCAL: Analyze spectra'
	inner rename-window -t proof:1 LocalShell
	inner set-option -p -t proof:1 @omp_state 'done'
	title 2 'π ! REVIEW: Check peak assignments'
	agent_pane=$(inner display-message -p -t proof:2 '#{pane_id}')
	inner split-window -t proof:2 'sleep 600'
	inner rename-window -t proof:3 InterruptedRun
	inner set-option -p -t proof:3 @omp_state crashed
	new_session observatory 0
	inner select-pane -t observatory:0 -T 'π > FOREIGN: Telescope'
	attach a 110 28
	pick a f
	eventually shows a 'NAVIGATOR'
	shows a 'Analyze spectra'
	shows a 'Check peak assignments'
	shows a 'InterruptedRun'
	hides a 'LocalShell'
	hides a 'Telescope'
	outer send-keys -t a /
	outer send-keys -l -t a 'TELESCOPE'
	eventually shows a 'No matches'
	outer send-keys -t a Escape
	eventually shows a 'Analyze spectra'
	outer send-keys -t a /
	outer send-keys -l -t a 'ASSIGNMENTS'
	eventually shows a 'Check peak assignments'
	eventually hides a 'Analyze spectra'
	outer send-keys -t a Enter
	eventually is "$agent_pane" inner display-message -p -t proof '#{pane_id}'
	is proof inner list-clients -F '#{client_session}'
}

@test "closing a work window keeps the active entry visible on the dock's next page" {
	start_session {0..12}
	for index in {0..12}; do title "$index" "π > w$index"; done
	attach a 100 22
	pick a l
	eventually is off height
	title 12 'π > QUEUE: Inspect the last sample'
	inner select-window -t proof:12
	eventually shows a 'Inspect the last sample'
	hides a 'w0'
	inner kill-window -t proof:12
	eventually shows a 'w0'
	[ "$(height)" = off ]
}

@test "the dock leaves shared windows untouched and keeps the grid hidden" {
	start_session 0 1
	title 1 'π ! LINKED: Shared agent'
	new_session other 0
	inner link-window -s proof:1 -t other:1
	attach a 100 24
	eventually row_contains a 1 0 '1:LINKED'
	inner set-option -t proof status off
	pick a l
	eventually shows a 'Shared agent'
	inner select-window -t proof:1
	eventually is 1 messages_with 'Left dock closed'
	[ "$(inner display-message -p -t other:1 '#{window_panes}')" = 1 ]
	[ "$(inner display-message -p -t proof:0 '#{window_panes}')" = 1 ]
	[ "$(height)" = off ]
}
