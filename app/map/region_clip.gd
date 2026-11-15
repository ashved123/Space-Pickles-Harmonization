## Draws the region (California) as filled polygons and clips its children to that shape,
## so map tiles only show inside the state.
extends Node2D

var rings: Array = []  # PackedVector2Array per ring, world coordinates


func _init() -> void:
	clip_children = CanvasItem.CLIP_CHILDREN_ONLY


func _draw() -> void:
	for ring in rings:
		if ring.size() >= 3:
			draw_colored_polygon(ring, Color.WHITE)
