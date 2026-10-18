#!/usr/bin/env bats
# The status grid as drawn on real attached clients.
# shellcheck disable=SC2154 # root, helper, socket and session_id come from helpers.bash

load helpers

@test "a fleet wider than the terminal wraps into rows above a summary" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually is 3 height
	eventually row_contains a 3 1 '4:'
	first=$(row a 3 0)
	[ "${first:3:2}" = '0:' ]
	[ "${first:23:2}" = '1:' ]
	[ "${first:43:2}" = '2:' ]
	[ "${first:63:2}" = '3:' ]
	summary=$(row a 3 2)
	case $summary in *'?0 +0 ^0 5 windows A w/d/p ['*'] '*) ;; *) false ;; esac
	[[ $summary =~ [0-9][0-9]:[0-9][0-9]$ ]]
}

@test "cells show agent state, priority and unseen bell independently" {
	start_session 0 1 2 3 4
	title 0 'π ! Pick a name'
	title 1 'π ⠋ compute π value'
	title 2 'π > Resting'
	title 4 'π ! Choose'
	inner set-option -w -t proof:4 @omp_priority high
	attach a 80 24
	ring 4
	refresh
	eventually row_contains a 3 2 '?2 +1 ^1'
	eventually is '?  0:Pick a name    ' cell a 3 0 0 20
	[ "$(cell a 3 0 1 20)" = '⠋  1:compute π val… ' ]
	[ "$(cell a 3 0 2 20)" = '·  2:Resting        ' ]
	[ "$(cell a 3 0 3 20)" = '   3:w3             ' ]
	[ "$(cell a 3 1 0 20)" = '?^+4:Choose         ' ]
}

@test "a waiting agent in an inactive pane marks its window and the count" {
	start_session 0 1 2 3 4
	inner split-window -d -t proof:2 'sleep 600'
	title 2.0 'π > Resting'
	title 2.1 'π ! Approve the plan'
	attach a 80 24
	refresh
	# The native row also shows the counts, so only the cell itself proves the layout drew.
	eventually is '?  2:Resting        ' cell a 3 0 2 20
	row_contains a 3 2 '?1 '
}

@test "the current cell alone is bold and underlined" {
	start_session 0 1 2 3 4
	inner select-window -t proof:2
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	styled=$(styled_row a 3 0)
	before=${styled%%2:*}
	after=${styled#*2:}
	case ${before#*1:} in *$'\e[1;4m'*) ;; *) false ;; esac
	case ${before%%1:*} in *'1;4m'* | *$'\e[1m'* | *$'\e[4m'*) false ;; esac
	case ${after#*$'\e[0m'} in *'1;4m'* | *$'\e[1m'* | *$'\e[4m'*) false ;; esac
}

@test "titles are literal data that never restyle or shift neighbouring cells" {
	start_session 0 1 2 3 4
	title 0 'π ! #H #[fg=red]%H'
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	[ "$(cell a 3 0 0 20)" = '?  0:#H #[fg=red]%H ' ]
	[ "$(cell a 3 0 1 20 | cut -c4-5)" = '1:' ]
	case $(styled_row a 3 0) in *$'\e[31m'*) false ;; esac
}

@test "labels longer than the budget end in an ellipsis inside the cell" {
	start_session 0 1 2 3 4
	title 0 'π > abcdefghijklmn'
	title 1 'π > abcdefghijklmno'
	title 2 'π > 日本語の解析です'
	title 3 'π > 日本語の解析で'
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	[ "$(cell a 3 0 0 20)" = '·  0:abcdefghijklmn ' ]
	[ "$(cell a 3 0 1 20)" = '·  1:abcdefghijklm… ' ]
	first=$(row a 3 0)
	third=${first:40}
	[ "${third:0:12}" = '·  2:日本語の解析…' ]
	[ "${third:12:2}" = '  ' ]
	[ "${third:14:12}" = '·  3:日本語の解析で' ]
}

@test "state, priority, bell and label changes never move cells or resize the bar" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	title 0 'π ⠋ a much longer working label than fits'
	title 1 'π ! x'
	inner set-option -w -t proof:2 @omp_priority high
	ring 3
	eventually row_contains a 3 2 '?1 +1 ^1'
	eventually row_contains a 3 0 '0:'
	first=$(row a 3 0)
	[ "${first:3:2}" = '0:' ]
	[ "${first:23:2}" = '1:' ]
	[ "${first:43:2}" = '2:' ]
	[ "${first:63:2}" = '3:' ]
	[ "$(height)" = 3 ]
}

@test "each client width pages independently and follows the selected window" {
	start_session 0 9 $(seq 101 132)
	inner select-window -t proof:132
	title 0 'π ! Waiting far away'
	attach a 244 76
	attach b 80 24
	refresh
	eventually is 4 height
	eventually row_contains b 4 3 'page 4/4'
	eventually row_contains a 4 3 'page 2/2'
	row_contains b 4 3 '?1 '
	row_contains b 4 0 '126:'
	row_contains b 4 2 '132:'
	inner select-window -t proof:101
	eventually row_contains b 4 3 'page 1/4'
	row_contains b 4 0 '101:'
	eventually row_contains a 4 3 'page 1/2'
}

@test "prefix A r applies changed layout settings" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually is 3 height
	inner set -g @omp_max_rows 2
	pick a r
	eventually is 2 height
	eventually row_contains a 2 1 'page 1/2'
}

@test "sourcing the configuration lays out clients already attached" {
	start_session 0 1 2 3 4
	attach a 80 24
	inner source-file "$root/omp-tmux.conf"
	eventually is 3 height
	eventually row_contains a 3 1 '4:'
}

@test "a short terminal keeps one row and pages beside the counts" {
	start_session $(seq 0 9)
	inner select-window -t proof:9
	attach a 80 9
	refresh
	eventually row_contains a 1 0 'page 5/5'
	only=$(row a 1 0)
	[ "${only:3:2}" = '8:' ]
	[ "${only:23:2}" = '9:' ]
	case $only in *' ?0  +0  ^0  page 5/5 10 windows A w/d/p') ;; *) false ;; esac
}

@test "a terminal too narrow for a cell shows only the current window" {
	start_session $(seq 0 19)
	inner select-window -t proof:7
	attach a 30 9
	refresh
	# The native row also contains " 7:w7", so only the compact cell's exact start proves the layout drew.
	eventually starts a 1 0 '    7:w7'
	only=$(row a 1 0)
	case $only in *' 6:'* | *' 8:'*) false ;; esac
	case $only in *' ?0  +0  ^0 ') ;; *) false ;; esac
}

@test "an invalid option keeps the last layout and says why" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually is 3 height
	inner set -g @omp_max_rows x
	refresh || true
	eventually is 1 messages_with 'omp-tmux: @omp_max_rows must be a positive integer'
	[ "$(height)" = 3 ]
}

@test "a superseded request never publishes" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually is 3 height
	inner set -g @omp_max_rows 2
	inner set-option -t proof @omp_layout_request newer
	"$helper" publish "$socket" "$session_id" older
	[ "$(height)" = 3 ]
}

@test "a refresh exceeding two seconds is stopped and leaves the layout" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually is 3 height
	inner set -g @omp_max_rows 2
	real_tmux=$(command -v tmux)
	mkdir "$BATS_TEST_TMPDIR/shim"
	cat >"$BATS_TEST_TMPDIR/shim/tmux" <<-EOF
		#!/bin/sh
		for argument; do
			[ "\$argument" != source-file ] || exec sleep 47
		done
		exec "$real_tmux" "\$@"
	EOF
	chmod +x "$BATS_TEST_TMPDIR/shim/tmux"
	start=$(date +%s)
	PATH="$BATS_TEST_TMPDIR/shim:$PATH" "$helper" refresh "$socket" "$session_id" || true
	[ $(($(date +%s) - start)) -le 4 ]
	[ "$(height)" = 3 ]
	eventually is 1 messages_with 'omp-tmux: layout refresh exceeded 2 seconds'
	eventually no_process 'sleep 47'
}
