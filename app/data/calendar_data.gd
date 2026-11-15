## Loads the burning calendar, fire events and risk outlook, and sums them over an area.
## Pure logic (no nodes), so it can be tested headless.
## Files come from pipeline/export_app_data.py.
extends RefCounted

const FIRST_YEAR := 2000
const OUTLOOK_YEAR := 2027
const BASELINE_YEARS := [2001, 2025]  # same-month baseline for "unusual" flags
const UNUSUAL_PERCENTILE := 0.9
const OUTLOOK_HIGH := 0.25    # same levels as outlook.json
const OUTLOOK_MEDIUM := 0.08
const MONTH_WORDS := ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

var unit := ""
var months: PackedStringArray = []       # "YYYY-MM"
var kinds: PackedStringArray = []        # "observed" / "harmonized" per month
var sources: PackedStringArray = []
var preliminary: Array = []
var partial: Array = []
var cell_lat := PackedFloat32Array()
var cell_lon := PackedFloat32Array()
var last_year := 2026

# Dense cell x calendar slot values. Slot = (year - FIRST_YEAR) * 12 + (month - 1).
# NAN where there is no satellite record for that month.
var _values := PackedFloat32Array()
var _slot_has_data := PackedByteArray()
var _slot_month := PackedInt32Array()    # slot -> index into months, -1 if none

var fires: Array = []
var outlook_label := ""
var outlook_p: Array = []                # per cell: 12 probabilities
var outlook_info := {}

const SENSOR_NAMES := ["MODIS", "VIIRS S-NPP", "VIIRS NOAA-20"]  # sensor codes 0-2 in the hotspot files
const LOOKUP_N := 64                         # 64 x 64 cells of 0.25 degrees covers California
var _sensor_counts := PackedInt32Array()     # [sensor][cell][slot], filled by count_sensor_year()
var _sensor_first := [-1, -1, -1]            # first / last slot with any detection, per sensor
var _sensor_last := [-1, -1, -1]
var _sensor_done := false
var _cell_lookup := PackedInt32Array()       # 0.25 degree lat/lon box -> cell index, -1 if none


## `with_sensor_counts`: also load the per-satellite counts file (false to count from the hotspot files).
func load_all(dir: String = "res://datasets", with_sensor_counts: bool = true) -> bool:
	var cal = _read_json(dir + "/calendar.json")
	if cal == null:
		return false
	unit = cal.unit
	months = PackedStringArray(cal.months)
	kinds = PackedStringArray(cal.kind)
	sources = PackedStringArray(cal.source)
	preliminary = cal.preliminary
	partial = cal.partial
	for c in cal.cells:
		cell_lat.append(c[0])
		cell_lon.append(c[1])
	last_year = int(months[months.size() - 1].substr(0, 4))
	var slots := (last_year - FIRST_YEAR + 1) * 12
	_slot_has_data.resize(slots)
	_slot_has_data.fill(0)
	_slot_month.resize(slots)
	_slot_month.fill(-1)
	for i in months.size():
		var s := slot_of(months[i])
		_slot_has_data[s] = 1
		_slot_month[s] = i
	_values.resize(cell_count() * slots)
	_values.fill(0.0)
	var v: Array = cal.values
	for k in range(0, v.size(), 3):
		var mi: int = int(v[k + 1])
		_values[int(v[k]) * slots + slot_of(months[mi])] = v[k + 2]

	var f = _read_json(dir + "/fires.json")
	if f != null:
		fires = f.events
	var o = _read_json(dir + "/outlook.json")
	if o != null:
		outlook_label = o.label
		outlook_p = o.p
		outlook_info = o.get("validation_summary", {})
	if with_sensor_counts:
		load_sensor_counts(dir + "/sensor_counts.bin")
	return true


func cell_count() -> int:
	return cell_lat.size()


func year_count() -> int:
	return last_year - FIRST_YEAR + 1


func slot_of(ym: String) -> int:
	return (int(ym.substr(0, 4)) - FIRST_YEAR) * 12 + int(ym.substr(5, 2)) - 1


func has_data(year: int, month: int) -> bool:
	var s := (year - FIRST_YEAR) * 12 + month - 1
	return s >= 0 and s < _slot_has_data.size() and _slot_has_data[s] == 1


## Index into `months` for a year/month, or -1 if there is no record.
func month_index(year: int, month: int) -> int:
	var s := (year - FIRST_YEAR) * 12 + month - 1
	if s < 0 or s >= _slot_month.size():
		return -1
	return _slot_month[s]


## Area total for one month (sum over the selected cells). NAN if no record.
func area_value(cells: PackedInt32Array, year: int, month: int) -> float:
	if not has_data(year, month):
		return NAN
	var s := (year - FIRST_YEAR) * 12 + month - 1
	var slots := year_count() * 12
	var total := 0.0
	for c in cells:
		total += _values[c * slots + s]
	return total


func cell_value(cell: int, year: int, month: int) -> float:
	if not has_data(year, month):
		return NAN
	return _values[cell * year_count() * 12 + (year - FIRST_YEAR) * 12 + month - 1]


## Year x month grid for an area: Array of years, each a PackedFloat32Array(12).
func area_grid(cells: PackedInt32Array) -> Array:
	var grid := []
	for y in range(FIRST_YEAR, last_year + 1):
		var row := PackedFloat32Array()
		for m in range(1, 13):
			row.append(area_value(cells, y, m))
		grid.append(row)
	return grid


## Per calendar month, the value at UNUSUAL_PERCENTILE over the baseline years (complete months).
func unusual_thresholds(grid: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for m in 12:
		var vals := []
		for y in range(BASELINE_YEARS[0], BASELINE_YEARS[1] + 1):
			var v: float = grid[y - FIRST_YEAR][m]
			if not is_nan(v):
				vals.append(v)
		vals.sort()
		if vals.is_empty():
			out.append(INF)
		else:
			out.append(vals[mini(int(floor(UNUSUAL_PERCENTILE * vals.size())), vals.size() - 1)])
	return out


## Median per calendar month over the baseline years.
func baseline_medians(grid: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for m in 12:
		var vals := []
		for y in range(BASELINE_YEARS[0], BASELINE_YEARS[1] + 1):
			var v: float = grid[y - FIRST_YEAR][m]
			if not is_nan(v):
				vals.append(v)
		vals.sort()
		out.append(vals[vals.size() / 2] if not vals.is_empty() else NAN)
	return out


## Expected number of cells with notable burning per month in the outlook year.
func outlook_area(cells: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	out.fill(0.0)
	if outlook_p.is_empty():
		return out
	for c in cells:
		var p: Array = outlook_p[c]
		for m in 12:
			out[m] += p[m]
	return out


## Fire events whose centre is in the area and that were burning during year/month, largest first.
func fires_in(cells: PackedInt32Array, year: int, month: int) -> Array:
	var ym := "%04d-%02d" % [year, month]
	var keys := {}
	for c in cells:
		keys[_cell_key(cell_lat[c], cell_lon[c])] = true
	var out := []
	for f in fires:
		if f.start.substr(0, 7) > ym or f.end.substr(0, 7) < ym:
			continue
		if keys.has(_cell_key(_snap(f.lat), _snap(f.lon))):
			out.append(f)
	return out  # fires.json is already sorted by footprint


func cells_in_box(lat0: float, lon0: float, lat1: float, lon1: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c in cell_count():
		if cell_lat[c] >= minf(lat0, lat1) and cell_lat[c] <= maxf(lat0, lat1) \
				and cell_lon[c] >= minf(lon0, lon1) and cell_lon[c] <= maxf(lon0, lon1):
			out.append(c)
	return out


func all_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	for c in cell_count():
		out.append(c)
	return out


func cell_at(lat: float, lon: float) -> int:
	for c in cell_count():
		if absf(cell_lat[c] - lat) <= 0.125 and absf(cell_lon[c] - lon) <= 0.125:
			return c
	return -1


## Cell centre (0.125 + k*0.25) for a coordinate.
static func _snap(x: float) -> float:
	return floor(x / 0.25) * 0.25 + 0.125


static func _cell_key(lat: float, lon: float) -> String:
	return "%.3f,%.3f" % [lat, lon]


# ---------- raw detections per satellite ----------
# Counted from the per-year hotspot files (the map's data), not from the harmonized series:
# these are raw detection counts, so MODIS (1 km pixels) and VIIRS (375 m) are NOT comparable.

## Counts one year of detections per sensor, cell and month. Call once for every year from
## FIRST_YEAR to last_year, in order (the big years take a moment, so spread them over frames).
func count_sensor_year(y: int, dir: String = "res://datasets/hotspots") -> void:
	if _sensor_done:
		return  # already loaded from the counts file
	var slots := year_count() * 12
	var cells := cell_count()
	if _sensor_counts.is_empty():
		_sensor_counts.resize(SENSOR_NAMES.size() * cells * slots)
		_sensor_counts.fill(0)
		_cell_lookup.resize(LOOKUP_N * LOOKUP_N)
		_cell_lookup.fill(-1)
		for c in cells:
			_cell_lookup[_lookup_index(cell_lat[c], cell_lon[c])] = c
	var fmt = _read_json(dir + "/index.json")
	var path := "%s/%d.bin" % [dir, y]
	if fmt != null and FileAccess.file_exists(path):
		var b := FileAccess.get_file_as_bytes(path)
		if b.size() >= 8 and b.slice(0, 4).get_string_from_ascii() == "HSP1":
			var lat0: float = fmt.format.lat0
			var lon0: float = fmt.format.lon0
			var ks: float = fmt.format.lat_span / 65535.0
			var kl: float = fmt.format.lon_span / 65535.0
			# Day of year -> month (1-12) for this year.
			var month_of := PackedByteArray()
			month_of.resize(367)
			var d := 1
			for m in range(1, 13):
				for _i in days_in_month(y, m):
					month_of[d] = m
					d += 1
			for i in b.decode_u32(4):
				var o := 8 + i * 10
				var c := _cell_lookup[_lookup_index(lat0 + b.decode_u16(o) * ks, lon0 + b.decode_u16(o + 2) * kl)]
				var month: int = month_of[mini(b.decode_u16(o + 4), 366)]
				var s: int = b[o + 8]
				if c < 0 or month == 0 or s >= SENSOR_NAMES.size():
					continue
				var slot := (y - FIRST_YEAR) * 12 + month - 1
				_sensor_counts[(s * cells + c) * slots + slot] += 1
				if _sensor_first[s] < 0 or slot < _sensor_first[s]:
					_sensor_first[s] = slot
				_sensor_last[s] = maxi(_sensor_last[s], slot)
	if y >= last_year:
		_sensor_done = true


## Loads the per-satellite counts made ahead of time by build_sensor_counts.gd. Counting 2.4 million
## detections in a browser takes over 20 s, so the app ships the result: a few hundred KB, instant.
## False if the file is missing or doesn't match this calendar (other cells or years); the app then
## counts from the hotspot files instead. File format: "SNC1", u32 cells, u32 slots, u32 sensors,
## u32 raw size, then per sensor s32 first slot and s32 last slot, then the int32 counts
## [sensor][cell][slot] compressed with deflate.
func load_sensor_counts(path: String = "res://datasets/sensor_counts.bin") -> bool:
	if not FileAccess.file_exists(path):
		return false
	var b := FileAccess.get_file_as_bytes(path)
	var n := SENSOR_NAMES.size()
	var header := 20 + n * 8
	if b.size() < header or b.slice(0, 4).get_string_from_ascii() != "SNC1":
		return false
	var slots := year_count() * 12
	var raw_size := b.decode_u32(16)
	if b.decode_u32(4) != cell_count() or b.decode_u32(8) != slots or b.decode_u32(12) != n \
			or raw_size != n * cell_count() * slots * 4:
		return false
	var body := b.slice(header).decompress(raw_size, FileAccess.COMPRESSION_DEFLATE)
	if body.size() != raw_size:
		return false
	_sensor_counts = body.to_int32_array()
	for i in n:
		_sensor_first[i] = b.decode_s32(20 + i * 8)
		_sensor_last[i] = b.decode_s32(24 + i * 8)
	_sensor_done = true
	return true


## Writes the counts file (see load_sensor_counts). Counts must be complete (every year counted).
func save_sensor_counts(path: String = "res://datasets/sensor_counts.bin") -> bool:
	if not _sensor_done:
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var body := _sensor_counts.to_byte_array()
	f.store_buffer("SNC1".to_ascii_buffer())
	f.store_32(cell_count())
	f.store_32(year_count() * 12)
	f.store_32(SENSOR_NAMES.size())
	f.store_32(body.size())
	for i in SENSOR_NAMES.size():
		f.store_32(_sensor_first[i] & 0xFFFFFFFF)
		f.store_32(_sensor_last[i] & 0xFFFFFFFF)
	f.store_buffer(body.compress(FileAccess.COMPRESSION_DEFLATE))
	f.close()
	return true


## True once every year has been counted.
func sensor_ready() -> bool:
	return _sensor_done


## Whether a sensor has any detections on record by that month (between its first and last).
func sensor_has_record(sensor: int, year: int, month: int) -> bool:
	var slot := (year - FIRST_YEAR) * 12 + month - 1
	return _sensor_first[sensor] >= 0 and slot >= _sensor_first[sensor] and slot <= _sensor_last[sensor]


## Raw detections of one sensor in a cell and month. NAN outside the sensor's record.
func sensor_cell_value(sensor: int, cell: int, year: int, month: int) -> float:
	if not sensor_has_record(sensor, year, month):
		return NAN
	return _sensor_counts[(sensor * cell_count() + cell) * year_count() * 12 + (year - FIRST_YEAR) * 12 + month - 1]


## Year x month grid of one sensor's raw detections over an area, shaped like area_grid().
func sensor_area_grid(sensor: int, cells: PackedInt32Array) -> Array:
	var slots := year_count() * 12
	var grid := []
	for y in range(FIRST_YEAR, last_year + 1):
		var row := PackedFloat32Array()
		for m in range(1, 13):
			if not sensor_has_record(sensor, y, m):
				row.append(NAN)
				continue
			var slot := (y - FIRST_YEAR) * 12 + m - 1
			var total := 0
			for c in cells:
				total += _sensor_counts[(sensor * cell_count() + c) * slots + slot]
			row.append(total)
		grid.append(row)
	return grid


## Slot in _cell_lookup for a coordinate: the 0.25 degree cell it falls in.
static func _lookup_index(lat: float, lon: float) -> int:
	var li := clampi(int(floor(lat / 0.25)) - 120, 0, LOOKUP_N - 1)   # from 30 N
	var lo := clampi(int(floor(lon / 0.25)) + 512, 0, LOOKUP_N - 1)   # from 128 W
	return li * LOOKUP_N + lo


static func days_in_month(y: int, m: int) -> int:
	if m == 2:
		return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
	return 30 if m in [4, 6, 9, 11] else 31


## Reads a typed date: a year ("2031"), a month ("2031-09", "9/2031", "Sep 2031", "september")
## or a day ("2031-09-15", "9/15/2031", "15 Sep 2031"). A year needs 4 digits; other numbers
## are month then day (swapped when only day-first makes sense).
## Returns {year, month, day} with 0 for the parts not given, or {} if it can't be read.
static func parse_date_query(text: String) -> Dictionary:
	var year := 0
	var month := 0
	var day := 0
	var has_month := false
	var nums: Array[int] = []
	var cleaned := text.to_lower()
	for ch in [",", ".", "/", "-"]:
		cleaned = cleaned.replace(ch, " ")
	for word in cleaned.split(" ", false):
		var tok: String = word
		for suffix in ["st", "nd", "rd", "th"]:  # 15th, 1st
			if tok.ends_with(suffix) and tok.trim_suffix(suffix).is_valid_int():
				tok = tok.trim_suffix(suffix)
		if tok.is_valid_int():
			if tok.length() == 4 and year == 0:
				year = int(tok)
			else:
				nums.append(int(tok))
		else:
			month = _month_from_word(tok)
			if month == 0 or has_month:
				return {}
			has_month = true
	if not has_month and not nums.is_empty():
		if nums.size() == 2 and nums[0] > 12 and nums[1] <= 12:
			nums.reverse()  # day first, e.g. 15/9/2031
		month = nums.pop_front()
		has_month = true
	if not nums.is_empty():
		day = nums.pop_front()
		if day < 1:
			return {}
	if not nums.is_empty() or (year == 0 and not has_month):
		return {}
	if has_month and (month < 1 or month > 12):
		return {}
	if year != 0 and (year < 1900 or year > 2200):
		return {}
	# Without a year, allow 29 Feb.
	if day > days_in_month(year if year != 0 else 2028, maxi(month, 1)):
		return {}
	return {"year": year, "month": month, "day": day}


## 1-12 for a month name or a prefix of it of 3+ letters ("sep", "sept", "september"), else 0.
static func _month_from_word(word: String) -> int:
	if word.length() < 3:
		return 0
	for i in MONTH_WORDS.size():
		if MONTH_WORDS[i].begins_with(word):
			return i + 1
	return 0


## Outlook over all cells for a month (1-12), or for each cell's peak month (0):
## {expected: cells expected to have notable burning, high: cells at High, medium: at Medium}.
func outlook_summary(month: int) -> Dictionary:
	var expected := 0.0
	var high := 0
	var medium := 0
	for p in outlook_p:
		var v: float = p[month - 1] if month > 0 else p.max()
		expected += v
		if v >= OUTLOOK_HIGH:
			high += 1
		elif v >= OUTLOOK_MEDIUM:
			medium += 1
	return {"expected": expected, "high": high, "medium": medium}


static func _read_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("can't open " + path)
		return null
	return JSON.parse_string(f.get_as_text())
