## Start screen: a pannable, zoomable map of California with hotspots, fire outlines and the
## harmonized burning grid. The side panel has a month calendar (days shaded by hotspot count),
## layer toggles and preset filters.
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
const SimRegion = preload("res://data/sim_region.gd")

const SURFACE := Color("#1a1a19")
const PANEL_BG := Color("#222220")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
# Ring colour per sensor code (0 MODIS, 1 VIIRS S-NPP, 2 VIIRS NOAA-20): blue, yellow, aqua from the
# categorical palette, validated all-pairs colour-blind safe on the dark surface. The red centre
# of every hotspot (HotspotLayer.CORE_COLOR) means "observed fire detection", whatever the satellite.
const SENSOR_COLORS: Array[Color] = [Color("#3987e5"), Color("#c98500"), Color("#199e70")]
const ALL_RED: Array[Color] = [HotspotLayer.CORE_COLOR, HotspotLayer.CORE_COLOR, HotspotLayer.CORE_COLOR]
const PANEL_W := 340.0
const INNER_W := PANEL_W - 30.0
const DAY_W := 42.0
const FRP_STEPS := [0, 10, 50, 100]      # MW
const SIZE_STEPS := [0, 10, 50, 200]     # km2
const MONTH_NAMES := ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
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
# Backdrop outside California: a dark silhouette, not a map. Land is flat dark grey with
# thin diagonal white stripes ("not covered here"), water is dark blue, and a light line
# marks the shore. The land / water shapes come from low-zoom USGS topo tiles (the topo map
# draws water in blue); nothing else from the tiles is shown.
const BACKDROP_MAX_ZOOM := 7
const BACKDROP_LAND := Color("#2b2b29")
const BACKDROP_WATER := Color("#122436")
const BACKDROP_STRIPE := Color(1, 1, 1, 0.13)
const BACKDROP_BORDER := Color("#8a897f")
const BACKDROP_SHADER := "
shader_type canvas_item;
uniform vec4 land : source_color;
uniform vec4 water : source_color;
uniform vec4 stripe : source_color;
uniform vec4 border : source_color;
float water_at(sampler2D tex, vec2 uv) {
	vec4 c = texture(tex, uv);
	return smoothstep(0.03, 0.12, c.b - c.r);  // the topo map draws water in blue
}
void fragment() {
	// Water only where the pixels 3 texels away on every side are water too: this drops
	// rivers, blue labels and road shields, and keeps the ocean and real lakes.
	vec2 d = TEXTURE_PIXEL_SIZE * 3.0;
	float w = water_at(TEXTURE, UV);
	w = min(w, min(water_at(TEXTURE, UV + vec2(d.x, 0.0)), water_at(TEXTURE, UV - vec2(d.x, 0.0))));
	w = min(w, min(water_at(TEXTURE, UV + vec2(0.0, d.y)), water_at(TEXTURE, UV - vec2(0.0, d.y))));
	float aa = fwidth(w) + 0.0001;
	float is_water = smoothstep(0.5 - aa, 0.5 + aa, w);  // sharp edge at any zoom
	float shore = 1.0 - smoothstep(aa * 0.75, aa * 1.5, abs(w - 0.5));
	// Stripes are fixed to the screen: 1.5 px wide, every 14 px, running bottom-left to top-right.
	float on_stripe = step(fract((FRAGCOORD.x + FRAGCOORD.y) / 14.0), 0.11);
	vec3 col = mix(mix(land.rgb, stripe.rgb, on_stripe * stripe.a), water.rgb, is_water);
	COLOR = vec4(mix(col, border.rgb, shore), 1.0);
}
"
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
var cal_month := 11        # month shown in the calendar (month is 0 for "whole year")
var _last_day := 8         # day to return to when switching back to "single day"
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
var color_by_satellite := false  # off: every hotspot is plain red
var wind_hour := 20        # UTC
var _wind_date := ""

# Results.
var shown_idx_modis := PackedInt32Array()
var shown_idx_viirs := PackedInt32Array()
var shown_fires: Array = []
var selected_fire := {}
var selected_info := ""
var _built := false          # _ready has built the view
var picked_hotspot := -1   # index into hs of the clicked hotspot, -1 = none
var outlook_month := -1    # month the outlook layer shows (0 = each cell's peak); -1 = follow the map's month
var outlook_toggle: Button
var outlook_edit := LineEdit.new()
var outlook_result := Label.new()

# Nodes.
var world := Node2D.new()
var region_clip: RegionClip = RegionClip.new()
var backdrop_tiles: TileLayer = TileLayer.new()  # greyed-out surroundings, not clipped to the state
var base_tiles: TileLayer = TileLayer.new()
var sat_tiles: TileLayer = TileLayer.new()
var wind: WindLayer = WindLayer.new()
var _wind_timer := Timer.new()
var region_bbox := Rect2()   # world rect of California, limits panning
var hour_label := Label.new()
var wind_row := HBoxContainer.new()
var month_label := Label.new()
var day_grid := GridContainer.new()
var cal_note := Label.new()
var scope_buttons: Array = []
var vector: VectorLayer = VectorLayer.new()
var modis_layer: HotspotLayer = HotspotLayer.new()
var viirs_layer: HotspotLayer = HotspotLayer.new()
var status := RichTextLabel.new()
var info := Label.new()
var date_label := Label.new()
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
	if AppState.map_state.is_empty():
		_fit_state()  # first visit: show the whole state, sized for this window
	base_tiles.setup(BASES[base_choice][1], BASES[base_choice][2])
	sat_tiles.setup(GIBS_DAILY, 9)
	# Keep the whole state in memory at low zoom, so zooming always has something to show.
	base_tiles.preload_region(region_bbox, 6, 9)
	get_window().size_changed.connect(_apply_view)
	backdrop_tiles.setup(USGS % "USGSTopo", BACKDROP_MAX_ZOOM)
	var backdrop_shader := Shader.new()
	backdrop_shader.code = BACKDROP_SHADER
	var backdrop_mat := ShaderMaterial.new()
	backdrop_mat.shader = backdrop_shader
	backdrop_mat.set_shader_parameter("land", BACKDROP_LAND)
	backdrop_mat.set_shader_parameter("water", BACKDROP_WATER)
	backdrop_mat.set_shader_parameter("stripe", BACKDROP_STRIPE)
	backdrop_mat.set_shader_parameter("border", BACKDROP_BORDER)
	backdrop_tiles.material = backdrop_mat
	backdrop_tiles.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	world.add_child(backdrop_tiles)
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
	_built = true
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
	scroll.offset_right = -6
	scroll.offset_top = 12
	scroll.offset_bottom = -12
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = INNER_W
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)

	_heading(box, "California fire map", 20)

	# ----- date: month calendar -----
	date_label.add_theme_font_size_override("font_size", 16)
	date_label.add_theme_color_override("font_color", INK)
	box.add_child(date_label)
	var nav := HBoxContainer.new()
	box.add_child(nav)
	_nav_button(nav, "«", "Previous year", func(): _step_month(-12))
	_nav_button(nav, "‹", "Previous month", func(): _step_month(-1))
	month_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	month_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	month_label.add_theme_color_override("font_color", INK)
	nav.add_child(month_label)
	_nav_button(nav, "›", "Next month", func(): _step_month(1))
	_nav_button(nav, "»", "Next year", func(): _step_month(12))
	var week := GridContainer.new()
	week.columns = 7
	week.add_theme_constant_override("h_separation", 2)
	box.add_child(week)
	for d in ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]:
		var l := Label.new()
		l.text = d
		l.custom_minimum_size = Vector2(DAY_W, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 11)
		l.add_theme_color_override("font_color", INK_3)
		week.add_child(l)
	day_grid.columns = 7
	day_grid.add_theme_constant_override("h_separation", 2)
	day_grid.add_theme_constant_override("v_separation", 2)
	box.add_child(day_grid)
	cal_note.add_theme_font_size_override("font_size", 11)
	cal_note.add_theme_color_override("font_color", INK_3)
	cal_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cal_note.custom_minimum_size.x = INNER_W
	box.add_child(cal_note)
	var step := HBoxContainer.new()
	box.add_child(step)
	_action_button(step, "‹ Previous day", func(): _step_day(-1))
	_action_button(step, "Next day ›", func(): _step_day(1))
	_text(box, "Show", INK_3)
	scope_buttons = _segmented(box, ["Single day", "Whole month", "Whole year"], _scope(), _set_scope)

	# ----- layers -----
	_heading(box, "Layers", 15)
	var layers := GridContainer.new()
	layers.columns = 2
	layers.add_theme_constant_override("h_separation", 4)
	layers.add_theme_constant_override("v_separation", 4)
	box.add_child(layers)
	_toggle(layers, "Hotspots", "Individual satellite fire detections (observed)", show_hotspots, func(on): show_hotspots = on; _refresh_data())
	_toggle(layers, "Fire outlines", "Hotspots grouped into fire events", show_fires, func(on): show_fires = on; _refresh_data())
	_toggle(layers, "Burning grid", "Harmonized MODIS + VIIRS burning per 25 km cell", show_grid, func(on): show_grid = on; _refresh_data())
	outlook_toggle = _toggle(layers, "Outlook", "Outlook from past patterns, not a forecast of actual fires", show_outlook, func(on): show_outlook = on; _refresh_data())
	_toggle(layers, "Clouds + smoke", "NASA satellite image for that day, over the base map", show_sat, func(on): show_sat = on; _apply_view())
	_toggle(layers, "Wind", "Wind that day (ERA5 reanalysis, modelled)", show_wind, func(on): show_wind = on; _apply_view())
	_toggle(layers, "Satellite colours", "Ring each hotspot in its satellite's colour: MODIS blue, VIIRS S-NPP yellow, VIIRS NOAA-20 aqua",
		color_by_satellite, func(on): color_by_satellite = on; _refresh_data())
	wind_row.visible = show_wind
	box.add_child(wind_row)
	_nav_button(wind_row, "‹", "One hour earlier", func(): wind_hour = (wind_hour + 23) % 24; _apply_view())
	hour_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hour_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hour_label.add_theme_font_size_override("font_size", 13)
	hour_label.add_theme_color_override("font_color", INK_2)
	wind_row.add_child(hour_label)
	_nav_button(wind_row, "›", "One hour later", func(): wind_hour = (wind_hour + 1) % 24; _apply_view())

	# ----- outlook for a typed date -----
	_heading(box, "Fire season outlook", 15)
	_text(box, "Type a year, month or date, then press Enter.", INK_3)
	outlook_edit.placeholder_text = "2031   Sep 2030   2028-08-15"
	outlook_edit.add_theme_font_size_override("font_size", 13)
	outlook_edit.text_submitted.connect(_on_outlook_query)
	box.add_child(outlook_edit)
	outlook_result.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outlook_result.custom_minimum_size.x = INNER_W
	outlook_result.add_theme_font_size_override("font_size", 12)
	outlook_result.add_theme_color_override("font_color", INK_2)
	outlook_result.visible = false
	box.add_child(outlook_result)

	# ----- filters -----
	_heading(box, "Filters", 15)
	_text(box, "Sensor", INK_3)
	_segmented(box, ["All", "MODIS 1 km", "VIIRS 375 m"], sensor_choice, func(i): sensor_choice = i; _refresh_data())
	_text(box, "Hotspot heat output (fire radiative power)", INK_3)
	_segmented(box, ["Any", "10+ MW", "50+ MW", "100+ MW"], FRP_STEPS.find(min_frp), func(i): min_frp = FRP_STEPS[i]; _refresh_data())
	_text(box, "Fire size (hotspot footprint)", INK_3)
	_segmented(box, ["Any", "10+ km²", "50+ km²", "200+ km²"], SIZE_STEPS.find(int(min_km2)), func(i): min_km2 = SIZE_STEPS[i]; _refresh_data())

	# ----- base map -----
	_heading(box, "Base map", 15)
	_segmented(box, ["Labels", "Aerial", "Topo", "None"], base_choice, func(i): base_choice = i; _apply_view())

	# ----- selection -----
	_heading(box, "Selected", 15)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size.x = INNER_W
	info.text = "Click a hotspot or inside a fire outline."
	info.add_theme_font_size_override("font_size", 13)
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
	l.custom_minimum_size.x = INNER_W
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", c)
	box.add_child(l)


func _flat(bg: Color, border: Color, width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(4)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


## Dark when off, light when on (or pressed).
func _style_toggle(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _flat(Color("#2b2b29"), Color("#4a4a46")))
	b.add_theme_stylebox_override("hover", _flat(Color("#383835"), INK_3))
	b.add_theme_stylebox_override("pressed", _flat(Color("#e8e7e2"), Color("#e8e7e2")))
	b.add_theme_stylebox_override("hover_pressed", _flat(INK, INK))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", INK_2)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", SURFACE)
	b.add_theme_color_override("font_hover_pressed_color", SURFACE)
	b.add_theme_color_override("font_focus_color", INK_2)
	b.add_theme_font_size_override("font_size", 13)


func _toggle(box: Container, t: String, tip: String, on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_pressed = on
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_toggle(b)
	b.toggled.connect(cb)
	box.add_child(b)
	return b


## A row of buttons where exactly one is on. Returns the buttons.
func _segmented(box: Container, labels: Array, selected: int, cb: Callable) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	box.add_child(row)
	var group := ButtonGroup.new()
	var out := []
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == maxi(selected, 0)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_style_toggle(b)
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(cb.bind(i))
		row.add_child(b)
		out.append(b)
	return out


func _nav_button(box: Container, t: String, tip: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(34, 30)
	_style_toggle(b)
	b.add_theme_font_size_override("font_size", 16)
	b.pressed.connect(cb)
	box.add_child(b)


func _action_button(box: Container, t: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = t
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_toggle(b)
	b.pressed.connect(cb)
	box.add_child(b)


# ---------- calendar ----------

func _scope() -> int:
	return 2 if month == 0 else (1 if day == 0 else 0)


func _set_scope(i: int) -> void:
	if i == 2:
		month = 0
		day = 0
	elif i == 1:
		month = cal_month
		day = 0
	else:
		month = cal_month
		day = clampi(maxi(day, _last_day), 1, _days_in_month(year, month))
	_date_changed()


func _step_month(n: int) -> void:
	var k := year * 12 + cal_month - 1 + n
	k = clampi(k, 2000 * 12 + 10, 2026 * 12 + 11)  # Nov 2000 .. Dec 2026
	year = k / 12
	cal_month = k % 12 + 1
	if month != 0:
		month = cal_month
		if day > 0:
			day = mini(day, _days_in_month(year, month))
	_date_changed()


func _step_day(n: int) -> void:
	if month == 0 or day == 0:
		month = cal_month
		day = clampi(_last_day, 1, _days_in_month(year, month))
	else:
		var t := Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": day}) + n * 86400
		var d := Time.get_datetime_dict_from_unix_time(t)
		if d.year < 2000 or d.year > 2026:
			return
		year = d.year
		month = d.month
		day = d.day
		cal_month = month
	_date_changed()


func _pick_day(d: int) -> void:
	month = cal_month
	day = d
	_date_changed()


func _date_changed() -> void:
	outlook_month = -1  # the outlook layer follows the map's month again
	if day > 0:
		_last_day = day
	for i in scope_buttons.size():
		scope_buttons[i].set_pressed_no_signal(i == _scope())
	_refresh_data()


## Month grid. Each day is shaded by how many hotspots were detected that day (observed).
func _rebuild_calendar() -> void:
	for c in day_grid.get_children():
		c.queue_free()
	month_label.text = "%s %d" % [MONTH_NAMES[cal_month - 1], year]
	hs.load_year(year)
	var peak := 1
	for n in hs.day_counts:
		peak = maxi(peak, n)
	# Monday-first offset of the 1st of the month.
	var first := Time.get_datetime_dict_from_datetime_string("%04d-%02d-01" % [year, cal_month], true)
	var offset: int = (int(first.weekday) + 6) % 7
	for i in offset:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(DAY_W, 26)
		day_grid.add_child(pad)
	var has_record: bool = cal.has_data(year, cal_month)
	var month_total := 0
	for d in range(1, _days_in_month(year, cal_month) + 1):
		var n: int = hs.day_counts[_doy(year, cal_month, d)] if hs.day_counts.size() > 366 else 0
		month_total += n
		var b := Button.new()
		b.text = str(d)
		b.custom_minimum_size = Vector2(DAY_W, 26)
		b.tooltip_text = "%d %s %d: %s hotspots detected" % [d, MONTH_NAMES[cal_month - 1], year, _thousands(n)]
		var shade := Color("#262624") if n == 0 else VectorLayer._ramp(VectorLayer.REDS, log(1.0 + n) / log(1.0 + peak))
		var chosen := month == cal_month and (day == d or day == 0)
		var exact := month == cal_month and day == d
		# Selected day: a thick ring that contrasts with the cell's own shade.
		var ring := SURFACE if shade.get_luminance() > 0.45 else INK
		var border := ring if exact else (INK_3 if chosen else shade)
		b.add_theme_stylebox_override("normal", _flat(shade, border, 3 if exact else 1))
		b.add_theme_stylebox_override("hover", _flat(shade.lightened(0.15), INK, 1))
		b.add_theme_stylebox_override("pressed", _flat(shade, INK, 2))
		b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var ink := SURFACE if shade.get_luminance() > 0.45 else (INK_3 if n == 0 else INK)
		for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(c, ink)
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(_pick_day.bind(d))
		day_grid.add_child(b)
	if not has_record:
		cal_note.text = "No satellite record for this month (the record starts in Nov 2000). Missing data is not zero fire."
	else:
		cal_note.text = "Brighter day = more hotspots detected (observed). %s this month. Click a day." % _thousands(month_total)


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
	var zoom_box := VBoxContainer.new()
	zoom_box.position = Vector2(10, 10)
	zoom_box.add_theme_constant_override("separation", 3)
	add_child(zoom_box)
	_nav_button(zoom_box, "+", "Zoom in", func(): _zoom_at(_map_size() / 2.0, zoom + 1.0))
	_nav_button(zoom_box, "−", "Zoom out", func(): _zoom_at(_map_size() / 2.0, zoom - 1.0))
	_nav_button(zoom_box, "CA", "Show the whole state", _show_state)
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
	_rebuild_calendar()
	var r := _date_range()
	var mask := 7 if sensor_choice == 0 else (1 if sensor_choice == 1 else 6)

	shown_idx_modis = PackedInt32Array()
	shown_idx_viirs = PackedInt32Array()
	hs.load_year(year)
	picked_hotspot = -1  # indices change with the year and filters
	sim_button.disabled = selected_fire.is_empty()
	if show_hotspots:
		var idx := hs.filter(r.x, r.y, mask, min_frp)
		for i in idx:
			if hs.sensor[i] == 0:
				shown_idx_modis.append(i)
			else:
				shown_idx_viirs.append(i)
	# Plain red unless "Satellite colours" is on; then the ring shows which satellite saw it.
	var rings: Array[Color] = SENSOR_COLORS if color_by_satellite else ALL_RED
	modis_layer.build(hs.pos, shown_idx_modis, hs.sensor, rings)
	viirs_layer.build(hs.pos, shown_idx_viirs, hs.sensor, rings)

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
		var om := month if outlook_month < 0 else outlook_month
		for c in cal.cell_count():
			var p: Array = cal.outlook_p[c]
			var v: float = p[om - 1] if om > 0 else p.max()
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
	# On high-DPI or enlarged windows one map pixel covers several screen pixels: load sharper tiles.
	var bias := clampf(log(get_viewport().get_stretch_transform().get_scale().x) / log(2.0), 0.0, 1.5)
	base_tiles.pixel_bias = bias
	sat_tiles.pixel_bias = bias
	backdrop_tiles.update_view(rect, zoom)
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
	wind_row.visible = show_wind
	hour_label.text = "%02d:00 Pacific (%02d:00 UTC)" % [(wind_hour + 16) % 24, wind_hour]
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


func _show_state() -> void:
	_fit_state()
	_apply_view()


## Zoom and centre that fit the whole state in the map area (left of the panel), with a margin.
## Uses the window's current size, so it is sharper on big windows than a fixed zoom would be.
func _fit_state() -> void:
	if not region_bbox.has_area():
		zoom = 6.0
		center = Mercator.to_world(37.3, -119.4)
		return
	var area := get_viewport_rect().size - Vector2(PANEL_W, 0.0)
	var px_per_world := minf(area.x / region_bbox.size.x, area.y / region_bbox.size.y) * 0.88
	zoom = clampf(Mercator.ZREF + log(px_per_world) / log(2.0), MIN_ZOOM, MAX_ZOOM)
	center = region_bbox.get_center()


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
		_legend_text()]


func _legend_text() -> String:
	var t := "[color=#e5383b]●[/color] hotspot (observed)"
	if color_by_satellite:
		t += "   ring = satellite: [color=#3987e5]●[/color] MODIS 1 km   [color=#c98500]●[/color] VIIRS S-NPP   [color=#199e70]●[/color] VIIRS NOAA-20 (375 m)"
	return t + "\n[color=#f0efec]□[/color] fire event outline (observed detections, grouped)"


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _notification(what: int) -> void:
	# Before _ready the view isn't built yet (and saving it would count as a first visit).
	if what == NOTIFICATION_RESIZED and is_inside_tree() and _built:
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
	picked_hotspot = best
	_select_fire(fire)
	if best >= 0:
		var ll := hs.lat_lon(best)
		selected_info = "Hotspot (observed)\n%s, %d MW fire radiative power\nday %d of %d, %02d:00 UTC\n%.4f, %.4f" % [
			hs.SENSOR_NAMES[hs.sensor[best]], hs.frp[best], hs.doy[best], hs.year, hs.hour[best], ll.x, ll.y]
		if not fire.is_empty():
			selected_info += "\n\nInside fire event:\n" + _fire_text(fire)
		selected_info += "\n\nOpen in fire sim: 60 km around this hotspot, started from that day's detections."
	elif not fire.is_empty():
		selected_info = _fire_text(fire) + "\n\nDouble-click to zoom to it.\nOpen in fire sim: the whole fire, started from %s." % (
			"the selected day" if _fire_on_selected_day(fire) else "its first day")
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
	sim_button.disabled = f.is_empty() and picked_hotspot < 0
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

## A typed year, month or date. Dates in the satellite record move the map there (observed);
## later dates show the risk outlook for that month (the outlook is monthly, not daily).
func _on_outlook_query(text: String) -> void:
	outlook_edit.release_focus()
	outlook_result.visible = true
	var q := CalendarData.parse_date_query(text)
	if q.is_empty():
		outlook_result.text = "Couldn't read that. Try 2031, Sep 2030 or 2028-08-15."
		return
	var y: int = q.year if q.year > 0 else CalendarData.OUTLOOK_YEAR
	var m: int = q.month
	var last: String = cal.months[cal.months.size() - 1]  # last "YYYY-MM" with a record
	var after_record := y > cal.last_year if m == 0 else "%04d-%02d" % [y, m] > last
	if after_record:
		outlook_month = m
		show_outlook = true
		outlook_toggle.set_pressed_no_signal(true)
		_refresh_data()
		outlook_result.text = _outlook_text(y, m, q.day)
	elif y < CalendarData.FIRST_YEAR or (m > 0 and not cal.has_data(y, m)):
		outlook_result.text = "No satellite record for %s. The record starts in November 2000. Missing data is not zero fire." % (
			"%s %d" % [MONTH_NAMES[m - 1], y] if m > 0 else str(y))
	else:
		year = y
		month = m
		day = q.day if m > 0 else 0
		if m > 0:
			cal_month = m
		_date_changed()
		outlook_result.text = "%s is in the satellite record, so the map now shows what was observed. The outlook applies to dates after %s %s." % [
			_date_text(), MONTH_NAMES[int(last.substr(5, 2)) - 1], last.substr(0, 4)]


func _outlook_text(y: int, m: int, d: int) -> String:
	var by_month: PackedFloat32Array = cal.outlook_area(cal.all_cells())
	var order := range(12)
	order.sort_custom(func(a, b): return by_month[a] > by_month[b])
	var s: Dictionary = cal.outlook_summary(m)
	var t := ""
	if m > 0:
		t = "OUTLOOK for %s %d\nAbout %.0f of %d map cells (25 km each) are expected to have notable burning. %s ranks %d of 12 for the year; the peak is %s (%.0f cells).\nHigh risk: %d cells. Medium: %d cells. Shown in blue on the map." % [
			MONTH_NAMES[m - 1], y, s.expected, cal.cell_count(), MONTH_NAMES[m - 1], order.find(m - 1) + 1,
			MONTH_NAMES[order[0]], by_month[order[0]], s.high, s.medium]
		if d > 0:
			t += "\nThe outlook is monthly: %d %s gets the values for all of %s." % [d, MONTH_NAMES[m - 1], MONTH_NAMES[m - 1]]
	else:
		t = "OUTLOOK for %d\nBusiest months: %s (%.0f cells expected to have notable burning), %s (%.0f), %s (%.0f). Quietest: %s (%.0f).\n%d of %d cells reach High risk in at least one month, %d more reach Medium. The map shows each cell's peak month in blue." % [
			y, MONTH_NAMES[order[0]], by_month[order[0]], MONTH_NAMES[order[1]], by_month[order[1]],
			MONTH_NAMES[order[2]], by_month[order[2]], MONTH_NAMES[order[11]], by_month[order[11]],
			s.high, cal.cell_count(), s.medium]
	if y != CalendarData.OUTLOOK_YEAR:
		t += "\n\nThe model was built for %d from the 10 years of record before it. It has no newer data and no year input, so every date after the record gets this same outlook. The further from %d, the less it tells you." % [
			CalendarData.OUTLOOK_YEAR, CalendarData.OUTLOOK_YEAR]
	return t + "\n\nOutlook from historical patterns, not a forecast of actual fires. It can't foresee extreme years. Notable burning includes farm and prescribed burns."


## True if an exact day is selected and the fire was burning on it.
func _fire_on_selected_day(f: Dictionary) -> bool:
	if month == 0 or day == 0:
		return false
	var d := "%04d-%02d-%02d" % [year, month, day]
	return d >= f.start and d <= f.end


## A clicked hotspot opens 60 km around it, seeded from its day. A fire outline opens the
## whole fire, seeded from the selected day if it was burning then, else from its first day.
func _open_sim() -> void:
	if picked_hotspot >= 0:
		var ll := hs.lat_lon(picked_hotspot)
		AppState.sim_request = {"lat": ll.x, "lon": ll.y, "year": hs.year, "doy": hs.doy[picked_hotspot],
			"label": "hotspot %.4f, %.4f" % [ll.x, ll.y]}
	elif not selected_fire.is_empty():
		if _fire_on_selected_day(selected_fire):
			AppState.sim_request = SimRegion.request_for_fire(selected_fire, year, _doy(year, month, day))
		else:
			AppState.sim_request = SimRegion.request_for_fire(selected_fire)
	else:
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
		"cal_month": cal_month, "sat": show_sat, "wind": show_wind, "hour": wind_hour,
		"by_satellite": color_by_satellite}


func _restore_state() -> void:
	var s: Dictionary = AppState.map_state
	if s.is_empty():
		return
	zoom = s.zoom
	center = s.center
	year = s.year
	month = s.month
	day = s.day
	cal_month = month if month > 0 else s.get("cal_month", 8)
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
	color_by_satellite = s.get("by_satellite", false)
	wind_hour = s.hour
