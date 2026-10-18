#!/usr/bin/env bats
# Geometry of the multirow status layout, computed without a tmux server.

setup() {
	helper="$BATS_TEST_DIRNAME/../scripts/omp-layout.sh"
}

windows() {
	i=$1
	while [ "$i" -le "$2" ]; do
		echo "window $i"
		i=$((i + 1))
	done
}

plan() {
	run "$helper" plan "$@"
}

rows_of() {
	echo "$output" | awk -v w="$1" '$1 == "row" && $2 == w { print $3, $4, $5, $6 }'
}

width_of() {
	echo "$output" | awk -v w="$1" '$1 == "width" && $2 == w'
}

@test "a fleet that fits stays on one row with every window and the full summary" {
	plan 5 20 <<-EOF
		$(windows 0 2)
		client 244 76 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'windows 3 1 1'
	echo "$output" | grep -qx 'height 1'
	[ "$(width_of 244)" = 'width 244 line 10 24 18 18 1 waiting,bells,priority,total,hints,session,zoom,clock' ]
	[ "$(rows_of 244)" = '0 0 0 2' ]
}

@test "overflowing one row wraps into grid rows above a summary row" {
	plan 5 20 <<-EOF
		$(windows 0 4)
		client 80 24 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 3'
	[ "$(width_of 80)" = 'width 80 grid 4 20 14 14 1 waiting,bells,priority,total,hints,session,zoom,clock' ]
	[ "$(rows_of 80)" = "$(printf '0 0 0 3\n0 1 4 4')" ]
}

@test "terminal height caps the rows at one fifth and pages the overflow" {
	plan 5 20 <<-EOF
		$(windows 0 8)
		client 80 10 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 2'
	[ "$(width_of 80 | awk '{ print $3, $8 }')" = 'grid 3' ]
	[ "$(rows_of 80)" = "$(printf '0 0 0 3\n1 0 4 7\n2 0 8 8')" ]
}

@test "the max rows option caps the height below the terminal allowance" {
	plan 3 20 <<-EOF
		$(windows 0 19)
		client 80 76 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 3'
	[ "$(width_of 80 | awk '{ print $4, $8 }')" = '3 4' ]
}

@test "the row count never exceeds five whatever the option and terminal allow" {
	plan 9 20 <<-EOF
		$(windows 0 99)
		client 80 200 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 5'
}

@test "a one-row allowance pages cells beside reserved counts and page indicator" {
	plan 5 20 <<-EOF
		$(windows 0 9)
		client 80 9 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 1'
	[ "$(width_of 80)" = 'width 80 paged 4 20 14 14 5 waiting,bells,priority,page,total,hints' ]
	[ "$(rows_of 80 | head -n 2)" = "$(printf '0 0 0 1\n1 0 2 3')" ]
}

@test "sparse multi-digit indices widen the index slot and never create empty cells" {
	plan 5 20 <<-EOF
		window 0
		window 9
		window 101
		window 102
		client 80 24 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'windows 4 3 1'
	[ "$(width_of 80 | awk '{ print $4, $5, $6, $7 }')" = '3 26 18 18' ]
	[ "$(rows_of 80)" = "$(printf '0 0 0 101\n0 1 102 102')" ]
}

@test "clients of different widths share one height and get their own pages" {
	plan 5 20 <<-EOF
		window 0
		window 9
		$(windows 101 132)
		client 244 76 0
		client 80 24 0
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 4'
	[ "$(width_of 244 | awk '{ print $3, $4, $8 }')" = 'grid 9 2' ]
	[ "$(width_of 80 | awk '{ print $3, $4, $8 }')" = 'grid 3 4' ]
	[ "$(rows_of 80 | tail -n 3)" = "$(printf '3 0 126 128\n3 1 129 131\n3 2 132 132')" ]
}

@test "control-mode clients do not influence the layout" {
	plan 5 20 <<-EOF
		$(windows 0 4)
		client 80 24 0
		client 20 5 1
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 3'
	[ -z "$(width_of 20)" ]
}

@test "a session without interactive clients falls back to the native row" {
	plan 5 20 <<-EOF
		$(windows 0 4)
		client 80 24 1
	EOF
	[ "$status" -eq 0 ]
	echo "$output" | grep -qx 'height 1'
	echo "$output" | grep -qx 'native'
	[ "$(echo "$output" | grep -c '^width')" -eq 0 ]
}

@test "narrow summaries keep counts and page before optional fields" {
	plan 5 20 <<-EOF
		$(windows 0 39)
		client 40 25 0
	EOF
	[ "$status" -eq 0 ]
	[ "$(width_of 40)" = 'width 40 grid 2 20 13 13 5 waiting,bells,priority,page,total,hints' ]
}

@test "a longer menu key widens the hints field" {
	plan 5 20 <<-EOF
		$(windows 0 39)
		client 40 25 0
		key M-a
	EOF
	[ "$status" -eq 0 ]
	[ "$(width_of 40)" = 'width 40 grid 2 20 13 13 5 waiting,bells,priority,page,total,zoom,clock' ]
}

@test "a one-row allowance too narrow for a cell shows the current window compactly" {
	plan 5 20 <<-EOF
		$(windows 0 19)
		client 30 9 0
	EOF
	[ "$status" -eq 0 ]
	[ "$(width_of 30)" = 'width 30 compact 1 30 12 12 1 state,waiting,bells,priority,flags,label' ]
	[ -z "$(rows_of 30)" ]
}

@test "below the envelope label and lower-priority counts go before state and waiting" {
	plan 5 20 <<-EOF
		$(windows 0 19)
		client 8 9 0
	EOF
	[ "$status" -eq 0 ]
	[ "$(width_of 8)" = 'width 8 compact 1 8 0 0 1 state,waiting' ]
}

@test "a width below the index itself keeps only an attention marker" {
	plan 5 20 <<-EOF
		$(windows 0 19)
		client 1 9 0
	EOF
	[ "$status" -eq 0 ]
	[ "$(width_of 1)" = 'width 1 compact 1 1 0 0 1 marker' ]
}

@test "every window appears exactly once, in order, in contiguous pages" {
	for n in 1 7 34 100; do
		for size in 40x10 80x24 132x30 244x76 80x9; do
			w=${size%x*}
			h=${size#*x}
			plan 5 20 <<-EOF
				$(windows 0 $((n - 1)))
				client $w $h 0
			EOF
			[ "$status" -eq 0 ]
			mode=$(width_of "$w" | awk '{ print $3 }')
			[ "$mode" != compact ] || continue
			echo "$output" | awk -v w="$w" -v n="$n" '
				BEGIN { page = -1; next_index = 0 }
				$1 == "row" && $2 == w {
					if ($3 < page || ($3 == page && $4 <= row)) bad = 1
					if ($5 != next_index) bad = 1
					page = $3; row = $4; next_index = $6 + 1
				}
				END { exit (bad || next_index != n) }'
		done
	done
}

@test "invalid options are rejected without producing a layout" {
	for options in '0 20' 'x 20' '5 0' '5 -3' '5 abc' '2.5 20'; do
		read -r rows label <<<"$options"
		plan "$rows" "$label" <<-EOF
			$(windows 0 4)
			client 80 24 0
		EOF
		[ "$status" -eq 2 ]
		[ "${output#omp-tmux: }" != "$output" ]
		[ "$(echo "$output" | grep -c '^height')" -eq 0 ]
	done
}
