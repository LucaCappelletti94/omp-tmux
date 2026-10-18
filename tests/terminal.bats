#!/usr/bin/env bats
# How omp-tmux meets the outer terminal, the user's own settings and plugin managers.
# shellcheck disable=SC2154 # root and socket come from helpers.bash

load helpers

# prompt_row ROW prints the bar row a message lands on when ROW is the summary and last row.
# tmux 3.4 to 3.6 keep it on row 0, older releases use the last row and newer ones follow message-line.
prompt_row() {
	case $(tmux -V) in
	'tmux 3.'[4-5] | 'tmux 3.'[4-5][!0-9]* | 'tmux 3.6') echo 0 ;;
	*) echo "$1" ;;
	esac
}

@test "a bell in another window reaches the outer terminal" {
	start_session 0 1
	attach a 80 24
	ring 1
	eventually is 1 outer display-message -p -t a: '#{window_bell_flag}'
}

@test "messages go to the summary row where tmux keeps the prompt cursor with them" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is 3 height
	eventually row_contains a 3 1 '4:w4'
	# tmux 3.2a rejects a message together with -c, so the session's only client is found from -t.
	inner display-message -t proof -d 5000 'omp probe message'
	at=$(prompt_row 2)
	eventually row_contains a 3 "$at" 'omp probe message'
	[ "$at" = 0 ] || row_contains a 3 0 '0:w0'
}

@test "the configuration keeps the user's mouse and status interval" {
	new_session proof 0
	inner set -g mouse on
	inner set -g status-interval 7
	inner source-file "$root/omp-tmux.conf"
	[ "$(inner show-options -gv mouse)" = on ]
	[ "$(inner show-options -gv status-interval)" = 7 ]
}

@test "reloading returns without waiting for the layout helper" {
	real_tmux=$(command -v tmux)
	mkdir "$BATS_TEST_TMPDIR/shim"
	cat >"$BATS_TEST_TMPDIR/shim/tmux" <<-EOF
		#!/bin/sh
		for argument; do
			[ "\$argument" != source-file ] || sleep 2.9
		done
		exec "$real_tmux" "\$@"
	EOF
	chmod +x "$BATS_TEST_TMPDIR/shim/tmux"
	# The server's PATH reaches the helper, so only the helper's own tmux calls are slowed.
	PATH="$BATS_TEST_TMPDIR/shim:$PATH" inner -f /dev/null new-session -d -s proof -x 80 -y 24 'sleep 600'
	start=$(date +%s)
	inner source-file "$root/omp-tmux.conf"
	[ $(($(date +%s) - start)) -le 1 ]
	eventually no_process 'sleep 2.9'
}
