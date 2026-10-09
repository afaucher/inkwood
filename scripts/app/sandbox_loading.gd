extends Control

# "Drawing the map..." -- the inked card shown while the first view bakes (a
# blocking card on a paper backdrop: nothing can be clicked until the map is
# there to plan on) and, smaller and out of the way, while a knob change
# redraws the map (a note at the top: the game stays playable, the map fills
# in). In Track U's card style (data/ui/ui.json), so it reads as part of the UI.
#
#   var card := SandboxLoading.new()
#   layer.add_child(card)                    # a CanvasLayer above everything
#   card.setup(style, true)                  # blocking
#   card.set_progress(done, total, seconds)  # a line of ink fills as chunks bake

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

var style: UiStyle = null
var blocking := true
var title := "Drawing the map…"
var done := 0
var total := 0
var seconds := 0.0
var seed_text: Variant = ""

func setup(st: RefCounted, is_blocking: bool, text: String = "") -> void:
	style = st as UiStyle
	blocking = is_blocking
	if text != "":
		title = text
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP if blocking else Control.MOUSE_FILTER_IGNORE
	queue_redraw()

func set_progress(d: int, t: int, secs: float) -> void:
	done = d
	total = t
	seconds = secs
	queue_redraw()

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()

func _draw() -> void:
	if style == null:
		return
	var ink: Color = style.color("ink")
	var soft: Color = style.color("ink_soft")
	var faint: Color = style.color("ink_faint")
	if blocking:
		draw_rect(Rect2(Vector2.ZERO, size), style.color("map_paper"), true)
	var w := 340.0 if blocking else 300.0
	var h := 126.0 if blocking else 64.0
	var r := Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5 if blocking else 18.0), Vector2(w, h))
	UiInk.card_shadow(self, r, style.shadow_dir() * style.num("card.lift_px"), style.color("card_shadow"))
	UiInk.card(self, r, style.color("card_fill"), ink, style.num("card.outer_line_px"), style.num("card.inner_line_px"),
		style.num("card.inner_inset_px"), style.num("card.wobble_px"), 31)
	var serif: Font = style.font(false)
	var italic: Font = style.font(true)
	var pad: float = style.num("card.pad_px")
	var ty := r.position.y + (40.0 if blocking else 28.0)
	UiInk.text(self, serif, Vector2(r.position.x, ty), title, style.num("fonts.title_px") + (4.0 if blocking else 0.0), ink,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	# A line of ink that fills as the chunks come in; before the first chunk, a short stroke that travels.
	var x0 := r.position.x + pad + 6.0
	var x1 := r.end.x - pad - 6.0
	var y := ty + (22.0 if blocking else 16.0)
	UiInk.ink_line(self, PackedVector2Array([Vector2(x0, y), Vector2(x1, y)]), false, faint, 0.8, 7, 0.5)
	if total > 0:
		var f := clampf(float(done) / float(total), 0.0, 1.0)
		if f > 0.0:
			UiInk.ink_line(self, PackedVector2Array([Vector2(x0, y), Vector2(lerpf(x0, x1, f), y)]), false, ink, 2.0, 9, 0.8)
	else:
		var u := fmod(Time.get_ticks_msec() / 1000.0, 1.6) / 1.6
		var a := lerpf(x0, x1 - 40.0, u)
		UiInk.ink_line(self, PackedVector2Array([Vector2(a, y), Vector2(a + 40.0, y)]), false, ink, 2.0, 9, 0.8)
	var detail := "%d of %d pieces" % [done, total] if total > 0 else "starting"
	if blocking:
		detail += "  ·  %.0f s" % seconds
		UiInk.text(self, italic, Vector2(r.position.x, y + 26.0), detail, style.num("fonts.detail_px"), soft,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		UiInk.text(self, italic, Vector2(r.position.x, y + 44.0), "the same map every time: seed %s" % str(seed_text),
			style.num("fonts.small_px"), faint, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
