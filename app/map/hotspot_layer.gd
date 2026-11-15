## Draws many hotspots at once with a MultiMesh (one quad per detection, one draw call).
## The quad size is the sensor's pixel footprint, but never smaller than MIN_PX on screen.
extends MultiMeshInstance2D

const MIN_PX := 3.0

var footprint_world := 33.0  # sensor pixel size in world px (set by the map)
var _quad := QuadMesh.new()


func _init() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.mesh = _quad


## Rebuild instances for the given detection indices.
func build(positions: PackedVector2Array, indices: PackedInt32Array, color: Color) -> void:
	var n := indices.size()
	multimesh.instance_count = n
	if n == 0:
		return
	var buf := PackedFloat32Array()
	buf.resize(n * 12)
	var k := 0
	for i in indices:
		var p := positions[i]
		# 2D transform rows (x.x, y.x, pad, origin.x, x.y, y.y, pad, origin.y), then colour.
		buf[k] = 1.0
		buf[k + 1] = 0.0
		buf[k + 2] = 0.0
		buf[k + 3] = p.x
		buf[k + 4] = 0.0
		buf[k + 5] = 1.0
		buf[k + 6] = 0.0
		buf[k + 7] = p.y
		buf[k + 8] = color.r
		buf[k + 9] = color.g
		buf[k + 10] = color.b
		buf[k + 11] = color.a
		k += 12
	multimesh.buffer = buf


## Keep points visible when zoomed out: size = max(footprint, MIN_PX screen pixels).
func set_view_scale(screen_scale: float) -> void:
	var s := maxf(footprint_world, MIN_PX / screen_scale)
	_quad.size = Vector2(s, s)
