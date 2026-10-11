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
	var ink: Color = style.color("ink")   # (Track L, readable lettering: the keys are full ink in the label face at 14 px, not the soft thin italic)
	ink.a *= a
	var font: Font = style.text_font()
	var serif: Font = style.font(false)
	var px: float = style.num("fonts.detail_px")
	var m: float = style.num("card.margin_px")
	var head_px: float = px + 2.0
	# At the size the words are read at the briefing and the keys are longer than the map's free width: they wrap, and the card
	# stays clear of the sidebar column on the right.
	var max_w: float = maxf(size.x - 2.0 * m - (style.num("roster.width_px") + 2.0 * m) - 20.0, 320.0)
	var keys := UiInk.wrap(font, text, px, max_w)
	var heads := UiInk.wrap(serif, headline, head_px, max_w) if headline != "" else PackedStringArray()
	var key_h := px + 5.0
	var head_h := head_px + 6.0
	var w := 0.0
	for ln: String in keys:
		w = maxf(w, UiInk.text_width(font, ln, px))
	for ln: String in heads:
		w = maxf(w, UiInk.text_width(serif, ln, head_px))
	var h := 12.0 + key_h * float(keys.size()) + head_h * float(heads.size())
	var r := Rect2(Vector2(m, size.y - m - style.num("lettering.stamp.clear_px") - h), Vector2(w + 20.0, h))
	var fill: Color = style.color("card_fill")
	fill.a *= a * 0.9
	draw_rect(r, fill, true)
	var y := r.position.y + 4.0
	var head_ink: Color = style.color("ink")
	head_ink.a *= a
	for ln: String in heads:
		UiInk.text(self, serif, Vector2(r.position.x + 10.0, y + head_px), ln, head_px, head_ink)
		y += head_h
	for ln: String in keys:
		UiInk.text(self, font, Vector2(r.position.x + 10.0, y + px), ln, px, ink)
		y += key_h
