#!/usr/bin/env bats
# The prefix A pickers, opened by keys on real attached clients.
# shellcheck disable=SC2154 # root comes from helpers.bash

load helpers

shows() { outer capture-pane -p -t "$1" | grep -qF -- "$2"; }
hides() { ! shows "$@"; }

in_mode() { inner display-message -p -t proof '#{pane_in_mode}'; }

# pick KEY opens the prefix A picker bound to KEY on client a.
pick() {
	outer send-keys -t a C-b A
	eventually is omp-agent inner display-message -p '#{client_key_table}'
	outer send-keys -t a "$1"
}

fleet() {
	start_session 0 1 2 3 4
	new_session other 0
	title 1 'π ⠋ Working away'
	title 2 'π ! Choose a route between the two parsers'
	title 3 'π > Resting'
	title 4 'π ! Choose'
	inner set-option -w -t proof:4 @omp_priority high
	attach a 100 30
	ring 3
	ring 4
}

@test "the waiting picker lists only waiting windows with their signals and full labels" {
	fleet
	pick w
	eventually is 1 in_mode
	eventually shows a '2: ?   Choose a route between the two parsers'
	shows a '4: ?^+ Choose'
	hides a '1: '
	hides a 'other'
	shows a 'proof: ?2 +2 ^1'
}

@test "the waiting picker lists a window whose inactive pane waits" {
	fleet
	inner split-window -d -t proof:3 'sleep 600'
	title 3.1 'π ! Approve the plan'
	pick w
	eventually shows a '3: ? + Resting'
	shows a 'proof: ?3 +2 ^1'
}

@test "the unseen bell and priority pickers show the same rows" {
	fleet
	pick d
	eventually shows a '3: · + Resting'
	shows a '4: ?^+ Choose'
	hides a '2: '
	outer send-keys -t a q
	eventually is 0 in_mode
	pick p
	eventually shows a '4: ?^+ Choose'
	hides a '3: '
}

@test "titles in picker rows are literal text" {
	fleet
	title 2 'π ! #H #[fg=red] %H'
	pick w
	eventually shows a '2: ?   #H #[fg=red] %H'
	case $(outer capture-pane -e -p -t a | grep -F '#H') in *$'\e[31m'*) false ;; esac
}

@test "choosing a picker row switches to that window" {
	fleet
	pick w
	eventually shows a '4: ?^+ Choose'
	outer send-keys -t a 2
	eventually is 0 in_mode
	eventually is 4 inner display-message -p -t proof '#{window_index}'
}

@test "a picker with no matches says so and leaves the current window alone" {
	start_session 0 1 2 3 4
	inner select-window -t proof:3
	attach a 100 30
	pick w
	eventually is 1 messages_with 'omp-tmux: no window is waiting for input'
	pick d
	eventually is 1 messages_with 'omp-tmux: no window has an unseen bell'
	pick p
	eventually is 1 messages_with 'omp-tmux: no window is marked priority'
	[ "$(in_mode)" = 0 ]
	[ "$(inner display-message -p -t proof '#{window_index}')" = 3 ]
}
