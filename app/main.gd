## Fire sim screen: the grid on the left, a side panel with the controls on the right.
## Opened from the map or calendar with a hotspot / fire: builds a real region around it
## (fuel, terrain, hourly weather fetched live), seeds the fire from that day's observed
## detections and lets it play out. Opened on its own: fake test terrain.
## Everything in the panel also has a key: Space play/pause · N one step · [ / ] slower/faster ·
## Left/Right turn wind · Up/Down wind speed · H/J humidity -/+ · W recorded weather ·
## V aerial photo · O observed detections · R reset · F fit · T new test terrain · Esc/B back.
## Mouse: left = the chosen tool (ignite / firebreak / retardant), Shift+left = retardant,
## right drag = firebreak, wheel = zoom, middle drag = pan.
extends Node2D

const FireSim = preload("res://sim/fire_sim.gd")
const SimRegion = preload("res://data/sim_region.gd")
const RegionLoader = preload("res://sim/region_loader.gd")
const HotspotData = preload("res://data/hotspot_data.gd")
const Mercator = preload("res://map/mercator.gd")
const UI = preload("res://ui/ui_kit.gd")

const SPEEDS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]  # steps per second
const RETARDANT_RADIUS := 5.0
const FIREBREAK_WIDTH := 2
const MAX_VIEW_ZOOM := 8.0
const WHEEL_ZOOM_PER_NOTCH := 1.1  # zoom factor for one notch of an ordinary mouse wheel
const TOOL_IGNITE := 0
const TOOL_FIREBREAK := 1
const TOOL_RETARDANT := 2
const TOOL_HINTS := [
	"Click to start a fire there.",
	"Drag a line: those cells lose their fuel. Right-drag does this with any tool.",
	"Click to drop retardant: 5-cell radius, burning chance x 0.2. Shift+click does this with any tool.",
]
const SCALE_BAR_KM: Array[float] = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]

const FUEL_NAMES := ["No fuel", "Grass", "Grass + shrub", "Shrub", "Timber + brush", "Timber litter", "Slash"]
const FUEL_COLORS: Array[Color] = [
	Color(0.45, 0.55, 0.65),  # 0 NB  non-burnable
	Color(0.80, 0.78, 0.45),  # 1 GR  grass
	Color(0.62, 0.70, 0.38),  # 2 GS  grass-shrub
	Color(0.45, 0.58, 0.30),  # 3 SH  shrub
	Color(0.30, 0.50, 0.28),  # 4 TU  timber-understory
	Color(0.22, 0.40, 0.22),  # 5 TL  timber litter
	Color(0.55, 0.45, 0.32),  # 6 SB  slash-blowdown
]
const FIRE_COLOR := Color(1.0, 0.35, 0.05)
const BURNT_COLOR := Color(0.12, 0.10, 0.09)
const RETARDANT_COLOR := Color(0.85, 0.25, 0.45)
const OBSERVED_COLOR := Color(0.55, 0.8, 1.0, 0.38)  # detections after the seed day
const STATE_NAMES := ["no fuel", "unburnt", "burning", "burnt"]

var sim: FireSim = FireSim.new()
var image: Image
var texture: ImageTexture
var shade := PackedFloat32Array()
var playing := false
var speed_index := 3  # 8 steps per second
var step_timer := 0.0
var terrain_seed := 1
var tool := TOOL_IGNITE
var break_start := Vector2i(-1, -1)
var base_fuel := PackedByteArray()  # fuel before any firebreak, restored by Reset

# View: `view` holds the grid in cell units (1 cell = 1 unit) and is scaled / moved to zoom and pan.
var view := Node2D.new()
var sprite := Sprite2D.new()
var bg_sprite := Sprite2D.new()
var obs_sprite := Sprite2D.new()
var overlay := Node2D.new()      # wind compass, scale bar, firebreak preview (screen space)
var cell_px := 4.0               # screen pixels per cell
var view_zoom := 1.0             # 1 = the whole grid fits
var view_center := Vector2.ZERO  # cell (col, row) in the middle of the view
var _panning := false
var font: Font

# Real region (null on test terrain).
var region
var hs: HotspotData
var seeds := PackedInt32Array()  # indices into hs: detections on the seed day inside the grid
var loading := false
var load_text := ""
var manual_weather := false      # true once the user changes wind or humidity by hand
var weather_hour := -1           # index of the hour of weather now applied
var show_satellite := false
var obs_image: Image
var obs_texture: ImageTexture
var observed_day := 0            # last day of year painted into the observed overlay
var observed_count := 0

# Panel.
var loading_label := Label.new()
var info_label: Label
var clock_label: Label
var run_label: Label
var stats_label: Label
var play_button: Button
var speed_buttons: Array = []
var tool_buttons: Array = []
var tool_hint: Label
var weather_status: Label
var wind_dir_label: Label
var wind_speed_label: Label
var humidity_label: Label
var derived_label: Label
var recorded_button: Button
var aerial_toggle: Button
var observed_toggle: Button
var terrain_button: Button
var cursor_label: Label
var inputs_label: Label


func _ready() -> void:
	font = ThemeDB.fallback_font
	RenderingServer.set_default_clear_color(UI.SURFACE)
	add_child(view)
	for s in [bg_sprite, sprite, obs_sprite]:
		s.centered = false
		view.add_child(s)
	bg_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	bg_sprite.visible = false
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	build_panel()
	get_viewport().size_changed.connect(apply_view)
	var req: Dictionary = AppState.sim_request
	if req.is_empty() and not AppState.sim_event.is_empty():
		req = SimRegion.request_for_fire(AppState.sim_event)
	if req.is_empty():
		new_terrain()
	else:
		start_region(req)


# ---------- setup ----------

func new_terrain() -> void:
	sim.make_test_terrain(terrain_seed)
	sim.set_wind(45.0, 5.0)
	build_view()
	playing = false


## Places the grid, finds the seed detections and starts fetching the real inputs.
func start_region(req: Dictionary) -> void:
	region = SimRegion.from_request(req)
	hs = HotspotData.new()
	hs.load_index()
	hs.load_year(region.year)
	seeds = region.hotspots_in(hs, region.doy, region.doy)
	# The clock starts at the last satellite pass of the seed day.
	var last_hour := -1
	for i in seeds:
		last_hour = maxi(last_hour, hs.hour[i])
	if last_hour >= 0:
		region.start_hour = last_hour
	loading = true
	load_text = "starting"
	var loader := RegionLoader.new()
	add_child(loader)
	loader.progress.connect(func(done: int, total: int): load_text = "%d of %d requests done" % [done, total])
	loader.finished.connect(_on_region_loaded.bind(loader))
	loader.start(region)


func _on_region_loaded(loader: Node) -> void:
	loader.queue_free()
	sim.setup(region.rows, region.cols, region.cell_size_m)
	sim.fuel = region.fuel
	sim.elevation = region.elevation
	sim.finish_terrain()
	build_view()
	if region.background != null:
		bg_sprite.texture = ImageTexture.create_from_image(region.background)
		bg_sprite.scale = Vector2.ONE * sim.cols / region.background.get_width()
	obs_image = Image.create(sim.cols, sim.rows, false, Image.FORMAT_RGBA8)
	obs_texture = ImageTexture.create_from_image(obs_image)
	obs_sprite.texture = obs_texture
	loading = false
	restart_region_fire()


## Paints every cell and fits the whole grid in the window.
func build_view() -> void:
	base_fuel = sim.fuel.duplicate()  # packed arrays are shared on assignment, so copy
	compute_shade()
	image = Image.create(sim.cols, sim.rows, false, Image.FORMAT_RGBA8)
	for i in sim.rows * sim.cols:
		paint(i)
	texture = ImageTexture.create_from_image(image)
	sprite.texture = texture
	fit_view()


## Puts out the fire and removes every firebreak and retardant drop. (The engine's own
## reset_fire() keeps interventions, so they are undone here by restoring the cell data.)
func clear_fire() -> void:
	sim.fuel = base_fuel.duplicate()
	sim.retardant.fill(1.0)
	sim.reset_fire()
	break_start = Vector2i(-1, -1)


## Clears the fire and the interventions, goes back to the recorded weather and re-seeds
## from the detections.
func restart_region_fire() -> void:
	clear_fire()
	playing = false
	manual_weather = not region.weather_ok
	if manual_weather:
		sim.set_wind(45.0, 5.0)
	weather_hour = -1
	apply_weather()
	for i in seeds:
		var cell: Vector2i = region.cell_of(hs.pos[i])
		if not sim.ignite(cell.x, cell.y) and sim.state[sim.index(cell.x, cell.y)] == FireSim.NO_FUEL:
			ignite_next_to(cell)
	obs_image.fill(Color(0, 0, 0, 0))
	obs_texture.update(obs_image)
	observed_day = region.doy
	observed_count = 0
	repaint_all()


## A detection centred on a road or water cell: start in the first burnable neighbour.
func ignite_next_to(cell: Vector2i) -> void:
	for d in FireSim.DIRS:
		if sim.ignite(cell.x + d.x, cell.y + d.y):
			return


func compute_shade() -> void:
	shade.resize(sim.rows * sim.cols)
	for r in sim.rows:
		for c in sim.cols:
			var e_e: float = sim.elevation[sim.index(r, mini(c + 1, sim.cols - 1))]
			var e_w: float = sim.elevation[sim.index(r, maxi(c - 1, 0))]
			var e_s: float = sim.elevation[sim.index(mini(r + 1, sim.rows - 1), c)]
			var e_n: float = sim.elevation[sim.index(maxi(r - 1, 0), c)]
			# Light from the north-west.
			var g := ((e_e - e_w) + (e_s - e_n)) / (2.0 * sim.cell_size_m)
			shade[sim.index(r, c)] = clampf(0.9 + g * 2.0, 0.55, 1.2)


# ---------- view: fit, zoom, pan ----------

## The part of the window left of the panel.
func map_size() -> Vector2:
	var v := get_viewport_rect().size
	return Vector2(v.x - UI.PANEL_W, v.y)


func fit_view() -> void:
	view_zoom = 1.0
	view_center = Vector2(sim.cols, sim.rows) / 2.0
	apply_view()


func apply_view() -> void:
	if sim.cols == 0:
		return
	var ms := map_size()
	cell_px = minf(ms.x / sim.cols, ms.y / sim.rows) * view_zoom
	# Don't pan past the grid: the centre can move only as far as the grid overflows the view.
	var half := ms / 2.0 / cell_px
	var lo := Vector2(minf(half.x, sim.cols / 2.0), minf(half.y, sim.rows / 2.0))
	view_center = view_center.clamp(lo, Vector2(sim.cols, sim.rows) - lo)
	view.scale = Vector2(cell_px, cell_px)
	view.position = ms / 2.0 - view_center * cell_px


## Zoom keeping the cell under `screen_pos` in place.
func zoom_at(screen_pos: Vector2, new_zoom: float) -> void:
	var under := (screen_pos - view.position) / cell_px
	var old_zoom := view_zoom
	view_zoom = clampf(new_zoom, 1.0, MAX_VIEW_ZOOM)
	var new_px := cell_px * view_zoom / old_zoom
	view_center = under - (screen_pos - map_size() / 2.0) / new_px
	apply_view()


func mouse_cell() -> Vector2i:
	var p := view.get_local_mouse_position()
	return Vector2i(floori(p.y), floori(p.x))  # (row, col)


## Screen position of the middle of a cell.
func cell_screen(cell: Vector2i) -> Vector2:
	return view.position + Vector2(cell.y + 0.5, cell.x + 0.5) * cell_px


# ---------- drawing ----------

func paint(i: int) -> void:
	var col: Color
	match sim.state[i]:
		FireSim.BURNING:
			col = FIRE_COLOR
			col.a = 1.0
		FireSim.BURNT:
			col = BURNT_COLOR
			col.a = 0.8 if show_satellite else 1.0
		_:
			col = FUEL_COLORS[sim.fuel[i]] * shade[i]
			col.a = 0.0 if show_satellite else 1.0  # aerial view: the photo shows through
			if sim.retardant[i] < 1.0:
				col = col.lerp(RETARDANT_COLOR, 0.45)
				col.a = 0.6 if show_satellite else 1.0
	image.set_pixel(i % sim.cols, i / sim.cols, col)


func repaint_changed() -> void:
	for i in sim.changed:
		paint(i)
	texture.update(image)


func repaint_all() -> void:
	for i in sim.rows * sim.cols:
		paint(i)
	texture.update(image)


## Day of year the sim clock is on.
func sim_day() -> int:
	return region.doy + int((region.start_hour * 60 + sim.elapsed_minutes) / 1440.0)


func clock_text() -> String:
	var minutes := int(region.start_hour * 60 + sim.elapsed_minutes)
	return "%s %02d:%02d UTC" % [SimRegion.date_string(region.year, sim_day()), (minutes / 60) % 24, minutes % 60]


## Paints the footprints of observed detections from the days the sim clock has reached
## (after the seed day), to compare the simulated spread with what the satellites saw.
func update_observed() -> void:
	var day := sim_day()
	if day <= observed_day:
		return
	for i in region.hotspots_in(hs, observed_day + 1, day):
		var cell: Vector2i = region.cell_of(hs.pos[i])
		var half: int = region.footprint_half_cells(hs.sensor[i])
		obs_image.fill_rect(Rect2i(cell.y - half, cell.x - half, half * 2 + 1, half * 2 + 1), OBSERVED_COLOR)
		observed_count += 1
	observed_day = day
	obs_texture.update(obs_image)


## Uses the recorded weather for the hour the sim clock is in, unless the user took over.
func apply_weather() -> void:
	if region == null or manual_weather or not region.weather_ok:
		return
	var h: int = region.weather_index(sim.elapsed_minutes)
	if h == weather_hour:
		return
	weather_hour = h
	var w: PackedFloat32Array = region.weather[h]
	sim.set_weather(w[0], w[1], w[2], w[3])


func _process(delta: float) -> void:
	if not loading and playing:
		step_timer += delta
		var interval := 1.0 / SPEEDS[speed_index]
		while step_timer >= interval:
			step_timer -= interval
			step_once()
			if sim.is_done():
				playing = false
				break
	update_panel()
	overlay.queue_redraw()


func step_once() -> void:
	sim.step()
	repaint_changed()
	if region != null:
		apply_weather()
		update_observed()


## Wind compass, scale bar and the firebreak being dragged, drawn over the grid.
func _draw_overlay() -> void:
	if loading or sim.cols == 0:
		return
	# Wind compass, top left: the arrow points where the wind blows toward.
	var c := Vector2(58, 58)
	overlay.draw_circle(c, 44, Color(0.08, 0.08, 0.08, 0.7))
	overlay.draw_arc(c, 44, 0, TAU, 48, Color(1, 1, 1, 0.25), 1.0, true)
	overlay.draw_string(font, c + Vector2(-4, -30), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UI.INK_3)
	var dir := Vector2(sin(deg_to_rad(sim.wind_to_deg)), -cos(deg_to_rad(sim.wind_to_deg)))
	var length := minf(14.0 + sim.wind_speed * 4.0, 56.0)
	var tip := c + dir * length * 0.5
	overlay.draw_line(c - dir * length * 0.5, tip, UI.INK, 3.0, true)
	overlay.draw_line(tip, tip - dir.rotated(0.5) * 11, UI.INK, 3.0, true)
	overlay.draw_line(tip, tip - dir.rotated(-0.5) * 11, UI.INK, 3.0, true)
	overlay.draw_string(font, c + Vector2(-44, 62), "wind %.1f m/s" % sim.wind_speed, HORIZONTAL_ALIGNMENT_CENTER, 88, 12, UI.INK)
	# Scale bar, bottom left: the longest round distance that fits in ~140 px.
	var km: float = SCALE_BAR_KM[0]
	for k in SCALE_BAR_KM:
		if k * 1000.0 / sim.cell_size_m * cell_px <= 140.0:
			km = k
	var bar := km * 1000.0 / sim.cell_size_m * cell_px
	var a := Vector2(18, map_size().y - 22)
	overlay.draw_rect(Rect2(a + Vector2(-8, -22), Vector2(bar + 16, 34)), Color(0.08, 0.08, 0.08, 0.7))
	overlay.draw_line(a, a + Vector2(bar, 0), UI.INK, 2.0)
	overlay.draw_line(a, a + Vector2(0, -5), UI.INK, 2.0)
	overlay.draw_line(a + Vector2(bar, 0), a + Vector2(bar, -5), UI.INK, 2.0)
	overlay.draw_string(font, a + Vector2(0, -8), "%s km" % str(km).trim_suffix(".0"), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UI.INK)
	# Firebreak preview while dragging.
	if break_start.x >= 0:
		overlay.draw_line(cell_screen(break_start), get_viewport().get_mouse_position(), Color(1, 1, 1, 0.7), maxf(FIREBREAK_WIDTH * cell_px, 2.0))


# ---------- actions (panel buttons and keys) ----------

func go_back() -> void:
	get_tree().change_scene_to_file(AppState.return_scene)


func toggle_play() -> void:
	if not loading:
		playing = not playing


func step_button() -> void:
	if not loading:
		step_once()


func reset_fire() -> void:
	if loading:
		return
	if region != null:
		restart_region_fire()
	else:
		clear_fire()
		repaint_all()
		playing = false


func set_speed(i: int) -> void:
	speed_index = clampi(i, 0, SPEEDS.size() - 1)
	speed_buttons[speed_index].button_pressed = true


func set_tool(i: int) -> void:
	tool = i
	tool_buttons[i].button_pressed = true
	tool_hint.text = TOOL_HINTS[i]


## Changing the wind by hand stops the recorded weather until "Back to recorded weather".
func nudge_wind(d_deg: float, d_speed: float) -> void:
	manual_weather = true
	sim.set_wind(sim.wind_to_deg + d_deg, sim.wind_speed + d_speed)


func nudge_humidity(d_pct: float) -> void:
	manual_weather = true
	sim.set_moisture(sim.humidity_pct + d_pct, sim.temperature_c)


func use_recorded_weather() -> void:
	if region != null and region.weather_ok:
		manual_weather = false
		weather_hour = -1
		apply_weather()


func set_aerial(on: bool) -> void:
	show_satellite = on
	bg_sprite.visible = on
	if image != null:
		repaint_all()


func next_terrain() -> void:
	if region == null:
		terrain_seed += 1
		new_terrain()


# ---------- input ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE, KEY_B]:
		go_back()
		return
	if loading:
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion and _panning:
		view_center -= event.relative / cell_px
		apply_view()
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				toggle_play()
			KEY_N:
				step_once()
			KEY_LEFT:
				nudge_wind(-15.0, 0.0)
			KEY_RIGHT:
				nudge_wind(15.0, 0.0)
			KEY_UP:
				nudge_wind(0.0, 1.0)
			KEY_DOWN:
				nudge_wind(0.0, -1.0)
			KEY_H:
				nudge_humidity(-5.0)
			KEY_J:
				nudge_humidity(5.0)
			KEY_W:
				use_recorded_weather()
			KEY_V:
				if not aerial_toggle.disabled:
					aerial_toggle.button_pressed = not aerial_toggle.button_pressed
			KEY_O:
				observed_toggle.button_pressed = not observed_toggle.button_pressed
			KEY_R:
				reset_fire()
			KEY_F:
				fit_view()
			KEY_BRACKETLEFT:
				set_speed(speed_index - 1)
			KEY_BRACKETRIGHT:
				set_speed(speed_index + 1)
			KEY_T:
				next_terrain()


func _mouse_button(event: InputEventMouseButton) -> void:
	# Presses over the side panel are the panel's: scrolling it must not zoom the grid, and a click on
	# its empty parts must not ignite or drop anything on cells hidden under it.
	if event.pressed and event.position.x > map_size().x:
		return
	var cell := mouse_cell()
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				zoom_at(event.position, view_zoom * pow(WHEEL_ZOOM_PER_NOTCH, UI.wheel_notches(event)))
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				zoom_at(event.position, view_zoom / pow(WHEEL_ZOOM_PER_NOTCH, UI.wheel_notches(event)))
		MOUSE_BUTTON_MIDDLE:
			_panning = event.pressed
		MOUSE_BUTTON_LEFT:
			if not event.pressed:
				finish_firebreak(cell)
			elif event.shift_pressed or tool == TOOL_RETARDANT:
				sim.apply_retardant(cell.x, cell.y, RETARDANT_RADIUS)
				repaint_changed()
			elif tool == TOOL_FIREBREAK:
				break_start = cell
			else:
				sim.changed = PackedInt32Array()
				sim.ignite(cell.x, cell.y)
				repaint_changed()
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				break_start = cell
			else:
				finish_firebreak(cell)


func finish_firebreak(cell: Vector2i) -> void:
	if break_start.x < 0:
		return
	sim.add_firebreak(break_start.x, break_start.y, cell.x, cell.y, FIREBREAK_WIDTH)
	repaint_changed()
	break_start = Vector2i(-1, -1)


# ---------- side panel ----------

func build_panel() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	loading_label.position = Vector2(28, 24)
	loading_label.add_theme_font_size_override("font_size", 15)
	loading_label.add_theme_color_override("font_color", UI.INK_2)
	layer.add_child(loading_label)
	var box := UI.side_panel(layer)

	UI.heading(box, "Fire sim", 20)
	UI.text(box, "SIMULATED what-if for planning and training. Not a prediction.")
	info_label = UI.text(box, "", UI.INK_2, 13)
	UI.button(box, "‹ Back", "Esc or B", go_back)

	UI.heading(box, "Run")
	clock_label = UI.text(box, "", UI.INK, 16)
	run_label = UI.text(box, "")
	var run_row := HBoxContainer.new()
	run_row.add_theme_constant_override("separation", 3)
	box.add_child(run_row)
	play_button = UI.button(run_row, "Play", "Space", toggle_play)
	UI.button(run_row, "One step", "N", step_button)
	UI.button(run_row, "Reset", "R: put the fire back to its start and remove firebreaks and retardant", reset_fire)
	UI.text(box, "Speed (steps per second)")
	speed_buttons = UI.segmented(box, ["1", "2", "4", "8", "16", "32"], speed_index, set_speed)
	stats_label = UI.text(box, "", UI.INK_2, 13)

	UI.heading(box, "Click on the map to")
	tool_buttons = UI.segmented(box, ["Ignite", "Firebreak", "Retardant"], tool, set_tool)
	tool_hint = UI.text(box, TOOL_HINTS[tool])

	UI.heading(box, "Weather")
	weather_status = UI.text(box, "")
	wind_dir_label = UI.stepper(box, "Turn the wind 15° left (Left arrow)", "Turn the wind 15° right (Right arrow)",
		nudge_wind.bind(-15.0, 0.0), nudge_wind.bind(15.0, 0.0))
	wind_speed_label = UI.stepper(box, "1 m/s slower (Down arrow)", "1 m/s faster (Up arrow)",
		nudge_wind.bind(0.0, -1.0), nudge_wind.bind(0.0, 1.0))
	humidity_label = UI.stepper(box, "5% drier (H)", "5% damper (J)", nudge_humidity.bind(-5.0), nudge_humidity.bind(5.0))
	derived_label = UI.text(box, "")
	recorded_button = UI.button(box, "Back to recorded weather", "W", use_recorded_weather)

	UI.heading(box, "View")
	var toggles := GridContainer.new()
	toggles.columns = 2
	toggles.add_theme_constant_override("h_separation", 4)
	box.add_child(toggles)
	aerial_toggle = UI.toggle(toggles, "Aerial photo", "V: show the fire over a USGS aerial photo instead of the fuel map", false, set_aerial)
	observed_toggle = UI.toggle(toggles, "Observed later", "O: detections the satellites made on later days (light blue)", true,
		func(on: bool): obs_sprite.visible = on)
	UI.button(box, "Fit whole area", "F. Scroll to zoom, drag with the middle button to pan", fit_view)
	terrain_button = UI.button(box, "New test terrain", "T", next_terrain)
	var legend := GridContainer.new()
	legend.columns = 2
	legend.add_theme_constant_override("h_separation", 4)
	legend.add_theme_constant_override("v_separation", 2)
	box.add_child(legend)
	for i in FUEL_NAMES.size():
		UI.swatch(legend, FUEL_COLORS[i], FUEL_NAMES[i])
	UI.swatch(legend, FIRE_COLOR, "Burning")
	UI.swatch(legend, BURNT_COLOR.lightened(0.25), "Burnt")
	UI.swatch(legend, RETARDANT_COLOR, "Retardant")
	UI.swatch(legend, Color(OBSERVED_COLOR, 1.0), "Observed later")

	UI.heading(box, "Under the cursor")
	cursor_label = UI.text(box, "", UI.INK_2)
	UI.heading(box, "Inputs")
	inputs_label = UI.text(box, "")
	UI.text(box, "Keys: Space play · N step · [ ] speed · arrows wind · H J humidity · W recorded weather · V aerial · O observed · R reset · F fit · Esc back")


func update_panel() -> void:
	loading_label.visible = loading
	if loading:
		loading_label.text = "Loading the real area for %s, %s\n\nFuel (LANDFIRE), terrain, hourly weather (ERA5)\nand an aerial photo are fetched live.\n%s" % [
			region.label, region.seed_date(), load_text]
		info_label.text = "Loading…"
		return
	var real: bool = region != null
	var mins := int(sim.elapsed_minutes)
	play_button.text = "Pause" if playing else "Play"
	clock_label.text = clock_text() if real else "+%dh %02dm" % [mins / 60, mins % 60]
	run_label.text = "%s · step %d · %.1f min per step%s" % [
		("+%dh %02dm since the start" % [mins / 60, mins % 60]) if real else "sim time",
		sim.step_count, sim.step_minutes, " · fire is out" if sim.is_done() and sim.step_count > 0 else ""]
	var fire_cells: int = sim.burnt_count + sim.burning.size()
	stats_label.text = "Fire area %s ha\nBurning %s cells · burnt %s cells" % [
		UI.thousands(int(fire_cells * sim.cell_size_m * sim.cell_size_m / 10000.0)),
		UI.thousands(sim.burning.size()), UI.thousands(sim.burnt_count)]

	wind_dir_label.text = "Wind toward %.0f° (%s)" % [sim.wind_to_deg, UI.compass(sim.wind_to_deg)]
	wind_speed_label.text = "Wind speed %.1f m/s" % sim.wind_speed
	humidity_label.text = "Humidity %.0f%%" % sim.humidity_pct
	derived_label.text = "Temperature %.0f °C · fuel moisture %.1f%%%s\nHead spread about %.1f km/h on flat shrub" % [
		sim.temperature_c, sim.fuel_moisture_pct, " (too damp to spread)" if sim.moisture_speed <= 0.0 else "",
		sim.ROS_FRACTION_OF_WIND * maxf(sim.wind_speed, sim.MIN_WIND_FOR_ROS) * 3.6 * sim.moisture_factor(sim.fuel_moisture_pct, sim.MX_BY_CLASS[3])]
	var recorded: bool = real and region.weather_ok
	if not real:
		weather_status.text = "Set by hand (test terrain)."
	elif not recorded:
		weather_status.text = "Recorded weather unavailable: set by hand."
	elif manual_weather:
		weather_status.text = "Changed by hand. The recorded weather is paused."
	else:
		weather_status.text = "Recorded: ERA5 hourly (modelled), follows the sim clock."
	recorded_button.disabled = not (recorded and manual_weather)

	aerial_toggle.visible = real
	aerial_toggle.disabled = not real or region.background == null
	observed_toggle.visible = real
	terrain_button.visible = not real
	info_label.text = region_text() if real else "Fake test terrain, %d x %d cells of %.0f m." % [sim.rows, sim.cols, sim.cell_size_m]
	inputs_label.text = inputs_text() if real else "Made-up fuel and hills for testing."
	cursor_label.text = cursor_text()


func region_text() -> String:
	var seed_line := "No detections here that day: use Ignite to start a fire."
	if not seeds.is_empty():
		seed_line = "Started from %s observed detections (MODIS + VIIRS) on %s." % [UI.thousands(seeds.size()), region.seed_date()]
	return "%s\n%s\nGrid %d x %d cells of %.0f m (%.0f km across)." % [
		region.label, seed_line,
		sim.rows, sim.cols, sim.cell_size_m, sim.cols * sim.cell_size_m / 1000.0]


func inputs_text() -> String:
	var lf: int = SimRegion.landfire_year(region.year)
	var fuel_line := "uniform shrub (LANDFIRE unavailable)"
	if region.fuel_ok:
		fuel_line = "LANDFIRE %d FBFM40" % lf
		if lf >= region.year:
			fuel_line += " (mapped after this fire: old burn scars can show as light fuel)"
	return "Fuel: %s\nTerrain: %s\nWeather: %s\nLight blue: observed detections on later days (%s so far)." % [
		fuel_line, "elevation tiles (Terrarium)" if region.elevation_ok else "flat (elevation unavailable)",
		"ERA5 hourly, modelled (Open-Meteo)" if region.weather_ok else "unavailable",
		UI.thousands(observed_count)]


func cursor_text() -> String:
	var cell := mouse_cell()
	if not sim.in_bounds(cell.x, cell.y) or get_viewport().get_mouse_position().x > map_size().x:
		return "Move over the map."
	var i := sim.index(cell.x, cell.y)
	var t := "%s · %.0f m · %s" % [FUEL_NAMES[sim.fuel[i]], sim.elevation[i], STATE_NAMES[sim.state[i]]]
	if sim.retardant[i] < 1.0:
		t += " · retardant"
	if region != null:
		var ll := Mercator.to_latlon(region.origin + Vector2(cell.y + 0.5, cell.x + 0.5) * region.cell_world)
		t += "\n%.4f, %.4f" % [ll.x, ll.y]
	return t
