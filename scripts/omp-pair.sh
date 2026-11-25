#!/bin/sh
# A pair owns one temporary window and two clients on the same server.
set -eu

action=$1 socket=$2 session=$3
shift 3
tm() { tmux -S "$socket" "$@"; }
field() { tm display-message -p -t "$1" "$2"; }
error() { printf 'OMP pair: %s\n' "$1" >&2; exit 1; }
id() {
	case $1 in "$2"*) ;; *) return 1 ;; esac
	case ${1#?} in ''|*[!0-9]*) return 1 ;; esac
}
id "$session" '$' || error 'Invalid source session.'
record_key=@omp_pair_record_${session#?}
dock_script=${0%/*}/omp-dock.sh

# Only fixed tmux identifiers and boolean tests cross the shell boundary.
agent='#{&&:#{m/r:^π [>!⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] .+,#{pane_title}},#{==:#{pane_dead},0}}'
work() {
	[ "$(field "$session:$1.$2" "#{session_id} #{window_id} #{pane_id} $agent #{?#{||:#{@omp_navigator},#{@omp_dock_slot}},slot,work}")" = "$session $1 $2 1 work" ]
}
sources() {
	[ "$(field "$session:" '#{session_id} #{window_id} #{session_grouped} -#{@omp_pair_owner}')" = "$session $left 0 -" ] &&
		work "$left" "$left_pane" && work "$right" "$right_pane"
}
exclusive() {
	tm list-windows -a -F '#{window_id}' | awk -v left="$left" -v right="$right" '
		$1 == left { first++ } $1 == right { second++ } END { exit !(first == 1 && second == 1) }'
}
preflight() {
	[ "$left" != "$right" ] || error 'Choose a different agent window.'
	[ -z "$(field "$session:" '#{@omp_pair_busy}#{@omp_pair_owner}')" ] || error 'This session already belongs to a pair.'
	sources || error 'Choose two live OMP windows in the current ungrouped session.'
	exclusive || error 'A shared work window cannot be paired.'
}

# Preserve manual dimensions and explicit versus inherited sizing options.
fit_work() {
	policy=$(tm show-options -wqv -t "$1" window-size)
	aggressive=$(tm show-options -wqv -t "$1" aggressive-resize)
	size=$(field "$1" '#{window-size} #{window_width} #{window_height}')
	tm set-option -wo -t "$1" @omp_pair_sizing "$session ${policy:--} ${aggressive:--} $size" \; \
		set-option -w -t "$1" window-size smallest \; set-option -w -t "$1" aggressive-resize on
}
restore_work() {
	saved=$(tm show-options -wqv -t "$1" @omp_pair_sizing 2>/dev/null) || return 0
	read -r owner policy aggressive effective width height <<-EOF
	$saved
	EOF
	[ "$owner" = "$session" ] || return 0
	work_window=$1
	set -- set-option -wqu -t "$work_window" @omp_pair_sizing
	if [ "$effective" = manual ]; then set -- "$@" \; resize-window -t "$work_window" -x "$width" -y "$height"; fi
	if [ "$policy" = - ]; then set -- "$@" \; set-option -wu -t "$work_window" window-size
	else set -- "$@" \; set-option -w -t "$work_window" window-size "$policy"; fi
	if [ "$aggressive" = - ]; then set -- "$@" \; set-option -wu -t "$work_window" aggressive-resize
	else set -- "$@" \; set-option -w -t "$work_window" aggressive-resize "$aggressive"; fi
	tm "$@" >/dev/null
}

make_view() {
	window=$1 pane=$2
	created=$(tm new-session -dP -F '#{session_id} #{window_id}' -s "omp-view-${session#?}-${window#?}" sleep 15)
	read -r view scratch <<-EOF
	$created
	EOF
	if [ "$window" = "$left" ]; then left_view=$view; else right_view=$view; fi
	tm set-option -t "$view" @omp_pair_owner "$session" \; set-option -t "$view" destroy-unattached off \; \
		set-option -t "$view" detach-on-destroy on \; set-option -t "$view" status off \; set-option -t "$view" @omp_bar dock \; \
		set-option -t "$view" prefix None \; set-option -t "$view" prefix2 None \; set-option -t "$view" key-table omp-pair-input \; \
		set-option -t "$view" mouse off \; set-option -t "$view" set-titles off \; \
		link-window -d -s "$session:$window" -t "$view:" \; kill-window -t "$view:$scratch" \; select-pane -t "$view:$window.$pane"
}

retire() {
	# Never replace a native window selection that has already left the pair.
	if [ -n "$host" ] && { [ "$action" = setup ] || [ "$(field "$host" '#{@omp_pair_host}' 2>/dev/null)" = "$session" ]; }; then
		for destination in "${preferred:-$left}" "$left" "$right"; do
			tm if-shell -F -t "$session:" "#{==:#{window_id},$host}" "select-window -t '$session:$destination'" 2>/dev/null && break
		done
		tm kill-window -t "$host" 2>/dev/null || :
	fi
	for view in "$left_view" "$right_view"; do
		[ -n "$view" ] || continue
		if [ "$action" = setup ] || [ "$(field "$view:" '#{@omp_pair_owner}' 2>/dev/null)" = "$session" ]; then
			tm kill-session -t "$view" 2>/dev/null || :
		fi
	done
	restore_work "$left" || :
	restore_work "$right" || :
	tm set-option -qu -t "$session" @omp_pair_window \; set-option -qu -t "$session" @omp_pair_busy 2>/dev/null || return 0
	if [ "$reopen" = 1 ]; then sh "$dock_script" resume "$socket" "$session"; fi
}

setup_failed() {
	trap - EXIT HUP INT TERM
	tm set-option -gqu "$record_key" 2>/dev/null || :
	retire || :
	tm display-message -t "$session" 'OMP pair could not open. The work window, its agent or its available space changed.' 2>/dev/null || :
}

healthy() {
	# An explicit session target proves each original still has its owner link.
	state=$(tm display-message -p -t "$session:" '#{window_id} #{window_panes} #{P:#{pane_dead}}' \; \
		display-message -p -t "$session:$left.$left_pane" '#{session_id} #{window_id} #{pane_id} #{pane_dead}' \; \
		display-message -p -t "$session:$right.$right_pane" '#{session_id} #{window_id} #{pane_id} #{pane_dead}' \; \
		display-message -p -t "$left_view:" '#{session_id} #{window_id} #{session_windows} #{session_attached}' \; \
		display-message -p -t "$right_view:" '#{session_id} #{window_id} #{session_windows} #{session_attached}' 2>/dev/null) || return 1
	[ "$state" = "$host 2 00
$session $left $left_pane 0
$session $right $right_pane 0
$left_view $left 1 1
$right_view $right 1 1" ]
}

case $action in
open|setup)
	[ "$#" = 4 ] || error 'Expected two window and pane IDs.'
	left=$1 left_pane=$2 right=$3 right_pane=$4
	id "$left" @ && id "$right" @ && id "$left_pane" % && id "$right_pane" % || error 'Invalid work target.'
	if [ "$action" = open ]; then
		preflight
		tm run-shell -b -t "$session:" "#{E:@omp_pair_command} setup #{q:socket_path} '$session' '$left' '$left_pane' '$right' '$right_pane'"
		exit
	fi
	host='' left_view='' right_view='' reopen=0
	if ! tm set-option -o -t "$session" @omp_pair_busy "$$" 2>/dev/null; then
		tm display-message -t "$session" 'OMP pair is already open or being prepared.'
		exit 1
	fi
	trap setup_failed EXIT
	trap 'exit 1' HUP INT TERM
	sources && exclusive || exit 1
	if [ -n "$(field "$session:" '#{@omp_dock_status}')" ]; then reopen=1; fi
	sh "$dock_script" suspend "$socket" "$session"
	sources && exclusive || exit 1
	for window in "$left" "$right"; do
		[ -z "$(field "$window" '#{P:#{?#{||:#{@omp_navigator},#{@omp_dock_slot}},slot,}}')" ] || exit 1
		fit_work "$window"
	done
	make_view "$left" "$left_pane"
	make_view "$right" "$right_pane"
	# The two numeric fields at the end of TMUX follow the complete socket path.
	attach='server=${TMUX%,*}; socket=${server%,*}; unset TMUX TMUX_PANE; exec tmux -S "$socket" attach-session -Et "$1"'
	created=$(tm new-window -dP -F '#{window_id} #{pane_id}' -t "$session:" -n 'OMP pair' sh -c "$attach" sh "$left_view")
	read -r host first <<-EOF
	$created
	EOF
	second=$(tm split-window -dhP -F '#{pane_id}' -t "$host" sh -c "$attach" sh "$right_view")
	tm set-option -w -t "$host" @omp_pair_host "$session" \; set-option -w -t "$host" synchronize-panes off \; set-option -w -t "$host" window-size latest \; \
		set-option -p -t "$first" @omp_pair_return "$left" \; set-option -p -t "$second" @omp_pair_return "$right" \; \
		set-option -p -t "$first" remain-on-exit off \; set-option -p -t "$second" remain-on-exit off \; select-layout -t "$host" even-horizontal >/dev/null
	# Wait only for the two native clients created by this request to attach.
	attempt=0
	while [ "$(tm display-message -p -t "$left_view:" '#{session_attached}' \; display-message -p -t "$right_view:" '#{session_attached}')" != '1
1' ]; do
		attempt=$((attempt + 1)); [ "$attempt" -lt 40 ] || exit 1
		sleep 0.05
	done
	if tm list-keys -T prefix Space 2>/dev/null | grep -Eq '^bind-key[[:space:]]+-T[[:space:]]+prefix[[:space:]]+Space[[:space:]]+next-layout$'; then
		tm run-shell -C -t "$session:" '#{@omp_bind_pair_space}'
	fi
	sources || exit 1
	record="$host $left $left_pane $left_view $right $right_pane $right_view $reopen"
	published=$(tm if-shell -F -t "$session:" "#{==:#{window_id},$left}" \
		"select-window -t '$session:$host' ; set-option -g $record_key '$record' ; set-option -t '$session' @omp_pair_window '$host' ; display-message -p ready")
	[ "$published" = ready ] || exit 1
	trap - EXIT HUP INT TERM
	;;
check|close|lost)
	record=$(tm show-options -gqv "$record_key" 2>/dev/null) || exit 0
	[ -n "$record" ] || exit 0
	read -r host left left_pane left_view right right_pane right_view reopen <<-EOF
	$record
	EOF
	id "$host" @ && id "$left" @ && id "$right" @ && id "$left_pane" % && id "$right_pane" % && id "$left_view" '$' && id "$right_view" '$' || exit 1
	case $reopen in 0|1) ;; *) exit 1 ;; esac
	if [ "$action" != lost ]; then [ "$host" = "${1-}" ] || exit 0; fi
	if [ "$action" = check ] && healthy; then exit 0; fi
	preferred=$left
	if [ "$action" = close ] && [ "$(field "$session:$host" '#{@omp_pair_return}' 2>/dev/null)" = "$right" ]; then preferred=$right; fi
	# Only the first hook for this exact generation retires its resources.
	claimed=$(tm if-shell -F "#{==:#{$record_key},$record}" "set-option -gu $record_key ; display-message -p claimed") || exit 0
	[ "$claimed" = claimed ] || exit 0
	retire
	;;
*) exit 2 ;;
esac
