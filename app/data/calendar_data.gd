## Loads the burning calendar, fire events and risk outlook, and sums them over an area.
## Pure logic (no nodes), so it can be tested headless.
## Files come from pipeline/export_app_data.py.
extends RefCounted

const FIRST_YEAR := 2000
const OUTLOOK_YEAR := 2027
const BASELINE_YEARS := [2001, 2025]  # same-month baseline for "unusual" flags
const UNUSUAL_PERCENTILE := 0.9

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


func load_all(dir: String = "res://datasets") -> bool:
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


static func _read_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("can't open " + path)
		return null
	return JSON.parse_string(f.get_as_text())
