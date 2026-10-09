extends Control

# THE KNOB PANEL (Track A, PROPOSED): F2 opens a small card of the demo's live
# knobs, in Track U's card style -- not a debug console. One row per knob: its
# label and its value; a left click steps to the next value, a right click to the
# previous one, and the change is live (the map scale redraws the map, 8-11 s,
# with no restart). A value reads "2 (data)" while the knob is on "data": what
# the data files say.
#
# The values live in the DebugSettings autoload (scripts/debug/debug_settings.gd,
# section "Sandbox"), so INKWOOD_<KEY> drives each from the command line; the
# panel only reads and writes them through the sandbox:
#
#   knobs.setup(sandbox, style)       # sandbox: knob_keys(), knob_label(key), knob_text(key),
#                                     #          knob_step(key, +1 | -1), frame_line()
#   knobs.toggle()                    # F2

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

const WIDTH := 330.0
const ROW_H := 27.0
const HEADER_H := 40.0
const FOOT_H := 52.0

var sandbox: Object = null
var style: UiStyle = null
var keys: Array[String] = []

func setup(sb: Object, st: RefCounted) -> void:
	sandbox = sb
	style = st as UiStyle
	keys = sb.knob_keys()
	mouse_filter = Control.MOUSE_FILTER_STOP
	size = Vector2(WIDTH, HEADER_H + ROW_H * float(keys.size()) + FOOT_H)
	custom_minimum_size = size
	position = Vector2(style.num("card.margin_px"), style.num("card.margin_px"))
	visible = false
	DebugSettings.changed.connect(func(_k: String, _v: Variant) -> void: queue_redraw())

func toggle() -> void:
	visible = not visible
	queue_redraw()

func row_rect(i: int) -> Rect2:
	var pad: float = style.num("card.pad_px") * 0.5
	return Rect2(Vector2(pad, HEADER_H + ROW_H * float(i)), Vector2(size.x - 2.0 * pad, ROW_H))

func row_at(p: Vector2) -> int:
	for i in keys.size():
		if row_rect(i).has_point(p):
			return i
	return -1

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT):
			var i := row_at(mb.position)
			if i >= 0:
				sandbox.knob_step(keys[i], 1 if mb.button_index == MOUSE_BUTTON_LEFT else -1)
				accept_event()

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()   # the frame-time line moves

func _draw() -> void:
	if style == null or sandbox == null:
		return
	var ink: Color = style.color("ink")
	var soft: Color = style.color("ink_soft")
	var faint: Color = style.color("ink_faint")
	var r := Rect2(Vector2.ZERO, size)
	UiInk.card_shadow(self, r, style.shadow_dir() * style.num("card.lift_px"), style.color("card_shadow"))
	UiInk.card(self, r, style.color("card_fill"), ink, style.num("card.outer_line_px"), style.num("card.inner_line_px"),
		style.num("card.inner_inset_px"), style.num("card.wobble_px"), 41)
	var serif: Font = style.font(false)
	var italic: Font = style.font(true)
	var pad: float = style.num("card.pad_px")
	UiInk.text(self, serif, Vector2(pad, 26.0), "K N O B S", style.num("fonts.title_px"), ink)
	UiInk.text(self, italic, Vector2(0.0, 26.0), "F2 closes", style.num("fonts.detail_px"), soft, HORIZONTAL_ALIGNMENT_RIGHT, size.x - pad)
	UiInk.ink_line(self, PackedVector2Array([Vector2(pad, 34.0), Vector2(size.x - pad, 34.0)]), false, faint, 0.8, 11, 0.4)
	for i in keys.size():
		var rr := row_rect(i)
		var k := keys[i]
		var base := rr.position.y + rr.size.y * 0.5 + style.num("fonts.name_px") * 0.34
		UiInk.text(self, serif, Vector2(rr.position.x + 6.0, base), sandbox.knob_label(k), style.num("fonts.button_px") + 1.0, ink)
		var is_data: bool = DebugSettings.get_choice(k) == 0
		UiInk.text(self, italic, Vector2(rr.position.x, base), sandbox.knob_text(k), style.num("fonts.detail_px") + 1.0,
			soft if is_data else ink, HORIZONTAL_ALIGNMENT_RIGHT, rr.size.x - 6.0)
		if i < keys.size() - 1:
			draw_line(Vector2(rr.position.x + 6.0, rr.end.y), Vector2(rr.end.x - 6.0, rr.end.y), faint, 0.5, true)
	var fy := HEADER_H + ROW_H * float(keys.size()) + 18.0
	UiInk.text(self, italic, Vector2(pad, fy), "click: next value   right click: back", style.num("fonts.small_px"), soft)
	UiInk.text(self, italic, Vector2(pad, fy + 17.0), sandbox.frame_line(), style.num("fonts.small_px"), soft)
