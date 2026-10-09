extends "res://scripts/test_support/test_case.gd"

# THE MOTION PLANNER (Track U, exit criterion 3: "a plan is a curve of steps;
# each step is a point inside the plane's performance envelope; inertia
# applies"), driven headless through its public methods -- the same ones its
# mouse handlers call -- on a UnitUI mounted as Track A will mount it:
#
#   1. a point outside the reachable set comes back CLAMPED, and what the
#      planner draws (its states and its curve) is the clamped result, on the
#      edge of the fan it showed
#   2. a point inside the fan is taken as asked
#   3. steps chain: each fan starts where the step before it ends
#   4. altitude per step: climb / level / dive on the last placed step
#   5. undo drops the last step and leaves the others as they were; clear
#      empties the plan
#   6. drag: begin / drag / end plans one step that follows the pointer; a
#      screen press through the host mapping lands the same at any scale
#   7. Ready commits the local player and locks the plan; pressed again it
#      withdraws
#   8. the turn plays: with the AI in, Ready resolves; the markers animate
#      along the histories (World.sample) and the next turn begins

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")

const PPM := 3.8

var _played: Array[int] = []

func setup(_main) -> void:
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2700.0, "heading": 0.0})
	w.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1800.0, "heading": PI})
	var origin := Vector2(1400.0, 2200.0)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var pl := ui.planner
	ui.select("p1")

	# 1. Outside the envelope: 90 degrees right of the nose and far off.
	eq(pl.next_step_index(), 0, "an empty plan places step 1 next")
	var fan0 := pl.fan_outline_world()
	check(fan0.size() >= 6, "the next step's fan is a polygon (%d points)" % fan0.size())
	var out := pl.place_point(Vector2(1500.0, 3400.0))
	if not check(not out.is_empty(), "a point outside the fan still plans a step: %s" % w.last_error):
		finish()
		return
	check(bool(out["clamped"]), "a point outside the reachable set comes back clamped")
	check((out["limits"] as Array).has("turn"), "clamped by the turn limit (limits %s)" % str(out["limits"]))
	var st0: Dictionary = pl.states()[0]
	eq(st0["x"], out["x"], "the planner's state for step 1 is the clamped result (x)")
	eq(st0["y"], out["y"], "the planner's state for step 1 is the clamped result (y)")
	var end0 := Vector2(float(out["x"]), float(out["y"]))
	check(_dist_to_poly(end0, fan0) < 0.5, "the clamped end lies on the fan it showed (%.3f m off)" % _dist_to_poly(end0, fan0))
	var curve: Array = pl.path_world("p1")
	eq(curve.size(), 5, "the curve covers all five steps")
	var seg0: PackedVector2Array = curve[0][0]
	check(seg0[seg0.size() - 1].distance_to(end0) < 1e-3, "the drawn curve ends step 1 at the clamped point")
	check(bool(curve[0][1]) and not bool(curve[1][1]), "step 1 draws as planned, step 2 as carry-on")
	check(seg0[0].distance_to(Vector2(1500.0, 2400.0)) < 1e-3, "the curve starts at the unit")

	# 2. Inside the fan for step 2: the middle of the band.
	var r1 := w.reachable("p1", 1)
	var o1: PackedVector2Array = r1["outline"]
	var half := o1.size() / 2
	var mid := (o1[half / 2] + o1[o1.size() - 1 - half / 2]) * 0.5
	var in1 := pl.place_point(mid)
	check(not bool(in1["clamped"]), "a point inside the fan is not clamped (limits %s)" % str(in1.get("limits")))
	check(Vector2(float(in1["x"]), float(in1["y"])).distance_to(mid) < 1.0, "it lands where it was asked (%.3f m)" % Vector2(float(in1["x"]), float(in1["y"])).distance_to(mid))
	eq(pl.next_step_index(), 2, "two steps placed, step 3 next")
	eq(pl.planned_count(), 2, "planned_count counts them")
	eq(ui.roster.rows()[0]["planned"], 2, "the roster shows 2 of 5")

	# 3. Chaining: the next fan starts where step 2 ends.
	var r2 := pl.reachable_next()
	near(float(r2["speed"]), float(in1["speed"]), 1e-9, "step 3's envelope starts at step 2's end speed")
	var o2: PackedVector2Array = r2["outline"]
	var reach := float(r2["speed"]) * w.step_dt("p1")
	var d2 := o2[o2.size() / 4].distance_to(Vector2(float(in1["x"]), float(in1["y"])))
	check(absf(d2 - reach) < reach * 0.1, "step 3's fan is one step's flight from step 2's end (%.1f m vs %.1f m)" % [d2, reach])

	# 4. Altitude on the last placed step.
	var climb := pl.change_band(1)
	eq(climb.get("altitude_band"), "high", "climb takes step 2 from medium to high")
	eq(pl.states()[1]["altitude_band"], "high", "the plan shows step 2 at high")
	var opts := pl.band_options()
	check(bool(opts[1]) and bool(opts[0]) and bool(opts[-1]), "from medium, step 2 may climb, hold or dive (%s)" % str(opts))
	var level := pl.change_band(0)
	eq(level.get("altitude_band"), "medium", "level puts step 2 back at the band it started in")
	var dive := pl.change_band(-1)
	eq(dive.get("altitude_band"), "low", "dive takes step 2 to low")
	eq(pl.set_step_band(1, "medium").get("altitude_band"), "medium", "set_step_band sets one step's band")
	near(float(pl.states()[1]["x"]), float(in1["x"]), 1e-6, "a band change keeps the step's point (same band, same place)")

	# 5. Undo and clear.
	var before0: Dictionary = pl.states()[0]
	check(pl.undo(), "undo drops the last step")
	eq(pl.planned_count(), 1, "one step left")
	eq(pl.next_step_index(), 1, "step 2 is next again")
	eq(pl.states()[0]["x"], before0["x"], "undo leaves step 1 where it was (x)")
	eq(pl.states()[0]["y"], before0["y"], "undo leaves step 1 where it was (y)")
	check(not bool(pl.states()[1]["planned"]), "step 2 is carry-on again")
	pl.clear()
	eq(pl.planned_count(), 0, "clear empties the plan")
	eq((w.units["p1"].plan as Array).size(), 0, "the world's plan is empty")
	check(not pl.undo(), "nothing to undo on an empty plan")

	# 6. Drag, and screen presses at two scales.
	var a := Vector2(1600.0, 2380.0)
	var b := Vector2(1595.0, 2420.0)
	pl.begin_step(a)
	check(pl.is_dragging(), "begin_step starts a drag")
	pl.drag_step(b)
	var dragged := pl.end_step()
	check(not pl.is_dragging(), "end_step ends it")
	eq(pl.planned_count(), 1, "a drag plans one step, however far it moves")
	var direct := w.plan_step("p1", 0, {"to": b})
	eq(dragged["x"], direct["x"], "the drag's step steers for where the pointer ended")
	pl.clear()
	var screen_b: Vector2 = xf * b
	check(pl.press(xf * Vector2(float(direct["x"]), float(direct["y"]))), "a press on the fan starts a step")
	pl.release(screen_b)
	var at_k1: Dictionary = pl.states()[0]
	pl.clear()
	var xf2 := Transform2D(0.0, Vector2(PPM * 0.5, PPM * 0.5), 0.0, Vector2(-300.0, -900.0))
	ui.set_mapping(xf2)
	check(pl.press(xf2 * Vector2(float(direct["x"]), float(direct["y"]))), "at half the scale a press on the fan still starts a step")
	pl.release(xf2 * b)
	near(float(pl.states()[0]["x"]), float(at_k1["x"]), 1e-3, "the same world point, whatever the host's scale")
	check(not pl.press(xf2 * Vector2(900.0, 900.0)), "a press far from the fan does not start a step")
	ui.set_mapping(xf)
	# Re-drag a planned step by its handle.
	var h_screen: Vector2 = xf * Vector2(float(pl.states()[0]["x"]), float(pl.states()[0]["y"]))
	eq(pl.handle_at(h_screen), 0, "step 1's end is a handle")
	check(pl.press(h_screen), "pressing a handle re-drags that step")
	pl.release(xf * a)
	eq(pl.planned_count(), 1, "re-dragging does not add a step")

	# The real input path: mouse events through UnitUI's own handler (the map
	# layers sit in a CanvasLayer, so viewport and layer points are the same).
	pl.clear()
	var fan_mid := _fan_middle(pl.fan_outline_world())
	var press_ev := InputEventMouseButton.new()
	press_ev.button_index = MOUSE_BUTTON_LEFT
	press_ev.pressed = true
	press_ev.position = xf * fan_mid
	ui._unhandled_input(press_ev)
	check(pl.is_dragging(), "a mouse press on the fan starts a step")
	var move_ev := InputEventMouseMotion.new()
	move_ev.position = xf * (fan_mid + Vector2(0.0, 6.0))
	ui._unhandled_input(move_ev)
	var release_ev := InputEventMouseButton.new()
	release_ev.button_index = MOUSE_BUTTON_LEFT
	release_ev.pressed = false
	release_ev.position = move_ev.position
	ui._unhandled_input(release_ev)
	check(not pl.is_dragging(), "the mouse release ends it")
	eq(pl.planned_count(), 1, "one step from a press, a drag and a release")
	var key_ev := InputEventKey.new()
	key_ev.keycode = OS.find_keycode_from_string(ui.style.text("keys.undo"))
	key_ev.pressed = true
	ui._unhandled_input(key_ev)
	eq(pl.planned_count(), 0, "the undo key drops it")
	pl.place_point(a)

	# 7. Ready.
	check(not pl.ready_up(), "Ready alone does not make everyone ready (the AI has not planned)")
	check(w.is_ready("local"), "Ready commits the local player")
	check(not pl.can_plan(), "a readied player's plans are locked")
	check(pl.place_point(Vector2(1600.0, 2400.0)).is_empty(), "no step can be placed while ready")
	check(ui.orders.press_button("ready"), "the orders card's Ready, pressed again")
	check(not w.is_ready("local"), "withdraws")
	check(pl.can_plan(), "and plans open again")

	# 8. The turn plays.
	var ai := AiDumb.new(w)
	ai.attach()
	check(w.is_ready(World.AI_PLAYER), "the AI readied itself")
	ui.turn_played.connect(func(t: int) -> void: _played.append(t))
	ui.select("p1")
	pl.place_point(Vector2(1600.0, 2380.0))
	check(ui.orders.press_button("ready"), "Ready through the orders card")
	eq(w.phase, World.PHASE_RESOLVED, "everyone ready: the turn resolved")
	check(ui.marker_layer.is_playing(), "the markers play the turn back")
	for t: float in [0.0, 1.3, 2.5, 4.9]:
		ui.marker_layer.set_playback_time(t)
		for id: String in ["p1", "p2", "ai1"]:
			var s := w.sample(id, t, "history")
			var want: Vector2 = xf * Vector2(float(s["x"]), float(s["y"]))
			check(ui.marker_layer.marker(id).position.distance_to(want) < 1e-3, "%s at %.1f s is where World.sample puts it" % [id, t])
	var p1_mid := ui.roster.rows()[0]
	ui.marker_layer.set_playback_time(0.0)
	near(float(ui.roster.rows()[0]["speed"]), 100.0, 1e-9, "during playback the roster shows the speed at the playback time")
	check(p1_mid.has("speed"), "rows carry speed during playback")
	var guard := 0
	while ui.marker_layer.is_playing() and guard < 1000:
		ui.marker_layer.advance_playback(1.0 / 60.0)
		guard += 1
	check(guard < 1000, "playback ends")
	eq(_played, [1] as Array[int], "turn_played fired for turn 1")
	eq(w.phase, World.PHASE_PLANNING, "the next turn began")
	eq(w.turn, 2, "it is turn 2")
	var u1 = w.units["p1"]
	check(ui.marker_layer.marker("p1").position.distance_to(xf * Vector2(float(u1.x), float(u1.y))) < 1e-3, "after playback the marker is where the unit is")
	eq(pl.next_step_index(), 0, "a fresh plan for turn 2")
	finish()

func _fan_middle(o: PackedVector2Array) -> Vector2:
	var half := o.size() / 2
	return (o[half / 2] + o[o.size() - 1 - half / 2]) * 0.5

func _dist_to_poly(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		best = minf(best, q.distance_to(p))
	return 0.0 if Geometry2D.is_point_in_polygon(p, poly) else best
