## Top-down view of the fire sim.
## Opened from the map or calendar with a hotspot / fire: builds a real region around it
## (fuel, terrain, hourly weather fetched live), seeds the fire from that day's observed
## detections and lets it play out. Opened on its own: fake test terrain.
## Left click: ignite · Shift+left click: retardant · Right drag: firebreak
## Space: play/pause · N: one step · [ / ]: slower/faster · Left/Right: turn wind · Up/Down: wind speed · H/J: humidity -/+
## W: back to recorded weather · V: fuel map / aerial view · O: observed detections on/off
## R: reset fire · T: new test terrain · Esc/B: go back
extends Node2D

const FireSim = preload("res://sim/fire_sim.gd")
const SimRegion = preload("res://data/sim_region.gd")
const RegionLoader = preload("res://sim/region_loader.gd")
const HotspotData = preload("res://data/hotspot_data.gd")

const PANEL_W := 330.0
const SPEEDS: Array[float] = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0]  # steps per second
const RETARDANT_RADIUS := 5.0
const FIREBREAK_WIDTH := 2

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
const OBSERVED_COLOR := Color(0.55, 0.8, 1.0, 0.55)  # detections after the seed day

var sim: FireSim = FireSim.new()
var image: Image
var texture: ImageTexture
var shade := PackedFloat32Array()
var sprite := Sprite2D.new()
var hud := Label.new()
var cell_px := 4.0  # screen pixels per cell
var playing := false
var speed_index := 3  # 8 steps per second
var step_timer := 0.0
var terrain_seed := 1
var break_start := Vector2i(-1, -1)

# Real region (null on test terrain).
var region
var hs: HotspotData
var seeds := PackedInt32Array()  # indices into hs: detections on the seed day inside the grid
var loading := false
var load_text := ""
var manual_weather := false      # true once the user changes wind or humidity by hand
var weather_hour := -1           # index of the hour of weather now applied
var show_satellite := false
var bg_sprite := Sprite2D.new()
var obs_sprite := Sprite2D.new()
var obs_image: Image
var obs_texture: ImageTexture
var observed_day := 0            # last day of year painted into the observed overlay
var observed_count := 0


func _ready() -> void:
	for s in [bg_sprite, sprite, obs_sprite]:
		s.centered = false
		add_child(s)
	bg_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	bg_sprite.visible = false
	hud.add_theme_font_size_override("font_size", 13)
	add_child(hud)
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
		bg_sprite.scale = Vector2.ONE * sim.cols * cell_px / region.background.get_width()
	obs_image = Image.create(sim.cols, sim.rows, false, Image.FORMAT_RGBA8)
	obs_texture = ImageTexture.create_from_image(obs_image)
	obs_sprite.texture = obs_texture
	obs_sprite.scale = Vector2(cell_px, cell_px)
	loading = false
	restart_region_fire()


## Fits the grid to the window (left of the text panel) and paints every cell.
func build_view() -> void:
	var view := get_viewport_rect().size
	cell_px = minf((view.x - PANEL_W) / sim.cols, view.y / sim.rows)
	compute_shade()
	image = Image.create(sim.cols, sim.rows, false, Image.FORMAT_RGBA8)
	for i in sim.rows * sim.cols:
		paint(i)
	texture = ImageTexture.create_from_image(image)
	sprite.texture = texture
	sprite.scale = Vector2(cell_px, cell_px)
	hud.position = Vector2(sim.cols * cell_px + 16, 8)


## Clears the fire, goes back to the recorded weather and re-seeds from the detections.
func restart_region_fire() -> void:
	sim.reset_fire()
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
	update_hud()
	queue_redraw()


func step_once() -> void:
	sim.step()
	repaint_changed()
	if region != null:
		apply_weather()
		update_observed()


# ---------- input ----------

func mouse_cell() -> Vector2i:
	var p := get_local_mouse_position() / cell_px
	return Vector2i(int(p.y), int(p.x))  # (row, col)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_ESCAPE, KEY_B]:
		get_tree().change_scene_to_file(AppState.return_scene)
		return
	if loading:
		return
	if event is InputEventMouseButton:
		var cell := mouse_cell()
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if event.shift_pressed:
				sim.apply_retardant(cell.x, cell.y, RETARDANT_RADIUS)
			else:
				sim.changed = PackedInt32Array()
				sim.ignite(cell.x, cell.y)
			repaint_changed()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				break_start = cell
			elif break_start.x >= 0:
				sim.add_firebreak(break_start.x, break_start.y, cell.x, cell.y, FIREBREAK_WIDTH)
				repaint_changed()
				break_start = Vector2i(-1, -1)
	elif event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				playing = not playing
			KEY_N:
				step_once()
			KEY_LEFT:
				manual_weather = true
				sim.set_wind(sim.wind_to_deg - 15.0, sim.wind_speed)
			KEY_RIGHT:
				manual_weather = true
				sim.set_wind(sim.wind_to_deg + 15.0, sim.wind_speed)
			KEY_UP:
				manual_weather = true
				sim.set_wind(sim.wind_to_deg, sim.wind_speed + 1.0)
			KEY_DOWN:
				manual_weather = true
				sim.set_wind(sim.wind_to_deg, sim.wind_speed - 1.0)
			KEY_H:
				manual_weather = true
				sim.set_moisture(sim.humidity_pct - 5.0, sim.temperature_c)
			KEY_J:
				manual_weather = true
				sim.set_moisture(sim.humidity_pct + 5.0, sim.temperature_c)
			KEY_W:
				if region != null and region.weather_ok:
					manual_weather = false
					weather_hour = -1
					apply_weather()
			KEY_V:
				if region != null and region.background != null:
					show_satellite = not show_satellite
					bg_sprite.visible = show_satellite
					repaint_all()
			KEY_O:
				obs_sprite.visible = not obs_sprite.visible
			KEY_R:
				if region != null:
					restart_region_fire()
				else:
					sim.reset_fire()
					repaint_all()
					playing = false
			KEY_BRACKETLEFT:
				speed_index = maxi(speed_index - 1, 0)
			KEY_BRACKETRIGHT:
				speed_index = mini(speed_index + 1, SPEEDS.size() - 1)
			KEY_T:
				if region == null:
					terrain_seed += 1
					new_terrain()


# ---------- text panel ----------

func update_hud() -> void:
	if loading:
		hud.position = Vector2(24, 20)
		hud.text = "Loading the real area for %s, %s\n\nFuel (LANDFIRE), terrain, hourly weather (ERA5)\nand an aerial image are fetched live.\n%s\n\nEsc / B: go back" % [
			region.label, region.seed_date(), load_text]
		return
	var fire_cells: int = sim.burnt_count + sim.burning.size()
	var area_ha: float = fire_cells * sim.cell_size_m * sim.cell_size_m / 10000.0
	var mins := int(sim.elapsed_minutes)
	var text := "SIMULATED (test terrain)\n" if region == null else region_text()
	text += "\nsim time +%dh %02dm  %s\nstep %d  (%.1f min/step, %.0f steps/s)\nfire area %.0f ha\nburning %d  burnt %d cells\nwind toward %.0f° @ %.1f m/s\nhumidity %.0f%%  temp %.0f °C\nfuel moisture %.1f%%%s\nhead spread ~%.1f km/h on flat shrub\n" % [
		mins / 60, mins % 60, "playing" if playing else "paused",
		sim.step_count, sim.step_minutes, SPEEDS[speed_index],
		area_ha, sim.burning.size(), sim.burnt_count,
		sim.wind_to_deg, sim.wind_speed,
		sim.humidity_pct, sim.temperature_c, sim.fuel_moisture_pct,
		"  (too damp to spread)" if sim.moisture_speed <= 0.0 else "",
		sim.ROS_FRACTION_OF_WIND * maxf(sim.wind_speed, sim.MIN_WIND_FOR_ROS) * 3.6 * sim.moisture_factor(sim.fuel_moisture_pct, sim.MX_BY_CLASS[3])]
	text += "\nLeft click   ignite\nShift+click  retardant\nRight drag   firebreak\nSpace        play/pause\nN            one step\n[ / ]        slower / faster\nLeft/Right   turn wind\nUp/Down      wind speed\nH / J        humidity - / +\nR            reset fire\n"
	if region == null:
		text += "T            new terrain\n"
	else:
		text += "W            recorded weather\nV            fuel map / aerial\nO            observed on/off\n"
	hud.text = text + "Esc / B      go back"


func region_text() -> String:
	var lf: int = SimRegion.landfire_year(region.year)
	var fuel_line := "uniform shrub (LANDFIRE unavailable)"
	if region.fuel_ok:
		fuel_line = "LANDFIRE %d FBFM40" % lf
		if lf >= region.year:
			fuel_line += "\n  (mapped after this fire: old burn\n  scars can show as light fuel)"
	var weather_line := "unavailable, set by hand"
	if region.weather_ok:
		weather_line = "changed by hand (W: recorded)" if manual_weather else "ERA5 hourly (modelled)"
	var seed_line := "No detections here that day:\nleft click to start a fire."
	if not seeds.is_empty():
		seed_line = "Started from %d observed detections\n(MODIS + VIIRS) on %s" % [seeds.size(), region.seed_date()]
	return "SIMULATED what-if, not a prediction\n%s\n%s\nclock %s\ngrid %d x %d cells of %.0f m (%.0f km)\n\nfuel: %s\nterrain: %s\nweather: %s\nlight blue: observed detections on\n  later days (%d so far)\n" % [
		region.label, seed_line, clock_text(),
		sim.rows, sim.cols, sim.cell_size_m, sim.cols * sim.cell_size_m / 1000.0,
		fuel_line, "elevation tiles (Terrarium)" if region.elevation_ok else "flat (elevation unavailable)",
		weather_line, observed_count]


func _draw() -> void:
	if loading:
		return
	# Wind arrow, pointing where the wind blows toward.
	var view := get_viewport_rect().size
	var center := Vector2(view.x - 60, view.y - 60)
	var dir := Vector2(sin(deg_to_rad(sim.wind_to_deg)), -cos(deg_to_rad(sim.wind_to_deg)))
	var length := 20.0 + sim.wind_speed * 6.0
	draw_circle(center, 50, Color(1, 1, 1, 0.08))
	draw_line(center - dir * length * 0.5, center + dir * length * 0.5, Color.WHITE, 3.0)
	draw_line(center + dir * length * 0.5, center + dir * length * 0.5 - dir.rotated(0.5) * 12, Color.WHITE, 3.0)
	draw_line(center + dir * length * 0.5, center + dir * length * 0.5 - dir.rotated(-0.5) * 12, Color.WHITE, 3.0)
	# Firebreak preview while right-dragging.
	if break_start.x >= 0:
		var a := Vector2(break_start.y, break_start.x) * cell_px
		draw_line(a, get_local_mouse_position(), Color(1, 1, 1, 0.7), FIREBREAK_WIDTH * cell_px)
