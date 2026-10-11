extends RefCounted

# THE BIG-GUN SPECIALS: the model of a gun salvo fired at a spotted target (Track SH, the warship, proposed 2026-10-10).
# Pure functions, headless, no nodes; the dice are Mulberry32 streams seeded here and drawn by the combat resolver
# (combat_resolver.gd); the numbers are data/sim/guns.json (gun_rules.gd), the units that have such a special are
# data/units/<id>.json specials (the small cruiser's "main_guns", name "Main Guns", action "Fire"), and WHO CAN BE FIRED AT
# is scripts/sim/spotting.gd's.
#
# Alex (decision mixed-warfare, 2026-10-10): "You have a huge ship parked off the coast but you need tanks to move inland to
# spot the aa batteries for the ship." Shared spotting: "Yes". Big guns as specials: "yes ... fired by hand with a long
# reload, aimed with the target selection". He has not settled engagement ranges ("I am not sure what engagement ranges
# make sense yet"). His targeting rules (special-targeting, target-follows-unit, step-selection) are the bomb drop's.
# EVERYTHING BELOW THAT IS NOT THOSE WORDS IS PROPOSED.
#
# THE GENERALISATION. A unit's special is the bomb drop (id "bomb", the plan request "drop", bombs.gd) OR a gun
# special (any other id with a record in data/sim/guns.json, the plan request "fire"). A step's request carries at most
# one of each, and a gun special is switched on the way the drop is: a target is set, the step names it.
#
#     {"turn": ..., "speed": ..., "fire": {"special": "main_guns", "target": {"unit": "aa_1"}}}      (a unit: followed)
#     {"fire": {"special": "main_guns", "target": {"point": [x, y]}, "aim": [x, y]}}                   (a point: fixed)
#
# `aim` is optional: the point the target was SHOWN at when the special was activated (the preview; a unit target is
# followed at resolve, as the bombs' is). The envelope ignores a fire (it is a special, not a manoeuvre).
#
# ACTIVATING (World.gun_check; plan_step accepts any well-formed fire and the step's "fire" analysis says whether it
# would go off): the special can be switched on only while
#   - the guns are loaded (reload_turns after the last salvo) and no other step of the plan fires them (one salvo a turn),
#   - the target is an enemy unit that is up, or a point,
#   - its distance from the ship, at the moment of the step the guns fire at (fire_at), is in [range_min_m, range_max_m],
#   - the unit's side SPOTS it at planning (scripts/sim/spotting.gd: shared spotting, any unit of the side).
# Each failing condition has a reason the card words: reloading, already_planned, no_target, target_down, own_side, too_close,
# out_of_range, inland (Alex: "You can attack coast not inland": the first water along the line of fire from the target back toward the
# ship must be within inland_max_m; needs the World's water), unspotted.
#
# FIRING (combat_resolver.gd, on the combat tick the moment falls in). At the moment fire_at of the step:
#   - the unit must be up (as the guns and the bombs: simultaneous within a tick) and loaded;
#   - the target must STILL be spotted by the side and in range. If not the salvo is not fired and nothing is spent (event
#     "gun_hold", with the reason): PROPOSED. This is the same answer data/sim/bombs.json outside_cone_mode "hold" gives a bomb
#     whose target left its cone. Alex's open question outside-cone-release (hold, or poor_shot: a bad shot) therefore covers
#     the guns too, and is not decided; the poor-shot answer for a gun would be to fire at where the target was last
#     spotted, with the widest scatter. It is not built;
#   - a unit target is followed: the salvo is aimed where the unit would be when the shells land if it keeps its heading
#     and speed from the moment of fire (lead_target; the bombs' followed_aim);
#   - the salvo is `shells` shells leaving salvo_interval_s apart, each flying range / shell_speed_mps seconds (at least
#     min_flight_s), landing scattered about the aim point by a Gaussian per ground axis of
#
#         sigma = (spread_base_m + spread_per_range x range) x aim_factor(spotted seconds) x bracket_mult(salvos) x spotter_mult(closeness)
#
#     where aim_factor falls in a straight line from unranged_factor to ranged_factor as the time the target has been
#     spotted WITHOUT A BREAK (run_s: spotting.gd) goes from 0 to ranging_s: RANGING IN (PROPOSED); bracket_mult is bracket_factor
#     for each salvo this side has already fired at the same spotted target, to bracket_floor: BRACKETING (PROPOSED, the historical
#     walk of the fall of shot); spotter_mult is 1 with a spotter on the target and spotter_far_factor with the nearest one at the
#     edge of its sight (PROPOSED: "the longer and closer the target is spotted, the tighter"). A part of the scatter
#     (salvo_error_fraction) is the whole salvo's, as a stick of bombs' is.
#
# THE DICE. Mulberry32 streams seeded from (the World's rng_seed, the turn, a constant tag, the unit's index in World.units,
# the step), the shell's index folded in through combat.gd's mix32: the same game rolls the same salvo, and only the host's
# World rolls.
#
# THE SHELLS IN FLIGHT. A record (World.shells_in_flight, the "extras" of resolve()'s result, which apply_resolution hands a
# client and a snapshot hands a joiner):
#
#   {"id" ("<unit>/<turn>/<step>/<shell>"), "unit", "special", "step", "shell" (index in the salvo),
#    "release_turn", "release_t" (this shell's leaving, seconds into release_turn), "x0", "y0" (the guns), "x", "y" (where it
#    will land, scatter included), "fall_s" (its flight), "apex_m", "impact_turn", "impact_t"}
#
# and shell_position() says where it is at a moment, for the effects.
#
# EVENTS (added to resolve()'s events, merged in time order; every one has "turn", the World's turn, and t seconds into it):
#
#   {"type": "shell_fire", "turn", "unit", "special", "t", "x", "y" (the guns), "step", "target", "aim": [x, y] (the salvo's centre),
#    "shells": n, "range_m", "flight_s", "impact_t" (seconds after the start of THIS turn the first shell lands: above
#    turn_seconds means a later turn), "spread_m" (sigma), "spotted_s", "salvos_before", "spotter_ratio", "followed": bool}
#   {"type": "shell_impact", "turn" (the turn it LANDS in), "unit", "special", "shell", "step", "t", "x", "y", "blast_m", "released_turn",
#    "released_t"}
#   {"type": "gun_hold", "turn", "unit", "special", "t", "step", "target", "reason"}      the salvo that was planned and not fired
#   {"type": "hit", ..., "weapon": "main_guns"} / {"type": "down", ...}                      after a shell_impact that did it

const Combat = preload("res://scripts/sim/combat.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const MASK32 := 0xFFFFFFFF
const GUN_TAG := 0x47554E53   # "GUNS"

# Why a salvo cannot be fired (the strings the card words; the keys of ui.json's guns.text):
const WHY_RELOADING := "reloading"
const WHY_NO_TARGET := "no_target"
const WHY_TARGET_DOWN := "target_down"
const WHY_OWN_SIDE := "own_side"
const WHY_TOO_CLOSE := "too_close"
const WHY_OUT_OF_RANGE := "out_of_range"
const WHY_UNSPOTTED := "unspotted"
const WHY_INLAND := "inland"                     # beyond the coastal strip (Alex: the sea guns attack the coast, not inland)
const WHY_ALREADY_PLANNED := "already_planned"   # another step of the plan fires this special: one salvo a turn
const WHY_NOT_A_GUN := "not_a_gun"               # the unit has no such gun special
const WHY_UNIT_DOWN := "unit_down"

# --- The request ---------------------------------------------------------------------------

# "" if `fire` is a well-formed fire request ({"special": id, "target": {...}, "aim"?: [x, y]}), else what is wrong with it.
static func request_error(fire: Variant) -> String:
	if not (fire is Dictionary):
		return "'fire' must be {\"special\": id, \"target\": {...}}, got %s" % str(fire)
	var f: Dictionary = fire
	if not (f.get("special") is String) or str(f["special"]) == "":
		return "'fire.special' must be the id of a gun special, got %s" % str(f.get("special"))
	if not f.has("target"):
		return "'fire.target' is required: a special is active and targeted for its step (Alex)"
	var te := Envelope.target_error(f["target"])
	if te != "":
		return te.replace("drop.target", "fire.target")
	if f.has("aim"):
		var a: Variant = f["aim"]
		var ok := a is Vector2 and (a as Vector2).is_finite()
		if not ok and a is Array and (a as Array).size() >= 2 and _is_num(a[0]) and _is_num(a[1]):
			ok = is_finite(float(a[0])) and is_finite(float(a[1]))
		if not ok:
			return "'fire.aim' must be a Vector2 or [x, y] of finite numbers, got %s" % str(a)
	for k: Variant in f:
		if k != "special" and k != "target" and k != "aim":
			return "'fire' has an unknown field '%s'" % str(k)
	return ""

static func _is_num(v: Variant) -> bool:
	return v is float or v is int

# The special id of a request's fire ("" if it has none).
static func fire_special(request: Variant) -> String:
	if not (request is Dictionary) or not (request as Dictionary).has("fire"):
		return ""
	var f: Variant = (request as Dictionary)["fire"]
	if not (f is Dictionary):
		return ""
	return str((f as Dictionary).get("special", ""))

# The target of a request's fire, normalised: {"unit": id} or {"point": [x, y]} (floats), or {} if it has none or a malformed one.
static func fire_target(request: Variant) -> Dictionary:
	if not (request is Dictionary) or not (request as Dictionary).has("fire"):
		return {}
	var f: Variant = (request as Dictionary)["fire"]
	if not (f is Dictionary) or not (f as Dictionary).has("target"):
		return {}
	return normal_target((f as Dictionary)["target"])

# A target ({"unit": id} | {"point": [x, y]}) normalised, or {} when malformed.
static func normal_target(t: Variant) -> Dictionary:
	if Envelope.target_error(t) != "":
		return {}
	if (t as Dictionary).has("unit"):
		return {"unit": str((t as Dictionary)["unit"])}
	var p: Variant = (t as Dictionary)["point"]
	if p is Vector2:
		return {"point": [(p as Vector2).x, (p as Vector2).y]}
	return {"point": [float(p[0]), float(p[1])]}

# The aim stored with a request's fire (where the target was shown), [x, y], or [].
static func fire_aim(request: Variant) -> Array:
	if not (request is Dictionary) or not (request as Dictionary).has("fire"):
		return []
	var f: Variant = (request as Dictionary)["fire"]
	if not (f is Dictionary) or not (f as Dictionary).has("aim"):
		return []
	var a: Variant = (f as Dictionary)["aim"]
	if a is Vector2:
		return [(a as Vector2).x, (a as Vector2).y] if (a as Vector2).is_finite() else []
	if a is Array and (a as Array).size() >= 2 and _is_num(a[0]) and _is_num(a[1]) and is_finite(float(a[0])) and is_finite(float(a[1])):
		return [float(a[0]), float(a[1])]
	return []

# --- Range, flight and aim -----------------------------------------------------------------------

# "" if a target `range_m` away is inside the guns' reach, else WHY_TOO_CLOSE / WHY_OUT_OF_RANGE.
static func range_error(range_m: float, spec: GunRules.Spec) -> String:
	if range_m < spec.range_min_m:
		return WHY_TOO_CLOSE
	if range_m > spec.range_max_m:
		return WHY_OUT_OF_RANGE
	return ""

# THE COASTAL STRIP (Alex: "You can attack coast not inland."): how far a target is from the shore, metres, measured along the line
# of fire from the target back toward the guns: 0 for a target on the water, else the distance to the first water on that line, in
# steps of inland_step_m, or INF when there is none within the strip (inland_max_m and a step more). `water` is the World's depth
# query (x, y) -> metres of water, 0 or less on land.
static func inland_depth_m(water: Callable, from: Vector2, to: Vector2, spec: GunRules.Spec) -> float:
	if float(water.call(to.x, to.y)) > 0.0:
		return 0.0
	var dir := (from - to)
	var dist := dir.length()
	if dist < 1e-6:
		return INF
	dir /= dist
	var d := spec.inland_step_m
	var limit := minf(spec.inland_max_m + spec.inland_step_m, dist)
	while d <= limit + 1e-9:
		var p := to + dir * d
		if float(water.call(p.x, p.y)) > 0.0:
			return d
		d += spec.inland_step_m
	return INF

# "" if the target is inside the guns' reach: range, and with a water query the coastal strip too. WHY_TOO_CLOSE, WHY_OUT_OF_RANGE
# or WHY_INLAND otherwise.
static func reach_error(from: Vector2, to: Vector2, spec: GunRules.Spec, water: Callable = Callable()) -> String:
	var why := range_error(from.distance_to(to), spec)
	if why != "":
		return why
	if water.is_valid() and inland_depth_m(water, from, to, spec) > spec.inland_max_m:
		return WHY_INLAND
	return ""

# Seconds a shell flies over `range_m` of ground.
static func flight_time(range_m: float, spec: GunRules.Spec) -> float:
	return maxf(range_m / spec.shell_speed_mps, spec.min_flight_s)

# Where a salvo fired from `from` at a target at `target_pos` moving at `target_vel` (m/s) is aimed, and how long its shells
# fly: the target's position led by its velocity times the flight time (lead_target; a constant-velocity projection, the
# bombs' followed_aim), the flight time being that of the shot to the led point (a few passes find it). {aim: Vector2,
# range_m (to the aim), flight_s}.
static func aim_for(from: Vector2, target_pos: Vector2, target_vel: Vector2, spec: GunRules.Spec) -> Dictionary:
	var aim := target_pos
	var flight := flight_time(from.distance_to(aim), spec)
	if spec.lead_target and target_vel != Vector2.ZERO:
		for _i in 4:
			aim = target_pos + target_vel * flight
			flight = flight_time(from.distance_to(aim), spec)
		aim = target_pos + target_vel * flight
	return {"aim": aim, "range_m": from.distance_to(aim), "flight_s": flight}

# --- Accuracy ---------------------------------------------------------------------------------

# The factor the scatter is multiplied by for a target that has been spotted `spotted_s` seconds without a break: unranged_factor
# at 0, ranged_factor from ranging_s on, a straight line between.
static func aim_factor(spotted_s: float, spec: GunRules.Spec) -> float:
	var f := clampf(maxf(spotted_s, 0.0) / spec.ranging_s, 0.0, 1.0)
	return spec.unranged_factor + (spec.ranged_factor - spec.unranged_factor) * f

# One shell's scatter (one standard deviation per ground axis), metres: a base and a part that grows with the range, times the
# ranging factor (how long the target has been spotted), the bracketing multiplier (how many salvos this side has already fired
# at the same spotted target) and the spotter's (how close the nearest spotter is: `spotter_ratio`, its distance to the target over
# its sight, 0 on top of it and 1 at the edge of its sight).
static func sigma_m(range_m: float, spotted_s: float, spec: GunRules.Spec, salvos_before: int = 0, spotter_ratio: float = 0.0) -> float:
	return (spec.spread_base_m + spec.spread_per_range * maxf(range_m, 0.0)) * aim_factor(spotted_s, spec) * bracket_mult(salvos_before, spec) \
		* spotter_mult(spotter_ratio, spec)

# The scatter's multiplier for the nearest spotter's closeness (PROPOSED): 1 at the target, spotter_far_factor at the edge of its sight.
static func spotter_mult(spotter_ratio: float, spec: GunRules.Spec) -> float:
	return 1.0 + (spec.spotter_far_factor - 1.0) * clampf(spotter_ratio, 0.0, 1.0)

# BRACKETING (PROPOSED; the historical walk of the fall of shot onto a target): each salvo already fired at the same spotted target
# multiplies the scatter by bracket_factor, down to bracket_floor.
static func bracket_mult(salvos_before: int, spec: GunRules.Spec) -> float:
	return maxf(spec.bracket_floor, pow(spec.bracket_factor, float(maxi(salvos_before, 0))))

# The bracketing memory is an Array of records {"side", "unit" ("" for a point target), "point" ([x, y] of the last aim, or []),
# "salvos" (fired at it), "turn" (the last turn one was fired)}, kept by the World and carried across the wire with the shells.
# How many salvos `side` has fired at this target before `turn` (an entry not renewed for bracket_turns is a new target).
static func bracket_salvos(memory: Array, side: String, target: Dictionary, turn: int, spec: GunRules.Spec) -> int:
	var i := _bracket_index(memory, side, target, spec)
	if i < 0:
		return 0
	var rec: Dictionary = memory[i]
	if turn - int(rec["turn"]) > spec.bracket_turns:
		return 0
	return int(rec["salvos"])

# The memory after `side` fires a salvo whose aim is `aim` at `target` in `turn`: the salvo count of the matching entry plus one
# (a stale entry starts again from one), or a new entry. Returns a new Array.
static func bracket_after(memory: Array, side: String, target: Dictionary, aim: Vector2, turn: int, spec: GunRules.Spec) -> Array:
	var out: Array = memory.duplicate(true)
	var i := _bracket_index(out, side, target, spec)
	var tpoint: Array = [] if target.has("unit") else [aim.x, aim.y]
	if i < 0:
		out.append({"side": side, "unit": str(target.get("unit", "")), "point": tpoint, "salvos": 1, "turn": turn})
		return out
	var rec: Dictionary = out[i]
	var n := int(rec["salvos"]) + 1 if turn - int(rec["turn"]) <= spec.bracket_turns else 1
	rec["salvos"] = n
	rec["turn"] = turn
	rec["point"] = tpoint
	return out

static func _bracket_index(memory: Array, side: String, target: Dictionary, spec: GunRules.Spec) -> int:
	for i in memory.size():
		var rec: Dictionary = memory[i]
		if str(rec["side"]) != side:
			continue
		if target.has("unit"):
			if str(rec["unit"]) == str(target["unit"]):
				return i
		elif str(rec["unit"]) == "" and (rec["point"] as Array).size() >= 2:
			var tp: Variant = target["point"]
			var tx := (tp as Vector2).x if tp is Vector2 else float(tp[0])
			var ty := (tp as Vector2).y if tp is Vector2 else float(tp[1])
			if Vector2(tx - float(rec["point"][0]), ty - float(rec["point"][1])).length() <= spec.bracket_point_m:
				return i
	return -1

# --- The salvo ----------------------------------------------------------------------------------

# The seed of one salvo's dice: the game seed, the turn, a constant tag, the unit's index in World.units and the step, folded through mix32.
static func salvo_seed(game_seed: int, turn: int, unit_index: int, step: int) -> int:
	var s := (game_seed & MASK32) ^ ((game_seed >> 32) & MASK32)
	for part: int in [turn, GUN_TAG, unit_index, step]:
		s = Combat.mix32(s, part)
	return s

# The shells of one salvo. `shot`: {unit, special, step, t (the moment of fire, seconds into `turn`), from: Vector2 (the guns),
# aim: Vector2, range_m, flight_s, sigma_m}. Returns the records (see the header) with "impact_total": seconds from the start of
# the release turn at which each lands, for Bombs.schedule to turn into an impact turn and moment.
static func make_salvo(shot: Dictionary, spec: GunRules.Spec, game_seed: int, turn: int, unit_index: int) -> Array:
	var sigma := float(shot["sigma_m"])
	var common_sigma := sigma * spec.salvo_error_fraction
	var own_sigma := sigma * sqrt(maxf(1.0 - spec.salvo_error_fraction * spec.salvo_error_fraction, 0.0))
	var seed_value := salvo_seed(game_seed, turn, unit_index, int(shot["step"]))
	var common := Bombs.gaussian_pair(Mulberry32.new(seed_value)) * common_sigma
	var aim: Vector2 = shot["aim"]
	var from: Vector2 = shot["from"]
	var flight := float(shot["flight_s"])
	var out: Array = []
	for i in spec.shells:
		var own := Bombs.gaussian_pair(Mulberry32.new(Combat.mix32(seed_value, i + 1))) * own_sigma
		var t_i := float(shot["t"]) + float(i) * spec.salvo_interval_s
		out.append({
			"id": "%s/%d/%d/%d" % [str(shot["unit"]), turn, int(shot["step"]), i],
			"unit": str(shot["unit"]), "special": str(shot["special"]), "step": int(shot["step"]), "shell": i,
			"release_turn": turn, "release_t": t_i,
			"x0": from.x, "y0": from.y,
			"x": aim.x + common.x + own.x, "y": aim.y + common.y + own.y,
			"fall_s": flight, "apex_m": spec.apex_per_range * float(shot["range_m"]),
			"impact_total": t_i + flight,
		})
	return out

# Where a shell in flight is at `t` seconds into `turn`: {x, y, height_m, state} with state "unreleased", "falling" (in the
# air) or "landed". Horizontally a straight line from the guns to where it lands; its height an arc, apex_m at the top.
static func shell_position(shell: Dictionary, turn: int, t: float, turn_seconds: float) -> Dictionary:
	var tau := float(turn - int(shell["release_turn"])) * turn_seconds + t - float(shell["release_t"])
	var fall := float(shell["fall_s"])
	if tau <= 0.0:
		return {"x": float(shell["x0"]), "y": float(shell["y0"]), "height_m": 0.0, "state": "unreleased"}
	if tau >= fall:
		return {"x": float(shell["x"]), "y": float(shell["y"]), "height_m": 0.0, "state": "landed"}
	var f := tau / fall
	return {
		"x": lerpf(float(shell["x0"]), float(shell["x"]), f), "y": lerpf(float(shell["y0"]), float(shell["y"]), f),
		"height_m": float(shell["apex_m"]) * 4.0 * f * (1.0 - f), "state": "falling",
	}
