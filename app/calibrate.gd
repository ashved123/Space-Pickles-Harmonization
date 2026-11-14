## Measures fire shape and speed on flat, uniform shrub and compares to targets.
## godot --headless --path app -s calibrate.gd [-- "p_h,wind_gain,shape_k,diag,burn_steps;..."]
##
## Targets (see docs/fire_sim_calibration.md):
##   L/B  = 1 + 0.25 * U_mid(mi/h), U_mid = 0.4 * U10 / 1.15   (Andrews 2018; Andrews 2012)
##   head ROS proportional to U10                                (Cruz & Alexander 2019, 10% rule)
##   no-wind fire round: diagonal reach / axial reach = 1.0
extends SceneTree

const FireSim = preload("res://sim/fire_sim.gd")
const N := 301
const SEEDS := 10
const FUEL := 3  # shrub
const WINDS := [0.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0]
const REF_WIND := 5.0
const MPS_TO_MPH := 2.23694


static func target_lb(u10: float) -> float:
	return FireSim.length_to_breadth(u10)


func _init() -> void:
	var sets: Array = ["0.1,0.3,1.0,0.7071,16"]
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		sets = Array(args[0].split(";"))
	for s in sets:
		var v: Array = Array(s.split(",")).map(func(x): return float(x))
		run_set(v[0], v[1], v[2], v[3], int(v[4]))
	quit()


func run_set(p_h: float, c1: float, c2: float, diag: float, burn: int) -> void:
	print("\np_h %.3f  wind_gain %.3f  shape_k %.2f  diag %.3f  burn_steps %d" % [p_h, c1, c2, diag, burn])
	print("wind  head c/step  ROS/ROS5 (target)  L/B (target)  round  survived")
	var rows := []
	for w in WINDS:
		rows.append(measure(p_h, c1, c2, diag, burn, w))
	var ref: float = rows[WINDS.find(REF_WIND)].head
	for k in WINDS.size():
		var m: Dictionary = rows[k]
		var w: float = WINDS[k]
		print("%4.1f  %6.3f      %5.2f (%4.2f)        %5.2f (%4.2f)   %4.2f   %d/%d" % [
			w, m.head, m.head / ref, w / REF_WIND, m.lb, target_lb(w), m.round, m.survived, SEEDS])


func measure(p_h: float, c1: float, c2: float, diag: float, burn: int, wind: float) -> Dictionary:
	var head := 0.0
	var back := 0.0
	var flank := 0.0
	var diag_reach := 0.0
	var axial := 0.0
	var survived := 0
	var c := N / 2
	for s in SEEDS:
		var sim = FireSim.new()
		sim.p_h = p_h
		sim.wind_gain = c1
		sim.shape_k = c2
		sim.diag_factor = diag
		sim.burn_steps = burn
		sim.setup(N, N, 150.0)
		sim.fuel.fill(FUEL)
		sim.finish_terrain()
		sim.set_wind(90.0, wind)  # toward east
		sim.rng.seed = s
		sim.ignite(c, c)
		# Run until the head is 60% of the way to the edge (or the fire dies).
		var limit := int(c * 0.6)
		while not sim.is_done() and reach(sim, c, 0, 1) < limit and sim.step_count < 3000:
			sim.step()
		if sim.is_done():
			continue
		survived += 1
		var steps: float = sim.step_count
		var e := reach(sim, c, 0, 1)
		var w := reach(sim, c, 0, -1)
		var n := reach(sim, c, -1, 0)
		var so := reach(sim, c, 1, 0)
		head += e / steps
		back += w / steps
		flank += (n + so) * 0.5 / steps
		axial += (e + w + n + so) / 4.0
		diag_reach += (reach(sim, c, -1, 1) + reach(sim, c, 1, 1) + reach(sim, c, 1, -1) + reach(sim, c, -1, -1)) * 1.41421 / 4.0
	var k := maxf(survived, 1)
	head /= k
	back /= k
	flank /= k
	return {
		"head": head,
		"lb": (head + back) / maxf(2.0 * flank, 0.0001),
		"round": diag_reach / maxf(axial, 0.0001),
		"survived": survived,
	}


## Distance in cells to the farthest burnt/burning cell along a ray from the centre.
func reach(sim, c: int, dr: int, dc: int) -> float:
	var far := 0
	for k in range(1, N / 2):
		var r := c + dr * k
		var col := c + dc * k
		if sim.state[sim.index(r, col)] >= FireSim.BURNING:
			far = k
	return far
