extends "res://scripts/test_support/test_case.gd"

# SMOKE IS VISIBLE BUT UNTRACKABLE (decision forest-fire, 2026-10-11). The lead asked "hidden, or visible but not trackable?" and "a bomb whose target goes into the
# smoke: still followed, or aimed at its last-seen place?"; ALEX: "1 visible but untrackable and 2 last place you saw it". So smoke is NOT cover: a ground or sea unit
# in the smoke of a burning tree (within 20 m of its canopy: PROPOSED) is seen exactly as it would be without smoke, but it cannot be TRACKED --
#
#   1. STILL SEEN            the player's fog still shows it, the enemy AI still knows it, shared spotting still lists the units that see it, the woods radius is the same;
#                            planes are not denied, a point is not a unit, a static unit in smoke is denied as a mobile one is (PROPOSED)
#   2. NOT SPOTTED           for fire control (the cruiser's guns): the special cannot be switched on at a unit in smoke ("unspotted", with visible and in_smoke said), and a
#                            salvo already set at a unit that is in smoke at the moment of fire is a POOR SHOT (data/sim/guns.json gun_unspotted_mode) at the last place it was
#                            tracked -- where it entered the smoke -- no lead; with no smoke the same salvo is a normal shot
#   3. BOMBS                 a bomb that follows a tank which drives into smoke aims where it entered, no lead (Alex: "last place you saw it"); a tank that has left the
#                            smoke by the release is followed normally (PROPOSED)
#   4. THE CLICK             a click on an enemy that is in smoke at the planning moment sets a POINT target at its shown place, left or right button (PROPOSED reading of Alex:
#                            it "won't be able to target it directly in a way that tracks it if it moves"); a unit target set before it went into the smoke stays one
#
# Headless; the fire is made by hand (FireFakes), so every distance is the test's own.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const FireFakes = preload("res://scripts/test_support/fire_fakes.gd")
const FireState = preload("res://scripts/sim/fire.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const AiSense = preload("res://scripts/sim/ai_sense.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiTarget = preload("res://scripts/ui/ui_target.gd")
const FireTrees = preload("res://scripts/sim/fire_trees.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")

const SEED := 20261009
const PPM := 0.5
const ORIGIN := Vector2(1300.0, 1900.0)

var _w: World
var _ui: UnitUI
var _xf: Transform2D

func setup(_main) -> void:
	timeout_seconds = 180.0
	for part: Script in [World, Bombs, FireFakes, BombWorlds, GunWorlds, FogVision, AiSense, ConcealRules, UnitUI, UiTarget, FireTrees, GroundMap]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	eq(_still_seen(), true, "1. the still-seen part ran to its end")
	eq(_guns(), true, "2. the guns part ran to its end")
	eq(_bombs(), true, "3. the bombs part ran to its end")
	eq(_clicks(), true, "4. the click part ran to its end")
	finish()

# --- 1. Still seen --------------------------------------------------------------------------------------------------------

# A plane `gap` m west of a tank, in a World with a fire that has one burning tree at the tank (lit at the start of turn 1) when `smoke`.
func _seen_world(plane_side: String, plane_ctl: String, tank_side: String, tank_ctl: String, gap: float, smoke: bool, tank_type: String = "tank") -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "plane", "type": "light_fighter", "side": plane_side, "controller": plane_ctl, "x": 1400.0 - gap, "y": 1000.0, "heading": 0.0})
	var spec := {"id": "tank", "type": tank_type, "side": tank_side, "controller": tank_ctl, "x": 1400.0, "y": 1000.0, "heading": 0.0}
	if tank_type == "tank":
		spec["speed"] = 0.0
	w.add_unit(spec)
	if smoke:
		w.enable_fire(null)
		w.fire.add_lit(FireFakes.tree(1, 1400.0, 1000.0, 8.0), 1, 0.0, "bomb")
	return w

func _still_seen() -> bool:
	# the fire's own question first: who is in the smoke
	var ws := _seen_world("allies", "player", "axis", "ai", 400.0, true)
	check(ws.tracking_denied("tank"), "1. the tank among the burning trees is in the smoke")
	check(not ws.tracking_denied("plane"), "1. the plane is not (planes are not denied tracking: PROPOSED)")
	check(not _seen_world("allies", "player", "axis", "ai", 400.0, false).tracking_denied("tank"), "1. with no fire, nobody is")
	var wfar := _seen_world("allies", "player", "axis", "ai", 400.0, true)
	wfar.units["tank"].x = 1400.0 + 8.0 + 30.0   # 30 m beyond the canopy's edge
	check(not wfar.tracking_denied("tank"), "1. 30 m beyond the canopy's edge is out of the smoke (it reaches 20 m)")
	wfar.units["tank"].x = 1400.0 + 8.0 + 19.0
	check(wfar.tracking_denied("tank"), "1. 19 m beyond is in it")
	var wb := _seen_world("allies", "player", "axis", "ai", 400.0, true, "radio_tower")
	check(wb.tracking_denied("tank"), "1. a STATIC unit in smoke is denied tracking as a mobile one is (PROPOSED)")
	# the player's fog: the tank in smoke is shown exactly as the tank out of it is
	var vis := FogVision.new()
	vis.update_from_world(ws)
	check(vis.shows_unit(ws, "tank"), "1. (fog) a tank 400 m off, in smoke, is SHOWN: smoke is not cover")
	var wn := _seen_world("allies", "player", "axis", "ai", 400.0, false)
	var vis_n := FogVision.new()
	vis_n.update_from_world(wn)
	check(vis_n.shows_unit(wn, "tank") == vis.shows_unit(ws, "tank"), "1. (fog) as it is without the smoke")
	var wfar2 := _seen_world("allies", "player", "axis", "ai", 900.0, true)
	var vis_f := FogVision.new()
	vis_f.update_from_world(wfar2)
	check(not vis_f.shows_unit(wfar2, "tank"), "1. (fog) and beyond the plane's sight (900 m against 800) it is not shown, smoke or no")
	# the enemy AI: a player's tank in smoke is known to the AI's plane
	var wa := _seen_world("axis", "ai", "allies", "player", 400.0, true)
	var sense := AiSense.new()
	sense.update(wa, 3)
	check(sense.knows("tank") and sense.is_visible("tank"), "1. (AI) a player's tank 400 m off, in smoke, is KNOWN and visible this turn")
	var wan := _seen_world("axis", "ai", "allies", "player", 400.0, false)
	var sense_n := AiSense.new()
	sense_n.update(wan, 3)
	check(sense_n.knows("tank") == sense.knows("tank") and sense_n.is_visible("tank") == sense.is_visible("tank"), "1. (AI) exactly as without the smoke")
	# shared spotting: the plane SEES it (spotters), but it is not SPOTTED (tracked)
	var sp := ws.spotters_now("allies", {"unit": "tank"})
	check(sp.has("plane"), "1. (spotting) the plane still sees the tank in smoke: spotters_now lists it")
	check(not ws.spotted_now("allies", {"unit": "tank"}), "1. (spotting) but the tank is not SPOTTED: it is not tracked")
	var res: Dictionary = ws.spotting.spotted_in(ws, "allies", {"unit": "tank"}, ws.spotting.frame_at(ws, -1.0))
	check(bool(res["visible"]) and bool(res["untracked"]) and not bool(res["spotted"]) and str(res["by"]) == "plane", "1. (spotting) the record says visible, untracked, not spotted, by whom: %s" % str(res))
	check(wn.spotted_now("allies", {"unit": "tank"}), "1. (spotting) without the smoke it is spotted")
	check(ws.spotted_now("allies", {"point": [1400.0, 1000.0]}), "1. (spotting) the ground itself, as a point, is still spotted (a point is not a unit)")
	# a plane among the burning trees stays spotted
	var wp := _seen_world("axis", "ai", "allies", "player", 400.0, true, "light_fighter")
	wp.units["tank"].altitude_band = "low"
	check(wp.spotted_now("axis", {"unit": "tank"}), "1. (spotting) an enemy plane over the smoke is spotted as ever")
	# the woods radius is the woods' and smoke does not add to it: a tank in a grove AND in smoke is seen at 190 m and not at 250 m, with the smoke or without
	var water: RefCounted = WaterGen.shared(SEED)
	# A GroundMap of the test's own, not GroundMap.shared: with the shared one, the village its terrain builds for the trees stayed in the
	# static cache and this test crashed at EXIT (0xC0000005 after its pass marker, every run; 2026-10-11, found when build.ps1's gate
	# failed). Freed with the function, it leaves nothing for the engine's shutdown to tear down.
	var gm: RefCounted = GroundMap.new(SEED, water)
	var src := FireTrees.new(gm.terrain)
	var site: Vector2 = WorldLayout.shared(SEED).sites()["radio_tower"]
	var grove := FireFakes.grove_point(gm, src, site)
	check(grove != Vector2.INF, "1. a grove with woods density 0.5 or more was found: (%.0f, %.0f)" % [grove.x, grove.y])
	for smoke: bool in [false, true]:
		for case: Array in [[190.0, true], [250.0, false]]:
			var wg := World.new()
			wg.quiet = true
			gm.attach(wg)
			wg.add_player("local")
			wg.add_unit({"id": "plane", "type": "light_fighter", "side": "allies", "controller": "player", "x": grove.x - float(case[0]), "y": grove.y, "heading": 0.0})
			wg.add_unit({"id": "tank", "type": "tank", "side": "axis", "controller": "ai", "x": grove.x, "y": grove.y, "heading": 0.0, "speed": 0.0})
			if smoke:
				wg.enable_fire(src)
				wg.fire.add_lit(FireFakes.tree(1, grove.x, grove.y, 8.0), 1, 0.0, "bomb")
			var vg := FogVision.new()
			vg.update_from_world(wg)
			eq(vg.shows_unit(wg, "tank"), bool(case[1]), "1. (fog) a tank in a grove %s, plane %.0f m off: shown = %s (the woods radius is 200 m; smoke changes nothing)" % ["with smoke" if smoke else "without", float(case[0]), str(case[1])])
	return true

# --- 2. The guns ------------------------------------------------------------------------------------------------------------

# The cruiser's world with an enemy tank on the coast driving east at `v` from (x0, 2540), a burning tree at (cx, 2540) when `smoke`.
func _gun_world(seed_v: int, x0: float, v: float, cx: float, smoke: bool) -> World:
	var w := GunWorlds.world(seed_v)
	if not check(w.ok() and w.add_unit({"id": "tank", "type": "tank", "side": "axis", "controller": "ai", "x": x0, "y": 2540.0, "heading": 0.0, "speed": v}) == "tank", "2. the cruiser's world takes a tank: %s" % w.last_error):
		return w
	if smoke:
		w.enable_fire(null)
		w.fire.add_lit(FireFakes.tree(1, cx, 2540.0, 8.0), 1, 0.0, "bomb")
	return w

func _guns() -> bool:
	# The tank starts clear of the smoke (the planning moment: the salvo may be set), drives east at 10 m/s and is in the smoke from x = 1767 (t = 0.7 s): the guns fire
	# at 1.25 s (the middle of the cruiser's first 2.5 s step), the walk of the target's spotting is every 0.5 s -- 0.0, 0.5 (clear), 1.0, 1.25 (in smoke).
	var x0 := 1760.0
	var cx := 1795.0
	var w := _gun_world(3, x0, 10.0, cx, true)
	var st := GunWorlds.fire(w, "tank")
	if not check(not st.is_empty() and st["fire"]["ok"] == true, "2. the salvo is planned at the tank, which is clear of the smoke at the planning moment: %s" % str(st.get("fire", w.last_error))):
		return false
	var chk := w.gun_check("cruiser", 0, {"unit": "tank"})
	check(bool(chk["spotted"]) and bool(chk["visible"]) and not bool(chk["in_smoke"]), "2. the card says spotted, visible, not in smoke")
	var res := GunWorlds.turn(w)
	if res.is_empty():
		fail("2. the turn did not resolve: %s" % w.last_error)
		return false
	var fired := GunWorlds.events_of(res, "shell_fire", "cruiser")
	if not check(fired.size() == 1, "2. the cruiser fired (%d salvos)" % fired.size()):
		return false
	var ev: Dictionary = fired[0]
	var t_fire := float(ev["t"])
	check(bool(ev.get("poor_shot", false)) and str(ev.get("poor_why", "")) == "unspotted", "2. a target in smoke at the moment of fire is a POOR SHOT (unspotted): %s" % str(ev.get("poor_why", "-")))
	# the last place it was tracked: its place at the last walked moment before it was in the smoke (0.5 s), the entry being at about 0.7 s
	var last_clear := w.sample("tank", 0.5, "history")
	var at_fire := w.sample("tank", t_fire, "history")
	var in_smoke_at_fire := Vector2(float(at_fire["x"]) - cx, float(at_fire["y"]) - 2540.0).length() - 8.0 <= 20.0
	check(in_smoke_at_fire, "2. (the tank is in the smoke at the moment of fire, %.2f s)" % t_fire)
	near(float(ev["known"][0]), float(last_clear["x"]), 0.01, "2. the guns take it to be where it was last tracked (x)")
	near(float(ev["known"][1]), float(last_clear["y"]), 0.01, "2. ... (y)")
	near(float(ev["aim"][0]), float(last_clear["x"]), 0.01, "2. and aim there, with no lead (x)")
	check(absf(float(at_fire["x"]) - float(ev["aim"][0])) > 5.0, "2. which is %.1f m short of where it was when they fired" % (float(at_fire["x"]) - float(ev["aim"][0])))
	check(GunWorlds.events_of(res, "gun_hold").is_empty(), "2. (the salvo was not held)")
	# The same turn without the smoke: a normal shot, aimed ahead of the tank
	var wn := _gun_world(3, x0, 10.0, cx, false)
	GunWorlds.fire(wn, "tank")
	var rn := GunWorlds.turn(wn)
	var fn := GunWorlds.events_of(rn, "shell_fire", "cruiser")
	if check(fn.size() == 1, "2. without the smoke it fired"):
		check(not bool(fn[0].get("poor_shot", false)), "2. and it is not a poor shot")
		check(float(fn[0]["aim"][0]) > float(last_clear["x"]) + 5.0, "2. it is aimed at the tank, led (%.1f m beyond the last-tracked place)" % (float(fn[0]["aim"][0]) - float(last_clear["x"])))
	# Being in smoke breaks the spotted run: the run starts again when it leaves (the memory carries nothing for a unit that ends the turn in smoke)
	check(not (w.spot_memory.get("allies", {}) as Dictionary).has("tank"), "2. a target that ends the turn in smoke is not remembered as spotted (the run starts again after it leaves)")
	check((wn.spot_memory.get("allies", {}) as Dictionary).has("tank"), "2. (without the smoke it is)")
	# The planning card for a tank that is already in the smoke: it is visible, it is not spotted, the special cannot be switched on, a set salvo is a poor shot
	var wp := _gun_world(5, 1790.0, 0.0, cx, true)
	var cp := wp.gun_check("cruiser", 0, {"unit": "tank"})
	check(not bool(cp["ok"]) and str(cp["reason"]) == "unspotted", "2. the card: a tank in the smoke cannot be targeted: unspotted (%s)" % str(cp["reason"]))
	check(bool(cp["visible"]) and bool(cp["in_smoke"]) and not bool(cp["spotted"]), "2. and says it is visible, in smoke, not spotted")
	check(str(cp["by"]) == "spotter", "2. seen by the tower")
	check(bool(cp["poor_shot"]), "2. a salvo set at it would be a poor shot")
	var cq := _gun_world(5, 1790.0, 0.0, cx, false).gun_check("cruiser", 0, {"unit": "tank"})
	check(bool(cq["ok"]) and bool(cq["spotted"]) and not bool(cq["in_smoke"]), "2. without the smoke the same tank can be targeted")
	var cpt := wp.gun_check("cruiser", 0, {"point": [1790.0, 2540.0]})
	check(bool(cpt["ok"]), "2. and the same place as a POINT can be (a point is not a unit): %s" % str(cpt["reason"]))
	return true

# --- 3. Bombs ------------------------------------------------------------------------------------------------------------------

func _align(w: World, aim: Vector2) -> void:
	var u: Unit = w.units["bomber"]
	u.x = aim.x - 85.0 * 0.5 * w.step_dt("bomber") - Bombs.ideal_range(85.0, w.band_height("medium"), w.bombs.gravity)
	u.y = aim.y

# A bomber lined up on a tank that drives east at 8 m/s from the tower's place, with a burning tree at (cx, 2500) when cx is finite.
func _bomb_world(seed_v: int, cx: float) -> World:
	var w := BombWorlds.world(seed_v)
	w.add_unit({"id": "tank", "type": "tank", "side": "axis", "controller": "ai", "x": BombWorlds.TOWER.x, "y": BombWorlds.TOWER.y, "heading": 0.0, "speed": 8.0})
	# a lookout keeps the tank in the bomber's side's SIGHT all through the turn, so that only the smoke can lose it (decision lost-target-last-seen)
	w.add_unit({"id": "lookout", "type": "radio_tower", "side": "allies", "controller": "player", "x": BombWorlds.TOWER.x + 60.0, "y": BombWorlds.TOWER.y + 120.0, "heading": 0.0})
	_align(w, BombWorlds.TOWER + Vector2(80.0, 0.0))
	if is_finite(cx):
		w.enable_fire(null)
		w.fire.add_lit(FireFakes.tree(1, cx, BombWorlds.TOWER.y, 8.0), 1, 0.0, "bomb")
	return w

func _release(w: World) -> Dictionary:
	var shown := Vector2(w.units["tank"].x, w.units["tank"].y)
	var st := w.plan_step("bomber", 0, {"drop": {"aim": [shown.x, shown.y], "target": {"unit": "tank"}}})
	check(not st.is_empty(), "3. the drop on the tank is planned: %s" % w.last_error)
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
	if not check(rel.size() == 1, "3. one stick was released (%d)" % rel.size()):
		return {}
	return rel[0]

# The first second (to a millisecond) at which the tank, on its history, is within 20 m of the canopy edge of the tree at (cx, 2500), or -1.
func _entry_t(w: World, cx: float) -> float:
	var t := 0.0
	while t <= 5.0:
		var p := w.sample("tank", t, "history")
		if Vector2(float(p["x"]) - cx, float(p["y"]) - BombWorlds.TOWER.y).length() - 8.0 <= 20.0:
			return t
		t += 0.001
	return -1.0

func _bombs() -> bool:
	var speed := 8.0
	# the control: no fire; the stick is aimed at the tank's place at the release plus its speed x the fall time (the existing rule)
	var wc := _bomb_world(4, INF)
	var evc := _release(wc)
	if evc.is_empty():
		return false
	var fall := float(evc["fall_s"])
	var at_rel_c := wc.sample("tank", float(evc["t"]), "history")
	near(float((evc["aim"] as Array)[0]), float(at_rel_c["x"]) + speed * fall, 0.5, "3. (no smoke) the aim is the tank's place at the release plus speed x fall time")
	var t_rel_c := float(evc["t"])
	print("[test] the control stick is released %.3f s into the turn, %.2f s of fall" % [t_rel_c, fall])
	check(t_rel_c > 0.2, "3. (the release comes after the first moments of the turn, so the tank can enter the smoke before it)")
	# The tank enters the smoke a quarter of the way to the release: the tree's centre 28 m (8 m canopy + 20 m reach) beyond the tank's place then
	var cx := BombWorlds.TOWER.x + speed * 0.25 * t_rel_c + 28.0
	var w := _bomb_world(4, cx)
	var ev := _release(w)
	if ev.is_empty():
		return false
	eq(ev.get("followed"), true, "3. the release says it followed a unit")
	var t_rel := float(ev["t"])
	var t_in := _entry_t(w, cx)
	check(t_in >= 0.0 and t_in < t_rel, "3. the tank entered the smoke at %.3f s, before the release at %.3f s" % [t_in, t_rel])
	var entry := w.sample("tank", t_in, "history")
	var aim := Vector2(float((ev["aim"] as Array)[0]), float((ev["aim"] as Array)[1]))
	check(aim.distance_to(Vector2(float(entry["x"]), float(entry["y"]))) < 0.5, "3. the bomb aims where the tank entered the smoke (%.2f, %.2f), no lead: aim (%.2f, %.2f)" % [float(entry["x"]), float(entry["y"]), aim.x, aim.y])
	var at_rel := w.sample("tank", t_rel, "history")
	check(float(at_rel["x"]) + speed * float(ev["fall_s"]) - aim.x > 30.0, "3. which is %.0f m behind the led aim it would have had" % (float(at_rel["x"]) + speed * float(ev["fall_s"]) - aim.x))
	# The tank leaves the smoke before the release: tracked again, followed normally. It starts inside it and leaves half way to the release.
	var cx2 := BombWorlds.TOWER.x + speed * 0.5 * t_rel_c - 28.0
	var wl := _bomb_world(4, cx2)
	var evl := _release(wl)
	if evl.is_empty():
		return false
	var t_rel_l := float(evl["t"])
	var in_at_rel := Vector2(float(wl.sample("tank", t_rel_l, "history")["x"]) - cx2, 0.0).length() - 8.0 <= 20.0
	check(not in_at_rel, "3. (the tank has left the smoke by the release at %.3f s)" % t_rel_l)
	check(wl.tracking_denied("tank", 0.0), "3. (it started in the smoke)")
	var at_rel_l := wl.sample("tank", t_rel_l, "history")
	near(float((evl["aim"] as Array)[0]), float(at_rel_l["x"]) + speed * float(evl["fall_s"]), 0.5, "3. out of the smoke by the release it is followed normally: the aim is its place plus the lead")
	# a tank that is in the smoke all the way back to the start of the turn: the last place it was tracked is where it stood then (the tree 20 m ahead of it)
	var wa := _bomb_world(4, BombWorlds.TOWER.x + 20.0)
	var wa_ev := _release(wa)
	if not wa_ev.is_empty():
		check(float(wa_ev["t"]) < 1.9, "3. (the release is %.2f s in, the tank is in the smoke from the start to there)" % float(wa_ev["t"]))
		var start := Vector2(BombWorlds.TOWER.x, BombWorlds.TOWER.y)
		var wa_aim := Vector2(float((wa_ev["aim"] as Array)[0]), float((wa_ev["aim"] as Array)[1]))
		check(wa_aim.distance_to(start) < 0.5, "3. in smoke since the turn began, the aim is where it stood at the start of the turn %s: %s" % [str(start), str(wa_aim)])
	return true

# --- 4. The click ----------------------------------------------------------------------------------------------------------------

func _make_ui_world() -> World:
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0, "altitude_band": "high"})
	w.add_unit({"id": "eb", "type": "bomber", "side": "axis", "controller": "ai", "x": 2400.0, "y": 2000.0, "heading": PI, "altitude_band": "high"})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2785.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2600.0, "y": 2700.0, "heading": 0.4})
	return w

func _mouse(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev

func _left_click(screen_pt: Vector2) -> void:
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, screen_pt))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))

func _right_click(screen_pt: Vector2) -> void:
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, true, screen_pt))
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, false, screen_pt))

func _clicks() -> bool:
	_w = _make_ui_world()
	_xf = Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false
	check(_w.ok(), "4. the world loads")
	var tower := Vector2(2785.0, 2400.0)
	var aa := Vector2(2600.0, 2700.0)
	_ui.marker_layer.update_poses()
	# no fire: a click on an enemy is a unit target, as it always was
	_ui.select("b1")
	_left_click(_xf * tower)
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "tower"], "4. (no smoke) a left click on the tower is a unit target")
	# a unit target set before the smoke came stays a unit target
	_ui.target.set_unit("aa1", aa)
	_w.enable_fire(null)
	_w.fire.add_lit(FireFakes.tree(1, tower.x, tower.y, 8.0), 1, 0.0, "bomb")   # the tower is among burning trees
	_ui.marker_layer.update_poses()
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "aa1"], "4. a unit target set before the smoke stays a unit target")
	# a click on the enemy in smoke: a point at its shown place
	check(_w.tracking_denied("tower") and not _w.tracking_denied("eb") and not _w.tracking_denied("aa1"), "4. the tower is in smoke, the others are not")
	_ui.select("")
	_ui.select("b1")
	_left_click(_xf * tower)
	eq(_ui.selection.unit_id, "b1", "4. the friendly stays selected")
	eq(_ui.target.kind, "point", "4. a left click on the tower in smoke sets a POINT target")
	eq(_ui.target.unit_id, "", "4. no unit")
	near(_ui.target.point_m.x, tower.x, 0.01, "4. at its shown place (x)")
	near(_ui.target.point_m.y, tower.y, 0.01, "4. (y)")
	# a click on an enemy that is not in smoke is still a unit
	_left_click(_xf * aa)
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "aa1"], "4. a click on a unit out of the smoke is a unit target")
	# the right button too
	_ui.target.clear()
	_right_click(_xf * tower)
	eq(_ui.target.kind, "point", "4. a right click on the tower in smoke is a point target")
	near(_ui.target.point_m.x, tower.x, 0.01, "4. at its place")
	_ui.target.clear()
	_right_click(_xf * aa)
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "aa1"], "4. and on a unit out of the smoke a unit target")
	# the smoke gone (the trees burnt out), the tower is a unit target again
	_w.turn = 4
	check(not _w.tracking_denied("tower"), "4. (after the trees burn out the tower is out of the smoke)")
	_ui.target.clear()
	_left_click(_xf * tower)
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "tower"], "4. and a click on it is a unit target again")
	return true
