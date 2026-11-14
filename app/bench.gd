## Headless benchmark: godot --headless --path app -s bench.gd
extends SceneTree

const FireSim = preload("res://sim/fire_sim.gd")
const RUNS := 5


func _init() -> void:
	var sim = FireSim.new()
	sim.make_test_terrain(1)
	sim.set_wind(45.0, 5.0)
	var worst_step := 0.0
	var total_ms := 0.0
	var total_steps := 0
	var total_burnt := 0
	for run in RUNS:
		sim.reset_fire()
		sim.rng.seed = run
		sim.ignite(sim.rows / 2, sim.cols / 2)
		var t_fire := Time.get_ticks_usec()
		while not sim.is_done():
			var t := Time.get_ticks_usec()
			sim.step()
			worst_step = maxf(worst_step, (Time.get_ticks_usec() - t) / 1000.0)
		total_ms += (Time.get_ticks_usec() - t_fire) / 1000.0
		total_steps += sim.step_count
		total_burnt += sim.burnt_count
	print("grid %dx%d, wind %.0f deg @ %.1f m/s, %d runs" % [sim.rows, sim.cols, sim.wind_to_deg, sim.wind_speed, RUNS])
	print("avg steps/fire %.0f, avg cells burnt %.0f" % [float(total_steps) / RUNS, float(total_burnt) / RUNS])
	print("worst step %.2f ms, avg full fire %.1f ms" % [worst_step, total_ms / RUNS])
	quit()
