#!/usr/bin/env bats
# The prefix A agent menu and its pickers, opened by keys on real attached clients.
# shellcheck disable=SC2154 # root comes from helpers.bash

load helpers

in_mode() { inner display-message -p -t proof '#{pane_in_mode}'; }

priority() { inner show-options -wqv -t "proof:$1" @omp_priority; }

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

@test "prefix A opens a menu naming every agent action with its key" {
	start_session 0 1 2 3 4
	attach a 100 30
	menu a
	for entry in 'Waiting windows:w' 'Unseen bells:d' 'Priority windows:p' 'Mark priority:h' \
		'Clear priority:c' 'Hide the bar:s' 'Lay out the bar again:r'; do
		outer capture-pane -p -t a | grep -qE "${entry%:*} +\(${entry#*:}\)"
	done
	outer send-keys -t a q
	eventually hides a 'omp-tmux agents'
	[ "$(in_mode)" = 0 ]
}

@test "prefix ? lists the agent menu key" {
	start_session 0
	# tmux 3.7 and newer list the key with the prefix in front.
	inner list-keys -N -T prefix | grep -E '^(C-b +)?A +omp-tmux agents$'
}

@test "the menu marks and clears the current window's priority" {
	start_session 0 1 2
	inner select-window -t proof:1
	attach a 100 30
	pick a h
	eventually is high priority 1
	pick a c
	eventually is '' priority 1
	[ -z "$(priority 0)" ]
}

@test "@omp_key moves the menu and a reload with another key frees the old one" {
	new_session proof 0 1
	inner set -g @omp_key B
	inner source-file "$root/omp-tmux.conf"
	attach a 100 30
	menu a B
	outer send-keys -t a q
	[ -z "$(inner list-keys -T prefix A 2>/dev/null)" ]
	inner set -g @omp_key C
	inner source-file "$root/omp-tmux.conf"
	[ -z "$(inner list-keys -T prefix B 2>/dev/null)" ]
	menu a C
}

@test "the waiting picker lists only waiting windows with their signals and full labels" {
	fleet
	pick a w
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
	pick a w
	eventually shows a '3: ? + Resting'
	shows a 'proof: ?3 +2 ^1'
}

@test "the unseen bell and priority pickers show the same rows" {
	fleet
	pick a d
	eventually shows a '3: · + Resting'
	shows a '4: ?^+ Choose'
	hides a '2: '
	outer send-keys -t a q
	eventually is 0 in_mode
	pick a p
	eventually shows a '4: ?^+ Choose'
	hides a '3: '
}

@test "titles in picker rows are literal text" {
	fleet
	title 2 'π ! #H #[fg=red] %H'
	pick a w
	eventually shows a '2: ?   #H #[fg=red] %H'
	case $(outer capture-pane -e -p -t a | grep -F '#H') in *$'\e[31m'*) false ;; esac
}

@test "choosing a picker row switches to that window" {
	fleet
	pick a w
	eventually shows a '4: ?^+ Choose'
	outer send-keys -t a 2
	eventually is 0 in_mode
	eventually is 4 inner display-message -p -t proof '#{window_index}'
}

@test "a picker with no matches says so and leaves the current window alone" {
	start_session 0 1 2 3 4
	inner select-window -t proof:3
	attach a 100 30
	pick a w
	eventually is 1 messages_with 'omp-tmux: no window is waiting for input'
	pick a d
	eventually is 1 messages_with 'omp-tmux: no window has an unseen bell'
	pick a p
	eventually is 1 messages_with 'omp-tmux: no window is marked priority'
	[ "$(in_mode)" = 0 ]
	[ "$(inner display-message -p -t proof '#{window_index}')" = 3 ]
}
