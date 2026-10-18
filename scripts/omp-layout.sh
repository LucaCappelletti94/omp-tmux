#!/bin/sh
# Computes and publishes the omp-tmux multirow status layout.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
program="$here/omp-layout.awk"
self="$here/$(basename -- "$0")"

usage() {
	cat >&2 <<-EOF
		usage: omp-layout.sh plan MAX_ROWS LABEL_WIDTH
		       omp-layout.sh render SESSION REQUEST shown|hidden|off
		       omp-layout.sh refresh SOCKET SESSION
		       omp-layout.sh refresh-all SOCKET
		       omp-layout.sh publish SOCKET SESSION REQUEST
	EOF
	exit 2
}

tm() { tmux -S "$socket" "$@"; }

# The stale guard retries at every redraw, so each distinct failure shows once. The text goes in
# through argv, and if-shell checks and records its checksum in one atomic command.
report() {
	key="@omp_layout_message_$$"
	sum=$(printf '%s' "$1" | cksum | cut -d ' ' -f 1)
	tm set-option -t "$session" "$key" "$1" 2>/dev/null || return 0
	tm if-shell -F -t "$session" "#{!=:#{@omp_layout_error},$sum}" \
		"set-option -t '$session' @omp_layout_error $sum ; display-message -t '$session' '#{$key}'" 2>/dev/null || true
	tm set-option -u -t "$session" "$key" 2>/dev/null || true
}

# Only the request id still stored on the session may publish, so a newer or expired refresh wins.
publish() {
	dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-layout.XXXXXX")
	trap 'rm -rf "$dir"' EXIT
	trap 'exit 143' TERM
	if ! {
		max_rows=$(tm display-message -p -t "$session" '#{@omp_max_rows}') &&
			label_width=$(tm display-message -p -t "$session" '#{@omp_label_width}') &&
			own_status=$(tm show-options -qv -t "$session" status) &&
			global_status=$(tm show-options -gqv status) &&
			bar_flag=$(tm show-options -qv -t "$session" @omp_bar) &&
			tm list-windows -t "$session" -F 'window #{window_index}' >"$dir/meta" &&
			tm list-clients -t "$session" -F 'client #{client_width} #{client_height} #{client_control_mode}' >>"$dir/meta" &&
			tm display-message -p -t "$session" 'key #{@omp_key}' >>"$dir/meta"
	} 2>"$dir/error"; then
		tm has-session -t "$session" 2>/dev/null || exit 0
		report "omp-tmux: layout refresh failed: $(head -n 1 "$dir/error")"
		exit 1
	fi
	# The session's own off is the user's and stays. A global off hides the bar unless the
	# menu showed it, which leaves the session's own status set and @omp_bar at shown.
	if [ "$own_status" = off ]; then
		bar=off
	elif [ "$global_status" = off ] && { [ -z "$own_status" ] || [ "$bar_flag" != shown ]; }; then
		bar=hidden
	else
		bar=shown
	fi
	if ! "$self" plan "$max_rows" "$label_width" <"$dir/meta" >"$dir/plan"; then
		report "$(head -n 1 "$dir/plan")"
		exit 1
	fi
	"$self" render "$session" "$request" "$bar" <"$dir/plan" >"$dir/batch"
	if ! tm source-file "$dir/batch" 2>"$dir/error"; then
		tm has-session -t "$session" 2>/dev/null || exit 0
		report "omp-tmux: layout refresh failed: $(head -n 1 "$dir/error")"
		exit 1
	fi
}

# The worker gets two seconds, then its request is retired and it and its children are killed.
refresh() {
	request="$$.$(date +%s)"
	tm set-option -t "$session" @omp_layout_request "$request" 2>/dev/null || return 0
	"$self" publish "$socket" "$session" "$request" &
	worker=$!
	(
		sleep 2
		# Once fired, the watchdog must outlive the cleanup below to show its message.
		trap '' TERM
		kill -0 "$worker" 2>/dev/null || exit 0
		tm set-option -t "$session" @omp_layout_request "expired.$request" 2>/dev/null || true
		pkill -TERM -P "$worker" 2>/dev/null || true
		kill -TERM "$worker" 2>/dev/null || true
		report 'omp-tmux: layout refresh exceeded 2 seconds and was stopped'
	) 2>/dev/null &
	watchdog=$!
	status=0
	wait "$worker" || status=$?
	# BSD pkill stops reading options at the pattern, so -P must come first.
	pkill -TERM -P "$watchdog" -x sleep 2>/dev/null || true
	kill -TERM "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	return "$status"
}

case ${1-} in
plan)
	[ $# -eq 3 ] || usage
	exec awk -v stage=plan -v max_rows="$2" -v label_width="$3" -f "$program"
	;;
render)
	[ $# -eq 4 ] || usage
	exec awk -v stage=render -v session="$2" -v request="$3" -v bar="$4" -f "$program"
	;;
publish)
	[ $# -eq 4 ] || usage
	socket=$2 session=$3 request=$4
	publish
	;;
refresh)
	[ $# -eq 3 ] || usage
	socket=$2 session=$3
	[ -n "$session" ] || exit 0
	refresh
	;;
refresh-all)
	[ $# -eq 2 ] || usage
	socket=$2
	failed=0
	for session in $(tm list-sessions -F '#{session_id}' 2>/dev/null); do
		refresh || failed=1
	done
	exit "$failed"
	;;
*)
	usage
	;;
esac
