#!/usr/bin/env bats
# An outer tmux server hosts each client, so its capture-pane sees the real status rows.

setup() {
	export LC_ALL=C.UTF-8
	root="$BATS_TEST_DIRNAME/.."
	helper="$root/scripts/omp-layout.sh"
	inner_socket="omp-in-$$-$BATS_TEST_NUMBER"
	outer_socket="omp-out-$$-$BATS_TEST_NUMBER"
	printf 'set -g status off\nset -g remain-on-exit on\n' >"$BATS_TEST_TMPDIR/outer.conf"
}

teardown() {
	tmux -L "$outer_socket" kill-server 2>/dev/null || true
	tmux -L "$inner_socket" kill-server 2>/dev/null || true
}

inner() { tmux -L "$inner_socket" "$@"; }
outer() { tmux -L "$outer_socket" "$@"; }

# eventually retries a command for up to 5 seconds, so $(...) checks go through is to rerun.
eventually() {
	tries=0
	until "$@"; do
		tries=$((tries + 1))
		[ "$tries" -lt 50 ] || return 1
		sleep 0.1
	done
}

# is WANT CMD... succeeds when CMD prints exactly WANT.
is() {
	want=$1
	shift
	[ "$("$@")" = "$want" ]
}

start_session() {
	inner -f /dev/null new-session -d -s proof -n w0 -x 80 -y 24 'sleep 600'
	keep_zero=0
	for i in "$@"; do
		if [ "$i" -eq 0 ]; then keep_zero=1; else inner new-window -d -n "w$i" -t "proof:$i" 'sleep 600'; fi
	done
	[ "$keep_zero" -eq 1 ] || inner kill-window -t proof:0
	inner source-file "$root/omp-tmux.conf"
	session_id=$(inner display-message -p -t proof '#{session_id}')
	socket=$(inner display-message -p '#{socket_path}')
}

clients() { inner list-clients | wc -l; }

attach() {
	expected=$(($(clients) + 1))
	if outer has-session 2>/dev/null; then
		outer new-session -d -s "$1" -x "$2" -y "$3" "env -u TMUX tmux -L $inner_socket attach -t proof"
	else
		outer -f "$BATS_TEST_TMPDIR/outer.conf" new-session -d -s "$1" -x "$2" -y "$3" \
			"env -u TMUX tmux -L $inner_socket attach -t proof"
	fi
	eventually is "$expected" clients || {
		echo "client $1 did not attach: expected $expected clients, list-clients shows:" >&2
		inner list-clients -F '#{client_name} #{client_width}x#{client_height} control=#{client_control_mode} session=#{session_name}' >&2
		echo "its pane shows:" >&2
		outer capture-pane -p -t "$1" | grep -v '^$' >&2
		return 1
	}
}

refresh() { "$helper" refresh "$socket" "$session_id"; }

height() { inner show-options -v -t proof status; }

# row CLIENT ROWS K prints status row K of a ROWS-high bar.
row() { outer capture-pane -N -p -t "$1" | tail -n "$2" | sed -n "$(($3 + 1))p"; }
styled_row() { outer capture-pane -e -p -t "$1" | tail -n "$2" | sed -n "$(($3 + 1))p"; }

row_contains() { case $(row "$1" "$2" "$3") in *"$4"*) return 0 ;; esac; return 1; }

cell() { r=$(row "$1" "$2" "$3"); printf '%s' "${r:$(($4 * $5)):$5}"; }

title() {
	printf '\033]2;%s\007' "$2" >"$(inner display-message -p -t "proof:$1" '#{pane_tty}')"
	eventually is "$2" inner display-message -p -t "proof:$1" '#{pane_title}'
}

ring() {
	printf '\a' >"$(inner display-message -p -t "proof:$1" '#{pane_tty}')"
	eventually is 1 inner display-message -p -t "proof:$1" '#{window_bell_flag}'
}

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
	row_contains a 4 3 'page 2/2'
	row_contains b 4 3 '?1 '
	row_contains b 4 0 '126:'
	row_contains b 4 2 '132:'
	inner select-window -t proof:101
	eventually row_contains b 4 3 'page 1/4'
	row_contains b 4 0 '101:'
	row_contains a 4 3 'page 1/2'
}

@test "a width without a computed layout falls back to the native row" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	outer resize-window -t a -x 100 -y 24
	eventually row_contains a 3 0 '?0 +0 ^0'
	native=$(row a 3 0)
	case $native in *'0:'*'1:'*'2:'*'3:'*'4:'*) ;; *) false ;; esac
	[ -z "$(row a 3 1 | tr -d ' ')" ]
}

@test "prefix A r lays the bar out again for the current width" {
	start_session 0 1 2 3 4
	attach a 80 24
	refresh
	eventually row_contains a 3 1 '4:'
	outer resize-window -t a -x 100 -y 24
	eventually row_contains a 3 0 '?0 +0 ^0'
	outer send-keys -t a C-b A
	eventually is omp-agent inner display-message -p '#{client_key_table}'
	outer send-keys -t a r
	eventually row_contains a 3 2 '5 windows'
	first=$(row a 3 0)
	[ "${first:28:2}" = '1:' ]
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
	eventually row_contains a 1 0 ' 7:w7'
	only=$(row a 1 0)
	[ "${only:0:8}" = '    7:w7' ]
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
	eventually eval 'inner show-messages | grep -q "omp-tmux: @omp_max_rows must be a positive integer"'
	[ "$(height)" = 3 ]
}

@test "a superseded request never publishes" {
	start_session 0 1 2 3 4
	attach a 80 24
	inner set-option -t proof @omp_layout_request newer
	"$helper" publish "$socket" "$session_id" older
	[ -z "$(inner show-options -q -v -t proof status)" ]
}

@test "a refresh exceeding two seconds is stopped and leaves the layout" {
	start_session 0 1 2 3 4
	attach a 80 24
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
	[ -z "$(inner show-options -q -v -t proof status)" ]
	eventually eval 'inner show-messages | grep -q "omp-tmux: layout refresh exceeded 2 seconds"'
	eventually eval '! pgrep -f "sleep 47" >/dev/null'
}
