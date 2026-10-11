extends "res://scripts/test_support/test_case.gd"

# THE TANK ON THE SCREEN (Track TK2, 2026-10-11): the marker, the roster row, the label, the cones, the plan -- everything the interface
# does for a unit, done for a tank, headless (pixels are scripts/ui/tank_shot.gd's business):
#
#   1. THE ART        the unit sheet's tank is the tank's silhouette, at the planes' scale (marker.true_scale, not the static
#                     units' bigger one): its model has the engine-deck accent panel (the side's recognition panel), the turret
#                     and the gun nose up, and a footprint for the shadow; the same on a second build (the seed rule)
#   2. THE MARKER     a marker for every tank, on the surface: its shadow is cast by its height (the style guide: "give it a height, and let
#                     the shadow pass draw its shadow"; ui.json marker.cast_height_m, behind marker.cast_shadow_on), its label reads
#                     "0 m · 8" (height and speed, the same text as a plane's), and it follows the playback
#   3. THE ROSTER     a row for each player tank: "Tank", its speed on the surface band, 2 steps a turn, six pips; the second line
#                     "Tank · 8 m/s · surface"; every string the tank brings to the screen is in the readable lettering
#   4. THE CONES      the selected tank's gun cone (all round, a level ring) draws without an error: a pie that closes on itself
#                     cannot be triangulated (the fix is cone_overlay.gd's FULL_CIRCLE_GAP)
#   5. THE PLAN       a tank is planned like any unit: a step, its node label (speed over height), Ready, the resolve, the playback
#   6. THE FALL       a destroyed tank's marker goes at the event (fate destroyed), and the roster says it is down

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const PPM := 1.4     # (the planning zoom 0.7 at 2 px per metre: where the labels show)
var _st: UiStyle
var _done := 0

func setup(_main) -> void:
	timeout_seconds = 60.0
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_art()
	await _screen()
	eq(_done, 2, "the test reached its last section (a runtime error would have ended it silently)")
	finish()

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

# --- 1. The art -----------------------------------------------------------------------------------------------------

func _art() -> void:
	check(UnitMarkerArt.is_tank("tank"), "1. the tank is a silhouette the sheet draws")
	check(not UnitMarkerArt.is_plane("tank") and not UnitMarkerArt.is_static("tank"), "1. (not a plane, not a static unit)")
	var m := UnitMarkerArt.model_for(_st, "tank")
	var again := UnitMarkerArt.model_for(_st, "tank", m.variant)
	check(m == again, "1. the model is cached")
	var fresh_p := UnitMarkerArt.gen_tank(preload("res://scripts/core/mulberry32.gd").new(m.seed))
	eq(str(fresh_p), str(m.p), "1. the same seed makes the same tank on a second build")
	check((m.G.panel as PackedVector2Array).size() >= 3, "1. the engine deck carries the side's accent panel")
	check((m.G.sil as Array).size() >= 4, "1. a footprint for the shadow (tracks, hull, turret and gun)")
	var gun: PackedVector2Array = m.G.gun
	var top := 0.0
	for q in gun:
		top = minf(top, q.y)
	check(top < -2.5, "1. the gun points nose up, forward of the hull (muzzle at y %.2f m)" % top)
	check(float(m.p.length) >= 5.5 and float(m.p.length) <= 6.7, "1. the sheet's 5.6 to 6.6 m (%.2f m)" % float(m.p.length))
	var d: Dictionary = {}
	d = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/tank.json"))
	near(float((d["size_m"] as Dictionary)["value"]), 6.0, 1e-9, "1. the unit file says 6 m: the middle of that")
	# the planes' scale: a tank's marker is not scaled up the way the static units' are
	var base_static := _st.num("marker.static_scale")
	check(base_static > 1.0, "1. (the static units are drawn larger: %s)" % str(base_static))
	_done += 1

# --- 2 to 6. On the screen --------------------------------------------------------------------------------------------

func _screen() -> void:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.rng_seed = 3
	w.add_unit({"id": "t1", "type": "tank", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "t2", "type": "tank", "side": "allies", "controller": "player", "x": 1500.0, "y": 2440.0, "heading": 0.3, "speed": 0.0})
	w.add_unit({"id": "e1", "type": "tank", "side": "axis", "controller": "ai", "x": 1640.0, "y": 2420.0, "heading": PI, "speed": 0.0})
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1450.0, "y": 2380.0, "heading": 0.0})
	var origin := Vector2(1400.0, 2300.0)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(1280.0, 720.0)
	add_child(holder)
	var ui := UnitUI.new()
	holder.add_child(ui)
	ui.setup(w, xf, "local")
	await _frames(3)
	# 2. THE MARKER
	var ml = ui.marker_layer
	for id: String in ["t1", "t2", "e1"]:
		check(ml.marker(id) != null, "2. a marker for %s" % id)
	var mk = ml.marker("t1")
	eq(mk.silhouette, "tank", "2. the marker's silhouette is the tank")
	eq(mk.size_m, 6.0, "2. 6 m")
	eq(mk.base_scale, 1.0, "2. at the planes' scale (the unit's own multiplier is 1)")
	eq(mk.draw_scale, 1.0, "2. ... drawn at it")
	eq(ml.unit_label("t1"), "0 m · 8", "2. the label reads height and speed, the same words as a plane's: '0 m · 8'")
	check(ml.label_shown("t1"), "2. ... and shows at the planning zoom")
	eq(ml.unit_label("e1"), "0 m · 0", "2. an enemy tank in sight is labelled too")
	eq(ml.unit_label("p1"), "400 m · 100", "2. (a plane's label is as it was)")
	# THE SHADOW (Style guide > Light and shadow: one sun, north-west, elevation 46 degrees, every shadow as long as its object's height / tan 46,
	# falling south-east; the lead's rule, 2026-10-11, PROPOSED, data switch ui.json marker.cast_shadow_on): a tank on the ground is not
	# a plane with an altitude gap (that is 0 at the surface) but a thing 2.0 m high (marker.cast_height_m.tank), so its footprint's shadow
	# is lifted by that height x the sun's length, toward the south-east, at its drawn scale.
	var tank_st: UiStyle = ml.style
	var tw := Vector2(float(w.units["t1"].x), float(w.units["t1"].y))
	var tank_h := float(tank_st.lookup("marker.cast_height_m.tank"))
	check(tank_h > 0.0, "2. the tank has a cast height in the data (%s m)" % str(tank_h))
	var tank_off: Vector2 = tank_st.shadow_dir() * tank_st.sun_len() * tank_h * ml.mapping.px_per_m(tw) * tank_st.num("marker.true_scale") * mk.draw_scale
	check(mk.shadow_offset.distance_to(tank_off) < 1e-6 and mk.shadow_offset.length() > 0.0, "2. a tank's shadow is lifted by its height x the sun's length (%s px, wanted %s)" % [str(mk.shadow_offset), str(tank_off)])
	check(mk.shadow_offset.x > 0.0 and mk.shadow_offset.y > 0.0, "2. ... toward the south-east, away from the north-west sun")
	check(ml.marker("p1").shadow_offset != Vector2.ZERO, "2. (a plane's has its altitude gap)")
	# 3. THE ROSTER
	var rows: Array[Dictionary] = ui.roster.rows()
	eq(rows.map(func(r: Dictionary) -> String: return r["id"]), ["t1", "t2", "p1"], "3. a row for each player unit, the tanks first as they were added")
	eq(rows[0]["type"], "Tank", "3. the row's type is the unit file's name")
	eq(rows[0]["steps"], 2, "3. two steps a turn")
	eq(rows[0]["band"], "surface", "3. on the surface band")
	near(float(rows[0]["speed"]), 8.0, 1e-9, "3. at its cruise")
	eq(rows[0]["health_max"], 6, "3. six pips")
	eq(rows[0]["health"], 6, "3. ... all there")
	# 4. THE CONES
	ui.select("t1")
	await _frames(3)
	var cones = ui.cones
	check(cones.arcs_shown(), "4. the arcs are on (the data's starting state)")
	var recs: Array = cones.collect()
	var mine := recs.filter(func(c: Dictionary) -> bool: return c["unit"] == "t1")
	eq(mine.size(), 1, "4. the selected tank shows its one gun cone")
	if mine.size() == 1:
		var c: Dictionary = mine[0]
		check(float(c["half"]) >= PI - 0.01, "4. ... all the way round (half width %.3f rad)" % float(c["half"]))
		check(absf(float(c["range_px"]) - 350.0 * PPM) < 0.5, "4. ... 350 m of range (%.1f px)" % float(c["range_px"]))
		var wedge: PackedVector2Array = preload("res://scripts/ui/cone_overlay.gd").wedge_points(c, float(c["half"]))
		check(Geometry2D.triangulate_polygon(wedge).size() >= 3, "4. the pie of an all-round cone triangulates (it is drawn as a polygon)")
		var ring: PackedVector2Array = preload("res://scripts/ui/cone_overlay.gd").annulus(c, -PI, PI, 300.0, 330.0)
		check(Geometry2D.triangulate_polygon(ring).size() >= 3, "4. so does its ring of falling odds")
	var before := int(cones.draw_count)
	cones.queue_redraw()
	await _frames(3)
	check(int(cones.draw_count) > before, "4. the cones were drawn")
	eq(int(cones.failed_draws), 0, "4. ... every sub-draw to its end")
	# 5. THE PLAN
	var pl = ui.planner
	var s0: Dictionary = pl.place_point(Vector2(1520.0, 2400.0))
	check(not s0.is_empty() and Vector2(float(s0["x"]), float(s0["y"])).distance_to(Vector2(1520.0, 2400.0)) < 5.0, "5. a step is placed for a tank, where it was asked (a tank step is 20 m)")
	eq(pl.planned_count(), 1, "5. one step planned")
	eq(ui.roster.rows()[0]["planned"], 1, "5. the roster says 1 of 2")
	var s1: Dictionary = pl.place_point(Vector2(1545.0, 2400.0))
	eq(pl.planned_count(), 2, "5. both steps planned")
	check(pl.next_step_index() < 0, "5. a tank has two steps, so the plan is full")
	UiInk.logging = true
	UiInk.drawn.clear()
	ui.roster.queue_redraw()
	ml._marks.queue_redraw()
	pl.queue_redraw()
	await _frames(3)
	UiInk.logging = false
	var texts: Array = (UiInk.drawn as Array).map(func(e: Dictionary) -> String: return str(e["text"]))
	var lines := "\n".join(texts)
	check(lines.contains("Tank"), "3. the roster says 'Tank'")
	check(texts.any(func(t: String) -> bool: return t.begins_with("Tank") and t.contains("surface")), "3. the second line carries its speed and band")
	check(texts.has("0 m · 8"), "2. the map carries the tank's label")
	var min_px := _st.min_px()
	var small: Array = []
	for e: Dictionary in UiInk.drawn:
		if float(e["px"]) < min_px - 0.01 and str(e["kind"]) != "mark_number":
			small.append("%s (%s px)" % [str(e["text"]), str(e["px"])])
	eq(small, [], "3. every string the tank's screen draws is at least %s px (the readable lettering)" % str(min_px))
	# the node's label is two lines: speed over height
	var ps: Array = pl.states()
	check(ps.size() == 2 and float(ps[1]["speed"]) > 0.0, "5. the plan's states: a tank on the move")
	# Ready: the AI tank has no assignment, it flies... drives straight on; the resolve plays back
	ui.auto_begin_turn = false
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	check(not res.is_empty(), "5. Ready is taken and the turn resolves: %s" % w.last_error)
	await _frames(2)
	check(ml.is_playing(), "5. the turn plays back")
	ml.playback_paused = true
	ml.set_playback_time(2.5)
	var mid_pose: Dictionary = ml.pose_of("t1")
	check(Vector2(float(mid_pose["x"]), float(mid_pose["y"])).distance_to(Vector2(1500.0, 2400.0)) > 5.0, "5. the marker followed the history (%.1f m from the start at 2.5 s)" % Vector2(float(mid_pose["x"]), float(mid_pose["y"])).distance_to(Vector2(1500.0, 2400.0)))
	eq(ml.unit_label("t1").begins_with("0 m · "), true, "5. its label follows (%s)" % ml.unit_label("t1"))
	ml.stop_playback()
	# 6. THE FALL: tank e1 destroyed
	var e1: Object = w.units["e1"]
	if w.phase == World.PHASE_RESOLVED:
		w.begin_turn()
	e1.health = 0
	e1.down = true
	e1.fate = "destroyed"
	e1.down_at = NAN
	await _frames(2)
	check(not UiFate.on_map(e1, 0.0, false), "6. a destroyed tank is not on the map as a unit")
	ml.update_poses()
	check(not ml.marker("e1").visible, "6. its marker is gone (the effects layer's ruin takes its place)")
	_done += 1
