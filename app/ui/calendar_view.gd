## Burning calendar: California map (pick an area) + year x month heatmap + fire list -> sim.
## Map: click a cell, shift+click to add/remove, drag a box. Heatmap: hover for details,
## click a month to list that area's fires. Pick a fire and press "Open in fire sim".
extends Control

const CalendarData = preload("res://data/calendar_data.gd")
const UI = preload("res://ui/ui_kit.gd")

# Dark surface and ink (dataviz reference palette, dark mode).
const SURFACE := Color("#1a1a19")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
const GRID_LINE := Color("#383835")
const ZERO := Color("#262624")       # recorded, no burning
const NO_DATA := Color("#121211")    # no satellite record (hatched)
const SELECT := Color("#f0efec")
const UNUSUAL := Color("#f5c542")    # yellow so it shows on the red cells, always with the ▲ marker
const UNUSUAL_X_MEDIAN := 2.0       # unusual = top 10% for that month AND >= 2x its median
# Burning: sequential red, dark mode: near zero recedes toward the surface, high is bright.
const REDS: Array[Color] = [Color("#4d0f0f"), Color("#7a1818"), Color("#ab2525"), Color("#d93a3a"),
	Color("#ec7070"), Color("#f4a3a3"), Color("#fbd3d3")]
# Second sequential context (outlook), one hue: blue, so it can't be mistaken for burning.
const BLUES: Array[Color] = [Color("#0d366b"), Color("#184f95"), Color("#256abf"), Color("#3987e5"),
	Color("#6da7ec"), Color("#9ec5f4"), Color("#cde2fb")]
# What the heatmap shows: the harmonized series, or one satellite's raw detections.
const VIEWS := ["Harmonized", "MODIS", "VIIRS S-NPP", "VIIRS NOAA-20"]
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# Map geometry (equirectangular, x scaled by cos 37.5°).
const LAT_TOP := 42.25
const LAT_BOTTOM := 32.5
const LON_LEFT := -124.6
const LON_RIGHT := -113.9
# Layout. The project stretches to the window with the 1200 x 800 design size as the minimum
# (stretch aspect "expand"), so the screen is always at least that big; layout() gives the
# extra width and height to the map, the heatmap cells and the fire list.
const DESIGN_SIZE := Vector2(1200, 800)
const HEAT_Y := 96.0
const OUTLOOK_GAP := 12.0
const LABEL_W := 172.0        # room right of the heatmap for the side notes
const MAX_CELL_W := 90.0
const MAX_CELL_H := 34.0
const SIDE_BUTTON_W := 180.0  # "Open in fire sim"
const MAP_ASPECT := 0.8706    # width / height of the drawn map: 10.7° lon x cos 37.5° over 9.75° lat
# Set by layout():
var map_rect := Rect2(16, 76, 410, 500)
var heat_x := 478.0
var cell_w := 46.0
var cell_h := 18.0
var heat_font := 12

var data: CalendarData = CalendarData.new()
var selection := PackedInt32Array()
var grid: Array = []
var unusual := PackedFloat32Array()
var medians := PackedFloat32Array()
var outlook := PackedFloat32Array()
var heat_max := 1.0
var heat_min := 1.0  # low end of the colour scale (5th percentile of non-zero months)
var cell_mean := PackedFloat32Array()  # mean monthly value per cell, for the default map
var view := 0            # index into VIEWS now shown; satellite views are sensor code + 1
var wanted_view := 0     # view picked by the user; shown once its counts are ready
var counting_year := 0   # next hotspot year to count for the satellite views, 0 = not started
var view_buttons: Array = []
var view_row := VBoxContainer.new()
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
var map_button := Button.new()
var shown_fires: Array = []


func _ready() -> void:
	font = ThemeDB.fallback_font
	RenderingServer.set_default_clear_color(SURFACE)
	if not data.load_all():
		hover_text = "Couldn't load app/datasets. Run pipeline/export_app_data.py."
		return
	_compute_cell_means()
	_build_controls()
	layout()
	if AppState.selection.is_empty():
		set_selection(data.all_cells())
	else:
		set_selection(AppState.selection)
	if AppState.selected_year > 0:
		select_month(AppState.selected_year, AppState.selected_month)


func _build_controls() -> void:
	for b in [all_button, sim_button, map_button]:
		b.add_theme_stylebox_override("normal", _button_style(UI.BTN))
		b.add_theme_stylebox_override("hover", _button_style(UI.BTN_HOVER))
		b.add_theme_stylebox_override("pressed", _button_style(UI.BTN_PRESSED))
		b.add_theme_stylebox_override("disabled", _button_style(UI.BTN_DISABLED))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_color_override("font_color", INK)
	_update_title()
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
	map_button.text = "← Back to map"
	map_button.pressed.connect(back_to_map)
	add_child(map_button)

	view_row.size.y = 30
	add_child(view_row)
	view_buttons = UI.segmented(view_row, VIEWS, view, set_view)

	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_color_override("font_color", INK_2)
	add_child(info)

	fire_title.add_theme_color_override("font_color", INK)
	add_child(fire_title)
	fire_list.item_selected.connect(func(_i): sim_button.disabled = false)
	fire_list.item_activated.connect(func(_i): open_sim())
	add_child(fire_list)
	sim_button.text = "Open in fire sim"
	sim_button.disabled = true
	sim_button.pressed.connect(open_sim)
	add_child(sim_button)


## Sizes and places everything for the current window: the design layout at 1200 x 800, with
## any extra width or height going to the map, the heatmap cells and the fire list.
func layout() -> void:
	var vs := get_viewport_rect().size
	vs = vs.max(DESIGN_SIZE)
	var rows := data.OUTLOOK_YEAR - data.FIRST_YEAR + 1  # one row per year, plus the outlook row
	# Map: as big as the left third and the height allow, at the map's own aspect.
	var avail := Vector2(vs.x * 0.34, vs.y - 300.0)
	var h := minf(avail.y, avail.x / MAP_ASPECT)
	map_rect = Rect2(16, 76, h * MAP_ASPECT, h)
	heat_x = map_rect.end.x + 52.0
	cell_w = clampf((vs.x - heat_x - LABEL_W) / 12.0, 30.0, MAX_CELL_W)
	# Rows take 70% of any extra height; the fire list gets the rest.
	var spare := maxf(vs.y - DESIGN_SIZE.y, 0.0)
	cell_h = clampf((vs.y - 296.0 - spare * 0.3) / rows, 12.0, MAX_CELL_H)
	heat_font = clampi(roundi(cell_h * 0.67), 11, 16)
	var list_y := HEAT_Y + rows * cell_h + OUTLOOK_GAP + 18.0 + 30.0 + 26.0
	title.position = Vector2(16, 10)
	area_label.position = Vector2(16, 42)
	map_button.position = Vector2(vs.x - 160.0, 8)
	view_row.position = Vector2(heat_x, 38)
	view_row.size.x = 12.0 * cell_w
	info.position = Vector2(16, map_rect.end.y + 36.0)
	info.size = Vector2(maxf(heat_x - 52.0 - 16.0, 300.0), maxf(vs.y - info.position.y - 10.0, 60.0))
	fire_title.position = Vector2(heat_x, list_y - 26.0)
	fire_list.position = Vector2(heat_x, list_y)
	fire_list.size = Vector2(maxf(vs.x - heat_x - 16.0 - SIDE_BUTTON_W - 12.0, 300.0), maxf(vs.y - list_y - 10.0, 60.0))
	sim_button.position = Vector2(fire_list.position.x + fire_list.size.x + 12.0, list_y)
	sim_button.size = Vector2(SIDE_BUTTON_W, 36)
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_inside_tree() and font != null and not grid.is_empty():
		layout()


## A square-cornered fill with no outline.
func _button_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


## Switch between the harmonized series and one satellite's raw detections. The satellite
## counts are made from the hotspot files the first time they are needed (a few seconds).
func set_view(i: int) -> void:
	wanted_view = i
	view_buttons[i].button_pressed = true
	if i > 0 and not data.sensor_ready():
		if counting_year == 0:
			counting_year = data.FIRST_YEAR
		_update_title()
		return
	_show_view(i)


func _show_view(i: int) -> void:
	view = i
	hover_text = ""  # the old text described the previous view
	info.text = ""
	_update_title()
	_compute_cell_means()
	set_selection(selection)


func _process(_delta: float) -> void:
	if counting_year == 0 or data.sensor_ready():
		return
	data.count_sensor_year(counting_year)
	counting_year += 1
	_update_title()
	if data.sensor_ready() and wanted_view != view:
		_show_view(wanted_view)


func _update_title() -> void:
	var t := "MODIS + VIIRS harmonized, 2000–2026"
	if wanted_view > 0 and not data.sensor_ready():
		t = "counting %s detections, %d…" % [VIEWS[wanted_view], counting_year]
	elif view > 0:
		t = "%s only: raw detections (observed), not harmonized" % VIEWS[view]
	title.text = "California burning calendar   ·   " + t


## Value of a cell in a month for the current view. NAN = no record.
func value_of(c: int, year: int, month: int) -> float:
	if view == 0:
		return data.cell_value(c, year, month)
	return data.sensor_cell_value(view - 1, c, year, month)


## What the numbers count in the current view.
func unit_text() -> String:
	return "fire cell-days" if view == 0 else "%s detections" % VIEWS[view]


func _compute_cell_means() -> void:
	cell_mean.resize(data.cell_count())
	for c in data.cell_count():
		var total := 0.0
		var n := 0
		for y in range(data.FIRST_YEAR, data.last_year + 1):
			for m in range(1, 13):
				var v: float = value_of(c, y, m)
				if not is_nan(v):
					total += v
					n += 1
		cell_mean[c] = total / maxf(n, 1)


func set_selection(cells: PackedInt32Array) -> void:
	if cells.is_empty():
		return
	selection = cells
	AppState.selection = cells
	grid = data.area_grid(selection) if view == 0 else data.sensor_area_grid(view - 1, selection)
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


## Back to the map, showing the month picked here (if any).
func back_to_map() -> void:
	if sel_year > 0 and not AppState.map_state.is_empty():
		AppState.map_state.year = mini(sel_year, data.last_year)
		AppState.map_state.month = sel_month
		AppState.map_state.day = 0
	get_tree().change_scene_to_file("res://ui/map_view.tscn")


func open_sim() -> void:
	var picked := fire_list.get_selected_items()
	if picked.is_empty():
		return
	AppState.sim_event = shown_fires[picked[0]]
	AppState.sim_request = {}  # the sim builds the region from the fire event
	AppState.return_scene = "res://ui/calendar_view.tscn"
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
			if map_rect.has_point(event.position):
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
	return minf(map_rect.size.x / w, map_rect.size.y / (LAT_TOP - LAT_BOTTOM))


func _to_screen(lat: float, lon: float) -> Vector2:
	var s := _map_scale()
	return map_rect.position + Vector2((lon - LON_LEFT) * cos(deg_to_rad(37.5)) * s, (LAT_TOP - lat) * s)


func _to_latlon(p: Vector2) -> Vector2:
	var s := _map_scale()
	var q := p - map_rect.position
	return Vector2(LAT_TOP - q.y / s, LON_LEFT + q.x / (cos(deg_to_rad(37.5)) * s))


func _row_y(year: int) -> float:
	var y := HEAT_Y + (year - data.FIRST_YEAR) * cell_h
	return y + OUTLOOK_GAP if year > data.last_year else y


## (year, month) under the mouse in the heatmap, or (0, 0).
func _heat_cell_at(p: Vector2) -> Vector2i:
	var m := int(floor((p.x - heat_x) / cell_w)) + 1
	if m < 1 or m > 12:
		return Vector2i.ZERO
	for y in range(data.FIRST_YEAR, data.OUTLOOK_YEAR + 1):
		var top := _row_y(y)
		if p.y >= top and p.y < top + cell_h:
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
	return ramp(REDS, (log(v) - log(vmin)) / maxf(log(vmax) - log(vmin), 0.001))


func is_unusual(v: float, m: int) -> bool:
	# Only for the harmonized series: a single satellite's record is too short for a baseline.
	return view == 0 and v > 0.0 and v >= unusual[m] and v >= UNUSUAL_X_MEDIAN * medians[m]


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
		var v: float = value_of(c, sel_year, sel_month) if month_mode else cell_mean[c]
		if not is_nan(v):
			vmax = maxf(vmax, v)
	var sel := {}
	for c in selection:
		sel[c] = true
	for c in data.cell_count():
		var v: float = value_of(c, sel_year, sel_month) if month_mode else cell_mean[c]
		var p := _to_screen(data.cell_lat[c] + 0.125, data.cell_lon[c] - 0.125)
		draw_rect(Rect2(p + Vector2(0.5, 0.5), size - Vector2(1, 1)), heat_color(v, vmax))
	if selection.size() < data.cell_count():
		for c in selection:
			var p := _to_screen(data.cell_lat[c] + 0.125, data.cell_lon[c] - 0.125)
			draw_rect(Rect2(p, size), SELECT, false, 1.5)
	if drag_from.x >= 0 and drag_from.distance_to(drag_to) > 6.0:
		draw_rect(Rect2(drag_from, drag_to - drag_from).abs(), SELECT, false, 1.0)
	var caption := "Map: %s" % ("%s %d, %s per 25 km cell" % [MONTHS[sel_month - 1], sel_year, unit_text()]
		if month_mode else "average monthly %s per 25 km cell" % unit_text())
	draw_string(font, Vector2(map_rect.position.x, map_rect.end.y + 4), caption,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_3)
	draw_string(font, Vector2(map_rect.position.x, map_rect.end.y + 20), "Click a cell · shift+click to add · drag a box",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_3)


func _draw_heatmap() -> void:
	for m in 12:
		draw_string(font, Vector2(heat_x + m * cell_w, HEAT_Y - 6), MONTHS[m], HORIZONTAL_ALIGNMENT_CENTER,
			cell_w, heat_font, INK_2)
	for y in range(data.FIRST_YEAR, data.last_year + 1):
		var top := _row_y(y)
		draw_string(font, Vector2(heat_x - 46, top + _text_dy()), str(y), HORIZONTAL_ALIGNMENT_RIGHT, 40, heat_font, INK_2)
		for m in 12:
			var v: float = grid[y - data.FIRST_YEAR][m]
			var r := Rect2(heat_x + m * cell_w + 1, top + 1, cell_w - 2, cell_h - 2)
			draw_rect(r, heat_color(v, heat_max, heat_min))
			if is_nan(v):
				_hatch(r)
				continue
			var mi: int = data.month_index(y, m + 1)
			if mi >= 0 and (data.partial[mi] or data.preliminary[mi]):
				draw_circle(r.position + Vector2(r.size.x - 5, 5), 2.0, INK_2)
			if is_unusual(v, m):
				draw_rect(r.grow(-1), UNUSUAL, false, 2.0)
				_triangle(r.position + Vector2(4, r.size.y - 4))
	# Sensor change markers (the harmonized series switches source in 2012).
	if view == 0:
		var y2012 := _row_y(2012) + cell_h / 18.0  # Feb 2012 sits in the 2012 row (a fraction of the row)
		draw_line(Vector2(heat_x - 50, _row_y(2012)), Vector2(heat_x + 12 * cell_w, _row_y(2012)), INK_3, 1.0)
		draw_string(font, Vector2(heat_x + 12 * cell_w + 6, y2012 + 4), "↑ MODIS, harmonized",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
		draw_string(font, Vector2(heat_x + 12 * cell_w + 6, y2012 + 18), "↓ VIIRS S-NPP, observed",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	else:
		draw_string(font, Vector2(heat_x + 12 * cell_w + 6, _row_y(data.FIRST_YEAR) + _text_dy()), "raw counts: don't compare",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
		draw_string(font, Vector2(heat_x + 12 * cell_w + 6, _row_y(data.FIRST_YEAR) + _text_dy() + 14), "between satellites",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	if view == 0 or view == 2:
		var y26 := _row_y(data.last_year)
		draw_string(font, Vector2(heat_x + 12 * cell_w + 6, y26 + _text_dy()), "S-NPP ended 2 Nov",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	# Outlook row.
	var oy := _row_y(data.OUTLOOK_YEAR)
	draw_string(font, Vector2(heat_x - 70, oy + _text_dy()), "%d" % data.OUTLOOK_YEAR, HORIZONTAL_ALIGNMENT_RIGHT, 64, heat_font, BLUES[4])
	var omax := 0.001
	for v in outlook:
		omax = maxf(omax, v)
	for m in 12:
		var r := Rect2(heat_x + m * cell_w + 1, oy + 1, cell_w - 2, cell_h - 2)
		draw_rect(r, ramp(BLUES, outlook[m] / omax))
	draw_string(font, Vector2(heat_x + 12 * cell_w + 6, oy + _text_dy()), "OUTLOOK: past patterns,",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, BLUES[4])
	draw_string(font, Vector2(heat_x + 12 * cell_w + 6, oy + _text_dy() + 14), "not a fire forecast",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, BLUES[4])
	# Selected month.
	if sel_year > 0:
		draw_rect(Rect2(heat_x + (sel_month - 1) * cell_w, _row_y(sel_year), cell_w, cell_h), SELECT, false, 2.0)
	# Hover.
	var h := _heat_cell_at(get_local_mouse_position())
	if h.x > 0:
		draw_rect(Rect2(heat_x + (h.y - 1) * cell_w, _row_y(h.x), cell_w, cell_h), INK_2, false, 1.0)


func _draw_legend() -> void:
	var x := heat_x
	var y := _row_y(data.OUTLOOK_YEAR) + cell_h + 18
	draw_string(font, Vector2(x, y), "less", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_3)
	for i in 24:
		draw_rect(Rect2(x + 30 + i * 6, y - 9, 6, 10), ramp(REDS, i / 23.0))
	draw_string(font, Vector2(x + 180, y), "more (log scale, %.0f–%.0f %s)" % [heat_min, heat_max, unit_text()],
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


## Baseline offset that centres text in a heatmap row (13 px in a 18 px row at 12 pt).
func _text_dy() -> float:
	return cell_h * 0.5 + heat_font * 0.34


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
	if map_rect.has_point(p):
		var ll := _to_latlon(p)
		var c: int = data.cell_at(ll.x, ll.y)
		if c < 0:
			return "No fire detections recorded in this 25 km cell."
		var v: float = value_of(c, sel_year, sel_month) if sel_year > 0 else cell_mean[c]
		if is_nan(v):
			return "Cell %.3f, %.3f\nNo record for this month in this view." % [data.cell_lat[c], data.cell_lon[c]]
		return "Cell %.3f, %.3f\n%s: %.1f %s" % [data.cell_lat[c], data.cell_lon[c],
			("%s %d" % [MONTHS[sel_month - 1], sel_year]) if sel_year > 0 else "Average month", v, unit_text()]
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
		return "%s %d — no %s record. Missing data is not zero fire." % [MONTHS[h.y - 1], h.x, "satellite" if view == 0 else VIEWS[view]]
	if view > 0:
		return "%s %d — OBSERVED, %s only\n%s raw detections in this area\n%s\nSource: NASA FIRMS active-fire detections.\nClick to list this area's fires for the month." % [
			MONTHS[h.y - 1], h.x, VIEWS[view], UI.thousands(int(v)),
			"MODIS pixels are 1 km, VIIRS pixels 375 m, so the satellites' counts are not comparable. Use Harmonized to compare years."]
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
