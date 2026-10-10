extends Control

# A line of small ink lettering at the bottom left for the first seconds of the
# sandbox -- the keys the demo answers to (Track A, proposed) -- then it fades.
# Never takes a click. With a `headline` (a scenario's briefing) the card has a second,
# larger line above the keys: what the game is about.
#
#   hint.headline = "INTERCEPT - ..."  # optional
#   hint.setup(style, "F2 knobs   Esc menu ...", 14.0)
#   hint.start()                      # when the map is playable

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

const FADE_S := 3.0

var style: UiStyle = null
var text := ""
var headline := ""
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
	var head_px: float = px + 2.0
	var head_w := UiInk.text_width(style.font(false), headline, head_px) if headline != "" else 0.0
	var h := px + 14.0 + (head_px + 8.0 if headline != "" else 0.0)
	var r := Rect2(Vector2(m, size.y - m - h), Vector2(maxf(w, head_w) + 20.0, h))
	var fill: Color = style.color("card_fill")
	fill.a *= a * 0.9
	draw_rect(r, fill, true)
	var y := r.position.y
	if headline != "":
		var head_ink: Color = style.color("ink")
		head_ink.a *= a
		UiInk.text(self, style.font(false), Vector2(r.position.x + 10.0, y + head_px + 4.0), headline, head_px, head_ink)
		y += head_px + 8.0
	UiInk.text(self, font, Vector2(r.position.x + 10.0, y + px + 3.0), text, px, ink)
