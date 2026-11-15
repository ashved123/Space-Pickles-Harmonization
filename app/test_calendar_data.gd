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
	var s: Dictionary = d.outlook_summary(9)
	check(absf(s.expected - o[8]) < 0.01 and s.high > 0 and s.medium > s.high, "outlook summary: Sept %.1f cells expected, %d high, %d medium" % [s.expected, s.high, s.medium])
	check(d.outlook_summary(0).high >= s.high, "peak-month summary has at least as many High cells")
	test_date_queries()
	test_sensor_counts(d, butte)
	print("FAILED: %d" % failures if failures > 0 else "all tests passed")
	quit(1 if failures > 0 else 0)


## Raw detections per satellite, counted from the hotspot files.
func test_sensor_counts(d, butte: PackedInt32Array) -> void:
	check(not d.sensor_ready(), "satellite counts start empty")
	var t := Time.get_ticks_msec()
	for y in range(d.FIRST_YEAR, d.last_year + 1):
		d.count_sensor_year(y)
	check(d.sensor_ready(), "all years counted in %d ms" % (Time.get_ticks_msec() - t))
	var all: PackedInt32Array = d.all_cells()
	var modis: Array = d.sensor_area_grid(0, all)
	var snpp: Array = d.sensor_area_grid(1, all)
	var noaa20: Array = d.sensor_area_grid(2, all)
	check(modis[5][7] > 0.0 and is_nan(snpp[5][7]) and is_nan(noaa20[5][7]), "Aug 2005: MODIS only (%d detections)" % modis[5][7])
	check(snpp[13][7] > 0.0 and is_nan(noaa20[13][7]), "Aug 2013: S-NPP on record, NOAA-20 not yet")
	check(noaa20[20][7] > 0.0 and snpp[20][7] > modis[20][7], "Aug 2020: all three, VIIRS sees more than MODIS (%d vs %d)" % [snpp[20][7], modis[20][7]])
	var camp: Array = d.sensor_area_grid(1, butte)
	check(camp[18][10] > 1000.0 and camp[18][10] > camp[18][5] * 10.0, "Camp Fire: Butte S-NPP detections spike in Nov 2018 (%d)" % camp[18][10])
	var total := 0.0
	for c in butte:
		total += d.sensor_cell_value(1, c, 2018, 11)
	check(is_equal_approx(total, camp[18][10]), "cell values add up to the area total")
	var index = JSON.parse_string(FileAccess.get_file_as_string("res://datasets/hotspots/index.json"))
	var year_total := 0.0
	for g in [modis, snpp, noaa20]:
		for v in g[18]:
			if not is_nan(v):
				year_total += v
	check(absf(year_total - index.years["2018"]) <= index.years["2018"] * 0.01, "2018 counts match the hotspot file (%d of %d)" % [year_total, index.years["2018"]])


func test_date_queries() -> void:
	var cases := {
		"2031": [2031, 0, 0], "2031-09": [2031, 9, 0], "9/2031": [2031, 9, 0], "Sep 2031": [2031, 9, 0],
		"september": [0, 9, 0], "Sept. 2030": [2030, 9, 0], "2031-09-15": [2031, 9, 15],
		"9/15/2031": [2031, 9, 15], "15/9/2031": [2031, 9, 15], "15 Sep 2031": [2031, 9, 15],
		"September 15th, 2031": [2031, 9, 15], "  2028-02-29 ": [2028, 2, 29], "feb 29": [0, 2, 29],
	}
	var ok := true
	for text in cases:
		var q: Dictionary = CalendarData.parse_date_query(text)
		var want: Array = cases[text]
		if q.is_empty() or q.year != want[0] or q.month != want[1] or q.day != want[2]:
			print("       wrong: '%s' -> %s" % [text, q])
			ok = false
	check(ok, "typed dates are read (%d forms)" % cases.size())
	var bad := true
	for text in ["", "soon", "13/2031", "2027-02-30", "2031 2032", "0/2031", "15", "1 2 3 2031", "mar apr 2030"]:
		if not CalendarData.parse_date_query(text).is_empty():
			print("       should be rejected: '%s'" % text)
			bad = false
	check(bad, "unreadable dates are rejected")


func check(cond: bool, name: String) -> void:
	print(("  ok   " if cond else "  FAIL ") + name)
	if not cond:
		failures += 1
