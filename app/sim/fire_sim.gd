## 2D cellular-automaton fire spread (Alexandridis et al. 2008).
## Pure logic: no nodes, no rendering, so it runs headless.
##
## p_burn = p_h * (1 + p_veg) * (1 + p_den) * p_wind * p_slope * retardant
##
## Our changes to the paper (see docs/fire_sim_calibration.md):
## 1. Timing: a cell burns for `burn_steps` steps and tries to ignite each unburnt
##    neighbour on every one of them, with p_burn as the per-step chance. The paper
##    burns a cell for one step only, which pins the head to 1 cell/step and makes
##    fires square. Diagonal neighbours are scaled by `diag_factor` (farther away).
## 2. p_wind: the paper's exp form starves the flanks below the spread threshold
##    when the per-step chance is small. We use the elliptical fire shape instead
##    (Andrews 2018): p_wind = (1 + wind_gain*V) * (1 - e) / (1 - e*cos θ), with
##    e from the length-to-breadth ratio L/B = 1 + 0.25*U_mid (mi/h),
##    U_mid = 0.4 * V / 1.15 (Andrews 2012). θ = angle between wind and spread.
## 3. Real time per step depends on the wind (one wind value for the whole region),
##    so the head spreads at ~10% of the 10 m wind (Cruz & Alexander 2019) on the
##    reference fuel (shrub, flat). The probabilities set the shape; the step
##    length sets the speed.
## 4. Fuel moisture from humidity and temperature (one value for the whole region):
##    fine dead fuel moisture M = 1.03 * EMC(RH, T) (Simard 1968 via Ottmar &
##    Sandberg 1985; Bradshaw et al. 1984). Spread scales with Rothermel's
##    eta_M(M/Mx) / (250 + 1116*M) (Andrews 2018), relative to M_REF. Mx per fuel
##    class from Scott & Burgan 2005 (arid-climate models). The fastest fuel's
##    factor scales the step time; the others scale p_burn relative to it, and a
##    fuel at or above its Mx can't carry fire.
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

# Tuning constants. Paper values: p_h 0.58, a 0.078 (c1/c2 replaced, see above).
# p_h is now a per-step chance, so it is re-tuned (docs/fire_sim_calibration.md).
var p_h := 0.06
var a := 0.078
var wind_gain := 0.3       # head spread grows by this fraction per m/s of wind
var shape_k := 1.0         # >1 tightens the ellipse to offset spread via side paths
var diag_factor := 0.7071  # per-step chance multiplier for diagonal neighbours
var burn_steps := 24       # steps a cell keeps burning (and trying to spread)

# Time scale. Head speed in cells/step on flat shrub, measured by calibrate.gd for
# the constants above: HEAD_CPS_0 + HEAD_CPS_PER_MS * wind (fit, max error 0.011).
# Re-run calibrate.gd and update these if p_h, wind_gain, shape_k, diag_factor or
# burn_steps change.
const HEAD_CPS_0 := 0.3362
const HEAD_CPS_PER_MS := 0.01798
const ROS_FRACTION_OF_WIND := 0.1  # 10% rule (Cruz & Alexander 2019)
const MIN_WIND_FOR_ROS := 2.0      # m/s; below this the 10% rule is held at 2 m/s (assumption)

var step_minutes := 1.0    # real time per step at the current wind and moisture
var elapsed_minutes := 0.0

# Moisture. Defaults (RH 30%, 25 °C) give M ≈ 6%, the calibration reference.
# Dead fuel moisture of extinction (%) per fuel class, Scott & Burgan 2005
# arid/semiarid models (California): GR/GS/SH 15, TU 20, TL/SB 25.
const MX_BY_CLASS: Array[float] = [0.0, 15.0, 15.0, 15.0, 20.0, 25.0, 25.0]
const M_REF := 6.0  # % fine dead fuel moisture behind the 10% rule calibration (assumption)
var humidity_pct := 30.0
var temperature_c := 25.0
var fuel_moisture_pct := 6.0
var moisture_speed := 1.0  # fastest fuel's spread factor vs M_REF; 0 = too damp to spread
var _moist_mult := PackedFloat32Array([0, 1, 1, 1, 1, 1, 1])  # p_burn multiplier per fuel class

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
var burn_left := PackedByteArray()  # steps left for BURNING cells
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
	burn_left.resize(n)
	set_wind(0.0, 0.0)
	set_moisture(humidity_pct, temperature_c)


## Call after filling fuel/elevation/density. Precomputes slope factors and resets the fire.
func finish_terrain() -> void:
	_compute_slope_factors()
	reset_fire()


## Clears the fire but keeps terrain and interventions.
func reset_fire() -> void:
	for i in state.size():
		state[i] = NO_FUEL if fuel[i] == 0 else UNBURNT
	burn_left.fill(0)
	burning = PackedInt32Array()
	changed = PackedInt32Array()
	step_count = 0
	burnt_count = 0
	elapsed_minutes = 0.0


func set_wind(to_deg: float, speed_ms: float) -> void:
	wind_to_deg = fposmod(to_deg, 360.0)
	wind_speed = maxf(speed_ms, 0.0)
	_p_wind.resize(DIRS.size())
	var e := ellipse_eccentricity(wind_speed)
	_update_step_minutes()
	for k in DIRS.size():
		var theta := deg_to_rad(wind_to_deg - _bearing_deg(DIRS[k]))
		_p_wind[k] = (1.0 + wind_gain * wind_speed) * pow((1.0 - e) / (1.0 - e * cos(theta)), shape_k)
		if DIRS[k].x != 0 and DIRS[k].y != 0:
			_p_wind[k] *= diag_factor


## Humidity (%) and air temperature (°C) for the whole region.
func set_moisture(rh_pct: float, temp_c: float) -> void:
	humidity_pct = clampf(rh_pct, 0.0, 100.0)
	temperature_c = temp_c
	fuel_moisture_pct = fine_fuel_moisture_pct(humidity_pct, temperature_c)
	var factors := PackedFloat32Array()
	moisture_speed = 0.0
	for c in MX_BY_CLASS.size():
		var f := 0.0 if c == 0 else moisture_factor(fuel_moisture_pct, MX_BY_CLASS[c])
		factors.append(f)
		moisture_speed = maxf(moisture_speed, f)
	for c in factors.size():
		_moist_mult[c] = factors[c] / moisture_speed if moisture_speed > 0.0 else 0.0
	_update_step_minutes()


## Equilibrium moisture content (%) of fine fuels, Simard (1968), T in °F.
static func emc_pct(rh_pct: float, temp_c: float) -> float:
	var t := temp_c * 9.0 / 5.0 + 32.0
	var h := rh_pct
	if h < 10.0:
		return 0.03229 + 0.281073 * h - 0.000578 * h * t
	if h <= 50.0:
		return 2.22749 + 0.160107 * h - 0.014784 * t
	return 21.0606 + 0.005565 * h * h - 0.00035 * h * t - 0.483199 * h


## 1-hour dead fuel moisture (%) = 1.03 * EMC (Bradshaw et al. 1984, eq. 26).
static func fine_fuel_moisture_pct(rh_pct: float, temp_c: float) -> float:
	return maxf(1.03 * emc_pct(rh_pct, temp_c), 1.0)


## Rothermel moisture effect on spread rate, relative to M_REF. 0 at or above Mx.
static func moisture_factor(m_pct: float, mx_pct: float) -> float:
	return _rothermel_moisture(m_pct, mx_pct) / _rothermel_moisture(M_REF, mx_pct)


static func _rothermel_moisture(m_pct: float, mx_pct: float) -> float:
	if m_pct >= mx_pct:
		return 0.0
	var r := m_pct / mx_pct
	var eta := 1.0 - 2.59 * r + 5.11 * r * r - 3.52 * r * r * r
	return maxf(eta, 0.0) / (250.0 + 1116.0 * m_pct / 100.0)


func _update_step_minutes() -> void:
	# Damp fuel spreads slower: stretch the time a step stands for.
	step_minutes = minutes_per_step(wind_speed) / maxf(moisture_speed, 0.05)


## Real minutes per step so the head on flat shrub spreads at ~10% of the wind speed.
func minutes_per_step(wind_10m_ms: float) -> float:
	var head_cells_per_step := HEAD_CPS_0 + HEAD_CPS_PER_MS * wind_10m_ms
	var ros_ms := ROS_FRACTION_OF_WIND * maxf(wind_10m_ms, MIN_WIND_FOR_ROS)
	return head_cells_per_step * cell_size_m / ros_ms / 60.0


## Length-to-breadth of a wind-driven fire for a 10 m wind in m/s (Andrews 2018, 2012).
static func length_to_breadth(wind_10m_ms: float) -> float:
	var u_mid_mph := 0.4 * wind_10m_ms / 1.15 * 2.23694
	return 1.0 + 0.25 * u_mid_mph


static func ellipse_eccentricity(wind_10m_ms: float) -> float:
	var z := length_to_breadth(wind_10m_ms)
	return sqrt(z * z - 1.0) / z


## Weather data reports where wind comes FROM; this converts it.
func set_wind_from(from_deg: float, speed_ms: float) -> void:
	set_wind(from_deg + 180.0, speed_ms)


## One hour of weather as reported (wind FROM direction, 10 m speed m/s, RH %, °C).
func set_weather(wind_from_deg: float, wind_ms: float, rh_pct: float, temp_c: float) -> void:
	set_wind_from(wind_from_deg, wind_ms)
	set_moisture(rh_pct, temp_c)


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
	burn_left[i] = burn_steps
	burning.append(i)
	changed.append(i)
	return true


## One time step: every burning cell may ignite each unburnt neighbour.
## Cells burn out after `burn_steps` steps.
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
				* _p_wind[k] * _p_slope[i * 8 + k] * retardant[j] * _moist_mult[fuel[j]]
			if rng.randf() < p:
				state[j] = BURNING
				burn_left[j] = burn_steps
				next.append(j)
				changed.append(j)
		burn_left[i] -= 1
		if burn_left[i] > 0:
			next.append(i)
		else:
			state[i] = BURNT
			changed.append(i)
			burnt_count += 1
	burning = next
	step_count += 1
	elapsed_minutes += step_minutes
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
