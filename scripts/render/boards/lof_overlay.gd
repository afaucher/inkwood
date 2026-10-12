extends Node2D

# THE HEIGHT GRID OVER THE MAP (builder LOF1, stage 1 of the lines of fire, 2026-10-11; proof 3). A DEBUGGING AID, not game art: it
# draws what the line check will treat as solid -- the cells' heights and materials, the trees' canopies -- over the real map, so
# anything that is drawn but does not block (or blocks but is not drawn) shows. Its colours are a debugging key, not the palette
# (CLAUDE.md rule 6 is for drawn things of the game); nothing in the game loads this.
#
#   var ov := LofOverlay.new()
#   map_view.live_layer.add_child(ov)             # MAP px, zooms with the map
#   ov.setup(grid, Rect2(x, y, w, h))             # metres: the part of the map to cover (the chunks are built if need be)
#
# One texel per grid cell, drawn at the map's scale with the nearest texel, so a 1 m cell is 2 px at zoom 1 and 4 px at zoom 2:
#   ground at 0 m   clear (the map shows through);   a terrain step   amber (12 m) and orange (24 m), the brighter the higher
#   water           blue;   stone (walls, the bridge's deck)   magenta;   timber (houses)   red;   earthworks (sandbags)   green
#   a deck (a unit stands on it)   violet
# Block edges (16 m) are thin grey lines, chunk edges (256 m) heavier. A canopy is a green circle at its radius with its top height
# written in it. Cells that carry a structure are labelled with their height.

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")

var grid: Object
var rect_m := Rect2()
var ppm := 2.0
var show_canopies := true
var show_labels := true
var show_blocks := true
var _tex: ImageTexture = null
var _canopies: Array = []
var _labels: Array = []   # [position m, text]
var stats: Dictionary = {}

func setup(grid_v: Object, rect: Rect2) -> void:
	grid = grid_v
	rect_m = rect
	ppm = float(grid.ppm)
	var t0 := Time.get_ticks_usec()
	grid.build_rect(rect.grow(40.0))
	var c: float = grid.cell_m
	var w := int(ceil(rect.size.x / c))
	var h := int(ceil(rect.size.y / c))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var counts := {"ground": 0, "water": 0, "stone": 0, "timber": 0, "earthworks": 0, "deck": 0, "step12": 0, "step24": 0}
	var seen: Dictionary = {}
	for j in h:
		for i in w:
			var x: float = rect.position.x + (float(i) + 0.5) * c
			var y: float = rect.position.y + (float(j) + 0.5) * c
			var top: float = grid.top_at(x, y)
			var byte: int = grid.cell_byte(x, y)
			var col := _color(top, byte, counts)
			img.set_pixel(i, j, col)
			var mat := byte & Rules.MATERIAL_MASK
			if (mat == Rules.TIMBER or mat == Rules.STONE or mat == Rules.EARTHWORKS or (byte & Rules.FLAG_DECK) != 0) and (i % 24 == 12 and j % 24 == 12):
				_labels.append([Vector2(x, y), "%.1f" % top])
			seen[mat] = true
	_tex = ImageTexture.create_from_image(img)
	_canopies = grid.canopies_near(rect.get_center().x, rect.get_center().y, maxf(rect.size.x, rect.size.y) * 0.75)
	stats = {"cells": w * h, "counts": counts, "canopies": _canopies.size(), "build_ms": (Time.get_ticks_usec() - t0) / 1000.0}
	queue_redraw()

# The debugging key, see the header.
func _color(top: float, byte: int, counts: Dictionary) -> Color:
	var mat := byte & Rules.MATERIAL_MASK
	var k := clampf(top / 14.0, 0.0, 1.0)
	if (byte & Rules.FLAG_DECK) != 0:
		counts["deck"] += 1
		return Color(0.55, 0.25, 0.95, 0.55 + 0.25 * k)
	match mat:
		Rules.WATER:
			counts["water"] += 1
			return Color(0.15, 0.45, 1.0, 0.30)
		Rules.STONE:
			counts["stone"] += 1
			return Color(0.95, 0.1, 0.85, 0.55 + 0.35 * k)
		Rules.TIMBER:
			counts["timber"] += 1
			return Color(0.95, 0.15, 0.1, 0.55 + 0.35 * k)
		Rules.EARTHWORKS:
			counts["earthworks"] += 1
			return Color(0.1, 0.8, 0.15, 0.85)
	if top > 0.05:
		if top > 18.0:
			counts["step24"] += 1
			return Color(1.0, 0.45, 0.0, 0.45)
		counts["step12"] += 1
		return Color(1.0, 0.8, 0.05, 0.32)
	counts["ground"] += 1
	return Color(0, 0, 0, 0)

func _draw() -> void:
	if _tex == null:
		return
	var c: float = grid.cell_m
	var origin := rect_m.position * ppm
	draw_texture_rect(_tex, Rect2(origin, Vector2(_tex.get_width(), _tex.get_height()) * c * ppm), false)
	if show_blocks:
		var bm: float = grid.block_m
		var cm: float = grid.chunk_m
		var x0 := floorf(rect_m.position.x / bm) * bm
		while x0 <= rect_m.end.x:
			var heavy := absf(fmod(x0, cm)) < 1e-6
			draw_line(Vector2(x0, rect_m.position.y) * ppm, Vector2(x0, rect_m.end.y) * ppm, Color(0.2, 0.2, 0.2, 0.8 if heavy else 0.14), 2.0 if heavy else 1.0)
			x0 += bm
		var y0 := floorf(rect_m.position.y / bm) * bm
		while y0 <= rect_m.end.y:
			var heavy2 := absf(fmod(y0, cm)) < 1e-6
			draw_line(Vector2(rect_m.position.x, y0) * ppm, Vector2(rect_m.end.x, y0) * ppm, Color(0.2, 0.2, 0.2, 0.8 if heavy2 else 0.14), 2.0 if heavy2 else 1.0)
			y0 += bm
	if show_canopies:
		for cn: Dictionary in _canopies:
			var p := Vector2(cn.x, cn.y) * ppm
			if not rect_m.grow(30.0).has_point(Vector2(cn.x, cn.y)):
				continue
			draw_arc(p, float(cn.r) * ppm, 0.0, TAU, 28, Color(0.0, 0.55, 0.1, 0.85), 1.5)
			if show_labels and float(cn.r) > 9.0:
				draw_string(ThemeDB.fallback_font, p + Vector2(-10, 4), "%.0f" % float(cn.zt), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.0, 0.35, 0.05, 0.95))
	if show_labels:
		for l: Array in _labels:
			var p2: Vector2 = (l[0] as Vector2) * ppm
			draw_string(ThemeDB.fallback_font, p2 + Vector2(-8, 4), str(l[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0, 0, 0, 0.95))
