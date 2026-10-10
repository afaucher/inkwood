extends "res://scripts/test_support/test_case.gd"

# COMBAT ON THE MAP (Track U2, "the first fight", part 2). Headless: the interface is mounted
# through UnitUI exactly as the sandbox mounts it, worlds are fought for real (World.resolve with
# the seeds FOUND for each fate, scripts/test_support/combat_worlds.gd) and the playback is
# stepped by hand the way a host's frames step it. Every number tested is PROPOSED data
# (data/ui/ui.json combat.*) or the sim's own.
#
#   1. MOUNT: the pieces sit in the right order (the effects' ground, shadow and air passes under
#      the planner; the cone overlay's interior, then the wingtip trails, just under the markers;
#      the effects' bursts and the overlay above them) and the cone overlay's "Marks" child over
#      the markers; the effects layer has the world's seed and the data's working-default options
#   2. THE RANGE FACTOR on the cone overlay is combat.gd's own, with the rules' own overshoot
#   3. AN EXPLODED PLANE: its marker is there before down_at and gone from it, and after the turn
#   3b. THE LINE AHEAD of a plane during a playback: the players' own planes only (the enemy's plan is
#      never shown), and only up to the moment a unit goes down (no spoiled deaths)
#   4. AN OUT-OF-CONTROL PLANE: its marker follows the sample, its shadow gap closes with the
#      fall height (continuous at down_at over ground), it rocks; it is gone at the crash
#   5. THE EFFECTS FEED, against a recording fake of the layer: calls in event order at the right
#      game times, damage smoke on the exact grid of the layer with the health fraction of that
#      moment, falling() each frame, impact() at the crash, nothing for a unit out of sight
#   6. THE INK ON A HIT: appears at the hit event, full at once, a paper flash gone in a blink, a
#      very slow decay; tracers off by default and on when switched
#   7. LATE JOINERS: a wreck on the ground comes back as a scar
#   8. THE FRAMES: the real frame order draws every piece whole

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")
const HitMarks = preload("res://scripts/ui/hit_marks.gd")
const CombatWorlds = preload("res://scripts/test_support/combat_worlds.gd")

const PPM := 1.5
const ORIGIN := Vector2(1000.0, 2200.0)

# The effects layer's calls, recorded. Has the FxLayer calls UnitUI's feed makes.
class _FakeFx extends RefCounted:
	var calls: Array = []
	var true_scale: float = 1.0
	var now: float = 0.0
	func emit_path(unit_id: String, sampler: Callable, t0: float, t1: float, frac: float, size_m: float = 9.0) -> int:
		calls.append({"call": "emit_path", "unit": unit_id, "t0": t0, "t1": t1, "frac": frac, "size": size_m,
			"first": sampler.call(t0), "last": sampler.call(t1)})
		return 0
	func falling(unit_id: String, pos: Vector2, h: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
		calls.append({"call": "falling", "unit": unit_id, "pos": pos, "h": h, "t": t, "size": size_m, "heading": heading})
		return 0
	func explode_midair(unit_id: String, pos: Vector2, h: float, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
		calls.append({"call": "explode_midair", "unit": unit_id, "pos": pos, "h": h, "t": t, "size": size_m, "heading": heading})
	func impact(unit_id: String, pos: Vector2, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
		calls.append({"call": "impact", "unit": unit_id, "pos": pos, "t": t, "size": size_m, "heading": heading})
	func add_scar(unit_id: String, pos: Vector2, t: float, size_m: float = 9.0, rot: float = 0.0, seed_v: int = 0) -> void:
		calls.append({"call": "add_scar", "unit": unit_id, "pos": pos, "t": t, "size": size_m, "rot": rot, "seed": seed_v})
	func set_time(t: float) -> void:
		now = t
	func clear() -> void:
		calls.append({"call": "clear"})
	func of(kind: String) -> Array:
		return calls.filter(func(c: Dictionary) -> bool: return c["call"] == kind)

var _st: UiStyle
var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
var _ran := {}
var _saved := {}
var _seeds := {}

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_saved = {"k": _st.num("marker.true_scale"), "speed": _st.num("marker.playback_speed")}
	for fate: String in ["exploded", "out_of_control"]:
		_seeds[fate] = CombatWorlds.find_seed(fate)
		check(int(_seeds[fate]) > 0, "a seed sends the victim down '%s'" % fate)
	_seeds["hit"] = CombatWorlds.find_hit_seed()
	check(int(_seeds["hit"]) > 0, "a seed hits the 8-pip victim without downing it")
	print("  seeds found: %s" % str(_seeds))
	if int(_seeds["exploded"]) > 0 and int(_seeds["out_of_control"]) > 0 and int(_seeds["hit"]) > 0:
		_mount()
		_exploded()
		_ahead()
		_falling()
		_feed_exploded()
		_feed_fall()
		_feed_damage()
		_feed_fog()
		_hit_ink()
		_late_joiner()
		await _frames()
	var missing: Array = []
	for k: String in ["mount", "range", "exploded", "ahead", "falling", "feed_exploded", "feed_fall", "feed_damage", "feed_fog", "hit_ink", "late_joiner", "frames"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	_st.set_num("marker.true_scale", float(_saved["k"]))
	finish()

# --- helpers -----------------------------------------------------------------------------------

# A UnitUI on a world, mounted in a Node2D of its own so the children's order can be read.
func _ui_on(w: World) -> Array:
	var mount := Node2D.new()
	mount.name = "Mount"
	add_child(mount)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local", mount, null)
	return [ui, mount]

func _game_t(turn_no: int, t: float) -> float:
	return float(turn_no - 1) * 5.0 + t

# --- 1 and 2: the mount ----------------------------------------------------------------------------

func _mount() -> void:
	var w := CombatWorlds.world(int(_seeds["hit"]), 8)
	var made := _ui_on(w)
	var ui: UnitUI = made[0]
	var mount: Node2D = made[1]
	var idx := func(n: Node) -> int: return mount.get_children().find(n)   # read afresh: the order is changed below
	check(ui.fx != null and ui.cones != null and ui.trails != null and ui.hit_marks != null and ui.feed != null and ui.result_card != null, "UnitUI built the effects layer, the cone overlay, the trails, the hit marks, the feed and the result card")
	check(_st.flag("marker.trails.under_smoke"), "the data puts the ribbon under the smoke (proposed default)")
	check(idx.call(ui.trails) >= 0 and idx.call(ui.trails) < idx.call(ui.fx), "the wingtip ribbon is UNDER the effects layer (the smoke is over it)")
	check(idx.call(ui.fx) < idx.call(ui.planner), "the effects' ground, shadow and air passes are under the planner")
	check(idx.call(ui.planner) < idx.call(ui.cones), "the cone overlay (its interior) is over the planner")
	check(idx.call(ui.cones) < idx.call(ui.marker_layer) and idx.call(ui.marker_layer) - idx.call(ui.cones) == 1, "the cones are just under the markers")
	check(idx.call(ui.marker_layer) < idx.call(ui.fx_above), "the effects' bursts are over the planes")
	check(idx.call(ui.fx_above) < idx.call(ui.overlay), "...and under the overlay (the health arc)")
	# The other order: the ribbon over the smoke, just under the planes (after the cones).
	_st.ui["marker"]["trails"]["under_smoke"] = false
	ui.apply_trail_order()
	check(idx.call(ui.fx) < idx.call(ui.planner) and idx.call(ui.planner) < idx.call(ui.cones) and idx.call(ui.cones) < idx.call(ui.trails) and idx.call(ui.trails) < idx.call(ui.marker_layer) and idx.call(ui.marker_layer) - idx.call(ui.trails) == 1,
		"under_smoke false: the ribbon is over the smoke, after the cones, just under the planes")
	_st.ui["marker"]["trails"]["under_smoke"] = true
	ui.apply_trail_order()
	ui.apply_trail_order()
	check(idx.call(ui.trails) < idx.call(ui.fx) and idx.call(ui.fx) < idx.call(ui.planner) and idx.call(ui.cones) < idx.call(ui.marker_layer), "...and back under the smoke, and the call is idempotent")
	eq(ui.fx.top_node.get_parent(), ui.fx_above, "the effects layer's top pass sits in fx_above")
	eq(ui.fx.ground_node.get_parent(), ui.fx, "its ground pass is under the layer, below the planes")
	var marks_node: Node2D = ui.cones.get_node("Marks")
	check(marks_node.z_index > 0, "the cone overlay's Marks child draws over the markers (z_index %d)" % marks_node.z_index)
	eq(ui.cones.marker_layer, ui.marker_layer, "the cone overlay reads the marker layer's scale")
	eq(ui.trails.marker_layer, ui.marker_layer, "the trails read the marker layer's playback clock")
	eq(ui.hit_marks.get_parent(), ui.overlay, "the hit marks are in the overlay")
	check(ui.overlay.get_child(0) == ui.health_arc and ui.hit_marks.get_index() > ui.health_arc.get_index(), "...after the health arc")
	eq(ui.result_card.get_parent(), ui.hud, "the result card is in the HUD")
	eq(ui.result_card.get_index(), ui.hud.get_child_count() - 1, "...the last child, over the roster and the orders card")
	eq(ui.fx.field.world_seed, w.rng_seed, "the effects layer has the world's seed")
	eq(ui.fx.field.smoke_name, ui.fx.data.working_default("smoke"), "it runs fx.json's working-default smoke option")
	eq(ui.fx.field.crash_name, ui.fx.data.working_default("crash"), "...and crash option")
	# The cones' fog seam follows the marker layer's, set after setup().
	ui.marker_layer.unit_visible = func(id: String) -> bool: return id != "bomber"
	check(not ui.cones.unit_visible.call("bomber") and ui.cones.unit_visible.call("fighter"), "the cones' and trails' sight seam follows marker_layer.unit_visible, set after setup()")
	ui.marker_layer.unit_visible = Callable()
	check(ui.trails.unit_visible.call("bomber"), "...and sees everything when it is cleared")
	_ran["mount"] = true

	# 2. The range factor is combat.gd's own.
	var wp = w.units["fighter"].def.weapons[0]
	var eff := float(wp.effective_range_m)
	var over: float = w.combat.range_overshoot
	for d: float in [0.0, eff * 0.5, eff, eff * (1.0 + over * 0.25), eff * (1.0 + over * 0.5), eff * (1.0 + over * 0.75), eff * (1.0 + over), eff * 3.0]:
		near(ui.cones.range_factor.call(wp, d), Combat.range_factor(wp, d, over), 1e-12, "range_factor at %.0f m is combat.gd's" % d)
	near(ui.cones.range_factor.call(wp, eff), 1.0, 1e-12, "full odds at the effective range")
	near(ui.cones.range_factor.call(wp, eff * (1.0 + over * 0.5)), 0.5, 1e-9, "half way through the overshoot the smoothstep is at half")
	near(ui.cones.range_factor.call(wp, eff * (1.0 + over)), 0.0, 1e-12, "none at the reach")
	# It follows the rules (not a stand-in of the overlay's own): a changed overshoot moves it.
	w.combat.range_overshoot = 0.5
	near(ui.cones.range_factor.call(wp, eff * 1.25), 0.5, 1e-9, "the rules' overshoot 0.5: half way is at 1.25 x the effective range")
	ui.select("fighter")
	var cones: Array = ui.cones.collect()
	var wing: Array = cones.filter(func(c: Dictionary) -> bool: return c["unit"] == "fighter")
	if check(not wing.is_empty(), "the selected fighter has cones"):
		var c: Dictionary = wing[0]
		check(absf(float(c["reach_px"]) / (float(c["range_px"]) * 1.5) - 1.0) < 0.03, "the cone's reach is the rules' reach: effective range x 1.5 (%.3f)" % (float(c["reach_px"]) / (float(c["range_px"]) * 1.5)))
	# Without the "range" factor the edge is hard.
	w.combat.odds_factors = ["centre"]
	eq(ui.cones.range_factor.call(wp, eff), 1.0, "no range factor: full odds to the effective range")
	eq(ui.cones.range_factor.call(wp, eff + 1.0), 0.0, "...and none just past it, as Combat.reach reads the rules")
	_ran["range"] = true

# --- 3: an exploded plane --------------------------------------------------------------------------------

func _exploded() -> void:
	var seed_value := int(_seeds["exploded"])
	var w := CombatWorlds.world(seed_value)
	var made := _ui_on(w)
	var ui: UnitUI = made[0]
	var layer = ui.marker_layer
	check(layer.marker("bomber").visible, "before the fight the bomber's marker is there")
	var res := CombatWorlds.turn(w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	eq(down["fate"], "exploded", "the bomber exploded")
	check(layer.is_playing(), "the playback is running")
	layer.set_playback_time(0.0)
	check(layer.marker("bomber").visible, "t = 0: the exploded plane's marker is there")
	layer.set_playback_time(t_down - 0.02)
	check(layer.marker("bomber").visible, "just before down_at (%.2f s) it is still there" % t_down)
	layer.set_playback_time(t_down)
	check(not layer.marker("bomber").visible, "at down_at it is gone (the effects take over)")
	check(not layer.marker("bomber").shadow.visible, "...and so is its shadow")
	layer.set_playback_time(4.99)
	check(not layer.marker("bomber").visible, "gone for the rest of the turn")
	check(layer.unit_at(layer.mapping.world_to_screen(Vector2(w.units["bomber"].x, w.units["bomber"].y))) == "", "it cannot be picked on the map")
	check(layer.marker("fighter").visible, "the shooter's marker is untouched")
	layer.stop_playback()
	check(not layer.marker("bomber").visible, "after the turn it is still gone")
	_ran["exploded"] = true

# --- 4: a plane out of control ------------------------------------------------------------------------

func _falling() -> void:
	var w := CombatWorlds.world(int(_seeds["out_of_control"]))
	var ui: UnitUI = _ui_on(w)[0]
	var layer = ui.marker_layer
	layer.ground_height = func(_x: float, _y: float) -> float: return 60.0
	var res := CombatWorlds.turn(w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	eq(down["fate"], "out_of_control", "the bomber lost control")
	var u: Unit = w.units["bomber"]
	var mk = layer.marker("bomber")
	var amp := deg_to_rad(_st.num("combat.fall.wobble_deg"))
	# Before down_at it is a plane like any other.
	layer.set_playback_time(t_down - 0.02)
	check(mk.visible and not layer.unit_falling("bomber"), "before down_at it flies under control")
	eq(mk.wobble, 0.0, "...and does not rock")
	var gap_before: float = mk.shadow_offset.length()
	layer.set_playback_time(t_down + 0.02)
	check(mk.visible and layer.unit_falling("bomber"), "after down_at it is falling, and still on the map")
	var gap_after: float = mk.shadow_offset.length()
	check(gap_before > 1.0 and absf(gap_after - gap_before) / gap_before < 0.04, "the shadow gap is continuous across down_at, over ground 60 m high (%.3f px then %.3f px)" % [gap_before, gap_after])
	check(absf(mk.wobble) < amp * 0.05, "the rock is eased in (%.4f rad just after down_at)" % mk.wobble)
	# It follows the sample; the gap follows the fall height and only shrinks.
	var prev_gap := INF
	var max_wobble := 0.0
	for k in 8:
		var t := t_down + 0.15 + (5.0 - t_down - 0.2) * float(k) / 7.0
		layer.set_playback_time(t)
		var s := w.sample("bomber", t, "history")
		var wp := Vector2(float(s["x"]), float(s["y"]))
		check(mk.visible, "t = %.2f: still drawn" % t)
		check(mk.position.distance_to(layer.mapping.world_to_screen(wp)) < 0.01, "t = %.2f: the marker is where the sample puts the plane" % t)
		var want: Vector2 = layer.shadow_offset_px(wp, layer.fall_height_above_ground(s), 1.0)
		check(mk.shadow_offset.distance_to(want) < 1e-6, "t = %.2f: its shadow gap is the fall height's (%.3f px)" % [t, want.length()])
		var gap: float = mk.shadow_offset.length()
		check(gap < prev_gap, "t = %.2f: the gap has closed a little more (%.3f px)" % [t, gap])
		prev_gap = gap
		check(absf(mk.wobble) <= amp + 1e-9, "t = %.2f: the rock stays inside %.1f degrees" % [t, _st.num("combat.fall.wobble_deg")])
		max_wobble = maxf(max_wobble, absf(mk.wobble))
		eq(layer.marker("fighter").wobble, 0.0, "t = %.2f: the plane under control does not rock" % t)
	check(max_wobble > amp * 0.3, "it rocks (largest %.4f of %.4f rad)" % [max_wobble, amp])
	# After the turn it is still a plane, falling: its height is the sim's fall height.
	CombatWorlds.play_out(ui)
	check(mk.visible, "after the turn it is still on the map (it has not struck the ground)")
	eq(layer.pose_of("bomber")["height_m"], u.fall_height_m, "...at the fall height the sim holds, not a band's")
	eq(mk.wobble, 0.0, "...held still while nothing plays")
	check(not ui.planner.plan_shown("bomber") and ui.planner.plan_shown("fighter"), "a down unit's plan is never drawn (a plane under control keeps its own)")
	# The turns on: visible until the crash, then gone.
	var turn_no := 1
	var crash := {}
	while turn_no < 7 and crash.is_empty():
		turn_no += 1
		var r := CombatWorlds.turn(w)
		crash = CombatWorlds.event_of(r, "crash")
		if crash.is_empty():
			layer.set_playback_time(2.5)
			check(mk.visible and layer.unit_falling("bomber"), "turn %d: still falling, still drawn" % turn_no)
			CombatWorlds.play_out(ui)
	if not check(not crash.is_empty(), "the bomber crashes within a few turns"):
		return
	var t_c := float(crash["t"])
	near(UiFate.crash_t(u), t_c, 1e-9, "the interface finds the crash time the sim reported (%.3f s into turn %d)" % [t_c, turn_no])
	check(t_c > 0.02, "the crash is not at the turn's start")
	layer.set_playback_time(0.0)
	check(mk.visible, "the crash turn, t = 0: drawn")
	layer.set_playback_time(t_c - 0.02)
	check(mk.visible, "just before the crash it is still drawn")
	var s_c := w.sample("bomber", t_c - 0.02, "history")
	check(float(s_c["height_m"]) < 3.0, "...a metre or two above the ground (%.2f m)" % float(s_c["height_m"]))
	check(mk.shadow_offset.length() < 0.1 * gap_before, "...with its shadow nearly under it (%.3f px)" % mk.shadow_offset.length())
	layer.set_playback_time(t_c)
	check(not mk.visible, "at the crash it is gone (the wreck is the effects' scar)")
	layer.set_playback_time(4.99)
	check(not mk.visible, "...for the rest of the turn")
	CombatWorlds.play_out(ui)
	check(not mk.visible, "after the turn it is gone")
	# A turn after: a wreck has no marker at any time of the turn.
	CombatWorlds.turn(w)
	layer.set_playback_time(0.0)
	check(not mk.visible, "the turn after the crash, t = 0: no marker")
	layer.set_playback_time(3.0)
	check(not mk.visible, "...nor later in it")
	CombatWorlds.play_out(ui)
	_ran["falling"] = true

# --- 5: the effects feed --------------------------------------------------------------------------------

# A fight on `seed_value` through a UnitUI whose effects layer is a recording fake: the
# victim has `pips`; turns are resolved and played until `stop` (a callable on the turn's result:
# true = stop BEFORE playing this turn out) or `max_turns`. Returns {ui, w, fake, results}.
func _fight(seed_value: int, pips: int, hide_bomber: bool, max_turns: int, stop: Callable = Callable(), fake_fx: bool = true) -> Dictionary:
	var w := CombatWorlds.world(seed_value, pips)
	var ui: UnitUI = _ui_on(w)[0]
	var fake := _FakeFx.new()
	if fake_fx:
		ui.feed.fx = fake
	if hide_bomber:
		ui.marker_layer.unit_visible = func(id: String) -> bool: return id != "bomber"
	var results: Array = []
	for i in max_turns:
		var r := CombatWorlds.turn(w)
		results.append(r)
		if stop.is_valid() and bool(stop.call(r)):
			break
		CombatWorlds.play_out(ui)
	return {"ui": ui, "w": w, "fake": fake, "results": results}

func _feed_exploded() -> void:
	var f := _fight(int(_seeds["exploded"]), 1, false, 1)
	var fake: _FakeFx = f["fake"]
	var w: World = f["w"]
	var down := CombatWorlds.event_of(f["results"][0], "down")
	var ex := fake.of("explode_midair")
	var smoke := fake.of("emit_path")
	eq(fake.calls.size(), smoke.size() + 1, "an exploded plane: smoke while it was hurt, then one blast, and nothing else (the full-health shooter makes none)")
	check(smoke.size() > 20, "the bomber at 1 of 8 pips smokes all the way to its end (%d stretches)" % smoke.size())
	for c: Dictionary in smoke:
		if c["unit"] != "bomber" or absf(float(c["frac"]) - 0.125) > 1e-9:
			fail("a smoke stretch is not the bomber's at 1/8: %s" % str(c))
			break
	near(float((smoke[smoke.size() - 1] as Dictionary)["t1"]), _game_t(1, float(down["t"])), 1e-9, "the smoke stops at the moment it is shot down (the blast takes over)")
	if check(ex.size() == 1, "explode_midair is called once"):
		var c: Dictionary = ex[0]
		check(fake.calls.find(c) > fake.calls.rfind(smoke[smoke.size() - 1]), "...after the smoke")
		eq(c["unit"], "bomber", "for the bomber")
		near(float(c["t"]), _game_t(1, float(down["t"])), 1e-9, "at the down event's game time")
		check((c["pos"] as Vector2).distance_to(Vector2(float(down["x"]), float(down["y"]))) < 0.01, "where it went down")
		near(float(c["h"]), 400.0, 1e-6, "at its height above the ground (the medium band over flat ground)")
		near(float(c["size"]), 20.0, 1e-9, "sized by the plane (a bomber's 20 m)")
		near(float(c["heading"]), float(w.sample("bomber", float(down["t"]))["heading"]), 1e-9, "heading the way it was flying")
	_ran["feed_exploded"] = true

func _feed_fall() -> void:
	var f := _fight(int(_seeds["out_of_control"]), 1, false, 7, func(r: Dictionary) -> bool: return not CombatWorlds.event_of(r, "crash").is_empty())
	var fake: _FakeFx = f["fake"]
	var ui: UnitUI = f["ui"]
	var results: Array = f["results"]
	ui.marker_layer.ground_height = func(_x: float, _y: float) -> float: return 60.0
	var crash_turn := results.size()
	var crash := CombatWorlds.event_of(results[crash_turn - 1], "crash")
	if not check(not crash.is_empty(), "the bomber crashes within a few turns (%d turns)" % crash_turn):
		return
	# The crash turn is resolved but not played: play it now (the ground height is set).
	CombatWorlds.play_out(ui)
	var down := CombatWorlds.event_of(results[0], "down")
	var falls := fake.of("falling")
	var impacts := fake.of("impact")
	check(falls.size() > 100, "falling() is called every frame of the fall (%d calls over %d turns)" % [falls.size(), crash_turn])
	near(float((falls[0] as Dictionary)["t"]), _game_t(1, float(down["t"])), 1e-9, "the first fall call is at the down event's game time")
	eq(fake.of("explode_midair").size() + fake.of("add_scar").size(), 0, "no explosion and no quiet scar")
	var prev_t := -INF
	var prev_pos := Vector2.INF
	var ok_order := true
	for c: Dictionary in falls:
		eq(c["unit"], "bomber", "only the falling plane is ridden")
		if float(c["t"]) < prev_t:
			ok_order = false
		if prev_pos.is_finite() and (c["pos"] as Vector2).distance_to(prev_pos) > 40.0:
			ok_order = false
		prev_t = float(c["t"])
		prev_pos = c["pos"]
	check(ok_order, "the fall calls run forward in game time and the plane moves smoothly from one to the next")
	check(float((falls[falls.size() - 1] as Dictionary)["h"]) < 40.0, "the last is near the ground (%.1f m)" % float((falls[falls.size() - 1] as Dictionary)["h"]))
	if check(impacts.size() == 1, "impact() is called once"):
		var im: Dictionary = impacts[0]
		near(float(im["t"]), _game_t(crash_turn, float(crash["t"])), 1e-9, "at the crash event's game time (turn %d, %.2f s)" % [crash_turn, float(crash["t"])])
		check((im["pos"] as Vector2).distance_to(Vector2(float(crash["x"]), float(crash["y"]))) < 0.01, "where it struck")
		near(float(im["size"]), 20.0, 1e-9, "sized by the plane")
		check(float((falls[falls.size() - 1] as Dictionary)["t"]) < float(im["t"]) + 1e-9, "the last frame of the fall is no later than the crash")
	var order: Array = []
	for c: Dictionary in fake.calls:
		order.append(c["call"])
	eq(order.find("impact"), order.size() - 1, "the crash is the last thing the effects were told")
	_ran["feed_fall"] = true

func _feed_damage() -> void:
	var f := _fight(int(_seeds["hit"]), 8, false, 1)
	var fake: _FakeFx = f["fake"]
	var w: World = f["w"]
	var res: Dictionary = f["results"][0]
	var hits := CombatWorlds.events_of(res, "hit")
	var paths := fake.of("emit_path").filter(func(c: Dictionary) -> bool: return c["unit"] == "bomber")
	if not check(not paths.is_empty() and not hits.is_empty(), "a damaged plane leaves smoke along its path (%d stretches after %d hits)" % [paths.size(), hits.size()]):
		return
	eq(fake.of("emit_path").size(), paths.size(), "...and only the damaged one does (the full-health shooter makes none)")
	near(float((paths[0] as Dictionary)["t0"]), _game_t(1, float((hits[0] as Dictionary)["t"])), 1e-9, "the smoke starts at the first hit's game time")
	near(float((paths[paths.size() - 1] as Dictionary)["t1"]), 5.0, 1e-9, "...and runs to the turn's end")
	var prev_frac := 1.0
	for i in paths.size():
		var p: Dictionary = paths[i]
		if i > 0:
			near(float(p["t0"]), float((paths[i - 1] as Dictionary)["t1"]), 1e-9, "stretch %d begins where the last ended" % i)
		# The health fraction shown at that moment: the pips left after the last hit at or before it.
		var left := 8
		for h: Dictionary in hits:
			if _game_t(1, float(h["t"])) <= float(p["t0"]) + 1e-9:
				left = int(h["health"])
		near(float(p["frac"]), float(left) / 8.0, 1e-9, "stretch %d: the health fraction is the pips left at that moment (%d of 8)" % [i, left])
		check(float(p["frac"]) <= prev_frac + 1e-9 and float(p["frac"]) > 0.0 and float(p["frac"]) < 1.0, "stretch %d: damaged, not dead, and never healing" % i)
		prev_frac = float(p["frac"])
		near(float(p["size"]), 20.0, 1e-9, "stretch %d: sized by the plane" % i)
	# What the layer's sampler is given: the path from World.sample, the height above the ground.
	var p0: Dictionary = paths[0]
	var s0 := w.sample("bomber", float(p0["t0"]), "history")
	near(float((p0["first"] as Dictionary)["x"]), float(s0["x"]), 1e-9, "the sampler gives the sample's x")
	near(float((p0["first"] as Dictionary)["height_m"]), 400.0, 1e-6, "...the height above the ground")
	near(float((p0["first"] as Dictionary)["heading"]), float(s0["heading"]), 1e-9, "...and the heading")
	_ran["feed_damage"] = true

func _feed_fog() -> void:
	# A plane the player cannot see leaves no smoke and no blast; its wreck still goes down.
	var f := _fight(int(_seeds["exploded"]), 1, true, 1)
	eq((f["fake"] as _FakeFx).calls.size(), 0, "exploded out of sight: nothing for the effects")
	f = _fight(int(_seeds["hit"]), 8, true, 1)
	eq((f["fake"] as _FakeFx).calls.size(), 0, "damaged out of sight: no smoke")
	f = _fight(int(_seeds["out_of_control"]), 1, true, 7, func(r: Dictionary) -> bool: return not CombatWorlds.event_of(r, "crash").is_empty())
	CombatWorlds.play_out(f["ui"])
	var fake: _FakeFx = f["fake"]
	eq(fake.calls.size(), 1, "out of control and crashed out of sight: one call")
	var sc := fake.of("add_scar")
	if check(sc.size() == 1, "...the scar alone"):
		var res_list: Array = f["results"]
		var crash := CombatWorlds.event_of(res_list[res_list.size() - 1], "crash")
		check((sc[0]["pos"] as Vector2).distance_to(Vector2(float(crash["x"]), float(crash["y"]))) < 0.01, "...where it struck")
	# The data can say otherwise.
	_st.ui["combat"]["fx"]["smoke_when_hidden"] = true
	f = _fight(int(_seeds["exploded"]), 1, true, 1)
	eq((f["fake"] as _FakeFx).of("explode_midair").size(), 1, "combat.fx.smoke_when_hidden true: the blast shows")
	_st.ui["combat"]["fx"]["smoke_when_hidden"] = false
	_ran["feed_fog"] = true

# --- 6: the ink on a hit --------------------------------------------------------------------------------

func _hit_ink() -> void:
	var w := CombatWorlds.world(int(_seeds["hit"]), 8)
	var ui: UnitUI = _ui_on(w)[0]
	var layer = ui.marker_layer
	var hm = ui.hit_marks
	var res := CombatWorlds.turn(w)
	var hits := CombatWorlds.events_of(res, "hit")
	var t_h := float((hits[0] as Dictionary)["t"])
	eq(hm.marks.size(), 0, "no ink before a hit")
	while layer.playback_t < t_h - 0.05:
		CombatWorlds.step(ui, 1.0 / 60.0)
	eq(hm.marks.size(), 0, "none just before the first hit (%.2f s)" % t_h)
	while layer.playback_t < t_h + 0.02:
		CombatWorlds.step(ui, 1.0 / 60.0)
	if not check(hm.marks.size() >= 1, "the ink appears as the hit event passes the playback clock"):
		return
	var m: Dictionary = hm.marks[0]
	eq(m["unit"], "bomber", "on the unit that was hit")
	near(float(m["t"]), _game_t(1, t_h), 1e-9, "at the hit's game time")
	# FAST FLASH, VERY SLOW DECAY.
	var flash_s: float = _st.num("combat.hit_mark.flash_s")
	var life: float = _st.num("combat.hit_mark.life_s")
	near(HitMarks.ink_alpha(0.0, _st), 1.0, 1e-12, "the ink is at full strength at once")
	near(HitMarks.flash_alpha(0.0, _st), 1.0, 1e-12, "...with a full flash of paper")
	near(HitMarks.flash_alpha(flash_s, _st), 0.0, 1e-12, "the flash is gone in %.2f s" % flash_s)
	check(HitMarks.ink_alpha(flash_s, _st) > 0.85, "...by when the ink has hardly faded (%.3f)" % HitMarks.ink_alpha(flash_s, _st))
	var mid := HitMarks.ink_alpha(life * 0.5, _st)
	check(mid > 0.3 and mid < 0.7, "half way through its life it is half there (%.3f)" % mid)
	near(HitMarks.ink_alpha(life, _st), 0.0, 1e-12, "and gone at %.1f s" % life)
	eq(HitMarks.ink_alpha(-0.1, _st), 0.0, "nothing before the hit")
	var mono := true
	var prev := 2.0
	for i in 41:
		var a := HitMarks.ink_alpha(life * float(i) / 40.0, _st)
		if a > prev + 1e-12:
			mono = false
		prev = a
	check(mono, "the decay never brightens")
	check(life > 5.0 * flash_s, "very slow against the flash (%.1f s against %.2f s)" % [life, flash_s])
	# Where it is: on the plane, riding with it.
	var mk = layer.marker("bomber")
	var g: Dictionary = hm.mark_geometry(m)
	if check(not g.is_empty(), "the mark has a place on the drawn plane"):
		check((g["centre"] as Vector2).distance_to(mk.position) <= _st.num("combat.hit_mark.spot_k") * mk.radius_px() + 1e-6, "inside the plane's radius, %.2f px from its centre" % (g["centre"] as Vector2).distance_to(mk.position))
		check(float(g["radius"]) >= _st.num("combat.hit_mark.min_radius_px") and float(g["radius"]) <= _st.num("combat.hit_mark.max_radius_px"), "a sensible size (%.1f px)" % float(g["radius"]))
		var rel1: Vector2 = ((g["centre"] as Vector2) - mk.position).rotated(-mk.screen_heading)
		var p1: Vector2 = mk.position
		for i in 30:
			CombatWorlds.step(ui, 1.0 / 60.0)
		var g2: Dictionary = hm.mark_geometry(m)
		var rel2: Vector2 = ((g2["centre"] as Vector2) - mk.position).rotated(-mk.screen_heading)
		check(rel1.distance_to(rel2) < 1e-3, "it keeps its place in the plane's own frame")
		check(mk.position.distance_to(p1) > 20.0, "...so it travels with the plane (%.0f px in half a second)" % mk.position.distance_to(p1))
		layer.unit_visible = func(id: String) -> bool: return id != "bomber"
		layer.update_poses()
		check(hm.mark_geometry(m).is_empty(), "a unit out of sight shows no ink")
		layer.unit_visible = Callable()
		layer.update_poses()
	# The turn ends: the ink goes on fading in real time, and is gone at its life's end.
	CombatWorlds.play_out(ui)
	check(not layer.is_playing() and hm.marks.size() >= 1, "after the turn the ink is still there")
	var last: Dictionary = hm.marks[hm.marks.size() - 1]
	var left: float = life - (hm.clock - float(last["t"]))
	check(left > 0.0, "...with %.2f s of its life left" % left)
	hm._process(left * 0.5)
	check(hm.marks.size() >= 1, "half that later it is still there")
	hm._process(left * 0.6 + 1.0)
	eq(hm.marks.size(), 0, "past its life it is gone")
	# A new turn clears what is left; the data switch turns the ink off.
	hm.add_hit("bomber", hm.clock, 1)
	check(hm.marks.size() >= 1, "a hit adds a mark")
	CombatWorlds.turn(w)
	eq(hm.marks.size(), 0, "a new playback clears what was left of the turn before")
	CombatWorlds.play_out(ui)
	_st.ui["combat"]["hit_mark"]["enabled"] = false
	hm.clear()
	hm.add_hit("bomber", 9.0, 1)
	eq(hm.marks.size(), 0, "combat.hit_mark.enabled false: no ink")
	_st.ui["combat"]["hit_mark"]["enabled"] = true
	# Tracers: off by default; switched on, a miss runs on past the target.
	check(not _st.flag("combat.tracers.enabled"), "tracers are off in the data")
	hm.add_shot({"x": 0.0, "y": 0.0, "tx": 100.0, "ty": 0.0, "hit": true}, 1.0)
	eq(hm.tracers.size(), 0, "...so a shot leaves none")
	_st.ui["combat"]["tracers"]["enabled"] = true
	hm.add_shot({"x": 0.0, "y": 0.0, "tx": 100.0, "ty": 0.0, "hit": true}, 1.0)
	hm.add_shot({"x": 0.0, "y": 0.0, "tx": 100.0, "ty": 0.0, "hit": false}, 1.0)
	eq(hm.tracers.size(), 2, "switched on, a shot leaves a tracer")
	check((hm.tracers[0]["b"] as Vector2).is_equal_approx(Vector2(100.0, 0.0)), "a hit's runs to the target")
	check((hm.tracers[1]["b"] as Vector2).x > 120.0, "a miss runs on past it (%.0f m)" % (hm.tracers[1]["b"] as Vector2).x)
	_st.ui["combat"]["tracers"]["enabled"] = false
	_ran["hit_ink"] = true

# --- 7: a client that joins late ----------------------------------------------------------------------

func _late_joiner() -> void:
	var f := _fight(int(_seeds["out_of_control"]), 1, false, 7, func(r: Dictionary) -> bool: return not CombatWorlds.event_of(r, "crash").is_empty(), false)
	var ui1: UnitUI = f["ui"]
	var w: World = f["w"]
	var u: Unit = w.units["bomber"]
	# The crash turn is resolved and playing: this turn's wreck is still to come as an event.
	eq(ui1.restore_wrecks(), 0, "during the crash turn's playback only the wrecks of earlier turns are put back")
	CombatWorlds.play_out(ui1)
	eq(ui1.fx.field.scars.size(), 1, "the live crash left its scar")
	eq(ui1.restore_wrecks(), 0, "...and a restore does not double it")
	var ui2: UnitUI = _ui_on(w)[0]
	eq(ui2.fx.field.scars.size(), 1, "a client that joins after the crash finds the wreck on the ground")
	var sc: Dictionary = ui2.fx.field.scars[0]
	eq(sc["unit"], "bomber", "its scar")
	check((sc["pos"] as Vector2).distance_to(Vector2(u.x, u.y)) < 0.01, "at the wreck")
	near(ui2.fx.field.scar_alpha(sc, ui2.game_time()), 1.0, 1e-9, "settled: black already, its embers long out")
	eq(ui2.restore_wrecks(), 0, "a second restore changes nothing")
	eq(ui2.restore_wrecks(true), 1, "a rebuild (clear = true) puts it back")
	eq(ui2.fx.field.scars.size(), 1, "...once")
	var ui3: UnitUI = _ui_on(w)[0]
	eq(ui3.fx.field.scars[0]["seed"], ui2.fx.field.scars[0]["seed"], "the same wreck looks the same on every peer (its seed is the unit's)")
	# An exploded plane leaves no wreck to restore.
	var wx := CombatWorlds.world(int(_seeds["exploded"]))
	var uix: UnitUI = _ui_on(wx)[0]
	CombatWorlds.turn(wx)
	CombatWorlds.play_out(uix)
	var uiy: UnitUI = _ui_on(wx)[0]
	eq(uiy.fx.field.scars.size(), 0, "an exploded plane leaves no scar to restore")
	_ran["late_joiner"] = true

# --- 8: the real frames ---------------------------------------------------------------------------------

func _frames() -> void:
	var w := CombatWorlds.world(int(_seeds["hit"]), 8)
	var ui: UnitUI = _ui_on(w)[0]
	_st.set_num("marker.true_scale", 2.0)
	CombatWorlds.turn(w)
	var n := 0
	while ui.marker_layer.is_playing() and n < 700:
		await get_tree().process_frame
		n += 1
	check(n > 200 and n < 700, "the playback ran in real frames (%d)" % n)
	for i in 3:
		await get_tree().process_frame
	check(ui.hit_marks.draw_count > 0, "the hit marks drew (%d frames)" % ui.hit_marks.draw_count)
	eq(ui.hit_marks.failed_draws, 0, "...to the end every time")
	eq(ui.cones.failed_draws, 0, "the cone overlay drew whole")
	eq(ui.trails.failed_draws, 0, "the trails drew whole")
	near(ui.fx.true_scale, 2.0, 1e-9, "the effects layer has the drawn scale, set from the style each frame")
	near(ui.fx.now, ui.game_time(), 1e-9, "...and the game time (the start of turn 2 once the turn is over: %.2f s)" % ui.game_time())
	near(ui.game_time(), 5.0, 1e-9, "game time is (turn - 1) x 5 s: the end of turn 1 is the start of turn 2")
	_st.set_num("marker.true_scale", float(_saved["k"]))
	_ran["frames"] = true

# --- 3b: the line ahead of a plane ----------------------------------------------------------------------

func _ahead() -> void:
	var w := CombatWorlds.world(int(_seeds["exploded"]))
	var ui: UnitUI = _ui_on(w)[0]
	var layer = ui.marker_layer
	var res := CombatWorlds.turn(w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	var step_px: float = _st.num("marker.trail_dt_s") * 85.0 * PPM
	layer.set_playback_time(0.2)
	var fighter_rest: PackedVector2Array = layer.track_points("fighter")["rest"]
	var last_f: Dictionary = w.units["fighter"].history[w.units["fighter"].history.size() - 1]
	if check(fighter_rest.size() > 10, "a plane under control has its dashed line ahead to the turn's end"):
		check(fighter_rest[fighter_rest.size() - 1].distance_to(_xf * Vector2(float(last_f["x"]), float(last_f["y"]))) < 0.5, "...which ends where the turn takes it")
	var rest: PackedVector2Array = layer.track_points("bomber")["rest"]
	var full: Dictionary = w.units["bomber"].history[w.units["bomber"].history.size() - 1]
	if check(rest.size() > 3, "the plane about to explode has a line ahead"):
		check(rest[rest.size() - 1].distance_to(_xf * Vector2(float(down["x"]), float(down["y"]))) <= step_px + 0.5, "...only up to the moment it goes down (not the phantom path beyond it)")
		check(rest[rest.size() - 1].distance_to(_xf * Vector2(float(full["x"]), float(full["y"]))) > 20.0, "...not to where its motion would have ended the turn")
	layer.set_playback_time(t_down + 0.3)
	check((layer.track_points("bomber")["rest"] as PackedVector2Array).is_empty(), "a unit that has gone down has none")
	# Whose: the players' own planes; the enemy's plan is never shown.
	layer.set_playback_time(0.2)
	layer.marker("fighter").own = false
	check((layer.track_points("fighter")["rest"] as PackedVector2Array).is_empty(), "marker.ahead_line.applies_to own: another side's plane has no line ahead")
	_st.ui["marker"]["ahead_line"]["applies_to"] = "all"
	check(not (layer.track_points("fighter")["rest"] as PackedVector2Array).is_empty(), "...'all' draws it as it was")
	_st.ui["marker"]["ahead_line"]["applies_to"] = "own"
	layer.marker("fighter").own = true
	# A fall is not previewed either.
	var w2 := CombatWorlds.world(int(_seeds["out_of_control"]))
	var ui2: UnitUI = _ui_on(w2)[0]
	var res2 := CombatWorlds.turn(w2)
	var down2 := CombatWorlds.event_of(res2, "down")
	var l2 = ui2.marker_layer
	l2.set_playback_time(0.2)
	var r2: PackedVector2Array = l2.track_points("bomber")["rest"]
	if check(r2.size() > 3, "the plane about to lose control has a line ahead"):
		check(r2[r2.size() - 1].distance_to(_xf * Vector2(float(down2["x"]), float(down2["y"]))) <= step_px + 0.5, "...which stops where it will lose control, not along the fall")
	l2.set_playback_time(float(down2["t"]) + 0.3)
	check((l2.track_points("bomber")["rest"] as PackedVector2Array).is_empty(), "falling, it has none")
	_ran["ahead"] = true
