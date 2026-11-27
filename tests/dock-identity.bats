#!/usr/bin/env bats

load helpers

@test "the navigator opens the exact pane by its terminal breadcrumb UUID without Telegram" {
	export PI_CODING_AGENT_DIR="$BATS_TEST_TMPDIR/agent"
	unset OMP_PROFILE PI_PROFILE
	start_session 0 1 2
	title 0 'π > FIRST: Inspect batches'
	title 1 'π > SECOND: Collect samples'
	title 2 'π > CRASH: Interrupted run'
	inner set-option -p -t proof:2 @omp_state crashed
	selected=$(inner display-message -p -t proof:1 '#{pane_id}')
	terminal=$(inner display-message -p -t "$selected" '#{pane_tty}')
	directory=$(inner display-message -p -t "$selected" '#{pane_current_path}')
	terminal=${terminal#/dev/}
	identity=11111111-1111-4111-8111-111111abcdef
	mkdir -p "$PI_CODING_AGENT_DIR/terminal-sessions"
	printf '%s\n%s\nfresh\n' "$directory" "$PI_CODING_AGENT_DIR/sessions/2026-01-05T18-59-59-000Z_$identity.jsonl" >"$PI_CODING_AGENT_DIR/terminal-sessions/${terminal//\//-}"
	crashed=$(inner display-message -p -t proof:2 '#{pane_tty}')
	crashed=${crashed#/dev/}
	cp "$PI_CODING_AGENT_DIR/terminal-sessions/${terminal//\//-}" "$PI_CODING_AGENT_DIR/terminal-sessions/${crashed//\//-}"
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Keyword or session ID'
	outer send-keys -l -t a "$identity"
	eventually shows a 'Collect samples'
	eventually hides a 'Inspect batches'
	hides a 'Interrupted run'
	outer send-keys -t a Enter
	eventually is "$selected" inner display-message -p -t proof '#{pane_id}'
}
