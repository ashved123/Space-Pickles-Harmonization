## A sim grid placed on the real map, built live from a clicked hotspot or fire event
## ("option B": no pipeline region files needed). Pure logic, no nodes.
##
## The grid is square and aligned with Web Mercator, so map tiles, the hotspot files and the
## image services all line up with it by simple scaling. Over a region this small (60-150 km)
## Mercator's scale change is under 1%, far below the 150 m cell.
## Row 0 = north edge, col 0 = west edge, like the pipeline data contract.
##
## Filled in by sim/region_loader.gd:
##   fuel        LANDFIRE FBFM40 codes -> our 7 classes (nearest neighbour, never averaged)
##   elevation   Terrarium elevation tiles, metres
##   weather     hourly ERA5 (Open-Meteo): wind FROM deg, wind m/s, RH %, temp C
##   background  USGS aerial image of the grid (display only)
extends RefCounted

const Mercator = preload("res://map/mercator.gd")

const CELL_M := 150.0
const DEFAULT_SIDE_M := 60000.0   # 400 x 400 cells around a single hotspot
const MAX_CELLS := 512            # bigger areas get bigger cells instead of more cells
const FIRE_MARGIN := 1.5          # region side = fire's bounding box side * this
const WEATHER_DAYS := 4           # seed day + 3 more
const DEFAULT_FUEL := 3           # shrub, used when LANDFIRE can't be reached
# LANDFIRE releases with an FBFM40 image service (lfps.usgs.gov). A release shows the land
# at the end of its year, so a fire needs one from an earlier year.
const LANDFIRE_YEARS: Array[int] = [2016, 2022, 2023, 2024, 2025]
# Footprint half-width in metres, per sensor code (0 MODIS 1 km, 1-2 VIIRS 375 m).
const FOOTPRINT_HALF_M: Array[float] = [500.0, 187.5, 187.5]

var lat := 0.0            # centre
var lon := 0.0
var rows := 0
var cols := 0
var cell_size_m := CELL_M
var origin := Vector2.ZERO  # world coordinates of the north-west corner
var cell_world := 0.0       # world units per cell
var year := 0
var doy := 0                # seed day (day of year)
var start_hour := 20        # UTC hour the sim clock starts at
var label := ""

var fuel := PackedByteArray()
var elevation := PackedFloat32Array()
var weather: Array = []     # one PackedFloat32Array [from_deg, speed_ms, rh_pct, temp_c] per hour from 00:00 UTC on the seed day
var background: Image
var fuel_ok := false
var elevation_ok := false
var weather_ok := false


## Request passed from the map / calendar: {lat, lon, year, doy, side_m, label}.
static func from_request(req: Dictionary):
	var r = new()
	r.label = req.get("label", "")
	r.year = req.year
	r.doy = req.doy
	r.place(req.lat, req.lon, req.get("side_m", DEFAULT_SIDE_M))
	return r


## Request for a whole fire event (app/datasets/fires.json entry). Seeds from the fire's first
## day unless a day is given.
static func request_for_fire(f: Dictionary, p_year: int = 0, p_doy: int = 0) -> Dictionary:
	var b: Array = f.bbox  # [south, west, north, east]
	var mid_lat: float = (b[0] + b[2]) / 2.0
	var height_m: float = (b[2] - b[0]) * 111320.0
	var width_m: float = (b[3] - b[1]) * 111320.0 * cos(deg_to_rad(mid_lat))
	var req := {"lat": mid_lat, "lon": (b[1] + b[3]) / 2.0,
		"side_m": maxf(maxf(height_m, width_m) * FIRE_MARGIN, DEFAULT_SIDE_M),
		"label": "fire event %s" % f.id, "year": p_year, "doy": p_doy}
	if p_year == 0:
		var parts: PackedStringArray = String(f.start).split("-")
		req.year = int(parts[0])
		req.doy = day_of_year(int(parts[0]), int(parts[1]), int(parts[2]))
	return req


static func day_of_year(y: int, m: int, d: int) -> int:
	var t0 := Time.get_unix_time_from_datetime_dict({"year": y, "month": 1, "day": 1})
	var t := Time.get_unix_time_from_datetime_dict({"year": y, "month": m, "day": d})
	return int((t - t0) / 86400) + 1


## "YYYY-MM-DD" for a day of year (days past the end of the year roll into the next one).
static func date_string(y: int, day: int) -> String:
	var t0 := Time.get_unix_time_from_datetime_dict({"year": y, "month": 1, "day": 1})
	var d := Time.get_datetime_dict_from_unix_time(t0 + (day - 1) * 86400)
	return "%04d-%02d-%02d" % [d.year, d.month, d.day]


## Square grid of `side_m` centred on a point. 150 m cells up to MAX_CELLS, coarser beyond.
func place(p_lat: float, p_lon: float, side_m: float) -> void:
	lat = p_lat
	lon = p_lon
	var n := ceili(side_m / CELL_M)
	cell_size_m = CELL_M
	if n > MAX_CELLS:
		n = MAX_CELLS
		cell_size_m = side_m / MAX_CELLS
	rows = n
	cols = n
	cell_world = cell_size_m * Mercator.world_per_metre(lat)
	origin = Mercator.to_world(lat, lon) - Vector2(cols, rows) * cell_world / 2.0
	fuel.resize(rows * cols)
	fuel.fill(DEFAULT_FUEL)
	elevation.resize(rows * cols)
	elevation.fill(0.0)


## (row, col) of a world position. Can be outside the grid: check with in_grid().
func cell_of(world_pos: Vector2) -> Vector2i:
	var p := (world_pos - origin) / cell_world
	return Vector2i(floori(p.y), floori(p.x))


func in_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < rows and cell.y >= 0 and cell.y < cols


## Grid bounds in Web Mercator metres (EPSG:3857): [west, south, east, north].
func bbox_3857() -> Array[float]:
	var c := Mercator.EARTH_CIRCUMFERENCE_M
	var k := c / Mercator.WORLD
	var west := origin.x * k - c / 2.0
	var north := c / 2.0 - origin.y * k
	var out: Array[float] = [west, north - rows * cell_world * k, west + cols * cell_world * k, north]
	return out


func seed_date() -> String:
	return date_string(year, doy)


# ---------- hotspots ----------

## Indices into `hs` (HotspotData with this region's year loaded) of detections inside the
## grid with day of year in [d0, d1].
func hotspots_in(hs, d0: int, d1: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in hs.doy.size():
		var d: int = hs.doy[i]
		if d >= d0 and d <= d1 and in_grid(cell_of(hs.pos[i])):
			out.append(i)
	return out


## Footprint half-width in cells for a sensor code (VIIRS 1, MODIS 3 at 150 m).
func footprint_half_cells(sensor: int) -> int:
	return roundi(FOOTPRINT_HALF_M[mini(sensor, FOOTPRINT_HALF_M.size() - 1)] / cell_size_m)


# ---------- fuel (LANDFIRE FBFM40) ----------

## FBFM40 code -> fuel class index 0-6 (see CLAUDE.md data contract). Anything else is non-burnable.
static func fuel_class(code: int) -> int:
	if code >= 101 and code <= 109:
		return 1  # GR grass
	if code >= 121 and code <= 124:
		return 2  # GS grass-shrub
	if code >= 141 and code <= 149:
		return 3  # SH shrub
	if code >= 161 and code <= 165:
		return 4  # TU timber-understory
	if code >= 181 and code <= 189:
		return 5  # TL timber litter
	if code >= 201 and code <= 204:
		return 6  # SB slash-blowdown
	return 0


## Newest LANDFIRE release from before the fire's year; the oldest one if there is none.
static func landfire_year(fire_year: int) -> int:
	var best: int = LANDFIRE_YEARS[0]
	for y in LANDFIRE_YEARS:
		if y < fire_year:
			best = y
	return best


func fuel_url() -> String:
	var b := bbox_3857()
	var y := landfire_year(year)
	# renderingRule None returns the raw FBFM40 codes as 8-bit grey instead of legend colours.
	return "https://lfps.usgs.gov/arcgis/rest/services/Landfire_LF%d/LF%d_FBFM40_CONUS/ImageServer/exportImage?bbox=%.1f,%.1f,%.1f,%.1f&bboxSR=3857&imageSR=3857&size=%d,%d&format=png&pixelType=U8&interpolation=RSP_NearestNeighbor&renderingRule=%%7B%%22rasterFunction%%22%%3A%%22None%%22%%7D&f=image" % [
		y, y, b[0], b[1], b[2], b[3], cols, rows]


## Grey image of FBFM40 codes, one pixel per cell. False (fuel unchanged) if it has no
## burnable cell, e.g. outside LANDFIRE's coverage.
func set_fuel_from_image(img: Image) -> bool:
	if img == null or img.is_empty():
		return false
	if img.get_width() != cols or img.get_height() != rows:
		img.resize(cols, rows, Image.INTERPOLATE_NEAREST)
	img.convert(Image.FORMAT_L8)
	var codes := img.get_data()
	var classes := PackedByteArray()
	classes.resize(rows * cols)
	var burnable := 0
	for i in rows * cols:
		var cls := fuel_class(codes[i])
		classes[i] = cls
		if cls > 0:
			burnable += 1
	if burnable == 0:
		return false
	fuel = classes
	fuel_ok = true
	return true


# ---------- elevation (Terrarium tiles) ----------

## Tile zoom whose pixels are just finer than a cell (120 m pixels for 150 m cells at 38 N).
func elevation_zoom() -> int:
	var m_per_px_z0 := Mercator.EARTH_CIRCUMFERENCE_M * cos(deg_to_rad(lat)) / 256.0
	return clampi(ceili(log(m_per_px_z0 / cell_size_m) / log(2.0)), 0, 14)


## Tiles covering the grid, as Vector2i(x, y) at elevation_zoom().
func elevation_tiles() -> Array[Vector2i]:
	var k := pow(2.0, elevation_zoom() - Mercator.ZREF) / 256.0
	var a := origin * k
	var b := (origin + Vector2(cols, rows) * cell_world) * k
	var out: Array[Vector2i] = []
	for ty in range(floori(a.y), floori(b.y) + 1):
		for tx in range(floori(a.x), floori(b.x) + 1):
			out.append(Vector2i(tx, ty))
	return out


func elevation_tile_url(tile: Vector2i) -> String:
	return "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/%d/%d/%d.png" % [elevation_zoom(), tile.x, tile.y]


## Terrarium encoding: metres = R * 256 + G + B / 256 - 32768.
static func terrarium_metres(r: int, g: int, b: int) -> float:
	return r * 256.0 + g + b / 256.0 - 32768.0


## `tiles`: Vector2i(x, y) -> 256 x 256 Image. Each cell takes the pixel under its centre.
## Cells on a missing tile stay at 0 m. Returns the number of cells filled.
func set_elevation_from_tiles(tiles: Dictionary) -> int:
	var data := {}
	for key in tiles:
		var img: Image = tiles[key]
		if img == null or img.get_width() != 256 or img.get_height() != 256:
			continue
		img.convert(Image.FORMAT_RGB8)
		data[key] = img.get_data()
	var k := pow(2.0, elevation_zoom() - Mercator.ZREF)
	var filled := 0
	for r in rows:
		var py := (origin.y + (r + 0.5) * cell_world) * k
		var ty := floori(py / 256.0)
		var iy := clampi(int(py) - ty * 256, 0, 255)
		for c in cols:
			var px := (origin.x + (c + 0.5) * cell_world) * k
			var tx := floori(px / 256.0)
			var bytes = data.get(Vector2i(tx, ty))
			if bytes == null:
				continue
			var o := (iy * 256 + clampi(int(px) - tx * 256, 0, 255)) * 3
			elevation[r * cols + c] = terrarium_metres(bytes[o], bytes[o + 1], bytes[o + 2])
			filled += 1
	elevation_ok = filled > 0
	return filled


# ---------- weather (Open-Meteo archive, ERA5) ----------

func weather_url() -> String:
	return "https://archive-api.open-meteo.com/v1/archive?latitude=%.3f&longitude=%.3f&start_date=%s&end_date=%s&hourly=wind_speed_10m,wind_direction_10m,relative_humidity_2m,temperature_2m&wind_speed_unit=ms&timezone=GMT&models=era5" % [
		lat, lon, seed_date(), date_string(year, doy + WEATHER_DAYS - 1)]


## Parsed Open-Meteo reply. Keeps hours up to the first gap. False if there is no usable hour.
func set_weather_from_json(data) -> bool:
	weather = []
	if typeof(data) != TYPE_DICTIONARY or not data.has("hourly"):
		return false
	var h: Dictionary = data.hourly
	var speed: Array = h.get("wind_speed_10m", [])
	var from: Array = h.get("wind_direction_10m", [])
	var rh: Array = h.get("relative_humidity_2m", [])
	var temp: Array = h.get("temperature_2m", [])
	for i in mini(mini(speed.size(), from.size()), mini(rh.size(), temp.size())):
		if speed[i] == null or from[i] == null or rh[i] == null or temp[i] == null:
			break
		weather.append(PackedFloat32Array([float(from[i]), float(speed[i]), float(rh[i]), float(temp[i])]))
	weather_ok = weather.size() > start_hour
	return weather_ok


## Index into `weather` for a sim time; holds the last hour once the data runs out.
func weather_index(elapsed_minutes: float) -> int:
	return mini(start_hour + int(elapsed_minutes / 60.0), weather.size() - 1)


# ---------- background (USGS aerial imagery) ----------

func background_url() -> String:
	var b := bbox_3857()
	return "https://basemap.nationalmap.gov/arcgis/rest/services/USGSImageryOnly/MapServer/export?bbox=%.1f,%.1f,%.1f,%.1f&bboxSR=3857&imageSR=3857&size=1024,1024&format=jpg&f=image" % [
		b[0], b[1], b[2], b[3]]
