# Shared helpers for tests on real attached clients. An outer tmux server hosts each
# client, so its capture-pane sees the real status rows.

setup() {
	# Tests run as the invoking user, so on a workstation one stray kill reaches every session.
	if [ ! -f /.dockerenv ] && [ ! -f /run/.containerenv ] && [ "${CI:-}" != true ]; then
		echo "refusing to start tmux outside a container, run tests/run.sh" >&2
		return 1
	fi
	# No test may reach a tmux server it did not start, even through an inherited TMUX.
	unset TMUX
	isolated_tmpdir=$(mktemp -d /tmp/omp-tmux.XXXXXX)
	export TMUX_TMPDIR="$isolated_tmpdir"
	# macOS has no C.UTF-8, so CI passes its own UTF-8 locale.
	export LC_ALL="${LC_ALL:-C.UTF-8}"
	root="$BATS_TEST_DIRNAME/.."
	helper="$root/scripts/omp-layout.sh"
	inner_socket="omp-in-$$-$BATS_TEST_NUMBER"
	outer_socket="omp-out-$$-$BATS_TEST_NUMBER"
	printf 'set -g status off\nset -g remain-on-exit on\n' >"$BATS_TEST_TMPDIR/outer.conf"
}

# Only a setup that got past the guard owns servers to stop, and only in its own socket directory.
teardown() {
	[ -n "${isolated_tmpdir:-}" ] || return 0
	TMUX_TMPDIR="$isolated_tmpdir" tmux -L "$outer_socket" kill-server 2>/dev/null || true
	TMUX_TMPDIR="$isolated_tmpdir" tmux -L "$inner_socket" kill-server 2>/dev/null || true
	rm -rf "$isolated_tmpdir"
}

inner() { tmux -L "$inner_socket" "$@"; }
outer() { tmux -L "$outer_socket" "$@"; }

# eventually retries a command for up to 5 seconds, so $(...) checks go through is to rerun.
eventually() {
	tries=0
	unset last_output
	until "$@"; do
		tries=$((tries + 1))
		if [ "$tries" -ge 50 ]; then
			echo "gave up waiting for: $*${last_output+, last output: [$last_output]}" >&2
			return 1
		fi
		sleep 0.1
	done
}

# is WANT CMD... succeeds when CMD prints exactly WANT.
is() {
	want=$1
	shift
	last_output=$("$@")
	[ "$last_output" = "$want" ]
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

# BSD wc pads its count with spaces, so lines are counted with grep.
clients() { inner list-clients | grep -c '' || true; }

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

row_contains() {
	case $(row "$1" "$2" "$3") in *"$4"*) return 0 ;; esac
	return 1
}

# starts CLIENT ROWS K TEXT succeeds when status row K begins with TEXT.
starts() {
	last_output=$(row "$1" "$2" "$3")
	[ "${last_output:0:${#4}}" = "$4" ]
}

cell() {
	r=$(row "$1" "$2" "$3")
	printf '%s' "${r:$(($4 * $5)):$5}"
}

title() {
	printf '\033]2;%s\007' "$2" >"$(inner display-message -p -t "proof:$1" '#{pane_tty}')"
	eventually is "$2" inner display-message -p -t "proof:$1" '#{pane_title}'
}

ring() {
	printf '\a' >"$(inner display-message -p -t "proof:$1" '#{pane_tty}')"
	eventually is 1 inner display-message -p -t "proof:$1" '#{window_bell_flag}'
}

shows() { outer capture-pane -p -t "$1" | grep -qF -- "$2"; }
hides() { ! shows "$@"; }

# menu CLIENT [KEY] opens the agent menu with prefix KEY, A by default.
menu() {
	outer send-keys -t "$1" C-b "${2:-A}"
	eventually shows "$1" 'omp-tmux agents'
}

# pick CLIENT KEY chooses KEY from the agent menu on CLIENT.
pick() {
	menu "$1"
	outer send-keys -t "$1" "$2"
}
