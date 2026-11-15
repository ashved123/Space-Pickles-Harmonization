## Draws fire outlines, the harmonized 25 km burning grid and the outlook grid in world coordinates.
## Redraw only when filters or the zoom change (line widths are kept constant on screen).
extends Node2D

const Mercator = preload("res://map/mercator.gd")

const FIRE_LINE := Color("#f0efec")
const FIRE_FILL := Color(0.94, 0.94, 0.92, 0.10)
const FIRE_SELECTED := Color("#ec835a")
const BLUES: Array[Color] = [Color("#0d366b"), Color("#184f95"), Color("#256abf"), Color("#3987e5"),
	Color("#6da7ec"), Color("#9ec5f4"), Color("#cde2fb")]
# Burning (observed / harmonized) uses a heat scale everywhere: dark red = little, through red and
# orange to bright yellow = most. (A red-to-pale-pink ramp read as "washed out = low" at the top.)
# The outlook is blue so the two can't be mixed up.
const HEAT: Array[Color] = [Color("#3d0c0c"), Color("#7a1414"), Color("#b3201a"), Color("#e0401a"),
	Color("#f47a1c"), Color("#fbb62e"), Color("#ffe97a")]
const ORANGES: Array[Color] = [Color("#4a1f0d"), Color("#7a3415"), Color("#b14a1e"), Color("#eb6834"),
	Color("#f29a73"), Color("#f8c7b0")]

var screen_scale := 1.0
var fires: Array = []            # fire dicts with "hull_world": PackedVector2Array
var selected_fire := {}
var grid_cells: Array = []       # [Rect2 world, value]
var grid_max := 1.0
var outlook_cells: Array = []    # [Rect2 world, probability]
var outline_rings: Array = []    # region outline (PackedVector2Array per ring)


func _draw() -> void:
	var px := 1.0 / screen_scale
	for ring in outline_rings:
		var closed: PackedVector2Array = ring.duplicate()
		closed.append(ring[0])
		draw_polyline(closed, Color(0.76, 0.76, 0.72, 0.9), 1.2 * px, true)
	for g in grid_cells:
		var t := log(1.0 + float(g[1])) / log(1.0 + grid_max)
		var c := _ramp(HEAT, t)
		c.a = 0.55
		draw_rect(g[0], c)
	for g in outlook_cells:
		var c := _ramp(BLUES, clampf(float(g[1]) / 0.4, 0.0, 1.0))
		c.a = 0.55
		draw_rect(g[0], c)
		draw_rect(g[0], Color(BLUES[4], 0.6), false, px)
	for f in fires:
		var hull: PackedVector2Array = f.hull_world
		if hull.size() < 3:
			continue
		var sel: bool = not selected_fire.is_empty() and f.id == selected_fire.get("id", "")
		if f.get("fillable", false):
			draw_colored_polygon(hull, FIRE_FILL)
		var ring := hull.duplicate()
		ring.append(hull[0])
		draw_polyline(ring, FIRE_SELECTED if sel else FIRE_LINE, (3.0 if sel else 1.5) * px, true)


static func _ramp(colors: Array[Color], t: float) -> Color:
	t = clampf(t, 0.0, 1.0) * (colors.size() - 1)
	var i := mini(int(floor(t)), colors.size() - 2)
	return colors[i].lerp(colors[i + 1], t - i)
