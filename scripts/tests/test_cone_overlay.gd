extends "res://scripts/test_support/test_case.gd"

# THE ENGAGEMENT-CONE OVERLAY (Track U1, the first fight; variants/cone-overlay/).
# EVERY STYLE AND RULE IS PROPOSED; this holds what must be true whichever Alex
# picks. Headless: the overlay is mounted on a World as UnitUI's map layer would
# mount it and driven through the style's data. The weapons are the unit files'
# (data/units/*.json weapons, Track C's records of the lead's proposal).
#
#   1. WHO SHOWS CONES: the selected player unit's, every weapon and hardpoint;
#      an enemy's only while it is in sight; none unless planning
#   2. WHERE THEY START: each wedge's apex is on its hardpoint, drawn on the airframe
#      at the plane's drawn size (metres x the map scale x marker.true_scale); a pair
#      of wing hardpoints are the airframe's 6 m apart on the drawn plane
#   3. THE CONE IN HEIGHT: cut at the plane's own level, a weapon pitched up as far as
#      its half height has no slice there (the dorsal turret: overhead), the others
#      keep a slice no wider than their cone
#   4. ODDS: the shading is combat.gd's centre factor: 1 at a peaked gun's centre
#      and its rim factor at the rim; even for a flat one
#   5. EVERY STYLE DRAWS TO THE END, in both layers (a runtime error in a draw
#      function ends it silently: each sub-draw returns true as its last act and
#      the overlay tallies the ones that did not)

const World = preload("res://scripts/sim/world.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const Combat = preload("res://scripts/sim/combat.gd")

const PPM := 2.0

var _st: UiStyle
var _ov: ConeOverlay
var _w: World
var _sel: UiSelection
var _modes: Array = []
var _next := 0
var _frame := 0
var _saved_mode := ""
var _saved_enemy := ""
var _counts := {}
var _setup_done := false     # set at the end of setup(): a runtime error in setup() ends it silently

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_saved_mode = _st.text("planner.cones.mode")
	_saved_enemy = _st.text("planner.cones.enemy")
	# Alex 2026-10-09 (decision cone-overlay): the colour wash, for the
	# selected unit only -- no enemy cones. The rest of this test exercises the
	# overlay's other rules too, so it sets them explicitly and restores the
	# data's values at the end.
	eq(_saved_mode, "wash", "the data holds Alex's choice: the colour wash")
	eq(_saved_enemy, "none", "the data holds Alex's choice: no enemy cones")
	eq(_st.text("planner.cones.own"), "selected", "the data holds Alex's choice: the selected unit only")
	_st.ui["planner"]["cones"]["enemy"] = "in_sight"
	_modes = _st.lookup("planner.cones.modes")
	check(_modes.size() >= 4, "the data lists the styles: %s" % str(_modes))
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.0})
	_w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1200.0, "heading": 0.0})
	_w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 1500.0, "y": 1000.0, "heading": 0.0})
	_sel = UiSelection.new()
	_ov = ConeOverlay.new()
	add_child(_ov)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, Vector2.ZERO)
	_ov.setup(_w, xf, _sel, _st)

	# 1. Who shows cones.
	var none := _ov.collect()
	eq(_count(none, "ai1"), 3, "nothing selected: the bomber's three turrets, in sight")
	eq(_count(none, "p1") + _count(none, "p2"), 0, "nothing selected: no player cones")
	_sel.select("p1")
	var sel1 := _ov.collect()
	eq(_count(sel1, "p1"), 2, "the light fighter selected: its wing guns, one wedge per hardpoint")
	eq(_count(sel1, "p2"), 0, "the other player plane shows none")
	_ov.unit_visible = func(id: String) -> bool: return id != "ai1"
	eq(_count(_ov.collect(), "ai1"), 0, "an enemy out of sight shows no cones")
	_ov.unit_visible = Callable()
	_sel.select("p2")
	eq(_count(_ov.collect(), "p2"), 2, "the heavy fighter selected: nose cannon and rear gunner")
	_st.ui["planner"]["cones"]["own"] = "all_own"
	eq(_count(_ov.collect(), "p1") + _count(_ov.collect(), "p2"), 4, "own = all_own: every player unit's")
	_st.ui["planner"]["cones"]["own"] = "selected"
	_st.ui["planner"]["cones"]["enemy"] = "none"
	eq(_count(_ov.collect(), "ai1"), 0, "enemy = none: no enemy cones")
	_st.ui["planner"]["cones"]["enemy"] = "in_sight"
	_w.phase = World.PHASE_RESOLVING
	eq(_ov.collect().size(), 0, "no cones while a turn resolves")
	_w.phase = World.PHASE_PLANNING

	# 2. The apex is on the hardpoint, at the drawn size.
	_sel.select("p1")
	# The sandbox draws planes at their own scale, so true_scale is not 1: the apex must follow it.
	var k0: float = _st.num("marker.true_scale")
	_st.set_num("marker.true_scale", 2.5)
	var k: float = _st.num("marker.true_scale")
	var wing: Array = _of(_ov.collect(), "p1")
	if check(wing.size() == 2, "two wing cones"):
		var w = wing[0]["weapon"]
		var sp: Vector2 = wing[0]["sp"]
		var u = _w.units["p1"]
		check(sp.is_equal_approx(Vector2(float(u.x), float(u.y)) * PPM), "the unit's screen position is the host mapping's")
		for c: Dictionary in wing:
			var hp: Vector3 = w.hardpoints[int(c["hp"])]
			# Heading 0: forward is screen +x, right is screen +y.
			var want := sp + Vector2(hp.x, hp.y) * PPM * k
			check((c["apex"] as Vector2).is_equal_approx(want), "wing hardpoint %d: the apex is the hardpoint on the drawn airframe" % int(c["hp"]))
		near((wing[1]["apex"] as Vector2).distance_to(wing[0]["apex"]), absf(w.hardpoints[1].y - w.hardpoints[0].y) * PPM * k, 1e-6, "the two wing apexes are the hardpoints' spacing apart at the drawn size")
		near(float(wing[0]["range_px"]), float(w.range_m) * PPM, 1e-6, "the range is the true range at the map's scale")
		near(float(wing[0]["phi"]), 0.0, 1e-9, "a forward gun's centre line is the heading")
		near(float(wing[0]["half"]), float(w.half_across), 1e-9, "a level forward gun keeps its whole width at the plane's level")
	_st.set_num("marker.true_scale", k0)
	# A rearward weapon points the other way.
	var rear: Array = _of(_ov.collect(), "ai1")
	for c: Dictionary in rear:
		var wn = c["weapon"]
		near(absf(angle_difference(float(c["phi"]), float(wn.mount))), 0.0, 1e-9, "%s: the centre line is heading + mount" % str(wn.id))

	# 3. The cone in height, cut at the plane's own level.
	for c: Dictionary in rear:
		var wn = c["weapon"]
		var half := float(c["half"])
		if absf(wn.elevation) >= wn.half_height - 1e-9:
			eq(half, 0.0, "%s: pitched up by its whole half height, it has no slice at the plane's level (overhead)" % str(wn.id))
		else:
			check(half > 0.0 and half <= float(wn.half_across) + 1e-9, "%s: a slice no wider than the cone" % str(wn.id))
	var heavy_rear: Array = _of(_sel_cones("p2"), "p2")
	for c: Dictionary in heavy_rear:
		if (c["weapon"] as Object).id == "rear_gunner":
			var wr = c["weapon"]
			var expect := float(wr.half_across) * sqrt(1.0 - pow(wr.elevation / wr.half_height, 2.0))
			near(float(c["half"]), expect, 1e-9, "the rear gunner's slice at level: its width times sqrt(1 - (elevation / half height)^2)")

	# 4. The odds are combat.gd's centre factor.
	for c: Dictionary in _of(_sel_cones("p2"), "p2"):
		var wc = c["weapon"]
		var o0: float = ConeOverlay.odds_rel(c, 0.0)
		var o1: float = ConeOverlay.odds_rel(c, float(c["half"]))
		var b0 := float(c["b0"])
		near(o0, Combat.centre_factor(wc, absf(b0)), 1e-9, "%s: at the centre line the factor is combat.gd's at the level's height offset" % str(wc.id))
		near(o1, Combat.centre_factor(wc, 1.0), 1e-9, "%s: at the slice's edge the factor is combat.gd's at the rim" % str(wc.id))
		if wc.rim_odds_factor < 0.999:
			check(o0 > o1 + 0.2, "%s is peaked: better at the centre than at the rim" % str(wc.id))
		else:
			near(o0, o1, 1e-9, "%s is flat: even across" % str(wc.id))

	# 4b. The effective range and the falloff past it (Alex: guns fire slightly over it).
	var frac: float = _st.num("planner.cones.overshoot_fraction")
	check(frac > 0.0 and frac < 1.0, "the overshoot is a fraction of the effective range (%s)" % str(frac))
	for c: Dictionary in _of(_sel_cones("p2"), "p2"):
		var wr = c["weapon"]
		near(float(c["range_px"]), float(wr.range_m) * PPM, 1e-6, "%s: the rim is the effective range" % str(wr.id))
		near(float(c["reach_px"]), float(wr.range_m) * (1.0 + frac) * PPM, 1e-6, "%s: the odds reach zero an overshoot beyond it" % str(wr.id))
		var r_px: float = c["range_px"]
		var over: float = float(c["reach_px"]) - r_px
		eq(ConeOverlay.range_rel(c, 0.0), 1.0, "%s: full odds at the apex" % str(wr.id))
		eq(ConeOverlay.range_rel(c, r_px), 1.0, "%s: full odds up to the effective range" % str(wr.id))
		eq(ConeOverlay.range_rel(c, r_px + over), 0.0, "%s: none at the reach" % str(wr.id))
		eq(ConeOverlay.range_rel(c, r_px + over * 2.0), 0.0, "%s: none beyond it" % str(wr.id))
		var prev := 1.0
		var smooth_ok := true
		for i in range(1, 20):
			var f := ConeOverlay.range_rel(c, r_px + over * float(i) / 20.0)
			if f > prev + 1e-9 or f < 0.0 or f > 1.0:
				smooth_ok = false
			prev = f
		check(smooth_ok, "%s: the range factor only falls, between 1 and 0, through the zone" % str(wr.id))
		near(ConeOverlay.range_rel(c, r_px + over * 0.5), 0.5, 1e-9, "%s: half way through the zone the smooth ramp is at half" % str(wr.id))
		check(ConeOverlay.inside(c, (c["apex"] as Vector2) + Vector2.from_angle(float(c["phi"])) * (r_px + over * 0.5), float(c["half"])), "%s: a point in the falloff zone is inside the drawn wedge" % str(wr.id))
		check(not ConeOverlay.inside(c, (c["apex"] as Vector2) + Vector2.from_angle(float(c["phi"])) * (r_px + over * 1.05), float(c["half"])), "%s: and one past the reach is not" % str(wr.id))
	# The host's own factor (Track C's, when it lands) sizes the zone and shapes the fall.
	var linear := func(wpn: Object, d_m: float) -> float: return clampf(1.0 - (d_m - float(wpn.range_m)) / (float(wpn.range_m) * 0.5), 0.0, 1.0)
	_ov.range_factor = linear
	for c: Dictionary in _of(_sel_cones("p2"), "p2"):
		var wq = c["weapon"]
		near(float(c["reach_px"]), float(wq.range_m) * 1.5 * PPM, float(wq.range_m) * 0.05 * PPM, "%s: the zone is as long as the host's factor says (a half of the range here)" % str(wq.id))
		near(ConeOverlay.range_rel(c, float(c["range_px"]) * 1.25), 0.5, 1e-6, "%s: the host's factor is the one sampled" % str(wq.id))
	_ov.range_factor = Callable()

	# 5. Every style draws, in both layers.
	_sel.select("p2")
	_next = 0
	_setup_done = true
	timeout_seconds = 60.0

func _sel_cones(id: String) -> Array:
	_sel.select(id)
	return _ov.collect()

func _count(cones: Array, unit: String) -> int:
	return _of(cones, unit).size()

func _of(cones: Array, unit: String) -> Array:
	return cones.filter(func(c: Dictionary) -> bool: return c["unit"] == unit)

# One style per two frames: set it, let the overlay see the change and draw.
func _physics_process(_delta: float) -> void:
	if _modes.is_empty() or _finished_all():
		return
	_frame += 1
	if _frame % 3 == 1:
		if _next > 0:
			var prev: String = _modes[_next - 1]
			_counts[prev] = [_ov.draw_count, _ov.marks_draw_count]
		if _next >= _modes.size():
			_done()
			return
		_st.ui["planner"]["cones"]["mode"] = _modes[_next]
		_next += 1

func _finished_all() -> bool:
	return _next > _modes.size() + 1

func _done() -> void:
	_next = _modes.size() + 2
	check(_setup_done, "setup() ran to its end (a runtime error would have ended it early, leaving every assertion above unrun)")
	var last_fill := -1
	var last_marks := -1
	for m: String in _modes:
		var c: Array = _counts.get(m, [0, 0])
		check(int(c[0]) > last_fill, "style '%s': the fill layer drew to its end" % m)
		check(int(c[1]) > last_marks, "style '%s': the marks layer drew to its end" % m)
		last_fill = int(c[0])
		last_marks = int(c[1])
	eq(_ov.failed_draws, 0, "every sub-draw of every style ran to its end (a runtime error would end one early)")
	eq(_st.errors.size(), 0, "no style error was raised by drawing: %s" % str(_st.errors))
	_st.ui["planner"]["cones"]["mode"] = _saved_mode
	_st.ui["planner"]["cones"]["enemy"] = _saved_enemy
	finish()
