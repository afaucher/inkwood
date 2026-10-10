extends RefCounted

# The hit model: pure functions, headless, no nodes, no randomness here (the
# rolls are drawn by combat_resolver.gd from seeds this file mints). Track C,
# proposed 2026-10-09 for the first fight, on Alex's decisions: a CONE PER WEAPON
# starting at a HARDPOINT on the airframe; the cone has HEIGHT as well as width;
# hits are random-ish, and the first factor decided is that a machine gun has
# better odds the nearer the target is to the centre of its cone.
#
#   var pose := Combat.pose({"x": .., "y": .., "heading": .., "height_m": .., "pitch": 0.0}, weapon.hardpoints[0])
#   var g := Combat.evaluate_pose(pose, weapon, {"x": .., "y": .., "height_m": ..}, ["centre"])
#   g.in_cone, g.r, g.distance, g.odds           # or Combat.evaluate(shooter, weapon, 0, target)
#
# THE GEOMETRY (proposed). World axes: x right, y DOWN, height_m up (metres
# above sea level, the sim's altitude bands). The shooter's airframe has its
# own axes: forward along the nose (heading, clockwise on screen), right the
# right-hand wing, up above it. `pitch` (radians, nose up positive; 0 in level
# flight) tilts the airframe about the right-hand axis; there is no bank (the
# sim has none). A hardpoint is [forward, right, up] metres in those axes, so
# its world position follows the unit's position, heading, height and pitch.
#
# A cone is centred on the direction (mount_deg, elevation_deg) IN THE AIRFRAME'S
# AXES: mount_deg 0 is the nose, 180 the tail, positive to the right; elevation
# above the airframe's level. A target's direction from the hardpoint is
# measured the same way (azimuth and elevation), and its OFFSET from the
# cone's centre is `across` (azimuth difference) and `height` (elevation
# difference). The cone is an ELLIPSE in those two angles:
#
#     r = sqrt((across / half_across)^2 + (height / half_height)^2)
#
# r is 0 at the centre and 1 at the rim; the target is in the arc when r <= 1.
# It is IN THE CONE when it is also within the weapon's REACH of the hardpoint
# (the slant distance, so a target 600 m up is 600 m away): its effective range
# stretched by range_overshoot while the "range" factor is on (a gun fires
# slightly over its effective range, Alex), else the effective range alone, a
# hard edge. Azimuth and
# elevation (a turret's traverse and elevation) rather than the true angle from
# the axis because that is how a cone of +-110 degrees across and 35 +- 35 in
# height reads, and for the narrow cones the two are the same.
#
# THE TILT (proposed, data/sim/combat.json max_pitch_deg): while a plane changes
# altitude band its airframe pitches with the climb or dive, so every cone
# tilts with it (a tail turret points DOWN in a climb). The resolver supplies
# pitch = clamp(atan2(vertical speed, speed), +-max_pitch). In level flight
# pitch is 0 and the cones are level.
#
# ODDS = base_hit_chance x the product of the NAMED FACTORS data/sim/combat.json
# lists (odds_factors), clamped to 0..1. Three exist:
#     centre(r) = 1 - (1 - rim_odds_factor) x r^falloff_exponent
# 1 at the centre, rim_odds_factor at the rim. Fixed guns are PEAKED (rim factor
# well under 1), flexible guns and turrets FLAT (rim factor 1: a gunner aims
# within the arc).
#     range(d) = 1 for d <= effective_range_m, else 1 - s^2 (3 - 2 s) with
#                s = (d - effective_range_m) / (effective_range_m x range_overshoot)
# a smoothstep: 1 inside the effective range, falling smoothly (no kink at the
# range) to 0 at effective_range_m x (1 + range_overshoot), where range_overshoot
# is data/sim/combat.json's, passed in `params` (CombatRules.factor_params()).
# Alex 2026-10-09: "slightly over effective range" a gun still fires.
#     crossing_rate(w) = 1 / (1 + (w / tracking_dps)^crossing_exponent)
# Alex 2026-10-10: "relative velocity should also have an accuracy impact". w is the
# turn rate of the line of sight from the shooter's hardpoint to the target, degrees/s:
# the relative velocity (target minus shooter) perpendicular to the line of fire, over
# the distance -- the deflection a gun must track, so the same crossing speed costs
# less from farther away. 1 when nothing crosses (a matched-speed tail chase), exactly
# 0.5 at the weapon's tracking_dps, smooth, never a cliff. tracking_dps is small for
# a fixed gun (the pilot swings the whole plane) and larger for a flexible gun or a
# turret (a gunner tracks); crossing_exponent is data/sim/combat.json's. The velocity
# along the line of fire (closing or opening) costs nothing, by design: a fast pass is
# brief, and the tick count already pays for that in fewer rolls; it is computed
# (closing_mps) so a later factor can use it. Velocities come from the resolver: speed
# along the nose, pitched by the same tilt as the cones (so a plane changing band
# climbs or dives at its pitch, not at the 280 to 600 m a second the band heights
# imply over a 1 to 1.7 s step, which would make any band change untouchable).
# Adding a factor (target size, ...) means adding its name to FACTOR_NAMES and a branch
# in factor_value(), then its name to the data; the geometry dictionary it reads (`geo`)
# has distance, r, across, height, crossing_dps, closing_mps and the `params`, and gains
# whatever the new factor needs. NONE of those is built.
#
# THE ROLLS (combat_resolver.gd): the turn is cut into ticks (tick_seconds); at
# each tick every unit that is up is sampled at the tick's END time t on the
# arcs World.sample uses. Each hardpoint of each weapon of each up unit picks,
# among the enemy units (another side) that are up and in its cone, the one
# with the best odds (proposed default; NOT target priority, which Alex will
# design) and rolls: hit when a Mulberry32 draw is below the odds. A weapon
# rolls `rolls_per_second` times a second, on the global clock: it makes
# floor(t x rate) - floor(t_previous x rate) rolls in a tick. All shots in a
# tick are SIMULTANEOUS: who is up is decided at the start of the tick, so two
# planes can shoot each other down in the same tick; from the next tick a unit
# that went down neither fires nor is fired at. Damage takes pips from health;
# at 0 the unit is down at that tick's t.
#
# THE SEED (roll_seed): Mulberry32 seeded from (the World's rng_seed, turn,
# shooter index, weapon index, hardpoint index, tick index) through a
# documented 32-bit mix, so the same game draws the same rolls and one roll
# does not depend on how many other rolls the turn held. Indices: the shooter's
# position in World.units (the order units were added), the weapon's in
# def.weapons, the hardpoint's in weapon.hardpoints, and the tick counted from 1
# (the tick ending at t = turn_seconds x tick / ticks); the turn is
# World.turn. The rolls of one tick (rate above one a tick) are that stream's
# first draws in order.
#
# Engine trig is used (the motion model's JsMath exists to give every peer the
# same bits; only the host rolls, and it sends the result: CLAUDE.md, the
# network contract). If a client ever has to re-resolve a turn, swap JsMath
# in here.
#
# EVENTS: combat adds these to resolve()'s `events` list (the same list as
# left_bounds). The list is merged in time order (t ascending; a motion event
# before a combat event at the same t). Every combat event also has "turn" (the
# World's turn). Positions are metres, height_m is metres above sea level, t is
# seconds into the turn. All values are plain (String, int, float, bool), so the
# list travels as it is.
#
#   {"type": "fire", "turn", "tick" (1-based), "unit" (shooter id), "weapon"
#    (weapon id), "hardpoint" (index), "target" (unit id), "t", "hit" (bool),
#    "odds" (what the roll was against, 0..1), "r", "distance" (slant m), "crossing_dps" (the line of sight's turn rate),
#    "x", "y", "height_m" (the hardpoint, where the shot starts),
#    "tx", "ty", "theight_m" (the target's centre)}      one per roll
#   {"type": "hit", "turn", "unit" (the TARGET), "by" (shooter id), "weapon",
#    "t", "damage" (pips taken), "health" (the target's pips left, 0 or more)}
#   {"type": "down", "turn", "unit", "by" (the shooter whose hit did it),
#    "t", "x", "y", "height_m", "fate" ("exploded" | "out_of_control")}
#                                                        once, where it went down
#   {"type": "crash", "turn", "unit", "t", "x", "y"}     later: an out-of-control
#                                                        unit reached the ground
#                                                        (this turn or a later one)
#
# A fire event's `hit` says whether the roll hit; a hit event follows its fire
# event at once, and a down event follows the hit that took the last pip. A
# unit hit again within the tick it went down (simultaneous fire) gets another
# hit event with health 0 and no second down.
#
# WHAT A KILL DOES (Alex 2026-10-09: "dead planes should either explode mid air
# or lose control by players and crash eventually"; details proposed). At the
# tick a unit's health reaches 0 it is DOWN and its FATE is decided by a seeded
# roll of its own (fate_seed / fate_roll): "exploded" with probability
# data/sim/combat.json explode_chance, else "out_of_control".
#   exploded        gone at that t, at that position and height; it stays where
#                   it exploded, still in World.units for the interface to show.
#   out_of_control  nobody can plan it (players and the AI alike) but the sim
#                   flies it: from that t it turns at a fixed rate (the roll
#                   picks left or right), holds or gains speed and loses height
#                   at a fixed rate, across turns, until it reaches the ground
#                   (0 m; the sim has no terrain), where it "crashed" and stops.
# Neither fires or is fired at once down. The World carries the fall height
# (Unit.fall_height_m, metres above the ground, continuous; the altitude_band of
# a falling unit is just the nearest band) and World.sample reports it as
# height_m. The details, all of them in world.gd:
#   - the turn it goes down out of control, its history keeps every state before
#     down_at as it was, gains one state AT down_at (so it has one more entry than
#     the type's steps + 1, unless a step ended exactly there) and the states
#     after it are the fall; every state from down_at on carries fall_height_m.
#     An exploded unit's history is left as motion built it: use down_at and the
#     "down" event to stop drawing it. Either way the unit's own state at the end
#     of the turn is where it went down (exploded) or where it struck the ground
#     (crashed), speed 0.
#   - later turns, an out-of-control unit's history is the fall, step by step; a
#     crashed or exploded unit's history sits still.
#   - bounds events are not reported for a unit after it goes down.

const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Unit = preload("res://scripts/sim/unit.gd")

const MASK32 := 0xFFFFFFFF


# The odds factors the code knows. data/sim/combat.json names the ones in use;
# a name not listed here is a data error.
const FACTOR_NAMES: Array[String] = ["centre", "range", "crossing_rate"]

# --- Geometry ----------------------------------------------------------------

# Where a hardpoint is and the airframe's axes, for a shooter state
# {x, y, heading, height_m, pitch (optional, default 0)} and a hardpoint
# Vector3 [forward, right, up]. Compute it once per hardpoint per tick and
# evaluate every candidate target against it (evaluate_pose).
# Returns {x, y, z (world position; z is metres above sea level), and the
# airframe's axes in the world: fx, fy, fz (forward), rx, ry (right; no z, the
# wings are level), ux, uy, uz (up)}.
# The shooter's velocity vx, vy, vz (m/s, world axes; optional, default 0) is carried
# along as vx, vy, vz: the crossing_rate factor needs it.
static func pose(shooter: Dictionary, hardpoint: Vector3) -> Dictionary:
	var h := float(shooter["heading"])
	var th := float(shooter.get("pitch", 0.0))
	var ch := cos(h)
	var sh := sin(h)
	var cp := 1.0
	var sp := 0.0
	if th != 0.0:
		cp = cos(th)
		sp = sin(th)
	var fx := cp * ch
	var fy := cp * sh
	var fz := sp
	var rx := -sh
	var ry := ch
	var ux := -sp * ch
	var uy := -sp * sh
	var uz := cp
	var hf := float(hardpoint.x)
	var hr := float(hardpoint.y)
	var hu := float(hardpoint.z)
	return {
		"x": float(shooter["x"]) + hf * fx + hr * rx + hu * ux,
		"y": float(shooter["y"]) + hf * fy + hr * ry + hu * uy,
		"z": float(shooter["height_m"]) + hf * fz + hu * uz,
		"fx": fx, "fy": fy, "fz": fz,
		"rx": rx, "ry": ry,
		"ux": ux, "uy": uy, "uz": uz,
		"vx": float(shooter.get("vx", 0.0)), "vy": float(shooter.get("vy", 0.0)), "vz": float(shooter.get("vz", 0.0)),
	}

# Squared slant distance from a pose to a target {x, y, height_m}: the cheap
# range test before the trig.
static func distance_sq(p: Dictionary, target: Dictionary) -> float:
	var dx := float(target["x"]) - float(p["x"])
	var dy := float(target["y"]) - float(p["y"])
	var dz := float(target["height_m"]) - float(p["z"])
	return dx * dx + dy * dy + dz * dz

# The cone test of a target {x, y, height_m} from a pose, against a weapon.
# `factors`: the named odds factors to apply (CombatRules.odds_factors).
# `params`: the numbers the factors read besides the weapon (CombatRules.factor_params():
# range_overshoot, crossing_exponent); a missing range_overshoot is 0, a hard edge at the
# effective range. The target may carry its velocity vx, vy, vz (m/s, world axes; default 0);
# the pose carries the shooter's. Without either, there is no relative motion.
# Returns {in_cone, in_arc, in_range (within the reach, see reach()), r (1 or less is inside the arc;
# INF when the target is at the hardpoint), distance (slant metres), across,
# height (signed offsets from the cone's centre, radians; NAN at the
# hardpoint), crossing_dps (the line of sight's turn rate, degrees/s, from the relative
# velocity; 0 outside the cone), closing_mps (the relative velocity along the line of fire,
# negative closing; 0 outside the cone), odds (0 outside the cone), factors ({name: value},
# empty outside the cone)}.
static func evaluate_pose(p: Dictionary, weapon: CombatWeapon, target: Dictionary, factors: Array, params: Dictionary = {}) -> Dictionary:
	var dx := float(target["x"]) - float(p["x"])
	var dy := float(target["y"]) - float(p["y"])
	var dz := float(target["height_m"]) - float(p["z"])
	var dist := sqrt(dx * dx + dy * dy + dz * dz)
	var reach_m := reach(weapon, factors, params)
	var out := {
		"in_cone": false, "in_arc": false, "in_range": dist <= reach_m,
		"r": INF, "distance": dist, "across": NAN, "height": NAN,
		"odds": 0.0, "factors": {}, "crossing_dps": 0.0, "closing_mps": 0.0,
	}
	if dist < 1e-9:
		return out
	# The target's direction in the airframe's axes.
	var df := dx * float(p["fx"]) + dy * float(p["fy"]) + dz * float(p["fz"])
	var dr := dx * float(p["rx"]) + dy * float(p["ry"])
	var du := dx * float(p["ux"]) + dy * float(p["uy"]) + dz * float(p["uz"])
	var azimuth := atan2(dr, df)
	var elevation := atan2(du, hypot(df, dr))
	var across := wrap_angle(azimuth - weapon.mount)
	var height := elevation - weapon.elevation
	var a := across / weapon.half_across
	var b := height / weapon.half_height
	var r := sqrt(a * a + b * b)
	out["across"] = across
	out["height"] = height
	out["r"] = r
	out["in_arc"] = r <= 1.0
	out["in_cone"] = r <= 1.0 and dist <= reach_m
	if out["in_cone"]:
		# Relative motion: the target's velocity minus the shooter's, split along the line of
		# fire (closing) and across it (the line of sight's turn rate, the deflection a gun must track).
		var rvx := float(target.get("vx", 0.0)) - float(p["vx"])
		var rvy := float(target.get("vy", 0.0)) - float(p["vy"])
		var rvz := float(target.get("vz", 0.0)) - float(p["vz"])
		var closing := (rvx * dx + rvy * dy + rvz * dz) / dist
		var perp_sq := maxf(rvx * rvx + rvy * rvy + rvz * rvz - closing * closing, 0.0)
		var crossing_dps := rad_to_deg(sqrt(perp_sq) / dist)
		out["crossing_dps"] = crossing_dps
		out["closing_mps"] = closing
		var geo := {"r": r, "distance": dist, "across": across, "height": height, "crossing_dps": crossing_dps, "closing_mps": closing, "params": params}
		var odds := weapon.base_hit_chance
		var used := {}
		for name: Variant in factors:
			var v := factor_value(str(name), weapon, geo)
			used[str(name)] = v
			odds *= v
		out["factors"] = used
		out["odds"] = clampf(odds, 0.0, 1.0)
	return out

# pose() then evaluate_pose(), for one hardpoint of a weapon (by index).
# `shooter` {x, y, heading, height_m, pitch?}; `target` {x, y, height_m}.
static func evaluate(shooter: Dictionary, weapon: CombatWeapon, hardpoint_index: int, target: Dictionary, factors: Array = ["centre"], params: Dictionary = {}) -> Dictionary:
	return evaluate_pose(pose(shooter, weapon.hardpoints[hardpoint_index]), weapon, target, factors, params)

# --- Odds --------------------------------------------------------------------

# One named factor's multiplier for a target in the cone; `geo` is
# {r, distance, across, height, crossing_dps, closing_mps, params}. An unknown name is a data error caught at load
# (CombatRules); here it is 1.0 so a stray name cannot silently zero the odds.
static func factor_value(name: String, weapon: CombatWeapon, geo: Dictionary) -> float:
	match name:
		"centre":
			return centre_factor(weapon, float(geo["r"]))
		"range":
			return range_factor(weapon, float(geo["distance"]), float((geo["params"] as Dictionary).get("range_overshoot", 0.0)))
		"crossing_rate":
			return crossing_factor(weapon, float(geo["crossing_dps"]), float((geo["params"] as Dictionary).get("crossing_exponent", 2.0)))
	return 1.0

# 1 at the cone's centre, weapon.rim_odds_factor at its rim, along r^exponent.
static func centre_factor(weapon: CombatWeapon, r: float) -> float:
	var rr := clampf(r, 0.0, 1.0)
	return 1.0 - (1.0 - weapon.rim_odds_factor) * pow(rr, weapon.falloff_exponent)

# 1 inside the effective range; past it a smoothstep down to 0 at effective range x
# (1 + overshoot): 1 - s^2 (3 - 2 s), s the fraction of the way through the fringe.
# With no overshoot the edge is hard (0 just past the range).
static func range_factor(weapon: CombatWeapon, distance: float, overshoot: float) -> float:
	var eff := weapon.effective_range_m
	if distance <= eff:
		return 1.0
	var fringe := eff * overshoot
	if fringe <= 0.0:
		return 0.0
	var s := clampf((distance - eff) / fringe, 0.0, 1.0)
	return 1.0 - s * s * (3.0 - 2.0 * s)

# Accuracy against relative motion: 1 when the line of sight is not turning, falling
# smoothly with its rate -- 1 / (1 + (rate / tracking_dps)^exponent), so exactly half at
# the weapon's tracking_dps and never a cliff or an exact 0. A fixed gun has a small
# tracking_dps (the pilot swings the whole plane), a gunner's a larger one.
static func crossing_factor(weapon: CombatWeapon, crossing_dps: float, exponent: float) -> float:
	return 1.0 / (1.0 + pow(maxf(crossing_dps, 0.0) / maxf(weapon.tracking_dps, 1e-6), exponent))

# The farthest slant distance at which a weapon rolls at all: its effective range
# stretched by the overshoot when the "range" factor is applied, else the
# effective range alone.
static func reach(weapon: CombatWeapon, factors: Array, params: Dictionary) -> float:
	if factors.has("range"):
		return weapon.max_range_m(float(params.get("range_overshoot", 0.0)))
	return weapon.effective_range_m

# --- Rolls -------------------------------------------------------------------

# How many rolls a weapon makes in the tick from t0 to t1 (seconds into the
# turn) at `rate` rolls a second, on the turn's clock. The epsilon keeps a
# product that should be a whole number from landing a ulp under it.
static func rolls_in_tick(rate: float, t0: float, t1: float) -> int:
	return int(floorf(t1 * rate + 1e-9)) - int(floorf(t0 * rate + 1e-9))

# The seed of one hardpoint's rolls in one tick (see the header): the game seed
# and each index folded in turn through mix32, so changing any one of them
# changes the stream completely.
static func roll_seed(game_seed: int, turn: int, shooter_index: int, weapon_index: int, hardpoint_index: int, tick_index: int) -> int:
	var s := (game_seed & MASK32) ^ ((game_seed >> 32) & MASK32)
	for part: int in [turn, shooter_index, weapon_index, hardpoint_index, tick_index]:
		s = mix32(s, part)
	return s

# The seed of the fate roll of a unit that goes down (its own stream, apart from
# the hit rolls): the game seed, the turn, a constant tag, the unit's index in
# World.units and the tick it went down in, folded through mix32 like roll_seed.
const FATE_TAG := 0x46415445   # "FATE"
static func fate_seed(game_seed: int, turn: int, unit_index: int, tick_index: int) -> int:
	var s := (game_seed & MASK32) ^ ((game_seed >> 32) & MASK32)
	for part: int in [turn, FATE_TAG, unit_index, tick_index]:
		s = mix32(s, part)
	return s

# The fate of a unit downed at `tick_index` of `turn`: {"fate": "exploded" |
# "out_of_control", "spin": +1 (a right turn, clockwise on screen) | -1 (left),
# 0 when it exploded}. Two draws from the fate stream, always both: the first
# against explode_chance, the second picks the spin.
static func fate_roll(game_seed: int, turn: int, unit_index: int, tick_index: int, explode_chance: float) -> Dictionary:
	var rng := Mulberry32.new(fate_seed(game_seed, turn, unit_index, tick_index))
	var explodes := rng.next() < explode_chance
	var spin := 1 if rng.next() < 0.5 else -1
	if explodes:
		return {"fate": Unit.FATE_EXPLODED, "spin": 0}
	return {"fate": Unit.FATE_OUT_OF_CONTROL, "spin": spin}

# Fold one value into a 32-bit hash: xor it in, add the golden-ratio constant,
# then murmur3's finaliser (fmix32), a bijection with full avalanche. All
# unsigned 32-bit arithmetic through Mulberry32.imul, so the result is the same
# on every platform.
static func mix32(h: int, v: int) -> int:
	var x := ((h ^ (v & MASK32)) + 0x9E3779B9) & MASK32
	x ^= x >> 16
	x = Mulberry32.imul(x, 0x85EBCA6B)
	x ^= x >> 13
	x = Mulberry32.imul(x, 0xC2B2AE35)
	x ^= x >> 16
	return x & MASK32

# --- Small helpers -----------------------------------------------------------

# An angle in [-PI, PI).
static func wrap_angle(a: float) -> float:
	return a - TAU * floorf((a + PI) / TAU)

static func hypot(a: float, b: float) -> float:
	return sqrt(a * a + b * b)
