extends "res://scripts/render/ink_canvas.gd"

# An InkCanvas that also keeps the polylines drawn on it (move_to / line_to, in
# user units, before the transform), so a test can check WHERE a routine drew
# without rendering a frame. It records and paints exactly as InkCanvas does, so
# it can be passed anywhere an InkCanvas is typed (fx_ruin.gd's hatch).
#
#   var rec := RecordingCanvas.new(Vector2i(256, 256))
#   UnitMarkerArt.hatch_lines(rec, ink, outline, dir, sp, {})
#   for part: PackedVector2Array in rec.lines: ...
#
# clear_lines() forgets what was recorded (the paint calls stay).

var lines: Array[PackedVector2Array] = []
var _open := PackedVector2Array()

func _init(canvas_size: Vector2i = Vector2i(256, 256)) -> void:
	super(canvas_size)

func clear_lines() -> void:
	lines.clear()
	_open = PackedVector2Array()

func begin_path() -> void:
	_end_line()
	super()

func move_to(x: float, y: float) -> void:
	_end_line()
	_open.push_back(Vector2(x, y))
	super(x, y)

func line_to(x: float, y: float) -> void:
	_open.push_back(Vector2(x, y))
	super(x, y)

func stroke() -> void:
	_end_line()
	super()

func fill() -> void:
	_end_line()
	super()

func _end_line() -> void:
	if _open.size() >= 2:
		lines.append(_open)
	_open = PackedVector2Array()
