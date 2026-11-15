## Start screen: a pannable, zoomable map (NASA GIBS imagery) with hotspots, fire outlines and the
## harmonized burning grid, filtered by date, sensor, heat and fire size.
## Drag to pan, scroll / pinch to zoom, click a fire or hotspot for details.
extends Control

const Mercator = preload("res://map/mercator.gd")
const TileLayer = preload("res://map/tile_layer.gd")
const HotspotLayer = preload("res://map/hotspot_layer.gd")
const VectorLayer = preload("res://map/vector_layer.gd")
const RegionClip = preload("res://map/region_clip.gd")
const WindLayer = preload("res://map/wind_layer.gd")
const CalendarData = preload("res://data/calendar_data.gd")
const HotspotData = preload("res://data/hotspot_data.gd")

const SURFACE := Color("#1a1a19")
const PANEL_BG := Color("#222220")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
const MODIS_COLOR := Color("#3987e5")  # categorical slot 1 (dark mode)
const VIIRS_COLOR := Color("#d95926")  # categorical slot 2 (dark mode)
const PANEL_W := 330.0
const MIN_ZOOM := 5.0
const MAX_ZOOM := 15.0
const GIBS_DAILY := "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/MODIS_Terra_CorrectedReflectance_TrueColor/default/{date}/GoogleMapsCompatible_Level9/{z}/{y}/{x}.jpg"
const USGS := "https://basemap.nationalmap.gov/arcgis/rest/services/%s/MapServer/tile/{z}/{y}/{x}"
# Base maps: [name, url template, max zoom]. USGS National Map tiles are public domain.
const BASES := [
	["Aerial imagery + roads and names (USGS)", USGS % "USGSImageryTopo", 16],
	["Aerial imagery (USGS, cloud-free)", USGS % "USGSImageryOnly", 16],
	["Topographic map (USGS)", USGS % "USGSTopo", 16],
	["None", "", 0],
]
const FIRST_IMAGERY := "2000-02-24"     # MODIS Terra true colour starts here in GIBS
const MONTHS := ["All months", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

var cal: CalendarData = CalendarData.new()
var hs: HotspotData = HotspotData.new()

# View.
var zoom := 6.0
var center := Mercator.to_world(37.3, -119.4)
var _drag := false
var _drag_moved := 0.0
var _last_vector_zoom := -1.0
var _last_loading := -1

# Filters.
var year := 2018
var month := 11
var day := 0
var sensor_choice := 0     # 0 all, 1 MODIS, 2 VIIRS
var min_frp := 0
var min_km2 := 0.0
var show_hotspots := true
var show_fires := true
var show_grid := false
var show_outlook := false
var base_choice := 0       # index into BASES
var show_sat := false      # daily MODIS image (clouds, smoke) over the base map
var show_wind := false
var wind_hour := 20        # UTC
var _wind_date := ""

# Results.
var shown_idx_modis := PackedInt32Array()
var shown_idx_viirs := PackedInt32Array()
var shown_fires: Array = []
var selected_fire := {}
var selected_info := ""

# Nodes.
var world := Node2D.new()
var region_clip: RegionClip = RegionClip.new()
var base_tiles: TileLayer = TileLayer.new()
var sat_tiles: TileLayer = TileLayer.new()
var wind: WindLayer = WindLayer.new()
var _wind_timer := Timer.new()
var region_bbox := Rect2()   # world rect of California, limits panning
var hour_label := Label.new()
var hour_slider := HSlider.new()
var vector: VectorLayer = VectorLayer.new()
var modis_layer: HotspotLayer = HotspotLayer.new()
var viirs_layer: HotspotLayer = HotspotLayer.new()
var status := RichTextLabel.new()
var info := Label.new()
var date_label := Label.new()
var year_slider := HSlider.new()
var month_slider := HSlider.new()
var day_slider := HSlider.new()
var frp_slider := HSlider.new()
var frp_label := Label.new()
var size_slider := HSlider.new()
var size_label := Label.new()
var sim_button := Button.new()
var font: Font


func _ready() -> void:
	font = ThemeDB.fallback_font
	RenderingServer.set_default_clear_color(SURFACE)
	clip_contents = true
	cal.load_all()
	hs.load_index()
	_restore_state()

	_load_region()
	base_tiles.setup(BASES[base_choice][1], BASES[base_choice][2])
	sat_tiles.setup(GIBS_DAILY, 9)
	region_clip.add_child(base_tiles)
	region_clip.add_child(sat_tiles)
	world.add_child(region_clip)
	var m2 := Mercator.world_per_metre(37.5)
	modis_layer.footprint_world = 1000.0 * m2
	viirs_layer.footprint_world = 375.0 * m2
	for n in [vector, modis_layer, viirs_layer]:
		world.add_child(n)
	add_child(world)
	wind.to_world = screen_to_world
	add_child(wind)
	_wind_timer.one_shot = true
	_wind_timer.wait_time = 0.6
	_wind_timer.timeout.connect(func(): wind.show_date(_wind_date))
	add_child(_wind_timer)
	_build_panel()
	_build_overlay()
	_refresh_data()
	_apply_view()


func _load_region() -> void:
	var f := FileAccess.open("res://datasets/california.json", FileAccess.READ)
	if f == null:
		return
	var ca = JSON.parse_string(f.get_as_text())
	var rings := []
	for ring in ca.rings:
		var pts := PackedVector2Array()
		for p in ring:
			pts.append(Mercator.to_world(p[0], p[1]))
		rings.append(pts)
	region_clip.rings = rings
	vector.outline_rings = rings
	var a := Mercator.to_world(ca.bbox[2], ca.bbox[1])
	var b := Mercator.to_world(ca.bbox[0], ca.bbox[3])
	region_bbox = Rect2(a, b - a)
	wind.set_region(rings[0], ca.bbox)


# ---------- panel ----------

func _build_panel() -> void:
	var bg := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	bg.add_theme_stylebox_override("panel", sb)
	bg.anchor_left = 1.0
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.offset_left = -PANEL_W
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 14
	scroll.offset_right = -10
	scroll.offset_top = 12
	scroll.offset_bottom = -12
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = PANEL_W - 40
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	_heading(box, "California fire map", 20)
	_text(box, "MODIS + VIIRS hotspots, fire events and harmonized burning. Drag to pan, scroll to zoom, click for details.", INK_3)

	_heading(box, "Date", 15)
	date_label.add_theme_color_override("font_color", INK)
	box.add_child(date_label)
	_text(box, "Year", INK_3)
	_slider(box, year_slider, 2000, 2026, year, func(v): year = int(v); _clamp_day(); _refresh_data())
	_text(box, "Month (far left = whole year)", INK_3)
	_slider(box, month_slider, 0, 12, month, func(v): month = int(v); _clamp_day(); _refresh_data())
	_text(box, "Day (far left = whole month)", INK_3)
	_slider(box, day_slider, 0, 31, day, func(v): day = int(v); _clamp_day(); _refresh_data())

	_heading(box, "Layers", 15)
	_check(box, "Hotspots (observed)", show_hotspots, func(on): show_hotspots = on; _refresh_data())
	_check(box, "Fire event outlines", show_fires, func(on): show_fires = on; _refresh_data())
	_check(box, "Harmonized burning (25 km)", show_grid, func(on): show_grid = on; _refresh_data())
	_check(box, "2027 outlook (not a forecast)", show_outlook, func(on): show_outlook = on; _refresh_data())

	_heading(box, "Filters", 15)
	var sensors := OptionButton.new()
	for s in ["All sensors", "MODIS only (1 km)", "VIIRS only (375 m)"]:
		sensors.add_item(s)
	sensors.select(sensor_choice)
	sensors.item_selected.connect(func(i): sensor_choice = i; _refresh_data())
	box.add_child(sensors)
	frp_label.add_theme_color_override("font_color", INK_2)
	box.add_child(frp_label)
	_slider(box, frp_slider, 0, 300, min_frp, func(v): min_frp = int(v); _refresh_data())
	size_label.add_theme_color_override("font_color", INK_2)
	box.add_child(size_label)
	_slider(box, size_slider, 0, 500, min_km2, func(v): min_km2 = v; _refresh_data())

	_heading(box, "Base map", 15)
	var base := OptionButton.new()
	for b in BASES:
		base.add_item(b[0])
	base.select(base_choice)
	base.item_selected.connect(func(i): base_choice = i; _apply_view())
	box.add_child(base)
	_check(box, "Satellite view that day (clouds, smoke)", show_sat, func(on): show_sat = on; _apply_view())

	_heading(box, "Wind", 15)
	_check(box, "Wind that day (ERA5, modelled)", show_wind, func(on): show_wind = on; _apply_view())
	hour_label.add_theme_color_override("font_color", INK_2)
	box.add_child(hour_label)
	_slider(box, hour_slider, 0, 23, wind_hour, func(v): wind_hour = int(v); _apply_view())

	_heading(box, "Selected", 15)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.x = PANEL_W - 44
	info.add_theme_color_override("font_color", INK_2)
	box.add_child(info)
	sim_button.text = "Open in fire sim"
	sim_button.disabled = true
	sim_button.pressed.connect(_open_sim)
	box.add_child(sim_button)
	var cal_button := Button.new()
	cal_button.text = "Burning calendar for this view"
	cal_button.pressed.connect(_open_calendar)
	box.add_child(cal_button)
	for b in [sim_button, cal_button]:
		_style_button(b)


func _heading(box: Container, t: String, size: int) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", INK)
	box.add_child(l)


func _text(box: Container, t: String, c: Color) -> void:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = PANEL_W - 40
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", c)
	box.add_child(l)


func _slider(box: Container, s: HSlider, lo: float, hi: float, v: float, cb: Callable) -> void:
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = v
	s.value_changed.connect(cb)
	box.add_child(s)


func _check(box: Container, t: String, on: bool, cb: Callable) -> void:
	var c := CheckBox.new()
	c.text = t
	c.button_pressed = on
	c.toggled.connect(cb)
	box.add_child(c)


func _style_button(b: Button) -> void:
	for state in ["normal", "hover", "pressed", "disabled"]:
		var s := StyleBoxFlat.new()
		s.bg_color = Color("#383835") if state in ["hover", "pressed"] else (SURFACE if state == "disabled" else Color("#2b2b29"))
		s.border_color = Color("#383835") if state == "disabled" else INK_3
		s.set_border_width_all(1)
		s.set_corner_radius_all(4)
		s.content_margin_top = 6
		s.content_margin_bottom = 6
		b.add_theme_stylebox_override(state, s)


func _build_overlay() -> void:
	var back := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.098, 0.82)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	back.add_theme_stylebox_override("panel", sb)
	back.anchor_top = 1.0
	back.anchor_bottom = 1.0
	back.offset_left = 10
	back.offset_top = -86
	back.offset_bottom = -10
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)
	status.bbcode_enabled = true
	status.fit_content = true
	status.autowrap_mode = TextServer.AUTOWRAP_OFF
	status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_theme_color_override("default_color", INK_2)
	status.add_theme_font_size_override("normal_font_size", 12)
	back.add_child(status)


# ---------- dates ----------

func _days_in_month(y: int, m: int) -> int:
	if m == 2:
		return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
	return 30 if m in [4, 6, 9, 11] else 31


func _doy(y: int, m: int, d: int) -> int:
	var t0 := Time.get_unix_time_from_datetime_dict({"year": y, "month": 1, "day": 1})
	var t := Time.get_unix_time_from_datetime_dict({"year": y, "month": m, "day": d})
	return int((t - t0) / 86400) + 1


func _clamp_day() -> void:
	if month == 0:
		day = 0
	elif day > _days_in_month(year, month):
		day = _days_in_month(year, month)
	day_slider.set_value_no_signal(day)


func _date_range() -> Vector2i:
	if month == 0:
		return Vector2i(1, 366)
	if day == 0:
		return Vector2i(_doy(year, month, 1), _doy(year, month, _days_in_month(year, month)))
	var d := _doy(year, month, day)
	return Vector2i(d, d)


func _date_text() -> String:
	if month == 0:
		return "%d (whole year)" % year
	if day == 0:
		return "%s %d (whole month)" % [MONTHS[month], year]
	return "%d %s %d" % [day, MONTHS[month], year]


func _imagery_date() -> String:
	var d := ""
	if month > 0 and day > 0:
		d = "%04d-%02d-%02d" % [year, month, day]  # an exact day always wins
	elif not selected_fire.is_empty():
		d = selected_fire.peak
	elif month == 0:
		d = "%04d-08-15" % year
	else:
		d = "%04d-%02d-%02d" % [year, month, day if day > 0 else 15]
	return d if d >= FIRST_IMAGERY else FIRST_IMAGERY


# ---------- data ----------

func _refresh_data() -> void:
	date_label.text = _date_text()
	frp_label.text = "Min fire radiative power: %d MW" % min_frp
	size_label.text = "Min fire event size: %.0f km²" % min_km2
	var r := _date_range()
	var mask := 7 if sensor_choice == 0 else (1 if sensor_choice == 1 else 6)

	shown_idx_modis = PackedInt32Array()
	shown_idx_viirs = PackedInt32Array()
	if show_hotspots and hs.load_year(year):
		var idx := hs.filter(r.x, r.y, mask, min_frp)
		for i in idx:
			if hs.sensor[i] == 0:
				shown_idx_modis.append(i)
			else:
				shown_idx_viirs.append(i)
	modis_layer.build(hs.pos, shown_idx_modis, Color(MODIS_COLOR, 0.9))
	viirs_layer.build(hs.pos, shown_idx_viirs, Color(VIIRS_COLOR, 0.9))

	# Fires burning at any time in the date range.
	shown_fires = []
	if show_fires:
		var a := "%04d-%02d-%02d" % [year, maxi(month, 1), maxi(day, 1)]
		var b := "%04d-%02d-%02d" % [year, month if month > 0 else 12,
			day if day > 0 else (_days_in_month(year, month) if month > 0 else 31)]
		for f in cal.fires:
			if f.start > b or f.end < a or f.km2 < min_km2:
				continue
			if not f.has("hull_world"):
				var hull := PackedVector2Array()
				for p in f.hull:
					hull.append(Mercator.to_world(p[0], p[1]))
				f["hull_world"] = hull
				f["fillable"] = hull.size() >= 3 and not Geometry2D.triangulate_polygon(hull).is_empty()
			shown_fires.append(f)
	vector.fires = shown_fires
	if not selected_fire.is_empty() and not shown_fires.has(selected_fire):
		_select_fire({})

	# Harmonized grid for the month (or the year's total).
	vector.grid_cells = []
	vector.grid_max = 1.0
	if show_grid:
		for c in cal.cell_count():
			var v := 0.0
			if month > 0:
				v = cal.cell_value(c, year, month)
			else:
				for m in range(1, 13):
					var x: float = cal.cell_value(c, year, m)
					if not is_nan(x):
						v += x
			if is_nan(v) or v <= 0.0:
				continue
			vector.grid_cells.append([_cell_rect(c), v])
			vector.grid_max = maxf(vector.grid_max, v)
	vector.outlook_cells = []
	if show_outlook and not cal.outlook_p.is_empty():
		for c in cal.cell_count():
			var p: Array = cal.outlook_p[c]
			var v: float = p[month - 1] if month > 0 else p.max()
			if v >= 0.02:
				vector.outlook_cells.append([_cell_rect(c), v])
	vector.queue_redraw()
	_apply_view()


func _cell_rect(c: int) -> Rect2:
	var a := Mercator.to_world(cal.cell_lat[c] + 0.125, cal.cell_lon[c] - 0.125)
	var b := Mercator.to_world(cal.cell_lat[c] - 0.125, cal.cell_lon[c] + 0.125)
	return Rect2(a, b - a)


# ---------- view ----------

func _map_size() -> Vector2:
	return Vector2(size.x - PANEL_W, size.y)


func _scale() -> float:
	return Mercator.scale_for_zoom(zoom)


func screen_to_world(p: Vector2) -> Vector2:
	return center + (p - _map_size() / 2.0) / _scale()


func _apply_view() -> void:
	var s := _scale()
	var ms := _map_size()
	if region_bbox.has_area():
		center = center.clamp(region_bbox.position, region_bbox.end)
	world.scale = Vector2(s, s)
	world.position = ms / 2.0 - center * s
	var rect := Rect2(center - ms / 2.0 / s, ms / s)
	var img_date := _imagery_date()
	base_tiles.visible = BASES[base_choice][1] != ""
	if base_tiles.visible:
		base_tiles.set_template(BASES[base_choice][1], BASES[base_choice][2])
		base_tiles.update_view(rect, zoom)
	sat_tiles.visible = show_sat
	if show_sat:
		sat_tiles.set_date(img_date)
		sat_tiles.update_view(rect, zoom)
	wind.visible = show_wind
	wind.map_size = ms
	wind.hour = wind_hour
	hour_label.text = "Hour: %02d:00 UTC (%02d:00 Pacific standard time)" % [wind_hour, (wind_hour + 16) % 24]
	if show_wind:
		_wind_date = img_date
		_wind_timer.start()  # fetch once the date stops changing
		wind.queue_redraw()
	modis_layer.set_view_scale(s)
	viirs_layer.set_view_scale(s)
	if absf(zoom - _last_vector_zoom) > 0.01:
		_last_vector_zoom = zoom
		vector.screen_scale = s
		vector.queue_redraw()
	_save_state()
	_update_status()
	queue_redraw()


func _zoom_at(screen_pos: Vector2, new_zoom: float) -> void:
	var wp := screen_to_world(screen_pos)
	zoom = clampf(new_zoom, MIN_ZOOM, MAX_ZOOM)
	center = wp - (screen_pos - _map_size() / 2.0) / _scale()
	_apply_view()


func _process(_delta: float) -> void:
	# Keep the loading counter fresh while tiles stream in.
	var n := sat_tiles.loading_count() + base_tiles.loading_count() + (1000 if wind.status == "loading" else 0)
	if n != _last_loading:
		_last_loading = n
		_update_status()


func _update_status() -> void:
	var n_hot := shown_idx_modis.size() + shown_idx_viirs.size()
	var loading := sat_tiles.loading_count() + base_tiles.loading_count()
	var base := "Base map: USGS National Map" if base_tiles.visible else "No base map"
	if show_sat:
		base += " · Satellite: NASA GIBS, MODIS Terra, %s" % _imagery_date()
	if show_wind:
		var ws := "loading…" if wind.status == "loading" else ("arrows point where it blows, longer = faster" if wind.status == "ready" else wind.status)
		base += "\nWind %s %02d:00 UTC, ERA5 reanalysis via Open-Meteo (modelled): %s" % [_imagery_date(), wind_hour, ws]
	status.text = "%s%s\n%s hotspots (observed, NASA FIRMS) · %d fire events · zoom %.1f\n%s" % [
		base, ("   loading %d tiles…" % loading) if loading > 0 else "",
		_thousands(n_hot), shown_fires.size(), zoom,
		"[color=#3987e5]■[/color] MODIS 1 km   [color=#d95926]■[/color] VIIRS 375 m   [color=#f0efec]□[/color] fire event outline (observed detections, grouped)"]


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_inside_tree():
		_apply_view()


# ---------- input ----------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.position.x > _map_size().x:
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.pressed:
					_drag = true
					_drag_moved = 0.0
				else:
					_drag = false
					if _drag_moved < 5.0:
						_pick(event.position)
					if event.double_click and not selected_fire.is_empty():
						_zoom_to_fire(selected_fire)
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_at(event.position, zoom + 0.5)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_at(event.position, zoom - 0.5)
	elif event is InputEventMouseMotion and _drag:
		_drag_moved += event.relative.length()
		center -= event.relative / _scale()
		_apply_view()
	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, zoom + log(event.factor) / log(2.0))
	elif event is InputEventPanGesture:
		center += event.delta * 8.0 / _scale()
		_apply_view()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.pressed:
		return
	var mid := _map_size() / 2.0
	match event.keycode:
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_zoom_at(mid, zoom + 1.0)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(mid, zoom - 1.0)


func _pick(screen_pos: Vector2) -> void:
	var wp := screen_to_world(screen_pos)
	# Hotspot first if one is right under the cursor, else the smallest fire containing the point.
	var best := -1
	var best_d := 8.0 / _scale()
	for idx in [shown_idx_viirs, shown_idx_modis]:
		for i in idx:
			var d := hs.pos[i].distance_to(wp)
			if d < best_d:
				best_d = d
				best = i
	var fire := {}
	for f in shown_fires:
		if Geometry2D.is_point_in_polygon(wp, f.hull_world) and (fire.is_empty() or f.km2 < fire.km2):
			fire = f
	_select_fire(fire)
	if best >= 0:
		var ll := hs.lat_lon(best)
		selected_info = "Hotspot (observed)\n%s, %d MW fire radiative power\nday %d of %d, %02d:00 UTC\n%.4f, %.4f" % [
			hs.SENSOR_NAMES[hs.sensor[best]], hs.frp[best], hs.doy[best], hs.year, hs.hour[best], ll.x, ll.y]
		if not fire.is_empty():
			selected_info += "\n\nInside fire event:\n" + _fire_text(fire)
	elif not fire.is_empty():
		selected_info = _fire_text(fire) + "\n\nDouble-click to zoom to it."
	else:
		selected_info = "Nothing here. Click a hotspot or inside a fire outline."
	if show_wind:
		var w: Vector2 = wind.wind_at(wp)
		if not is_nan(w.x):
			selected_info += "\n\nWind here (ERA5, modelled), %s %02d:00 UTC:\n%.1f m/s, blowing toward %.0f° (from %.0f°)" % [
				_imagery_date(), wind_hour, w.length(), fposmod(rad_to_deg(atan2(w.x, w.y)), 360.0),
				fposmod(rad_to_deg(atan2(w.x, w.y)) + 180.0, 360.0)]
	info.text = selected_info


func _fire_text(f: Dictionary) -> String:
	return "Fire event %s\n%s → %s (peak %s)\n%.0f km² footprint · %d detections\nObserved detections grouped in space and time; footprint is hotspot pixels, not burned area." % [
		f.id, f.start, f.end, f.peak, f.km2, f.det]


func _select_fire(f: Dictionary) -> void:
	selected_fire = f
	vector.selected_fire = f
	vector.queue_redraw()
	sim_button.disabled = f.is_empty()
	_apply_view()


func _zoom_to_fire(f: Dictionary) -> void:
	var b: Array = f.bbox
	var a := Mercator.to_world(b[2], b[1])
	var c := Mercator.to_world(b[0], b[3])
	center = (a + c) / 2.0
	var span := maxf((c - a).x / _map_size().x, (c - a).y / _map_size().y) * 1.4
	zoom = clampf(Mercator.ZREF + log(1.0 / maxf(span, 1e-6)) / log(2.0), MIN_ZOOM, MAX_ZOOM)
	_apply_view()


# ---------- screens ----------

func _open_sim() -> void:
	if selected_fire.is_empty():
		return
	AppState.sim_event = selected_fire
	AppState.return_scene = "res://ui/map_view.tscn"
	get_tree().change_scene_to_file("res://main.tscn")


func _open_calendar() -> void:
	var ms := _map_size()
	var a := Mercator.to_latlon(screen_to_world(Vector2.ZERO))
	var b := Mercator.to_latlon(screen_to_world(ms))
	var cells: PackedInt32Array = cal.cells_in_box(a.x, a.y, b.x, b.y)
	AppState.selection = cells if not cells.is_empty() else cal.all_cells()
	AppState.selected_year = year
	AppState.selected_month = maxi(month, 1)
	get_tree().change_scene_to_file("res://ui/calendar_view.tscn")


func _save_state() -> void:
	AppState.map_state = {"zoom": zoom, "center": center, "year": year, "month": month, "day": day,
		"sensor": sensor_choice, "min_frp": min_frp, "min_km2": min_km2, "base": base_choice,
		"hotspots": show_hotspots, "fires": show_fires, "grid": show_grid, "outlook": show_outlook,
		"sat": show_sat, "wind": show_wind, "hour": wind_hour}


func _restore_state() -> void:
	var s: Dictionary = AppState.map_state
	if s.is_empty():
		return
	zoom = s.zoom
	center = s.center
	year = s.year
	month = s.month
	day = s.day
	sensor_choice = s.sensor
	min_frp = s.min_frp
	min_km2 = s.min_km2
	base_choice = s.base
	show_hotspots = s.hotspots
	show_fires = s.fires
	show_grid = s.grid
	show_outlook = s.outlook
	show_sat = s.sat
	show_wind = s.wind
	wind_hour = s.hour
