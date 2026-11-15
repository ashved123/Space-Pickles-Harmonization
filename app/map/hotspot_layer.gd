## Draws many hotspots at once with a MultiMesh (one quad per detection, one draw call).
## Each quad carries a round dot texture, so detections show as circles. The circle's diameter
## is the sensor's pixel footprint, but never smaller than MIN_PX on screen.
extends MultiMeshInstance2D

const MIN_PX := 4.0
const DOT_PX := 64  # size of the dot texture

var footprint_world := 33.0  # sensor pixel size in world px (set by the map)
var _quad := QuadMesh.new()


func _init() -> void:
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	multimesh.mesh = _quad
	texture = _dot_texture()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## White disc with a soft edge; each instance's colour tints it.
static func _dot_texture() -> ImageTexture:
	var img := Image.create(DOT_PX, DOT_PX, false, Image.FORMAT_RGBA8)
	var mid := DOT_PX / 2.0
	for y in DOT_PX:
		for x in DOT_PX:
			var d := Vector2(x + 0.5 - mid, y + 0.5 - mid).length()
			img.set_pixel(x, y, Color(1, 1, 1, clampf(mid - 0.5 - d, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


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
