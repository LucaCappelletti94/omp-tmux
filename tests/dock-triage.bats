#!/usr/bin/env bats
# shellcheck disable=SC2154 # root and session_id come from helpers.bash

load helpers

# The labels occur only in roster headings. Read their display order from the renderer.
roster_order() {
	inner capture-pane -p -t "$dock" | awk 'match($0, /OLDEST|FIRST|SECOND|LATEST/) {print substr($0, RSTART, RLENGTH)}' | paste -sd ' ' -
}

ping() { inner show-options -wqv -t "$1" @omp_dock_ping; }

has_ping() { [[ $(ping "$1") =~ ^[1-9][0-9]*\.[1-9][0-9]*$ ]]; }

@test "triage remembers on and off when reopened and stays local to the tmux session" {
	start_session 0 3
	title 0 'π > FIRST: Baseline scan'
	title 3 'π ! SECOND: Input requested'
	new_session other 0
	inner select-pane -t other:0 -T 'π > OTHER: Separate run'
	attach a 110 26
	attach b 110 26 other
	outer send-keys -t a BTab
	eventually shows a 'NAVIGATOR FULL'
	outer send-keys -t a C-t
	eventually shows a 'NAVIGATOR TRIAGE'
	outer send-keys -t a BTab
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a BTab
	eventually shows a 'NAVIGATOR TRIAGE'
	outer send-keys -t a Enter
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t b BTab
	eventually shows b 'NAVIGATOR FULL'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a C-t
	eventually shows a 'NAVIGATOR FULL'
	outer send-keys -t a BTab
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a BTab
	eventually shows a 'NAVIGATOR FULL'
}

@test "attention focus watches hidden workers and drops sessions whose last signal clears" {
	start_session 0 3 8
	title 0 'π > HOME: Baseline controls'
	title 3 'π ⠋ SCAN: Overnight acquisition'
	title 8 'π > FIT: Fragment assignment'
	work=$(inner display-message -p -t proof:0 '#{pane_id}')
	worker=$(inner display-message -p -t proof:3 '#{pane_id}')
	attach a 110 26
	outer send-keys -t a BTab
	eventually shows a 'Overnight acquisition'
	outer send-keys -t a C-a
	eventually shows a 'No sessions need attention'
	hides a 'Overnight acquisition'
	hides a 'Fragment assignment'
	outer send-keys -t a BTab
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a BTab
	eventually shows a 'No sessions need attention'
	outer send-keys -t a Escape
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	ring 3
	eventually shows a 'Overnight acquisition'
	is "$work" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a Enter
	eventually is "$worker" inner display-message -p -t proof '#{pane_id}'
	eventually shows a 'No sessions need attention'
	title 8 'π ! FIT: Fragment assignment'
	eventually shows a 'Fragment assignment'
	hides a 'Overnight acquisition'
	is "$worker" inner display-message -p -t proof '#{pane_id}'
	title 8 'π ⠙ FIT: Fragment assignment'
	eventually shows a 'No sessions need attention'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a C-a
	eventually shows a 'Overnight acquisition'
	shows a 'Fragment assignment'
}

@test "an older unread window rings again and moves first without taking focus or selection" {
	start_session 0 8 3 9
	title 0 'π > OLDEST: Laboratory'
	title 8 'π > FIRST: Spectra'
	title 3 'π > SECOND: Molecules'
	title 9 'π > LATEST: Samples'
	attach a 110 30
	work=$(inner display-message -p -t proof '#{pane_id}')
	ring 8
	eventually has_ping proof:8
	initial=$(ping proof:8)
	is '' inner show-options -qv -t proof @omp_dock_pane
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	outer send-keys -t a C-t
	eventually shows a 'TRIAGE'
	eventually is 'FIRST LATEST SECOND OLDEST' roster_order

	ring 3
	eventually is 'SECOND FIRST LATEST OLDEST' roster_order
	second=$(ping proof:3)
	[ "${second#*.}" -gt "${initial#*.}" ]
	# FIRST remains selected even as SECOND passes it. Select SECOND and return focus to work.
	outer send-keys -t a Up Escape
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	ring 8
	eventually is 'FIRST SECOND LATEST OLDEST' roster_order
	repeated=$(ping proof:8)
	[ "${repeated#*.}" -gt "${second#*.}" ]
	is "$work" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a BTab
	eventually is "$dock" inner display-message -p -t proof '#{pane_id}'
	outer send-keys -t a Enter
	eventually is 3 inner display-message -p -t proof '#{window_index}'
	is 0 inner display-message -p -t proof:3 '#{window_bell_flag}'
	eventually is 'FIRST LATEST SECOND OLDEST' roster_order
}

@test "new windows keep their creation time across index changes and a config reload preserves other hooks" {
	start_session 0
	attach a 110 30
	inner set-hook -g 'after-new-window[7]' 'set -gF @test_new_window "#{window_id}"'
	inner set-hook -g 'alert-bell[7]' 'set -gF @test_bell_window "#{hook_window}"'
	inner source-file "$root/omp-tmux.conf"
	earliest=$(date +%s)
	inner new-window -d -t proof:80 'sleep 600'
	inner new-window -d -t proof:2 'sleep 600'
	latest=$(date +%s)
	older=$(inner show-options -wqv -t proof:80 @omp_dock_created)
	newer=$(inner show-options -wqv -t proof:2 @omp_dock_created)
	[ "$older" -ge "$earliest" ]
	[ "$newer" -ge "$older" ]
	[ "$latest" -ge "$newer" ]
	new_window=$(inner display-message -p -t proof:2 '#{window_id}')
	is "$new_window" inner show-options -gv @test_new_window
	title 80 'π > FIRST: Spectra'
	title 2 'π > SECOND: Molecules'
	inner move-window -s proof:80 -t proof:90
	inner source-file "$root/omp-tmux.conf"
	is "$older" inner show-options -wqv -t proof:90 @omp_dock_created
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	dock=$(inner display-message -p -t proof '#{pane_id}')
	outer send-keys -t a C-t
	eventually is 'SECOND FIRST' roster_order
	ring 2
	eventually is "$new_window" inner show-options -gv @test_bell_window
}

@test "a bell wakes only its session-owned renderer and sends no key to a stale work pane" {
	start_session 0 1
	new_session other 0 1
	# Capture actual input bytes so the periodic roster refresh cannot hide a missed or misdirected wake.
	inner respawn-pane -k -t proof:0 'stty raw -echo; printf Listening; dd bs=1 count=1 2>/dev/null | od -An -tx1; sleep 600'
	cp "$(command -v bash)" "$BATS_TEST_TMPDIR/omp-dock"
	inner respawn-pane -k -t other:0 "$BATS_TEST_TMPDIR/omp-dock" -c "stty raw -echo; printf Listening; IFS= read -r -N6 keys; printf %s \"\$keys\" | od -An -tx1; sleep 600"
	attach a 110 28
	attach b 110 28 other
	eventually shows a Listening
	eventually shows b Listening
	work=$(inner display-message -p -t proof:0 '#{pane_id}')
	other=$(inner display-message -p -t other:0 '#{pane_id}')
	other_session=$(inner display-message -p -t other '#{session_id}')
	inner set -t proof @omp_dock_pane "$work" \; set -p -t "$work" @omp_dock_slot "$session_id" \; set -p -t "$work" @omp_navigator 1
	inner set -t other @omp_dock_pane "$other" \; set -p -t "$other" @omp_dock_slot "$other_session" \; set -p -t "$other" @omp_navigator 1
	ring 1
	eventually has_ping proof:1
	initial=$(ping proof:1)
	inner send-keys -l -t "$work" Q
	eventually shows a ' 51'
	inner set -t proof @omp_dock_pane "$other"
	ring 1
	eventually differs "$initial" ping proof:1
	is '' ping other:1
	inner send-keys -l -t "$other" Q
	printf '\a' >"$(inner display-message -p -t other:1 '#{pane_tty}')"
	eventually shows b '51 1b 5b 32 34 7e'
	has_ping other:1
	is "$work" inner display-message -p -t proof '#{pane_id}'
	is "$other" inner display-message -p -t other '#{pane_id}'
}
