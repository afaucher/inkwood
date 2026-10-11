extends "res://scripts/test_support/test_case.gd"

# A BOMB'S TARGET LOST IN THE FOG (decision lost-target-last-seen, 2026-10-11). The lead asked "should bombs aim at the last place you saw any lost target?";
# ALEX: "1. We should do last place for fog. Keep trees as they are for now." So a bomb that follows a unit is aimed at the last place the bombing side SAW it,
# with no lead, when the unit is out of the side's SIGHT at the release (the sight circles of the side's units, cut by the line of sight where it is on:
# Spotting.in_sight_of); a unit hidden in WOODS but inside a sight circle is still followed, as built; smoke is decision forest-fire's (test_fire_track).
# The enemy AI's bombs go through the same rule, by side. The place the planning player last saw it is the fallback when it was not seen at all in the turn
# before the release (PROPOSED: data/sim/bombs.json lost_target_fallback).
#
#   1. IN SIGHT ALL ALONG   a followed tank a lookout of the bomber's side sees throughout: the aim is its place at the release plus the lead, as ever
#   2. OUT OF SIGHT         a tank that drives out of every sight circle of the side before the release: the aim is where it was last in one, no lead
#   3. THE SWITCH           lost_target_mode "followed" is the old rule: the tank is followed wherever it goes
#   4. NEVER SEEN           a tank no unit of the side sees this turn: the aim is the one the drop was planned with (PROPOSED); "turn_start": where it stood at the start
#   5. WOODS                a tank in a grove, 300 m from a lookout (outside the 200 m woods radius, inside its sight circle): still followed
#   6. THE LINE OF SIGHT    where the line of sight is on (the spotting seam) and blocks the lookout's view, the tank is lost
#   7. THE ENEMY AI         a bomber of the AI's side, a tank of the players': the same rules by side
#
# Headless, on the real World; positions are the test's own, expected values are computed from the histories and the sight radii, not from the rule under test.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const FireFakes = preload("res://scripts/test_support/fire_fakes.gd")
const FireTrees = preload("res://scripts/sim/fire_trees.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")

const SEED := 20261009
const START := Vector2(2500.0, 2500.0)     # where the tank stands at the start of the turn
const SPEED := 8.0                          # the tank's speed, m/s, east
const BOMBER_SPEED := 85.0
const LOOKOUT_SIGHT := 500.0                # radio_tower sight_range_m
const BOMBER_SIGHT := 650.0                 # bomber sight_range_m

func setup(_main) -> void:
	timeout_seconds = 240.0
	for part: Script in [World, Bombs, BombRules, BombWorlds, FireFakes, FireTrees, GroundMap, ConcealRules]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	var rules := BombRules.new()
	check(rules.ok() and rules.lost_target_mode == "last_seen" and rules.lost_target_fallback == "planning_aim", "0. data/sim/bombs.json: lost_target_mode last_seen (Alex), the fallback planning_aim (PROPOSED): %s" % str(rules.errors))
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BombRules.PATH))
	eq(str((raw["lost_target_mode"] as Dictionary).get("decision", "")), "lost-target-last-seen", "0. the mode names Alex's decision")
	check(bool((raw["lost_target_fallback"] as Dictionary).get("_proposed", false)), "0. and the fallback is labelled PROPOSED")
	var bad: Dictionary = raw.duplicate(true)
	((bad["lost_target_mode"] as Dictionary))["value"] = "forgotten"
	check(not BombRules.new(bad, true).ok(), "0. a mode the code does not know is an error")
	eq(_in_sight_all_along(), true, "1. the in-sight part ran to its end")
	eq(_out_of_sight(), true, "2-3. the out-of-sight part ran to its end")
	eq(_never_seen(), true, "4. the never-seen part ran to its end")
	eq(_woods(), true, "5. the woods part ran to its end")
	eq(_line_of_sight(), true, "6. the line-of-sight part ran to its end")
	eq(_enemy_ai(), true, "7. the AI part ran to its end")
	finish()

# --- A scene ------------------------------------------------------------------------------------------------------------

# A bomber of `bomber_side` lined up so that the ideal aim of its step `k` is `lead` m east of the tank's start; a tank of `tank_side` at `at` driving east at
# SPEED; lookouts: [{pos: Vector2, side: String}] static radio towers (sight 500 m). `gm`: give the World the ground (woods, for concealment).
func _scene(bomber_side: String, tank_side: String, lookouts: Array, lead: float, at: Vector2 = START, gm: RefCounted = null, k: int = 0) -> World:
	var w := World.new()
	w.quiet = true
	w.rng_seed = 5
	if gm != null:
		gm.attach(w)
	w.add_player("local")
	var bomber_ctl := "player" if bomber_side == "allies" else "ai"
	var tank_ctl := "player" if tank_side == "allies" else "ai"
	w.add_unit({"id": "bomber", "type": "bomber", "side": bomber_side, "controller": bomber_ctl, "x": 0.0, "y": at.y, "heading": 0.0, "altitude_band": "medium", "speed": BOMBER_SPEED})
	w.add_unit({"id": "tank", "type": "tank", "side": tank_side, "controller": tank_ctl, "x": at.x, "y": at.y, "heading": 0.0, "speed": SPEED})
	var n := 0
	for l: Dictionary in lookouts:
		n += 1
		w.add_unit({"id": "lookout%d" % n, "type": "radio_tower", "side": str(l["side"]), "controller": "player" if str(l["side"]) == "allies" else "ai", "x": (l["pos"] as Vector2).x, "y": (l["pos"] as Vector2).y, "heading": 0.0})
	var b: Unit = w.units["bomber"]
	b.x = at.x + lead - BOMBER_SPEED * (float(k) + 0.5) * w.step_dt("bomber") - Bombs.ideal_range(BOMBER_SPEED, w.band_height("medium"), w.bombs.gravity)
	return w

# Plan the bomber's drop on the tank, aimed at `planned` (where the planning player saw it, or thought to), ready every participant and resolve; the stick's release.
func _release(w: World, planned: Vector2, k: int = 0) -> Dictionary:
	var st := w.plan_step("bomber", k, {"drop": {"aim": [planned.x, planned.y], "target": {"unit": "tank"}}})
	if not check(not st.is_empty(), "the drop on the tank is planned: %s" % w.last_error):
		return {}
	for p: String in w.participants():
		w.commit(p)
	var res := w.resolve()
	var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
	if not check(rel.size() == 1, "one stick was released (%d): %s" % [rel.size(), w.last_error]):
		return {}
	return rel[0]

func _aim(ev: Dictionary) -> Vector2:
	return Vector2(float((ev["aim"] as Array)[0]), float((ev["aim"] as Array)[1]))

# The aim of a FOLLOWED unit at the release: its place plus its velocity x the fall time of the stick (bombs.gd followed_aim, spelled out).
func _led(w: World, ev: Dictionary) -> Vector2:
	var p := w.sample("tank", float(ev["t"]), "history")
	var lead := float(p["speed"]) * float(ev["fall_s"])
	return Vector2(float(p["x"]) + cos(float(p["heading"])) * lead, float(p["y"]) + sin(float(p["heading"])) * lead)

func _place(w: World, t: float) -> Vector2:
	var p := w.sample("tank", t, "history")
	return Vector2(float(p["x"]), float(p["y"]))

# The last moment (to a millisecond) at or before `until` at which the tank is inside the sight circle of a unit of `side` (bomber 650 m, lookouts 500 m),
# straight from the histories; -1 if never.
func _last_in_circle(w: World, side: String, until: float) -> float:
	var last := -1.0
	var t := 0.0
	while t <= until + 1e-9:
		var tp := _place(w, t)
		for id: String in w.units:
			var o: Unit = w.units[id]
			if o.side != side or id == "tank":
				continue
			var op := w.sample(id, t, "history")
			if tp.distance_to(Vector2(float(op["x"]), float(op["y"]))) <= float(o.def.sight_range_m):
				last = t
		t += 0.001
	return last

# --- 1. In sight all along ------------------------------------------------------------------------------------------------

func _in_sight_all_along() -> bool:
	var near_lookout := {"pos": START + Vector2(60.0, 120.0), "side": "allies"}
	var w := _scene("allies", "axis", [near_lookout], 80.0)
	var ev := _release(w, START)
	if ev.is_empty():
		return false
	eq(ev.get("followed"), true, "1. the release says it followed a unit")
	var t_rel := float(ev["t"])
	check(_last_in_circle(w, "allies", t_rel) >= t_rel - 0.002, "1. (the tank is in a sight circle of the bomber's side at the release, %.3f s)" % t_rel)
	var want := _led(w, ev)
	check(_aim(ev).distance_to(want) < 0.5, "1. in sight all along it is followed: the aim is its place at the release plus the lead %s (aim %s)" % [str(want), str(_aim(ev))])
	check(want.x - START.x > 60.0, "1. (which is %.0f m ahead of where it stood)" % (want.x - START.x))
	return true

# --- 2 and 3. Out of sight, and the switch ---------------------------------------------------------------------------------

# The drop is on the bomber's SECOND step (its window runs from 1.67 s to 3.33 s), a lookout stands 500 m west of the tank's start, so that the tank drives out
# of its circle at 0.8 s -- before the window opens; the bomber, 700 m behind, never sees it. The best release is therefore a moment the tank is lost (a drop on
# the first step would be released while it is still in sight: a release moment is chosen for the aim, and the aim is the led one while it is tracked).
func _out_of_sight() -> bool:
	var lookout_x := START.x + SPEED * 0.8 - LOOKOUT_SIGHT
	var ideal := 49.0   # halfway between the last place it is seen (about +6) and the led aim at the release (about +92): both inside the cone
	var w := _scene("allies", "axis", [{"pos": Vector2(lookout_x, START.y), "side": "allies"}], ideal, START, null, 1)
	var ev := _release(w, START, 1)
	if ev.is_empty():
		return false
	var t_rel := float(ev["t"])
	var last := _last_in_circle(w, "allies", t_rel)
	print("[test] out of sight: released %.3f s in; the tank last in a sight circle at %.3f s; poor shot: %s" % [t_rel, last, str(ev.get("poor_shot", false))])
	check(t_rel > 1.6 and last >= 0.0 and last < t_rel - 0.5, "2. the tank was last in a sight circle at %.3f s and the stick is released at %.3f s: it had left every circle by then" % [last, t_rel])
	var seen_at := _place(w, last)
	var aim := _aim(ev)
	check(aim.distance_to(seen_at) < 0.5, "2. the bomb is aimed at the last place it was seen %s, with no lead: aim %s" % [str(seen_at), str(aim)])
	check(_led(w, ev).distance_to(aim) > 40.0, "2. which is %.0f m short of where it would have been aimed had it been followed" % _led(w, ev).distance_to(aim))
	check(seen_at.distance_to(START) > 3.0, "2. (and not the place it stood at the start of the turn, %.1f m behind)" % seen_at.distance_to(START))
	eq(ev.get("followed"), true, "2. the release still says it followed a unit (it is the unit's drop)")
	# 3. the switch: the old rule, a unit target is followed wherever it goes
	var w3 := _scene("allies", "axis", [{"pos": Vector2(lookout_x, START.y), "side": "allies"}], ideal, START, null, 1)
	w3.bombs.lost_target_mode = "followed"
	var ev3 := _release(w3, START, 1)
	if not ev3.is_empty():
		check(_aim(ev3).distance_to(seen_at) > 20.0, "3. with lost_target_mode \"followed\" the tank is followed out of sight: the aim is %.0f m from the last place it was seen" % _aim(ev3).distance_to(seen_at))
		if not bool(ev3.get("poor_shot", false)):
			check(_aim(ev3).distance_to(_led(w3, ev3)) < 0.5, "3. namely its place at the release plus the lead")
	return true

# --- 4. Never seen ----------------------------------------------------------------------------------------------------------

func _never_seen() -> bool:
	# no lookout: the lone bomber is 700 m from the tank at the release and sees 650. Planned at a place 40 m beyond where the tank stands (to tell the aim
	# the drop was set with from where the tank stood), ideal aim 40 m ahead of it.
	var planned := START + Vector2(40.0, 0.0)
	var w := _scene("allies", "axis", [], 40.0)
	var ev := _release(w, planned)
	if ev.is_empty():
		return false
	check(_last_in_circle(w, "allies", float(ev["t"])) < 0.0, "4. (the tank is in no sight circle of the bomber's side before the release)")
	check(_aim(ev).distance_to(planned) < 0.5, "4. never seen this turn: the bomb goes to where the planning player last saw it, the aim the drop was set with %s: %s" % [str(planned), str(_aim(ev))])
	check(not bool(ev.get("poor_shot", false)), "4. (a fair shot, not a poor one)")
	var w2 := _scene("allies", "axis", [], 40.0)
	w2.bombs.lost_target_fallback = "turn_start"
	var ev2 := _release(w2, planned)
	if not ev2.is_empty():
		check(_aim(ev2).distance_to(START) < 0.5, "4. (lost_target_fallback \"turn_start\": where the tank stood at the start of the turn): %s" % str(_aim(ev2)))
	return true

# --- 5. Woods ---------------------------------------------------------------------------------------------------------------

func _woods() -> bool:
	var water: RefCounted = WaterGen.shared(SEED)
	var gm: RefCounted = GroundMap.shared(SEED, water)
	var src := FireTrees.new(gm.terrain)
	var g := FireFakes.grove_point(gm, src, WorldLayout.shared(SEED).sites()["radio_tower"])
	if not check(g != Vector2.INF, "5. a grove was found (%.0f, %.0f)" % [g.x, g.y]):
		return false
	var rule: RefCounted = ConcealRules.shared()
	# a lookout 300 m from the grove: outside the 200 m woods radius, inside its own 500 m sight circle
	var lookout := g + Vector2(-250.0, 165.0)
	check(lookout.distance_to(g) > rule.radius_m + 50.0 and lookout.distance_to(g) < LOOKOUT_SIGHT - 100.0, "5. (the lookout is %.0f m from the tank: beyond the woods radius %.0f m, inside its sight)" % [lookout.distance_to(g), rule.radius_m])
	var w := _scene("allies", "axis", [{"pos": lookout, "side": "allies"}], 40.0, g, gm)
	var tank: Unit = w.units["tank"]
	check(rule.covered(w, tank, g.x, g.y), "5. the tank is in cover: woods (density %.2f)" % float(gm.woods_at(g.x, g.y)))
	check(not w.spotted_now("allies", {"unit": "tank"}), "5. and the lookout, at %.0f m, does not SPOT it (the woods hide it beyond 200 m: shared spotting is as built)" % lookout.distance_to(g))
	check(w.spotting.in_sight_of(w, "allies", {"unit": "tank"}, w.spotting.frame_at(w, -1.0)), "5. though it is inside the lookout's sight circle (Spotting.in_sight_of does not ask the woods)")
	var planned := g
	var ev := _release(w, planned)
	if ev.is_empty():
		return false
	var want := _led(w, ev)
	var moved := _place(w, float(ev["t"])).distance_to(g)
	print("[test] woods: the tank moved %.1f m by the release (%.3f s), led aim %.1f m from where it stood" % [moved, float(ev["t"]), want.distance_to(g)])
	check(want.distance_to(g) > 10.0, "5. (the led aim is %.1f m from where it stood, so followed and last-seen can be told apart)" % want.distance_to(g))
	check(_aim(ev).distance_to(want) < 0.5, "5. a tank in woods but inside a sight circle is still followed: the aim is its place plus the lead %s (aim %s)" % [str(want), str(_aim(ev))])
	return true

# --- 6. The line of sight ---------------------------------------------------------------------------------------------------

func _line_of_sight() -> bool:
	# a lookout 100 m from the tank (the tank is in its circle all along) and a line of sight that is blocked east of x = START.x + 3 -- a ridge
	var w := _scene("allies", "axis", [{"pos": START + Vector2(60.0, 120.0), "side": "allies"}], 49.0, START, null, 1)
	var ridge_x := START.x + SPEED * 0.8
	w.set_sight_los(func(_eye: Dictionary, tgt: Dictionary) -> bool: return float(tgt["x"]) <= ridge_x)
	var ev := _release(w, START, 1)
	if ev.is_empty():
		return false
	var t_rel := float(ev["t"])
	check(_place(w, t_rel).x > ridge_x + 1.0, "6. (at the release the tank is behind the ridge: x = %.2f)" % _place(w, t_rel).x)
	var t_ridge := 0.0
	while _place(w, t_ridge).x <= ridge_x and t_ridge < 5.0:
		t_ridge += 0.001
	var seen_at := _place(w, t_ridge - 0.001)
	check(_aim(ev).distance_to(seen_at) < 0.5, "6. lost to the line of sight, the bomb goes where it was last in view (x = %.2f): %s" % [ridge_x, str(_aim(ev))])
	# without the seam's blocking it is followed
	var w2 := _scene("allies", "axis", [{"pos": START + Vector2(60.0, 120.0), "side": "allies"}], 49.0, START, null, 1)
	var ev2 := _release(w2, START, 1)
	if not ev2.is_empty() and not bool(ev2.get("poor_shot", false)):
		check(_aim(ev2).distance_to(_led(w2, ev2)) < 0.5, "6. (with a clear line it is followed)")
	return true

# --- 7. The enemy AI ---------------------------------------------------------------------------------------------------------

func _enemy_ai() -> bool:
	# the bomber is the AI's (axis), the tank the players' (allies); the AI side's lookout sees it all along: followed
	var wa := _scene("axis", "allies", [{"pos": START + Vector2(60.0, 120.0), "side": "axis"}], 80.0)
	var eva := _release(wa, START)
	if eva.is_empty():
		return false
	check(_aim(eva).distance_to(_led(wa, eva)) < 0.5, "7. an AI bomber whose side sees the players' tank follows it")
	# a lookout of the PLAYERS' side sees it, the AI side's nobody: for the AI's bomb it is lost, never seen -> the planned aim
	var planned := START + Vector2(40.0, 0.0)
	var wb := _scene("axis", "allies", [{"pos": START + Vector2(60.0, 120.0), "side": "allies"}], 40.0)
	var evb := _release(wb, planned)
	if not evb.is_empty():
		check(_aim(evb).distance_to(planned) < 0.5, "7. the players' own lookout does not count for the AI's bomb: it aims at the place it was planned for %s: %s" % [str(planned), str(_aim(evb))])
	return true
