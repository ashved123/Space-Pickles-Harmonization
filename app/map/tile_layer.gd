## Streams Web Mercator map tiles (NASA GIBS, USGS National Map) for the visible area and draws
## them in world coordinates. The URL template uses {z} {x} {y} and optionally {date}. Missing tiles fall back to a scaled-up parent tile while they load.
## Tiles that fail (offline, server error) are skipped; the map still works without them.
extends Node2D

const Mercator = preload("res://map/mercator.gd")
const MAX_REQUESTS := 6
const MAX_CACHE := 400
const RETRY_MS := 30000      # retry a failed tile after this long (network blips)

var url_template := ""
var max_zoom := 9
var date := ""           # "YYYY-MM-DD" for daily layers, "" for static ones
var tint := Color.WHITE

var _view_rect := Rect2()
var _tile_zoom := 0
var _needed: Array[Vector3i] = []
var _cache := {}         # url -> ImageTexture
var _failed := {}        # url -> time of failure (msec)
var _pending := {}       # url -> true
var _queue: Array[String] = []
var _requests: Array[HTTPRequest] = []
var _busy := {}          # HTTPRequest -> url


func setup(p_url_template: String, p_max_zoom: int, p_date: String = "") -> void:
	url_template = p_url_template
	max_zoom = p_max_zoom
	date = p_date
	for i in MAX_REQUESTS:
		var r := HTTPRequest.new()
		r.timeout = 20.0
		r.request_completed.connect(_on_done.bind(r))
		add_child(r)
		_requests.append(r)


func set_template(p_url_template: String, p_max_zoom: int) -> void:
	if p_url_template == url_template:
		return
	url_template = p_url_template
	max_zoom = p_max_zoom
	_queue.clear()
	update_view(_view_rect, _tile_zoom)


func set_date(p_date: String) -> void:
	if p_date == date:
		return
	date = p_date
	_queue.clear()
	update_view(_view_rect, _tile_zoom)


func tile_url(z: int, x: int, y: int) -> String:
	return url_template.replace("{z}", str(z)).replace("{x}", str(x)).replace("{y}", str(y)).replace("{date}", date)


## Call when the visible world rectangle or zoom changes.
func update_view(world_rect: Rect2, zoom: float) -> void:
	_view_rect = world_rect
	_tile_zoom = clampi(int(round(zoom)), 1, max_zoom)
	var n := 1 << _tile_zoom
	var ts := Mercator.WORLD / n
	var x0 := clampi(int(floor(world_rect.position.x / ts)), 0, n - 1)
	var x1 := clampi(int(floor(world_rect.end.x / ts)), 0, n - 1)
	var y0 := clampi(int(floor(world_rect.position.y / ts)), 0, n - 1)
	var y1 := clampi(int(floor(world_rect.end.y / ts)), 0, n - 1)
	_needed.clear()
	var centre := world_rect.get_center() / ts
	var wanted: Array = []
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_needed.append(Vector3i(x, y, _tile_zoom))
			var url := tile_url(_tile_zoom, x, y)
			if not _cache.has(url) and not _recently_failed(url) and not _pending.has(url):
				wanted.append([Vector2(x + 0.5, y + 0.5).distance_squared_to(centre), url])
	wanted.sort_custom(func(a, b): return a[0] < b[0])
	_queue.clear()
	for w in wanted:
		_queue.append(w[1])
	_pump()
	_evict()
	queue_redraw()


func loading_count() -> int:
	return _pending.size() + _queue.size()


func _enter_tree() -> void:
	_pump.call_deferred()


func _recently_failed(url: String) -> bool:
	return _failed.has(url) and Time.get_ticks_msec() - int(_failed[url]) < RETRY_MS


func _pump() -> void:
	if not is_inside_tree():
		return  # HTTPRequest only works in the tree; _enter_tree pumps again
	for r in _requests:
		if _queue.is_empty():
			return
		if _busy.has(r):
			continue
		var url: String = _queue.pop_front()
		if r.request(url) == OK:
			_busy[r] = url
			_pending[url] = true
		else:
			_queue.push_front(url)
			return


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, r: HTTPRequest) -> void:
	var url: String = _busy.get(r, "")
	_busy.erase(r)
	_pending.erase(url)
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.size() > 0:
		var img := Image.new()
		# PNG files start with byte 0x89; everything else we request is JPEG.
		var err := img.load_png_from_buffer(body) if body[0] == 0x89 else img.load_jpg_from_buffer(body)
		if err == OK:
			_cache[url] = ImageTexture.create_from_image(img)
			queue_redraw()
		else:
			_failed[url] = Time.get_ticks_msec()
	else:
		_failed[url] = Time.get_ticks_msec()
	_pump()


func _evict() -> void:
	if _cache.size() <= MAX_CACHE:
		return
	var keep := {}
	for t in _needed:
		keep[tile_url(t.z, t.x, t.y)] = true
	for url in _cache.keys():
		if not keep.has(url):
			_cache.erase(url)
		if _cache.size() <= MAX_CACHE / 2:
			break


func _draw() -> void:
	for t in _needed:
		var ts := Mercator.WORLD / (1 << t.z)
		var rect := Rect2(t.x * ts, t.y * ts, ts, ts)
		var url := tile_url(t.z, t.x, t.y)
		if _cache.has(url):
			draw_texture_rect(_cache[url], rect, false, tint)
			continue
		# Fall back to a loaded parent tile, cropped to this tile's part of it.
		for k in range(1, 6):
			var pz := t.z - k
			if pz < 1:
				break
			var purl := tile_url(pz, t.x >> k, t.y >> k)
			if _cache.has(purl):
				var tex: ImageTexture = _cache[purl]
				var part := tex.get_width() / float(1 << k)
				var src := Rect2((t.x - ((t.x >> k) << k)) * part, (t.y - ((t.y >> k) << k)) * part, part, part)
				draw_texture_rect_region(tex, rect, src, tint)
				break
