#!/bin/sh
# One renderer moves between process-free reservations in its session.
set -eu

action=$1
socket=$2
session=$3
tm() { tmux -S "$socket" "$@"; }
option() { tm show-options -qv -t "$session" "$1"; }

owned='#{||:#{==:#{@omp_dock_slot},#{session_id}},#{==:#{pane_id},#{@omp_dock_pane}}}'

# Hooks from independent clients can overlap. The session option is acquired in one
# tmux command queue and names its owner so a killed helper cannot strand the dock.
lock() {
	attempt=0
	while [ "$attempt" -lt 200 ]; do
		holder=$(tm if-shell -F -t "$session:" '#{@omp_dock_lock}' \
			"display-message -p -t '$session:' '#{@omp_dock_lock}'" \
			"set-option -t '$session' @omp_dock_lock $$ ; display-message -p $$") || return 1
		if [ "$holder" = "$$" ]; then
			trap 'tm set-option -qu -t "$session" @omp_dock_lock 2>/dev/null || :' EXIT
			trap 'exit 1' HUP INT TERM
			return 0
		fi
		if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
			tm if-shell -F -t "$session:" "#{==:#{@omp_dock_lock},$holder}" "set-option -qu -t '$session' @omp_dock_lock"
		fi
		attempt=$((attempt + 1))
		sleep 0.05
	done
	return 1
}

# Only the leftmost leaf's pane ID changes on a swap. Keep every work pane ID.
shape() { printf '%s\n' "${1#*,}" | sed 's/\({[0-9]*x[0-9]*,0,0,\)[0-9]*/\1slot/'; }

release_slot() {
	release_target="$session:$1" slot_pane=$2
	record=$(tm display-message -p -t "$release_target" '#{window_panes} #{window_zoomed_flag} #{pane_id} #{window_layout} #{@omp_dock_reserved} #{@omp_dock_layout}') || return 0
	read -r count zoom active layout reserved original <<-EOF
	$record
	EOF
	if [ "$count" = 1 ]; then tm kill-pane -t "$release_target.$slot_pane"; return; fi
	set -- set-option -wqu -t "$release_target" @omp_dock_reserved \; set-option -wqu -t "$release_target" @omp_dock_layout \
		\; set-option -wqu -t "$release_target" @omp_dock_size \; kill-pane -t "$release_target.$slot_pane"
	if [ -n "$original" ] && [ "$(shape "$layout")" = "$(shape "$reserved")" ]; then
		set -- "$@" \; select-layout -t "$release_target" "$original"
	fi
	if [ "$zoom" = 1 ] && [ "$active" != "$slot_pane" ]; then
		set -- "$@" \; if-shell -F -t "$release_target.$active" '#{==:#{window_zoomed_flag},0}' "resize-pane -Z -t '$release_target.$active'"
	fi
	tm "$@" >/dev/null
}

# Prefer the current work split, then the one that had focus before the dock.
work_action() {
	work=$(tm list-panes -t "$session:" -f "#{==:$owned,0}" -F '#{window_id}.#{pane_id} #{pane_active} #{pane_last}' |
		awk '{rank=1+2*$2+$3; if (rank>best) {best=rank; work=$1}} END {print work}')
	[ -n "$work" ] || return 0
	tm if-shell -F -t "$session:$work" '#{==:#{pane_mode},copy-mode}' "send-keys -t '$session:$work' -X cancel" \
		\; "$@" -t "$session:$work"
}

close_dock() {
	if [ "$action" = toggle ]; then work_action select-pane -Z || :; fi
	slots=$(tm list-panes -s -t "$session:" -f "$owned" -F '#{window_active} #{window_id} #{pane_id}' | sort -k1,1nr)
	tm set-option -qu -t "$session" @omp_dock_status \; set-option -qu -t "$session" @omp_dock_pane
	while read -r current window slot; do
		[ -z "$slot" ] || release_slot "$window" "$slot" || :
	done <<-EOF
	$slots
	EOF
	if [ "$(option @omp_bar)" != dock ]; then
		if [ "$previous" = inherit ]; then tm set-option -u -t "$session" status
		else tm set-option -t "$session" status "$previous"; fi
		tm run-shell -b -t "$session" '#{E:@omp_refresh}'
	fi
}

# Count actual links because a pending window notification also holds a tmux window
# reference. Read client viewports with the status hidden and leave manual sizes alone.
windows() {
	tm display-message -p -t "$session:" 'latest #{client_width} #{client_height}' \; \
		list-clients -t "$session" -F 'client #{client_width} #{client_height} #{client_flags}' \; \
		list-windows -a -F "#{session_id} #{window_id} #{window_active} #{window_width} #{window_height} #{window-size} #{window_zoomed_flag} #{window_panes} -#{P:#{?$owned,#{pane_id},}} -#{@omp_dock_size}" |
	awk -v session="$session" '
		$1 == "latest" { latest_width=$2; latest_height=$3; next }
		$1 == "client" {
			if ($4 ~ /ignore-size/) next
			if (!$2 || !$3) next
			if (!minimum_width || $2 < minimum_width) minimum_width=$2
			if (!minimum_height || $3 < minimum_height) minimum_height=$3
			if ($2 > maximum_width) maximum_width=$2
			if ($3 > maximum_height) maximum_height=$3
			next
		}
		{ links[$2]++; if ($1 == session) rows[$3 ? 0 : ++count]=$0 }
		END {
			for (position=0; position<=count; position++) {
				if (!(position in rows)) continue
				$0=rows[position]; width=$4; height=$5
				if ($6 == "latest" && latest_width && latest_height) { width=latest_width; height=latest_height }
				if ($6 == "smallest" && minimum_width) { width=minimum_width; height=minimum_height }
				if ($6 == "largest" && maximum_width) { width=maximum_width; height=maximum_height }
				state=(links[$2]!=1 || width<76) ? "unavailable" : ($7 ? "zoomed" : "ready")
				print $2, $3, state, $8, $9, $4 "x" $5, width, height, $10
			}
		}'
}

reserve() {
	if [ "$size" != "${width}x$height" ]; then
		policy=$(tm show-options -wqv -t "$target" window-size) || return 1
		set -- resize-window -t "$target" -x "$width" -y "$height" \;
		if [ -n "$policy" ]; then set -- "$@" set-option -w -t "$target" window-size "$policy"
		else set -- "$@" set-option -wu -t "$target" window-size; fi
		tm "$@" || return 1
	fi
	if [ -z "$slot" ]; then
		slot=$(tm set-option -wF -t "$target" @omp_dock_layout '#{window_layout}' \; \
			split-window -dfhb -l 40 -P -F '#{pane_id}' -t "$target" '' \; \
			set-option -p -t "$target.{top-left}" @omp_dock_slot "$session" \; \
			set-option -wF -t "$target" @omp_dock_reserved '#{window_layout}' \; \
			set-option -w -t "$target" @omp_dock_size "${width}x$height" 2>/dev/null) || {
			tm set-option -wqu -t "$target" @omp_dock_layout 2>/dev/null || :
			return 1
		}
	elif [ "$prepared_size" != "-${width}x$height" ]; then
		tm resize-pane -t "$target.$slot" -x 40 \; set-option -w -t "$target" @omp_dock_size "${width}x$height" || return 1
	fi
}

reconcile() {
	rows=$(windows)
	destination='' source=''
	while read -r window current state panes slot size width height prepared_size; do
		[ -n "$window" ] || continue
		target="$session:$window"
		slot=${slot#-}
		if [ -n "$slot" ] && [ "$panes" = 1 ]; then
			release_slot "$window" "$slot" || :
			# Killing the final reservation lets tmux select the next work window.
			if [ "$current" = 1 ]; then return 0; fi
			continue
		fi
		if [ "$state" = zoomed ]; then
			if [ "$current" = 1 ] && [ "$action" = focus ]; then
				tm resize-pane -Z -t "$target" || return 1
				state=ready
			elif [ -z "$slot" ]; then
				continue
			fi
		fi
		if [ "$state" = unavailable ] || { [ "$state" = ready ] && ! reserve; }; then
			if [ "$current" = 1 ]; then
				close_dock
				tm display-message -t "$session" 'Left dock closed. This window cannot reserve space on the left.'
				return 0
			fi
			[ -z "$slot" ] || release_slot "$window" "$slot" || :
			continue
		fi
		if [ "$current" = 1 ]; then destination=$target current_slot=$slot; fi
		if [ "$slot" = "$renderer" ]; then source=$target; fi
	done <<-EOF
	$rows
	EOF
	[ -n "$destination" ] || return 0
	if [ -z "$source" ]; then
		tm set-option -p -t "$destination.$current_slot" remain-on-exit off \; set-option -p -t "$destination.$current_slot" @omp_navigator 1 \
			\; respawn-pane -t "$destination.$current_slot" "$binary" "$socket" "$session" \; set-option -t "$session" @omp_dock_pane "$current_slot" \
			\; set-option -t "$session" @omp_bar dock
		renderer=$current_slot
	elif [ "$source" != "$destination" ]; then
		tm if-shell -F -t "$source.$renderer" '#{pane_active}' "select-pane -lZ -t '$source.$renderer'" \
			\; swap-pane -dZ -s "$source.$renderer" -t "$destination.$current_slot"
	fi
	if [ "$action" != follow ] && [ "$action" != resume ]; then
		tm if-shell -F -t "$destination.$renderer" '#{==:#{pane_mode},copy-mode}' "send-keys -t '$destination.$renderer' -X cancel" \; select-pane -t "$destination.$renderer"
	fi
}

binary=$(dirname "$0")/../target/release/omp-dock
if [ ! -x "$binary" ]; then binary=$(command -v omp-dock || :); fi

case $action in focus | work | fullscreen | follow | toggle | suspend | resume) ;; *) exit 2 ;; esac
lock || exit 1
previous=$(option @omp_dock_status)
if [ "$action" = suspend ]; then
	if [ -n "$previous" ]; then close_dock; fi
	exit 0
fi
if [ -n "$(option @omp_pair_busy)$(option @omp_pair_owner)" ]; then exit 0; fi
if [ "$action" = work ]; then
	work_action select-pane
	exit
fi
if [ "$action" = fullscreen ]; then
	work_action resize-pane -Z
	action=follow
fi
if [ "$action" = toggle ]; then
	if [ -n "$previous" ]; then
		close_dock
		exit
	fi
	action=focus
fi
if [ -z "$previous" ] && [ "$action" = follow ]; then exit; fi
if [ ! -x "$binary" ]; then
	tm display-message -t "$session" 'Build the navigator with cargo build --release --locked in omp-tmux'
	exit
fi
if [ -z "$previous" ]; then
	previous=$(option status)
	previous=${previous:-inherit}
	tm set-option -t "$session" @omp_dock_status "$previous" \; set-option -qu -t "$session" @omp_layout_request \; set-option -t "$session" status off
fi
renderer=$(option @omp_dock_pane)
reconcile
