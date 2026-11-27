#!/usr/bin/env bats

load helpers

print_working_row() {
	local terminal
	terminal=$(inner display-message -p -t "$1" '#{pane_tty}')
	printf '\033[2J\033[HSome earlier transcript\r\n  ⎋ Old unrelated text\r\nOutput from a job\r\n\r\n  ⎋ %s\r\n ⠏ 14m > ◉ GPT-6.2 Astra > 📁 ~/lab\r\n╰─\r\n' "$2" >"$terminal"
}

@test "live working messages are opt-in, update in compact view, and disappear when work stops" {
	start_session 0 3 4
	title 0 'π > CONTROL: Pick a working agent'
	title 3 'π ⠋ SCAN: Compare fractions'
	title 4 'π ⠙ FIT: Model peaks'
	worker=$(inner display-message -p -t proof:3 '#{pane_id}')
	other=$(inner display-message -p -t proof:4 '#{pane_id}')
	print_working_row "$worker" 'Reading calibration scans'
	print_working_row "$other" 'Fitting isotope envelopes'
	attach a 110 30
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	hides a 'Reading calibration scans'
	outer send-keys -t a C-s
	eventually shows a 'Reading calibration scans'
	shows a 'Fitting isotope envelopes'
	hides a 'Old unrelated text'
	outer send-keys -t a Tab
	eventually shows a 'COMPACT'
	shows a 'Reading calibration scans'
	hides a 'Compare fractions'
	print_working_row "$worker" 'Aligning fragment peaks'
	eventually shows a 'Aligning fragment peaks'
	hides a 'Reading calibration scans'
	inner select-pane -T 'π > SCAN: Compare fractions' -t "$worker"
	eventually hides a 'Aligning fragment peaks'
	shows a 'Fitting isotope envelopes'
	pick a l
	eventually hides a 'NAVIGATOR'
	outer send-keys -t a BTab
	eventually shows a 'Fitting isotope envelopes'
	outer send-keys -t a C-s
	eventually hides a 'Fitting isotope envelopes'
}
