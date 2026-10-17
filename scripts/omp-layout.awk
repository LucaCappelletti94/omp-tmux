# omp-tmux status layout: stage=plan computes geometry, stage=render emits tmux commands.

function min(a, b) { return a < b ? a : b }
function max(a, b) { return a > b ? a : b }
function ceil_div(a, b) { return int((a + b - 1) / b) }
function digits(x) { return length(x "") }
function positive_int(s) { return s ~ /^[0-9]+$/ && s + 0 > 0 }

function fail(message) {
	print "omp-tmux: " message
	exit 2
}

# Summary field widths in cells, each including its leading space.
function field_width(name, pages) {
	if (name == "waiting" || name == "bells" || name == "priority") return 2 + count_digits
	if (name == "page") return 7 + 2 * digits(pages)
	if (name == "total") return 9 + count_digits
	if (name == "hints") return 8
	if (name == "session") return 15
	if (name == "zoom") return 2
	if (name == "clock") return 6
}

function summary_fields(avail, pages,    order, count, i, name, w, out) {
	count = split("waiting bells priority page total hints session zoom clock", order, " ")
	out = ""
	for (i = 1; i <= count; i++) {
		name = order[i]
		if (name == "page" && pages < 2) continue
		w = field_width(name, pages)
		if (w > avail) continue
		avail -= w
		out = out (out == "" ? "" : ",") name
	}
	return out
}

function print_rows(w, page, row, first, last) {
	print "row", w, page, row, index_of[first], index_of[last]
}

function plan_compact(w,    avail, out, count, order, sizes, i, budget) {
	if (w < index_digits + 1) {
		print "width", w, "compact", 1, w, 0, 0, 1, "marker"
		return
	}
	avail = w - index_digits
	count = split("state waiting bells priority flags", order, " ")
	split("1 " 2 + count_digits " " 2 + count_digits " " 2 + count_digits " 2", sizes, " ")
	out = ""
	for (i = 1; i <= count; i++) {
		if (sizes[i] > avail) continue
		avail -= sizes[i]
		out = out (out == "" ? "" : ",") order[i]
	}
	budget = 0
	if (avail >= 2) {
		budget = min(label_width, avail - 1)
		out = out "," "label"
	}
	print "width", w, "compact", 1, w, budget, budget, 1, out
}

function plan_width(w,    cols, cell, field, budget, core, cap, pages, p, r, s, e) {
	cols = columns[w]; cell = cells[w]
	field = cell - index_digits - 5
	if (field < 1) { plan_compact(w); return }
	budget = min(label_width, field)
	core = 3 * (2 + count_digits)
	if (height == 1 && fits_line[w]) {
		print "width", w, "line", cols, cell, budget, field, 1, summary_fields(w - window_count * cell, 1)
		print_rows(w, 0, 0, 0, window_count - 1)
		return
	}
	if (height == 1) {
		cap = int((w - core - field_width("page", window_count)) / cell)
		if (cap < 1) { plan_compact(w); return }
		pages = ceil_div(window_count, cap)
		print "width", w, "paged", cols, cell, budget, field, pages, summary_fields(w - cap * cell, pages)
		for (p = 0; p < pages; p++)
			print_rows(w, p, 0, p * cap, min(window_count, (p + 1) * cap) - 1)
		return
	}
	cap = cols * (height - 1)
	pages = ceil_div(window_count, cap)
	print "width", w, "grid", cols, cell, budget, field, pages, summary_fields(w, pages)
	for (p = 0; p < pages; p++)
		for (r = 0; r < height - 1; r++) {
			s = p * cap + r * cols
			if (s >= window_count) break
			e = min(window_count, s + cols) - 1
			print_rows(w, p, r, s, e)
		}
}

stage == "plan" && $1 == "window" { index_of[window_count++] = $2; next }
stage == "plan" && $1 == "client" && $4 == 0 {
	client_heights[client_count++] = $3 + 0
	if (!($2 in seen)) { seen[$2] = 1; widths[width_count++] = $2 + 0 }
	next
}

function plan_end(    i, w, allowance, target, minimum, needed, line) {
	if (!positive_int(max_rows)) fail("@omp_max_rows must be a positive integer, got '" max_rows "'")
	if (!positive_int(label_width)) fail("@omp_label_width must be a positive integer, got '" label_width "'")
	# BusyBox awk compares -v values and fields as strings, so numbers are coerced with + 0.
	max_rows += 0
	label_width += 0
	if (window_count == 0) fail("no windows to lay out")

	index_digits = digits(index_of[window_count - 1])
	count_digits = digits(window_count)
	print "windows", window_count, index_digits, count_digits
	line = "indices"
	for (i = 0; i < window_count; i++) line = line " " index_of[i]
	print line

	if (client_count == 0) {
		print "height 1"
		print "native"
		return
	}

	allowance = min(max_rows, 5)
	for (i = 0; i < client_count; i++)
		allowance = min(allowance, max(1, int(client_heights[i] / 5)))

	target = index_digits + 5 + label_width
	minimum = index_digits + 5 + min(12, label_width)
	needed = 1
	for (i = 0; i < width_count; i++) {
		w = widths[i]
		columns[w] = max(1, min(ceil_div(w, target), max(1, int(w / minimum))))
		cells[w] = int(w / columns[w])
		if (cells[w] - index_digits - 5 < 1) continue
		fits_line[w] = window_count * cells[w] + 3 * (2 + count_digits) <= w
		if (!fits_line[w]) needed = max(needed, ceil_div(window_count, columns[w]) + 1)
	}
	height = min(allowance, needed)
	print "height", height
	for (i = 0; i < width_count; i++) plan_width(widths[i])
}

# Cell and summary pieces live in the @omp_cell_* and @omp_sum_* options of omp-tmux.conf.

stage == "render" && $1 == "windows" { index_digits = $3 + 0 }
stage == "render" && $1 == "indices" { for (i = 2; i <= NF; i++) signature = signature $i " " }
stage == "render" && $1 == "height" { height = $2 + 0 }
stage == "render" && $1 == "native" { native = 1 }
stage == "render" && $1 == "width" {
	order[width_count++] = $2
	mode[$2] = $3; budget[$2] = $6 + 0; field[$2] = $7 + 0; pages[$2] = $8 + 0; fields[$2] = $9
}
stage == "render" && $1 == "row" {
	members[$2, $3, $4] = $5 " " $6
	if (!(($2, $3) in page_last) || $6 + 0 > page_last[$2, $3] + 0) page_last[$2, $3] = $6
}

# Width is measured on @omp_cell_raw because hash escapes in @omp_cell_text skew it.
function label(b, source,    trimmed) {
	trimmed = b == 1 ? "…" : "#{=/" (b - 1) "/…:#{E:" source "}}"
	return "#{?#{e|>:#{E:@omp_cell_width}," b "}," trimmed ",#{E:" source "}}"
}

function grid_cell(w) {
	return "#{E:@omp_cell_open}#{E:@omp_cell_state}#{E:@omp_cell_flags}#{p-" index_digits ":window_index}:" \
		label(budget[w], "@omp_cell_text") \
		"#{p/#{e|-:" field[w] ",#{w:" label(budget[w], "@omp_cell_raw") "}}/:}#[none] "
}

function compact_cell(w,    f) {
	f = "," fields[w] ","
	if (f ~ /,marker,/)
		return "#{active_window_index}#{?#{||:#{e|>:#{E:@omp_n_waiting},0},#{e|>:#{E:@omp_n_bells},0}},!,}"
	return "#{W:#{?window_active,#{E:@omp_cell_open}" \
		(f ~ /,state,/ ? "#{E:@omp_cell_state}" : "") \
		(f ~ /,flags,/ ? "#{E:@omp_cell_flags}" : "") \
		"#{p-" index_digits ":window_index}" \
		(f ~ /,label,/ ? ":" label(budget[w], "@omp_cell_text") : "") \
		"#[none],}}"
}

function by_page(w, content,    p, out, tail) {
	out = ""; tail = ""
	for (p = 0; p < pages[w] - 1; p++) {
		out = out "#{?#{e|<=:#{active_window_index}," page_last[w, p] "}," content[p] ","
		tail = tail "}"
	}
	return out content[pages[w] - 1] tail
}

function cells_row(w, p, r,    m) {
	if (!((w, p, r) in members)) return ""
	split(members[w, p, r], m, " ")
	return "#{W:#{?#{&&:#{e|>=:#{window_index}," m[1] "},#{e|<=:#{window_index}," m[2] "}}," grid_cell(w) ",}}"
}

function summary(w,    names, count, i, out, numbers, p, q) {
	count = split(fields[w], names, ",")
	out = ""
	for (i = 1; i <= count; i++) {
		if (names[i] == "page") {
			q = digits(pages[w])
			for (p = 0; p < pages[w]; p++) numbers[p] = sprintf("%" q "d/%d", p + 1, pages[w])
			out = out " page " by_page(w, numbers)
		} else if (names[i] == "clock") {
			out = out "#[align=right] %H:%M"
		} else if (names[i] ~ /^(waiting|bells|priority|total|hints|session|zoom)$/) {
			out = out "#{E:@omp_sum_" names[i] "}"
		}
	}
	return out
}

function row_for(w, i,    p, content) {
	if (mode[w] == "compact") return i == 0 ? compact_cell(w) "#[align=right]" summary(w) : ""
	if (mode[w] == "grid") {
		if (i == height - 1) return summary(w)
		for (p = 0; p < pages[w]; p++) content[p] = cells_row(w, p, i)
		return by_page(w, content)
	}
	for (p = 0; p < pages[w]; p++) content[p] = cells_row(w, p, 0)
	return by_page(w, content) "#[align=right]" summary(w)
}

function render_end(    i, k, w, out, tail) {
	print "if-shell -F -t '" session "' '#{==:#{@omp_layout_request}," request "}' {"
	if (native) {
		print "set-option -u -t '" session "' status"
		print "set-option -u -t '" session "' status-format"
	} else {
		for (i = 0; i < height; i++) {
			out = ""; tail = ""
			for (k = 0; k < width_count; k++) {
				w = order[k]
				out = out "#{?#{==:#{client_width}," w "}," row_for(w, i) ","
				tail = tail "}"
			}
			# A layout built for other window indices is stale, so row 0 falls back to the self-healing native row.
			out = out (i == 0 ? "#{E:@omp_native_row}" : "") tail
			print "set-option -t '" session "' status-format[" i "] '#{?#{==:#{W:#{window_index} }," signature "}," out "," (i == 0 ? "#{E:@omp_native_row}" : "") "}'"
		}
		print "set-option -t '" session "' status " (height == 1 ? "on" : height)
	}
	print "set-option -u -t '" session "' @omp_layout_error"
	print "}"
}

END {
	if (stage == "plan") plan_end()
	else if (stage == "render") render_end()
}
