extends "res://scripts/test_support/test_case.gd"

# THE TAIL AT THE START (builder PT2, 2026-10-11; Alex's playtest of build 2026-10-10.134839: "The plane motion tails don't
# render at the start. Create a tail for them assuming they are moving forward at normal speed."). Headless. The ribbon trails
# (scripts/ui/wingtip_trails.gd) are recorded from World history when a turn resolves, so at mission start there was nothing to
# draw; every unit that is moving at the start now has a synthetic past behind it (data marker.trails.start_tail, PROPOSED rules).
#
#   1. THE DATA holds the switch and the rules, with Alex's words as the reason
#   2. A MOVING UNIT HAS A RIBBON OF THE WINDOW'S LENGTH BEHIND IT, ALONG ITS HEADING, in the real Strike's first state: the
#      players' three planes and the patrol fighter; the ribbon runs from the plane (age 0) back a window at its speed (the fade's
#      last sliver is not drawn), in its side's accent
#   3. A STATIC UNIT HAS NONE (the tower, the batteries, the bridge), and neither has a ground unit or a ship that is not moving; a
#      plane whose start speed is 0 is taken to fly at its type's normal speed (PROPOSED); a tank and a boat that move have one
#   4. ONLY FROM THE INITIAL STATE: two Worlds built from the same scenario give the same tail, and so does one with a plan already
#      on the fighter; nothing is written into World history; the unit is not moved by it
#   5. IT GIVES WAY TO REAL HISTORY: while turn 1 plays back the window reaches back before the start through the tail; after turn 1
#      has resolved the ribbon is the real one (its far end is where the plane was at the start of the turn), and the tail rolls out
#   6. A GAME ALREADY PAST TURN 1 (a client that joined late) has none, and neither does one that is switched off
#   7. THE FOG still hides it: a unit out of sight has no ribbon

const World = preload("res://scripts/sim/world.gd")
const WingtipTrails = preload("res://scripts/ui/wingtip_trails.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")

const PPM := 2.0

class _Playback extends RefCounted:
	var playback_turn := 1
	var playback_t := 2.5
	func is_playing() -> bool:
		return true
	func marker(_id: String) -> Object:
		return null

var _st: UiStyle
var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, Vector2.ZERO)
var _sentinel := false
var _sections: Array[String] = []

func setup(_main) -> void:
	timeout_seconds = 120.0
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_check_data()
	_check_strike()
	_check_kinds()
	_check_initial_only()
	_check_gives_way()
	_check_not_at_start()
	_sentinel = true
	print("[test] sections run: %s" % ", ".join(_sections))
	eq(_sections.size(), 6, "all six sections ran")
	check(_sentinel, "the test ran to its end (a runtime error would have ended it early, leaving every assertion above unrun)")
	eq(_st.errors.size(), 0, "no style lookup failed: %s" % str(_st.errors))
	finish()

func _node(w: World) -> WingtipTrails:
	var tr := WingtipTrails.new()
	add_child(tr)
	tr.setup(w, _xf, null, _st)
	return tr

func _item(items: Array, id: String) -> Dictionary:
	for it: Dictionary in items:
		if it["unit"] == id:
			return it
	return {}

func _set_start_tail(key: String, value: Variant) -> Variant:
	var blk: Dictionary = _st.ui["marker"]["trails"]["start_tail"]
	var old: Variant = blk[key]
	blk[key] = value
	return old

# A World of the real Strike's first state (the scenario file, populated as the game does).
func _strike_world() -> World:
	var sc := SandboxScenario.new("strike")
	if not sc.ok():
		fail("the Strike scenario did not load: %s" % str(sc.errors))
		return null
	var w := World.new()
	w.quiet = true
	var ids := sc.populate(w)
	if ids.has(""):
		fail("the Strike's units did not all load: %s" % w.last_error)
		return null
	check(sc.water_on, "the Strike has its water on (its boats and bridge are in the World)")
	return w

# --- 1 -------------------------------------------------------------------------

func _check_data() -> void:
	_sections.append("data")
	eq(_st.flag("marker.trails.start_tail.enabled"), true, "1. the start tail is on")
	eq(_st.flag("marker.trails.start_tail.air_at_rest_uses_cruise"), true, "1. a plane at 0 m/s is taken to fly at its normal speed (proposed)")
	check(_st.num("marker.trails.start_tail.min_speed_mps") > 0.0, "1. there is a speed under which a unit counts as not moving")
	check(_st.text("marker.trails.start_tail._reason").contains("tails don't render at the start"), "1. the reason quotes Alex")
	check(_st.text("marker.trails.start_tail._reason").contains("PROPOSED"), "1. and says what is proposed")
	eq(_st.text("marker.trails.mode"), "ribbon", "1. (the ribbon is the mode: Alex's choice)")
	eq(_st.text("marker.trails.applies_to"), "all", "1. (and every unit in sight has one)")

# --- 2 -------------------------------------------------------------------------

func _check_strike() -> void:
	_sections.append("strike")
	var w := _strike_world()
	if w == null:
		return
	var tr := _node(w)
	var win := _st.num("marker.trails.window_turns") * float(w.rules.turn_seconds)
	eq(win, 5.0, "2. the window is one turn: 5 s")
	var items := tr.collect()
	var moving := ["bomber_1", "light_fighter_1", "heavy_fighter_1", "patrol_1"]
	for id: String in moving:
		var u = w.units[id]
		check(u.history.is_empty(), "2. %s has no history: nothing has resolved, the tail is not History" % id)
		var it := _item(items, id)
		if not check(not it.is_empty(), "2. %s has a ribbon at the start of the mission" % id):
			continue
		var centre: PackedVector2Array = it["centre"]
		var age: PackedFloat64Array = it["age"]
		var here := Vector2(float(u.x), float(u.y))
		check(centre[0].is_equal_approx(_xf * here), "2. %s: the ribbon starts at the unit" % id)
		near(age[0], 0.0, 1e-9, "2. %s: age 0 at the unit" % id)
		var far: Vector2 = (centre[centre.size() - 1] - centre[0]) / PPM   # world metres
		var dir := Vector2.from_angle(float(u.heading))
		var run := far.length()
		# a window of path at the unit's speed (the last tenth of a second of the fade is under min_alpha and is not drawn)
		var expect := float(u.speed) * win
		check(run > expect * 0.95 and run <= expect + 1e-3, "2. %s: it is a window long (%.1f m of the %.1f m a window at %.0f m/s is)" % [id, run, expect, float(u.speed)])
		check(far.normalized().dot(-dir) > 0.9999, "2. %s: and runs straight back along minus its heading" % id)
		check(age[age.size() - 1] > 0.95 and age[age.size() - 1] <= 1.0, "2. %s: to the far end of the window (%.3f)" % [id, age[age.size() - 1]])
		# straight: every centre point lies on the line behind the unit
		var straight := true
		for p: Vector2 in centre:
			var rel: Vector2 = (p - centre[0]) / PPM
			if absf(rel.cross(dir)) > 1e-3:
				straight = false
		check(straight, "2. %s: a straight path" % id)
		var accent: Color = it["accent"]
		check(accent.is_equal_approx(_st.side_color(str(u.side))), "2. %s: in its own side's accent" % id)
		# wingtips on each side of the centre line, a half-span out (the drawn half-span at the unit)
		var l: PackedVector2Array = it["left"]
		var r: PackedVector2Array = it["right"]
		check(l[l.size() - 1].distance_to(r[r.size() - 1]) > 1.0, "2. %s: a ribbon with a width, not a line" % id)
	# the order of the tail's age is the order of its distance
	var it1 := _item(items, "light_fighter_1")
	if not it1.is_empty():
		var ages: PackedFloat64Array = it1["age"]
		var mono := true
		for i in range(1, ages.size()):
			if ages[i] < ages[i - 1] - 1e-12:
				mono = false
		check(mono, "2. age only grows away from the plane")
		check(WingtipTrails.fade(0.0, _st) == 1.0 and WingtipTrails.fade(0.5, _st) < 1.0, "2. it fades as the real ribbon does")
	tr.queue_free()
	_strike_w = w

var _strike_w: World = null

# --- 3 -------------------------------------------------------------------------

func _check_kinds() -> void:
	_sections.append("kinds")
	# Static units of the Strike have none, in the real scenario.
	var w := _strike_w
	var tr := _node(w)
	var items := tr.collect()
	for id: String in w.units:
		if (w.units[id].def as Object).is_static():
			check(not tr._buf.has(id), "3. %s is static: no tail is recorded for it" % id)
			check(_item(items, id).is_empty(), "3. %s: and none is drawn" % id)
	check(w.units.has("radio_tower_1") and w.units.has("aa_battery_1") and w.units.has("bridge_1"), "3. (the Strike has its tower, batteries and bridge)")
	# The boats are moving at the start: they have one (the scenario's own water units).
	for id: String in ["patrol_boat_1", "supply_boat_1"]:
		if w.units.has(id):
			check(float(w.units[id].speed) > 1.0, "3. %s starts moving (%.1f m/s)" % [id, float(w.units[id].speed)])
			check(tr._buf.has(id), "3. %s is a ship that is moving: it has a tail" % id)
	tr.queue_free()

	# A hand-built world for the other kinds.
	var h := World.new()
	h.quiet = true
	h.add_player("local")
	h.add_unit({"id": "rest_plane", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.5, "speed": 0.0})
	h.add_unit({"id": "tank_go", "type": "tank", "side": "allies", "controller": "player", "x": 1000.0, "y": 1400.0, "heading": 0.0})
	h.add_unit({"id": "tank_stopped", "type": "tank", "side": "allies", "controller": "player", "x": 1000.0, "y": 1600.0, "heading": 0.0, "speed": 0.0})
	h.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 3000.0, "y": 3000.0, "heading": 0.0})
	h.add_unit({"id": "boat_stopped", "type": "patrol_boat", "side": "axis", "controller": "ai", "x": 3000.0, "y": 3400.0, "heading": 1.0, "speed": 0.0})
	h.add_unit({"id": "boat_going", "type": "patrol_boat", "side": "axis", "controller": "ai", "x": 3000.0, "y": 3800.0, "heading": 1.0})
	if not check(h.ok(), "3. the hand-built world loads: %s" % str(h.errors)):
		return
	var t2 := _node(h)
	t2.collect()
	var win := 5.0
	# A plane at rest is taken to fly at its type's normal speed (PROPOSED).
	var rest: Dictionary = t2._buf.get("rest_plane", {})
	if check(not rest.is_empty(), "3. a plane whose start speed is 0 has a tail anyway (proposed: it is taken to fly at its normal speed)"):
		var cruise := float(h.units["rest_plane"].def.envelope.speed_cruise)
		check(cruise > 50.0, "3. (the light fighter's normal speed is %.0f m/s)" % cruise)
		var xs: PackedFloat64Array = rest["x"]
		var ys: PackedFloat64Array = rest["y"]
		var back := Vector2(xs[0], ys[0]).distance_to(Vector2(1000.0, 1000.0))
		near(back, cruise * win, 1e-3, "3. its tail is a window of path at that speed (Vector2 is float32)")
		near(absf(angle_difference((Vector2(xs[0], ys[0]) - Vector2(1000.0, 1000.0)).angle(), 0.5 + PI)), 0.0, 1e-5, "3. straight behind its heading")
		eq(float(h.units["rest_plane"].speed), 0.0, "3. and the unit itself is still at 0: only the drawing assumed a speed")
	check(t2._buf.has("tank_go"), "3. a tank that moves has a tail")
	check(not t2._buf.has("tank_stopped"), "3. a tank that is not moving has none")
	check(not t2._buf.has("tower"), "3. a tower has none")
	check(not t2._buf.has("boat_stopped"), "3. a ship that is not moving has none")
	check(t2._buf.has("boat_going"), "3. a ship that moves has a tail")
	if t2._buf.has("tank_go"):
		var tb: Dictionary = t2._buf["tank_go"]
		var tx: PackedFloat64Array = tb["x"]
		near(1000.0 - tx[0], float(h.units["tank_go"].speed) * win, 1e-9, "3. a tank's tail is a window at its own speed")
	# The rule on its own.
	var def_tank = h.units["tank_go"].def
	var def_plane = h.units["rest_plane"].def
	var def_tower = h.units["tower"].def
	eq(WingtipTrails.start_tail_speed(def_tower, 50.0, _st), 0.0, "3. a static unit has no tail speed, whatever it is given")
	eq(WingtipTrails.start_tail_speed(def_tank, 0.2, _st), 0.0, "3. a tank under min_speed_mps is not moving")
	eq(WingtipTrails.start_tail_speed(def_tank, -2.0, _st), -2.0, "3. a tank reversing keeps its (negative) speed: the tail is in front")
	eq(WingtipTrails.start_tail_speed(def_plane, 0.0, _st), float(def_plane.envelope.speed_cruise), "3. a plane at 0 takes its normal speed")
	var old: Variant = _set_start_tail("air_at_rest_uses_cruise", false)
	eq(WingtipTrails.start_tail_speed(def_plane, 0.0, _st), 0.0, "3. unless the data says it does not")
	_set_start_tail("air_at_rest_uses_cruise", old)
	t2.queue_free()

# --- 4 -------------------------------------------------------------------------

func _check_initial_only() -> void:
	_sections.append("initial")
	var a := _strike_world()
	var b := _strike_world()
	if a == null or b == null:
		return
	# A plan on the fighter in B before its node is built: the plan is not the state, the tail is the same.
	b.plan_step("light_fighter_1", 0, {"turn": 0.3})
	var ta := _node(a)
	var tb := _node(b)
	ta.collect()
	tb.collect()
	eq(ta._buf.keys().size() > 0, true, "4. there are tails to compare")
	eq(ta._buf.keys(), tb._buf.keys(), "4. the same units have one in two Worlds built from the same scenario")
	var same := true
	for id: String in ta._buf:
		var ra: Dictionary = ta._buf[id]
		var rb: Dictionary = tb._buf[id]
		for key: String in ["t", "x", "y", "h"]:
			if (ra[key] as PackedFloat64Array) != (rb[key] as PackedFloat64Array):
				same = false
	check(same, "4. and the same tail, sample for sample (it is a function of the initial state and the data alone)")
	# The items drawn are the same too.
	var ia := ta.collect()
	var ib := tb.collect()
	eq(ia.size(), ib.size(), "4. the same ribbons are collected")
	var same_items := true
	for it: Dictionary in ia:
		var o := _item(ib, str(it["unit"]))
		if o.is_empty() or (it["left"] as PackedVector2Array) != (o["left"] as PackedVector2Array) or (it["right"] as PackedVector2Array) != (o["right"] as PackedVector2Array):
			same_items = false
	check(same_items, "4. every point of every ribbon agrees")
	# Nothing was written into the World.
	for id: String in a.units:
		eq(a.units[id].history.size(), 0, "4. %s: the World's history is untouched" % id)
	# Asked again later (the unit not moved, the node built later): the same.
	var tc := _node(_strike_world())
	tc.collect()
	check((tc._buf["bomber_1"]["x"] as PackedFloat64Array) == (ta._buf["bomber_1"]["x"] as PackedFloat64Array), "4. a node built later draws the same tail")
	ta.queue_free()
	tb.queue_free()
	tc.queue_free()

# --- 5 -------------------------------------------------------------------------

func _check_gives_way() -> void:
	_sections.append("gives_way")
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 4200.0, "y": 4200.0, "heading": 3.0})
	var tr := _node(w)
	var start := Vector2(1500.0, 1500.0)
	var speed := float(w.units["p1"].speed)
	var win := 5.0
	# Planning turn 1: the whole window behind the start.
	var plan_item := _item(tr.collect(), "p1")
	if check(not plan_item.is_empty(), "5. turn 1, planning: the plane has its tail"):
		var c: PackedVector2Array = plan_item["centre"]
		check(c[0].is_equal_approx(_xf * start), "5. it ends at the plane")
		check(((c[c.size() - 1] - c[0]) / PPM).length() > speed * win * 0.95, "5. and reaches back a window")
	# Turn 1 resolves: the node records it through World.turn_resolved, as in the game.
	for k in w.steps_per_turn("p1"):
		w.plan_step("p1", k, {"turn": 0.1})
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	check(not res.is_empty(), "5. turn 1 resolves")
	var u = w.units["p1"]
	var h0: Dictionary = u.history[0]
	check(Vector2(float(h0["x"]), float(h0["y"])).is_equal_approx(start), "5. (the history's first state is the start: where the tail was drawn from)")
	var ts: PackedFloat64Array = tr._buf["p1"]["t"]
	check(ts[0] < -win + 0.2 and ts[ts.size() - 1] > win - 0.2, "5. the record now holds the tail (before game time 0) and turn 1 after it")
	# Playing back turn 1, 2.5 s in: the window reaches back past the start, through the tail.
	var pb := _Playback.new()
	tr.marker_layer = pb
	var it := _item(tr.collect(), "p1")
	if check(not it.is_empty(), "5. turn 1, playing back: a ribbon"):
		near(tr.now(), 2.5, 1e-9, "5. it ends at the playback clock")
		var c2: PackedVector2Array = it["centre"]
		var here := w.sample("p1", 2.5, "history")
		check(c2[0].distance_to(_xf * Vector2(float(here["x"]), float(here["y"]))) < 0.2, "5. at the plane's place now")
		var far2: Vector2 = c2[c2.size() - 1] / PPM
		# The far end is 2.5 s before the start: the tail, along minus the heading, at the start speed.
		var tail_end := start - Vector2.from_angle(float(h0["heading"])) * float(h0["speed"]) * 2.4   # (the 0.1 s under min_alpha is not drawn)
		check(far2.distance_to(tail_end) < 2.0, "5. its far end is on the tail, before the start (%s against %s)" % [str(far2), str(tail_end)])
	# Turn 2 planning: the ribbon is the real turn 1, and the tail is out of the window.
	tr.marker_layer = null
	w.begin_turn()
	var it2 := _item(tr.collect(), "p1")
	if check(not it2.is_empty(), "5. turn 2, planning: the real ribbon"):
		var c3: PackedVector2Array = it2["centre"]
		var begin: Vector2 = c3[c3.size() - 1] / PPM
		check(begin.distance_to(start) < speed * 0.2, "5. its far end is where the plane was at the start of turn 1, not the tail (%s)" % str(begin))
		var behind_start := false
		for p: Vector2 in c3:
			if (p / PPM).x < start.x - speed * 0.25:
				behind_start = true
		check(not behind_start, "5. nothing of the tail is in it")
	tr.queue_free()

# --- 6 and 7 -------------------------------------------------------------------

func _check_not_at_start() -> void:
	_sections.append("not_at_start")
	# A game already past turn 1 when the node first looks: none.
	var late := World.new()
	late.quiet = true
	late.add_player("local")
	late.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	late.turn = 3
	var tl := _node(late)
	eq(tl.collect().size(), 0, "6. a game already at turn 3 (a client that joined late) has no start tail")
	tl.queue_free()
	# A node mounted at turn 1 whose game then jumps ahead without it seeing a turn resolve (a snapshot arrived): the tail is forgotten.
	var snap := World.new()
	snap.quiet = true
	snap.add_player("local")
	snap.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	var ts := _node(snap)
	eq(ts.collect().size(), 1, "6. (at turn 1 it has one)")
	snap.turn = 5
	eq(ts.collect().size(), 0, "6. the game moved on without this node seeing a turn: the stale tail is gone")
	ts.queue_free()
	# Switched off.
	var old: Variant = _set_start_tail("enabled", false)
	var off := World.new()
	off.quiet = true
	off.add_player("local")
	off.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	var to := _node(off)
	eq(to.collect().size(), 0, "6. with start_tail.enabled false there is none")
	to.queue_free()
	_set_start_tail("enabled", old)
	# 7. The fog.
	var fog := World.new()
	fog.quiet = true
	fog.add_player("local")
	fog.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	fog.add_unit({"id": "e1", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 3200.0, "y": 1500.0, "heading": PI})
	var tf := _node(fog)
	eq(tf.collect().size(), 2, "7. both planes have a ribbon in the open")
	tf.unit_visible = func(id: String) -> bool: return id != "e1"
	var seen := tf.collect()
	eq(seen.size(), 1, "7. a unit out of sight has none (the fog hides the tail as it hides the real ribbon)")
	check(not _item(seen, "p1").is_empty(), "7. the player's own stays")
	tf.queue_free()
