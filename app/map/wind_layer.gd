## Wind for one day over California, drawn like a weather broadcast: curved flow lines that fade in
## from a faint tail to a bright head (the head is the downwind end), longer and a bit thicker
## where the wind is stronger.
##
## The lines live in map (world) coordinates, so they are pinned to the ground: they pan and
## zoom with the map and are clipped to the state (this layer is a child of the region clip).
## Their density follows the zoom in steps (one lattice level per whole zoom level, so a line
## never jumps while you zoom or pan) and only the part of the map in view is generated.
##
## Data: hourly 10 m wind from ERA5 reanalysis (Open-Meteo archive API) on a coarse grid. ERA5 is
## requested explicitly: the API's default model mix timed out for this grid, and ERA5-Land
## returns no wind. A cold request costs about 0.2 s per point, hence the coarse 1 degree grid.
## The grid is smoothed onto a finer field (inverse-distance weighting), and the lines follow it.
## This is modelled reanalysis wind (~25 km), not station measurements.
extends Node2D

const Mercator = preload("res://map/mercator.gd")
const API := "https://archive-api.open-meteo.com/v1/archive"
const GRID_DEG := 1.0         # spacing of fetched points
const FIELD_STEP := 800.0     # world px between nodes of the smoothed field (~24 km on the ground)
const MIN_SPEED := 0.4        # m/s: calmer than this gets no line
const BASE_SPACING_DEG := 0.65 # line lattice spacing at zoom level 6 (halves for each level up)
const MIN_LEVEL := 5
const MAX_LEVEL := 10
const STEPS_EACH_WAY := 5
const INK := Color("#f0efec")
const HALO := Color(0.05, 0.05, 0.05, 0.6)

var date := ""                 # "YYYY-MM-DD" currently shown
var hour := 20:                # UTC
	set(v):
		if v == hour:
			return
		hour = v
		if status == "ready":
			_data_changed()
var status := "off"            # off / loading / ready / error text
var screen_scale := 1.0        # screen px per world px, set by the map (keeps line widths constant)
var points := PackedVector2Array()   # world positions of the fetched grid
var _lat := PackedFloat32Array()
var _lon := PackedFloat32Array()
var _u := []                   # per point: PackedFloat32Array(24), m/s toward east
var _v := []                   # per point: PackedFloat32Array(24), m/s toward north
var _cache := {}               # date -> [u, v]
var _http := HTTPRequest.new()
var _requested := ""
var _mainland := PackedVector2Array()  # world coords, to keep lines inside California
var _mainland_box := Rect2()

# Smoothed field on a regular world-space grid.
var _f_origin := Vector2.ZERO
var _f_cols := 0
var _f_rows := 0
var _fu := PackedFloat32Array()   # east m/s, NAN where there is no data
var _fv := PackedFloat32Array()   # north m/s

# Flow lines for the part of the map in view.
var _lines: Array = []            # {p: PackedVector2Array, c: PackedColorArray, w: float}
var _view_rect := Rect2()
var _view_zoom := 6.0
var _gen_rect := Rect2()          # area the current lines were generated for
var _gen_level := -1
var _dirty := true
var _drawn_scale := -1.0


func _ready() -> void:
	_http.timeout = 60.0
	_http.request_completed.connect(_on_done)
	add_child(_http)


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree():
		_ensure_lines()
		queue_redraw()


## Grid of fetch points: every GRID_DEG inside (or just outside) the mainland outline.
func set_region(mainland_world: PackedVector2Array, bbox: Array) -> void:
	_mainland = mainland_world
	_mainland_box = Rect2(mainland_world[0], Vector2.ZERO)
	for p in mainland_world:
		_mainland_box = _mainland_box.expand(p)
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
		_data_changed()
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
		_data_changed()


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


# ---------- smoothed field ----------

func _data_changed() -> void:
	_rebuild_field()
	_dirty = true
	_ensure_lines()
	queue_redraw()


func _rebuild_field() -> void:
	_fu = PackedFloat32Array()
	_fv = PackedFloat32Array()
	if status != "ready" or _mainland.is_empty():
		return
	_f_origin = _mainland_box.position - Vector2(FIELD_STEP, FIELD_STEP)
	_f_cols = int(ceil(_mainland_box.size.x / FIELD_STEP)) + 3
	_f_rows = int(ceil(_mainland_box.size.y / FIELD_STEP)) + 3
	_fu.resize(_f_cols * _f_rows)
	_fv.resize(_f_cols * _f_rows)
	for j in _f_rows:
		for i in _f_cols:
			var w := wind_at(_f_origin + Vector2(i, j) * FIELD_STEP)
			_fu[j * _f_cols + i] = w.x
			_fv[j * _f_cols + i] = w.y


## Bilinear wind from the smoothed field: Vector2(east, north) in m/s, NAN if there's no data.
func field_at(p: Vector2) -> Vector2:
	if _fu.is_empty():
		return Vector2(NAN, NAN)
	var g := (p - _f_origin) / FIELD_STEP
	var i := int(floor(g.x))
	var j := int(floor(g.y))
	if i < 0 or j < 0 or i + 1 >= _f_cols or j + 1 >= _f_rows:
		return Vector2(NAN, NAN)
	var fx := g.x - i
	var fy := g.y - j
	var k := j * _f_cols + i
	var k2 := k + _f_cols
	var u00 := _fu[k]
	var u10 := _fu[k + 1]
	var u01 := _fu[k2]
	var u11 := _fu[k2 + 1]
	var v00 := _fv[k]
	var v10 := _fv[k + 1]
	var v01 := _fv[k2]
	var v11 := _fv[k2 + 1]
	if is_nan(u00) or is_nan(u10) or is_nan(u01) or is_nan(u11):
		return Vector2(NAN, NAN)
	return Vector2(
		lerpf(lerpf(u00, u10, fx), lerpf(u01, u11, fx), fy),
		lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy))


# ---------- flow lines ----------

## Tells the layer what part of the map is in view. Pan needs no redraw (the lines are in map
## coordinates); a new zoom level or leaving the generated area makes new lines.
func set_view(rect: Rect2, zoom: float) -> void:
	_view_rect = rect
	_view_zoom = zoom
	if not is_visible_in_tree():
		return
	_ensure_lines()
	if not is_equal_approx(screen_scale, _drawn_scale):
		queue_redraw()


func _ensure_lines() -> void:
	if status != "ready" or _view_rect.size == Vector2.ZERO or _fu.is_empty() or not is_visible_in_tree():
		return
	var level := clampi(int(floor(_view_zoom)), MIN_LEVEL, MAX_LEVEL)
	if not _dirty and level == _gen_level and _gen_rect.encloses(_view_rect):
		return
	_dirty = false
	_gen_level = level
	_gen_rect = _view_rect.grow_individual(_view_rect.size.x * 0.2, _view_rect.size.y * 0.2, _view_rect.size.x * 0.2, _view_rect.size.y * 0.2)
	_build_lines(level)
	queue_redraw()


func _build_lines(level: int) -> void:
	_lines.clear()
	var spacing := BASE_SPACING_DEG / pow(2.0, level - 6)
	if level >= 8:
		spacing *= 1.35  # zoomed in there are many lines per screen: thin them out a little
	var nw := Mercator.to_latlon(_gen_rect.position)  # (lat, lon) of the north-west corner
	var se := Mercator.to_latlon(_gen_rect.end)
	var j0 := int(floor(se.x / spacing)) - 1
	var j1 := int(ceil(nw.x / spacing)) + 1
	var i0 := int(floor(nw.y / spacing)) - 1
	var i1 := int(ceil(se.y / spacing)) + 1
	for j in range(j0, j1 + 1):
		var lat0 := j * spacing
		for i in range(i0, i1 + 1):
			var lat := lat0
			if _lines.size() >= 1500:
				return
			# Every other row is shifted half a step, so the lines don't form a rigid grid.
			var lon := (i + (0.5 if (j & 1) == 1 else 0.0)) * spacing
			# A little jitter per lattice node (the same every time), so the lines don't look like a grid.
			lat += (_noise(i, j, 1.0) - 0.5) * 0.5 * spacing
			lon += (_noise(i, j, 2.0) - 0.5) * 0.5 * spacing
			var p0 := Mercator.to_world(lat, lon)
			if not _mainland_box.has_point(p0) or not Geometry2D.is_point_in_polygon(p0, _mainland):
				continue
			var w := field_at(p0)
			if is_nan(w.x) or w.length() < MIN_SPEED:
				continue
			var speed := w.length()
			var step_world := absf(Mercator.to_world(lat + spacing, lon).y - p0.y)
			var length := step_world * clampf(0.6 + speed / 10.0, 0.7, 1.15) * (0.85 + 0.3 * _noise(i, j, 3.0))
			var h := length / (STEPS_EACH_WAY * 2.0)
			var back := _trace(p0, -1.0, h)
			var fwd := _trace(p0, 1.0, h)
			var pts := PackedVector2Array()
			for k in range(back.size() - 1, -1, -1):
				pts.append(back[k])
			pts.append(p0)
			pts.append_array(fwd)
			if pts.size() < 4:
				continue
			var cols := PackedColorArray()
			for k in pts.size():
				cols.append(Color(INK, lerpf(0.3, 1.0, float(k) / (pts.size() - 1))))
			_lines.append({"p": pts, "c": cols, "w": 1.3 + clampf(speed / 10.0, 0.0, 1.0) * 1.3})


## Repeatable pseudo-random number in 0..1 for a lattice node.
static func _noise(i: int, j: int, salt: float) -> float:
	return fposmod(sin(i * 12.9898 + j * 78.233 + salt * 37.719) * 43758.5453, 1.0)


## Points along the flow from `start` (sign +1 downwind, -1 upwind), stopping at the state's edge.
func _trace(start: Vector2, sign: float, h: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var p := start
	for _s in STEPS_EACH_WAY:
		var d1 := _flow_dir(p)
		if d1 == Vector2.ZERO:
			break
		var d2 := _flow_dir(p + d1 * sign * h * 0.5)  # midpoint step, so curves stay smooth
		if d2 == Vector2.ZERO:
			break
		p += d2 * sign * h
		if not _mainland_box.has_point(p) or not Geometry2D.is_point_in_polygon(p, _mainland):
			break
		out.append(p)
	return out


## Unit direction the wind blows toward in world coordinates (y grows southward), or ZERO.
func _flow_dir(p: Vector2) -> Vector2:
	var w := field_at(p)
	if is_nan(w.x) or w.length() < MIN_SPEED * 0.5:
		return Vector2.ZERO
	return Vector2(w.x, -w.y).normalized()


func _draw() -> void:
	_drawn_scale = screen_scale
	if status != "ready" or _lines.is_empty():
		return
	var px := 1.0 / maxf(screen_scale, 1e-6)  # world units per screen pixel
	for l in _lines:
		var pts: PackedVector2Array = l.p
		var width: float = l.w * px
		var halo_width := width + 2.2 * px
		draw_polyline(pts, HALO, halo_width, true)
		draw_polyline_colors(pts, l.c, width, true)
		# A bright dot at the downwind end.
		var tip := pts[pts.size() - 1]
		draw_circle(tip, halo_width * 0.62, HALO)
		draw_circle(tip, width * 0.85, INK)
