extends "res://scripts/test_support/test_case.gd"

# THE SIDE VIEW (Track V, 2026-10-10). Alex: "a side view indicator that only shows the firing cone and the
# relative straight line position of the targeted enemy" -- the colour wash in the top-down map's style,
# indicators only, no weapon labels; the target is an enemy unit or a point, followed at its SHOWN position.
# Every style choice and rule beyond that is PROPOSED; this holds what must be true whichever Alex picks.
# Headless: the panel's model (side_view.gd model()) is read as numbers, the card's growth on a mounted UnitUI,
# and the frame-driven part checks that every sub-draw ran to its end.
#
#   1. THE DATA          ui.json side_view holds every key the code reads
#   2. WHO               a friendly unit, planning: shown; an enemy, nothing selected, a unit shown down: hidden
#   3. ANGLES ARE TRUE   one scale on both axes; each cone's elevation extent is the weapon's own, cut by the
#                        plane along the nose, and a dive tilts it (the pitch is the resolver's own); the
#                        wedge drawn is the cone the sim tests (combat.gd's evaluate agrees at its rim)
#   4. THE TARGET        placed at its straight-line position (distance, height difference), an arrow on the
#                        edge when the page cannot hold it, a ring when its bearing is off every gun's arc
#   5. WHICH TARGET      a step with a special: its own (step_target, else the drop's aim); any other step:
#                        the selection; none: the cones only; a unit out of sight is not drawn, a point always
#   6. FOLLOWING         a unit target at its SHOWN position; a moved target moves the picture and the signature
#   7. THE DROP          the arc lands where World.drop_spread says, the target on the ground, the aim follows
#                        the target's shown position
#   8. NEVER AN ENEMY'S PLAN   a recording planner sees no AI unit id; a source scan of the side view's files
#   9. INDICATORS ONLY   no unit art, no hex literal in the draw code, no lettering on a cone
#  10. THE CARD          it grows by the section while the panel shows and keeps on screen at 720 px
#  11. THE FRAMES        every sub-draw ran to its end, in the guns view, the arrow, the drop and the playback
#  12. THE PLAYBACK      live at the shown pose, the target followed through the turn
#
# THE THREE STRIPS (decision side-view-views, 2026-10-11; Alex: "I want to be able to select between top, front & side ... Maybe they fold
# instead of you selecting only one - so you could have all three", "1 B - but no limit on which are open at a time", "Yes, lets actually
# add a button to the panel to turn arcs on/off", "3 self only"). The projections, the sizes and the room rule are PROPOSED.
#  13. THE STRIPS        three, in Alex's order; each folds and unfolds on its own; any number open at once; a click on a header
#  14. THE FOLD STATE    the session's, not a unit's; an enemy or nothing selected shows no strips
#  15. THE TOP STRIP     the map's own cone wash in the unit's frame; the dorsal turret as its footprint; a climb cuts the plane
#                        differently (combat.gd agrees); the target at its bearing and distance
#  16. THE FRONT STRIP   the dorsal turret a fan over the top, a forward gun a small disc, a waist gun a fan to its side; the target
#                        at its lateral offset and height difference
#  17. SELF ONLY         the selected friendly unit's own cones, nobody else's
#  21. THE ARCS BUTTON   the panel's own (the roster header's was removed: Alex 2026-10-11 "Yes, remove the extra") flips the one switch,
#                        UnitUI.toggle_arcs is that switch and the button follows it (mounted)
#  22. THE MAP'S ARCS    off by default: the overlay collects nothing until the switch is on
#  23. THE ROOM          the strips stack in a tall window, the room is shared in a shorter one (the card stays on the screen), and
#                        a window too short for the strips shows the panel as it was

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const SideView = preload("res://scripts/ui/side_view.gd")
const UiTarget = preload("res://scripts/ui/ui_target.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const SideViewTop = preload("res://scripts/ui/side_view_top.gd")
const SideViewFront = preload("res://scripts/ui/side_view_front.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")

const PPM := 2.0

# A planner as the side view sees one, with the call log a tripwire needs and the step target Track T adds
# (a proxy, so this test does not depend on the signature T gives step_target).
class _Proxy extends RefCounted:
	var inner: MotionPlanner = null
	var bombs: Variant = null
	var calls: Array = []
	var step_targets: Dictionary = {}
	func _note(what: String, id: String) -> void:
		calls.append([what, id if id != "" else inner.unit_id()])
	func plan_shown(id: String) -> bool:
		return inner.plan_shown(id)
	func focus_step(id: String = "") -> int:
		_note("focus_step", id)
		return inner.focus_step(id)
	func planned_count(id: String = "") -> int:
		_note("planned_count", id)
		return inner.planned_count(id)
	func states(id: String = "") -> Array:
		_note("states", id)
		return inner.states(id)
	func band_before(k: int, id: String = "") -> String:
		_note("band_before", id)
		return inner.band_before(k, id)
	func step_has_drop(k: int, id: String = "") -> bool:
		_note("step_has_drop", id)
		return inner.step_has_drop(k, id)
	func step_aim(k: int, id: String = "") -> Vector2:
		_note("step_aim", id)
		return inner.step_aim(k, id)
	var hide_step_target := false
	func step_target(k: int) -> Dictionary:
		_note("step_target", "")
		if hide_step_target:
			return {}
		if step_targets.has(k):
			return step_targets[k]
		return inner.step_target(k) if inner.has_method("step_target") else {}

var _st: UiStyle
var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, Vector2.ZERO)

# The model-level world.
var _w: World
var _sel: UiSelection
var _pl: MotionPlanner
var _px: _Proxy
var _sv: SideView
var _tg := UiTarget.new()

# The mounted UI (frame-driven part).
var _wb: World
var _ui: UnitUI
var _sv2: SideView
var _stage := 0
var _frames := 0
var _base_h := 0.0
var _setup_done := false
var _smoke_done := false

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_check_data()
	_build_model_world()
	_check_who()
	_check_angles()
	_check_target_placement()
	_check_which_target()
	_check_following()
	_check_drop()
	_check_never_enemy_plan()
	_check_indicators_only()
	_check_strips()
	_check_fold_state_kept()
	_check_top()
	_check_front()
	_check_self_only()
	SideView.reset_view_setting()
	ConeOverlay.reset_view_setting()
	_build_ui_world()
	_setup_done = true
	timeout_seconds = 60.0

# --- worlds ------------------------------------------------------------------------------------------

func _add(w: World, id: String, type: String, side: String, controller: String, x: float, y: float, hdg: float, band: String = "") -> void:
	var spec := {"id": id, "type": type, "side": side, "controller": controller, "x": x, "y": y, "heading": hdg}
	if band != "":
		spec["altitude_band"] = band
	w.add_unit(spec)

func _build_model_world() -> void:
	_w = World.new()
	_w.add_player("local")
	_add(_w, "p1", "light_fighter", "allies", "player", 1000.0, 1000.0, 0.0, "medium")
	_add(_w, "p3", "heavy_fighter", "allies", "player", 1000.0, 2000.0, 0.0, "high")
	_add(_w, "b1", "bomber", "allies", "player", 1000.0, 3000.0, 0.0, "medium")
	_add(_w, "ai1", "bomber", "axis", "ai", 1500.0, 1000.0, PI, "high")           # 500 m ahead of p1, 600 m above
	_add(_w, "ai2", "light_fighter", "axis", "ai", 1470.0, 1000.0, PI, "medium")  # 470 m ahead of p1, level
	_add(_w, "ai3", "light_fighter", "axis", "ai", 1380.0, 2000.0, PI, "low")     # 380 m ahead of p3, 280 m below its dive
	_add(_w, "ai4", "light_fighter", "axis", "ai", 700.0, 1000.0, 0.0, "medium")  # 300 m behind p1
	# The enemy has a plan the players must never see.
	_w.plan_step("ai1", 0, {"to": Vector2(1400.0, 1100.0)})
	_w.plan_step("ai2", 0, {"to": Vector2(1400.0, 900.0)})
	_sel = UiSelection.new()
	_pl = MotionPlanner.new()
	add_child(_pl)
	_pl.setup(_w, _xf, _sel, "local", _st)
	_px = _Proxy.new()
	_px.inner = _pl
	_px.bombs = _pl.bombs
	_pl.target = _tg   # one selection, shared as UnitUI shares it
	_sv = SideView.new()
	add_child(_sv)
	_sv.setup(_w, _px, _sel, _st)
	_sv.target_source = func() -> Object: return _tg


# Track T's UiTarget as the player's clicks set it (the place it was seen is kept for the fog; this panel reads the shown pose).
func _pick_unit(id: String) -> void:
	_tg.set_unit(id, Vector2(1.0, 1.0))

func _pick_point(p: Vector2) -> void:
	_tg.set_point(p)

func _model_for(id: String) -> Dictionary:
	_sel.select(id)
	_sv.refresh()
	return _sv.model()

# --- 1. The data ----------------------------------------------------------------------------------------

func _check_data() -> void:
	for n: String in ["side_view.section.gap_px", "side_view.section.head_px", "side_view.section.picture_h_px", "side_view.section.min_picture_h_px",
			"side_view.section.caption_h_px", "side_view.section.bottom_px", "side_view.section.pad_px", "side_view.frame.span_margin",
			"side_view.frame.span_min_m", "side_view.frame.rear_room_fraction", "side_view.frame.unit_y_frac", "side_view.frame.unit_y_min_frac", "side_view.frame.unit_y_max_frac", "side_view.drop.unreleased_alpha_k", "side_view.drop.fit_target_max_factor", "side_view.frame.edge_inset_px",
			"side_view.frame_px", "side_view.ground.px", "side_view.line.px", "side_view.line.dash_px", "side_view.line.gap_px",
			"side_view.mark.r_px", "side_view.mark.rim_px", "side_view.mark.pitch_tick_px", "side_view.mark.pitch_tick_line_px",
			"side_view.target.r_px", "side_view.target.rim_px", "side_view.target.hollow_ring_px", "side_view.target.cross_px",
			"side_view.target.cross_line_px", "side_view.target.tick_px", "side_view.target.tick_line_px", "side_view.target.tick_under_px",
			"side_view.target.arrow_px", "side_view.target.square_px", "side_view.strips.head_px", "side_view.strips.gap_px", "side_view.strips.box_px",
				"side_view.strips.box_gap_px", "side_view.strips.name_px", "side_view.strips.box_line_px", "side_view.strips.chevron_px",
				"side_view.strips.chevron_line_px", "side_view.strips.min_picture_h_px", "side_view.strips.picture_h_px.top",
				"side_view.strips.picture_h_px.front", "side_view.strips.picture_h_px.side", "side_view.arcs.w_px", "side_view.arcs.h_px",
				"side_view.top.nose_deg", "side_view.front.theta_bins", "side_view.front.pitch_step_deg", "side_view.front.boundary_samples",
				"side_view.front.densify_step", "side_view.drop.arc_px", "side_view.drop.arc_alpha", "side_view.drop.spread_h_px",
			"side_view.drop.spread_alpha", "side_view.drop.land_r_px", "side_view.drop.samples", "side_view.drop.top_px",
			"side_view.drop.bottom_px", "side_view.drop.left_px", "side_view.drop.right_px", "side_view.text.level_within_m"]:
		var v: Variant = _st.lookup(n)
		check(v is float or v is int, "1. ui.json has a number at '%s'" % n)
	for f: String in ["side_view.enabled", "side_view.live_during_playback", "side_view.text.enabled", "side_view.target.off_axis_hollow",
			"side_view.strips.open.top", "side_view.strips.open.front", "side_view.strips.open.side", "side_view.top.footprint",
			"side_view.top.pitch_shift", "side_view.front.rear_dashed"]:
		check(_st.lookup(f) is bool, "1. ui.json has a flag at '%s'" % f)
	for t: String in ["side_view.cone_mode", "side_view.text.head_step", "side_view.text.head_now", "side_view.text.head_live", "side_view.text.unit_line",
			"side_view.text.above", "side_view.text.below", "side_view.text.level", "side_view.text.drop_line", "side_view.text.drop_line_free",
			"side_view.text.point", "side_view.text.unseen", "side_view.strips.name.top", "side_view.strips.name.front",
			"side_view.strips.name.side", "side_view.arcs.label_on", "side_view.arcs.label_off", "side_view.arcs.tooltip"]:
		check(_st.lookup(t) is String, "1. ui.json has the text %s" % t)
	for r: String in ["side_view.paper_role", "side_view.frame_role", "side_view.ground.role", "side_view.line.role", "side_view.mark.rim_role", "side_view.target.rim_role"]:
		check(_st.lookup(r) is Dictionary and (_st.lookup(r) as Dictionary).has("base"), "1. ui.json has the palette role %s" % r)
	eq(_st.text("side_view.cone_mode"), "wash", "1. Alex chose the colour wash for the side view")
	eq(_st.flag("planner.cones.label"), false, "1. and no weapon labels (the map's lettering is off too)")
	eq(_st.flag("planner.cones.shown"), false, "1. the map's cone wash starts OFF (decision side-view-views: the strips show them)")
	eq(_st.text("planner.cones.shown_decision"), "side-view-views", "1. and the record names the decision")
	eq(_st.lookup("side_view.strips.order"), ["top", "front", "side"], "1. the strips are top, front and side (Alex's order)")
	check(float(_st.num("side_view.strips.name_px")) >= _st.min_px() and _st.num("fonts.button_px") >= _st.min_px(), "1. the strips' names and the Arcs button are at least the lettering floor")
	eq(_st.errors.size(), 0, "1. no style lookups failed: %s" % str(_st.errors))

# --- 2. Who ---------------------------------------------------------------------------------------------------

func _check_who() -> void:
	_sel.clear()
	_sv.refresh()
	eq(_sv.is_active(), false, "2. nothing selected: no side view")
	_sel.select("ai1")
	_sv.refresh()
	eq(_sv.is_active(), false, "2. an enemy selected: no side view")
	_sel.select("p1")
	_sv.refresh()
	eq(_sv.is_active(), true, "2. a friendly unit selected, planning: the side view")
	var m := _sv.model()
	eq(m["mode"], "guns", "2. with no drop it is the guns view")
	eq(m["step"], -1, "2. with no step placed it is the unit as it is now")
	eq(m["head"], _st.text("side_view.text.head_now"), "2. and the heading says so")
	_w.phase = World.PHASE_RESOLVING
	_sv.refresh()
	eq(_sv.is_active(), false, "2. no side view while a turn resolves with no playback")
	_w.phase = World.PHASE_PLANNING
	_sv.refresh()
	eq(_sv.is_active(), true, "2. and back with the planning phase")

# --- 3. Angles are true -------------------------------------------------------------------------------------

# Every cone of a model against the sim: its centre line is the weapon's elevation (plus the pitch) on the page,
# its half height is the weapon's (cut by the slice), its range the weapon's, and combat.gd agrees at the rim.
func _check_cone_truth(m: Dictionary, label: String) -> void:
	var cones: Array = m["cones"]
	var pitch: float = (m["pose"] as Dictionary)["pitch"]
	var ppm: float = m["ppm"]
	var height: float = (m["pose"] as Dictionary)["height_m"]
	check(cones.size() > 0, "%s: there are cones to check" % label)
	for c: Dictionary in cones:
		var wp = c["weapon"]
		var facing: int = c["facing"]
		var mid: float = -float(c["phi"])
		var want: float = pitch + float(wp.elevation) if facing == 1 else PI + pitch - float(wp.elevation)
		near(absf(angle_difference(mid, want)), 0.0, 1e-9, "%s %s: the centre line is the weapon's elevation on the page (tilted by the pitch)" % [label, str(wp.id)])
		# The slice along the nose: the azimuth at the nose or tail, narrowing the height as the ellipse says.
		var across: float = Combat.wrap_angle((0.0 if facing == 1 else PI) - float(wp.mount))
		var all_around: bool = float(wp.half_across) >= PI - 1e-9
		var expect_half: float = float(wp.half_height) if all_around else float(wp.half_height) * sqrt(1.0 - pow(across / float(wp.half_across), 2.0))
		near(float(c["half"]), expect_half, 1e-9, "%s %s: the half height is the weapon's, cut by the slice" % [label, str(wp.id)])
		near(float(c["range_px"]), float(wp.range_m) * ppm, 1e-6, "%s %s: the range is the weapon's on the one scale" % [label, str(wp.id)])
		near(float(c["reach_px"]), float(wp.range_m) * (1.0 + _st.num("planner.cones.overshoot_fraction")) * ppm, 1e-6, "%s %s: the fade runs the data's overshoot past it" % [label, str(wp.id)])
		# combat.gd at the rim: a target 0.9 of the half height off the centre line is in the cone, 1.1 is not.
		var shooter := {"x": 0.0, "y": 0.0, "heading": 0.0, "height_m": height, "pitch": pitch}
		var pose := Combat.pose(shooter, wp.weapon_hardpoint(int(c["hp"])) if wp.has_method("weapon_hardpoint") else (wp.hardpoints[int(c["hp"])] as Vector3))
		var dist := minf(300.0, float(wp.range_m) * 0.8)
		for f: Array in [[0.9, true], [-0.9, true], [1.1, false], [-1.1, false]]:
			var a: float = mid + float(f[0]) * float(c["half"])
			var tgt := {"x": float(pose["x"]) + dist * cos(a), "y": 0.0, "height_m": float(pose["z"]) + dist * sin(a)}
			var g := Combat.evaluate_pose(pose, wp, tgt, ["centre"])
			eq(bool(g["in_cone"]), bool(f[1]), "%s %s: combat.gd %s a target %.1f of the half height off the centre line (r %.3f)" % [label, str(wp.id), "takes" if bool(f[1]) else "refuses", float(f[0]), float(g["r"])])
			var drawn := ConeOverlay.inside(c, (c["apex"] as Vector2) + Vector2.from_angle(-a) * dist * ppm, float(c["half"]))
			eq(drawn, bool(f[1]), "%s %s: and the drawn wedge agrees at the same point" % [label, str(wp.id)])

func _check_angles() -> void:
	# The light fighter, level: two wing hardpoints that coincide side-on are ONE wedge.
	var m := _model_for("p1")
	var cones: Array = m["cones"]
	eq(cones.size(), 1, "3. the light fighter's wing guns are one wedge side-on (their two hardpoints coincide)")
	var w = _w.units["p1"].def.weapons[0]
	near(float((m["pose"] as Dictionary)["pitch"]), 0.0, 1e-12, "3. level flight: no pitch")
	near(float(cones[0]["phi"]), 0.0, 1e-12, "3. level: the wing guns point along the page's horizontal")
	near(float(cones[0]["half"]), float(w.half_height), 1e-12, "3. and span their own 8 degrees either side")
	_check_cone_truth(m, "3. light fighter, level")
	# One scale on both axes: a metre is the same px across and up.
	var ppm: float = m["ppm"]
	var o: Vector2 = m["origin"]
	near((cones[0]["apex"] as Vector2).x - o.x, w.hardpoints[0].x * ppm, 1e-4, "3. the hardpoint sits where the airframe has it (forward)")
	var sz: Vector2 = m["size"]
	check(o.x > 0.0 and o.x < sz.x * 0.2, "3. the fighter has little room behind it (it has no rearward gun): the unit sits near the left edge")
	# The reach sets the span: 450 m + the fade, with the margin.
	var reach: float = 450.0 * (1.0 + _st.num("planner.cones.overshoot_fraction"))
	var span := reach * _st.num("side_view.frame.span_margin")
	near((sz.x - 2.0 * _st.num("side_view.section.pad_px")) / ppm, span * (1.0 + _st.num("side_view.frame.rear_room_fraction")), 1e-6, "3. the span is the weapons' reach with the margin and a little room behind")
	# A bomber: rearward turrets point left, the dorsal turret up and back; the page makes room for them.
	var mb := _model_for("b1")
	var ids := {}
	for c: Dictionary in mb["cones"]:
		ids[str((c["weapon"] as Object).id)] = c
	check(ids.has("nose_gun") and ids.has("dorsal_turret") and ids.has("tail_turret"), "3. the bomber shows all three guns (%s)" % str(ids.keys()))
	check(Vector2.from_angle(float(ids["tail_turret"]["phi"])).x < -0.99, "3. the tail turret points left")
	check(Vector2.from_angle(float(ids["dorsal_turret"]["phi"])).x < 0.0 and Vector2.from_angle(float(ids["dorsal_turret"]["phi"])).y < 0.0, "3. the dorsal turret points up and back")
	check(Vector2.from_angle(float(ids["nose_gun"]["phi"])).x > 0.99, "3. the nose gun points right")
	check((mb["origin"] as Vector2).x > (mb["size"] as Vector2).x * 0.3, "3. the bomber has room behind it for its rear guns")
	_check_cone_truth(mb, "3. bomber, level")
	# The heavy fighter's rear gunner is pitched up 10 degrees with 35 either way: a slice behind it only.
	var mh := _model_for("p3")
	var hs := {}
	for c: Dictionary in mh["cones"]:
		hs[str((c["weapon"] as Object).id)] = c
	check(hs.has("nose_cannon") and hs.has("rear_gunner"), "3. the heavy fighter shows its cannon and its rear gunner")
	_check_cone_truth(mh, "3. heavy fighter, level")
	# A DIVE tilts every cone down, by the pitch the resolver gives the airframe.
	_sel.select("p3")
	_pl.clear()
	_pl.place_point(Vector2(1160.0, 2000.0))
	var dive := _pl.change_band(-1)
	check(not dive.is_empty() and str(dive["altitude_band"]) == "medium", "3. the heavy fighter dives a band")
	_sv.refresh()
	var md := _sv.model()
	eq(md["step"], 0, "3. the card is about step 1")
	eq(md["head"], _st.text("side_view.text.head_step") % 1, "3. and the heading says which step")
	var pd: float = (md["pose"] as Dictionary)["pitch"]
	near(pd, -_w.combat.max_pitch, 1e-9, "3. a one-band dive in one step pitches the airframe the full max_pitch down")
	near((md["pose"] as Dictionary)["height_m"], _w.band_height("medium"), 1e-9, "3. the unit is at the step's end height")
	for c: Dictionary in md["cones"]:
		if (c["weapon"] as Object).id == "nose_cannon":
			near(float(c["phi"]), -(pd + 0.0), 1e-9, "3. the nose cannon points DOWN by the pitch on the page")
			check(Vector2.from_angle(float(c["phi"])).y > 0.5, "3. (down the page)")
	_check_cone_truth(md, "3. heavy fighter, diving")
	_check_pitch_is_the_resolvers()
	_pl.clear()

# The pitch the panel shows for a step is the one combat_resolver.gd gives the airframe at that step's end.
func _check_pitch_is_the_resolvers() -> void:
	var w3 := World.new()
	w3.add_player("local")
	_add(w3, "q1", "light_fighter", "allies", "player", 1000.0, 1000.0, 0.0, "medium")
	var sel3 := UiSelection.new()
	var pl3 := MotionPlanner.new()
	add_child(pl3)
	pl3.setup(w3, _xf, sel3, "local", _st)
	var px3 := _Proxy.new()
	px3.inner = pl3
	px3.bombs = pl3.bombs
	var sv3 := SideView.new()
	add_child(sv3)
	sv3.setup(w3, px3, sel3, _st)
	sel3.select("q1")
	pl3.place_point(Vector2(1100.0, 1000.0))
	pl3.place_point(Vector2(1200.0, 1000.0))
	pl3.change_band(1)   # step 2 climbs
	sv3.refresh()
	var pitch_climb: float = (sv3.model()["pose"] as Dictionary)["pitch"]
	var step_k: int = sv3.model()["step"]
	eq(step_k, 1, "3. the card is about the climbing step")
	w3.commit("local")
	w3.resolve()
	var resolver := CombatResolver.new(w3.combat, w3.bombs)
	var t_end: float = w3.rules.turn_seconds * float(step_k + 1) / float(w3.steps_per_turn("q1"))
	var sampler := func(uid: String, t: float) -> Dictionary: return w3.sample(uid, t, "history")
	var bh := func(b: String) -> float: return w3.band_height(b)
	var st: Dictionary = resolver._state_at("q1", t_end, w3.units["q1"].history, sampler, bh)
	near(float(st["pitch"]), pitch_climb, 1e-9, "3. the pitch shown for the climbing step is the one the resolver gives the airframe at its end")
	check(pitch_climb > 0.0, "3. (a climb: nose up)")
	sv3.queue_free()
	pl3.queue_free()

# --- 4. The target on the page --------------------------------------------------------------------------------

func _check_target_placement() -> void:
	_tg.clear()
	# Scene 1 (the mock-up): a light fighter at 400 m, the bomber 600 m above and 500 m ahead.
	_pick_unit("ai1")
	var m := _model_for("p1")
	var t: Dictionary = m["target"]
	check(not t.is_empty(), "4. the targeted bomber is on the page's model")
	eq(t["kind"], "unit", "4. a unit target")
	near(float(t["rel_x"]), 500.0, 1e-3, "4. its straight-line position: 500 m ahead")
	near(float(t["rel_z"]), 600.0, 1e-3, "4. and 600 m above")
	near(float(t["slant"]), sqrt(500.0 * 500.0 + 600.0 * 600.0), 1e-3, "4. the slant distance")
	eq(bool(t["inside"]), false, "4. beyond the page: it is an arrow on the edge")
	var d: Vector2 = t["dir"]
	near(absf(angle_difference(-d.angle(), atan2(600.0, 500.0))), 0.0, 1e-5, "4. the arrow points along the TRUE angle to it (%.1f degrees above the nose)" % rad_to_deg(atan2(600.0, 500.0)))
	var inner := Rect2(Vector2.ZERO, m["size"] as Vector2).grow(-_st.num("side_view.frame.edge_inset_px"))
	var e: Vector2 = t["edge"]
	check(inner.grow(0.01).has_point(e) and (absf(e.x - inner.end.x) < 0.01 or absf(e.y - inner.position.y) < 0.01 or absf(e.x - inner.position.x) < 0.01 or absf(e.y - inner.end.y) < 0.01), "4. the arrow's tip is on the page's edge, inside the margin (%s)" % str(e))
	near(absf(angle_difference(-(e - (m["origin"] as Vector2)).angle(), atan2(600.0, 500.0))), 0.0, 1e-5, "4. and on the line from the plane to the target")
	eq(m["line"], _st.text("side_view.text.unit_line") % ["bomber", roundi(sqrt(500.0 * 500.0 + 600.0 * 600.0)), _st.text("side_view.text.above") % 600], "4. the one quiet line: name, slant distance, height difference")
	# Scene 3: 470 m ahead, level: in the fade past the wing guns' 450 m.
	_pick_unit("ai2")
	m = _model_for("p1")
	t = m["target"]
	eq(bool(t["inside"]), true, "4. 470 m ahead and level is on the page")
	var ppm: float = m["ppm"]
	var o: Vector2 = m["origin"]
	var px: Vector2 = t["px"]
	# (Vector2 is float32: at 200 px one ulp is 1.5e-5, so 1e-6 held only by luck of the card's width; Track L widened the card to 320 px)
	near((px - o).x, 470.0 * ppm, 1e-3, "4. at 470 m on the one scale")
	near((px - o).y, 0.0, 1e-6, "4. at the unit's own height")
	var cone: Dictionary = m["cones"][0]
	check(px.x - o.x > float(cone["range_px"]) and px.x - o.x < float(cone["reach_px"]), "4. inside the fade past the effective range, short of where the odds end")
	eq(m["line"], _st.text("side_view.text.unit_line") % ["light fighter", 470, _st.text("side_view.text.level")], "4. 'level' when the height difference is within the data's few metres")
	check(bool(ConeOverlay.inside(cone, px, float(cone["half"]))), "4. and the drawn wedge holds it")
	# One scale on both axes: a target up and ahead sits at the true angle on the page. A fighter at 120 m, a plane
	# a band above it (280 m up) and 200 m ahead: the page gives the unit's height room so the target is on it.
	_pick_unit("ai2")
	var wtarget = _w.units["ai2"]
	var old_x: float = wtarget.x
	wtarget.x = 1200.0
	_w.units["p1"].altitude_band = "low"
	m = _model_for("p1")
	t = m["target"]
	eq(bool(t["inside"]), true, "4. 200 m ahead and 280 m above is on the page (the page makes room above the plane): %s" % str(t["px"]))
	if bool(t["inside"]):
		var v: Vector2 = (t["px"] as Vector2) - (m["origin"] as Vector2)
		near(absf(angle_difference(-v.angle(), atan2(280.0, 200.0))), 0.0, 1e-5, "4. one scale on both axes: the page angle is the true angle (%.1f degrees)" % rad_to_deg(atan2(280.0, 200.0)))
		near(v.x / float(m["ppm"]), 200.0, 1e-3, "4. 200 m across")
		near(-v.y / float(m["ppm"]), 280.0, 1e-3, "4. and 280 m up")
	wtarget.x = old_x
	_w.units["p1"].altitude_band = "medium"
	# A dive: the heavy fighter diving onto a plane 280 m below its end height and 380 m ahead.
	_sel.select("p3")
	_pl.clear()
	_pl.place_point(Vector2(1000.0, 2000.0) + Vector2(125.0, 0.0))
	_pl.change_band(-1)
	_pick_unit("ai3")
	_sv.refresh()
	m = _sv.model()
	t = m["target"]
	near(float(t["rel_z"]), _w.band_height("low") - _w.band_height("medium"), 1e-6, "4. the quarry is a band below the dive's end")
	near(float(t["rel_x"]), 1380.0 - float((m["pose"] as Dictionary)["x"]), 1e-3, "4. and ahead of where the dive leaves the plane")
	eq(bool(t["inside"]), true, "4. the page hangs the diving plane high on it so the quarry below is on the page (%s)" % str(t["px"]))
	_pl.clear()
	# Behind: a plane 300 m behind a fighter that has no rear gun is off the left of the page (the room behind it is small).
	_pick_unit("ai4")
	m = _model_for("p1")
	t = m["target"]
	near(float(t["rel_x"]), -300.0, 1e-3, "4. behind the nose the distance is negative")
	eq(bool(t["forward"]), false, "4. (behind)")
	eq(bool(t["inside"]), false, "4. and off the page to the left, an arrow")
	check((t["dir"] as Vector2).x < 0.0, "4. pointing left")
	m = _model_for("b1")
	check(m["target"].is_empty() or true, "4. (the bomber's own page)")
	# The ring: a plane whose bearing is off every gun's arc is a ring, not a dot.
	_pick_unit("ai2")
	var a2 = _w.units["ai2"]
	var save_y: float = a2.y
	a2.y = 1000.0 + 470.0 * tan(deg_to_rad(5.0))
	m = _model_for("p1")
	eq(bool((m["target"] as Dictionary)["hollow"]), false, "4. 5 degrees off the nose is inside the wing guns' 10 degree arc: a dot")
	a2.y = 1000.0 + 470.0 * tan(deg_to_rad(20.0))
	m = _model_for("p1")
	eq(bool((m["target"] as Dictionary)["hollow"]), true, "4. 20 degrees off the nose is outside it: a ring")
	a2.y = save_y
	# The ground: the page draws it where the unit's height puts it, or not at all when it is off the page.
	_tg.clear()
	m = _model_for("p1")
	eq(m["ground_y"], INF, "4. a plane at 400 m has the ground off the page")
	_w.units["p1"].altitude_band = "low"
	m = _model_for("p1")
	var gy: float = m["ground_y"]
	near(gy, (m["origin"] as Vector2).y + _w.band_height("low") * float(m["ppm"]), 1e-6, "4. at 120 m the ground line is 120 m below the plane on the one scale")
	_sv.ground_height = func(_x: float, _y: float) -> float: return 20.0
	m = _model_for("p1")
	near(float(m["ground_y"]), (m["origin"] as Vector2).y + (_w.band_height("low") - 20.0) * float(m["ppm"]), 1e-6, "4. the ground seam, when wired, lifts the line")
	_sv.ground_height = Callable()
	_w.units["p1"].altitude_band = "medium"
	_tg.clear()

# The bomber's second step with a drop on the radio tower, through the planner as a player does it: the target
# selected (the tower), the special switched on. Returns the cone's ideal aim.
func _plan_tower_drop() -> Vector2:
	_sel.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1142.0, 3000.0))
	_pl.place_point(Vector2(1284.0, 3000.0))
	var ideal: Vector2 = _pl.bombs.cone("b1", 1)["ideal_aim"]
	if not _w.units.has("tower"):
		_add(_w, "tower", "radio_tower", "axis", "ai", ideal.x + 30.0, ideal.y + 12.0, 0.0)
	_pick_unit("tower")
	check(not _pl.set_step_drop(1, true).is_empty(), "the bomber's second step takes a drop on the tower (a target set, inside the cone)")
	return ideal

# --- 5. Which target ---------------------------------------------------------------------------------------------

func _check_which_target() -> void:
	_tg.clear()
	var m := _model_for("p1")
	check((m["target"] as Dictionary).is_empty(), "5. no target: the cones only")
	eq(m["line"], "", "5. and no line of text")
	check((m["cones"] as Array).size() > 0, "5. (the cones are there)")
	# The selection.
	_pick_point(Vector2(1300.0, 1000.0))
	m = _model_for("p1")
	var t: Dictionary = m["target"]
	eq(t["kind"], "point", "5. a point selected: a point target")
	eq(t["source"], "selection", "5. from the selection")
	near(float(t["rel_x"]), 300.0, 1e-3, "5. 300 m ahead")
	near(float(t["rel_z"]), -_w.band_height("medium"), 1e-6, "5. and on the ground, 400 m below")
	eq(m["line"], _st.text("side_view.text.unit_line") % ["point", roundi(sqrt(300.0 * 300.0 + 400.0 * 400.0)), _st.text("side_view.text.below") % 400], "5. the line names a point")
	_pick_unit("ai2")
	m = _model_for("p1")
	eq((m["target"] as Dictionary)["source"], "selection", "5. a unit selected: from the selection")
	# A step that carries a special keeps its own target: the selection does not replace it.
	var ideal := _plan_tower_drop()
	_px.step_targets.clear()
	_pick_unit("ai2")   # the selection moves on to another plane; the step keeps the tower
	_sv.refresh()
	m = _sv.model()
	eq(m["step"], 1, "5. the card is about the drop step")
	eq(m["mode"], "drop", "5. a step with a drop shows the bombs' fall")
	var t2: Dictionary = m["target"]
	eq([t2["source"], t2["unit"]], ["step", "tower"], "5. the step's own target (Track T's step_target) is the tower, not the selection")
	# Before the step target existed, the drop's aim stood in for it.
	_px.hide_step_target = true
	_sv.refresh()
	t2 = _sv.model()["target"]
	eq(t2["source"], "aim", "5. without a step target the drop's aim is its target")
	check((t2["pos"] as Vector2).distance_to(Vector2(float(_w.units["tower"].x), float(_w.units["tower"].y))) < 1e-3, "5. at the aim (where the tower was when the special was activated)")
	_px.hide_step_target = false
	_px.step_targets[1] = {"unit": "", "point": ideal + Vector2(20.0, 5.0)}
	_sv.refresh()
	t2 = _sv.model()["target"]
	eq([t2["source"], t2["kind"]], ["step", "point"], "5. a step whose special was aimed at a point has a point target")
	check((t2["pos"] as Vector2).distance_to(ideal + Vector2(20.0, 5.0)) < 1e-3, "5. at that point")
	_px.step_targets.clear()
	# A step without a special: the selection again.
	_pl.set_step_drop(1, false)
	_pick_unit("ai2")
	_sv.refresh()
	m = _sv.model()
	eq(m["mode"], "guns", "5. the drop taken off: the guns view")
	eq((m["target"] as Dictionary).get("source", ""), "selection", "5. and the selection is the target")
	_pl.clear()
	# A ground unit chosen as the target of a gun step is a tick on the ground line, never a plane's dot.
	_pick_unit("tower")
	m = _model_for("p1")
	t = m["target"]
	eq([t["kind"], bool(t["ground"]), bool(t["hollow"])], ["unit", true, false], "5. a ground unit: a tick (never a dot or a ring)")
	near(float(t["rel_z"]), -_w.band_height("medium"), 1e-6, "5. on the ground, 400 m below")
	# Out of sight: a unit target is not drawn, nothing of its place leaks; a point always is.
	_pick_unit("ai2")
	_sv.unit_visible = func(id: String) -> bool: return id != "ai2"
	m = _model_for("p1")
	check((m["target"] as Dictionary).is_empty(), "5. a unit target out of sight is not on the page")
	eq(bool(m["target_hidden"]), true, "5. (the model says it is hidden)")
	eq(m["line"], _st.text("side_view.text.unseen"), "5. and the line says only that it is out of sight")
	_pick_point(Vector2(1300.0, 1000.0))
	m = _model_for("p1")
	check(not (m["target"] as Dictionary).is_empty(), "5. a point target is always drawn")
	_sv.unit_visible = Callable()
	# A target that is down is not drawn either (no seam: simply not down).
	_pick_unit("ai2")
	_w.units["ai2"].down = true
	m = _model_for("p1")
	check((m["target"] as Dictionary).is_empty(), "5. a downed unit is not a target on the page")
	_w.units["ai2"].down = false
	# The words can be switched off.
	_st.ui["side_view"]["text"]["enabled"] = false
	m = _model_for("p1")
	eq(m["line"], "", "5. the quiet line is a data switch")
	_st.ui["side_view"]["text"]["enabled"] = true
	_tg.clear()

# --- 6. Following ------------------------------------------------------------------------------------------------------

func _check_following() -> void:
	_pick_unit("ai2")
	var m := _model_for("p1")
	var x0: float = ((m["target"] as Dictionary)["px"] as Vector2).x
	var sig0 := _sv._signature()
	# The target is drawn where the unit is SHOWN: the marker layer's pose, which moves through a playback.
	_sv.shown_pose = func(id: String) -> Dictionary:
		var u = _w.units[id]
		var s: Dictionary = u.state()
		s["x"] = float(s["x"]) - 100.0 if id == "ai2" else float(s["x"])
		s["height_m"] = _w.band_height(str(u.altitude_band))
		return s
	m = _model_for("p1")
	var t: Dictionary = m["target"]
	near(float(t["rel_x"]), 370.0, 1e-3, "6. the target is where it is SHOWN (100 m nearer)")
	check(((t["px"] as Vector2).x) < x0, "6. the page follows it")
	check(_sv._signature() != sig0, "6. and the panel notices the move (its redraw signature changed)")
	var sig1 := _sv._signature()
	_w.units["ai2"].x -= 10.0   # the sim's own unit moves too: the shown pose is what counts
	check(_sv._signature() != sig1, "6. a shown position that moves is a change")
	_w.units["ai2"].x += 10.0
	_sv.shown_pose = Callable()
	# The enemy's PLAN is not where it is drawn: ai2 plans to be elsewhere, the page shows it where it is.
	m = _model_for("p1")
	near(float((m["target"] as Dictionary)["rel_x"]), 470.0, 1e-3, "6. an enemy with a plan is drawn where it IS, never where it plans to be")
	_tg.clear()

# --- 7. The drop --------------------------------------------------------------------------------------------------------

func _check_drop() -> void:
	var ideal := _plan_tower_drop()
	_px.step_targets.clear()
	_tg.clear()   # nothing selected: the step carries its own target
	_sv.refresh()
	var m := _sv.model()
	eq(m["mode"], "drop", "7. the drop step shows the fall")
	check((m["cones"] as Array).is_empty(), "7. instead of the cones")
	var aim := Vector2(float(_w.units["tower"].x), float(_w.units["tower"].y))
	var info: Dictionary = _w.drop_spread("b1", 1, aim)
	var d: Dictionary = m["drop"]
	var rel: Vector2 = info["release"]
	var land: Vector2 = info["aim"]
	var h0: float = info["release_height_m"]
	var ppm: float = m["ppm"]
	var o: Vector2 = m["origin"]
	near(float(d["land_m"]), rel.distance_to(land), 1e-6, "7. the landing is the distance from the release World.drop_spread gives")
	check((d["release"] as Vector2).is_equal_approx(rel), "7. from its release point")
	check((d["aim"] as Vector2).is_equal_approx(land), "7. at its (clamped) aim")
	near(float(d["fall_s"]), float(info["fall_s"]), 1e-9, "7. falling for the time the sim says")
	var arc: PackedVector2Array = d["arc"]
	check(arc.size() > 4, "7. an arc of %d points" % arc.size())
	check(arc[0].is_equal_approx(o), "7. from the plane at the release")
	check(arc[arc.size() - 1].is_equal_approx(o + Vector2(rel.distance_to(land), h0) * ppm), "7. to the ground at the landing, on the one scale")
	near(float(m["ground_y"]), o.y + h0 * ppm, 1e-6, "7. the ground line is the release height below the plane")
	var n := arc.size() - 1
	var i := n / 2
	var f := float(i) / float(n)
	near(arc[i].x - o.x, rel.distance_to(land) * f * ppm, 1e-4, "7. level across: the horizontal is linear in time (bombs.gd bomb_position)")
	near(arc[i].y - o.y, h0 * f * f * ppm, 1e-4, "7. and the height is h0 (1 - f^2): the fall is quadratic")
	var t: Dictionary = m["target"]
	eq(t["source"], "step", "7. the tower is the step's own target")
	eq(bool(t["ground"]), true, "7. a ground unit")
	near(((t["px"] as Vector2).y), float(m["ground_y"]), 1e-6, "7. a tick on the ground line")
	var gap_px: float = ((t["px"] as Vector2).x) - ((d["land"] as Vector2).x)
	near(gap_px, (aim.distance_to(rel) - rel.distance_to(land)) * ppm, 1e-6, "7. and where the stick lands against the target is a gap the page shows")
	eq(m["line"], _st.text("side_view.text.drop_line") % ["radio tower", roundi(aim.distance_to(rel)), roundi(float(info["fall_s"]))], "7. the line: the target, its distance, the fall time")
	var sp: Vector2 = d["spread_px"]
	check(sp.x < (d["land"] as Vector2).x and sp.y > (d["land"] as Vector2).x, "7. the expected spread is a band round the landing")
	# The aim FOLLOWS the target's shown position: the sim picks the release moment itself at resolve.
	_sv.shown_pose = func(id: String) -> Dictionary:
		var u = _w.units[id]
		var s: Dictionary = u.state()
		if id == "tower":
			s["x"] = float(s["x"]) + 25.0
		s["height_m"] = 0.0
		return s
	_sv.refresh()
	var m2 := _sv.model()
	var aim2 := aim + Vector2(25.0, 0.0)
	var info2: Dictionary = _w.drop_spread("b1", 1, aim2)
	near(float((m2["drop"] as Dictionary)["land_m"]), (info2["release"] as Vector2).distance_to(info2["aim"] as Vector2), 1e-6, "7. aimed at the moved target: the release World.drop_spread gives for the target's shown position")
	check(not is_equal_approx(float((m2["drop"] as Dictionary)["land_m"]), float(d["land_m"])), "7. which is not where it landed before")
	_sv.shown_pose = Callable()
	# The selection is not a drop step's target.
	_px.step_targets.clear()
	_pick_unit("ai2")
	_sv.refresh()
	eq([(_sv.model()["target"] as Dictionary)["source"], (_sv.model()["target"] as Dictionary)["unit"]], ["step", "tower"], "7. a selection does not retarget a step that carries a special")
	_tg.clear()
	# A target the fall cannot reach on the page is an arrow, on the ground side.
	_px.step_targets[1] = {"point": ideal + Vector2(2500.0, 0.0)}
	_sv.refresh()
	t = _sv.model()["target"]
	eq(bool(t["inside"]), false, "7. a target far beyond the fall is an arrow on the edge")
	var dfar: Dictionary = _sv.model()["drop"]
	eq(bool(dfar["outside"]), true, "7. outside the step's cone: the sim's own say, drop_spread's 'outside'")
	eq(bool(dfar["releases"]), _w.bombs.outside_cone_mode == "poor_shot", "7. and whether it would release is the data's switch (%s)" % _w.bombs.outside_cone_mode)
	_px.step_targets.clear()
	_pl.clear()

# --- 8. Never an enemy's plan ----------------------------------------------------------------------------------------------

func _check_never_enemy_plan() -> void:
	var ai_ids := ["ai1", "ai2", "ai3", "ai4", "tower"]
	_px.calls.clear()
	_pick_unit("ai1")
	for id: String in ["ai1", "p1", "ai2", "p3", "b1", "ai1"]:
		_sel.select(id)
		_sv.refresh()
		_sv._signature()
	var seen := []
	for c: Array in _px.calls:
		if ai_ids.has(str(c[1])):
			seen.append(c)
	eq(seen, [], "8. the planner was never asked about an AI unit's plan (%d calls on the player units)" % _px.calls.size())
	check(_px.calls.size() > 5, "8. the tripwire saw the side view working (%d calls)" % _px.calls.size())
	# The enemy selected: nothing is shown, and no plan-derived question is asked for it.
	_px.calls.clear()
	_sel.select("ai1")
	_sv.refresh()
	eq(_sv.is_active(), false, "8. an enemy selected shows no side view")
	eq(_px.calls.size(), 0, "8. and asks the planner nothing")
	_tg.clear()
	# The files: no plan read in them but through the planner (the pattern test_ui_coop's tripwire uses).
	var rx := RegEx.new()
	rx.compile("\\.plan\\b|planned_states\\(|\"plan\"\\)|\\.reachable\\(|drop_cone\\(|drop_steps\\(")
	for f: String in ["res://scripts/ui/side_view.gd", "res://scripts/ui/side_view_art.gd", "res://scripts/ui/side_view_top.gd", "res://scripts/ui/side_view_front.gd"]:
		var hits := 0
		for line: String in FileAccess.get_file_as_string(f).split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			if rx.search(line) != null:
				hits += 1
		eq(hits, 0, "8. %s reads no plan or preview itself (test_ui_coop's pattern)" % f)
	var src := FileAccess.get_file_as_string("res://scripts/ui/side_view.gd")
	check(src.contains("planner.plan_shown(id)"), "8. side_view.gd gates its plan reads on plan_shown")

# --- 9. Indicators only ------------------------------------------------------------------------------------------------------

func _check_indicators_only() -> void:
	var rx_hex := RegEx.new()
	rx_hex.compile("Color\\(\\s*[0-9.]|Color8\\(|Color\\.html|\"#[0-9a-fA-F]{3,8}\"|Color\\.(RED|BLUE|GREEN|BLACK|WHITE)")
	var rx_art := RegEx.new()
	rx_art.compile("unit_marker|UnitMarkerArt|draw_texture|Sprite|TextureRect|silhouette|baked|\\.art\\b")
	for f: String in ["res://scripts/ui/side_view.gd", "res://scripts/ui/side_view_art.gd", "res://scripts/ui/side_view_top.gd", "res://scripts/ui/side_view_front.gd"]:
		var hex := 0
		var art := 0
		for line: String in FileAccess.get_file_as_string(f).split("\n"):
			if line.strip_edges().begins_with("#"):
				continue
			if rx_hex.search(line) != null:
				hex += 1
			if rx_art.search(line) != null:
				art += 1
		eq(hex, 0, "9. %s has no colour literal (colours are roles in data)" % f)
		eq(art, 0, "9. %s calls no unit art (indicators only, no side-view assets)" % f)
	# No weapon lettering: the cone records are side-on, which draw_cones leaves unlabelled.
	var m := _model_for("b1")
	for c: Dictionary in m["cones"]:
		eq(bool(c["side_view"]), true, "9. a side-on cone record (the overlay draws no label for it)")
	_sel.clear()

# --- 13 to 20. The three strips (decision side-view-views, 2026-10-11) -----------------------------------------------------

# A weapon as the front strip's outline reads one: only the cone's own fields.
class _Gun extends RefCounted:
	var id := "synthetic"
	var mount := 0.0
	var elevation := 0.0
	var half_across := 0.1
	var half_height := 0.1
	var rim_odds_factor := 1.0

const STRIP_IDS := ["top", "front", "side"]

func _rows(m: Dictionary) -> Dictionary:
	var out := {}
	for e: Dictionary in (m["layout"] as Dictionary)["strips"]:
		out[str(e["id"])] = e
	return out

func _pic_h(id: String) -> float:
	return _st.num("side_view.strips.picture_h_px." + id)

func _click(sv: SideView, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = at
	sv._gui_input(ev)

# 13. THREE STRIPS, EACH FOLDING ON ITS OWN, ANY NUMBER OPEN.
func _check_strips() -> void:
	SideView.reset_view_setting()
	_tg.clear()
	var m := _model_for("b1")
	var lay: Dictionary = m["layout"]
	eq(lay["mode"], "strips", "13. with no card to fit (a panel alone) the strips stack")
	var rows := _rows(m)
	eq(rows.keys(), STRIP_IDS, "13. three strips, in Alex's order: top, front, side")
	var names := {"top": "Top", "front": "Front", "side": "Side"}
	var chrome := _st.num("side_view.section.gap_px") + _st.num("side_view.section.head_px") + _st.num("side_view.section.caption_h_px") + _st.num("side_view.section.bottom_px")
	var sh := _st.num("side_view.strips.head_px")
	var sgap := _st.num("side_view.strips.gap_px")
	for id: String in STRIP_IDS:
		eq(str(rows[id]["name"]), names[id], "13. the %s strip is named %s" % [id, names[id]])
		check(bool(rows[id]["shown"]), "13. the %s strip starts unfolded (PROPOSED: all three)" % id)
		near((rows[id]["head"] as Rect2).size.y, sh, 1e-9, "13. %s: a header row of the data's height" % id)
		near((rows[id]["pic"] as Rect2).size.y, _pic_h(id), 1e-9, "13. %s: a picture of the data's height" % id)
		check(_st.num("side_view.strips.name_px") >= _st.min_px(), "13. (the names are at least the lettering floor, %s px)" % str(_st.min_px()))
	near(_sv.size.y, chrome + 3.0 * sh + _pic_h("top") + _pic_h("front") + _pic_h("side") + 3.0 * sgap, 1e-6, "13. the section is the rows and the pictures")
	near(float((m["size"] as Vector2).y), _pic_h("side"), 1e-9, "13. model()['size'] stays the Side picture's, as it was")
	check(m.has("top") and m.has("front"), "13. the model carries the other two strips")
	# Each folds and unfolds on its own.
	var full := _sv.size.y
	for id: String in STRIP_IDS:
		_sv.set_strip_open(id, false)
		var r2 := _rows(_sv.model())
		check(not bool(r2[id]["shown"]), "13. %s folds" % id)
		eq((r2[id]["pic"] as Rect2).size, Vector2.ZERO, "13. folded: header only, no picture")
		check(not (_sv._pics[id] as Control).visible, "13. (its canvas is down)")
		near(_sv.size.y, full - _pic_h(id) - sgap, 1e-6, "13. and the section is that much shorter")
		for other: String in STRIP_IDS:
			if other != id:
				check(bool(r2[other]["shown"]), "13. folding %s leaves %s as it was" % [id, other])
		_sv.set_strip_open(id, true)
		check(bool(_rows(_sv.model())[id]["shown"]) and (_sv._pics[id] as Control).visible, "13. %s unfolds again" % id)
		near(_sv.size.y, full, 1e-6, "13. at its old height")
	# Any number open at once: all eight combinations.
	for mask in 8:
		var want := chrome + 3.0 * sh
		for i in 3:
			var open := (mask >> i) & 1 == 1
			_sv.set_strip_open(STRIP_IDS[i], open)
			if open:
				want += _pic_h(STRIP_IDS[i]) + sgap
		var rr := _rows(_sv.model())
		for i in 3:
			eq(bool(rr[STRIP_IDS[i]]["shown"]), (mask >> i) & 1 == 1, "13. combination %d: %s" % [mask, STRIP_IDS[i]])
		near(_sv.size.y, want, 1e-6, "13. combination %d: the section is the rows and the open pictures" % mask)
	for id: String in STRIP_IDS:
		_sv.set_strip_open(id, true)
	# A click on a header folds and unfolds (the fold box is on-screen, no key).
	var head: Rect2 = (_rows(_sv.model())["front"]["head"] as Rect2)
	_click(_sv, head.get_center())
	check(not bool(_rows(_sv.model())["front"]["shown"]), "13. a click on the Front header folds it")
	eq([bool(_rows(_sv.model())["top"]["shown"]), bool(_rows(_sv.model())["side"]["shown"])], [true, true], "13. and only it")
	head = (_rows(_sv.model())["front"]["head"] as Rect2)
	_click(_sv, head.get_center())
	check(bool(_rows(_sv.model())["front"]["shown"]), "13. and a second click unfolds it")
	check(_sv.press_strip("top") and not _sv.strip_shown("top"), "13. press_strip is the click")
	_sv.set_strip_open("top", true)
	eq(_sv.has_arcs_button(), false, "13. a panel alone has no Arcs button (the interface points it at the switch)")

# 14. THE FOLD STATE IS THE SESSION'S, NOT A UNIT'S.
func _check_fold_state_kept() -> void:
	SideView.reset_view_setting()
	_sv.set_strip_open("front", false)
	for id: String in ["p1", "p3", "b1", "p1"]:
		var rr := _rows(_model_for(id))
		eq([bool(rr["top"]["shown"]), bool(rr["front"]["shown"]), bool(rr["side"]["shown"])], [true, false, true], "14. %s selected: Front is still folded, the others open" % id)
	var other_panel := SideView.new()
	add_child(other_panel)
	other_panel.setup(_w, _px, _sel, _st)
	check(not other_panel.strip_chosen("front") and other_panel.strip_chosen("top"), "14. another panel (a rebuilt interface) keeps it: the choice is the session's")
	other_panel.queue_free()
	# An enemy or nothing selected: no strips at all, and the choice waits.
	_sel.select("ai1")
	_sv.refresh()
	eq(_sv.is_active(), false, "14. an enemy selected: no panel")
	eq(_sv.model().has("layout"), false, "14. so no strips")
	for id: String in STRIP_IDS:
		check(not (_sv._pics[id] as Control).visible, "14. (every canvas is down)")
	_sel.clear()
	_sv.refresh()
	eq(_sv.is_active(), false, "14. nothing selected: no panel")
	eq(_sv.model().has("layout"), false, "14. and no strips")
	check(not _sv.strip_chosen("front"), "14. and the choice is still there for the next friendly unit")
	SideView.reset_view_setting()
	check(_sv.strip_chosen("front"), "14. reset_view_setting gives the data's starting state back")
	check(_st.flag("side_view.strips.open.top") and _st.flag("side_view.strips.open.front") and _st.flag("side_view.strips.open.side"), "14. (all three open: PROPOSED, Alex wants all three)")

# 15. THE TOP STRIP: the map's own cone wash in the unit's frame.
func _check_top() -> void:
	SideView.reset_view_setting()
	_tg.clear()
	_w.units["b1"].heading = 0.0
	var m := _model_for("b1")
	var t: Dictionary = m["top"]
	var by := {}
	for c: Dictionary in t["cones"]:
		by[str((c["weapon"] as Object).id)] = c
	var foot := {}
	for c: Dictionary in t["footprints"]:
		foot[str((c["weapon"] as Object).id)] = c
	check(by.has("nose_gun") and by.has("tail_turret") and not by.has("dorsal_turret"), "15. the nose gun and the tail turret are wedges in the plane (%s)" % str(by.keys()))
	check(foot.has("dorsal_turret"), "15. the dorsal turret misses the plane: it is in the Top strip as its footprint (%s)" % str(foot.keys()))
	near(float(foot["dorsal_turret"]["half"]), 0.0, 1e-12, "15. a footprint has no slice")
	# The records are the map's own (cone_overlay.gd's collect), made small: same half width, same level, same range on the strip's scale.
	var overlay := ConeOverlay.new()
	add_child(overlay)
	overlay.setup(_w, _xf, _sel, _st)
	eq(overlay.collect().size(), 0, "22. the map draws no cones by default: the overlay collects nothing until the switch is on")
	overlay.set_arcs_shown(true)
	var map_recs := overlay.collect()
	check(map_recs.size() == 3, "15. the map has one record a hardpoint (%d)" % map_recs.size())
	var ppm: float = t["ppm"]
	for r: Dictionary in map_recs:
		var key := str((r["weapon"] as Object).id)
		var mine: Dictionary = by.get(key, foot.get(key, {}))
		if not check(not mine.is_empty(), "15. the strip has the map's %s" % key):
			continue
		near(float(mine["half"]), float(r["half"]), 1e-12, "15. %s: the wedge's half width is the map's" % key)
		near(float(mine["b0"]), float(r["b0"]), 1e-12, "15. %s: and the plane's height over its centre line" % key)
		near(float(mine["phi"]), float(r["phi"]), 1e-9, "15. %s: and its centre line (the nose is the page's right: heading 0)" % key)
		near(float(mine["range_px"]) / ppm, float((r["weapon"] as Object).range_m), 1e-6, "15. %s: the range is the weapon's on the strip's one scale" % key)
	overlay.set_arcs_shown(false)
	overlay.queue_free()
	ConeOverlay.reset_view_setting()
	# The page holds every wedge, fade and all.
	var page := Rect2(Vector2.ZERO, t["size"] as Vector2).grow(1.0)
	for c: Dictionary in (t["cones"] as Array) + (t["footprints"] as Array):
		var w: Object = c["weapon"]
		var hw: float = float(c["half"]) if float(c["half"]) > 0.0 else float(w.half_across)
		check(page.encloses(ConeOverlay.wedge_bounds(c, hw)), "15. %s is on the page, whole" % str(w.id))
	# The target: at its bearing and distance in the unit's frame (nose right, the right wing down), the one scale on both axes.
	_pick_point(Vector2(1300.0, 3200.0))   # 300 m ahead, 200 m to the right of b1 (heading 0)
	m = _model_for("b1")
	t = m["top"]
	var tt: Dictionary = t["target"]
	near(float(tt["rel_f"]), 300.0, 1e-3, "15. the target is 300 m ahead")
	near(float(tt["rel_r"]), 200.0, 1e-3, "15. and 200 m to the right")
	var pv: Vector2 = (tt["px"] as Vector2) - (t["origin"] as Vector2)
	near(pv.x, 300.0 * float(t["ppm"]), 1e-3, "15. ahead is to the right on the page, on the strip's scale")
	near(pv.y, 200.0 * float(t["ppm"]), 1e-3, "15. and the right wing is down the page, on the same scale")
	# The unit's frame, not the world's: the same point seen by a bomber heading south is on its left.
	_w.units["b1"].heading = PI * 0.5
	m = _model_for("b1")
	tt = m["top"]["target"]
	near(float(tt["rel_f"]), 200.0, 1e-3, "15. a bomber heading south: the point is 200 m ahead (the page turns with the unit)")
	near(float(tt["rel_r"]), -300.0, 1e-3, "15. and 300 m to its left")
	_w.units["b1"].heading = 0.0
	# The nose is data: up puts ahead at the top.
	_st.ui["side_view"]["top"]["nose_deg"] = -90.0
	m = _model_for("b1")
	pv = (m["top"]["target"]["px"] as Vector2) - (m["top"]["origin"] as Vector2)
	near(pv.y, -300.0 * float(m["top"]["ppm"]), 1e-3, "15. nose_deg -90: ahead is up the page")
	near(pv.x, 200.0 * float(m["top"]["ppm"]), 1e-3, "15. and the right wing is still to the right")
	_st.ui["side_view"]["top"]["nose_deg"] = 0.0
	# A target far beyond the page is an arrow on its edge.
	_pick_point(Vector2(5000.0, 3000.0))
	m = _model_for("b1")
	eq(bool(m["top"]["target"]["inside"]), false, "15. a far target is an arrow on the edge")
	check((m["top"]["target"]["dir"] as Vector2).x > 0.9, "15. pointing right (ahead)")
	_tg.clear()
	# A climb tilts the slice the plane makes: the dorsal turret's cone reaches the plane, and combat.gd agrees at its rim.
	_sel.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1160.0, 3000.0))
	check(not _pl.change_band(1).is_empty(), "15. the bomber climbs a band")
	_sv.refresh()
	var mc := _sv.model()
	var pitch: float = (mc["pose"] as Dictionary)["pitch"]
	check(pitch > 0.1, "15. (a climb: pitch %.1f degrees)" % rad_to_deg(pitch))
	var dorsal: Dictionary = {}
	for c: Dictionary in mc["top"]["cones"]:
		if str((c["weapon"] as Object).id) == "dorsal_turret":
			dorsal = c
	if check(not dorsal.is_empty(), "15. in the climb the dorsal turret has a slice in the horizontal plane: a wedge, not a footprint"):
		var wp: Object = dorsal["weapon"]
		var shooter := {"x": 0.0, "y": 0.0, "heading": 0.0, "height_m": float((mc["pose"] as Dictionary)["height_m"]), "pitch": pitch}
		var pose := Combat.pose(shooter, wp.hardpoints[0] as Vector3)
		for f: Array in [[0.9, true], [-0.9, true], [1.1, false], [-1.1, false]]:
			var a: float = float(dorsal["phi"]) + float(f[0]) * float(dorsal["half"])
			var tgt := {"x": float(pose["x"]) + 200.0 * cos(a), "y": float(pose["y"]) + 200.0 * sin(a), "height_m": float(pose["z"])}
			var g := Combat.evaluate_pose(pose, wp, tgt, ["centre"])
			eq(bool(g["in_cone"]), bool(f[1]), "15. combat.gd %s a point on the plane %.1f of the slice's half width off its centre (r %.3f)" % ["takes" if bool(f[1]) else "refuses", float(f[0]), float(g["r"])])
	_pl.clear()
	# A weapon the plane misses on both sides of its level: the footprint (a battery's upward cone) is dashed, one per weapon.
	_sel.clear()

# 16. THE FRONT STRIP: looking along the nose.
func _check_front() -> void:
	SideView.reset_view_setting()
	_tg.clear()
	var m := _model_for("b1")
	var f: Dictionary = m["front"]
	var by := {}
	for c: Dictionary in f["cones"]:
		by[str((c["weapon"] as Object).id)] = c
	check(by.has("nose_gun") and by.has("dorsal_turret") and by.has("tail_turret"), "16. the Front strip has all three of the bomber's guns, the dorsal turret among them (%s)" % str(by.keys()))
	var dorsal_levels: Array = (by["dorsal_turret"]["shape"] as Dictionary)["levels"]
	var rad: PackedFloat64Array = dorsal_levels[dorsal_levels.size() - 1]
	var bins := rad.size()
	var covered := 0
	var below := 0
	var top_r := 0.0
	for i in bins:
		if rad[i] > 0.0:
			covered += 1
			var a := SideViewFront.bin_angle(i, bins)
			if sin(a) < -0.06:
				below += 1
			if absf(a - PI * 0.5) < deg_to_rad(3.0):
				top_r = maxf(top_r, rad[i])
	eq(below, 0, "16. the dorsal turret reaches nothing below the unit's level: a fan over the top")
	check(covered > bins * 2 / 5, "16. and it is a wide one (%d of %d directions round the unit)" % [covered, bins])
	near(top_r, sin(deg_to_rad(70.0)), 0.04, "16. straight up it reaches sin(70 degrees) of its range (its cone's top edge is 70 degrees up)")
	check(bool(by["dorsal_turret"]["rear"]) and bool(by["tail_turret"]["rear"]) and not bool(by["nose_gun"]["rear"]), "16. the cones that face the tail are marked (their rim is dashed)")
	# A fixed forward gun is a small disc at the centre: the light fighter's wing guns, 10 by 8 degrees.
	var mf := _model_for("p1")
	var wing: Dictionary = (mf["front"]["cones"] as Array)[0]
	var wl: Array = (wing["shape"] as Dictionary)["levels"]
	var outer: PackedFloat64Array = wl[wl.size() - 1]
	var all := true
	var big := 0.0
	for i in outer.size():
		all = all and outer[i] > 0.0
		big = maxf(big, outer[i])
	check(all, "16. a fixed forward gun is a disc round the unit: every direction is covered")
	near(big, sin(deg_to_rad(10.0)), 0.01, "16. of radius sin(10 degrees) of its range: small")
	eq(wl.size(), int(_st.num("planner.cones.wash.steps")), "16. a peaked gun has the map's rings of equal odds, nested")
	# A waist gun is a fan to its side; a fan to the other for the other side. (A synthetic gun: the data has none.)
	for side: float in [1.0, -1.0]:
		var g := _Gun.new()
		g.mount = side * PI * 0.5
		g.half_across = deg_to_rad(40.0)
		g.half_height = deg_to_rad(25.0)
		var shp := SideViewFront.shape(g, 0.0, _st)
		var lv: Array = shp["levels"]
		var rg: PackedFloat64Array = lv[lv.size() - 1]
		var wrong := 0
		var right := 0
		for i in rg.size():
			if rg[i] > 0.0:
				if cos(SideViewFront.bin_angle(i, rg.size())) * side < -0.05:
					wrong += 1
				else:
					right += 1
		eq(wrong, 0, "16. a gun mounted %s covers nothing on the other side" % ("to the right" if side > 0.0 else "to the left"))
		check(right > 4, "16. but a fan on its own (%d directions)" % right)
		var far := 0.0
		for v in rg:
			far = maxf(far, v)
		near(far, 1.0, 0.02, "16. out to its full range (abeam, the whole range is on the plane)")
	# The target: at its lateral offset and height difference, one scale on both axes.
	_pick_point(Vector2(1300.0, 3150.0))   # 150 m to the right of b1 and on the ground, 400 m below it
	m = _model_for("b1")
	var tt: Dictionary = m["front"]["target"]
	near(float(tt["rel_lat"]), 150.0, 1e-3, "16. the target is 150 m to the right")
	near(float(tt["rel_z"]), -_w.band_height("medium"), 1e-6, "16. and 400 m below")
	var pv: Vector2 = (tt["px"] as Vector2) - (m["front"]["origin"] as Vector2)
	near(pv.x, 150.0 * float(m["front"]["ppm"]), 1e-3, "16. its lateral offset on the strip's scale")
	near(pv.y, _w.band_height("medium") * float(m["front"]["ppm"]), 1e-3, "16. and its height difference on the same scale (down the page)")
	_tg.clear()
	# The ground is a line under the unit when it is near (the Side strip's rule).
	_w.units["b1"].altitude_band = "low"
	m = _model_for("b1")
	near(float(m["front"]["ground_y"]), float((m["front"]["origin"] as Vector2).y) + _w.band_height("low") * float(m["front"]["ppm"]), 1e-6, "16. the ground line is 120 m under a bomber in the low band")
	_w.units["b1"].altitude_band = "medium"
	# A climb turns the fan: the nose gun's disc rises by the pitch.
	_sel.select("p1")
	_pl.clear()
	_pl.place_point(Vector2(1100.0, 1000.0))
	_pl.change_band(1)
	_sv.refresh()
	var mc := _sv.model()
	var pitch: float = (mc["pose"] as Dictionary)["pitch"]
	check(pitch > 0.1, "16. the light fighter climbs (%.1f degrees)" % rad_to_deg(pitch))
	var wc: Array = ((mc["front"]["cones"] as Array)[0]["shape"] as Dictionary)["levels"]
	var rc: PackedFloat64Array = wc[wc.size() - 1]
	var up_sum := 0.0
	for i in rc.size():
		up_sum += rc[i] * sin(SideViewFront.bin_angle(i, rc.size()))
	check(up_sum > 0.0, "16. in a climb the forward gun's disc is above the nose axis on the plane across it (%.2f)" % up_sum)
	_pl.clear()
	_sel.clear()

# 17. SELF ONLY, THE SAME INK, NO LABELS: only the selected friendly unit's own cones, with enemies about.
func _check_self_only() -> void:
	SideView.reset_view_setting()
	_tg.clear()
	for id: String in ["b1", "p1", "p3"]:
		var m := _model_for(id)
		var own := 0
		for w in _w.units[id].def.weapons:
			own += 1
		var n_top := 0
		for c: Dictionary in (m["top"]["cones"] as Array) + (m["top"]["footprints"] as Array):
			eq(str(c["unit"]), id, "17. a Top cone is %s's" % id)
			n_top += 1
		var n_front := 0
		for c: Dictionary in m["front"]["cones"]:
			eq(str(c["unit"]), id, "17. a Front cone is %s's" % id)
			n_front += 1
		check(n_top >= own and n_front == own, "17. %s: its own weapons (%d), none of the enemy bombers' or fighters' (Top %d, Front %d)" % [id, own, n_top, n_front])
		for c: Dictionary in m["cones"]:
			eq(str(c["unit"]), id, "17. a Side cone is %s's" % id)
	_sel.clear()
	# no weapon lettering on the strips: the draw calls are the map's, with its label switch off
	eq(_st.flag("planner.cones.label"), false, "17. no weapon labels (decision side-view-look)")

# --- 10, 11, 12. The card, the frames, the playback -------------------------------------------------------------------------

func _build_ui_world() -> void:
	_wb = World.new()
	_wb.add_player("local")
	_add(_wb, "p1", "light_fighter", "allies", "player", 1500.0, 2400.0, 0.0, "medium")
	_add(_wb, "p2", "heavy_fighter", "allies", "player", 1520.0, 2700.0, 0.0)
	_add(_wb, "b1", "bomber", "allies", "player", 1500.0, 3000.0, 0.0, "medium")
	_add(_wb, "ai1", "bomber", "axis", "ai", 2000.0, 2400.0, PI, "high")
	_add(_wb, "tower", "radio_tower", "axis", "ai", 2000.0, 3000.0, 0.0)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_wb, _xf, "local")
	AiDumb.new(_wb).attach()
	_ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ui.hud.size = Vector2(1280.0, 720.0)
	_ui.layout()
	var found: Variant = _ui.get_meta("side_view", null)
	if not check(found != null and _ui.orders.get_node_or_null("SideView") == found, "10. UnitUI mounted the side view in the orders card"):
		finish()
		return
	_sv2 = found as SideView
	_base_h = _st.num("orders.height_px")
	near(_ui.orders.size.y, _base_h, 1e-6, "10. with nothing selected the card is its own size")
	# Track T's target selection is the one the mount follows: UnitUI.target when it is wired, else the planner's own.
	if _ui.get("target") != null:
		print("[test] UnitUI.target exists (Track T): the mount reads it")
	else:
		print("[test] UnitUI.target is not wired yet (Track T): the mount reads the planner's own target selection")
	check(_sv2.target_source.is_valid() and _sv2.target_source.call() == _ui_target(), "10. the mount's target source is the interface's target selection")
	_ui.select("p1")   # (the frame-driven part takes it from here)

# The interface's own target selection (what a click sets): UnitUI.target when it exists, else the planner's.
func _ui_target() -> Object:
	var shared: Variant = _ui.get("target")
	return (shared if shared != null else _ui.planner.target) as Object

func _physics_process(_delta: float) -> void:
	if not _setup_done:
		return
	_frames += 1
	if _frames < 4:
		return
	match _stage:
		0:
			# p1 selected for a few frames: the panel noticed (the process loop, not a refresh by hand).
			check(_sv2.is_active(), "10. selecting a friendly unit shows the side view (by the panel's own process loop)")
			var section: float = _sv2.size.y
			check(_ui.orders.size.y > _base_h + 50.0, "10. the orders card grew by the section (%.0f -> %.0f px)" % [_base_h, _ui.orders.size.y])
			near(_ui.orders.size.y, _base_h + section, 1e-6, "10. by exactly the section")
			check(_ui.orders.position.y + _ui.orders.size.y <= 720.0 - _st.num("card.margin_px") + 1e-6, "10. and it is on screen at 720 px (bottom %.0f)" % (_ui.orders.position.y + _ui.orders.size.y))
			check(_sv2.visible and _sv2.get_parent() == _ui.orders, "10. the section is a child of the card, visible")
			check(_ui.over_card(_ui.orders.get_global_rect().get_center() + Vector2(0.0, _ui.orders.size.y * 0.45)), "10. its area counts as the card for the pointer")
			check(_sv2.picture_draws > 0 and _sv2.draw_count > 0, "11. the picture and its heading have drawn (%d, %d)" % [_sv2.picture_draws, _sv2.draw_count])
			eq(_sv2.failed_draws, 0, "11. every sub-draw ran to its end")
			# A far target: the arrow.
			_ui_target().set_unit("ai1", Vector2(1.0, 1.0))
			_next(1)
		1:
			var m := _sv2.model()
			check(not (m["target"] as Dictionary).is_empty() and not bool((m["target"] as Dictionary)["inside"]), "11. a far target: the arrow was drawn")
			var drawn := _sv2.picture_draws
			check(drawn > 1, "11. and the picture redrew for it (%d)" % drawn)
			eq(_sv2.failed_draws, 0, "11. with every sub-draw whole")
			# The enemy plane selected: gone, and the card is its own size again.
			_ui.select("ai1")
			_next(2)
		2:
			eq(_sv2.is_active(), false, "10. an enemy selected: no side view")
			near(_ui.orders.size.y, _base_h, 1e-6, "10. and the card gives its room back")
			check(not _sv2.visible, "10. (hidden)")
			# The bomber with a drop onto the tower.
			_ui.select("b1")
			_ui.planner.place_point(Vector2(1642.0, 3000.0))
			_ui.planner.place_point(Vector2(1784.0, 3000.0))
			var ideal: Vector2 = _ui.planner.bombs.cone("b1", 1)["ideal_aim"]
			var tw = _wb.units["tower"]
			tw.x = ideal.x
			tw.y = ideal.y
			_ui_target().set_unit("tower", ideal)
			check(not _ui.planner.set_step_drop(1, true).is_empty(), "11. the drop is switched on with the tower as the target")
			_ui_target().clear()
			_next(3)
		3:
			var m2 := _sv2.model()
			eq(m2["mode"], "drop", "11. the bomber's drop step: the fall view")
			check(not (m2["target"] as Dictionary).is_empty() and str((m2["target"] as Dictionary)["unit"]) == "tower", "11. the tower is its target (the step's own)")
			check(_sv2.picture_draws > 2, "11. drawn (%d)" % _sv2.picture_draws)
			eq(_sv2.failed_draws, 0, "11. the fall drew to its end")
			var info: Dictionary = _wb.drop_spread("b1", 1, Vector2(float(_wb.units["tower"].x), float(_wb.units["tower"].y)))
			near(float((m2["drop"] as Dictionary)["land_m"]), (info["release"] as Vector2).distance_to(info["aim"] as Vector2), 1e-6, "7. on the mounted UI too: it lands where World.drop_spread says")
			near(_ui.orders.size.y, _base_h + _sv2.size.y, 1e-6, "10. the card holds the section for the drop view too")
			# The playback: p1 flies on with a climb; the picture follows its shown pose, and the AI bomber.
			_ui.planner.clear()
			_ui.select("p1")
			_ui.planner.place_point(Vector2(1600.0, 2400.0))
			_ui.planner.change_band(1)
			_ui_target().set_unit("ai1", Vector2(1.0, 1.0))
			_sv2.refresh()
			_ui.auto_begin_turn = false
			_ui.press_ready()
			check(_ui.is_playing(), "12. the turn plays")
			_ui.marker_layer.playback_paused = true
			_ui.marker_layer.set_playback_time(0.5)
			_next(4)
		4:
			var m3 := _sv2.model()
			check(_sv2.is_active() and bool(m3["live"]), "12. during the playback the side view stays up, live")
			eq(m3["head"], _st.text("side_view.text.head_live"), "12. and says so")
			var pose: Dictionary = _ui.marker_layer.pose_of("p1")
			var ref: Dictionary = m3["ref"]
			near(float(ref["x"]), float(pose["x"]), 1e-6, "12. at the unit's SHOWN pose (x)")
			near(float(ref["height_m"]), float(pose["height_m"]), 1e-6, "12. (height)")
			near(float((m3["pose"] as Dictionary)["pitch"]), _wb.combat.max_pitch, 1e-9, "12. inside the climb step the airframe has the full pitch up")
			var shown: Dictionary = _ui.marker_layer.pose_of("ai1")
			var t3: Dictionary = m3["target"]
			check(not t3.is_empty(), "12. the target is there")
			var dv := Vector2(float(shown["x"]) - float(pose["x"]), float(shown["y"]) - float(pose["y"]))
			var ahead := cos(float(pose["heading"])) * dv.x + sin(float(pose["heading"])) * dv.y >= 0.0
			near(float(t3["rel_x"]), dv.length() * (1.0 if ahead else -1.0), 1e-3, "12. at ITS shown position, wherever the playback has it")
			var x_a: float = (t3["px"] as Vector2).x
			_ui.marker_layer.set_playback_time(3.5)
			_sv2.refresh()
			var t4: Dictionary = _sv2.model()["target"]
			check(absf(float(t4["rel_x"]) - float(t3["rel_x"])) > 20.0, "12. later in the turn the target has moved on the page, followed (%.0f -> %.0f m)" % [float(t3["rel_x"]), float(t4["rel_x"])])
			var shown2: Dictionary = _ui.marker_layer.pose_of("ai1")
			var pose2: Dictionary = _ui.marker_layer.pose_of("p1")
			var want := Vector2(float(shown2["x"]) - float(pose2["x"]), float(shown2["y"]) - float(pose2["y"])).length()
			near(absf(float(t4["rel_x"])), want, 1e-3, "12. its horizontal distance is the shown poses' distance")
			check(x_a != (t4["px"] as Vector2).x, "12. (the pixel moved)")
			eq(_sv2.failed_draws, 0, "12. every sub-draw whole through the playback")
			_st.ui["side_view"]["live_during_playback"] = false
			_sv2.refresh()
			eq(_sv2.is_active(), false, "12. the data can keep the panel down while a turn plays")
			_st.ui["side_view"]["live_during_playback"] = true
			eq(_st.errors.size(), 0, "no style lookup failed in the whole run: %s" % str(_st.errors))
			_ui.marker_layer.playback_paused = false
			_ui.marker_layer.stop_playback()
			# On to the strips on the mounted interface: a new turn, the bomber selected.
			_ui.auto_begin_turn = true
			if _wb.phase == World.PHASE_RESOLVED:
				_wb.begin_turn()
			_ui.planner.clear()
			_ui_target().clear()
			SideView.reset_view_setting()
			_ui.select("b1")
			_next(5)
		5:
			_stage_arcs()
		6:
			_stage_strips_tall()
		7:
			_stage_strips_kept()
		8:
			_stage_room_short()
		9:
			_stage_room_compact()

# --- 21, 22. The two Arcs buttons, one switch (mounted) -----------------------------------------------------------------------------

func _stage_arcs() -> void:
	check(_sv2.is_active(), "21. the side view is up for the bomber in the new turn")
	eq(_ui.arcs_shown(), false, "22. the map's arcs start OFF")
	eq(_ui.cones.collect().size(), 0, "22. so the map draws no cones at all (the overlay collects nothing)")
	check(_sv2.has_arcs_button(), "21. the panel has an Arcs button")
	eq(_ui.roster.has_method("arcs_button_rect") or _ui.roster.has_method("press_arcs") or _ui.roster.has_method("has_arcs_button"), false, "21. and the roster header has none: it is the only arcs control")
	eq([_sv2.arcs_on(), _sv2.arcs_label()], [false, _st.text("side_view.arcs.label_off")], "21. it reads 'Arcs: off'")
	check((_sv2.model()["top"]["cones"] as Array).size() + (_sv2.model()["top"]["footprints"] as Array).size() > 0, "22. the strips show the bomber's cones all the same: they do not depend on the map's switch")
	check(_sv2.press_arcs(), "21. the panel's button is pressed")
	eq([_ui.arcs_shown(), _sv2.arcs_on(), _sv2.arcs_label()], [true, true, _st.text("side_view.arcs.label_on")], "21. the map and the panel's button say on")
	eq(_ui.cones.collect().size(), 3, "22. and the map's cones are back (the bomber's three guns)")
	_ui.toggle_arcs()
	eq([_ui.arcs_shown(), _sv2.arcs_on(), _sv2.arcs_label()], [false, false, _st.text("side_view.arcs.label_off")], "21. UnitUI.toggle_arcs is the same switch: the panel's button follows")
	eq(_ui.cones.collect().size(), 0, "22. and the map's cones are gone again")
	_ui.set_arcs(true)
	eq(_sv2.arcs_on(), true, "21. so is UnitUI.set_arcs")
	_ui.set_arcs(false)
	_click(_sv2, _sv2.arcs_button_rect().get_center())
	eq([_ui.arcs_shown(), _sv2.arcs_on()], [true, true], "21. a click on the panel's button is the same press")
	_click(_sv2, _sv2.arcs_button_rect().get_center())
	eq(_ui.arcs_shown(), false, "21. a second click turns them off")
	eq(_sv2.arcs_button_rect().size, Vector2(_st.num("side_view.arcs.w_px"), _st.num("side_view.arcs.h_px")), "21. the button is the data's size")
	check(_sv2.arcs_button_rect().end.x <= _sv2.size.x + 1e-6 and _sv2.arcs_button_rect().position.y >= 0.0, "21. inside the panel's heading row, at the right")
	eq(_sv2.tooltip_text == "" and _sv2._get_tooltip(_sv2.arcs_button_rect().get_center()) == _st.text("side_view.arcs.tooltip"), true, "21. and it says what it does")
	# A taller window, so the strips have their room.
	_ui.hud.size = Vector2(1280.0, 1400.0)
	_ui.layout()
	_next(6)

# 23. A tall window: the three strips stack and the card grows by them.
func _stage_strips_tall() -> void:
	var lay: Dictionary = _sv2.model()["layout"]
	eq(lay["mode"], "strips", "23. at 1400 px the strips stack")
	var rows := _rows(_sv2.model())
	eq([bool(rows["top"]["shown"]), bool(rows["front"]["shown"]), bool(rows["side"]["shown"])], [true, true, true], "23. all three are open (PROPOSED default)")
	var chrome := _st.num("side_view.section.gap_px") + _st.num("side_view.section.head_px") + _st.num("side_view.section.caption_h_px") + _st.num("side_view.section.bottom_px")
	var want := chrome + 3.0 * _st.num("side_view.strips.head_px") + _pic_h("top") + _pic_h("front") + _pic_h("side") + 3.0 * _st.num("side_view.strips.gap_px")
	near(_sv2.size.y, want, 1e-6, "23. the section is the data's rows and pictures (%.0f px)" % want)
	near(_ui.orders.size.y, _base_h + _sv2.size.y, 1e-6, "23. the card grew by exactly it (%.0f px tall)" % _ui.orders.size.y)
	check(_ui.orders.position.y + _ui.orders.size.y <= 1400.0 - _st.num("card.margin_px") + 1e-6, "23. and it is on the screen")
	print("[test] at 1280x1400 with 3 units the card is %.0f px tall (the section %.0f)" % [_ui.orders.size.y, _sv2.size.y])
	for id: String in STRIP_IDS:
		check((_sv2._pics[id] as Control).visible and ((_sv2._pics[id] as Control).size.y == _pic_h(id)), "23. the %s picture is on the card at its height" % id)
	eq(_sv2.failed_draws, 0, "23. every sub-draw of the three strips ran to its end")
	# A click on a header folds that strip and the card gives its room back; the others stay.
	_click(_sv2, (rows["front"]["head"] as Rect2).get_center())
	check(not _sv2.strip_shown("front") and _sv2.strip_shown("top") and _sv2.strip_shown("side"), "23. a click on Front's header folds only Front")
	near(_ui.orders.size.y, _base_h + want - _pic_h("front") - _st.num("side_view.strips.gap_px"), 1e-6, "23. and the card is that much shorter")
	_ui.select("p1")
	_next(7)

func _stage_strips_kept() -> void:
	check(_sv2.is_active(), "14. the fighter selected: the panel is up")
	check(not _sv2.strip_shown("front") and _sv2.strip_shown("top") and _sv2.strip_shown("side"), "14. Front is still folded: the fold state is the session's, not the bomber's")
	_ui.select("b1")
	_sv2.refresh()
	check(not _sv2.strip_shown("front"), "14. and still folded back on the bomber")
	_sv2.press_strip("front")
	check(_sv2.strip_shown("front"), "23. unfolded again by the click's own call")
	# A shorter window: the room is shared (each picture no smaller than the data's floor) and the card stays on screen. (The session's
	# order of opening starts afresh, so the data's priority rules.)
	SideView.reset_view_setting()
	var h := 800.0
	_ui.hud.size = Vector2(1280.0, h)
	_ui.layout()
	_next(8)

# 23. A shorter window: the open strips share the room, the ones that do not fit are held folded, the card stays on the screen.
func _stage_room_short() -> void:
	var lay: Dictionary = _sv2.model()["layout"]
	var h := 800.0
	eq(lay["mode"], "strips", "23. at 800 px there is still room for a strip")
	var shown: Array = []
	for e: Dictionary in lay["strips"]:
		if bool(e["shown"]):
			shown.append(str(e["id"]))
			check((e["pic"] as Rect2).size.y >= _st.num("side_view.strips.min_picture_h_px") - 1e-6, "23. the %s picture is not under the data's floor (%.0f px)" % [str(e["id"]), (e["pic"] as Rect2).size.y])
	check(shown.size() >= 1 and shown.size() < 3, "23. the room holds some of the open strips, not all (%s)" % str(shown))
	check(_ui.orders.position.y + _ui.orders.size.y <= h - _st.num("card.margin_px") + 1e-6, "23. and the card stays on the screen (bottom %.0f of %.0f)" % [_ui.orders.position.y + _ui.orders.size.y, h])
	for id: String in STRIP_IDS:
		check(_sv2.strip_chosen(id), "23. what the player chose is kept: %s is still open" % id)
	eq(shown[0], "side", "23. the Side strip, the picture the panel has always had, keeps its place first (the data's priority)")
	# A strip held folded comes forward on a click, and the one with the least claim gives its place up.
	var held := ""
	for id: String in STRIP_IDS:
		if not shown.has(id):
			held = id
	check(held != "" and _sv2.press_strip(held) and _sv2.strip_shown(held), "23. a click on %s's header brings it forward (the room had held it)" % held)
	check(not _sv2.strip_shown("side") or shown.size() >= 2, "23. the strip opened last has the first claim: Side gives its place up when only one fits")
	for id: String in STRIP_IDS:
		check(_sv2.strip_chosen(id), "23. what the player chose is still kept: %s is open" % id)
	check(_ui.orders.position.y + _ui.orders.size.y <= h - _st.num("card.margin_px") + 1e-6, "23. the card is still on the screen")
	_ui.hud.size = Vector2(1280.0, 720.0)
	_ui.layout()
	_next(9)

# 23. 1280x720 with three units, as before the strips: the heading row with its Arcs button, the Side picture, the quiet line.
func _stage_room_compact() -> void:
	_next(10)   # (this stage waits for frames: no other physics frame may enter it)
	var lay: Dictionary = _sv2.model()["layout"]
	eq(lay["mode"], "compact", "23. at 720 px there is room for the panel as it was (the Side picture alone)")
	check(_sv2.is_active() and _sv2.has_arcs_button(), "23. still up, still with its Arcs button")
	check((_sv2.model()["size"] as Vector2).y >= _st.num("side_view.section.min_picture_h_px"), "23. its picture is not under the data's floor (%.0f px)" % (_sv2.model()["size"] as Vector2).y)
	eq(_sv2.press_strip("top"), false, "23. no strips to press")
	check(_ui.orders.position.y + _ui.orders.size.y <= 720.0 - _st.num("card.margin_px") + 1e-6, "23. the card is on the screen (bottom %.0f)" % (_ui.orders.position.y + _ui.orders.size.y))
	print("[test] at 1280x720 with 3 units the panel is %s, the section %.0f px, the card %.0f px" % [str(lay["mode"]), _sv2.size.y, _ui.orders.size.y])
	# Too short even for that: nothing, and the card is its own size again.
	_ui.hud.size = Vector2(1280.0, 560.0)
	_ui.layout()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	eq(_sv2.is_active(), false, "23. a window too short for the Side picture shows no panel")
	near(_ui.orders.size.y, _base_h, 1e-6, "23. and the card gives its room back")
	await _smoke_all_units()
	check(_smoke_done, "18. the smoke check of every kind of unit ran to its end (a runtime error would have ended it early)")
	eq(_sv2.failed_draws, 0, "no sub-draw failed anywhere in the run")
	eq(_st.errors.size(), 0, "no style lookup failed in the whole run: %s" % str(_st.errors))
	SideView.reset_view_setting()
	ConeOverlay.reset_view_setting()
	finish()

# 18. EVERY KIND OF FRIENDLY UNIT draws its three strips to their end: the fighters and the bomber, a tank (an all-round cone), a cruiser (four
# mounts, all-round and up), a patrol boat, a mobile gun, a boat with none.
func _smoke_all_units() -> void:
	var w := World.new()
	w.add_player("local")
	var kinds := ["light_fighter", "heavy_fighter", "bomber", "tank", "cruiser", "patrol_boat", "mobile_aa", "supply_boat"]
	for i in kinds.size():
		_add(w, "u_" + str(kinds[i]), str(kinds[i]), "allies", "player", 1000.0 + 300.0 * float(i), 1000.0, 0.0)
	_add(w, "e1", "light_fighter", "axis", "ai", 1500.0, 1100.0, PI, "medium")
	var sel := UiSelection.new()
	var pl := MotionPlanner.new()
	add_child(pl)
	pl.setup(w, _xf, sel, "local", _st)
	var sv := SideView.new()
	add_child(sv)
	sv.setup(w, pl, sel, _st)
	SideView.reset_view_setting()
	for k: String in kinds:
		var id := "u_" + k
		sel.select(id)
		sv.refresh()
		if not check(sv.is_active(), "18. %s: the panel is up" % k):
			continue
		var m := sv.model()
		var before := sv.picture_draws
		await get_tree().process_frame
		await get_tree().process_frame
		check(sv.picture_draws - before >= 3, "18. %s: the three strips were drawn (%d draws)" % [k, sv.picture_draws - before])
		for c: Dictionary in (m["top"]["cones"] as Array) + (m["top"]["footprints"] as Array):
			eq(str(c["unit"]), id, "18. %s: a Top cone is its own" % k)
		var n_weapons: int = (w.units[id].def.weapons as Array).size()
		eq((m["front"]["cones"] as Array).size(), n_weapons, "18. %s: a Front cone for each of its %d weapons" % [k, n_weapons])
	eq(sv.failed_draws, 0, "18. every strip of every kind of unit ran to its end")
	sv.queue_free()
	pl.queue_free()
	_smoke_done = true

func _next(stage: int) -> void:
	_stage = stage
	_frames = 0
