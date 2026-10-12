extends Node2D

# A SEEDED RUN'S SHOTS ON THE MAP (builder LOF2, stage 2 of the lines of fire, 2026-10-12; proof 4). A DEBUGGING AID, not game art: every
# straight-round fire event of a run (combat "fire" events of the tanks' guns) drawn at the map's scale in metres -- from the muzzle to where the
# round went. The same seeded turns are drawn twice, once with the lines of fire off and once on:
#   OFF   no landing is known: a miss is drawn as a faint line to the tank it missed, a hit as a dark dot on the tank
#   ON    a hit is a dot at the point it struck, coloured by the BOX it struck (hull orange, turret red); a miss is a line to where it landed and a
#         mark there, coloured by what it landed on: stone violet, earth brown, wood green, water blue, lost in the air a hollow grey ring
# Its colours are a debugging key, not the palette; nothing in the game loads this.
#
#   var ev := LofEvents.new()
#   map_view.live_layer.add_child(ev)
#   ev.setup(events, weapon_ids, ppm, "ON")        # events: the run's events; weapon_ids: the weapons to draw
#   ev.counts                                      # {fire, hit, miss, by_box, by_material}

var ppm := 2.0
var mark := 1.0          # the marks are drawn this many times their size (1 over the zoom keeps them the same on screen)
var counts: Dictionary = {}
var outlines: Array = []   # world boxes (line_of_fire_shapes.gd) drawn as outlines under the shots: the low bridge (deck pale, parapets dark)
var title := ""
var _events: Array = []
var _weapons: Array = []

const MAT_COLORS := {
	"stone": Color(0.62, 0.2, 0.85, 0.95), "earth": Color(0.55, 0.33, 0.1, 0.95), "wood": Color(0.1, 0.55, 0.15, 0.95),
	"water": Color(0.1, 0.4, 0.95, 0.95), "metal": Color(0.2, 0.2, 0.2, 0.95), "air": Color(0.45, 0.45, 0.45, 0.95),
}

func setup(events: Array, weapon_ids: Array, ppm_v: float, title_v: String) -> void:
	ppm = ppm_v
	title = title_v
	_events = events
	_weapons = weapon_ids
	var fire := 0
	var hit := 0
	var miss := 0
	var by_box := {}
	var by_mat := {}
	var lands := 0
	for e: Dictionary in events:
		if e.get("type", "") != "fire" or not weapon_ids.has(e.get("weapon", "")):
			continue
		fire += 1
		if bool(e["hit"]):
			hit += 1
			if e.has("hit_part"):
				by_box[str(e["hit_part"])] = int(by_box.get(str(e["hit_part"]), 0)) + 1
		else:
			miss += 1
			if e.has("m_material"):
				lands += 1
				var m := str(e["m_material"])
				by_mat[m] = int(by_mat.get(m, 0)) + 1
	counts = {"fire": fire, "hit": hit, "miss": miss, "by_box": by_box, "by_material": by_mat, "landings": lands}
	queue_redraw()

func _p(x: float, y: float) -> Vector2:
	return Vector2(x, y) * ppm

func _draw() -> void:
	for b: Dictionary in outlines:
		var cs := float(b["cs"])
		var sn := float(b["sn"])
		var hl := float(b["hl"])
		var hw := float(b["hw"])
		var c := Vector2(float(b["cx"]), float(b["cy"]))
		var pts := PackedVector2Array()
		for k in [[1.0, 1.0], [1.0, -1.0], [-1.0, -1.0], [-1.0, 1.0], [1.0, 1.0]]:
			pts.append(_p(c.x + hl * k[0] * cs - hw * k[1] * sn, c.y + hl * k[0] * sn + hw * k[1] * cs))
		var parapet := str(b["part"]) == "parapet"
		draw_polyline(pts, Color(0.35, 0.1, 0.5, 0.9) if parapet else Color(0.4, 0.4, 0.4, 0.8), (2.0 if parapet else 1.2) * mark)
	# lines first, marks over them
	for e: Dictionary in _events:
		if e.get("type", "") != "fire" or not _weapons.has(e.get("weapon", "")):
			continue
		var from := _p(float(e["x"]), float(e["y"]))
		if bool(e["hit"]):
			var to := _p(float(e.get("hx", e["tx"])), float(e.get("hy", e["ty"])))
			draw_line(from, to, Color(0.7, 0.05, 0.05, 0.35), 1.0 * mark)
		elif e.has("mx"):
			var col: Color = MAT_COLORS.get(str(e["m_material"]), Color(0.3, 0.3, 0.3, 0.9))
			draw_line(from, _p(float(e["mx"]), float(e["my"])), Color(col.r, col.g, col.b, 0.28), 1.0 * mark)
		else:
			draw_line(from, _p(float(e["tx"]), float(e["ty"])), Color(0.35, 0.35, 0.35, 0.3), 1.0 * mark)
	for e: Dictionary in _events:
		if e.get("type", "") != "fire" or not _weapons.has(e.get("weapon", "")):
			continue
		var sp := _p(float(e["x"]), float(e["y"]))
		draw_rect(Rect2(sp - Vector2(2, 2) * mark, Vector2(4, 4) * mark), Color(0.05, 0.05, 0.05, 0.6))
		if bool(e["hit"]):
			if e.has("hit_part"):
				var hc := Color(0.95, 0.5, 0.05, 1.0) if str(e["hit_part"]) == "hull" else Color(0.85, 0.05, 0.05, 1.0)
				var hp := _p(float(e["hx"]), float(e["hy"]))
				draw_circle(hp, 5.0 * mark, Color(0, 0, 0, 0.9))
				draw_circle(hp, 3.6 * mark, hc)
			else:
				var tp := _p(float(e["tx"]), float(e["ty"]))
				draw_circle(tp, 4.5 * mark, Color(0.55, 0.0, 0.0, 0.95))
		elif e.has("mx"):
			var mp := _p(float(e["mx"]), float(e["my"]))
			var mat := str(e["m_material"])
			var col: Color = MAT_COLORS.get(mat, Color(0.3, 0.3, 0.3, 0.9))
			if mat == "air":
				draw_arc(mp, 4.0 * mark, 0.0, TAU, 14, col, 1.6 * mark)
			else:
				draw_line(mp + Vector2(-4, -4) * mark, mp + Vector2(4, 4) * mark, col, 2.2 * mark)
				draw_line(mp + Vector2(-4, 4) * mark, mp + Vector2(4, -4) * mark, col, 2.2 * mark)
		else:
			var tp2 := _p(float(e["tx"]), float(e["ty"]))
			draw_arc(tp2, 4.5 * mark, 0.0, TAU, 14, Color(0.3, 0.3, 0.3, 0.7), 1.2 * mark)
