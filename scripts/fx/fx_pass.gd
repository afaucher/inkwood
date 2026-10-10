extends Node2D

# One draw pass of the FxLayer (ground, air, top): a Node2D whose _draw asks the
# layer to paint its kind. The layer owns the state; a pass only holds the canvas.

var layer = null   # whatever paints: an FxLayer, or the board's plane proxy (draw_pass(item, kind))
var kind: String = ""

func _draw() -> void:
	if layer != null and is_instance_valid(layer):
		layer.draw_pass(self, kind)
