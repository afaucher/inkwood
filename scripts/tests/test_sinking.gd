extends "res://scripts/test_support/test_case.gd"

# SHIPS SINK, PLANES THAT COME DOWN OVER WATER GO UNDER IT (Track BB, 2026-10-11; Alex, decision ship-sinks: "For destroyed ships, ideally we
# just sink them to the bottom", "Just like a downed plane its altitude should decrease until it hits the floor. It just does so through the
# water", "In fact we could have planes do the same if they crash there"). The rate (data/sim/combat.json sink_descent_mps) is proposed. The sim
# only, headless, on a synthetic sea (a deep sea, a shallow strip, then land) so every number is known:
#
#   1. A SHIP        a patrol boat of one pip is bombed in deep water: the down event's fate is out_of_control (it falls), a SPLASH event at the
#                    moment it went down, its height is 0 m at the surface and then -sink_descent x seconds, across turns, it stays where it went down
#                    (apart from the few metres of way it had), reaches the floor (minus the depth) at exactly the right moment with a crash event,
#                    and stays on it: fate crashed, fall_height_m = -depth, for as many turns as you like
#   2. THE SHALLOWS  the same in 6 m of water: the floor is -6 m, reached sooner
#   3. A PLANE       one that falls out of control over deep water goes below 0 m at the surface (a splash, no crash there), stops moving along,
#                    sinks at the same rate to the floor and is then crashed on it; one over land stops at 0 m with a crash event and no splash
#                    (as it always did); a fall that starts over land and ends over water behaves as the water under the surface point says
#   4. THE WIRE      a client that applies the host's result every turn matches it at every turn: states, fall heights, histories, and the heights
#                    World.sample gives, below 0 m as above
#   5. NO WATER      with no water in the World a destroyed ship is DESTROYED, as before (the water's own rule does not apply)
#
# The numbers are checked against the data, not written down.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

const DEEP := 30.0
const SHALLOW := 6.0
var _rules: CombatRules = null
var _ran := 0

# The synthetic sea: deep water west of x = 3000, a 6 m strip to 3500, land beyond.
func _depth(x: float, _y: float) -> float:
	if x < 3000.0:
		return DEEP
	if x < 3500.0:
		return SHALLOW
	return 0.0

func setup(_main) -> void:
	timeout_seconds = 120.0
	_rules = CombatRules.new()
	if not check(_rules.ok(), "combat.json loads: %s" % str(_rules.errors)):
		finish()
		return
	check(_rules.sink_descent > 0.0 and _rules.sink_descent < _rules.fall_descent, "the sink rate is positive and slower than the fall in the air (%.1f against %.1f m/s)" % [_rules.sink_descent, _rules.fall_descent])
	_ship(1000.0, DEEP, "deep")
	_ship(3200.0, SHALLOW, "shallows")
	_plane()
	_wire()
	_no_water()
	eq(_ran, 4, "all four parts ran to their end (the ships count once)")
	finish()

func _world(with_water: bool = true) -> World:
	var w := BombWorlds.world(3, "medium")
	if with_water:
		w.set_water(Callable(self, "_depth"))
	return w

func _turn(w: World) -> Dictionary:
	if w.phase == World.PHASE_RESOLVED:
		w.begin_turn()
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "turn %d resolves: %s" % [w.turn, w.last_error])
	return res

func _events(res: Dictionary, type: String, id: String) -> Array:
	var out: Array = []
	for ev: Dictionary in res.get("events", []):
		if str(ev["type"]) == type and str(ev.get("unit", "")) == id:
			out.append(ev)
	return out

# --- 1 and 2: a ship ------------------------------------------------------------------------------------------------

func _ship(x: float, depth: float, label: String) -> void:
	var w := _world()
	w.add_unit({"id": "cutter", "type": "patrol_boat", "side": "axis", "controller": "player", "x": x, "y": 2500.0, "heading": 0.0, "speed": 10.0})
	w.units["cutter"].health = 1
	check(w.unit_afloat("cutter"), "%s: the cutter floats where it is" % label)
	# a bomb on it at t = 1 s (it has sailed 10 m on)
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, x + 10.0, 2500.0, 1.0, 0)])
	var res := _turn(w)
	var u: Unit = w.units["cutter"]
	var down := _events(res, "down", "cutter")
	eq(down.size(), 1, "%s: one down event" % label)
	if down.is_empty():
		return
	eq(str(down[0]["fate"]), Unit.FATE_OUT_OF_CONTROL, "%s: a ship goes down FALLING (fate out_of_control: the fall machinery)" % label)
	var t_d: float = float(down[0]["t"])
	var splash := _events(res, "splash", "cutter")
	eq(splash.size(), 1, "%s: one splash" % label)
	if splash.size() == 1:
		near(float(splash[0]["t"]), t_d, 1e-6, "%s: it goes under at the moment it went down" % label)
	check(u.fate == Unit.FATE_OUT_OF_CONTROL or u.fate == Unit.FATE_CRASHED, "%s: the cutter is falling or already on the floor (%s)" % [label, u.fate])
	# heights: 0 m at the surface, then the sink rate, to the floor
	var rate := _rules.sink_descent
	var floor_m := -depth
	for t: float in [t_d, t_d + 0.5, t_d + 1.0, t_d + 2.0, 4.0]:
		if t < t_d:
			continue
		var h := float(w.sample("cutter", t, "history")["height_m"])
		near(h, maxf(-rate * (t - t_d), floor_m), 1e-6, "%s: at t = %.2f the height is -rate x time since the splash (clamped at the floor %.0f)" % [label, t, floor_m])
	var s_before := w.sample("cutter", t_d, "history")
	var s_end := w.sample("cutter", 5.0, "history")
	check(absf(float(s_end["x"]) - float(s_before["x"])) < 12.0 and absf(float(s_end["y"]) - float(s_before["y"])) < 0.01, "%s: it stays where it went down (a few metres of way: %.1f m)" % [label, absf(float(s_end["x"]) - float(s_before["x"]))])
	# across the turns until the floor, then on it
	var ts: float = w.rules.turn_seconds
	var t_total := t_d + depth / rate   # from the start of the turn it went down in
	var want_turn := int(t_total / ts) + 1
	var want_t := t_total - float(want_turn - 1) * ts
	var turn_no := 1
	var crash := _events(res, "crash", "cutter")
	while crash.is_empty() and turn_no < 9:
		check(u.fate == Unit.FATE_OUT_OF_CONTROL and u.fall_height_m < 0.0 and u.fall_height_m > floor_m, "%s: still sinking at the end of turn %d (%.1f m)" % [label, turn_no, u.fall_height_m])
		res = _turn(w)
		turn_no += 1
		check(_events(res, "splash", "cutter").is_empty(), "%s: no second splash" % label)
		crash = _events(res, "crash", "cutter")
	eq(turn_no, want_turn, "%s: it reaches the floor in turn %d (%.1f s after the turn it went down in began: %.0f m at %.1f m/s)" % [label, want_turn, t_total, depth, rate])
	eq(crash.size(), 1, "%s: one crash event, the moment it reaches the floor" % label)
	if crash.size() == 1:
		near(float(crash[0]["t"]), want_t, 1e-6, "%s: %.2f s into that turn" % [label, want_t])
	eq(u.fate, Unit.FATE_CRASHED, "%s: it is on the floor" % label)
	near(u.fall_height_m, floor_m, 1e-9, "%s: fall_height_m is the floor, minus the depth (%.0f m)" % [label, floor_m])
	var rest := Vector2(float(u.x), float(u.y))
	for k in 3:
		_turn(w)
		near(u.fall_height_m, floor_m, 1e-9, "%s: it stays on the floor" % label)
		check(Vector2(float(u.x), float(u.y)).distance_to(rest) < 1e-9, "%s: and where it is" % label)
	near(float(w.sample("cutter", 2.0, "history")["height_m"]), floor_m, 1e-9, "%s: sample() reads the floor, below 0 m" % label)
	if label == "shallows":
		_ran += 1

# --- 3: a plane ---------------------------------------------------------------------------------------------------------------

func _falling_plane(w: World, id: String, x: float, height: float) -> void:
	w.add_unit({"id": id, "type": "light_fighter", "side": "axis", "controller": "player", "x": x, "y": 2000.0, "heading": 0.0, "speed": 60.0, "altitude_band": "low"})
	var u: Unit = w.units[id]
	u.health = 0
	u.down = true
	u.fate = Unit.FATE_OUT_OF_CONTROL
	u.fall_height_m = height
	u.fall_dir = 1

func _plane() -> void:
	var w := _world()
	_falling_plane(w, "sea_plane", 1000.0, 100.0)
	_falling_plane(w, "land_plane", 3800.0, 100.0)
	var res := _turn(w)
	var u: Unit = w.units["sea_plane"]
	var t_surface := 100.0 / _rules.fall_descent
	var splash := _events(res, "splash", "sea_plane")
	eq(splash.size(), 1, "3. the plane over deep water splashes once")
	if splash.size() == 1:
		near(float(splash[0]["t"]), t_surface, 0.05, "3. at the moment its height reaches 0 m (%.1f s)" % t_surface)
	eq(_events(res, "crash", "sea_plane").size(), 0, "3. it does not crash at the surface")
	check(u.fall_height_m < 0.0 and u.fate == Unit.FATE_OUT_OF_CONTROL, "3. at the end of the turn it is BELOW 0 m, falling (%.1f m)" % u.fall_height_m)
	# it stopped moving along where it went under
	var at_surface := w.sample("sea_plane", t_surface, "history")
	var at_end := w.sample("sea_plane", 5.0, "history")
	check(Vector2(float(at_end["x"]), float(at_end["y"])).distance_to(Vector2(float(at_surface["x"]), float(at_surface["y"]))) < 0.5, "3. and stops moving along there")
	check(float(at_surface["x"]) > 1000.0 + 50.0, "3. (it flew on to there)")
	near(float(w.sample("sea_plane", 5.0, "history")["height_m"]), -_rules.sink_descent * (5.0 - t_surface), 0.02, "3. its height under the surface is -rate x time since the splash")
	# the land plane: as it always did
	var lu: Unit = w.units["land_plane"]
	eq(lu.fate, Unit.FATE_CRASHED, "3. the plane over land crashed")
	near(lu.fall_height_m, 0.0, 1e-12, "3. at 0 m")
	eq(_events(res, "crash", "land_plane").size(), 1, "3. with a crash event")
	eq(_events(res, "splash", "land_plane").size(), 0, "3. and no splash")
	# on to the floor
	var h_start := 0.0
	for k in range(1, 6):
		if u.fate == Unit.FATE_CRASHED:
			break
		h_start = u.fall_height_m
		res = _turn(w)
	eq(u.fate, Unit.FATE_CRASHED, "3. the plane reaches the floor and is crashed there")
	near(u.fall_height_m, -DEEP, 1e-9, "3. fall_height_m is the floor (-%.0f m)" % DEEP)
	eq(_events(res, "crash", "sea_plane").size(), 1, "3. one crash event, at the floor")
	near(float(_events(res, "crash", "sea_plane")[0]["t"]), (h_start + DEEP) / _rules.sink_descent, 1e-6, "3. at the moment the height reaches it")
	# a plane that falls from over the shallows' strip onto land: whatever is under the surface point decides
	var w2 := _world()
	_falling_plane(w2, "shore_plane", 3380.0, 100.0)
	_turn(w2)
	check(w2.units["shore_plane"].fate == Unit.FATE_CRASHED or w2.units["shore_plane"].fall_height_m < 0.0, "3. a plane that comes down near the shore either crashed on land or went under: %s %.1f" % [w2.units["shore_plane"].fate, w2.units["shore_plane"].fall_height_m])
	_ran += 1

# --- 4: the wire --------------------------------------------------------------------------------------------------------------

func _wire_world() -> World:
	var w := _world()
	w.add_unit({"id": "cutter", "type": "patrol_boat", "side": "axis", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0, "speed": 10.0})
	w.units["cutter"].health = 1
	_falling_plane(w, "sea_plane", 1500.0, 100.0)
	return w

static func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return a == b or (is_nan(a) and is_nan(b))
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k: Variant in a:
			if not (b as Dictionary).has(k) or not _same(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _same(a[i], b[i]):
				return false
		return true
	return a == b

func _wire() -> void:
	var host := _wire_world()
	var client := _wire_world()
	BombWorlds.drop_bombs(host, [BombWorlds.record(host, 1010.0, 2500.0, 1.0, 0)])
	BombWorlds.drop_bombs(client, [BombWorlds.record(client, 1010.0, 2500.0, 1.0, 0)])
	var below := 0
	for k in 6:
		var res := _turn(host)
		if client.phase == World.PHASE_RESOLVED:
			client.begin_turn()
		check(client.apply_resolution(res), "4. turn %d: the client applies the host's result: %s" % [k + 1, client.last_error])
		for id: String in ["cutter", "sea_plane"]:
			var hu: Unit = host.units[id]
			var cu: Unit = client.units[id]
			check(_same(hu.net_state(), cu.net_state()), "4. turn %d, %s: the states match (fall height %.3f against %.3f)" % [k + 1, id, hu.fall_height_m, cu.fall_height_m])
			check(_same(hu.history, cu.history), "4. turn %d, %s: the histories match, floors and all" % [k + 1, id])
			for t: float in [0.0, 1.3, 2.6, 5.0]:
				near(float(host.sample(id, t, "history")["height_m"]), float(client.sample(id, t, "history")["height_m"]), 1e-12, "4. turn %d, %s, t = %.1f: the same height" % [k + 1, id, t])
			if hu.fall_height_m < 0.0:
				below += 1
	check(below >= 6, "4. (heights below 0 m crossed the wire: %d unit-turns)" % below)
	_ran += 1

# --- 5: no water ----------------------------------------------------------------------------------------------------------------

func _no_water() -> void:
	var w := _world(false)
	w.add_unit({"id": "cutter", "type": "patrol_boat", "side": "axis", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0, "speed": 10.0})
	w.units["cutter"].health = 1
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, 1010.0, 2500.0, 1.0, 0)])
	var res := _turn(w)
	eq(w.units["cutter"].fate, Unit.FATE_DESTROYED, "5. with no water a destroyed ship is DESTROYED, as before")
	eq(_events(res, "splash", "cutter").size(), 0, "5. no splash")
	_ran += 1
