## Headless checks for fire_sim.gd: godot --headless --path app -s test_fire_sim.gd
extends SceneTree

const FireSim = preload("res://sim/fire_sim.gd")

var failures := 0


func _init() -> void:
	test_no_fuel_does_not_burn()
	test_firebreak_stops_fire()
	test_wind_pushes_fire_downwind()
	test_uphill_spreads_faster()
	test_retardant_slows_fire()
	test_wind_from_conversion()
	test_same_seed_same_fire()
	test_no_wind_fire_is_round()
	test_wind_stretches_fire()
	test_step_time_follows_wind()
	test_moisture_values()
	test_damp_air_slows_fire()
	test_too_damp_no_spread()
	print("FAILED: %d" % failures if failures > 0 else "all tests passed")
	quit(1 if failures > 0 else 0)


func check(cond: bool, name: String) -> void:
	if cond:
		print("  ok   " + name)
	else:
		print("  FAIL " + name)
		failures += 1


func flat_sim(n: int = 60):
	var sim = FireSim.new()
	sim.setup(n, n, 150.0)
	sim.fuel.fill(1)
	sim.finish_terrain()
	sim.p_h = 1.0  # certain spread (grass gives p = 1.3)
	return sim


func run(sim) -> void:
	while not sim.is_done():
		sim.step()


func touched(sim) -> int:
	var n := 0
	for s in sim.state:
		if s == FireSim.BURNING or s == FireSim.BURNT:
			n += 1
	return n


func reach(sim, r0: int, c0: int, dr: int, dc: int) -> int:
	var far := 0
	var k := 1
	while sim.in_bounds(r0 + dr * k, c0 + dc * k):
		var s: int = sim.state[sim.index(r0 + dr * k, c0 + dc * k)]
		if s == FireSim.BURNING or s == FireSim.BURNT:
			far = k
		k += 1
	return far


func test_no_fuel_does_not_burn() -> void:
	var sim = flat_sim()
	sim.fuel[sim.index(30, 31)] = 0
	sim.finish_terrain()
	sim.ignite(30, 30)
	run(sim)
	check(sim.state[sim.index(30, 31)] == FireSim.NO_FUEL, "no-fuel cell never burns")


func test_firebreak_stops_fire() -> void:
	var sim = flat_sim()
	sim.add_firebreak(0, 40, 59, 40, 2)
	sim.ignite(30, 10)
	run(sim)
	var east_burnt := 0
	for r in 60:
		for c in range(42, 60):
			if sim.state[sim.index(r, c)] == FireSim.BURNT:
				east_burnt += 1
	check(east_burnt == 0, "full-height firebreak stops the fire")


func test_wind_pushes_fire_downwind() -> void:
	var east := 0
	var west := 0
	for s in 20:
		var sim = FireSim.new()
		sim.setup(60, 60, 150.0)
		sim.finish_terrain()
		sim.set_wind(90.0, 8.0)  # blowing toward east
		sim.rng.seed = s
		sim.ignite(30, 30)
		for i in 40:
			sim.step()
		for r in 60:
			for c in 60:
				if sim.state[sim.index(r, c)] != FireSim.UNBURNT:
					if c > 30:
						east += 1
					elif c < 30:
						west += 1
	check(east > west * 2, "east wind pushes fire east (east %d, west %d)" % [east, west])


func test_uphill_spreads_faster() -> void:
	var north := 0
	var south := 0
	for s in 20:
		var sim = FireSim.new()
		sim.setup(60, 60, 150.0)
		for r in 60:
			for c in 60:
				sim.elevation[sim.index(r, c)] = (60 - r) * 30.0  # rises toward north
		sim.finish_terrain()
		sim.rng.seed = s
		sim.ignite(30, 30)
		for i in 40:
			sim.step()
		for r in 60:
			for c in 60:
				if sim.state[sim.index(r, c)] != FireSim.UNBURNT:
					if r < 30:
						north += 1
					elif r > 30:
						south += 1
	check(north > south, "fire runs uphill (north %d, south %d)" % [north, south])


func test_retardant_slows_fire() -> void:
	var with_ret := 0
	var without := 0
	for s in 10:
		for use_ret in [false, true]:
			var sim = FireSim.new()
			sim.setup(60, 60, 150.0)
			sim.finish_terrain()
			if use_ret:
				sim.apply_retardant(30, 30, 10.0)
			sim.rng.seed = s
			sim.ignite(30, 30)
			for i in 40:
				sim.step()
			if use_ret:
				with_ret += touched(sim)
			else:
				without += touched(sim)
	check(with_ret < without / 2, "retardant slows spread (%d vs %d burnt)" % [with_ret, without])


func test_wind_from_conversion() -> void:
	var sim = FireSim.new()
	sim.setup(4, 4, 150.0)
	sim.set_wind_from(270.0, 5.0)  # wind from the west blows toward east
	check(is_equal_approx(sim.wind_to_deg, 90.0), "wind from 270 blows toward 90")


func test_same_seed_same_fire() -> void:
	var a = FireSim.new()
	var b = FireSim.new()
	for sim in [a, b]:
		sim.make_test_terrain(3, 80, 80)
		sim.set_wind(45.0, 5.0)
		sim.rng.seed = 42
		sim.ignite(40, 40)
		run(sim)
	check(a.state == b.state, "same seed gives the same fire")


func test_no_wind_fire_is_round() -> void:
	var ratio := 0.0
	for s in 6:
		var sim = FireSim.new()
		sim.setup(161, 161, 150.0)
		sim.fuel.fill(3)
		sim.finish_terrain()
		sim.rng.seed = s
		sim.ignite(80, 80)
		while reach(sim, 80, 80, 0, 1) < 50 and not sim.is_done():
			sim.step()
		var axial := (reach(sim, 80, 80, 0, 1) + reach(sim, 80, 80, 0, -1) + reach(sim, 80, 80, 1, 0) + reach(sim, 80, 80, -1, 0)) / 4.0
		var diag := (reach(sim, 80, 80, 1, 1) + reach(sim, 80, 80, 1, -1) + reach(sim, 80, 80, -1, 1) + reach(sim, 80, 80, -1, -1)) * 1.41421 / 4.0
		ratio += diag / axial / 6.0
	check(absf(ratio - 1.0) < 0.08, "no-wind fire is round (diagonal/axial %.2f, square would be 1.41)" % ratio)


func test_wind_stretches_fire() -> void:
	var lb := 0.0
	for s in 6:
		var sim = FireSim.new()
		sim.setup(201, 201, 150.0)
		sim.fuel.fill(3)
		sim.finish_terrain()
		sim.set_wind(90.0, 5.0)
		sim.rng.seed = s
		sim.ignite(100, 100)
		while reach(sim, 100, 100, 0, 1) < 60 and not sim.is_done():
			sim.step()
		var length := reach(sim, 100, 100, 0, 1) + reach(sim, 100, 100, 0, -1)
		var breadth := reach(sim, 100, 100, 1, 0) + reach(sim, 100, 100, -1, 0)
		lb += float(length) / breadth / 6.0
	var target: float = FireSim.length_to_breadth(5.0)
	check(absf(lb - target) / target < 0.2, "5 m/s fire length/breadth %.2f near target %.2f" % [lb, target])


func test_step_time_follows_wind() -> void:
	var sim = FireSim.new()
	sim.setup(4, 4, 150.0)
	var slow: float = sim.minutes_per_step(3.0)
	var fast: float = sim.minutes_per_step(10.0)
	# Head ROS = cells/step * cell size / minutes per step, should be ~10% of wind.
	var ros10: float = (sim.HEAD_CPS_0 + sim.HEAD_CPS_PER_MS * 10.0) * 150.0 / (fast * 60.0)
	check(fast < slow, "stronger wind means shorter steps (%.2f vs %.2f min)" % [fast, slow])
	check(is_equal_approx(snappedf(ros10, 0.001), 1.0), "head ROS at 10 m/s is 1.0 m/s (10%% rule): %.3f" % ros10)


func test_moisture_values() -> void:
	# Simard (1968) EMC, 10-50% branch: 2.22749 + 0.160107*30 - 0.014784*77 = 5.89
	var emc: float = FireSim.emc_pct(30.0, 25.0)
	check(absf(emc - 5.890) < 0.01, "EMC at 30%% RH, 25 C is 5.89%% (%.3f)" % emc)
	check(is_equal_approx(FireSim.moisture_factor(FireSim.M_REF, 15.0), 1.0), "moisture factor is 1 at the reference moisture")
	check(FireSim.moisture_factor(15.0, 15.0) == 0.0, "moisture factor is 0 at moisture of extinction")
	check(FireSim.moisture_factor(10.0, 15.0) < FireSim.moisture_factor(4.0, 15.0), "wetter fuel spreads slower")


func test_damp_air_slows_fire() -> void:
	var dry := 0
	var damp := 0
	var dry_minutes := 0.0
	var damp_minutes := 0.0
	for s in 10:
		for wet in [false, true]:
			var sim = FireSim.new()
			sim.setup(60, 60, 150.0)
			sim.fuel.fill(3)
			sim.finish_terrain()
			sim.set_wind(90.0, 5.0)
			sim.set_moisture(60.0 if wet else 20.0, 25.0)
			sim.rng.seed = s
			sim.ignite(30, 30)
			# Same real time for both: 3 hours.
			while sim.elapsed_minutes < 180.0 and not sim.is_done():
				sim.step()
			if wet:
				damp += touched(sim)
				damp_minutes = sim.step_minutes
			else:
				dry += touched(sim)
				dry_minutes = sim.step_minutes
	check(damp < dry / 2, "damp air (60%% RH) burns much less than dry (20%% RH) in 3 h: %d vs %d cells" % [damp, dry])
	check(damp_minutes > dry_minutes, "damp air stretches the step time (%.1f vs %.1f min)" % [damp_minutes, dry_minutes])


func test_too_damp_no_spread() -> void:
	var sim = FireSim.new()
	sim.setup(40, 40, 150.0)
	sim.fuel.fill(3)  # shrub, Mx 15%
	sim.finish_terrain()
	sim.set_moisture(95.0, 10.0)
	sim.ignite(20, 20)
	run(sim)
	check(touched(sim) == 1, "shrub doesn't spread at 95%% RH (fuel moisture %.0f%%)" % sim.fuel_moisture_pct)
