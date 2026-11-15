## Loads per-year hotspot files (app/datasets/hotspots/<year>.bin, written by
## pipeline/export_app_data.py) and filters them. Pure logic, no nodes.
## Record (10 bytes, little-endian): u16 lat_q, u16 lon_q, u16 day_of_year, u16 frp_mw,
## u8 sensor (0 MODIS, 1 VIIRS S-NPP, 2 VIIRS NOAA-20), u8 hour_utc.
extends RefCounted

const Mercator = preload("res://map/mercator.gd")
const SENSOR_NAMES := ["MODIS", "VIIRS S-NPP", "VIIRS NOAA-20"]

var dir := "res://datasets/hotspots"
var lat0 := 32.0
var lat_span := 10.5
var lon0 := -125.0
var lon_span := 11.5
var years := {}            # year -> count, from index.json

var year := 0              # currently loaded year
var pos := PackedVector2Array()   # world coordinates
var doy := PackedInt32Array()
var frp := PackedInt32Array()
var sensor := PackedByteArray()
var hour := PackedByteArray()


func load_index() -> bool:
	var f := FileAccess.open(dir + "/index.json", FileAccess.READ)
	if f == null:
		return false
	var idx = JSON.parse_string(f.get_as_text())
	lat0 = idx.format.lat0
	lat_span = idx.format.lat_span
	lon0 = idx.format.lon0
	lon_span = idx.format.lon_span
	for k in idx.years:
		years[int(k)] = int(idx.years[k])
	return true


func load_year(y: int) -> bool:
	if y == year:
		return true
	var path := "%s/%d.bin" % [dir, y]
	if not FileAccess.file_exists(path):
		year = y
		pos.clear()
		doy.clear()
		frp.clear()
		sensor.clear()
		hour.clear()
		return false
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 8 or b.slice(0, 4).get_string_from_ascii() != "HSP1":
		return false
	var n := b.decode_u32(4)
	pos.resize(n)
	doy.resize(n)
	frp.resize(n)
	sensor.resize(n)
	hour.resize(n)
	var ks := lat_span / 65535.0
	var kl := lon_span / 65535.0
	for i in n:
		var o := 8 + i * 10
		pos[i] = Mercator.to_world(lat0 + b.decode_u16(o) * ks, lon0 + b.decode_u16(o + 2) * kl)
		doy[i] = b.decode_u16(o + 4)
		frp[i] = b.decode_u16(o + 6)
		sensor[i] = b[o + 8]
		hour[i] = b[o + 9]
	year = y
	return true


## Indices of detections with day_of_year in [d0, d1], FRP >= min_frp and a sensor in the mask
## (bit 0 MODIS, bit 1 S-NPP, bit 2 NOAA-20).
func filter(d0: int, d1: int, sensor_mask: int, min_frp: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in doy.size():
		var d := doy[i]
		if d < d0 or d > d1:
			continue
		if frp[i] < min_frp:
			continue
		if (sensor_mask >> sensor[i]) & 1 == 0:
			continue
		out.append(i)
	return out


func lat_lon(i: int) -> Vector2:
	return Mercator.to_latlon(pos[i])
