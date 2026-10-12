extends Node2D

# THE COVER MAP (builder LOF2, stage 2 of the lines of fire, 2026-10-12; proof 2). A DEBUGGING AID, not game art: for one tank, the map shaded
# by how much of an ENEMY TANK standing at each spot it could see -- the real height grid, the real line check, the same sample lines the
# combat uses (CombatLines / LineOfFire.exposure_xyz). An enemy tank is put at the middle of every cell facing the tank (end on: the smallest
# target), on the ground, the water's surface or the bridge deck it would stand on, and its hull and turret are traced to.
#   red     FULLY VISIBLE      the whole tank in view (95 percent or more of it)
#   amber   HULL-DOWN          the turret in view (90 percent or more of it) and the hull mostly hidden (60 percent or less): low solid cover
#   yellow  PARTLY SCREENED    some of it in view, not as above: the thin trees' crowns stopping some of the lines, a corner of cover
#   blue    HIDDEN             nothing in view: the gun would HOLD
# Water is left clear (a tank cannot stand there) except under the bridge's deck. Its colours are a debugging key, not the palette
# (CLAUDE.md rule 6 is for drawn things of the game); nothing in the game loads this.
#
#   var cm := LofCover.new()
#   map_view.live_layer.add_child(cm)                 # MAP px, zooms with the map
#   cm.setup(lof, grid, rules, tank_def, muzzle_xyz, Rect2(x, y, w, h) in metres, 3.0)
#   cm.stats                                           # counts per class, the time it took

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")

var rect_m := Rect2()
var ppm := 2.0
var cell := 3.0
var stats: Dictionary = {}
var muzzle := Vector3.ZERO
var rings: Array[float] = [100.0, 200.0, 350.0]
var _tex: ImageTexture = null

func setup(lof: Object, grid: Object, rules: Object, tank_def: Object, muzzle_xyz: Vector3, rect: Rect2, cell_m: float = 3.0) -> void:
	rect_m = rect
	cell = cell_m
	ppm = float(grid.ppm)
	muzzle = muzzle_xyz
	var t0 := Time.get_ticks_usec()
	grid.build_rect(rect.grow(40.0))
	var w := int(ceil(rect.size.x / cell))
	var h := int(ceil(rect.size.y / cell))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var counts := {"full": 0, "hull_down": 0, "partly": 0, "hidden": 0, "water": 0}
	var key := 1
	for j in h:
		for i in w:
			var x := rect.position.x + (float(i) + 0.5) * cell
			var y := rect.position.y + (float(j) + 0.5) * cell
			var byte: int = grid.cell_byte(x, y)
			var mat := byte & Rules.MATERIAL_MASK
			if (mat == Rules.WATER and (byte & Rules.FLAG_DECK) == 0) or (mat != Rules.GROUND and mat != Rules.WATER and (byte & Rules.FLAG_DECK) == 0):
				# water, or a house, a wall, the parapets: nowhere a tank stands
				counts["water"] += 1
				continue
			var heading := atan2(muzzle.y - y, muzzle.x - x)
			var base := float(grid.stand_z(x, y))
			var boxes := Shapes.world_boxes(tank_def, rules, x, y, heading, base)
			var ex: Dictionary = lof.exposure_xyz(muzzle.x, muzzle.y, muzzle.z, boxes, key, false, false)
			key += 1
			var share := float(ex["share"])
			if not bool(ex["visible"]):
				counts["hidden"] += 1
				img.set_pixel(i, j, Color(0.12, 0.3, 0.95, 0.5))
			elif share >= 0.95:
				counts["full"] += 1
				img.set_pixel(i, j, Color(0.92, 0.12, 0.08, 0.42))
			elif float(ex["boxes"][1]["share"]) >= 0.9 and float(ex["boxes"][0]["share"]) <= 0.6:
				counts["hull_down"] += 1
				img.set_pixel(i, j, Color(1.0, 0.5, 0.0, 0.7))
			else:
				counts["partly"] += 1
				img.set_pixel(i, j, Color(1.0, 0.88, 0.1, 0.25 + 0.4 * (1.0 - share)))
	_tex = ImageTexture.create_from_image(img)
	stats = {"cells": w * h, "cell_m": cell, "counts": counts, "ms": (Time.get_ticks_usec() - t0) / 1000.0}
	queue_redraw()

func _draw() -> void:
	if _tex == null:
		return
	var origin := rect_m.position * ppm
	draw_texture_rect(_tex, Rect2(origin, Vector2(_tex.get_width(), _tex.get_height()) * cell * ppm), false)
	var c := Vector2(muzzle.x, muzzle.y) * ppm
	for r in rings:
		draw_arc(c, r * ppm, 0.0, TAU, 96, Color(0.1, 0.1, 0.1, 0.55), 1.5)
		draw_string(ThemeDB.fallback_font, c + Vector2(r * ppm * 0.7071 + 4.0, -r * ppm * 0.7071), "%.0f m" % r, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.1, 0.1, 0.1, 0.9))
	draw_circle(c, 7.0, Color(1, 1, 1, 0.95))
	draw_circle(c, 5.0, Color(0.05, 0.05, 0.05, 1.0))
