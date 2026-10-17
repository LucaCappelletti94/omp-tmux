#!/usr/bin/env bats
# The layout follows clients and windows by itself, with no manual refresh.
# shellcheck disable=SC2154 # root, helper, socket and session_id come from helpers.bash

load helpers

# slice CLIENT ROWS K START LEN prints LEN cells of status row K from START.
slice() { r=$(row "$1" "$2" "$3"); printf '%s' "${r:$4:$5}"; }

lacks() { ! row_contains "$@"; }

status_unset() { [ -z "$(inner show-options -q -v -t "${1:-proof}" status)" ]; }

@test "attaching a client lays the bar out without a manual refresh" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is 3 height
	eventually row_contains a 3 1 '4:w4'
}

@test "a resize lays the bar out again for the new width" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is '1:' slice a 3 0 23 2
	outer resize-window -t a -x 100 -y 24
	eventually is '1:' slice a 3 0 28 2
	eventually row_contains a 3 1 '4:w4'
}

@test "a burst of resizes ends in the layout for the final size" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is 3 height
	for size in 100x24 120x30 90x24 132x30; do
		outer resize-window -t a -x "${size%x*}" -y "${size#*x}"
	done
	eventually is on height
	eventually is '1:' slice a 1 0 25 2
	row_contains a 1 0 '4:w4'
}

@test "a new window joins the grid" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually row_contains a 3 1 '4:w4'
	inner new-window -d -n w5 -t proof:5 'sleep 600'
	eventually row_contains a 3 1 '5:w5'
}

@test "killing a window regroups the grid after automatic renumbering" {
	start_session 0 1 2 3 4
	inner set -g renumber-windows on
	attach a 80 24
	eventually is 3 height
	inner kill-window -t proof:1
	eventually is 2 height
	eventually row_contains a 2 0 '1:w2'
	row_contains a 2 0 '3:w4'
}

@test "moving a window to a new index updates the grid with the same window count" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually row_contains a 3 1 '4:w4'
	inner move-window -s proof:0 -t proof:9
	eventually row_contains a 3 1 '9:w0'
	row_contains a 3 0 '1:w1'
}

@test "renumbering without any hook heals within seconds" {
	start_session 0 2 4 6 8
	attach a 80 24
	eventually row_contains a 3 1 '8:w8'
	inner move-window -r -t proof
	eventually row_contains a 3 1 '4:w8'
	row_contains a 3 0 '1:w2'
}

@test "a linked window joins and leaves the grid of every session it is in" {
	start_session 0 1 2 3 4
	new_session other 0 7
	attach a 80 24
	eventually row_contains a 3 1 '4:w4'
	inner link-window -s other:7 -t proof:5
	eventually row_contains a 3 1 '5:w7'
	inner kill-window -t other:7
	eventually lacks a 3 1 '5:'
	eventually row_contains a 3 1 '4:w4'
	lacks a 3 1 '5:'
}

@test "detaching the last interactive client returns the session to the native row" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is 3 height
	inner detach-client -s proof
	eventually status_unset
	[ -z "$(inner show-options -q -v -t proof status-format)" ]
}

@test "a client switching sessions lays out the session it joins and resets the one it left" {
	start_session 0 1 2 3 4
	new_session other $(seq 0 9)
	attach a 80 24
	eventually is 3 height
	inner switch-client -c "$(inner list-clients -F '#{client_name}')" -t other
	eventually is 4 height other
	eventually status_unset proof
	eventually row_contains a 4 2 '9:w9'
}

@test "control-mode clients never change the layout" {
	start_session 0 1 2 3 4
	attach a 80 24
	eventually is 3 height
	before=$(request)
	# The client reads a fifo this test holds open, so it exits with the test and keeps no bats fd.
	mkfifo "$BATS_TEST_TMPDIR/control"
	inner -C attach -t proof <"$BATS_TEST_TMPDIR/control" >/dev/null 2>&1 3>&- &
	exec 4>"$BATS_TEST_TMPDIR/control"
	eventually is 2 clients
	inner refresh-client -t "$(inner list-clients -F '#{?client_control_mode,#{client_name},}' | grep .)" -C 20x5
	eventually differs "$before" request
	sleep 0.5
	[ "$(height)" = 3 ]
	row_contains a 3 1 '4:w4'
}

@test "a refresh racing the removal of its session exits quietly" {
	start_session 0 1 2 3 4
	new_session keepalive 0
	attach a 80 24
	eventually is 3 height
	real_tmux=$(command -v tmux)
	mkdir "$BATS_TEST_TMPDIR/shim"
	cat >"$BATS_TEST_TMPDIR/shim/tmux" <<-EOF
		#!/bin/sh
		for argument; do
			[ "\$argument" != source-file ] || sleep 1
		done
		exec "$real_tmux" "\$@"
	EOF
	chmod +x "$BATS_TEST_TMPDIR/shim/tmux"
	PATH="$BATS_TEST_TMPDIR/shim:$PATH" "$helper" refresh "$socket" "$session_id" &
	worker=$!
	sleep 0.3
	inner kill-session -t proof
	wait "$worker"
	[ "$(messages_with 'omp-tmux:')" -eq 0 ]
}

@test "reloading the configuration keeps one copy of each hook and leaves other hooks alone" {
	start_session 0 1 2 3 4
	inner set-hook -g 'client-resized[5]' 'display-message mine'
	inner source-file "$root/omp-tmux.conf"
	inner source-file "$root/omp-tmux.conf"
	hooks=$(inner show-hooks -g)
	for hook in client-attached client-detached client-resized client-session-changed window-linked window-unlinked; do
		[ "$(echo "$hooks" | grep "^$hook\[100\]" | grep -c '@omp_layout')" -eq 1 ]
		[ "$(echo "$hooks" | grep -c "^$hook\[")" -eq "$([ "$hook" = client-resized ] && echo 2 || echo 1)" ]
	done
	echo "$hooks" | grep -qF 'client-resized[5] display-message mine'
}

@test "a persistent failure is reported once while the stale guard retries" {
	start_session 0 2 4 6 8
	attach a 80 24
	eventually row_contains a 3 1 '8:w8'
	inner set -g @omp_max_rows x
	inner move-window -r -t proof
	eventually is 1 messages_with '@omp_max_rows must be'
	sleep 3
	[ "$(messages_with '@omp_max_rows must be')" -eq 1 ]
	inner set -g @omp_max_rows 5
	eventually row_contains a 3 1 '4:w8'
	[ -z "$(inner show-options -q -v -t proof @omp_layout_error)" ]
}
