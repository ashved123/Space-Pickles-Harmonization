## Fills a SimRegion from public, keyless, CORS-enabled services (no backend of ours):
## fuel (LANDFIRE), elevation (Terrarium tiles), hourly weather (Open-Meteo ERA5) and an aerial
## background (USGS). All requests run in parallel; a failed one leaves the region's fallback
## (uniform shrub, flat ground, no weather) and the sim screen says so.
## Like the map tiles, requests don't use threads (HTTPRequest.use_threads stalled in testing).
extends Node

signal progress(done: int, total: int)
signal finished

var region
var _total := 0
var _done := 0
var _tiles := {}  # Vector2i(x, y) -> Image


func start(p_region) -> void:
	region = p_region
	_fetch(region.fuel_url(), _on_fuel)
	_fetch(region.weather_url(), _on_weather)
	_fetch(region.background_url(), _on_background)
	for tile in region.elevation_tiles():
		_fetch(region.elevation_tile_url(tile), _on_tile.bind(tile))


func _fetch(url: String, on_body: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 60.0
	add_child(http)
	_total += 1
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray):
		http.queue_free()
		on_body.call(body if result == HTTPRequest.RESULT_SUCCESS and code == 200 else PackedByteArray())
		_one_done())
	if http.request(url) != OK:
		http.queue_free()
		on_body.call(PackedByteArray())
		_one_done.call_deferred()


func _one_done() -> void:
	_done += 1
	progress.emit(_done, _total)
	if _done == _total:
		region.set_elevation_from_tiles(_tiles)
		finished.emit()


func _on_fuel(body: PackedByteArray) -> void:
	var img := Image.new()
	if not body.is_empty() and img.load_png_from_buffer(body) == OK:
		region.set_fuel_from_image(img)


func _on_weather(body: PackedByteArray) -> void:
	if not body.is_empty():
		region.set_weather_from_json(JSON.parse_string(body.get_string_from_utf8()))


func _on_background(body: PackedByteArray) -> void:
	var img := Image.new()
	if not body.is_empty() and img.load_jpg_from_buffer(body) == OK:
		region.background = img


func _on_tile(body: PackedByteArray, tile: Vector2i) -> void:
	var img := Image.new()
	if not body.is_empty() and img.load_png_from_buffer(body) == OK:
		_tiles[tile] = img
