extends Control

# A line of small ink lettering at the bottom left for the first seconds of the
# sandbox -- the keys the demo answers to (Track A, proposed) -- then it fades.
# Never takes a click.
#
#   hint.setup(style, "F2 knobs   Esc menu ...", 14.0)
#   hint.start()                      # when the map is playable

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

const FADE_S := 3.0

var style: UiStyle = null
var text := ""
var show_s := 14.0
var _t := -1.0

func setup(st: RefCounted, line: String, seconds: float) -> void:
	style = st as UiStyle
	text = line
	show_s = seconds
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

func start() -> void:
	_t = 0.0
	queue_redraw()

func _process(delta: float) -> void:
	if _t < 0.0 or _t > show_s:
		return
	_t += delta
	queue_redraw()

func _draw() -> void:
	if style == null or _t < 0.0 or _t > show_s:
		return
	var a := clampf((show_s - _t) / FADE_S, 0.0, 1.0)
	var ink: Color = style.color("ink_soft")
	ink.a *= a
	var font: Font = style.font(true)
	var px: float = style.num("fonts.detail_px")
	var w := UiInk.text_width(font, text, px)
	var m: float = style.num("card.margin_px")
	var r := Rect2(Vector2(m, size.y - m - px - 12.0), Vector2(w + 20.0, px + 14.0))
	var fill: Color = style.color("card_fill")
	fill.a *= a * 0.9
	draw_rect(r, fill, true)
	UiInk.text(self, font, Vector2(r.position.x + 10.0, r.position.y + px + 3.0), text, px, ink)
