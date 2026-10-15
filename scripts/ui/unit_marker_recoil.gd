extends RefCounted

# THE RECOIL (builder BR, board 'recoil', 2026-10-14; backlog A5; ALEX, decision tank-fire-feedback: "The turret or the whole tank should have some visual
# feedback. Either the whole tank rocks back or just the turret." and "The turret feedback should also apply to the ship."). Pure functions, no nodes:
# how far the drawn barrel, turret and hull are kicked back at a given moment after a shot. EVERY NUMBER IS PROPOSED (data/ui/ui.json unit_art.recoil).
#
# THE SWITCH is unit_art.recoil.mode: none (today: nothing moves), barrel, turret, hull, turret_hull. For a kind (tank, ship) a mode lists the PARTS it moves,
# each {m, attack_s, return_s, settle}: m is the kick in metres of the drawn unit, attack_s the time to the full kick, return_s the time back, settle 0..1 how
# much of the return is a damped swing past rest (a hull comes back and rocks once). unit_art.recoil.<kind>.min_px floors a kick on screen.
#
# THE SHOTS the marker is given (UnitMarkerLayer collects them from the turn's events): [{"t": the shot's second of the turn, "salvo": 0 for a single shot, else
# the shells of a Main Guns salvo, "interval": seconds between its shells}]. A salvo recoils turret by turret, each at the moment ITS first shell leaves (the muzzle
# puffs' own times, gunfire_feed.gd on_shell_fire: the shell k leaves barrel k of the drawn barrels, the fore turrets first).

const KINDS := ["tank", "ship"]
const PARTS := ["barrel", "turret", "hull"]

# The mode in force.
static func mode_of(st: RefCounted) -> String:
	var v: Variant = st.lookup("unit_art.recoil.mode")
	return str(v) if v is String else "none"

# The record of a kind's mode: {part: {m, attack_s, return_s, settle}}, {} for none or an unknown mode.
static func spec(st: RefCounted, kind: String, mode: String = "") -> Dictionary:
	if mode == "":
		mode = mode_of(st)
	if mode == "none":
		return {}
	var v: Variant = st.lookup("unit_art.recoil.%s.modes.%s" % [kind, mode])
	return v as Dictionary if v is Dictionary else {}

static func min_px(st: RefCounted, kind: String) -> float:
	var v: Variant = st.lookup("unit_art.recoil.%s.min_px" % kind)
	return float(v) if (v is float or v is int) else 0.0

# Does the mode in force move the barrel on its own (so the art must carry the barrels as parts)?
static func wants_barrel(st: RefCounted) -> bool:
	for kind: String in KINDS:
		if (spec(st, kind) as Dictionary).has("barrel"):
			return true
	return false

# The kick factor `age_s` seconds after a shot: 0 before it, a fast rise to 1 over attack_s (eased out), then back to 0 over return_s (eased; with `settle` a
# damped swing that passes rest once, at most about a quarter of the kick the other way), 0 after.
static func kick(age_s: float, part: Dictionary) -> float:
	if age_s < 0.0:
		return 0.0
	var attack := maxf(float(part.get("attack_s", 0.05)), 1e-4)
	if age_s < attack:
		var x := age_s / attack
		return 1.0 - (1.0 - x) * (1.0 - x)
	var ret := maxf(float(part.get("return_s", 0.35)), 1e-4)
	var u := (age_s - attack) / ret
	if u >= 1.0:
		return 0.0
	var base := 1.0 - u * u * (3.0 - 2.0 * u)
	var settle := clampf(float(part.get("settle", 0.0)), 0.0, 1.0)
	if settle <= 0.0:
		return base
	var damped := (1.0 - u) * cos(1.25 * PI * u)
	return lerpf(base, damped, settle)

# The second of the turn a part of the unit recoils from for one shot: a single shot, the shot's own time; a salvo, the moment the first shell of part `index`
# leaves (index turrets of `barrels` barrels each, 0.2 s apart). -1 when this part's turret fires nothing in the salvo (fewer shells than barrels).
static func shot_time(shot: Dictionary, index: int, barrels: int) -> float:
	var t := float(shot.get("t", 0.0))
	var shells := int(shot.get("salvo", 0))
	if shells <= 0:
		return t
	var first := index * maxi(barrels, 1)
	if first >= shells:
		return -1.0
	return t + float(first) * float(shot.get("interval", 0.2))

# The kick factor of `part_name` for the part `index` of `barrels` barrels, at the turn's second `t` (all the shots of the turn added, at most 1.5).
static func factor(shots: Array, t: float, index: int, barrels: int, part: Dictionary, hull: bool = false) -> float:
	var k := 0.0
	for s: Variant in shots:
		var sd: Dictionary = s
		var ts := shot_time(sd, 0 if hull else index, barrels)
		if ts < 0.0:
			continue
		k += kick(t - ts, part)
	return minf(k, 1.5)

# The kick in screen px for a part: metres of the drawn unit at `px_per_m`, floored at min_px, times the factor. Positive = back along the barrel.
static func px(part: Dictionary, px_per_m: float, floor_px: float, k: float) -> float:
	var m := float(part.get("m", 0.0))
	if m <= 0.0 or k == 0.0:
		return 0.0
	return maxf(m * px_per_m, floor_px) * k
