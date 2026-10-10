extends "res://scripts/test_support/test_case.gd"

# SIGHT FOLLOWS THE PILOT (Track S-sight, 2026-10-10), headless. Alex, playtest of the Strike:
# "A destroyed plane keeps the fog away. Ideally we have this track the pilot. So a destroyed
# plane should loose the fog. One disabled and falling should keep it but with reduced distance
# until it hits. (take height into account too)."
#
#   DATA      data/sim/sight.json holds exactly the three proposed records the rule reads, each with
#             Alex's words in its _reason; broken data is an error, not a default.
#   RULE      scripts/sim/sight_rules.gd on hand-made units: a live unit is untouched; exploded and
#             destroyed ones see until down_at and then nothing (nothing at all when they went down
#             in an earlier turn); a falling one sees a radius in proportion to its height, between
#             a floor and falling_factor x its sight; a crashed one sees nothing.
#   FOG       the player's fog (FogVision.update_from_world at the playback time t), on real worlds
#             resolved by the real combat: a live plane's circle is unchanged at every t; an
#             exploding plane's circle is there until the moment it went down and never again; a
#             plane out of control keeps a smaller circle that shrinks with its height, turn after
#             turn, and is gone from the instant it crashes (the expected radius is computed here
#             from the JSON and the fall rate, not from the code under test); a plane that crashes
#             within the turn it went down in still shows its fall at t; the circle's edge is where
#             the circle says (is_visible_xy); a destroyed radio tower and battery (real bombs)
#             stop revealing at the bomb.
#   AI        the enemy AI's knowledge (AiSense) agrees with the fog for every state above: the
#             distance at which an AI-controlled unit spots a player's plane is the same radius.
#   LOS       with line of sight ON (real terrain, FogVision.set_line_of_sight): a falling plane's eye is
#             its CURRENT height (every sample of a resolved fall, and as it stands at the end of a
#             turn), so as it drops behind a plateau's lip the low ground beyond closes (a frozen
#             plane at a real plateau edge, lowered step by step: visible while high, hidden once low,
#             the radius rule still applied on top); and its shed is not swept every frame: it is
#             reused until its height, position or radius has changed by the data's tolerances.
#
# Seeds that give each fate are FOUND, not written down (a retune would move them).

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const SightRules = preload("res://scripts/sim/sight_rules.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const AiSense = preload("res://scripts/sim/ai_sense.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")
const FogSites = preload("res://scripts/render/fog_viewshed_sites.gd")

const TERRAIN_SEED := 20261009

const REF_BASE := 800.0   # a made-up full radius for the hand-made units

var _factor := NAN
var _ref := NAN
var _floor := NAN
var _descent := NAN
var _sections: Array[String] = []
var _terrain: Terrain

func setup(_main) -> void:
	timeout_seconds = 120.0
	if not _data():
		finish()
		return
	_rule_table()
	_fog_live()
	_fog_exploded()
	_fog_falling()
	_fog_crash_in_the_turn()
	_fog_ground()
	_ai_side()
	_los_falling()
	# The sentinel: a section that stopped on a runtime error is missing from this list.
	eq(_sections, ["data", "rule", "live", "exploded", "falling", "crash", "ground", "ai", "los_eye", "los_reuse", "los_hill"], "every section ran to its end")
	finish()

# --- helpers -----------------------------------------------------------------------------

# The radius the rule must give, computed here from the data (not by the code under test):
# nothing at or below the ground; else falling_factor x base x min(h / reference, 1), kept
# within [floor, falling_factor x base].
func _expect(base: float, h: float) -> float:
	if not (h > 0.0):
		return 0.0
	var cap := base * _factor
	return clampf(cap * minf(h / _ref, 1.0), minf(_floor, cap), cap)

static func _sight_from_file(type_id: String) -> float:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/%s.json" % type_id))
	return float(parsed["sight_range_m"]["value"])

# `bomber_ctl` and `fighter_ctl` say who gives orders ("player" or "ai"); the fog reveals by side, so
# with the bomber ("axis") the only player-controlled unit it is the only unit that reveals.
func _victim_world(seed_value: int, bomber_ctl: String, fighter_ctl: String, band: String, health: int = 1) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": bomber_ctl, "x": 1500.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": fighter_ctl, "x": 1200.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.units["bomber"].health = health
	w.units["fighter"].health = 99
	return w

# Ready everyone and resolve; {} (and a failure) if the turn did not resolve.
func _turn(w: World) -> Dictionary:
	for who: String in w.participants():
		w.commit(who)
	var res := w.resolve()
	check(not res.is_empty(), "turn %d resolves: %s" % [w.turn, w.last_error])
	return res

func _event(res: Dictionary, type: String, unit: String = "bomber") -> Dictionary:
	for ev: Dictionary in res.get("events", []):
		if ev["type"] == type and ev.get("unit") == unit:
			return ev
	return {}

# A seed whose first turn takes the bomber down with `fate` at a t within [min_td, max_td]; -1 if none.
func _find_seed(bomber_ctl: String, fighter_ctl: String, band: String, fate: String, min_td: float, max_td: float) -> int:
	for s in range(1, 300):
		var w := _victim_world(s, bomber_ctl, fighter_ctl, band)
		var ev := _event(_turn(w), "down")
		if not ev.is_empty() and ev["fate"] == fate and float(ev["t"]) >= min_td and float(ev["t"]) <= max_td:
			return s
	check(false, "a seed gives the fate %s in the %s band between t = %.1f and %.1f" % [fate, band, min_td, max_td])
	return -1

# The circle the vision holds for a unit, or {}.
func _circle(v: FogVision, id: String) -> Dictionary:
	for c: Dictionary in v.circles:
		if c.id == id:
			return c
	return {}

# --- data ---------------------------------------------------------------------------------

func _data() -> bool:
	var rules := SightRules.new()
	if not check(rules.ok(), "data/sim/sight.json loads: %s" % [rules.errors]):
		return false
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(SightRules.PATH))
	if not check(raw is Dictionary, "sight.json parses"):
		return false
	var keys: Array = []
	for k: Variant in (raw as Dictionary).keys():
		if not str(k).begins_with("_"):
			keys.append(str(k))
	keys.sort()
	eq(keys, ["falling_factor", "falling_floor_m", "falling_reference_height_m"], "the file holds exactly the fields the rule reads")
	for k: String in keys:
		var rec: Dictionary = raw[k]
		check(rec.get("_proposed") == true, "%s is labelled proposed" % k)
		check(str(rec.get("_reason", "")).contains("Alex 2026-10-10"), "%s carries Alex's words in its _reason" % k)
	check(str(raw["falling_factor"]["_reason"]).contains("reduced distance until it hits"), "falling_factor quotes 'reduced distance until it hits'")
	check(str(raw["falling_reference_height_m"]["_reason"]).contains("take height into account"), "falling_reference_height_m quotes 'take height into account'")
	check(str(raw["_about"]).contains("loose the fog"), "the file's _about quotes 'loose the fog'")
	_factor = float(raw["falling_factor"]["value"])
	_ref = float(raw["falling_reference_height_m"]["value"])
	_floor = float(raw["falling_floor_m"]["value"])
	check(_factor > 0.0 and _factor <= 1.0, "falling_factor is a share (%s)" % _factor)
	check(_floor > 0.0 and _floor < _factor * REF_BASE, "the floor is a small positive radius (%s)" % _floor)
	near(rules.falling_factor, _factor, 0.0, "the rule reads falling_factor")
	near(rules.falling_reference_m, _ref, 0.0, "the rule reads falling_reference_height_m")
	near(rules.falling_floor_m, _floor, 0.0, "the rule reads falling_floor_m")
	# Broken data is an error, never a silent default.
	check(not SightRules.new({}, true).ok(), "an empty source is an error")
	check(not SightRules.new({"falling_factor": {"value": 0.5}, "falling_reference_height_m": {"value": 400, "_proposed": true, "_reason": "x"}, "falling_floor_m": {"value": 40, "_proposed": true, "_reason": "x"}}, true).ok(), "a record that says neither where it came from nor why is an error")
	check(not SightRules.new({"falling_factor": {"value": 1.5, "_proposed": true, "_reason": "x"}, "falling_reference_height_m": {"value": 400, "_proposed": true, "_reason": "x"}, "falling_floor_m": {"value": 40, "_proposed": true, "_reason": "x"}}, true).ok(), "a falling share above 1 is an error")
	var combat := CombatRules.new()
	if not check(combat.ok(), "combat.json loads: %s" % [combat.errors]):
		return false
	_descent = combat.fall_descent
	check(FogVision.new().ok(), "FogVision loads with the sight rules")
	_sections.append("data")
	return true

# --- the rule on hand-made units ------------------------------------------------------------

func _unit(down: bool, fate: String, down_at: float, fall_h: float) -> Unit:
	var u := Unit.new()
	u.down = down
	u.fate = fate
	u.down_at = down_at
	u.fall_height_m = fall_h
	return u

func _rule_table() -> void:
	var r := SightRules.new()
	# A live unit: untouched, whatever else is asked.
	var live := _unit(false, "", NAN, NAN)
	for t: float in [-1.0, 0.0, 2.0, 5.0]:
		near(r.radius_m(live, REF_BASE, t, 1000.0), REF_BASE, 0.0, "a live unit sees its full radius (t = %s)" % t)
	# Exploded and destroyed: full until down_at, then nothing.
	for fate: String in [Unit.FATE_EXPLODED, Unit.FATE_DESTROYED]:
		var u := _unit(true, fate, 2.0, NAN)
		near(r.radius_m(u, REF_BASE, 1.999, 400.0), REF_BASE, 0.0, "%s: still sees just before it went down" % fate)
		near(r.radius_m(u, REF_BASE, 0.0, 400.0), REF_BASE, 0.0, "%s: ... and at the start of the turn" % fate)
		near(r.radius_m(u, REF_BASE, 2.0, 400.0), 0.0, 0.0, "%s: nothing at the moment it went down" % fate)
		near(r.radius_m(u, REF_BASE, 4.9, 400.0), 0.0, 0.0, "%s: nothing after" % fate)
		near(r.radius_m(u, REF_BASE), 0.0, 0.0, "%s: nothing as it stands now" % fate)
		var earlier := _unit(true, fate, NAN, NAN)
		near(r.radius_m(earlier, REF_BASE, 0.0, 400.0), 0.0, 0.0, "%s from an earlier turn: nothing even at t = 0" % fate)
		near(r.radius_m(earlier, REF_BASE), 0.0, 0.0, "%s from an earlier turn: nothing now" % fate)
	# Down with no fate at all (marked by hand): nothing.
	near(r.radius_m(_unit(true, "", NAN, NAN), REF_BASE, 0.0), 0.0, 0.0, "down with no fate sees nothing")
	# Out of control: full before it went down; then a radius in proportion to its height.
	var falling := _unit(true, Unit.FATE_OUT_OF_CONTROL, 1.0, 300.0)
	near(r.radius_m(falling, REF_BASE, 0.5, 400.0), REF_BASE, 0.0, "out of control: before it went down it sees its full radius")
	var cap := REF_BASE * _factor
	for h: float in [1000.0, _ref, _ref * 0.75, _ref * 0.5, _ref * 0.25, _ref * 0.1]:
		near(r.radius_m(falling, REF_BASE, 1.0, h), _expect(REF_BASE, h), 1e-9, "falling at %.0f m sees %.1f m" % [h, _expect(REF_BASE, h)])
	near(r.radius_m(falling, REF_BASE, 1.0, _ref), cap, 1e-9, "at the reference height it sees falling_factor x its sight")
	near(r.radius_m(falling, REF_BASE, 1.0, 2.0 * _ref), cap, 1e-9, "higher than the reference it sees no more than that")
	near(r.radius_m(falling, REF_BASE, 1.0, 0.5 * _ref) * 2.0, cap, 1e-9, "at half the height, half the radius")
	near(r.radius_m(falling, REF_BASE, 1.0, 0.001), _floor, 1e-9, "a few millimetres up it sees the floor, not nothing")
	near(r.radius_m(falling, REF_BASE, 1.0, 0.0), 0.0, 0.0, "at the ground it sees nothing")
	near(r.radius_m(falling, REF_BASE, 1.0, -5.0), 0.0, 0.0, "below the ground (a step past the crash) nothing")
	near(r.radius_m(falling, REF_BASE), _expect(REF_BASE, 300.0), 1e-9, "as it stands now it uses its own fall_height_m")
	near(r.radius_m(_unit(true, Unit.FATE_OUT_OF_CONTROL, NAN, NAN), REF_BASE), 0.0, 0.0, "falling with no known height sees nothing")
	var last := INF
	for i in 400:
		var rr := r.radius_m(falling, REF_BASE, 1.0, 400.0 - float(i))
		check(rr <= last + 1e-12, "the radius never grows as the plane comes down (%.1f m: %.3f after %.3f)" % [400.0 - float(i), rr, last])
		last = rr
	# A floor above the cap never lifts the radius over the cap.
	near(r.radius_m(falling, 50.0, 1.0, 1.0), 50.0 * _factor, 1e-9, "a small sight is not lifted by the floor above falling_factor x sight")
	# Crashed: nothing, but a plane that crashed THIS turn still falls at t before the crash.
	near(r.radius_m(_unit(true, Unit.FATE_CRASHED, NAN, 0.0), REF_BASE, 0.0, 0.0), 0.0, 0.0, "crashed in an earlier turn: nothing at t = 0")
	near(r.radius_m(_unit(true, Unit.FATE_CRASHED, NAN, 0.0), REF_BASE), 0.0, 0.0, "crashed: nothing now")
	var crashed_now := _unit(true, Unit.FATE_CRASHED, 1.0, 0.0)
	near(r.radius_m(crashed_now, REF_BASE, 0.5, 400.0), REF_BASE, 0.0, "crashed this turn: still flying before it went down")
	near(r.radius_m(crashed_now, REF_BASE, 1.5, 60.0), _expect(REF_BASE, 60.0), 1e-9, "crashed this turn: still falling, still seeing, before the crash")
	near(r.radius_m(crashed_now, REF_BASE, 3.0, 0.0), 0.0, 0.0, "crashed this turn: nothing once its height is 0")
	near(r.radius_m(crashed_now, REF_BASE), 0.0, 0.0, "crashed this turn: nothing as it stands at the end")
	# Not loaded: nothing for a falling plane rather than a made-up number.
	near(SightRules.new({}, true).radius_m(falling, REF_BASE, 1.0, 300.0), 0.0, 0.0, "without the data a falling plane sees nothing")
	_sections.append("rule")

# --- the player's fog ---------------------------------------------------------------------------

# A live plane: the circle is its type's sight at every t, and where World.sample puts it.
func _fog_live() -> void:
	var w := _victim_world(1, "player", "ai", "medium", 999)
	_turn(w)
	var v := FogVision.new()
	var base := _sight_from_file("bomber") * v.sight_scale
	for t: float in [-1.0, 0.0, 1.7, 3.0, 5.0]:
		v.update_from_world(w, t, "history")
		var c := _circle(v, "bomber")
		if check(not c.is_empty(), "a live plane reveals at t = %s" % t):
			near(c.r, base, 0.0, "... with its full radius (t = %s)" % t)
			if t >= 0.0:
				var s: Dictionary = w.sample("bomber", t, "history")
				near(c.x, float(s["x"]), 1e-9, "... centred where World.sample puts it (t = %s)" % t)
	_sections.append("live")

# An exploding plane stops revealing at the moment it went down.
func _fog_exploded() -> void:
	var seed_value := _find_seed("player", "ai", "medium", "exploded", 0.5, 4.5)
	if seed_value < 0:
		return
	var w := _victim_world(seed_value, "player", "ai", "medium")
	_turn(w)
	var u: Unit = w.units["bomber"]
	var td := u.down_at
	var v := FogVision.new()
	var base := v.sight_radius_m(u)
	check(u.fate == Unit.FATE_EXPLODED and is_finite(td), "it exploded at t = %.3f" % td)
	v.update_from_world(w, td - 1e-6, "history")
	var before := _circle(v, "bomber")
	if check(not before.is_empty(), "it reveals up to the moment it went down"):
		near(before.r, base, 0.0, "... with its full radius")
		# A point 40 m inside the edge, on the side away from the other plane (nobody else reveals anyway).
		check(v.is_visible_xy(before.x + base - 40.0, before.y), "so the ground near it is in sight")
	for t: float in [td, td + 0.01, 0.5 * (td + 5.0), 4.99, 5.0]:
		v.update_from_world(w, t, "history")
		check(_circle(v, "bomber").is_empty(), "it reveals nothing at t = %.3f (down at %.3f)" % [t, td])
		check(v.circles.is_empty(), "... and nothing else reveals: the fog is closed at t = %.3f" % t)
		check(not v.is_visible_xy(float(before.get("x", 0.0)), float(before.get("y", 0.0))), "... the ground it was over is dark at t = %.3f" % t)
	v.update_from_world(w)
	check(v.circles.is_empty(), "as it stands (no playback time) it reveals nothing")
	# The next turn it is a wreck from the first moment.
	w.begin_turn()
	_turn(w)
	check(is_nan(u.down_at), "down_at is NAN in the next turn")
	for t: float in [-1.0, 0.0, 2.0, 5.0]:
		v.update_from_world(w, t, "history")
		check(v.circles.is_empty(), "a wreck from an earlier turn reveals nothing (t = %s)" % t)
	_sections.append("exploded")

# A plane out of control keeps a reduced circle that shrinks with its height, turn after turn, and
# loses it at the crash.
func _fog_falling() -> void:
	var seed_value := _find_seed("player", "ai", "medium", "out_of_control", 0.3, 4.5)
	if seed_value < 0:
		return
	var w := _victim_world(seed_value, "player", "ai", "medium")
	var u: Unit = w.units["bomber"]
	var v := FogVision.new()
	var base := v.sight_radius_m(u)
	var td := NAN
	var crash_turn := -1
	var falling_samples := 0
	var proportional := 0
	var floored := 0
	var biggest_fall := 0.0
	var last_r := INF
	var edge_checked := false
	for turn_no in range(1, 9):
		var h_start := u.fall_height_m          # NAN in turn 1
		if turn_no > 1:
			w.begin_turn()
		var res := _turn(w)
		if turn_no == 1:
			td = u.down_at
			check(u.fate == Unit.FATE_OUT_OF_CONTROL and is_finite(td), "turn 1: out of control at t = %.3f" % td)
		var crash := _event(res, "crash")
		# When the height reaches 0 in this turn, by the fall rate.
		var t_crash := INF
		if turn_no == 1:
			if td + 400.0 / _descent <= 5.0:       # from the medium band, 400 m
				t_crash = td + 400.0 / _descent
		elif h_start / _descent <= 5.0:
			t_crash = h_start / _descent
		if t_crash < INF:
			if check(not crash.is_empty(), "turn %d: the crash event is there" % turn_no):
				near(float(crash["t"]), t_crash, 1e-6, "turn %d: it hits the ground at t = %.3f" % [turn_no, t_crash])
				crash_turn = turn_no
		else:
			check(crash.is_empty(), "turn %d: still falling at the end, no crash event" % turn_no)
		var times: Array[float] = []
		for i in 21:
			times.append(0.25 * float(i))
		if turn_no == 1:
			times.append(td)      # the very moment it went down
			times.sort()
		for t: float in times:
			var h := NAN
			var expected := 0.0
			if turn_no == 1 and t < td:
				expected = base
			else:
				h = 400.0 - _descent * (t - td) if turn_no == 1 else h_start - _descent * t
				if t > t_crash - 1e-6 and t < t_crash + 1e-6:
					continue           # the instant of the crash itself is a rounding matter
				expected = 0.0 if t > t_crash else _expect(base, h)
			v.update_from_world(w, t, "history")
			var c := _circle(v, "bomber")
			if expected <= 0.0:
				check(c.is_empty(), "turn %d t = %.2f: no circle (it has crashed)" % [turn_no, t])
				continue
			if not check(not c.is_empty(), "turn %d t = %.2f: a circle (height %.1f m)" % [turn_no, t, h]):
				continue
			near(c.r, expected, 1e-6, "turn %d t = %.2f: radius %.2f m at height %.1f m" % [turn_no, t, expected, h])
			var s: Dictionary = w.sample("bomber", t, "history")
			near(c.x, float(s["x"]), 1e-9, "turn %d t = %.2f: centred on the falling plane" % [turn_no, t])
			if turn_no == 1 and t < td:
				continue
			falling_samples += 1
			biggest_fall = maxf(biggest_fall, c.r)
			check(c.r < base, "turn %d t = %.2f: a falling plane sees less than a flying one (%.1f < %.1f)" % [turn_no, t, c.r, base])
			check(c.r <= last_r + 1e-9, "turn %d t = %.2f: the radius never grows on the way down (%.3f after %.3f)" % [turn_no, t, c.r, last_r])
			last_r = c.r
			if h < _ref and c.r > _floor + 1e-6:
				proportional += 1
				near(c.r / h, base * _factor / _ref, 1e-9, "turn %d t = %.2f: below the reference height the radius is in proportion to the height" % [turn_no, t])
			if c.r <= _floor + 1e-6:
				floored += 1
			if not edge_checked and c.r > 100.0:
				edge_checked = true
				check(v.is_visible_xy(c.x + c.r - 0.5, c.y), "the ground just inside the shrunken edge is in sight")
				check(not v.is_visible_xy(c.x + c.r + 0.5, c.y), "the ground just outside it is not")
		# At the end of the turn, as it stands.
		v.update_from_world(w)
		var now := _circle(v, "bomber")
		if u.fate == Unit.FATE_CRASHED:
			check(now.is_empty(), "turn %d: crashed, it reveals nothing as it stands" % turn_no)
			break
		if check(not now.is_empty(), "turn %d: still falling at the end, it reveals" % turn_no):
			near(now.r, _expect(base, u.fall_height_m), 1e-6, "turn %d: as it stands it uses its fall height (%.1f m)" % [turn_no, u.fall_height_m])
	check(crash_turn > 0 and u.fate == Unit.FATE_CRASHED, "it crashed within eight turns (turn %d)" % crash_turn)
	check(falling_samples >= 12, "enough falling samples were checked (%d)" % falling_samples)
	check(proportional >= 3, "enough samples below the reference height were checked for proportion (%d)" % proportional)
	near(biggest_fall, base * _factor, 1e-6, "the biggest circle of the fall is falling_factor x its sight")
	# After the crash turn: gone for good.
	w.begin_turn()
	_turn(w)
	for t: float in [-1.0, 0.0, 2.5, 5.0]:
		v.update_from_world(w, t, "history")
		check(v.circles.is_empty(), "the turn after the crash it reveals nothing (t = %s)" % t)
	print("[fog_downed] falling bomber: down at t = %.2f in turn 1, crashed in turn %d; %d falling samples (%d in proportion, %d on the floor)" % [td, crash_turn, falling_samples, proportional, floored])
	_sections.append("falling")

# A plane that crashes in the turn it went down in: its fall is still seen at t, before the crash.
func _fog_crash_in_the_turn() -> void:
	var fall_s := 120.0 / _descent
	var seed_value := _find_seed("player", "ai", "low", "out_of_control", 0.3, 4.9 - fall_s)
	if seed_value < 0:
		return
	var w := _victim_world(seed_value, "player", "ai", "low")
	var res := _turn(w)
	var u: Unit = w.units["bomber"]
	var td := float(_event(res, "down")["t"])
	var tc := td + fall_s
	var v := FogVision.new()
	var base := v.sight_radius_m(u)
	check(u.fate == Unit.FATE_CRASHED, "crashed within the turn it went down in")
	near(float(_event(res, "crash")["t"]), tc, 1e-6, "at t = %.3f" % tc)
	var on_floor := false
	var in_air := 0
	for i in 101:
		var t := 0.05 * float(i)
		if absf(t - td) < 1e-6 or absf(t - tc) < 1e-6:
			continue
		v.update_from_world(w, t, "history")
		var c := _circle(v, "bomber")
		if t < td:
			if check(not c.is_empty(), "t = %.2f: still flying, it reveals" % t):
				near(c.r, base, 0.0, "t = %.2f: ... fully" % t)
		elif t < tc:
			in_air += 1
			if check(not c.is_empty(), "t = %.2f: falling (the crash is at %.2f), it still reveals" % [t, tc]):
				near(c.r, _expect(base, 120.0 - _descent * (t - td)), 1e-6, "t = %.2f: ... by its height" % t)
				on_floor = on_floor or absf(c.r - _floor) < 1e-9
		else:
			check(c.is_empty(), "t = %.2f: after the crash nothing" % t)
	v.update_from_world(w, tc - 0.04, "history")
	near(_circle(v, "bomber").get("r", -1.0), _floor, 1e-9, "40 ms before it hits it still sees the floor, not nothing")
	check(on_floor and in_air >= 10, "the floor was reached in the air (%d samples in the air)" % in_air)
	v.update_from_world(w)
	check(v.circles.is_empty(), "as it stands (crashed) it reveals nothing")
	_sections.append("crash")

# A destroyed radio tower and battery (real bombs) stop revealing at the bomb.
func _fog_ground() -> void:
	var w := BombWorlds.world(3, "medium", true)
	# An axis plane under a player's orders, so the axis side (tower, batteries) is a revealing side.
	w.add_unit({"id": "scout", "type": "light_fighter", "side": "axis", "controller": "player", "x": 4600.0, "y": 4600.0, "heading": 0.0, "altitude_band": "medium", "speed": 100.0})
	w.units["tower"].health = 3
	w.units["aa0"].health = 3
	var v := FogVision.new()
	v.update_from_world(w)
	var tower_r := _sight_from_file("radio_tower") * v.sight_scale
	var aa_r := _sight_from_file("anti_aircraft_battery") * v.sight_scale
	if check(not _circle(v, "tower").is_empty() and not _circle(v, "aa0").is_empty() and not _circle(v, "aa1").is_empty(), "the tower and both batteries reveal while they stand"):
		near(_circle(v, "tower").r, tower_r, 0.0, "the tower's radius is its type's")
		near(_circle(v, "aa0").r, aa_r, 0.0, "the battery's radius is its type's")
	# The tower dies to a bomb at 2 s, battery aa0 to one at 1 s; aa1 is not hit.
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, BombWorlds.TOWER.x, BombWorlds.TOWER.y, 2.0, 0), BombWorlds.record(w, 2250.0, 2200.0, 1.0, 1)])
	BombWorlds.turn(w)
	var tower: Unit = w.units["tower"]
	var aa0: Unit = w.units["aa0"]
	check(tower.down and tower.fate == Unit.FATE_DESTROYED and aa0.down and aa0.fate == Unit.FATE_DESTROYED, "the bombs destroyed the tower and the battery")
	check(not w.units["aa1"].down, "the other battery stands")
	near(tower.down_at, 2.0, 1e-9, "the tower went down at 2 s")
	near(aa0.down_at, 1.0, 1e-9, "the battery went down at 1 s")
	v.update_from_world(w, 0.9, "history")
	check(not _circle(v, "tower").is_empty() and not _circle(v, "aa0").is_empty(), "t = 0.9: both still reveal")
	v.update_from_world(w, 1.5, "history")
	check(not _circle(v, "tower").is_empty(), "t = 1.5: the tower still reveals")
	check(_circle(v, "aa0").is_empty(), "t = 1.5: the battery has been destroyed and reveals nothing")
	check(not _circle(v, "aa1").is_empty(), "t = 1.5: the battery that stands still does")
	v.update_from_world(w, 2.0, "history")
	check(_circle(v, "tower").is_empty() and _circle(v, "aa0").is_empty(), "t = 2.0: neither reveals")
	v.update_from_world(w)
	check(_circle(v, "tower").is_empty() and _circle(v, "aa0").is_empty(), "as they stand: neither reveals")
	check(not _circle(v, "aa1").is_empty() and not _circle(v, "scout").is_empty() and not _circle(v, "bomber").is_empty(), "the live units are untouched")
	near(_circle(v, "aa1").r, aa_r, 0.0, "... fully")
	w.begin_turn()
	BombWorlds.turn(w)
	for t: float in [-1.0, 0.0, 3.0]:
		v.update_from_world(w, t, "history")
		check(_circle(v, "tower").is_empty() and _circle(v, "aa0").is_empty(), "the next turn: still nothing from the ruins (t = %s)" % t)
	_sections.append("ground")

# --- the enemy AI -----------------------------------------------------------------------------

# Does the AI-controlled `observer` know the player's `target` when it stands `dist` metres east of it?
func _ai_knows(w: World, observer: String, target: String, dist: float) -> bool:
	var o: Unit = w.units[observer]
	var t: Unit = w.units[target]
	t.x = o.x + dist
	t.y = o.y
	var sense := AiSense.new()
	sense.update(w, 3)
	return sense.knows(target)

# The AI spots at the radius the fog reveals to, for the unit as it stands now: within it known, outside not.
func _ai_agrees(w: World, observer: String, target: String, label: String) -> float:
	var v := FogVision.new()
	v.sight_scale = 1.0       # the fog's scale knob is the fog's; the AI has none
	var r := v.revealing_radius_m(w.units[observer])
	if r > 1.0:
		check(_ai_knows(w, observer, target, r - 0.5), "%s: the AI sees a plane %.1f m away, inside the %.1f m the fog reveals to" % [label, r - 0.5, r])
	check(not _ai_knows(w, observer, target, r + 0.5), "%s: ... and not one %.1f m away, outside it" % [label, r + 0.5])
	return r

func _ai_side() -> void:
	var live_sight := _sight_from_file("bomber")
	# A live AI bomber: as it always was.
	var w0 := _victim_world(1, "ai", "player", "medium", 999)
	_turn(w0)
	near(_ai_agrees(w0, "bomber", "fighter", "live"), live_sight, 1e-9, "a live unit sees its type's sight_range_m")

	# Exploded: sees nothing, however near.
	var ex_seed := _find_seed("ai", "player", "medium", "exploded", 0.5, 4.5)
	if ex_seed >= 0:
		var w1 := _victim_world(ex_seed, "ai", "player", "medium")
		_turn(w1)
		check(w1.units["bomber"].fate == Unit.FATE_EXPLODED, "the AI's bomber exploded")
		near(_ai_agrees(w1, "bomber", "fighter", "exploded"), 0.0, 0.0, "an exploded unit has no radius")
		check(not _ai_knows(w1, "bomber", "fighter", 5.0), "exploded: a plane 5 m from the wreck is not seen")

	# Falling, then crashed.
	var fall_seed := _find_seed("ai", "player", "medium", "out_of_control", 0.3, 4.5)
	if fall_seed >= 0:
		var w2 := _victim_world(fall_seed, "ai", "player", "medium")
		var u: Unit = w2.units["bomber"]
		_turn(w2)
		check(u.fate == Unit.FATE_OUT_OF_CONTROL, "the AI's bomber is out of control")
		var r := _ai_agrees(w2, "bomber", "fighter", "falling")
		near(r, _expect(live_sight, u.fall_height_m), 1e-9, "falling at %.1f m it sees %.1f m" % [u.fall_height_m, r])
		check(r > 0.0 and r < live_sight, "a falling unit's sight is smaller than a live one's")
		var prev := r
		var turns := 1
		while u.fate != Unit.FATE_CRASHED and turns < 8:
			w2.begin_turn()
			_turn(w2)
			turns += 1
			if u.fate != Unit.FATE_CRASHED:
				var r2 := _ai_agrees(w2, "bomber", "fighter", "falling, turn %d" % turns)
				check(r2 < prev + 1e-9, "its sight shrank as it came down (%.1f then %.1f)" % [prev, r2])
				prev = r2
		check(u.fate == Unit.FATE_CRASHED, "the AI's bomber crashed (turn %d)" % turns)
		near(_ai_agrees(w2, "bomber", "fighter", "crashed"), 0.0, 0.0, "a crashed unit has no radius")
		check(not _ai_knows(w2, "bomber", "fighter", 5.0), "crashed: a plane 5 m away is not seen")

	# A destroyed tower and a destroyed battery (the AI's) see nothing; standing, they see their sight_range_m.
	# One ground unit alone in each world, so no other observer spots the plane for it.
	for kind: String in ["radio_tower", "anti_aircraft_battery"]:
		var w3 := World.new()
		w3.rng_seed = 3
		w3.quiet = true
		w3.add_player("local")
		w3.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
		w3.add_unit({"id": "ground", "type": kind, "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
		w3.units["ground"].health = 3
		near(_ai_agrees(w3, "ground", "bomber", "%s, standing" % kind), _sight_from_file(kind), 1e-9, "a standing %s sees its sight_range_m" % kind)
		w3.units["bomber"].x = 400.0
		BombWorlds.drop_bombs(w3, [BombWorlds.record(w3, 2500.0, 2500.0, 1.0, 0)])
		BombWorlds.turn(w3)
		check(w3.units["ground"].down and w3.units["ground"].fate == Unit.FATE_DESTROYED, "the bomb destroyed the AI's %s" % kind)
		near(_ai_agrees(w3, "ground", "bomber", "%s, destroyed" % kind), 0.0, 0.0, "a destroyed %s has no radius" % kind)
		check(not _ai_knows(w3, "ground", "bomber", 5.0), "destroyed %s: a plane 5 m away is not seen" % kind)
	_sections.append("ai")

# --- line of sight on ------------------------------------------------------------------------

# A vision with line of sight ON over the real terrain; sheds swept whole (no frame budget), so
# a shed is always the one for this very frame.
func _los_vision() -> FogVision:
	var v := FogVision.new()
	v.attach_terrain(_terrain)
	v.set_line_of_sight(FogVision.LOS_TERRAIN)
	v.budget_ms = 0.0
	return v

# The height the resolved fall must have at t of turn `turn_no`, from the fall rate (not from World.sample).
func _fall_h(turn_no: int, t: float, td: float, h_start: float) -> float:
	return 400.0 - _descent * (t - td) if turn_no == 1 else h_start - _descent * t

func _los_falling() -> void:
	_terrain = Terrain.new(TERRAIN_SEED)
	if not check(_terrain.ok(), "terrain loads: %s" % [_terrain.errors]):
		return
	var seed_value := _find_seed("player", "ai", "medium", "out_of_control", 0.3, 2.0)
	if seed_value < 0:
		return
	_los_resolved(seed_value)
	_los_hill(seed_value)

# A resolved fall over the real terrain, line of sight on: the eye follows the height, and the shed is reused.
func _los_resolved(seed_value: int) -> void:
	var w := _victim_world(seed_value, "player", "ai", "medium")
	var u: Unit = w.units["bomber"]
	var va := _los_vision()       # sampled coarsely: every sample is a fresh shed
	var vc := _los_vision()       # sampled at 60 Hz: the sheds are reused
	check(va.ok() and vc.ok() and va.los_on(), "the vision loads with line of sight on over the terrain: %s %s" % [va.errors, vc.errors])
	var base := va.sight_radius_m(u)
	var td := NAN
	var coarse := 0
	var frames := 0
	var computes := 0
	var drop := 0.0
	var path := 0.0
	var dr := 0.0
	var prev := {}
	var crashed := false
	for turn_no in range(1, 9):
		var h_start := u.fall_height_m          # NAN in turn 1
		if turn_no > 1:
			w.begin_turn()
		_turn(w)
		if turn_no == 1:
			td = u.down_at
		# Coarse: the eye is the sampled height, above the ground there; the shed was swept from it.
		var times: Array[float] = []
		for i in 21:
			times.append(0.25 * float(i))
		if turn_no == 1:
			times.append(td)
			times.sort()
		for t: float in times:
			if turn_no == 1 and t < td:
				continue
			var h := _fall_h(turn_no, t, td, h_start)
			if h <= 1e-6:
				continue
			va.update_from_world(w, t, "history")
			var c := _circle(va, "bomber")
			if not check(not c.is_empty() and c.has("shed"), "turn %d t = %.2f: a circle with a shed" % [turn_no, t]):
				continue
			var agl := maxf(h - va.ground_at(c.x, c.y), 0.0)
			near(c.eye_agl, agl, 1e-6, "turn %d t = %.2f: the eye is %.1f m above the ground (height %.1f m)" % [turn_no, t, agl, h])
			var shed: FogViewshed.Shed = c.shed
			near(shed.eye_agl, agl, 1e-6, "turn %d t = %.2f: the shed was swept from that eye" % [turn_no, t])
			near(shed.eye_abs, va.ground_at(c.x, c.y) + agl, 1e-6, "turn %d t = %.2f: ... at that height above sea level" % [turn_no, t])
			coarse += 1
		# As it stands at the end of the turn (no playback time): its fall height, not its band's.
		va.update_from_world(w)
		var rest := _circle(va, "bomber")
		if u.fate == Unit.FATE_CRASHED:
			check(rest.is_empty(), "turn %d: crashed, no circle as it stands" % turn_no)
			crashed = true
		elif check(not rest.is_empty(), "turn %d: still falling, a circle as it stands" % turn_no):
			var agl_rest := maxf(u.fall_height_m - va.ground_at(rest.x, rest.y), 0.0)
			near(rest.eye_agl, agl_rest, 1e-6, "turn %d: as it stands the eye is at its fall height (%.1f m, %.1f m above the ground), not at the band's" % [turn_no, u.fall_height_m, agl_rest])
			coarse += 1
		# Fine: 60 frames a second, the shed kept while height, place and radius stay within the data's tolerances.
		for i in 300:
			var t := float(i) / 60.0
			var before := int(vc.stats.computed)
			vc.update_from_world(w, t, "history")
			var c := _circle(vc, "bomber")
			if c.is_empty():
				break
			if turn_no == 1 and t < td:
				continue
			var h := _fall_h(turn_no, t, td, h_start)
			near(c.r, _expect(base, h), 1e-6, "turn %d frame %d: the radius is exact whatever the shed" % [turn_no, i])
			check(not vc.is_visible_xy(c.x + c.r + 3.0, c.y) and not vc.is_visible_xy(c.x, c.y - c.r - 3.0), "turn %d frame %d: nothing beyond the circle is in sight, a stale shed or not" % [turn_no, i])
			frames += 1
			computes += int(vc.stats.computed) - before
			var pos := Vector2(c.x, c.y)
			if not prev.is_empty():
				path += pos.distance_to(prev.pos)
				drop += float(prev.h) - h
				dr += absf(float(prev.r) - float(c.r))
			prev = {"pos": pos, "h": h, "r": c.r}
		if crashed:
			break
	check(crashed and coarse >= 12, "the fall ran to the crash (%d coarse samples)" % coarse)
	var bound := 2.0 + ceilf(drop / vc.recompute_height_m) + ceilf(path / vc.recompute_move_m) + ceilf(dr / vc.recompute_move_m)
	check(frames >= 150, "enough falling frames at 60 Hz (%d)" % frames)
	check(float(computes) <= bound, "the shed is swept only when the height, place or radius has moved by the tolerances: %d sweeps in %d frames (bound %.0f: %.0f m of height / %s, %.0f m of path / %s, %.0f m of radius / %s)" % [computes, frames, bound, drop, vc.recompute_height_m, path, vc.recompute_move_m, dr, vc.recompute_move_m])
	check(float(computes) < 0.6 * float(frames), "... and far fewer than one a frame (%d in %d)" % [computes, frames])
	print("[fog_downed] LOS on: a falling bomber over the real terrain, %d frames at 60 Hz, %d sheds swept (one every %.1f frames); %.0f m of height, %.0f m of path" % [frames, computes, float(frames) / maxf(float(computes), 1.0), drop, path])
	_sections.append("los_eye")
	_sections.append("los_reuse")

# A frozen plane at a real plateau edge, lowered step by step: the lip hides the low ground beyond once the eye is low.
func _los_hill(seed_value: int) -> void:
	var site := FogSites.find_plateau_edge(_terrain, 950.0, 40.0, 8.0)
	if not check(float(site.get("score", -INF)) > -INF, "a plateau edge was found in the real terrain (%s)" % site.get("note", "")):
		return
	var w := _victim_world(seed_value, "player", "ai", "medium")
	var u: Unit = w.units["bomber"]
	_turn(w)
	check(u.fate == Unit.FATE_OUT_OF_CONTROL, "the bomber is out of control (a real fate)")
	var P: Vector2 = site.p
	var dir: Vector2 = site.dir
	var D: float = site.cliff_m
	var lvl: int = site.level
	var top: float = _terrain.heights_m[lvl]
	# T: ground a few metres past the lip, lower than the plateau.
	var T := Vector2.INF
	var k_t := 0.0
	for k: float in [15.0, 12.0, 10.0, 8.0]:
		var q := P + dir * (D + k)
		if _terrain.level_at(q.x, q.y) < lvl:
			T = q
			k_t = k
			break
	if not check(T != Vector2.INF, "ground below the lip was found"):
		return
	var g_t: float = _terrain.heights_m[_terrain.level_at(T.x, T.y)]
	# The eye (above the plateau) at which the lip just hides T: the sight line over the lip, D back, meets
	# the ground g_t below the plateau's top k_t beyond it when e = D x (top - g_t) / k_t.
	var thr := D * (top - g_t) / k_t
	var far := P + dir * (D + 120.0)         # low ground well beyond the dead ground, 120 m past the lip
	var dist_t := P.distance_to(T)
	var dist_far := P.distance_to(far)
	print("[fog_downed] plateau edge at %s: level %d (%.0f m), lip %.1f m ahead; T %.0f m past it (ground %.0f m); the lip hides T below an eye of %.1f m above the plateau" % [P, lvl, top, D, k_t, g_t, thr])
	var v := _los_vision()
	var base := v.sight_radius_m(u)
	var steps: Array = [
		[400.0, true], [200.0, true], [top + 100.0, true], [top + 2.0 * thr, true], [top + 0.5 * thr, false], [top + 0.2 * thr, false],
	]
	var radius_hid := 0
	var far_seen := 0
	var checked := 0
	# Frozen where the edge is, as if it had gone down in an earlier turn: the sampler puts it at its x, y and fall height.
	u.x = P.x
	u.y = P.y
	u.down_at = NAN
	u.history = []
	for st: Array in steps:
		var h_abs: float = st[0]
		var want_t: bool = st[1]
		u.fall_height_m = h_abs
		for t: float in [-1.0, 0.5]:
			v.update_from_world(w, t, "history")
			var c := _circle(v, "bomber")
			var tag := "height %.1f m (%.1f m over the plateau), t = %s" % [h_abs, h_abs - top, t]
			if not check(not c.is_empty() and c.has("shed"), "%s: a circle with a shed" % tag):
				continue
			near(c.eye_agl, h_abs - top, 1e-6, "%s: the eye is its current height" % tag)
			near(c.r, _expect(base, h_abs), 1e-6, "%s: the radius is the falling rule's" % tag)
			check(c.r >= dist_t, "%s: the radius (%.1f m) still covers the ground behind the lip (%.1f m away), so the lip, not the radius, decides" % [tag, c.r, dist_t])
			eq(v.is_visible(T), want_t, "%s: the ground %.0f m past the lip is %s" % [tag, k_t, "visible" if want_t else "hidden"])
			eq(v.engine().ground_visible_from(P, c.eye_agl, T), want_t, "%s: the viewshed engine, one exact ray, agrees" % tag)
			# The radius rule on top: the far ground is seen only inside the radius, though the line is clear.
			var los_far: bool = v.engine().ground_visible_from(P, c.eye_agl, far)
			eq(v.is_visible(far), los_far and c.r >= dist_far, "%s: the far ground (%.0f m) is in sight exactly when the line is clear AND it is inside the radius (%.1f m)" % [tag, dist_far, c.r])
			if los_far and c.r < dist_far:
				radius_hid += 1
			if los_far and c.r >= dist_far:
				far_seen += 1
			checked += 1
	check(checked == 2 * steps.size(), "every step was checked (%d)" % checked)
	check(radius_hid >= 2 and far_seen >= 2, "far ground was seen while the radius reached it (%d) and hidden by the radius alone while the line was clear (%d)" % [far_seen, radius_hid])
	_sections.append("los_hill")
