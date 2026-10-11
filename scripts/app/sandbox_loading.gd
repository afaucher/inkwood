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
#   card.set_pool_progress(done, total, share) # ... and as the global tree set is made (Track P2: first in line, a few seconds)
#   card.set_fog_progress(done, total, share)  # ... and as the fog's contour map is made for the whole map
#       (share: the part of the line it has; the rest is the map's chunks. Honest, not even: a contour
#       chunk is milliseconds of worker time, a map chunk about a second - data/view/fog.json topo.load_share)

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

var style: UiStyle = null
var blocking := true
var title := "Drawing the map…"
var done := 0
var total := 0
var seconds := 0.0
var seed_text: Variant = ""
var fog_done := 0
var fog_total := 0
var fog_share := 0.0
var pool_done := 0
var pool_total := 0
var pool_share := 0.0

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

func set_fog_progress(d: int, t: int, share: float) -> void:
	fog_done = d
	fog_total = t
	fog_share = share
	queue_redraw()

func set_pool_progress(d: int, t: int, share: float) -> void:
	pool_done = d
	pool_total = t
	pool_share = share
	queue_redraw()

# How far along the line of ink is: the map's pieces, the contour pieces and the tree set, each by its share.
func fraction() -> float:
	var f_map := clampf(float(done) / float(total), 0.0, 1.0) if total > 0 else 0.0
	var s_fog := fog_share if fog_total > 0 else 0.0
	var s_pool := pool_share if pool_total > 0 else 0.0
	var f := (1.0 - s_fog - s_pool) * f_map
	if fog_total > 0:
		f += s_fog * clampf(float(fog_done) / float(fog_total), 0.0, 1.0)
	if pool_total > 0:
		f += s_pool * clampf(float(pool_done) / float(pool_total), 0.0, 1.0)
	return f

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()

func _draw() -> void:
	if style == null:
		return
	var ink: Color = style.color("ink")
	var faint: Color = style.color("ink_faint")
	if blocking:
		draw_rect(Rect2(Vector2.ZERO, size), style.color("map_paper"), true)
	var w := 380.0 if blocking else 300.0
	var h := 126.0 if blocking else 64.0
	var r := Rect2(Vector2((size.x - w) * 0.5, (size.y - h) * 0.5 if blocking else 18.0), Vector2(w, h))
	UiInk.card_shadow(self, r, style.shadow_dir() * style.num("card.lift_px"), style.color("card_shadow"))
	UiInk.card(self, r, style.color("card_fill"), ink, style.num("card.outer_line_px"), style.num("card.inner_line_px"),
		style.num("card.inner_inset_px"), style.num("card.wobble_px"), 31)
	var serif: Font = style.font(false)
	var italic: Font = style.text_font()   # (Track L, readable lettering: the label face at 14 px in full ink, not the thin italic)
	var pad: float = style.num("card.pad_px")
	var ty := r.position.y + (40.0 if blocking else 28.0)
	UiInk.text(self, serif, Vector2(r.position.x, ty), title, style.num("fonts.title_px") + (4.0 if blocking else 0.0), ink,
		HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
	# A line of ink that fills as the chunks come in; before the first chunk, a short stroke that travels.
	var x0 := r.position.x + pad + 6.0
	var x1 := r.end.x - pad - 6.0
	var y := ty + (22.0 if blocking else 16.0)
	UiInk.ink_line(self, PackedVector2Array([Vector2(x0, y), Vector2(x1, y)]), false, faint, 0.8, 7, 0.5)
	if total > 0 or fog_total > 0 or pool_total > 0:
		var f := fraction()
		if f > 0.0:
			UiInk.ink_line(self, PackedVector2Array([Vector2(x0, y), Vector2(lerpf(x0, x1, f), y)]), false, ink, 2.0, 9, 0.8)
	else:
		var u := fmod(Time.get_ticks_msec() / 1000.0, 1.6) / 1.6
		var a := lerpf(x0, x1 - 40.0, u)
		UiInk.ink_line(self, PackedVector2Array([Vector2(a, y), Vector2(a + 40.0, y)]), false, ink, 2.0, 9, 0.8)
	# What is being made, in pieces: the tree set (until it is done), the map's chunks, the contour chunks. Three
	# counts do not fit one line of the card, so while the tree set is in the list the blocking card breaks them over two.
	var parts: Array[String] = []
	if pool_total > 0 and pool_done < pool_total:
		parts.append("trees %d of %d" % [pool_done, pool_total])
	if fog_total > 0:
		parts.append("map %d of %d" % [done, total] if total > 0 else "starting")
		parts.append("contours %d of %d" % [fog_done, fog_total])
	else:
		parts.append("%d of %d pieces" % [done, total] if total > 0 else "starting")
	if blocking:
		var second := "%.0f s" % seconds
		var first_line := "  ·  ".join(parts)
		var seed_y := y + 44.0
		if parts.size() >= 3:
			first_line = "  ·  ".join(parts.slice(0, 2))
			second = "%s  ·  %s" % [parts[2], second]
			UiInk.text(self, italic, Vector2(r.position.x, y + 44.0), second, style.num("fonts.detail_px"), ink,
				HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
			seed_y = y + 62.0
		else:
			first_line += "  ·  " + second
		UiInk.text(self, italic, Vector2(r.position.x, y + 26.0), first_line, style.num("fonts.detail_px"), ink,
			HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
		if style.flag("lettering.show.loading_seed"):   # (PROPOSED removal, Track L: off by default)
			UiInk.text(self, italic, Vector2(r.position.x, seed_y), "the same map every time: seed %s" % str(seed_text),
				style.num("fonts.small_px"), ink, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
