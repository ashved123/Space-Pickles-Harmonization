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
		for i in 15:
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
		for i in 15:
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
			for i in 10:
				sim.step()
			if use_ret:
				with_ret += sim.burnt_count
			else:
				without += sim.burnt_count
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
