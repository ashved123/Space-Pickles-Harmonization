## Streams Web Mercator map tiles (NASA GIBS, USGS National Map) for the visible area and draws
## them in world coordinates. The URL template uses {z} {x} {y} and optionally {date}.
##
## To keep zooming and panning smooth:
## - visible tiles load first, nearest the centre first;
## - then it prefetches a ring of tiles around the view and the next zoom level for the middle
##   of the view, so the likely next view is already in memory;
## - preload_region() keeps low-zoom tiles for a whole region in memory (never evicted), so there
##   is always something to show while sharper tiles arrive;
## - on desktop, downloaded tiles are also kept on disk (user://tile_cache) for the next run.
##   In the web build the browser's own HTTP cache does that job.
## Tiles that fail (offline, server error) are retried later; the map still works without them.
extends Node2D

const Mercator = preload("res://map/mercator.gd")
const MAX_REQUESTS := 12
const MAX_CACHE := 900        # tiles in memory (~0.2 MB each as RGB8)
const MAX_PREFETCH := 160
const RETRY_MS := 30000       # retry a failed tile after this long (network blips)
const DISK_LOADS_PER_FRAME := 12
const CACHE_DIR := "user://tile_cache"

var url_template := ""
var max_zoom := 9
var date := ""           # "YYYY-MM-DD" for daily layers, "" for static ones
var tint := Color.WHITE
var pixel_bias := 0.0    # extra zoom levels for high-DPI screens (log2 of screen px per map px)

var _view_rect := Rect2()
var _view_zoom := 0.0
var _tile_zoom := 0
var _needed: Array[Vector3i] = []
var _cache := {}         # url -> ImageTexture
var _pinned := {}        # url -> true, never evicted (preloaded region tiles)
var _failed := {}        # url -> time of failure (msec)
var _pending := {}       # url -> true
var _queue: Array[String] = []      # visible tiles, most important first
var _prefetch: Array[String] = []   # likely-next tiles, loaded when the queue is empty
var _requests: Array[HTTPRequest] = []
var _busy := {}          # HTTPRequest -> url
var _preload := []       # [world_rect, z_from, z_to] to redo when the template changes
var _use_disk := not OS.has_feature("web")


func setup(p_url_template: String, p_max_zoom: int, p_date: String = "") -> void:
	url_template = p_url_template
	max_zoom = p_max_zoom
	date = p_date
	if _use_disk:
		DirAccess.make_dir_recursive_absolute(CACHE_DIR)
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
	_prefetch.clear()
	_pinned.clear()
	if not _preload.is_empty() and url_template != "":
		preload_region(_preload[0], _preload[1], _preload[2])
	update_view(_view_rect, _view_zoom)


func set_date(p_date: String) -> void:
	if p_date == date:
		return
	date = p_date
	_queue.clear()
	_prefetch.clear()
	update_view(_view_rect, _view_zoom)


func tile_url(z: int, x: int, y: int) -> String:
	return url_template.replace("{z}", str(z)).replace("{x}", str(x)).replace("{y}", str(y)).replace("{date}", date)


## Keep every tile of zoom levels z_from..z_to covering world_rect in memory.
func preload_region(world_rect: Rect2, z_from: int, z_to: int) -> void:
	_preload = [world_rect, z_from, z_to]
	for z in range(z_from, mini(z_to, max_zoom) + 1):
		var r := _tile_range(world_rect, z)
		for y in range(r.position.y, r.end.y + 1):
			for x in range(r.position.x, r.end.x + 1):
				var url := tile_url(z, x, y)
				_pinned[url] = true
				if _wanted(url) and not _prefetch.has(url):
					_prefetch.append(url)
	_pump()


## Call when the visible world rectangle or zoom changes.
func update_view(world_rect: Rect2, zoom: float) -> void:
	_view_rect = world_rect
	_view_zoom = zoom
	_tile_zoom = clampi(int(round(zoom + pixel_bias)), 1, max_zoom)
	var ts := Mercator.WORLD / (1 << _tile_zoom)
	var r := _tile_range(world_rect, _tile_zoom)
	var centre := world_rect.get_center() / ts
	_needed.clear()
	var wanted: Array = []
	for y in range(r.position.y, r.end.y + 1):
		for x in range(r.position.x, r.end.x + 1):
			_needed.append(Vector3i(x, y, _tile_zoom))
			var url := tile_url(_tile_zoom, x, y)
			if _wanted(url):
				wanted.append([Vector2(x + 0.5, y + 0.5).distance_squared_to(centre), url])
	wanted.sort_custom(func(a, b): return a[0] < b[0])
	_queue.clear()
	for w in wanted:
		_queue.append(w[1])
	_plan_prefetch(r, centre)
	_pump()
	_evict()
	queue_redraw()


## Likely-next tiles: the next zoom level under the middle of the view, then a ring around the view.
func _plan_prefetch(r: Rect2i, centre: Vector2) -> void:
	var keep: Array[String] = []
	for url in _prefetch:  # unfinished region preload stays queued
		if _pinned.has(url) and _wanted(url):
			keep.append(url)
	var extra: Array = []
	if _tile_zoom < max_zoom:
		var n2 := 1 << (_tile_zoom + 1)
		var c2 := centre * 2.0
		var half := Vector2(r.size.x + 1, r.size.y + 1) * 0.55  # middle ~half of the view, in child tiles
		for y in range(int(floor(c2.y - half.y)), int(ceil(c2.y + half.y))):
			for x in range(int(floor(c2.x - half.x)), int(ceil(c2.x + half.x))):
				if x >= 0 and y >= 0 and x < n2 and y < n2:
					extra.append([Vector2(x + 0.5, y + 0.5).distance_squared_to(c2), tile_url(_tile_zoom + 1, x, y)])
	var n := 1 << _tile_zoom
	for y in range(r.position.y - 1, r.end.y + 2):
		for x in range(r.position.x - 1, r.end.x + 2):
			var inside := x >= r.position.x and x <= r.end.x and y >= r.position.y and y <= r.end.y
			if not inside and x >= 0 and y >= 0 and x < n and y < n:
				extra.append([1e9 + Vector2(x + 0.5, y + 0.5).distance_squared_to(centre), tile_url(_tile_zoom, x, y)])
	extra.sort_custom(func(a, b): return a[0] < b[0])
	_prefetch = []
	for e in extra:
		if _prefetch.size() >= MAX_PREFETCH:
			break
		if _wanted(e[1]):
			_prefetch.append(e[1])
	_prefetch.append_array(keep)


func _tile_range(world_rect: Rect2, z: int) -> Rect2i:
	var n := 1 << z
	var ts := Mercator.WORLD / n
	var x0 := clampi(int(floor(world_rect.position.x / ts)), 0, n - 1)
	var x1 := clampi(int(floor(world_rect.end.x / ts)), 0, n - 1)
	var y0 := clampi(int(floor(world_rect.position.y / ts)), 0, n - 1)
	var y1 := clampi(int(floor(world_rect.end.y / ts)), 0, n - 1)
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


func _wanted(url: String) -> bool:
	return not _cache.has(url) and not _pending.has(url) and not _recently_failed(url)


## Visible tiles still loading (prefetching doesn't count).
func loading_count() -> int:
	var n := _queue.size()
	for t in _needed:
		if _pending.has(tile_url(t.z, t.x, t.y)):
			n += 1
	return n


func _enter_tree() -> void:
	_pump.call_deferred()


func _recently_failed(url: String) -> bool:
	return _failed.has(url) and Time.get_ticks_msec() - int(_failed[url]) < RETRY_MS


func _next_url() -> String:
	if not _queue.is_empty():
		return _queue.pop_front()
	if not _prefetch.is_empty():
		return _prefetch.pop_front()
	return ""


func _pump() -> void:
	if not is_inside_tree() or url_template == "":
		return  # HTTPRequest only works in the tree; _enter_tree pumps again
	var disk_loads := 0
	for r in _requests:
		if _busy.has(r):
			continue
		while true:
			var url := _next_url()
			if url == "":
				return
			if not _wanted(url):
				continue
			if _use_disk and FileAccess.file_exists(_disk_path(url)):
				if _store(url, FileAccess.get_file_as_bytes(_disk_path(url))):
					disk_loads += 1
					if disk_loads >= DISK_LOADS_PER_FRAME:
						_pump.call_deferred()  # spread decoding over frames
						return
					continue
			if r.request(url) == OK:
				_busy[r] = url
				_pending[url] = true
			else:
				_queue.push_front(url)
				return
			break


func _disk_path(url: String) -> String:
	return "%s/%s.bin" % [CACHE_DIR, url.md5_text()]


## Decode tile bytes into the memory cache. Returns false if they aren't a valid image.
func _store(url: String, body: PackedByteArray) -> bool:
	if body.size() < 4:
		return false
	var img := Image.new()
	# PNG files start with byte 0x89; everything else we request is JPEG.
	var err := img.load_png_from_buffer(body) if body[0] == 0x89 else img.load_jpg_from_buffer(body)
	if err != OK:
		return false
	_cache[url] = ImageTexture.create_from_image(img)
	queue_redraw()
	return true


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, r: HTTPRequest) -> void:
	var url: String = _busy.get(r, "")
	_busy.erase(r)
	_pending.erase(url)
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and _store(url, body):
		if _use_disk:
			var f := FileAccess.open(_disk_path(url), FileAccess.WRITE)
			if f != null:
				f.store_buffer(body)
	else:
		_failed[url] = Time.get_ticks_msec()
	_pump()


func _evict() -> void:
	if _cache.size() <= MAX_CACHE:
		return
	var keep := {}
	for t in _needed:
		keep[tile_url(t.z, t.x, t.y)] = true
	# Dictionaries keep insertion order, so this drops the oldest tiles first.
	for url in _cache.keys():
		if not keep.has(url) and not _pinned.has(url):
			_cache.erase(url)
		if _cache.size() <= MAX_CACHE * 2 / 3:
			break


func _draw() -> void:
	for t in _needed:
		var ts := Mercator.WORLD / (1 << t.z)
		var rect := Rect2(t.x * ts, t.y * ts, ts, ts)
		var url := tile_url(t.z, t.x, t.y)
		if _cache.has(url):
			draw_texture_rect(_cache[url], rect, false, tint)
			continue
		# Fall back to the nearest loaded parent tile, cropped to this tile's part of it.
		for k in range(1, t.z):
			var purl := tile_url(t.z - k, t.x >> k, t.y >> k)
			if _cache.has(purl):
				var tex: ImageTexture = _cache[purl]
				var part := tex.get_width() / float(1 << k)
				var src := Rect2((t.x - ((t.x >> k) << k)) * part, (t.y - ((t.y >> k) << k)) * part, part, part)
				draw_texture_rect_region(tex, rect, src, tint)
				break
