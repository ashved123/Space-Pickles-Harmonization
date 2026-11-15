## Wind for one day over California: fetches hourly 10 m wind (ERA5 reanalysis via the Open-Meteo
## archive API) on a coarse grid and draws arrows in screen space.
## ERA5 is requested explicitly: the API's default model mix timed out for this grid, and ERA5-Land
## returns no wind. A cold request costs about 0.2 s per point, hence the coarse 1 degree grid.
## Arrows point where the wind blows TOWARD; length grows with speed.
## This is modelled reanalysis wind (~25 km, sampled every 1 degree), not station measurements.
extends Node2D

const Mercator = preload("res://map/mercator.gd")
const API := "https://archive-api.open-meteo.com/v1/archive"
const GRID_DEG := 1.0         # spacing of fetched points
const ARROW_SPACING := 64.0   # screen px between arrows
const PX_PER_MS := 4.0        # arrow length per m/s
const MAX_LEN := 56.0
const INK := Color("#f0efec")
const HALO := Color(0.05, 0.05, 0.05, 0.85)

var date := ""                 # "YYYY-MM-DD" currently shown
var hour := 20                 # UTC
var status := "off"            # off / loading / ready / error text
var points := PackedVector2Array()   # world positions of the fetched grid
var _lat := PackedFloat32Array()
var _lon := PackedFloat32Array()
var _u := []                   # per point: PackedFloat32Array(24), m/s toward east
var _v := []                   # per point: PackedFloat32Array(24), m/s toward north
var _cache := {}               # date -> [u, v]
var _http := HTTPRequest.new()
var _requested := ""
var _mainland := PackedVector2Array()  # world coords, to keep arrows inside California

var to_screen := Callable()    # world -> screen
var to_world := Callable()     # screen -> world
var map_size := Vector2.ZERO


func _ready() -> void:
	_http.timeout = 60.0
	_http.request_completed.connect(_on_done)
	add_child(_http)


## Grid of fetch points: every GRID_DEG inside (or just outside) the mainland outline.
func set_region(mainland_world: PackedVector2Array, bbox: Array) -> void:
	_mainland = mainland_world
	var margin := GRID_DEG * 0.6
	var lat: float = floor(bbox[0] / GRID_DEG) * GRID_DEG
	while lat <= bbox[2] + GRID_DEG:
		var lon: float = floor(bbox[1] / GRID_DEG) * GRID_DEG
		while lon <= bbox[3] + GRID_DEG:
			var near := false
			for d in [Vector2.ZERO, Vector2(margin, 0), Vector2(-margin, 0), Vector2(0, margin), Vector2(0, -margin)]:
				if Geometry2D.is_point_in_polygon(Mercator.to_world(lat + d.y, lon + d.x), _mainland):
					near = true
					break
			if near:
				_lat.append(lat)
				_lon.append(lon)
				points.append(Mercator.to_world(lat, lon))
			lon += GRID_DEG
		lat += GRID_DEG


func show_date(p_date: String) -> void:
	if p_date == date and status in ["ready", "loading"]:
		return
	date = p_date
	if _cache.has(date):
		_u = _cache[date][0]
		_v = _cache[date][1]
		status = "ready"
		queue_redraw()
		return
	_u = []
	_v = []
	status = "loading"
	queue_redraw()
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	var lats := []
	var lons := []
	for i in _lat.size():
		lats.append("%.2f" % _lat[i])
		lons.append("%.2f" % _lon[i])
	var url := "%s?latitude=%s&longitude=%s&start_date=%s&end_date=%s&hourly=wind_speed_10m,wind_direction_10m&wind_speed_unit=ms&timezone=GMT&models=era5" % [
		API, ",".join(lats), ",".join(lons), date, date]
	_requested = date
	if _http.request(url) != OK:
		status = "couldn't start the wind request"


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		status = "wind data unavailable (HTTP %d)" % code
		queue_redraw()
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) == TYPE_DICTIONARY:
		data = [data]
	if typeof(data) != TYPE_ARRAY or data.size() != _lat.size():
		status = "wind data unavailable (unexpected reply)"
		queue_redraw()
		return
	var u := []
	var v := []
	for loc in data:
		var pu := PackedFloat32Array()
		var pv := PackedFloat32Array()
		var sp: Array = loc.hourly.wind_speed_10m
		var di: Array = loc.hourly.wind_direction_10m
		for h in 24:
			if h >= sp.size() or sp[h] == null or di[h] == null:
				pu.append(NAN)
				pv.append(NAN)
				continue
			# Direction is where the wind comes FROM; flip it to get where it blows toward.
			var toward := deg_to_rad(float(di[h]) + 180.0)
			pu.append(float(sp[h]) * sin(toward))
			pv.append(float(sp[h]) * cos(toward))
		u.append(pu)
		v.append(pv)
	var any_value := false
	for pu in u:
		if not is_nan(pu[12]):
			any_value = true
	if not any_value:
		status = "no wind data for this date"
		queue_redraw()
		return
	_cache[_requested] = [u, v]
	if _requested == date:
		_u = u
		_v = v
		status = "ready"
	queue_redraw()


## Wind at a world position: Vector2(east, north) in m/s, inverse-distance weighted from the
## nearest grid points. Returns Vector2(NAN, NAN) if there is no data.
func wind_at(world_pos: Vector2) -> Vector2:
	if status != "ready":
		return Vector2(NAN, NAN)
	var sum := Vector2.ZERO
	var wsum := 0.0
	var reach := (points[1].distance_to(points[0]) if points.size() > 1 else 1.0) * 2.2
	for i in points.size():
		var d := points[i].distance_to(world_pos)
		if d > reach or is_nan(_u[i][hour]):
			continue
		var w := 1.0 / maxf(d * d, 1.0)
		sum += Vector2(_u[i][hour], _v[i][hour]) * w
		wsum += w
	return sum / wsum if wsum > 0.0 else Vector2(NAN, NAN)


func _draw() -> void:
	if status != "ready" or not to_world.is_valid():
		return
	var y := ARROW_SPACING / 2.0
	while y < map_size.y:
		var x := ARROW_SPACING / 2.0
		while x < map_size.x:
			var wp: Vector2 = to_world.call(Vector2(x, y))
			if Geometry2D.is_point_in_polygon(wp, _mainland):
				var w := wind_at(wp)
				if not is_nan(w.x):
					_arrow(Vector2(x, y), w)
			x += ARROW_SPACING
		y += ARROW_SPACING


func _arrow(at: Vector2, wind: Vector2) -> void:
	var speed := wind.length()
	if speed < 0.3:
		draw_circle(at, 2.0, INK)
		return
	var dir := Vector2(wind.x, -wind.y) / speed  # screen y points south
	var length := minf(8.0 + speed * PX_PER_MS, MAX_LEN)
	var a := at - dir * length / 2.0
	var b := at + dir * length / 2.0
	var head := 7.0
	for pass_i in 2:
		var c := HALO if pass_i == 0 else INK
		var w := 4.0 if pass_i == 0 else 1.6
		draw_line(a, b, c, w, true)
		draw_line(b, b - dir.rotated(0.45) * head, c, w, true)
		draw_line(b, b - dir.rotated(-0.45) * head, c, w, true)
