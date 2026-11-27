#!/usr/bin/env bats

load helpers

pane_size() { inner display-message -p -t "$1" '#{pane_width}x#{pane_height}'; }
pane_width() { inner display-message -p -t "$1" '#{pane_width}'; }
focused_pane() { inner display-message -p -t proof '#{pane_id}'; }
in_copy_mode() { inner display-message -p -t "$1" '#{pane_in_mode}'; }

@test "Shift+Tab returns to the current prompt without opening the highlighted agent or resizing a split" {
	start_session 0 3
	title 0 'π > SOURCE: Source agent'
	title 3 'π > OTHER: Filter needle'
	work=$(focused_pane)
	sibling=$(inner split-window -vdP -F '#{pane_id}' -t "$work" 'sleep 600')
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	dock=$(focused_pane)
	outer send-keys -l -t a needle
	eventually shows a '/ needle'
	hides a 'Source agent'
	size=$(pane_size "$work")
	inner copy-mode -t "$sibling" \; copy-mode -t "$work"
	outer send-keys -t a BTab
	eventually is "$work" focused_pane
	is "$size" pane_size "$work"
	is 0 in_copy_mode "$work"
	is 1 in_copy_mode "$sibling"
	shows a 'Filter needle'
	outer send-keys -t a BTab
	eventually is "$dock" focused_pane
	shows a 'Filter needle'
	hides a 'Source agent'
}

@test "Alt+z zooms only the work pane and restores the same dock after resizing and switching windows" {
	start_session 0 3
	title 0 'π > HOME: Current session'
	title 3 'π > OTHER: Filter needle'
	work=$(focused_pane)
	sibling=$(inner split-window -vdP -F '#{pane_id}' -t "$work" 'sleep 600')
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	dock=$(focused_pane)
	outer send-keys -l -t a needle
	eventually shows a '/ needle'
	hides a 'Current session'
	inner copy-mode -t "$sibling"
	outer send-keys -t a M-z
	eventually is "$work" focused_pane
	eventually is 110x28 pane_size "$work"
	eventually hides a 'NAVIGATOR'
	is 1 in_copy_mode "$sibling"
	outer resize-window -t a -x 128 -y 32
	eventually is 128x32 pane_size "$work"
	outer send-keys -t a C-b 3
	eventually shows a 'Filter needle'
	is 1 inner display-message -p -t "$work" '#{window_zoomed_flag}'
	outer send-keys -t a C-b 0
	eventually is "$work" focused_pane
	is 128x32 pane_size "$work"
	outer send-keys -t a M-z
	eventually shows a 'Filter needle'
	is "$work" focused_pane
	is "$dock" inner show-options -qv -t proof @omp_dock_pane
	is 0 inner display-message -p -t "$work" '#{window_zoomed_flag}'
	is 1 in_copy_mode "$sibling"
	hides a 'Current session'
	outer send-keys -t a M-z
	eventually is 128x32 pane_size "$work"
	outer send-keys -t a BTab
	eventually is "$dock" focused_pane
	eventually shows a 'Filter needle'
	hides a 'Current session'
}

@test "opening the navigator from the agent menu restores a fullscreen work window" {
	start_session 0
	title 0 'π > SOURCE: Source agent'
	work=$(focused_pane)
	inner split-window -vd -t "$work" 'sleep 600'
	attach a 110 28
	outer send-keys -t a M-z
	eventually is 1 inner display-message -p -t "$work" '#{window_zoomed_flag}'
	pick a l
	eventually shows a 'Shift+Tab work'
	is 0 inner display-message -p -t "$work" '#{window_zoomed_flag}'
	[ "$(focused_pane)" != "$work" ]
}

@test "choosing a window lands on its live prompt without resizing either window's work panes" {
	start_session 0 1
	title 0 'π > HOME: Source work'
	title 1 'π > DEST: Target work'
	origin=$(focused_pane)
	sibling=$(inner split-window -vdP -F '#{pane_id}' -t "$origin" 'sleep 600')
	target=$(inner display-message -p -t proof:1 '#{pane_id}')
	attach a 110 28
	eventually is 110 pane_width "$origin"
	inner select-window -t "$target"
	terminal=$(inner display-message -p -t "$target" '#{pane_tty}')
	for line in {1..120}; do printf 'Transcript row %03d\n' "$line"; done >"$terminal"
	printf 'LIVE PROMPT 711> ' >"$terminal"
	eventually shows a 'LIVE PROMPT 711>'
	inner copy-mode -t "$target" \; send-keys -t "$target" -X history-top
	eventually shows a 'Transcript row 001'
	hides a 'LIVE PROMPT 711>'
	inner select-window -t "$origin" \; copy-mode -t "$sibling"
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	eventually shows a 'Target work'
	dock=$(focused_pane)
	work_width=$(pane_width "$origin")
	[ "$work_width" -lt 110 ]
	eventually is "$work_width" pane_width "$target"
	origin_size=$(pane_size "$origin")
	sibling_size=$(pane_size "$sibling")
	target_size=$(pane_size "$target")
	is 1 in_copy_mode "$target"
	is 1 in_copy_mode "$sibling"

	outer send-keys -t a Down Enter
	eventually is "$target" focused_pane
	eventually shows a 'Transcript row'
	shows a 'LIVE PROMPT 711>'
	is 0 in_copy_mode "$target"
	is 1 in_copy_mode "$sibling"
	is "$origin_size" pane_size "$origin"
	is "$sibling_size" pane_size "$sibling"
	is "$target_size" pane_size "$target"

	outer send-keys -t a BTab
	eventually is "$dock" focused_pane
	outer send-keys -t a Up Enter
	eventually is "$origin" focused_pane
	is "$origin_size" pane_size "$origin"
	is "$sibling_size" pane_size "$sibling"
	is "$target_size" pane_size "$target"
	is 1 in_copy_mode "$sibling"

	outer send-keys -t a BTab
	eventually is "$dock" focused_pane
	pick a l
	eventually is "$origin" focused_pane
	eventually is 110 pane_width "$origin"
	is 110 pane_width "$sibling"
	is 2 inner display-message -p -t "$origin" '#{window_panes}'
	inner select-window -t "$target"
	eventually is 110 pane_width "$target"
	is 1 inner display-message -p -t "$target" '#{window_panes}'
}

@test "hiding returns to the last work split's live prompt and preserves other scrollback selections" {
	start_session 0
	title 0 'π > LAB: Recent measurements'
	neighbor=$(focused_pane)
	work=$(inner split-window -vP -t "$neighbor" -F '#{pane_id}' 'sleep 600')
	attach a 110 28
	terminal=$(inner display-message -p -t "$work" '#{pane_tty}')
	for line in {1..140}; do printf 'Spectrum record %03d\n' "$line"; done >"$terminal"
	printf 'LIVE WORK PROMPT 711> ' >"$terminal"
	eventually shows a 'LIVE WORK PROMPT 711>'
	inner copy-mode -t "$neighbor" \; copy-mode -t "$work" \; send-keys -t "$work" -X history-top
	eventually shows a 'Spectrum record 001'
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	pick a l
	eventually is 110 pane_width "$work"
	is "$work" focused_pane
	is 0 in_copy_mode "$work"
	is 1 in_copy_mode "$neighbor"
	eventually shows a 'LIVE WORK PROMPT 711>'
	hides a 'Spectrum record 001'
	inner capture-pane -p -t "$work" -S - | grep -F 'Spectrum record 001'
}

@test "a new background agent is sized before selection and exiting its last work pane removes the inactive window" {
	start_session 0
	title 0 'π > HOME: Source work'
	origin=$(focused_pane)
	attach a 110 28
	outer send-keys -t a BTab
	eventually shows a 'Shift+Tab work'
	eventually shows a 'Source work'
	dock=$(focused_pane)
	origin_size=$(pane_size "$origin")
	target=$(inner new-window -dP -F '#{pane_id}' -t proof:1 'printf "\033]2;π > NEW: Background job\007"; read -r finish')
	eventually shows a 'Background job'
	eventually is "$origin_size" pane_size "$target"
	is "$dock" focused_pane
	outer send-keys -t a Down Enter
	eventually is "$target" focused_pane
	is "$origin_size" pane_size "$target"
	is "$origin_size" pane_size "$origin"
	inner select-window -t "$origin"
	eventually shows a 'Background job'
	eventually is 0 inner display-message -p -t "$dock" '#{window_index}'
	inner send-keys -t "$target" Enter
	eventually is 0 inner list-windows -t proof -F '#{window_index}'
	eventually hides a 'Background job'
	shows a 'Source work'
	is "$origin_size" pane_size "$origin"
}
