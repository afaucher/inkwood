extends "res://scripts/test_support/test_case.gd"

# THE TANK'S GUN AS AN ORDER, THE TURRET, THE HOLD STEP (builder ORD, 2026-10-14; Alex, decisions playtest-4, tank-gun-orders, tank-fire-feedback:
# the tank's gun is its special and fires only when ordered; "It should delay the shot in the game so the timing is variable during the turn";
# "The turret feedback should also apply to the ship"; ships fire without moving, so a step may HOLD; the orders card shows only the actions that
# apply; selecting an already-selected unit or target deselects it). Every number is PROPOSED (data/units/tank.json, cruiser.json, data/sim/guns.json).
# Headless, on the Strike seed's map for the tanks and the warship test world for the cruiser:
#
#   1. THE TRAVERSE   the shot leaves when the turret is on bearing: a target 20, 60, 85 degrees off the nose is shot at 20/25, 60/25, 85/25 s into the
#                     turn, along the turret's bearing; the bearing is state (Unit.turret), it persists, it interpolates through the turn (turret_at)
#   2. TOO FAR A SWING a turn too short for the turret: no shot, the reason off_bearing, no reload spent, the turret has turned as far as it could and
#                     the next turn finishes the job
#   3. THE ARC        outside the 170 degrees the card says so and a forced order holds, the turret turned to the edge of the arc
#   4. THE SHIP       the cruiser's turrets turn at their own rate: the same delay, the same hold, the same next turn
#   5. THE HOLD STEP  a hold keeps the point, counts as planned, takes a special; a plane cannot hold; a bad hold is refused
#   6. THE AI         an AI tank orders its gun itself, at a foe the card would let it fire at, never at a friend, and not while it reloads
#   7. THE WIRE       the hold, the turret's bearing and its track cross with a plan, a resolve and a snapshot
#   8. THE INTERFACE  Hold in place of Dive / Level / Climb for a tank (a plane keeps its three), the hold on the card and the map, the special on a hold step,
#                     a click on the selected unit or the target lets go of it

const World = preload("res://scripts/sim/world.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const RATE := 25.0      # deg/s: data/units/tank.json turret.traverse_dps
const SHIP_RATE := 10.0   # data/units/cruiser.json turret.traverse_dps

var _done := 0

func setup(_main) -> void:
	timeout_seconds = 240.0
	for part: Script in [World, AiPilot, WorldSync, TankWorlds, GunWorlds, UnitUI]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_traverse()
	_too_far()
	_arc()
	_ship()
	_hold()
	_ai()
	_wire()
	_interface()
	_art()
	eq(_done, 9, "the test reached its last section (a runtime error would have ended it silently)")
	finish()

# Two tanks on the road 200 m apart, `a` turned `off_deg` away from `b` (so `b` lies off_deg to the LEFT of a's nose, a turret bearing of -off_deg).
func _pair(off_deg: float, seed_v: int = 3) -> World:
	var a_at := TankWorlds.road(140)
	var b_at := TankWorlds.road(160)
	var w := TankWorlds.world("allies", false)
	w.rng_seed = seed_v
	TankWorlds.tank(w, "a", "allies", "player", a_at, (b_at - a_at).angle() + deg_to_rad(off_deg), 0.0)
	TankWorlds.tank(w, "b", "axis", "player", b_at, (a_at - b_at).angle(), 0.0)
	return w

func _bearing_to_b() -> float:
	return (TankWorlds.road(160) - TankWorlds.road(140)).angle()

# --- 1. The traverse ----------------------------------------------------------------------------------------------------

func _traverse() -> void:
	for off: float in [0.0, 20.0, 60.0, 85.0]:
		var w := _pair(off)
		var chk := w.gun_check("a", 0, {"unit": "b"}, "tank_gun")
		check(bool(chk["ok"]) and bool(chk["bears_in_time"]), "1. b %.0f degrees off the nose can be fired at: %s" % [off, str(chk["reason"])])
		near(float(chk["traverse_s"]), off / RATE, 1e-6, "1. the card knows the turret needs %.2f s" % (off / RATE))
		check(float(chk["odds"]) > 0.3 and float(chk["odds"]) <= 1.0, "1. and the chance of a hit (%.2f)" % float(chk["odds"]))
		TankWorlds.order_fire(w, "a", "b")
		var res := TankWorlds.turn(w)
		var f := TankWorlds.fires(res, "a", "b")
		if not check(f.size() == 1, "1. one shot at %.0f degrees" % off):
			continue
		near(float(f[0]["t"]), off / RATE, 1e-6, "1. THE TURN DELAYS THE SHOT: it leaves %.2f s into the turn (the turret turns at %.0f deg/s)" % [off / RATE, RATE])
		check(bool(f[0]["aimed"]) and str(f[0]["special"]) == "tank_gun", "1. an aimed shot of the special")
		var diff := absf(wrapf(float(f[0]["bearing"]) - _bearing_to_b(), -PI, PI))
		near(diff, 0.0, 1e-6, "1. along the turret's bearing, which is on the target")
		var u: Object = w.units["a"]
		near(float(u.turret), -deg_to_rad(off), 1e-6, "1. the turret ends the turn at %.0f degrees to the left of the nose" % off)
		# the bearing through the turn: a straight line from the start to where it stopped, then still
		if off > 0.0:
			near(w.turret_at("a", off / RATE * 0.5), -deg_to_rad(off) * 0.5, 1e-6, "1. halfway through the traverse it is halfway round")
			near(w.turret_at("a", 0.0), 0.0, 1e-9, "1. it began at the nose")
		near(w.turret_at("a", 5.0), -deg_to_rad(off), 1e-6, "1. and stays on the target to the end of the turn")
		check(WorldSync.same(u.net_state()["turret"], u.turret), "1. the bearing is in the unit's net state (it crosses the wire)")
		# it persists: another turn with no order moves nothing
		TankWorlds.turn(w)
		near(float(u.turret), -deg_to_rad(off), 1e-6, "1. the bearing persists to the next turn")
	# a hull that turns carries its turret round: with no order the bearing relative to the nose does not change
	var wt := _pair(0.0)
	(wt.units["a"] as Object).turret = deg_to_rad(30.0)
	wt.plan_step("a", 0, {"turn": 0.5, "speed": 0.0})
	TankWorlds.turn(wt)
	near(float((wt.units["a"] as Object).turret), deg_to_rad(30.0), 1e-9, "1. a pivoting hull carries its turret round: the bearing from the nose is unchanged")
	# no order, no turret movement, even with a target in range
	var wn := _pair(60.0)
	TankWorlds.turn(wn)
	near(float((wn.units["a"] as Object).turret), 0.0, 1e-12, "1. no order, no turning: the turret keeps its bearing")
	_done += 1

# --- 2. Too far a swing ---------------------------------------------------------------------------------------------------

func _too_far() -> void:
	# the turret is 84 degrees to the left, the target 84 to the right: 168 degrees, 6.72 s; a turn is 5 s
	var w := _pair(-84.0)   # (b lies 84 degrees to the RIGHT of a's nose)
	(w.units["a"] as Object).turret = -deg_to_rad(84.0)
	var chk := w.gun_check("a", 0, {"unit": "b"}, "tank_gun")
	check(bool(chk["ok"]), "2. the order may be set (the target is in the arc): %s" % str(chk["reason"]))
	check(not bool(chk["bears_in_time"]), "2. but the card warns the turret will not bear this turn")
	near(float(chk["traverse_s"]), 168.0 / RATE, 1e-6, "2. it needs %.2f s" % (168.0 / RATE))
	var st := UiStyle.new()
	check(st.text("guns.text.bears_late").contains("%"), "2. the words exist (guns.text.bears_late)")
	TankWorlds.order_fire(w, "a", "b")
	var res := TankWorlds.turn(w)
	eq(TankWorlds.fires(res, "a").size(), 0, "2. no shot: the turret did not come round in the turn")
	var h := TankWorlds.holds(res, "a")
	check(h.size() == 1 and h[0]["reason"] == "off_bearing", "2. a gun_hold with the reason 'off_bearing': %s" % str(h))
	eq((w.units["a"] as Object).gun_ready.size(), 0, "2. and no reload was spent")
	near(float((w.units["a"] as Object).turret), -deg_to_rad(84.0) + deg_to_rad(RATE * 5.0), 1e-6, "2. the turret turned as far as it could in 5 s (to %.0f degrees)" % (-84.0 + RATE * 5.0))
	# the next turn: 43 degrees to go, 1.72 s
	var chk2 := w.gun_check("a", 0, {"unit": "b"}, "tank_gun")
	check(bool(chk2["bears_in_time"]), "2. next turn the card says it will bear")
	near(float(chk2["traverse_s"]), 43.0 / RATE, 1e-6, "2. 43 degrees to go: %.2f s" % (43.0 / RATE))
	TankWorlds.order_fire(w, "a", "b")
	var res2 := TankWorlds.turn(w)
	var f2 := TankWorlds.fires(res2, "a", "b")
	if check(f2.size() == 1, "2. the second turn fires"):
		near(float(f2[0]["t"]), 43.0 / RATE, 1e-6, "2. at %.2f s" % (43.0 / RATE))
	_done += 1

# --- 3. The arc ---------------------------------------------------------------------------------------------------------------

func _arc() -> void:
	for off: float in [80.0, 90.0, 135.0, 180.0]:
		var w := _pair(off)
		var chk := w.gun_check("a", 0, {"unit": "b"}, "tank_gun")
		var inside := off <= 85.0
		eq(bool(chk["ok"]), inside, "3. b %.0f degrees off the nose: %s" % [off, "inside the 170 degree arc" if inside else "outside it"])
		if not inside:
			eq(str(chk["reason"]), "out_of_arc", "3. the card says out of the arc")
			TankWorlds.order_fire(w, "a", "b")
			var res := TankWorlds.turn(w)
			eq(TankWorlds.fires(res, "a").size(), 0, "3. a forced order does not fire")
			var h := TankWorlds.holds(res, "a")
			check(h.size() == 1 and h[0]["reason"] == "out_of_arc", "3. a gun_hold 'out_of_arc'")
			var rel := float((w.units["a"] as Object).turret)
			check(absf(absf(rel) - deg_to_rad(85.0)) < 1e-6, "3. the turret turned to the edge of its arc (%.1f degrees)" % rad_to_deg(rel))
	# the hull coming round brings the target into the arc during the turn: the order then fires
	var wc := _pair(100.0)   # b is 100 degrees to the left: outside
	wc.plan_step("a", 0, {"turn": -deg_to_rad(75.0), "speed": 0.0})
	var chk_c := wc.gun_check("a", 0, {"unit": "b"}, "tank_gun")
	check(bool(chk_c["ok"]), "3. with the hull ordered round 75 degrees in step 1, the card finds the target inside the arc at the end of the step: %s" % str(chk_c["reason"]))
	_done += 1

# --- 4. The ship -----------------------------------------------------------------------------------------------------------

func _ship() -> void:
	# the cruiser heads east at rest, the target battery due east at 1200 m. Turrets on the nose: the old timing (fire_at)
	var w := GunWorlds.world(3)
	var c0 := w.gun_check("cruiser", 0, {"unit": "aa"})
	check(bool(c0["ok"]), "4. a battery 1200 m due east can be fired at: %s" % str(c0["reason"]))
	near(float(c0["traverse_s"]), 0.0, 1e-9, "4. the turrets are on it")
	var f0 := GunWorlds.events_of(GunWorlds.turn(w), "shell_fire", "cruiser")   # (no order: nothing fires)
	var wf := GunWorlds.world(3)
	GunWorlds.fire(wf, "aa")
	var rf := GunWorlds.turn(wf)
	var ff := GunWorlds.events_of(rf, "shell_fire", "cruiser")
	if check(ff.size() == 1, "4. the ordered salvo fires"):
		near(float(ff[0]["t"]), 1.25, 1e-9, "4. at fire_at of its step, as before (turrets already on bearing)")
	eq(f0.size(), 0, "4. (and nothing without an order)")
	# turrets trained 90 degrees away: 9 s at 10 deg/s; the turn is 5 s
	var ws := GunWorlds.world(3)
	(ws.units["cruiser"] as Object).turret = PI / 2.0
	var chk := ws.gun_check("cruiser", 0, {"unit": "aa"})
	check(bool(chk["ok"]) and not bool(chk["bears_in_time"]), "4. the card warns the turrets will not bear this turn")
	near(float(chk["traverse_s"]), 90.0 / SHIP_RATE, 1e-6, "4. 90 degrees at %.0f deg/s: %.0f s" % [SHIP_RATE, 90.0 / SHIP_RATE])
	GunWorlds.fire(ws, "aa")
	var rs := GunWorlds.turn(ws)
	eq(GunWorlds.events_of(rs, "shell_fire", "cruiser").size(), 0, "4. no salvo in the first turn")
	var hs := GunWorlds.events_of(rs, "gun_hold", "cruiser")
	check(hs.size() == 1 and hs[0]["reason"] == "off_bearing", "4. a gun_hold 'off_bearing': %s" % str(hs))
	eq(int((ws.units["cruiser"] as Object).gun_ready.get("main_guns", 0)), 0, "4. the reload is not spent")
	near(float((ws.units["cruiser"] as Object).turret), PI / 2.0 - deg_to_rad(SHIP_RATE * 5.0), 1e-6, "4. the turrets turned 50 degrees")
	near(ws.turret_at("cruiser", 2.5), PI / 2.0 - deg_to_rad(SHIP_RATE * 2.5), 1e-6, "4. and the playback has them partway at 2.5 s")
	ws.begin_turn()
	GunWorlds.fire(ws, "aa")
	var rs2 := GunWorlds.turn(ws)
	var fs2 := GunWorlds.events_of(rs2, "shell_fire", "cruiser")
	if check(fs2.size() == 1, "4. the next turn fires"):
		near(float(fs2[0]["t"]), 4.0, 1e-6, "4. at 4 s: the 40 degrees to go at %.0f deg/s" % SHIP_RATE)
		check(float(fs2[0]["flight_s"]) > 0.0 and int(fs2[0]["shells"]) > 0, "4. a salvo of shells as before")
	near(float((ws.units["cruiser"] as Object).turret), 0.0, 1e-6, "4. the turrets are on the target")
	# the scenario trains the turrets at the start (add_unit turret_deg)
	var wa := World.new()
	wa.quiet = true
	wa.add_unit({"id": "c", "type": "cruiser", "side": "allies", "controller": "player", "x": 500.0, "y": 500.0, "heading": 0.0, "speed": 0.0, "turret_deg": 75.0})
	near(float((wa.units["c"] as Object).turret), deg_to_rad(75.0), 1e-9, "4. add_unit's turret_deg trains the turrets at the start")
	var wb := World.new()
	wb.quiet = true
	wb.add_unit({"id": "t", "type": "tank", "side": "allies", "controller": "player", "x": 500.0, "y": 500.0, "heading": 0.0, "speed": 0.0, "turret_deg": 170.0})
	near(float((wb.units["t"] as Object).turret), deg_to_rad(85.0), 1e-9, "4. ... and a tank's is held inside its arc")
	_done += 1

# --- 5. The hold step ---------------------------------------------------------------------------------------------------

func _hold() -> void:
	var a_at := TankWorlds.road(140)
	var w := TankWorlds.world("allies", false)
	TankWorlds.tank(w, "t", "allies", "player", a_at, TankWorlds.toward(140, 160), 8.0)
	var s0 := w.plan_step("t", 0, {"hold": true})
	check(not s0.is_empty(), "5. a tank takes a hold step: %s" % w.last_error)
	check(bool(s0["planned"]) and bool(s0.get("hold", false)), "5. it counts as planned, and says it holds")
	eq(float(s0["speed"]), 0.0, "5. a tank doing 8 m/s brakes to a stop in the step (decel 4 m/s^2 x 2.5 s)")
	check(float(s0["turn"]) == 0.0, "5. without turning")
	var s1 := w.plan_step("t", 1, {"hold": true})
	eq([s1["x"], s1["y"]], [s0["x"], s0["y"]], "5. the second hold keeps the point exactly")
	# a tank at rest keeps its point to the bit
	var w2 := TankWorlds.world("allies", false)
	TankWorlds.tank(w2, "t", "allies", "player", a_at, TankWorlds.toward(140, 160), 0.0)
	var h0 := w2.plan_step("t", 0, {"hold": true})
	eq([h0["x"], h0["y"]], [a_at.x, a_at.y], "5. a tank at rest holds exactly where it is")
	# a hold takes a special; the special fires on the held step
	TankWorlds.tank(w2, "e", "axis", "player", TankWorlds.road(160), PI, 0.0)
	var held_fire := w2.plan_step("t", 0, {"hold": true, "fire": {"special": "tank_gun", "target": {"unit": "e"}}})
	check(not held_fire.is_empty() and held_fire.has("fire"), "5. a special can be set on a hold step")
	var res := TankWorlds.turn(w2)
	check(TankWorlds.fires(res, "t", "e").size() == 1, "5. ... and it fires (the tank held its place)")
	eq([(w2.units["t"] as Object).x, (w2.units["t"] as Object).y], [a_at.x, a_at.y], "5. ... and did not move")
	# the ship
	var ws := GunWorlds.world(2)
	var sh := ws.plan_step("cruiser", 0, {"hold": true, "fire": {"special": "main_guns", "target": {"unit": "aa"}}})
	check(not sh.is_empty() and float(sh["speed"]) == 0.0, "5. a ship holds too, and fires")
	eq(GunWorlds.events_of(GunWorlds.turn(ws), "shell_fire", "cruiser").size(), 1, "5. the cruiser's salvo leaves from a held step")
	# a plane cannot hold
	var wp := World.new()
	wp.quiet = true
	wp.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 2000.0, "heading": 0.0, "altitude_band": "medium"})
	eq(wp.plan_step("p", 0, {"hold": true}), {}, "5. a plane cannot hold")
	check(wp.last_error.contains("cannot hold"), "5. ... and the sim says so: %s" % wp.last_error)
	check(not Envelope.request_error({"hold": "yes"}).is_empty(), "5. 'hold' must be true or false")
	eq(Envelope.request_error({"hold": true}), "", "5. {hold: true} is a request")
	_done += 1

# --- 6. The AI -----------------------------------------------------------------------------------------------------------------

func _ai() -> void:
	var w := TankWorlds.world("allies", false)
	TankWorlds.tank(w, "p", "allies", "player", TankWorlds.road(150), TankWorlds.toward(150, 170), 0.0)
	TankWorlds.tank(w, "e", "axis", "ai", TankWorlds.road(172), TankWorlds.toward(172, 150), 0.0)
	TankWorlds.tank(w, "f", "axis", "ai", TankWorlds.road(180), TankWorlds.toward(180, 150), 0.0)   # the AI's own friend, behind e
	w.rng_seed = 5
	var ai := AiPilot.new()
	var to := TankWorlds.road(150)
	var f_to := TankWorlds.road(140)
	if not check(ai.attach(w, {"e": {"role": "drive", "to": [to.x, to.y]}, "f": {"role": "drive", "to": [f_to.x, f_to.y], "start_turn": 9}}), "6. the AI takes its orders: %s" % str(ai.errors)):
		_done += 1
		return
	var plan_e: Array = (w.units["e"] as Object).plan
	var fire_steps := 0
	var fire_target := ""
	for st: Variant in plan_e:
		if (st as Dictionary).has("fire"):
			fire_steps += 1
			fire_target = str(((st as Dictionary)["fire"] as Dictionary)["target"]["unit"])
			eq(str(((st as Dictionary)["fire"] as Dictionary)["special"]), "tank_gun", "6. the special it orders is the tank's gun")
	eq(fire_steps, 1, "6. THE AI ORDERS ITS GUN: one fire in its plan (one shot a turn)")
	eq(fire_target, "p", "6. at the foe in range (the player's tank), never at its friend")
	# the AI's plan did not need the player's: p has no plan at all
	eq(((w.units["p"] as Object).plan as Array).size(), 0, "6. (the player's tank has no plan: the AI did not read one)")
	var res := TankWorlds.turn(w)
	var shots := TankWorlds.fires(res, "e", "p")
	eq(shots.size(), 1, "6. and it fires in the turn")
	eq(TankWorlds.fires(res, "e", "f").size() + TankWorlds.fires(res, "f", "e").size(), 0, "6. the two AI tanks never fire at each other (the card refuses a friend)")
	# turn 2: reloading: no order
	var plan2: Array = (w.units["e"] as Object).plan
	var again := 0
	for st: Variant in plan2:
		if (st as Dictionary).has("fire"):
			again += 1
	eq(again, 0, "6. in the next turn the gun is reloading and the AI orders nothing")
	# turn 3: loaded again, orders again
	TankWorlds.turn(w)
	var third := 0
	for st: Variant in (w.units["e"] as Object).plan:
		if (st as Dictionary).has("fire"):
			third += 1
	check(third == 1 or (w.units["p"] as Object).down or (w.units["e"] as Object).down, "6. two turns after, it orders its gun again (or a tank is down)")
	_done += 1

# --- 7. The wire -----------------------------------------------------------------------------------------------------------------

func _coop_world(host: bool) -> Array:
	var w := TankWorlds.world("axis", false)
	var b_at := TankWorlds.road(160)
	var a_at := TankWorlds.road(140)
	TankWorlds.tank(w, "p1", "allies", "player", a_at, (b_at - a_at).angle() + deg_to_rad(40.0), 0.0)
	TankWorlds.tank(w, "p2", "allies", "player", TankWorlds.road(132), (b_at - a_at).angle(), 6.0)
	TankWorlds.tank(w, "e1", "axis", "player", b_at, (a_at - b_at).angle(), 0.0)
	w.rng_seed = 9
	var sync := WorldSync.new()
	sync.name = "WorldSync_%s_%d" % ["host" if host else "peer", get_child_count()]
	add_child(sync)
	sync.setup(w, "tank_orders", "local")
	return [w, sync]

func _wire() -> void:
	var h := _coop_world(true)
	var c := _coop_world(false)
	var host: World = h[0]
	var host_sync: WorldSync = h[1]
	var client: World = c[0]
	var client_sync: WorldSync = c[1]
	host.plan_step("p1", 0, {"hold": true, "fire": {"special": "tank_gun", "target": {"unit": "e1"}}})
	host.plan_step("p2", 0, {"hold": true})
	var snap := host_sync.snapshot()
	client_sync.apply_snapshot(snap)
	check(WorldSync.same(client.units["p1"].plan, host.units["p1"].plan), "7. the plan with its hold and its fire crosses (snapshot)")
	eq(bool((client.units["p2"].plan[0] as Dictionary).get("hold", false)), true, "7. p2's hold step is on the client")
	var cs: Dictionary = (client.planned_states("p1") as Array)[0]
	check(bool(cs.get("hold", false)), "7. and the client's own states say it holds")
	host.commit(host_sync.local_player())
	var result := host.resolve()
	check(not result.is_empty(), "7. the host resolves: %s" % host.last_error)
	check(client.apply_resolution(result), "7. the client applies it: %s" % client.last_error)
	var fired := TankWorlds.fires(result, "p1", "e1")
	eq(fired.size(), 1, "7. the held tank fired its swung turret's shot")
	near(float(fired[0]["t"]), 40.0 / RATE, 1e-6, "7. after the traverse (%.1f s)" % (40.0 / RATE))
	var u_h: Object = host.units["p1"]
	var u_c: Object = client.units["p1"]
	near(float(u_h.turret), -deg_to_rad(40.0), 1e-6, "7. the host's turret is on the target")
	eq(float(u_c.turret), float(u_h.turret), "7. the client has the host's turret bearing, to the bit")
	check(WorldSync.same(u_c.history, u_h.history), "7. and the history with the turret's track")
	var track: Variant = (u_h.history[0] as Dictionary).get("turret_track")
	check(track is Array and not (track as Array).is_empty(), "7. the track is in the history's first state")
	near(client.turret_at("p1", 0.8), host.turret_at("p1", 0.8), 0.0, "7. the playback's bearing agrees at 0.8 s")
	check(WorldSync.same(u_c.net_state(), u_h.net_state()), "7. the unit's net state agrees")
	host.begin_turn()
	client.begin_turn()
	# a late joiner takes the turret with the snapshot
	var l := _coop_world(false)
	var late: World = l[0]
	var late_sync: WorldSync = l[1]
	late_sync.apply_snapshot(host_sync.snapshot())
	eq(float((late.units["p1"] as Object).turret), float(u_h.turret), "7. a late joiner is told the turret's bearing")
	check(WorldSync.same((late.units["p1"] as Object).history, u_h.history), "7. ... and the history (the playback's track)")
	# the gun's reload crossed with the resolve: loaded in turn 3, reloading in turn 2
	eq(int(u_c.gun_ready.get("tank_gun", 0)), 3, "7. the reload (ready in turn 3) crossed")
	_done += 1

# --- 8. The interface ------------------------------------------------------------------------------------------------------------

func _interface() -> void:
	var st := UiStyle.new()
	var a_at := Vector2(1500.0, 2500.0)
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "t", "type": "tank", "side": "allies", "controller": "player", "x": a_at.x, "y": a_at.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "e", "type": "tank", "side": "axis", "controller": "ai", "x": a_at.x + 200.0, "y": a_at.y, "heading": PI, "speed": 0.0})
	w.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1400.0, "y": 2200.0, "heading": 0.0, "altitude_band": "medium"})
	var xf := Transform2D(0.0, Vector2(0.5, 0.5), 0.0, -Vector2(1300.0, 2300.0) * 0.5)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	ui.auto_resolve = false
	var pl = ui.planner
	var card = ui.orders
	ui.select("t")
	var bt: Dictionary = card.buttons()
	check(bt.has("hold") and not bt.has("dive") and not bt.has("level") and not bt.has("climb"), "8. a tank's card has Hold, and no Dive, Level or Climb")
	eq(str(bt["hold"]["label"]), "Hold", "8. the button reads Hold")
	check(bool(bt["hold"]["enabled"]) and not bool(bt["hold"]["on"]), "8. it is on offer (the next step), not pressed")
	ui.select("p")
	var bp: Dictionary = card.buttons()
	check(bp.has("dive") and bp.has("level") and bp.has("climb") and not bp.has("hold"), "8. a plane's card keeps Dive, Level and Climb, and has no Hold")
	ui.select("t")
	# Hold on the next step creates it
	var held: Dictionary = pl.toggle_hold()
	check(not held.is_empty() and bool(held.get("hold", false)), "8. Hold places a hold step")
	eq(pl.planned_count(), 1, "8. one step is planned")
	check(pl.step_holds(0), "8. step 1 holds")
	eq(pl.focus_step(), 0, "8. and is the selected step")
	check(bool(card.buttons()["hold"]["on"]), "8. the button is pressed")
	eq(card._altitude_caption(), st.text("orders.text.holds") % 1, "8. the card's line says the step holds its place")
	check(not card.press_button("dive"), "8. (no Dive to press)")
	# the special on a hold step, through the interface
	check(ui.set_target_unit("e"), "8. an enemy is targeted")
	var opt: Dictionary = pl.drop_options()
	check(bool(opt["available"]), "8. Turret Fire is on offer on the held step: %s" % str(opt["why"]))
	eq(pl.special_label(), "Turret Fire", "8. its words")
	pl.toggle_drop()
	check(pl.step_has_fire(0), "8. the gun is set on the held step")
	check(pl.step_holds(0), "8. and the step still holds")
	var cap: String = card.special_caption()
	check(cap.contains("Turret Fire") and cap.contains("percent"), "8. the card says what it does: '%s'" % cap)
	# pressing Hold again lets the step move on (the hold is taken away, the fire stays)
	pl.toggle_hold()
	check(not pl.step_holds(0), "8. Hold pressed again is off")
	check(pl.step_has_fire(0), "8. (the gun stays set)")
	# a point placed on a hold step turns it into a move
	pl.toggle_hold()
	check(pl.step_holds(0), "8. held again")
	pl.begin_edit(0, a_at + Vector2(10.0, 0.0))
	pl.end_step()
	check(not pl.step_holds(0), "8. a point placed on a hold step turns it back into a move")
	# the reasons the card gives
	pl.clear()
	ui.target.clear()
	ui.set_target_point(a_at + Vector2(80.0, 0.0))
	pl.toggle_hold()
	var why: Dictionary = pl.drop_options()
	check(not bool(why["available"]) and str(why["why"]) == st.text("guns.text.point_target"), "8. a point is not a target for the gun: '%s'" % str(why["why"]))
	# selecting the selected unit lets go of it; the roster and the map do the same
	check(ui.selection.unit_id == "t", "8. the tank is selected")
	ui.selection.toggle("t")
	eq(ui.selection.unit_id, "", "8. a click on the selected unit deselects it")
	ui.selection.toggle("t")
	eq(ui.selection.unit_id, "t", "8. and again selects it")
	var row_of_t := -1
	for i in ui.roster.rows().size():
		if str(ui.roster.rows()[i]["id"]) == "t":
			row_of_t = i
	check(row_of_t >= 0 and ui.roster.select_row(row_of_t), "8. the tank's roster row is clicked")
	eq(ui.selection.unit_id, "", "8. a click on the selected unit's row lets go of it")
	ui.select("t")
	# the target
	ui.target.clear()
	check(ui.toggle_target_unit("e"), "8. a click on an enemy targets it")
	eq(ui.target.unit_id, "e", "8. it is the target")
	check(ui.toggle_target_unit("e"), "8. a second click on the same enemy")
	check(not ui.target.is_set(), "8. lets go of it")
	check(ui.toggle_target_point(a_at + Vector2(50.0, 20.0)) and ui.target.is_point(), "8. a right-click on a point targets it")
	check(ui.toggle_target_point(a_at + Vector2(50.0, 20.0)) and not ui.target.is_set(), "8. and the same point again lets go of it")
	ui.queue_free()
	_done += 1

# --- 9. The drawn turrets ------------------------------------------------------------------------------------------------------------
# (what is baked needs a window, not the gate: the cruiser's muzzles come from the drawn barrels' geometry, which is pure)

func _art() -> void:
	const Art = preload("res://scripts/ui/unit_marker_art.gd")
	var st := UiStyle.new()
	var ahead: Array = Art.ship_muzzles(st, "small_cruiser", 0.0)
	var abeam: Array = Art.ship_muzzles(st, "small_cruiser", PI / 2.0)
	check(ahead.size() >= 4 and ahead.size() == abeam.size(), "9. the cruiser has barrels in its turrets (%d)" % ahead.size())
	var m: RefCounted = Art.model_for(st, "small_cruiser")
	var reach: float = float(m.p.turret_r) * 0.85 + float(m.p.barrel_len)
	var tc: Vector2 = (m.G.turrets[0] as Dictionary).c
	var i := 0
	for t: Dictionary in m.G.turrets:
		for k in int(m.p.barrels):
			var a: Dictionary = ahead[i]
			var b: Dictionary = abeam[i]
			# trained ahead the tip is ahead of the turret's axis by the reach; trained to starboard it is to starboard of it by the same
			near(float(a["fwd"]) - (-(t.c as Vector2).y), reach, 1e-3, "9. trained ahead, barrel %d of a turret ends %.1f m ahead of its axis" % [k, reach])
			near(float(b["lat"]) - (t.c as Vector2).x, reach, 1e-3, "9. trained to starboard, it ends %.1f m to starboard of the axis" % reach)
			i += 1
	check(tc.y < 0.0, "9. (the first turret stands forward)")
	# the unit file's tip agrees with the drawn tank's gun, as the fx data's tip did (4.8 m from the turret's axis)
	var w := World.new()
	w.quiet = true
	near(float(w.unit_def("tank").turret["barrel_tip_m"]), 4.8, 1e-9, "9. the tank's barrel tip is 4.8 m from its turret's axis")
	near(float(w.unit_def("cruiser").turret["barrel_tip_m"]), reach, 0.1, "9. the cruiser's data agrees with its drawn barrels (%.1f m)" % reach)
	_done += 1
