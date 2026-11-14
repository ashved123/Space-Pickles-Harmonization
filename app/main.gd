## Prototype top-down view of the fire sim.
## Left click: ignite · Shift+left click: retardant · Right drag: firebreak
## Space: play/pause · N: one step · Left/Right: turn wind · Up/Down: wind speed
## R: reset fire · T: new test terrain
extends Node2D

const FireSim = preload("res://sim/fire_sim.gd")

const SCALE := 4
const STEPS_PER_SEC := 12.0
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

var sim: FireSim = FireSim.new()
var image: Image
var texture: ImageTexture
var shade := PackedFloat32Array()
var sprite := Sprite2D.new()
var hud := Label.new()
var playing := false
var step_timer := 0.0
var terrain_seed := 1
var break_start := Vector2i(-1, -1)


func _ready() -> void:
	sprite.centered = false
	sprite.scale = Vector2(SCALE, SCALE)
	add_child(sprite)
	add_child(hud)
	new_terrain()


func new_terrain() -> void:
	sim.make_test_terrain(terrain_seed)
	sim.set_wind(45.0, 5.0)
	compute_shade()
	image = Image.create(sim.cols, sim.rows, false, Image.FORMAT_RGBA8)
	for i in sim.rows * sim.cols:
		paint(i)
	texture = ImageTexture.create_from_image(image)
	sprite.texture = texture
	hud.position = Vector2(sim.cols * SCALE + 20, 10)
	playing = false


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


func paint(i: int) -> void:
	var col: Color
	match sim.state[i]:
		FireSim.BURNING:
			col = FIRE_COLOR
		FireSim.BURNT:
			col = BURNT_COLOR
		_:
			col = FUEL_COLORS[sim.fuel[i]] * shade[i]
			if sim.retardant[i] < 1.0:
				col = col.lerp(RETARDANT_COLOR, 0.45)
	col.a = 1.0
	image.set_pixel(i % sim.cols, i / sim.cols, col)


func repaint_changed() -> void:
	for i in sim.changed:
		paint(i)
	texture.update(image)


func _process(delta: float) -> void:
	if playing:
		step_timer += delta
		while step_timer >= 1.0 / STEPS_PER_SEC:
			step_timer -= 1.0 / STEPS_PER_SEC
			sim.step()
			repaint_changed()
			if sim.is_done():
				playing = false
				break
	update_hud()
	queue_redraw()


func mouse_cell() -> Vector2i:
	var p := get_local_mouse_position() / SCALE
	return Vector2i(int(p.y), int(p.x))  # (row, col)


func _unhandled_input(event: InputEvent) -> void:
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
				sim.step()
				repaint_changed()
			KEY_LEFT:
				sim.set_wind(sim.wind_to_deg - 15.0, sim.wind_speed)
			KEY_RIGHT:
				sim.set_wind(sim.wind_to_deg + 15.0, sim.wind_speed)
			KEY_UP:
				sim.set_wind(sim.wind_to_deg, sim.wind_speed + 1.0)
			KEY_DOWN:
				sim.set_wind(sim.wind_to_deg, sim.wind_speed - 1.0)
			KEY_R:
				sim.reset_fire()
				for i in sim.rows * sim.cols:
					paint(i)
				texture.update(image)
				playing = false
			KEY_T:
				terrain_seed += 1
				new_terrain()


func update_hud() -> void:
	var area_ha: float = sim.burnt_count * sim.cell_size_m * sim.cell_size_m / 10000.0
	hud.text = "SIMULATED (test terrain)\n\nstep %d  %s\nburning %d\nburnt %d cells (%.0f ha)\nwind toward %.0f° @ %.0f m/s\n\n" % [
		sim.step_count, "playing" if playing else "paused", sim.burning.size(),
		sim.burnt_count, area_ha, sim.wind_to_deg, sim.wind_speed]
	hud.text += "Left click   ignite\nShift+click  retardant\nRight drag   firebreak\nSpace        play/pause\nN            one step\nLeft/Right   turn wind\nUp/Down      wind speed\nR            reset fire\nT            new terrain"


func _draw() -> void:
	# Wind arrow, pointing where the wind blows toward.
	var center := Vector2(sim.cols * SCALE + 90, 330)
	var dir := Vector2(sin(deg_to_rad(sim.wind_to_deg)), -cos(deg_to_rad(sim.wind_to_deg)))
	var length := 20.0 + sim.wind_speed * 6.0
	draw_circle(center, 50, Color(1, 1, 1, 0.08))
	draw_line(center - dir * length * 0.5, center + dir * length * 0.5, Color.WHITE, 3.0)
	draw_line(center + dir * length * 0.5, center + dir * length * 0.5 - dir.rotated(0.5) * 12, Color.WHITE, 3.0)
	draw_line(center + dir * length * 0.5, center + dir * length * 0.5 - dir.rotated(-0.5) * 12, Color.WHITE, 3.0)
	# Firebreak preview while right-dragging.
	if break_start.x >= 0:
		var a := Vector2(break_start.y, break_start.x) * SCALE
		draw_line(a, get_local_mouse_position(), Color(1, 1, 1, 0.7), FIREBREAK_WIDTH * SCALE)
