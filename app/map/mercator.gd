## Web Mercator helpers (the projection NASA GIBS and other web maps use).
## "World" coordinates are pixels at zoom ZREF: x, y in [0, WORLD).
extends RefCounted

const ZREF := 12
const WORLD := 256.0 * 4096.0  # 256 px tiles * 2^ZREF
const EARTH_CIRCUMFERENCE_M := 40075016.686


static func to_world(lat: float, lon: float) -> Vector2:
	var phi := deg_to_rad(clampf(lat, -85.05, 85.05))
	var x := (lon + 180.0) / 360.0 * WORLD
	var y := (1.0 - log(tan(phi) + 1.0 / cos(phi)) / PI) / 2.0 * WORLD
	return Vector2(x, y)


## Returns Vector2(lat, lon).
static func to_latlon(p: Vector2) -> Vector2:
	var lon := p.x / WORLD * 360.0 - 180.0
	var lat := rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * p.y / WORLD))))
	return Vector2(lat, lon)


## World pixels per metre on the ground at a latitude.
static func world_per_metre(lat: float) -> float:
	return WORLD / EARTH_CIRCUMFERENCE_M / cos(deg_to_rad(lat))


## Screen scale for a (fractional) zoom level: world px -> screen px.
static func scale_for_zoom(zoom: float) -> float:
	return pow(2.0, zoom - ZREF)
