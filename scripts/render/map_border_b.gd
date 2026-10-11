extends "res://scripts/render/map_border_base.gd"

# OPTION B, "Printed map sheet" (builder, map-border board, 2026-10-11; PROPOSED). The paper continues past the edge, blank. At the
# edge: a ruled neatline in the cards' double-rule language (a fine rule on the edge and a heavy one a few px outside it); a
# graticule tick every 500 m with its number in metres (the label face, at least 14 px, full ink on the paper margin, with the
# map's paper halo -- left off where there is no room, as the lettering rule says: "Readable or leave it off"); and, when the whole
# map is in view (the full zoom-out), a scale bar and a north arrow in the margin beside it. North is up: there is no rotation.
#
# Drawn in SCREEN px by a screen-pinned node (map_border_screen.gd), so a rule is 1 px or 2.2 px at every zoom and the lettering
# is crisp; the node repaints when the camera moves (about two hundred draw calls), and costs nothing while it does not.

const Screen = preload("res://scripts/render/map_border_screen.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const WOB_STEP := 16.0   # map px between the stored wobble values

var _screen: Screen
var _xf := Transform2D()
var _vp := Vector2(1280, 720)
var _st: UiStyle
var _font: Font
var _px := 14.0

var _inner_c: Color
var _inner_w: float
var _outer_c: Color
var _outer_w: float
var _gap: float
var _wob: float
var _tick_m: float
var _tick_len: float
var _tick_w: float
var _tick_c: Color
var _label_c: Color
var _label_gap: float
var _suffix: String
var _min_gap: float
var _bar_lengths: Array = []
var _bar_h: float
var _bar_min: float
var _bar_margin: float
var _bar_c: Color
var _north_h: float
var _north_c: Color
var _furniture: String
var _paper_c: Color

# What the last paint drew, for the test and the board: [{text, px, x, y}] and the furniture's rectangles.
var _wob_tables: Dictionary = {}   # seed -> PackedFloat32Array: the rules' hand wobble along a side, one value per WOB_STEP map px
var _asc := 0.0
var _wide := 0.0
var _narrow := 0.0
var _wcache: Dictionary = {}
var _paint_us := 0
var _paint_us_max := 0
var _paints := 0
var drawn_labels: Array = []
var drawn_furniture := {"scale_bar": Rect2(), "north": Rect2(), "bar_m": 0.0}

func build() -> void:
	var d: CameraData = b.data
	d.text("b.name")
	make_fill(true, b.role("paper.role"))
	_inner_c = b.role("b.rule.inner_role")
	_inner_w = d.num("b.rule.inner_px")
	_outer_c = b.role("b.rule.outer_role")
	_outer_w = d.num("b.rule.outer_px")
	_gap = d.num("b.rule.gap_px")
	_wob = d.num("b.rule.wobble_px")
	_tick_m = d.num("b.tick.spacing_m")
	_tick_len = d.num("b.tick.length_px")
	_tick_w = d.num("b.tick.width_px")
	_tick_c = b.role("b.tick.role")
	_label_c = b.role("b.label.role")
	_label_gap = d.num("b.label.gap_px")
	_suffix = d.text("b.label.suffix")
	_min_gap = d.num("b.label.min_gap_px")
	_bar_lengths = d.list("b.scale_bar.lengths_m")
	_bar_h = d.num("b.scale_bar.height_px")
	_bar_min = d.num("b.scale_bar.min_px")
	_bar_margin = d.num("b.scale_bar.margin_px")
	_bar_c = b.role("b.scale_bar.role")
	_north_h = d.num("b.north_arrow.height_px")
	_north_c = b.role("b.north_arrow.role")
	_furniture = d.text("b.furniture_when")
	_paper_c = b.role("paper.role")
	_st = UiStyle.shared()
	_font = UiLabels.font(_st)
	_px = UiLabels.px(_st)
	_asc = _font.get_ascent(int(round(_px)))
	_wide = UiInk.text_width(_font, "5000" + _suffix, _px)
	_narrow = UiInk.text_width(_font, "5000", _px)
	# the rules' hand wobble, world-anchored: noise of the position along a side, tabulated once (a paint then only interpolates)
	var rr: Rect2 = b.map_rect_px
	var longest := maxf(rr.size.x, rr.size.y)
	for sd in [11, 12, 13, 14, 21, 22, 23, 24]:
		var t := PackedFloat32Array()
		var n := int(ceil(longest / WOB_STEP)) + 2
		t.resize(n)
		for i in n:
			t[i] = (ValueNoise.vnoise(float(i) * WOB_STEP * 0.02, float(sd), 77) - 0.5) * 2.0
		_wob_tables[sd] = t
	_screen = Screen.new()
	_screen.painter = Callable(self, "_paint")
	b.add_child(_screen)

func stats() -> Dictionary:
	return {"paint_us": _paint_us, "paint_us_max": _paint_us_max, "paints": _paints, "labels": drawn_labels.size()}

func frame(xf: Transform2D, zoom: float, vp: Vector2) -> void:
	_xf = xf
	_vp = vp
	fill.set_zoom(zoom)
	var view: Node2D = b.view
	_screen.pin(xf * view.get_global_transform().affine_inverse())
	_screen.repaint()

# --- the paint ---------------------------------------------------------------------------------

func _paint(ci: CanvasItem) -> void:
	var t0 := Time.get_ticks_usec()
	drawn_labels.clear()
	drawn_furniture = {"scale_bar": Rect2(), "north": Rect2(), "bar_m": 0.0}
	var r: Rect2 = b.map_rect_px
	var a: Vector2 = _xf * r.position
	var e: Vector2 = _xf * r.end
	var vp := _vp
	var ppm: float = b.px_per_m
	var sp: float = _tick_m * ppm * _xf.get_scale().x     # screen px between ticks
	# the two rules, as four sides each, clipped to the view
	for side in 4:
		_rule(ci, side, a, e, 0.0, _inner_c, _inner_w, 11 + side)
		_rule(ci, side, a, e, _gap, _outer_c, _outer_w, 21 + side)
	# ticks and numbers
	var asc := _asc
	var lab_x_top := a.y >= _gap + _tick_len + _label_gap + asc + 2.0     # room above the top edge for a number
	var lab_x_bot := vp.y - e.y >= _gap + _tick_len + _label_gap + asc + 2.0
	var suffix_ok := false
	var plain_ok := false
	var wide := _wide
	var narrow := _narrow
	suffix_ok = wide + _min_gap <= sp
	plain_ok = narrow + _min_gap <= sp
	var x0m: float = r.position.x / ppm
	var x1m: float = r.end.x / ppm
	var y0m: float = r.position.y / ppm
	var y1m: float = r.end.y / ppm
	var k := ceili(x0m / _tick_m - 1e-6)
	while float(k) * _tick_m <= x1m + 1e-6:
		var m := float(k) * _tick_m
		var sx: float = (_xf * Vector2(m * ppm, 0.0)).x
		if sx >= -20.0 and sx <= vp.x + 20.0:
			if a.y > -30.0 and a.y < vp.y + 30.0:
				_tick(ci, Vector2(sx, a.y - _gap - _outer_w * 0.5), Vector2(0, -1))
				if lab_x_top and (suffix_ok or plain_ok):
					_label(ci, "%d%s" % [int(round(m)), _suffix if suffix_ok else ""], Vector2(sx, a.y - _gap - _tick_len - _label_gap), 0)
			if e.y > -30.0 and e.y < vp.y + 30.0:
				_tick(ci, Vector2(sx, e.y + _gap + _outer_w * 0.5), Vector2(0, 1))
				if lab_x_bot and (suffix_ok or plain_ok):
					_label(ci, "%d%s" % [int(round(m)), _suffix if suffix_ok else ""], Vector2(sx, e.y + _gap + _tick_len + _label_gap + asc), 0)
		k += 1
	k = ceili(y0m / _tick_m - 1e-6)
	while float(k) * _tick_m <= y1m + 1e-6:
		var m2 := float(k) * _tick_m
		var sy: float = (_xf * Vector2(0.0, m2 * ppm)).y
		if sy >= -20.0 and sy <= vp.y + 20.0:
			if a.x > -30.0 and a.x < vp.x + 30.0:
				_tick(ci, Vector2(a.x - _gap - _outer_w * 0.5, sy), Vector2(-1, 0))
				var avail_l: float = a.x - _gap - _tick_len - _label_gap - 2.0
				var tl := "%d%s" % [int(round(m2)), _suffix if wide <= avail_l else ""]
				if _width(tl) <= avail_l and sp >= _px + _min_gap:
					_label(ci, tl, Vector2(a.x - _gap - _tick_len - _label_gap, sy + asc * 0.5 - 1.0), 2)
			if e.x > -30.0 and e.x < vp.x + 30.0:
				_tick(ci, Vector2(e.x + _gap + _outer_w * 0.5, sy), Vector2(1, 0))
				var avail_r: float = vp.x - e.x - _gap - _tick_len - _label_gap - 2.0
				var tr := "%d%s" % [int(round(m2)), _suffix if wide <= avail_r else ""]
				if _width(tr) <= avail_r and sp >= _px + _min_gap:
					_label(ci, tr, Vector2(e.x + _gap + _tick_len + _label_gap, sy + asc * 0.5 - 1.0), 1)
		k += 1
	if _furniture == "whole_map_in_view" and a.x >= 0.0 and a.y >= 0.0 and e.x <= vp.x and e.y <= vp.y:
		_furniture_paint(ci, a, e)
	_paint_us = Time.get_ticks_usec() - t0
	_paint_us_max = maxi(_paint_us_max, _paint_us)
	_paints += 1

# One side of a rule: 0 top, 1 right, 2 bottom, 3 left; `off` px outside the edge; clipped to the view, with a world-anchored
# hand wobble (noise of the position along the side, so a pan does not make it swim).
func _rule(ci: CanvasItem, side: int, a: Vector2, e: Vector2, off: float, col: Color, w: float, seed_v: int) -> void:
	var horizontal := side == 0 or side == 2
	var along0: float = a.x if horizontal else a.y
	var along1: float = e.x if horizontal else e.y
	var fixed: float
	match side:
		0: fixed = a.y - off
		1: fixed = e.x + off
		2: fixed = e.y + off
		_: fixed = a.x - off
	var lim: float = (_vp.y if horizontal else _vp.x)
	if fixed < -40.0 or fixed > lim + 40.0:
		return   # the side is off screen
	var span: float = (_vp.x if horizontal else _vp.y)
	var s0 := maxf(along0 - off, -10.0)
	var s1 := minf(along1 + off, span + 10.0)
	if s1 <= s0:
		return
	var pts := PackedVector2Array()
	var step := 12.0
	var s := s0
	var z: float = _xf.get_scale().x
	var table: PackedFloat32Array = _wob_tables[seed_v]
	while true:
		var world_t := (s - along0) / z    # map px along the side from its start: the noise is anchored to it
		var fi := clampf(world_t / WOB_STEP, 0.0, float(table.size() - 2))
		var i0 := int(fi)
		var wob := lerpf(table[i0], table[i0 + 1], fi - float(i0)) * _wob
		var f := fixed + wob
		pts.append(Vector2(s, f) if horizontal else Vector2(f, s))
		if s >= s1:
			break
		s = minf(s + step, s1)
	ci.draw_polyline(pts, col, w, true)

func _width(text: String) -> float:
	if not _wcache.has(text):
		_wcache[text] = UiInk.text_width(_font, text, _px)
	return _wcache[text]

func _tick(ci: CanvasItem, from: Vector2, dir: Vector2) -> void:
	ci.draw_line(from, from + dir * (_tick_len + _outer_w * 0.5), _tick_c, _tick_w, true)

# A number: `pos` is the baseline point; anchor 0 centres on it, 1 starts at it (left aligned), 2 ends at it (right aligned).
func _label(ci: CanvasItem, s: String, pos: Vector2, anchor: int) -> void:
	var w := _width(s)
	var x := pos.x
	match anchor:
		0: x -= w * 0.5
		2: x -= w
	var p := Vector2(roundf(x), roundf(pos.y))
	UiLabels.draw(ci, _st, _font, p, s, _px, _label_c)
	drawn_labels.append({"text": s, "px": _px, "x": p.x, "y": p.y, "w": w})

# The scale bar and the north arrow, in the margin on the map's left (the roster is on the right).
func _furniture_paint(ci: CanvasItem, a: Vector2, e: Vector2) -> void:
	var strip := a.x                       # px of margin left of the map
	var z: float = _xf.get_scale().x
	var pxm: float = b.px_per_m
	# the longest scale bar that fits the strip
	var best_m := 0.0
	for L: Variant in _bar_lengths:
		var lm := float(L)
		var lp := lm * pxm * z
		if lp >= _bar_min and lp + 2.0 * _bar_margin <= strip:
			best_m = maxf(best_m, lm)
	if best_m > 0.0:
		var lp := best_m * pxm * z
		var x0 := roundf(_bar_margin + (strip - 2.0 * _bar_margin - lp) * 0.5)
		var y1 := roundf(e.y - _bar_margin - 6.0)
		var rect := Rect2(x0, y1 - _bar_h, lp, _bar_h)
		var half := Rect2(rect.position, Vector2(lp * 0.5, _bar_h))
		ci.draw_rect(rect, _paper_c, true)
		ci.draw_rect(half, _bar_c, true)
		ci.draw_rect(rect, _bar_c, false, 1.0, true)
		for t in [0.0, 0.5, 1.0]:
			ci.draw_line(Vector2(rect.position.x + lp * t, rect.position.y - 4.0), Vector2(rect.position.x + lp * t, rect.position.y), _bar_c, 1.0, true)
		var text := "%d m" % int(best_m) if best_m < 1000.0 else "%s km" % String.num(best_m / 1000.0, 1).trim_suffix(".0")
		_label(ci, text, Vector2(rect.position.x + lp * 0.5, rect.position.y - 4.0 - 3.0), 0)
		drawn_furniture["scale_bar"] = rect
		drawn_furniture["bar_m"] = best_m
	# the north arrow, near the top of the strip
	if strip >= 40.0:
		var cx := roundf(strip * 0.5)
		var top := a.y + 12.0 + _px + 4.0
		if top + _north_h < e.y - 90.0:
			var h := _north_h
			var tip := Vector2(cx, top)
			var bl := Vector2(cx - 8.0, top + h * 0.8)
			var br := Vector2(cx + 8.0, top + h * 0.8)
			var nt := Vector2(cx, top + h * 0.62)
			ci.draw_colored_polygon(PackedVector2Array([tip, bl, nt]), _north_c)
			ci.draw_polyline(PackedVector2Array([tip, br, nt, tip]), _north_c, 1.2, true)
			ci.draw_polyline(PackedVector2Array([tip, bl, nt, tip]), _north_c, 1.2, true)
			ci.draw_line(Vector2(cx, top + h * 0.62), Vector2(cx, top + h), _north_c, 1.4, true)
			_label(ci, "N", Vector2(cx, top - 4.0), 0)
			drawn_furniture["north"] = Rect2(cx - 10.0, top - _px - 4.0, 20.0, h + _px + 4.0)
