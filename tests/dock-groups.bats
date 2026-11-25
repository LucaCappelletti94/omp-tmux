#!/usr/bin/env bats

load helpers

await_label() {
	eventually shows a "$1" || {
		outer capture-pane -p -t a >&2
		return 1
	}
}

group_session() {
	export PI_CODING_AGENT_DIR="$BATS_TEST_TMPDIR/agent" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	unset OMP_PROFILE PI_PROFILE
	mkdir -p "$PI_CODING_AGENT_DIR/terminal-sessions"
	start_session "$@"
}

agent_identity() {
	local terminal directory
	terminal=$(inner display-message -p -t "$1" '#{pane_tty}')
	directory=$(inner display-message -p -t "$1" '#{pane_current_path}')
	terminal=${terminal#/dev/}
	printf '%s\n%s\nfresh\n' "$directory" "$PI_CODING_AGENT_DIR/sessions/2026-01-05T18-59-59-000Z_$2.jsonl" >"$PI_CODING_AGENT_DIR/terminal-sessions/${terminal//\//-}"
}

move_agent() {
	outer send-keys -t a C-g
	eventually shows a 'Move to group'
	outer send-keys -l -t a "$1"
	eventually shows a "$1"
	outer send-keys -t a Enter
	eventually hides a 'Move to group'
}

@test "grouping two running agents keeps their window numbers, draft and prompt while collapsed members remain searchable" {
	group_session 3 10 18
	title 3 'π > OTHER: Baseline controls'
	title 10 'π > FIRST: Isotope patterns'
	inner respawn-pane -k -t proof:18 'env PS1="Work> " bash --noprofile --norc -i'
	inner select-window -t proof:18
	attach a 110 30
	eventually shows a 'Work>'
	title 18 'π > SECOND: Fraction polarity'
	work=$(inner display-message -p -t proof:18 '#{pane_id}')
	agent_identity "$work" '11111111-1111-4111-8111-111111111118'
	agent_identity proof:10 '11111111-1111-4111-8111-111111111110'
	inner send-keys -l -t "$work" 'unfinished assignment'
	eventually shows a 'Work> unfinished assignment'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	identity_format='#{window_id} #{window_index} #{pane_id} #{pane_pid} #{pane_width}x#{pane_height}'
	before=$(inner display-message -p -t "$work" "$identity_format")
	move_agent Spectra
	eventually shows a 'Ungrouped'
	outer send-keys -l -t a '10'
	eventually hides a 'Fraction polarity'
	move_agent Spectra
	outer send-keys -t a Escape
	eventually shows a 'Keyword or session ID'
	outer send-keys -t a Left
	eventually hides a 'Isotope patterns'
	hides a 'Fraction polarity'
	await_label 'Baseline controls'
	outer send-keys -l -t a 'sPeCtRa'
	eventually shows a 'Isotope patterns'
	shows a 'Fraction polarity'
	hides a 'Baseline controls'
	outer send-keys -t a Escape
	eventually hides a 'Fraction polarity'
	outer send-keys -l -t a '18'
	eventually shows a 'Fraction polarity'
	outer send-keys -t a Enter
	eventually is "$work" inner display-message -p -t proof '#{pane_id}'
	is "$before" inner display-message -p -t "$work" "$identity_format"
	shows a 'Work> unfinished assignment'
	outer send-keys -t a C-b 3
	eventually is 3 inner display-message -p -t proof '#{window_index}'
}

@test "group membership follows a resumed OMP ID and supports moving, cancelling and ungrouping" {
	group_session 3 18
	title 3 'π > CONTROL: Calibration'
	title 18 'π > ORIGINAL: Original experiment'
	original='11111111-1111-4111-8111-111111111118'
	agent_identity proof:18 "$original"
	inner select-window -t proof:18
	attach a 110 30
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	move_agent Spectra
	outer send-keys -t a BTab
	eventually hides a 'NAVIGATOR'
	inner kill-window -t proof:18
	inner new-window -d -t proof:18 'sleep 600'
	inner new-window -d -t proof:28 'sleep 600'
	title 18 'π > REUSED: Replacement experiment'
	title 28 'π > RESUMED: Continued experiment'
	agent_identity proof:18 '22222222-2222-4222-8222-222222222218'
	agent_identity proof:28 "$original"
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -l -t a Spectra
	eventually hides a 'Replacement experiment'
	shows a 'Continued experiment'
	outer send-keys -t a C-g
	eventually shows a 'Move to group'
	outer send-keys -l -t a Discarded
	outer send-keys -t a Escape
	eventually shows a 'Continued experiment'
	move_agent Review
	eventually shows a 'No matches'
	outer send-keys -t a Escape
	eventually shows a 'Keyword or session ID'
	outer send-keys -l -t a Review
	await_label 'Continued experiment'
	hides a 'Replacement experiment'
	move_agent ungrouped
	eventually shows a 'No matches'
	outer send-keys -t a Escape
	eventually shows a 'Continued experiment'
	hides a 'Ungrouped'
	hides a 'Discarded'
}

@test "arrows wrap in both directions and triage opens the highest ranked agent" {
	group_session 0 3 8
	title 0 'π > BASE: Baseline scan'
	title 3 'π ! ASK: Waiting for input'
	title 8 'π > URGENT: Expiring run'
	inner set-option -p -t proof:8 @omp_state urgent
	attach a 110 30
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a Up Enter
	eventually is 8 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a Down Enter
	eventually is 0 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a C-t
	eventually shows a 'TRIAGE'
	outer send-keys -t a Enter
	eventually is 8 inner display-message -p -t proof '#{window_index}'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab hide'
	outer send-keys -t a Down Enter
	eventually is 3 inner display-message -p -t proof '#{window_index}'
}
