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
	for entry in 'Waiting windows:w' 'Unseen bells:d' 'Priority windows:p' 'Search windows:/' 'Mark priority:h' \
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

# tmux 3.8 draws each preview's label from tree-mode-preview-format.
has_preview_format() { inner show-options -gv tree-mode-preview-format >/dev/null 2>&1; }

@test "pane rows and preview labels in a picker are literal text" {
	fleet
	inner rename-window -t proof:2 'w#[fg=red]x'
	inner split-window -d -t proof:2 'sleep 600'
	title 2.1 'π ! #H #[fg=red] %H'
	pick a w
	eventually shows a '2: ?   Choose a route between the two parsers'
	shows a '2:w#[fg=red]x'
	# choose-tree selects the session row first, so Down reaches window 2 and Right expands it.
	outer send-keys -t a Down Right
	eventually shows a '1: π ! #H #[fg=red] %H'
	if has_preview_format; then shows a '1:π ! #H #[fg=red] %H'; fi
	# tmux colours the current preview label red itself, so only the tree row is checked for red.
	case $(outer capture-pane -e -p -t a | grep -F '1: π ! #H') in *$'\e[31m'*) false ;; esac
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

before_3_3() {
	case $(tmux -V) in 'tmux '[0-2].* | 'tmux 3.'[0-2] | 'tmux 3.'[0-2][!0-9]*) return 0 ;; esac
	return 1
}

# search CLIENT TEXT opens the menu search on CLIENT and submits TEXT.
search() {
	pick "$1" /
	eventually shows "$1" 'omp-tmux search'
	outer send-keys -t "$1" -l "$2"
	outer send-keys -t "$1" Enter
}

@test "before tmux 3.3 the search says it needs a newer tmux" {
	before_3_3 || skip 'tmux 3.3 and newer search'
	start_session 0 1 2
	attach a 100 30
	pick a /
	eventually is 1 messages_with 'omp-tmux: search needs tmux 3.3 or newer'
	[ "$(in_mode)" = 0 ]
}

@test "searching finds windows by label in any pane, ignoring case" {
	before_3_3 && skip 'no search before tmux 3.3'
	fleet
	inner split-window -d -t proof:3 'sleep 600'
	title 3.1 'π > Map the ROUTE table'
	search a route
	eventually is 1 in_mode
	eventually shows a '2: ?   Choose a route between the two parsers'
	shows a '3: · + Resting'
	hides a '1: '
	hides a '4: '
}

@test "searching finds a window by its working directory" {
	before_3_3 && skip 'no search before tmux 3.3'
	start_session 0 1 2
	mkdir "$BATS_TEST_TMPDIR/cargo-refquiem"
	inner new-window -d -n w5 -t proof:5 -c "$BATS_TEST_TMPDIR/cargo-refquiem" 'sleep 600'
	attach a 100 30
	search a refquiem
	eventually is 1 in_mode
	eventually shows a '5:     w5'
	hides a '1: '
	# choose-tree numbers its rows from the session row, so the only match is row 1.
	outer send-keys -t a 1
	eventually is 5 inner display-message -p -t proof '#{window_index}'
}

@test "a search with no matches says so, and its text is never read as a command or format" {
	before_3_3 && skip 'no search before tmux 3.3'
	start_session 0 1 2
	inner select-window -t proof:1
	attach a 100 30
	# tmux 3.4 stores a typed $ as \$ and 3.8 a typed ' as '\'', so neither is in the exact check.
	text='x"; kill-server ~ \ #{window_index},}'
	search a "$text"
	eventually is 1 messages_with 'omp-tmux: no window matches'
	[ "$(inner display-message -p '#{@omp_search}')" = "$text" ]
	[ "$(in_mode)" = 0 ]
	[ "$(inner display-message -p -t proof '#{window_index}')" = 1 ]
}
