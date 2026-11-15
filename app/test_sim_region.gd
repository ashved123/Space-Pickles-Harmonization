## Headless checks for data/sim_region.gd: godot --headless --path app -s test_sim_region.gd
## No network: images and the weather reply are built in memory.
extends SceneTree

const SimRegion = preload("res://data/sim_region.gd")
const Mercator = preload("res://map/mercator.gd")

var failures := 0


func _init() -> void:
	test_grid_size()
	test_cells_and_bbox()
	test_fire_request()
	test_dates()
	test_fuel_classes()
	test_fuel_image()
	test_elevation_tiles()
	test_weather()
	print("FAILED: %d" % failures if failures > 0 else "all tests passed")
	quit(1 if failures > 0 else 0)


func check(cond: bool, name: String) -> void:
	if cond:
		print("  ok   " + name)
	else:
		print("  FAIL " + name)
		failures += 1


func camp_fire():
	return SimRegion.from_request({"lat": 39.81, "lon": -121.44, "year": 2018, "doy": 312})


func test_grid_size() -> void:
	var r = camp_fire()
	check(r.rows == 400 and r.cols == 400 and is_equal_approx(r.cell_size_m, 150.0), "default grid is 400 x 400 at 150 m")
	var big = SimRegion.new()
	big.place(40.0, -123.0, 160000.0)
	check(big.rows == 512 and is_equal_approx(big.cell_size_m, 312.5), "a 160 km region keeps 512 cells and grows the cell")
	check(big.fuel.size() == 512 * 512 and big.elevation.size() == 512 * 512, "arrays match the grid")


func test_cells_and_bbox() -> void:
	var r = camp_fire()
	var mid: Vector2i = r.cell_of(Mercator.to_world(39.81, -121.44))
	check(absi(mid.x - 200) <= 1 and absi(mid.y - 200) <= 1, "centre maps to the middle cell")
	# 15 km north and 15 km east of the centre: 100 cells up, 100 cells right.
	var north: Vector2i = r.cell_of(Mercator.to_world(39.81 + 15000.0 / 111320.0, -121.44))
	check(absi(north.x - 100) <= 2 and absi(north.y - 200) <= 1, "north is toward row 0")
	var east: Vector2i = r.cell_of(Mercator.to_world(39.81, -121.44 + 15000.0 / (111320.0 * cos(deg_to_rad(39.81)))))
	check(absi(east.y - 300) <= 2 and absi(east.x - 200) <= 1, "east is toward higher columns")
	check(r.in_grid(Vector2i(0, 399)) and not r.in_grid(Vector2i(400, 0)) and not r.in_grid(Vector2i(-1, 5)), "in_grid bounds")
	var b: Array[float] = r.bbox_3857()
	# Web Mercator stretches ground distance by 1 / cos(lat).
	var want := 60000.0 / cos(deg_to_rad(39.81))
	check(absf((b[2] - b[0]) - want) < 200.0 and absf((b[3] - b[1]) - want) < 200.0, "bbox is 60 km on the ground")
	check(absf((b[0] + b[2]) / 2.0 - (-121.44 / 360.0 * Mercator.EARTH_CIRCUMFERENCE_M)) < 200.0, "bbox is centred on the longitude")


func test_fire_request() -> void:
	var f := {"id": "CA-TEST", "start": "2020-08-16", "bbox": [39.4, -123.5, 40.4, -122.4]}
	var req: Dictionary = SimRegion.request_for_fire(f)
	check(req.year == 2020 and req.doy == 229, "fire request starts on the fire's first day")
	check(absf(req.side_m - 111320.0 * 1.5) < 2000.0, "fire region is 1.5 x the bounding box")
	var small: Dictionary = SimRegion.request_for_fire({"id": "x", "start": "2019-01-01", "bbox": [38.0, -120.1, 38.1, -120.0]}, 2019, 40)
	check(is_equal_approx(small.side_m, 60000.0) and small.doy == 40, "small fires get the 60 km default and a given day")


func test_dates() -> void:
	check(SimRegion.day_of_year(2018, 11, 8) == 312, "day of year")
	check(SimRegion.date_string(2018, 312) == "2018-11-08", "date from day of year")
	check(SimRegion.date_string(2020, 366 + 2) == "2021-01-02", "days roll into the next year")


func test_fuel_classes() -> void:
	var ok := true
	var cases := {91: 0, 99: 0, 101: 1, 109: 1, 121: 2, 124: 2, 141: 3, 149: 3, 161: 4, 165: 4, 181: 5, 189: 5, 201: 6, 204: 6, 0: 0, 255: 0, 110: 0}
	for code in cases:
		ok = ok and SimRegion.fuel_class(code) == cases[code]
	check(ok, "FBFM40 codes map to the 7 classes")
	check(SimRegion.landfire_year(2018) == 2016 and SimRegion.landfire_year(2023) == 2022
		and SimRegion.landfire_year(2026) == 2025 and SimRegion.landfire_year(2012) == 2016, "LANDFIRE release from before the fire")


func test_fuel_image() -> void:
	var r = SimRegion.new()
	r.place(39.0, -121.0, 1500.0)  # 10 x 10
	var codes := PackedByteArray()
	codes.resize(100)
	codes.fill(165)
	codes[3] = 91
	var img := Image.create_from_data(10, 10, false, Image.FORMAT_L8, codes)
	check(r.set_fuel_from_image(img) and r.fuel_ok, "fuel image accepted")
	check(r.fuel[3] == 0 and r.fuel[4] == 4 and r.fuel[99] == 4, "codes land in the right cells")
	var empty := Image.create(10, 10, false, Image.FORMAT_L8)
	var r2 = SimRegion.new()
	r2.place(39.0, -121.0, 1500.0)
	check(not r2.set_fuel_from_image(empty) and r2.fuel[0] == SimRegion.DEFAULT_FUEL, "image with no fuel keeps the fallback")


func test_elevation_tiles() -> void:
	check(is_equal_approx(SimRegion.terrarium_metres(128, 0, 0), 0.0) and is_equal_approx(SimRegion.terrarium_metres(131, 232, 128), 1000.5), "Terrarium decoding")
	var r = camp_fire()
	check(r.elevation_zoom() == 10, "150 m cells use zoom 10 tiles")
	var tiles: Array[Vector2i] = r.elevation_tiles()
	check(tiles.size() >= 4 and tiles.size() <= 16, "a 60 km grid needs a handful of tiles")
	# Every tile encodes its own index, so each cell shows which tile it sampled.
	var images := {}
	for i in tiles.size():
		var bytes := PackedByteArray()
		bytes.resize(256 * 256 * 3)
		for p in 256 * 256:
			bytes[p * 3] = 128
			bytes[p * 3 + 1] = i + 1
		images[tiles[i]] = Image.create_from_data(256, 256, false, Image.FORMAT_RGB8, bytes)
	check(r.set_elevation_from_tiles(images) == 400 * 400 and r.elevation_ok, "all cells filled")
	var nw: int = roundi(r.elevation[0])
	var se: int = roundi(r.elevation[400 * 400 - 1])
	check(nw == 1 and se == tiles.size(), "north-west cell reads the first tile, south-east the last")
	var r2 = camp_fire()
	images.erase(tiles[0])
	check(r2.set_elevation_from_tiles(images) < 400 * 400 and is_equal_approx(r2.elevation[0], 0.0), "a missing tile leaves 0 m")


func test_weather() -> void:
	var r = camp_fire()
	r.start_hour = 21
	var speed := []
	var from := []
	var rh := []
	var temp := []
	for h in 30:
		speed.append(5.0 + h)
		from.append(45.0)
		rh.append(20.0)
		temp.append(15.0)
	speed.append(null)  # gap: later hours are dropped
	from.append(45.0)
	rh.append(20.0)
	temp.append(15.0)
	var reply := {"hourly": {"wind_speed_10m": speed, "wind_direction_10m": from, "relative_humidity_2m": rh, "temperature_2m": temp}}
	check(r.set_weather_from_json(reply) and r.weather.size() == 30, "weather parsed up to the first gap")
	check(r.weather_index(0.0) == 21 and r.weather_index(125.0) == 23, "sim time picks the hour after the start")
	check(r.weather_index(100000.0) == 29, "the last hour is held when data runs out")
	check(is_equal_approx(r.weather[21][1], 26.0) and is_equal_approx(r.weather[21][0], 45.0), "hour values are [from, speed, rh, temp]")
	check(not r.set_weather_from_json(null) and not r.set_weather_from_json({"hourly": {}}), "bad replies are rejected")
	check("start_date=2018-11-08&end_date=2018-11-11" in r.weather_url() and "models=era5" in r.weather_url(), "weather URL covers 4 days of ERA5")
