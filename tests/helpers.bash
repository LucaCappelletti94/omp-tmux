# Shared helpers for tests on real attached clients. An outer tmux server hosts each
# client, so its capture-pane sees the real status rows.

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

# differs OLD CMD... succeeds when CMD prints anything but OLD.
differs() {
	old=$1
	shift
	[ "$("$@")" != "$old" ]
}

# The message log also records commands and key bindings, so only displayed messages are counted.
messages_with() { inner show-messages | grep -F ' message: ' | grep -c "$1" || true; }

no_process() { ! pgrep -f "$1" >/dev/null; }

request() { inner show-options -v -t proof @omp_layout_request; }

# new_session NAME INDEX... adds a session with windows named wINDEX.
new_session() {
	name=$1
	shift
	if inner has-session 2>/dev/null; then
		inner new-session -d -s "$name" -n w0 -x 80 -y 24 'sleep 600'
	else
		inner -f /dev/null new-session -d -s "$name" -n w0 -x 80 -y 24 'sleep 600'
	fi
	keep_zero=0
	for i in "$@"; do
		if [ "$i" -eq 0 ]; then keep_zero=1; else inner new-window -d -n "w$i" -t "$name:$i" 'sleep 600'; fi
	done
	[ "$keep_zero" -eq 1 ] || inner kill-window -t "$name:0"
}

start_session() {
	new_session proof "$@"
	inner source-file "$root/omp-tmux.conf"
	session_id=$(inner display-message -p -t proof '#{session_id}')
	socket=$(inner display-message -p '#{socket_path}')
}

clients() { inner list-clients | wc -l; }

# attach NAME WIDTH HEIGHT [SESSION] attaches one more client of that size.
attach() {
	expected=$(($(clients) + 1))
	command="env -u TMUX tmux -L $inner_socket attach -t ${4:-proof}"
	if outer has-session 2>/dev/null; then
		outer new-session -d -s "$1" -x "$2" -y "$3" "$command"
	else
		outer -f "$BATS_TEST_TMPDIR/outer.conf" new-session -d -s "$1" -x "$2" -y "$3" "$command"
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

height() { inner show-options -v -t "${1:-proof}" status; }

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
