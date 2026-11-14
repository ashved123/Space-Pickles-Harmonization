## Burning calendar: California map (pick an area) + year x month heatmap + fire list -> sim.
## Map: click a cell, shift+click to add/remove, drag a box. Heatmap: hover for details,
## click a month to list that area's fires. Pick a fire and press "Open in fire sim".
extends Control

const CalendarData = preload("res://data/calendar_data.gd")

# Dark surface and ink (dataviz reference palette, dark mode).
const SURFACE := Color("#1a1a19")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
const GRID_LINE := Color("#383835")
const ZERO := Color("#262624")       # recorded, no burning
const NO_DATA := Color("#121211")    # no satellite record (hatched)
const SELECT := Color("#f0efec")
const UNUSUAL := Color("#ec835a")    # status "serious", always with the ▲ marker
const UNUSUAL_X_MEDIAN := 2.0       # unusual = top 10% for that month AND >= 2x its median
# Sequential blue, dark mode: near zero recedes toward the surface, high is bright.
const BLUES: Array[Color] = [Color("#0d366b"), Color("#184f95"), Color("#256abf"), Color("#3987e5"),
	Color("#6da7ec"), Color("#9ec5f4"), Color("#cde2fb")]
# Second sequential context (outlook), one hue: orange.
const ORANGES: Array[Color] = [Color("#4a1f0d"), Color("#7a3415"), Color("#b14a1e"), Color("#eb6834"),
	Color("#f29a73"), Color("#f8c7b0")]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# Map geometry (equirectangular, x scaled by cos 37.5°).
const MAP_RECT := Rect2(16, 76, 410, 500)
const LAT_TOP := 42.25
const LAT_BOTTOM := 32.5
const LON_LEFT := -124.6
const LON_RIGHT := -113.9
# Heatmap geometry.
const HEAT_X := 478.0
const HEAT_Y := 96.0
const CELL_W := 46.0
const CELL_H := 18.0
const OUTLOOK_GAP := 12.0

var data: CalendarData = CalendarData.new()
var selection := PackedInt32Array()
var grid: Array = []
var unusual := PackedFloat32Array()
var medians := PackedFloat32Array()
var outlook := PackedFloat32Array()
var heat_max := 1.0
var heat_min := 1.0  # low end of the colour scale (5th percentile of non-zero months)
var cell_mean := PackedFloat32Array()  # mean monthly value per cell, for the default map
var sel_year := 0
var sel_month := 0
var hover_text := ""
var drag_from := Vector2(-1, -1)
var drag_to := Vector2(-1, -1)
var font: Font

var title := Label.new()
var area_label := Label.new()
var info := Label.new()
var fire_list := ItemList.new()
var fire_title := Label.new()
var sim_button := Button.new()
var all_button := Button.new()
var shown_fires: Array = []


func _ready() -> void:
	font = ThemeDB.fallback_font
	RenderingServer.set_default_clear_color(SURFACE)
	if not data.load_all():
		hover_text = "Couldn't load app/datasets. Run pipeline/export_app_data.py."
		return
	_compute_cell_means()
	_build_controls()
	if AppState.selection.is_empty():
		set_selection(data.all_cells())
	else:
		set_selection(AppState.selection)
	if AppState.selected_year > 0:
		select_month(AppState.selected_year, AppState.selected_month)


func _build_controls() -> void:
	for b in [all_button, sim_button]:
		b.add_theme_stylebox_override("normal", _button_style(Color("#2b2b29"), INK_3))
		b.add_theme_stylebox_override("hover", _button_style(Color("#383835"), INK_2))
		b.add_theme_stylebox_override("pressed", _button_style(Color("#383835"), INK))
		b.add_theme_stylebox_override("disabled", _button_style(SURFACE, GRID_LINE))
		b.add_theme_color_override("font_color", INK)
	title.text = "California burning calendar   ·   MODIS + VIIRS harmonized, 2000–2026"
	title.position = Vector2(16, 10)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", INK)
	add_child(title)
	area_label.position = Vector2(16, 42)
	area_label.add_theme_color_override("font_color", INK_2)
	add_child(area_label)
	all_button.text = "All California"
	all_button.position = Vector2(300, 38)
	all_button.pressed.connect(func(): set_selection(data.all_cells()))
	add_child(all_button)

	info.position = Vector2(16, 612)
	info.size = Vector2(440, 180)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", INK_2)
	add_child(info)

	fire_title.position = Vector2(HEAT_X, 660)
	fire_title.add_theme_color_override("font_color", INK)
	add_child(fire_title)
	fire_list.position = Vector2(HEAT_X, 686)
	fire_list.size = Vector2(500, 104)
	fire_list.item_selected.connect(func(_i): sim_button.disabled = false)
	fire_list.item_activated.connect(func(_i): open_sim())
	add_child(fire_list)
	sim_button.text = "Open in fire sim"
	sim_button.position = Vector2(HEAT_X + 512, 686)
	sim_button.size = Vector2(180, 36)
	sim_button.disabled = true
	sim_button.pressed.connect(open_sim)
	add_child(sim_button)


func _button_style(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


func _compute_cell_means() -> void:
	cell_mean.resize(data.cell_count())
	for c in data.cell_count():
		var total := 0.0
		var n := 0
		for y in range(data.FIRST_YEAR, data.last_year + 1):
			for m in range(1, 13):
				var v: float = data.cell_value(c, y, m)
				if not is_nan(v):
					total += v
					n += 1
		cell_mean[c] = total / maxf(n, 1)


func set_selection(cells: PackedInt32Array) -> void:
	if cells.is_empty():
		return
	selection = cells
	AppState.selection = cells
	grid = data.area_grid(selection)
	unusual = data.unusual_thresholds(grid)
	medians = data.baseline_medians(grid)
	outlook = data.outlook_area(selection)
	var nonzero := []
	for row in grid:
		for v in row:
			if not is_nan(v) and v > 0.0:
				nonzero.append(v)
	nonzero.sort()
	heat_max = nonzero[-1] if not nonzero.is_empty() else 1.0
	heat_min = nonzero[int(nonzero.size() * 0.05)] if not nonzero.is_empty() else 1.0
	var all := selection.size() == data.cell_count()
	area_label.text = ("All California (%d cells)" if all else "Selected area: %d cells (~25 km each)") % selection.size()
	if sel_year > 0:
		select_month(sel_year, sel_month)
	queue_redraw()


func select_month(year: int, month: int) -> void:
	sel_year = year
	sel_month = month
	AppState.selected_year = year
	AppState.selected_month = month
	shown_fires = data.fires_in(selection, year, month)
	fire_list.clear()
	for f in shown_fires:
		fire_list.add_item("%s   %s → %s   %.0f km²   %d detections" % [f.id, f.start, f.end, f.km2, f.det])
	fire_title.text = "Fires in this area, %s %d (observed detections grouped into events): %d" % [
		MONTHS[month - 1], year, shown_fires.size()]
	sim_button.disabled = true
	queue_redraw()


func open_sim() -> void:
	var picked := fire_list.get_selected_items()
	if picked.is_empty():
		return
	AppState.sim_event = shown_fires[picked[0]]
	get_tree().change_scene_to_file("res://main.tscn")


# ---------- input ----------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		hover_text = _describe(event.position)
		info.text = hover_text
		if drag_from.x >= 0:
			drag_to = event.position
		queue_redraw()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if MAP_RECT.has_point(event.position):
				drag_from = event.position
				drag_to = event.position
			else:
				var ym := _heat_cell_at(event.position)
				if ym.x > 0 and ym.x <= data.last_year:
					select_month(ym.x, ym.y)
		elif drag_from.x >= 0:
			_finish_map_click(event.position, event.shift_pressed)
			drag_from = Vector2(-1, -1)
			queue_redraw()


func _finish_map_click(pos: Vector2, shift: bool) -> void:
	if drag_from.distance_to(pos) > 6.0:
		var a := _to_latlon(drag_from)
		var b := _to_latlon(pos)
		var box: PackedInt32Array = data.cells_in_box(a.x - 0.125, a.y - 0.125, b.x + 0.125, b.y + 0.125)
		if not box.is_empty():
			set_selection(box)
		return
	var ll := _to_latlon(pos)
	var c: int = data.cell_at(ll.x, ll.y)
	if c < 0:
		return
	if shift and selection.size() < data.cell_count():
		var s := selection.duplicate()
		var at := s.find(c)
		if at >= 0 and s.size() > 1:
			s.remove_at(at)
		elif at < 0:
			s.append(c)
		set_selection(s)
	else:
		set_selection(PackedInt32Array([c]))


# ---------- geometry ----------

func _map_scale() -> float:
	var w := (LON_RIGHT - LON_LEFT) * cos(deg_to_rad(37.5))
	return minf(MAP_RECT.size.x / w, MAP_RECT.size.y / (LAT_TOP - LAT_BOTTOM))


func _to_screen(lat: float, lon: float) -> Vector2:
	var s := _map_scale()
	return MAP_RECT.position + Vector2((lon - LON_LEFT) * cos(deg_to_rad(37.5)) * s, (LAT_TOP - lat) * s)


func _to_latlon(p: Vector2) -> Vector2:
	var s := _map_scale()
	var q := p - MAP_RECT.position
	return Vector2(LAT_TOP - q.y / s, LON_LEFT + q.x / (cos(deg_to_rad(37.5)) * s))


func _row_y(year: int) -> float:
	var y := HEAT_Y + (year - data.FIRST_YEAR) * CELL_H
	return y + OUTLOOK_GAP if year > data.last_year else y


## (year, month) under the mouse in the heatmap, or (0, 0).
func _heat_cell_at(p: Vector2) -> Vector2i:
	var m := int(floor((p.x - HEAT_X) / CELL_W)) + 1
	if m < 1 or m > 12:
		return Vector2i.ZERO
	for y in range(data.FIRST_YEAR, data.OUTLOOK_YEAR + 1):
		var top := _row_y(y)
		if p.y >= top and p.y < top + CELL_H:
			return Vector2i(y, m)
	return Vector2i.ZERO


# ---------- colour ----------

static func ramp(colors: Array[Color], t: float) -> Color:
	t = clampf(t, 0.0, 1.0) * (colors.size() - 1)
	var i := mini(int(floor(t)), colors.size() - 2)
	return colors[i].lerp(colors[i + 1], t - i)


func heat_color(v: float, vmax: float, vmin: float = 1.0) -> Color:
	if is_nan(v):
		return NO_DATA
	if v <= 0.0:
		return ZERO
	vmin = minf(vmin, vmax * 0.5)
	return ramp(BLUES, (log(v) - log(vmin)) / maxf(log(vmax) - log(vmin), 0.001))


func is_unusual(v: float, m: int) -> bool:
	return v > 0.0 and v >= unusual[m] and v >= UNUSUAL_X_MEDIAN * medians[m]


# ---------- drawing ----------

func _draw() -> void:
	if grid.is_empty():
		draw_string(font, Vector2(16, 40), hover_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, INK)
		return
	_draw_map()
	_draw_heatmap()
	_draw_legend()


func _draw_map() -> void:
	var s := _map_scale()
	var size := Vector2(0.25 * cos(deg_to_rad(37.5)) * s, 0.25 * s)
	var month_mode := sel_year > 0
	var vmax := 1.0
	for c in data.cell_count():
		var v: float = data.cell_value(c, sel_year, sel_month) if month_mode else cell_mean[c]
		if not is_nan(v):
			vmax = maxf(vmax, v)
	var sel := {}
	for c in selection:
		sel[c] = true
	for c in data.cell_count():
		var v: float = data.cell_value(c, sel_year, sel_month) if month_mode else cell_mean[c]
		var p := _to_screen(data.cell_lat[c] + 0.125, data.cell_lon[c] - 0.125)
		draw_rect(Rect2(p + Vector2(0.5, 0.5), size - Vector2(1, 1)), heat_color(v, vmax))
	if selection.size() < data.cell_count():
		for c in selection:
			var p := _to_screen(data.cell_lat[c] + 0.125, data.cell_lon[c] - 0.125)
			draw_rect(Rect2(p, size), SELECT, false, 1.5)
	if drag_from.x >= 0 and drag_from.distance_to(drag_to) > 6.0:
		draw_rect(Rect2(drag_from, drag_to - drag_from).abs(), SELECT, false, 1.0)
	var caption := "Map: %s" % ("%s %d, fire cell-days per 25 km cell" % [MONTHS[sel_month - 1], sel_year]
		if month_mode else "average monthly burning per 25 km cell, 2000–2026")
	draw_string(font, Vector2(MAP_RECT.position.x, MAP_RECT.end.y + 4), caption,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_3)
	draw_string(font, Vector2(MAP_RECT.position.x, MAP_RECT.end.y + 20), "Click a cell · shift+click to add · drag a box",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_3)


func _draw_heatmap() -> void:
	for m in 12:
		draw_string(font, Vector2(HEAT_X + m * CELL_W, HEAT_Y - 6), MONTHS[m], HORIZONTAL_ALIGNMENT_CENTER,
			CELL_W, 12, INK_2)
	for y in range(data.FIRST_YEAR, data.last_year + 1):
		var top := _row_y(y)
		var kind: String = "harmonized" if y < 2012 else "observed"
		draw_string(font, Vector2(HEAT_X - 46, top + 13), str(y), HORIZONTAL_ALIGNMENT_RIGHT, 40, 12, INK_2)
		for m in 12:
			var v: float = grid[y - data.FIRST_YEAR][m]
			var r := Rect2(HEAT_X + m * CELL_W + 1, top + 1, CELL_W - 2, CELL_H - 2)
			draw_rect(r, heat_color(v, heat_max, heat_min))
			if is_nan(v):
				_hatch(r)
				continue
			var mi: int = data.month_index(y, m + 1)
			if data.partial[mi] or data.preliminary[mi]:
				draw_circle(r.position + Vector2(r.size.x - 5, 5), 2.0, INK_2)
			if is_unusual(v, m):
				draw_rect(r.grow(-1), UNUSUAL, false, 2.0)
				_triangle(r.position + Vector2(4, r.size.y - 4))
	# Sensor change markers.
	var y2012 := _row_y(2012) + CELL_H / 18.0  # Feb 2012 sits in the 2012 row
	draw_line(Vector2(HEAT_X - 50, _row_y(2012)), Vector2(HEAT_X + 12 * CELL_W, _row_y(2012)), INK_3, 1.0)
	draw_string(font, Vector2(HEAT_X + 12 * CELL_W + 6, y2012 + 4), "↑ MODIS, harmonized",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	draw_string(font, Vector2(HEAT_X + 12 * CELL_W + 6, y2012 + 18), "↓ VIIRS S-NPP, observed",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	var y26 := _row_y(data.last_year)
	draw_string(font, Vector2(HEAT_X + 12 * CELL_W + 6, y26 + 13), "S-NPP ended 2 Nov",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	# Outlook row.
	var oy := _row_y(data.OUTLOOK_YEAR)
	draw_string(font, Vector2(HEAT_X - 70, oy + 13), "%d" % data.OUTLOOK_YEAR, HORIZONTAL_ALIGNMENT_RIGHT, 64, 12, ORANGES[4])
	var omax := 0.001
	for v in outlook:
		omax = maxf(omax, v)
	for m in 12:
		var r := Rect2(HEAT_X + m * CELL_W + 1, oy + 1, CELL_W - 2, CELL_H - 2)
		draw_rect(r, ramp(ORANGES, outlook[m] / omax))
	draw_string(font, Vector2(HEAT_X + 12 * CELL_W + 6, oy + 13), "OUTLOOK: past patterns,",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ORANGES[4])
	draw_string(font, Vector2(HEAT_X + 12 * CELL_W + 6, oy + 27), "not a fire forecast",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, ORANGES[4])
	# Selected month.
	if sel_year > 0:
		draw_rect(Rect2(HEAT_X + (sel_month - 1) * CELL_W, _row_y(sel_year), CELL_W, CELL_H), SELECT, false, 2.0)
	# Hover.
	var h := _heat_cell_at(get_local_mouse_position())
	if h.x > 0:
		draw_rect(Rect2(HEAT_X + (h.y - 1) * CELL_W, _row_y(h.x), CELL_W, CELL_H), INK_2, false, 1.0)


func _draw_legend() -> void:
	var x := HEAT_X
	var y := _row_y(data.OUTLOOK_YEAR) + CELL_H + 18
	draw_string(font, Vector2(x, y), "less", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	for i in 24:
		draw_rect(Rect2(x + 30 + i * 6, y - 9, 6, 10), ramp(BLUES, i / 23.0))
	draw_string(font, Vector2(x + 180, y), "more burning (log scale, %.0f–%.0f cell-days)" % [heat_min, heat_max],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	y += 18
	draw_rect(Rect2(x, y - 9, 14, 10), NO_DATA)
	_hatch(Rect2(x, y - 9, 14, 10))
	draw_string(font, Vector2(x + 18, y), "no record", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	draw_rect(Rect2(x + 90, y - 9, 14, 10), UNUSUAL, false, 2.0)
	_triangle(Vector2(x + 94, y - 1))
	draw_string(font, Vector2(x + 108, y), "unusual: top 10% for that month and ≥ 2× its median",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	draw_circle(Vector2(x + 420, y - 4), 2.0, INK_2)
	draw_string(font, Vector2(x + 426, y), "preliminary (NRT)", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)


func _hatch(r: Rect2) -> void:
	var step := 5.0
	var t := 0.0
	while t < r.size.x + r.size.y:
		var a := r.position + Vector2(minf(t, r.size.x), maxf(0.0, t - r.size.x))
		var b := r.position + Vector2(maxf(0.0, t - r.size.y), minf(t, r.size.y))
		draw_line(a, b, GRID_LINE, 1.0)
		t += step


func _triangle(p: Vector2) -> void:
	draw_colored_polygon(PackedVector2Array([p + Vector2(-3, 2), p + Vector2(3, 2), p + Vector2(0, -3)]), UNUSUAL)


# ---------- hover text ----------

func _describe(p: Vector2) -> String:
	if MAP_RECT.has_point(p):
		var ll := _to_latlon(p)
		var c: int = data.cell_at(ll.x, ll.y)
		if c < 0:
			return "No fire detections recorded in this 25 km cell."
		var v: float = data.cell_value(c, sel_year, sel_month) if sel_year > 0 else cell_mean[c]
		return "Cell %.3f, %.3f\n%s: %.1f fire cell-days" % [data.cell_lat[c], data.cell_lon[c],
			("%s %d" % [MONTHS[sel_month - 1], sel_year]) if sel_year > 0 else "Average month", v]
	var h := _heat_cell_at(p)
	if h.x == 0:
		return hover_text
	if h.x == data.OUTLOOK_YEAR:
		return ("%s %d — OUTLOOK\nExpected cells with notable burning (≥10 cell-days): %.1f of %d\n%s\n"
			+ "Validation (held-out %s): AUC %.2f vs %.2f for past frequency.") % [
			MONTHS[h.y - 1], h.x, outlook[h.y - 1], selection.size(), data.outlook_label,
			data.outlook_info.get("test_years", "?"), data.outlook_info.get("auc_model", 0.0),
			data.outlook_info.get("auc_climatology", 0.0)]
	var v: float = grid[h.x - data.FIRST_YEAR][h.y - 1]
	if is_nan(v):
		return "%s %d — no satellite record. Missing data is not zero fire." % [MONTHS[h.y - 1], h.x]
	var mi: int = data.month_index(h.x, h.y)
	var lines := ["%s %d — %s" % [MONTHS[h.y - 1], h.x, data.kinds[mi].to_upper()],
		"%.0f fire cell-days (S-NPP scale)" % v,
		"Source: %s" % data.sources[mi]]
	var med: float = medians[h.y - 1]
	if med > 0.0:
		lines.append("%.1f× the 2001–2025 median for %s (%.0f)" % [v / med, MONTHS[h.y - 1], med])
	if is_unusual(v, h.y - 1):
		lines.append("▲ Unusual: top 10%% of %s months and ≥ 2× the median" % MONTHS[h.y - 1])
	if data.preliminary[mi]:
		lines.append("Preliminary (near-real-time data, may be revised)")
	if data.partial[mi]:
		lines.append("Month not finished yet")
	lines.append("Click to list this area's fires for the month.")
	return "\n".join(lines)
