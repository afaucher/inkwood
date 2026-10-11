extends RefCounted

# THE DISTANCE LEGEND (builder, map-border board, 2026-10-11). Alex chose from variants/map-border (decision map-border): "I like the
# hatches, with the distance legend" -- option A's hatched edge plus option B's graticule ticks every 500 m with their numbers in
# metres and, at the full zoom-out, the scale bar; not B's double-ruled neatline and not its north arrow. This paints that legend,
# in SCREEN px, for the option that is the game's look (map_border_e.gd). Option B keeps its own, older copy of this code (its ticks
# and numbers stand OUTSIDE its neatline); when B goes, this is the one that stays.
#
# WHERE THE NUMBERS SIT (proposed): INSIDE THE MAP, along its edge, never on the hatching. The hatch band lies outside the edge and is
# 56 px deep (70 px of band at the planning zoom 0.35, 14 px at the full zoom-out): a number outside it would not fit in the 70 px the
# view shows past the edge at 0.35, and not in the 20 px above and below the map at the full zoom-out. So each tick is a short stroke
# from the edge line INWARD (tick.length_px), and its number stands just inside the tick's end (label.gap_px), on the map's own paper
# halo (the lettering rule for words on the map: label face, at least 14 px, full ink, the paper halo of ui.json labels.halo_px). The
# top edge's numbers are centred under their ticks, the bottom edge's above theirs, the left edge's to the right, the right edge's to the
# left. The corners (0 and 5,000 m) are not numbered: they are the edge. A number that does not fit between its neighbours is left off
# (the " m" first, then the number; the ticks stay), and so is one that would leave the window: "Readable or leave it off".
#
# THE SCALE BAR (at the full zoom-out only: the whole map in the window): the longest of tick.lengths_m that fits the margin LEFT of
# the map clear of the hatch band, at the map's bottom, inked and paper halves with its length above it in the label face.
#
# Everything is drawn through UiLabels.draw / UiInk (the lettering log) and the engine's draw calls; no colour is typed here: the roles
# are data/view/map_border.json's `e.*` records.

const CameraData = preload("res://scripts/world/camera_data.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")

var b: Node2D                          # the border
var paper_c: Color
var tick_m: float
var tick_len: float
var tick_w: float
var tick_c: Color
var ends: bool
var label_c: Color
var label_gap: float
var suffix: String
var min_gap: float
var bar_lengths: Array = []
var bar_h: float
var bar_min: float
var bar_margin: float
var bar_c: Color
var bar_when: String

var _st: UiStyle
var _font: Font
var _px := 14.0
var _asc := 0.0
var _wide := 0.0
var _narrow := 0.0
var _wcache: Dictionary = {}

# What the last paint drew, for the test and the board.
var drawn_labels: Array = []           # [{text, px, x, y, w}] baseline start and width, screen px
var drawn_ticks: Array = []            # [{from, to}] screen px
var drawn_bar := Rect2()
var drawn_bar_m := 0.0
var paint_us := 0
var paint_us_max := 0
var paints := 0

func _init(border: Node2D) -> void:
	b = border
	var d: CameraData = b.data
	paper_c = b.role("paper.role")
	tick_m = d.num("e.tick.spacing_m")
	tick_len = d.num("e.tick.length_px")
	tick_w = d.num("e.tick.width_px")
	tick_c = b.role("e.tick.role")
	ends = d.flag("e.tick.number_the_ends")
	label_c = b.role("e.label.role")
	label_gap = d.num("e.label.gap_px")
	suffix = d.text("e.label.suffix")
	min_gap = d.num("e.label.min_gap_px")
	bar_lengths = d.list("e.scale_bar.lengths_m")
	bar_h = d.num("e.scale_bar.height_px")
	bar_min = d.num("e.scale_bar.min_px")
	bar_margin = d.num("e.scale_bar.margin_px")
	bar_c = b.role("e.scale_bar.role")
	bar_when = d.text("e.scale_bar.when")
	_st = UiStyle.shared()
	_font = UiLabels.font(_st)
	_px = UiLabels.px(_st)
	_asc = _font.get_ascent(int(round(_px)))
	_wide = UiInk.text_width(_font, "5000" + suffix, _px)
	_narrow = UiInk.text_width(_font, "5000", _px)

func _width(text: String) -> float:
	if not _wcache.has(text):
		_wcache[text] = UiInk.text_width(_font, text, _px)
	return _wcache[text]

# Paints the legend for the camera `xf` (map px -> screen px) in a viewport of `vp` px. `hatch_clear` is how many screen px outside
# the map's edge the hatching reaches at this zoom (the scale bar keeps out of it).
func paint(ci: CanvasItem, xf: Transform2D, vp: Vector2, hatch_clear: float) -> void:
	var t0 := Time.get_ticks_usec()
	drawn_labels.clear()
	drawn_ticks.clear()
	drawn_bar = Rect2()
	drawn_bar_m = 0.0
	var r: Rect2 = b.map_rect_px
	var ppm: float = b.px_per_m
	var z := xf.get_scale().x
	var a: Vector2 = xf * r.position
	var e: Vector2 = xf * r.end
	var sp := tick_m * ppm * z                      # screen px between ticks
	var numbers := _narrow + min_gap <= sp          # room for a number at all
	var with_unit := _wide + min_gap <= sp          # ... and for its unit
	var x0m := r.position.x / ppm
	var x1m := r.end.x / ppm
	var y0m := r.position.y / ppm
	var y1m := r.end.y / ppm
	var top_in := a.y >= -1.0 and a.y <= vp.y + 1.0
	var bottom_in := e.y >= -1.0 and e.y <= vp.y + 1.0
	var left_in := a.x >= -1.0 and a.x <= vp.x + 1.0
	var right_in := e.x >= -1.0 and e.x <= vp.x + 1.0
	var view := Rect2(Vector2.ZERO, vp)
	# the ticks along the top and bottom edges
	var k := ceili(x0m / tick_m - 1e-6)
	while float(k) * tick_m <= x1m + 1e-6:
		var m := float(k) * tick_m
		var is_end := absf(m - x0m) < 1e-6 or absf(m - x1m) < 1e-6
		var sx: float = (xf * Vector2(m * ppm, 0.0)).x
		if sx >= 2.0 and sx <= vp.x - 2.0 and (ends or not is_end):
			var text := "%d%s" % [int(round(m)), suffix if with_unit else ""]
			if top_in:
				_tick(ci, Vector2(sx, a.y), Vector2(sx, a.y + tick_len))
				if numbers:
					_number(ci, view, text, Vector2(sx, a.y + tick_len + label_gap + _asc), 0)
			if bottom_in:
				_tick(ci, Vector2(sx, e.y), Vector2(sx, e.y - tick_len))
				if numbers:
					_number(ci, view, text, Vector2(sx, e.y - tick_len - label_gap), 0)
		k += 1
	# the left and right edges
	k = ceili(y0m / tick_m - 1e-6)
	var fits_v := sp >= _px + min_gap
	while float(k) * tick_m <= y1m + 1e-6:
		var m2 := float(k) * tick_m
		var is_end := absf(m2 - y0m) < 1e-6 or absf(m2 - y1m) < 1e-6
		var sy: float = (xf * Vector2(0.0, m2 * ppm)).y
		if sy >= 2.0 and sy <= vp.y - 2.0 and (ends or not is_end):
			if left_in:
				_tick(ci, Vector2(a.x, sy), Vector2(a.x + tick_len, sy))
				if numbers and fits_v:
					_number(ci, view, "%d%s" % [int(round(m2)), suffix if with_unit else ""], Vector2(a.x + tick_len + label_gap, sy + _asc * 0.5 - 1.0), 1)
			if right_in:
				_tick(ci, Vector2(e.x, sy), Vector2(e.x - tick_len, sy))
				if numbers and fits_v:
					_number(ci, view, "%d%s" % [int(round(m2)), suffix if with_unit else ""], Vector2(e.x - tick_len - label_gap, sy + _asc * 0.5 - 1.0), 2)
		k += 1
	if bar_when == "whole_map_in_view" and a.x >= 0.0 and a.y >= 0.0 and e.x <= vp.x and e.y <= vp.y:
		_scale_bar(ci, a, e, z, hatch_clear)
	paint_us = Time.get_ticks_usec() - t0
	paint_us_max = maxi(paint_us_max, paint_us)
	paints += 1

func _tick(ci: CanvasItem, from: Vector2, to: Vector2) -> void:
	ci.draw_line(from, to, tick_c, tick_w, true)
	drawn_ticks.append({"from": from, "to": to})

# A number: `pos` is the baseline point; anchor 0 centres on it, 1 starts at it, 2 ends at it. Left off when its box would leave `view`.
func _number(ci: CanvasItem, view: Rect2, s: String, pos: Vector2, anchor: int) -> void:
	var w := _width(s)
	var x := pos.x
	match anchor:
		0: x -= w * 0.5
		2: x -= w
	var p := Vector2(roundf(x), roundf(pos.y))
	var box := Rect2(p.x, p.y - _px * 0.8, w, _px * 0.95)
	if not view.encloses(box):
		return
	UiLabels.draw(ci, _st, _font, p, s, _px, label_c)
	drawn_labels.append({"text": s, "px": _px, "x": p.x, "y": p.y, "w": w})

# The scale bar, in the margin left of the map and clear of the hatch band.
func _scale_bar(ci: CanvasItem, a: Vector2, e: Vector2, z: float, hatch_clear: float) -> void:
	var strip := a.x - hatch_clear
	var pxm: float = b.px_per_m
	var best_m := 0.0
	for L: Variant in bar_lengths:
		var lm := float(L)
		var lp := lm * pxm * z
		if lp >= bar_min and lp + 2.0 * bar_margin <= strip:
			best_m = maxf(best_m, lm)
	if best_m <= 0.0:
		return
	var lp := best_m * pxm * z
	var x0 := roundf(bar_margin + (strip - 2.0 * bar_margin - lp) * 0.5)
	var y1 := roundf(e.y - bar_margin - 6.0)
	var rect := Rect2(x0, y1 - bar_h, lp, bar_h)
	var half := Rect2(rect.position, Vector2(lp * 0.5, bar_h))
	ci.draw_rect(rect, paper_c, true)
	ci.draw_rect(half, bar_c, true)
	ci.draw_rect(rect, bar_c, false, 1.0, true)
	for t in [0.0, 0.5, 1.0]:
		ci.draw_line(Vector2(rect.position.x + lp * t, rect.position.y - 4.0), Vector2(rect.position.x + lp * t, rect.position.y), bar_c, 1.0, true)
	var text := "%d m" % int(best_m) if best_m < 1000.0 else "%s km" % String.num(best_m / 1000.0, 1).trim_suffix(".0")
	var w := _width(text)
	var p := Vector2(roundf(rect.position.x + lp * 0.5 - w * 0.5), roundf(rect.position.y - 7.0))
	UiLabels.draw(ci, _st, _font, p, text, _px, label_c)
	drawn_labels.append({"text": text, "px": _px, "x": p.x, "y": p.y, "w": w, "bar": true})
	drawn_bar = rect
	drawn_bar_m = best_m
