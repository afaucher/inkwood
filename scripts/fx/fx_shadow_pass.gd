extends CanvasGroup

# The effects' ground shadows, composited ONCE at the map's shadow strength as
# the unit markers' shadows are (unit_marker_layer.gd): every sprite is drawn in
# the opaque shadow tint inside this group and the group's self_modulate carries
# the strength, so overlapping shadows merge and never darken twice.

var layer = null   # whatever paints: an FxLayer, or the board's plane proxy (draw_pass(item, kind))

func _draw() -> void:
	if layer != null and is_instance_valid(layer):
		layer.draw_pass(self, "shadows")
