extends Node2D

# A SCREEN-SPACE NODE IN THE MAP'S CANVAS (builder, map-border board, 2026-10-11; PROPOSED). Its transform is kept at the inverse
# of the camera's, so what its `painter` draws is in SCREEN px, whole pixels where the painter rounds, at every zoom: the way to
# put a rule of a fixed width or a line of lettering at a place on the map without a CanvasLayer (whose order against the
# unit interface's layers 1 and 2 would be left to chance). The painter is called by _draw, i.e. when something calls
# repaint(): the option does it when the camera or the viewport changes, never otherwise.
#
# z_index 3: over the fill (1) and whatever the option draws under it (2).

var painter: Callable = Callable()

func _init() -> void:
	name = "Screen"
	z_index = 3

# Pins the node: `canvas` is the transform from the MapView's parent space to screen px (the viewport's canvas transform).
func pin(canvas: Transform2D) -> void:
	global_transform = canvas.affine_inverse()

func repaint() -> void:
	queue_redraw()

func _draw() -> void:
	if painter.is_valid():
		painter.call(self)
