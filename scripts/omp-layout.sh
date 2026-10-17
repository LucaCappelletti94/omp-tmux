#!/bin/sh
# Computes and publishes the omp-tmux multirow status layout.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
program="$here/omp-layout.awk"
self="$here/$(basename -- "$0")"

usage() {
	cat >&2 <<-EOF
		usage: omp-layout.sh plan MAX_ROWS LABEL_WIDTH
		       omp-layout.sh render SESSION REQUEST
		       omp-layout.sh refresh SOCKET SESSION
		       omp-layout.sh refresh-all SOCKET
		       omp-layout.sh publish SOCKET SESSION REQUEST
	EOF
	exit 2
}

tm() { tmux -S "$socket" "$@"; }

report() { tm display-message -t "$session" "$1" 2>/dev/null || true; }

# Only the request id still stored on the session may publish, so a newer or expired refresh wins.
publish() {
	dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-layout.XXXXXX")
	trap 'rm -rf "$dir"' EXIT
	trap 'exit 143' TERM
	if ! {
		max_rows=$(tm display-message -p -t "$session" '#{@omp_max_rows}') &&
			label_width=$(tm display-message -p -t "$session" '#{@omp_label_width}') &&
			tm list-windows -t "$session" -F 'window #{window_index}' >"$dir/meta" &&
			tm list-clients -t "$session" -F 'client #{client_width} #{client_height} #{client_control_mode}' >>"$dir/meta"
	} 2>"$dir/error"; then
		tm has-session -t "$session" 2>/dev/null || exit 0
		report "omp-tmux: layout refresh failed: $(head -n 1 "$dir/error")"
		exit 1
	fi
	if ! "$self" plan "$max_rows" "$label_width" <"$dir/meta" >"$dir/plan"; then
		report "$(head -n 1 "$dir/plan")"
		exit 1
	fi
	"$self" render "$session" "$request" <"$dir/plan" >"$dir/batch"
	if ! tm source-file "$dir/batch" 2>"$dir/error"; then
		tm has-session -t "$session" 2>/dev/null || exit 0
		report "omp-tmux: layout refresh failed: $(head -n 1 "$dir/error")"
		exit 1
	fi
}

# The worker gets two seconds; on expiry its request is retired before it and its children are killed.
refresh() {
	request="$$.$(date +%s)"
	tm set-option -t "$session" @omp_layout_request "$request" 2>/dev/null || return 0
	"$self" publish "$socket" "$session" "$request" &
	worker=$!
	(
		sleep 2
		kill -0 "$worker" 2>/dev/null || exit 0
		tm set-option -t "$session" @omp_layout_request "expired.$request" 2>/dev/null || true
		pkill -TERM -P "$worker" 2>/dev/null || true
		kill -TERM "$worker" 2>/dev/null || true
		report 'omp-tmux: layout refresh exceeded 2 seconds and was stopped'
	) 2>/dev/null &
	watchdog=$!
	status=0
	wait "$worker" || status=$?
	pkill -TERM -P "$watchdog" 2>/dev/null || true
	wait "$watchdog" 2>/dev/null || true
	return "$status"
}

case ${1-} in
plan)
	[ $# -eq 3 ] || usage
	exec awk -v stage=plan -v max_rows="$2" -v label_width="$3" -f "$program"
	;;
render)
	[ $# -eq 3 ] || usage
	exec awk -v stage=render -v session="$2" -v request="$3" -f "$program"
	;;
publish)
	[ $# -eq 4 ] || usage
	socket=$2 session=$3 request=$4
	publish
	;;
refresh)
	[ $# -eq 3 ] || usage
	socket=$2 session=$3
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
