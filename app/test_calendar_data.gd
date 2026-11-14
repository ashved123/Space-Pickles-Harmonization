## Headless checks for data/calendar_data.gd: godot --headless --path app -s test_calendar_data.gd
extends SceneTree

const CalendarData = preload("res://data/calendar_data.gd")

var failures := 0


func _init() -> void:
	var d = CalendarData.new()
	check(d.load_all(), "datasets load")
	var all: PackedInt32Array = d.all_cells()
	check(d.cell_count() > 600, "%d cells" % d.cell_count())
	check(is_nan(d.area_value(all, 2000, 6)), "June 2000 has no record (NAN, not 0)")
	check(d.has_data(2000, 11), "Nov 2000 has a record")
	var aug2020: float = d.area_value(all, 2020, 8)
	var feb2020: float = d.area_value(all, 2020, 2)
	check(aug2020 > feb2020 * 3.0, "Aug 2020 (%.0f) far above Feb 2020 (%.0f)" % [aug2020, feb2020])
	var grid: Array = d.area_grid(all)
	var unusual: PackedFloat32Array = d.unusual_thresholds(grid)
	check(aug2020 >= unusual[7], "Aug 2020 is flagged unusual (threshold %.0f)" % unusual[7])
	check(d.kinds[d.month_index(2005, 7)] == "harmonized", "2005 is harmonized (MODIS converted)")
	check(d.kinds[d.month_index(2018, 7)] == "observed", "2018 is observed (VIIRS S-NPP)")
	# Camp Fire: Butte County box, November 2018.
	var butte: PackedInt32Array = d.cells_in_box(39.5, -122.0, 40.1, -121.2)
	var names := d.fires_in(butte, 2018, 11).map(func(f): return f.id)
	check(names.has("CA-20181108-0021"), "Camp Fire listed for Butte, Nov 2018 %s" % [names])
	var o: PackedFloat32Array = d.outlook_area(all)
	check(o[8] > o[2], "outlook: September above March (%.1f vs %.1f)" % [o[8], o[2]])
	print("FAILED: %d" % failures if failures > 0 else "all tests passed")
	quit(1 if failures > 0 else 0)


func check(cond: bool, name: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + name)
	if not cond:
		failures += 1
