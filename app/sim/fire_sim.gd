## 2D cellular-automaton fire spread (Alexandridis et al. 2008).
## Pure logic: no nodes, no rendering, so it runs headless.
##
## p_burn = p_h * (1 + p_veg) * (1 + p_den) * p_wind * p_slope * retardant
## Grid: row 0 = north edge, col 0 = west edge. Index = row * cols + col.
extends RefCounted

const NO_FUEL := 0
const UNBURNT := 1
const BURNING := 2
const BURNT := 3

# p_veg per fuel class index (see CLAUDE.md data contract).
const P_VEG: Array[float] = [-1.0, 0.3, 0.35, 0.4, 0.2, 0.0, 0.4]

# 8 neighbours as (d_row, d_col). Row grows southward.
const DIRS := [
	Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
	Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, -1),
]

# Tuning constants (starting values from the paper).
var p_h := 0.58
var c1 := 0.045
var c2 := 0.131
var a := 0.078

var rows := 0
var cols := 0
var cell_size_m := 150.0

# Cell data. Interventions edit these; they add no new physics.
var fuel := PackedByteArray()          # fuel class index 0-6
var elevation := PackedFloat32Array()  # metres
var density := PackedFloat32Array()    # p_den per cell (-0.4 sparse, 0 normal, 0.3 dense)
var retardant := PackedFloat32Array()  # burn-probability multiplier, 1.0 = none

# Fire state.
var state := PackedByteArray()
var burning := PackedInt32Array()  # the active front
var changed := PackedInt32Array()  # cells whose state changed in the last call
var step_count := 0
var burnt_count := 0

# Wind: direction the wind blows TOWARD (0 = N, 90 = E), speed in m/s.
var wind_to_deg := 0.0
var wind_speed := 0.0

var rng := RandomNumberGenerator.new()

var _p_wind := PackedFloat32Array()   # one factor per direction
var _p_slope := PackedFloat32Array()  # cells * 8, factor for spreading from cell in direction k


func setup(p_rows: int, p_cols: int, p_cell_size_m: float) -> void:
	rows = p_rows
	cols = p_cols
	cell_size_m = p_cell_size_m
	var n := rows * cols
	fuel.resize(n)
	fuel.fill(1)
	elevation.resize(n)
	elevation.fill(0.0)
	density.resize(n)
	density.fill(0.0)
	retardant.resize(n)
	retardant.fill(1.0)
	state.resize(n)
	set_wind(0.0, 0.0)


## Call after filling fuel/elevation/density. Precomputes slope factors and resets the fire.
func finish_terrain() -> void:
	_compute_slope_factors()
	reset_fire()


## Clears the fire but keeps terrain and interventions.
func reset_fire() -> void:
	for i in state.size():
		state[i] = NO_FUEL if fuel[i] == 0 else UNBURNT
	burning = PackedInt32Array()
	changed = PackedInt32Array()
	step_count = 0
	burnt_count = 0


func set_wind(to_deg: float, speed_ms: float) -> void:
	wind_to_deg = fposmod(to_deg, 360.0)
	wind_speed = maxf(speed_ms, 0.0)
	_p_wind.resize(DIRS.size())
	for k in DIRS.size():
		var theta := deg_to_rad(wind_to_deg - _bearing_deg(DIRS[k]))
		_p_wind[k] = exp(c1 * wind_speed) * exp(wind_speed * c2 * (cos(theta) - 1.0))


## Weather data reports where wind comes FROM; this converts it.
func set_wind_from(from_deg: float, speed_ms: float) -> void:
	set_wind(from_deg + 180.0, speed_ms)


func index(row: int, col: int) -> int:
	return row * cols + col


func in_bounds(row: int, col: int) -> bool:
	return row >= 0 and row < rows and col >= 0 and col < cols


func ignite(row: int, col: int) -> bool:
	if not in_bounds(row, col):
		return false
	var i := index(row, col)
	if state[i] != UNBURNT:
		return false
	state[i] = BURNING
	burning.append(i)
	changed.append(i)
	return true


## One time step: every burning cell may ignite each unburnt neighbour, then burns out.
## Returns the cells that changed (also kept in `changed`).
func step() -> PackedInt32Array:
	var next := PackedInt32Array()
	changed = PackedInt32Array()
	for i in burning:
		var r := i / cols
		var c := i % cols
		for k in DIRS.size():
			var nr: int = r + DIRS[k].x
			var nc: int = c + DIRS[k].y
			if nr < 0 or nr >= rows or nc < 0 or nc >= cols:
				continue
			var j := nr * cols + nc
			if state[j] != UNBURNT:
				continue
			var p: float = p_h * (1.0 + P_VEG[fuel[j]]) * (1.0 + density[j]) \
				* _p_wind[k] * _p_slope[i * 8 + k] * retardant[j]
			if rng.randf() < p:
				state[j] = BURNING
				next.append(j)
				changed.append(j)
		state[i] = BURNT
		changed.append(i)
		burnt_count += 1
	burning = next
	step_count += 1
	return changed


func is_done() -> bool:
	return burning.is_empty()


## Firebreak: a line of cells set to NO_FUEL. Burning cells are left alone.
func add_firebreak(r0: int, c0: int, r1: int, c1_: int, width_cells: int = 1) -> void:
	changed = PackedInt32Array()
	var steps := maxi(absi(r1 - r0), absi(c1_ - c0))
	var half := width_cells / 2
	for s in steps + 1:
		var t := 0.0 if steps == 0 else float(s) / steps
		var r := roundi(lerpf(r0, r1, t))
		var c := roundi(lerpf(c0, c1_, t))
		for dr in range(-half, width_cells - half):
			for dc in range(-half, width_cells - half):
				_clear_fuel(r + dr, c + dc)


## Retardant: multiplies the burn probability of cells within a radius.
func apply_retardant(row: int, col: int, radius_cells: float, factor: float = 0.2) -> void:
	changed = PackedInt32Array()
	var rad := ceili(radius_cells)
	for dr in range(-rad, rad + 1):
		for dc in range(-rad, rad + 1):
			if dr * dr + dc * dc > radius_cells * radius_cells:
				continue
			var r := row + dr
			var c := col + dc
			if not in_bounds(r, c):
				continue
			var i := index(r, c)
			retardant[i] = minf(retardant[i], factor)
			changed.append(i)


## Fake terrain for testing until real region files are loaded.
func make_test_terrain(seed_value: int = 1, p_rows: int = 200, p_cols: int = 200) -> void:
	setup(p_rows, p_cols, 150.0)
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.02
	var veg_noise := FastNoiseLite.new()
	veg_noise.seed = seed_value + 1
	veg_noise.frequency = 0.04
	for r in rows:
		for c in cols:
			var i := index(r, c)
			# A big hill north-east of centre plus rolling noise.
			var dx := (c - cols * 0.65) / cols
			var dy := (r - rows * 0.35) / rows
			elevation[i] = 600.0 * exp(-(dx * dx + dy * dy) * 8.0) + 80.0 * noise.get_noise_2d(c, r)
			# Fuel patches; a river and a lake with no fuel.
			var v := veg_noise.get_noise_2d(c, r)
			var cls := 1
			if v > 0.35:
				cls = 5
			elif v > 0.15:
				cls = 3
			elif v > -0.1:
				cls = 2
			elif v < -0.45:
				cls = 4
			var river := absf(c - (cols * 0.3 + 12.0 * sin(r * 0.05))) < 1.5
			var lx := (c - cols * 0.75) / 12.0
			var ly := (r - rows * 0.75) / 8.0
			if river or lx * lx + ly * ly < 1.0:
				cls = 0
			fuel[i] = cls
			density[i] = 0.3 if v > 0.4 else (-0.4 if v < -0.3 else 0.0)
	finish_terrain()


func _clear_fuel(row: int, col: int) -> void:
	if not in_bounds(row, col):
		return
	var i := index(row, col)
	if state[i] == BURNING:
		return
	fuel[i] = 0
	if state[i] == UNBURNT:
		state[i] = NO_FUEL
		changed.append(i)


func _compute_slope_factors() -> void:
	_p_slope.resize(rows * cols * 8)
	for r in rows:
		for c in cols:
			var i := index(r, c)
			for k in DIRS.size():
				var nr: int = r + DIRS[k].x
				var nc: int = c + DIRS[k].y
				var f := 1.0
				if in_bounds(nr, nc):
					var dist := cell_size_m * (1.4142135 if DIRS[k].x != 0 and DIRS[k].y != 0 else 1.0)
					var rise := elevation[index(nr, nc)] - elevation[i]
					f = exp(a * rad_to_deg(atan(rise / dist)))
				_p_slope[i * 8 + k] = f


## Compass bearing of a grid direction: 0 = N (row - 1), 90 = E (col + 1).
func _bearing_deg(d: Vector2i) -> float:
	return rad_to_deg(atan2(d.y, -d.x))
