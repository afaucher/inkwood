extends RefCounted

# The effects' STATE, with no pixels in it: where every puff, burst, piece of
# debris and scar is and how far through its life it is at a given game time.
# Pure arithmetic from (data, seed, the calls made), so two runs make the same
# field, a headless test can check it, and the drawing layer (fx_layer.gd) only
# has to draw what this says.
#
# TIME is GAME time in seconds (turn x turn_seconds + the second of the turn): it
# advances only while a resolve plays back, so a puff that "lasts 8 turns" lasts 8
# turns, not 40 s of the player's patience. Every call that makes something takes
# the game time it happened at; every query takes the time to look at. Looking at
# an earlier time shows things not yet born as absent (scrubbing is safe).
#
# WORLD units: positions are world metres (x east, y south), heights are metres
# ABOVE THE GROUND under the thing (the host subtracts the terrain; the layer's
# ground_height seam does it for callers that have only the sea-level height).
# Sizes are the plane's size_m; an effect scales with it (planes are drawn at
# their own scale, and so is what they leave behind).
#
# THREE PHASES OF A DEATH (Alex 2026-10-09: dead planes explode mid air or lose
# control and crash eventually); the sim decides which and flies the fall:
#   explode_midair   the plane is gone: a burst at its altitude, debris falling,
#                    smoke left in the sky
#   ride (each frame while out of control)  heavy smoke, a flame, embers on the
#                    plane the sim is flying
#   impact           the crash: a burst on the ground, a plume, the scar that stays
#
# Colours and looks are not here; only numbers and ids.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxRuin = preload("res://scripts/fx/fx_ruin.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")

var data: FxData
var world_seed: int = 20261009
var smoke_name: String = "A"
var crash_name: String = "A"
var smoke_o: Dictionary = {}            # the damage-smoke option
var crash_o: Dictionary = {}            # the crash option (groups)
var common_ref_plane_m: float = 9.0
var common_size_exp: float = 0.75
var common_max_puffs: int = 1500
# The fire machinery (flames, embers) runs only when this is true; the data's switch sets it (Alex 2026-10-10: no fire for now).
var fire_on: bool = false
# A smoke option the crash's trail, burst and plume are drawn in instead of the crash option's own (the board's
# comparison frames: any damage-smoke variant as the crash smoke).
var crash_smoke_override: String = ""
# THE STRIKE (Track X2): the options for flak, bombs and the radio tower's ruin, and what they leave
var flak_name: String = "F1"
var bomb_name: String = "B1"
var ruin_name: String = "R1"
var flak_o: Dictionary = {}
var bomb_o: Dictionary = {}
var ruin_o: Dictionary = {}

var puffs: Array[Dictionary] = []
var bursts: Array[Dictionary] = []
var debris: Array[Dictionary] = []
var scars: Array[Dictionary] = []
var set_defs: Dictionary = {}           # set id -> the smoke option dictionary its puffs are baked and faded by
var riders: Dictionary = {}             # unit id -> the last pose given to ride()
var craters: Array[Dictionary] = []     # the pits bombs leave: they stay for the rest of the game
var ruins: Array[Dictionary] = []       # what a destroyed tower leaves: it stays for the rest of the game
var drops: Array[Dictionary] = []       # bombs in the air

var _emit: Dictionary = {}              # unit id -> emitter state
var _next_id: int = 0
var _dirty: bool = false

func _init(fx_data: FxData = null) -> void:
	data = fx_data if fx_data != null else FxData.shared()
	common_ref_plane_m = data.common_num("ref_plane_m")
	common_size_exp = data.common_num("size_exp")
	common_max_puffs = int(data.common_num("max_puffs"))
	fire_on = data.fire_enabled()
	select(data.working_default("smoke"), data.working_default("crash"))
	select_strike(data.working_default("flak"), data.working_default("bomb"), data.working_default("ruin"))

# Chooses the options the field runs (until Alex chooses; the data's working defaults otherwise).
func select(smoke: String, crash: String, crash_smoke: String = "") -> void:
	smoke_name = smoke
	crash_name = crash
	crash_smoke_override = crash_smoke
	smoke_o = data.smoke_option(smoke)
	crash_o = data.crash_option(crash)
	set_defs.clear()
	set_defs["smoke"] = smoke_o

# Chooses the options for the strike: flak (data fx.json flak.options), bombs and the tower's ruin. "" keeps the current one.
func select_strike(flak: String = "", bomb: String = "", ruin: String = "") -> void:
	if flak != "":
		flak_name = flak
	if bomb != "":
		bomb_name = bomb
	if ruin != "":
		ruin_name = ruin
	flak_o = data.flak_option(flak_name)
	bomb_o = data.bomb_option(bomb_name)
	ruin_o = data.ruin_option(ruin_name)

func clear() -> void:
	puffs.clear()
	bursts.clear()
	debris.clear()
	scars.clear()
	craters.clear()
	ruins.clear()
	drops.clear()
	riders.clear()
	_emit.clear()
	_next_id = 0
	_dirty = false

func counts() -> Dictionary:
	return {"puffs": puffs.size(), "bursts": bursts.size(), "debris": debris.size(), "scars": scars.size(), "riders": riders.size(),
		"craters": craters.size(), "ruins": ruins.size(), "drops": drops.size()}

# --- Size ---------------------------------------------------------------------------------------------

# A burst's size grows with the plane's, but not in proportion: (size / ref) ^ size_exp.
func size_factor(size_m: float) -> float:
	return pow(maxf(size_m, 0.5) / common_ref_plane_m, common_size_exp)

# --- Damage smoke ---------------------------------------------------------------------------------------

# The damaged plane's smoke. Called each frame the plane is on show (or from emit_path);
# puffs are left every interval(i) game seconds along the way, at positions interpolated
# between the previous call and this one. Nothing is emitted for t at or before the
# latest time this unit has already emitted at (a scrub back and forth makes no duplicates).
# `world_pos` is the plane's centre; `heading` (radians, 0 = +x) puts the smoke at its tail.
func emit_damage_smoke(unit_id: String, world_pos: Vector2, height_m: float, health_fraction: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
	var i := FxPuff.intensity(smoke_o, health_fraction)
	return _emit_trail(unit_id, "smoke", smoke_o, "smoke", i, FxPuff.tone_of(smoke_o, i), FxPuff.interval_s(smoke_o, i), world_pos, height_m, t, size_m, heading, -1.0)

# The same from a sampler (time -> {x, y, height_m, heading}) between t0 and t1, on the exact
# emission grid: independent of how often a host calls. Returns the puffs added.
func emit_path(unit_id: String, sampler: Callable, t0: float, t1: float, health_fraction: float, size_m: float = 9.0) -> int:
	var made := 0
	var i := FxPuff.intensity(smoke_o, health_fraction)
	if i <= 0.0:
		return 0
	var iv := FxPuff.interval_s(smoke_o, i)
	var st: Dictionary = _emit_state(unit_id, "smoke")
	var t := maxf(float(st.get("next", t0)), t0)
	while t <= t1 + 1e-9:
		if t > float(st.get("high", -INF)):
			var s: Dictionary = sampler.call(t)
			var pos := Vector2(float(s["x"]), float(s["y"]))
			var h := float(s.get("height_m", 0.0))
			var hd := float(s.get("heading", NAN))
			made += _add_trail_puff(unit_id, "smoke", smoke_o, "smoke", i, FxPuff.tone_of(smoke_o, i), pos, h, t, size_m, hd, -1.0)
			st["high"] = t
		t += iv
	st["next"] = t
	st["t"] = t1
	st["high"] = maxf(float(st.get("high", -INF)), t1 - 1e-9)
	return made

func _emit_state(unit_id: String, kind: String) -> Dictionary:
	var key := kind + ":" + unit_id
	if not _emit.has(key):
		_emit[key] = {}
	return _emit[key]

# One trail: accumulates along the calls. `fixed_life` < 0 takes the option's life at intensity i.
func _emit_trail(unit_id: String, kind: String, o: Dictionary, set_id: String, i: float, tone: int, interval: float, pos: Vector2, h: float, t: float, size_m: float, heading: float, fixed_life: float) -> int:
	var st: Dictionary = _emit_state(unit_id, kind)
	if not st.has("high"):
		st["high"] = -INF
	if not st.has("t") or t < float(st["t"]) - 1e-9:
		# the first call, or a scrub backwards: the path restarts here
		st["t"] = t
		st["pos"] = pos
		st["h"] = h
		st["next"] = t
	var t_prev: float = st["t"]
	var p_prev: Vector2 = st["pos"]
	var h_prev: float = st["h"]
	var nxt: float = maxf(float(st["next"]), t_prev)
	var made := 0
	if i > 0.0:
		while nxt <= t + 1e-9:
			if nxt > float(st["high"]):
				var f := 0.0 if t <= t_prev else clampf((nxt - t_prev) / (t - t_prev), 0.0, 1.0)
				made += _add_trail_puff(unit_id, kind, o, set_id, i, tone, p_prev.lerp(pos, f), lerpf(h_prev, h, f), nxt, size_m, heading, fixed_life)
				st["high"] = nxt
			nxt += interval
	else:
		nxt = t   # nothing to leave: the grid starts again where the smoke does
	st["t"] = t
	st["pos"] = pos
	st["h"] = h
	st["next"] = nxt
	st["high"] = maxf(float(st["high"]), t - 1e-9)
	return made

func _add_trail_puff(unit_id: String, kind: String, o: Dictionary, set_id: String, i: float, tone: int, pos: Vector2, h: float, t: float, size_m: float, heading: float, fixed_life: float) -> int:
	var seed_v := FxBake.seed_of(world_seed, unit_id + kind, int(round(t * 1000.0)))
	var rng := Mulberry32.new(seed_v)
	var tail := Vector2.ZERO
	if not is_nan(heading):
		tail = -Vector2.from_angle(heading) * FxData.f(o, "tail_frac") * size_m
	var wind := _wind(o, rng)
	var r_m := FxPuff.radius_m(o, i, size_m) * (0.8 + rng.next() * 0.4)
	var p := {
		"id": _new_id(), "unit": unit_id, "kind": kind, "set": set_id, "born": t,
		"pos": pos + tail + Vector2(rng.next() - 0.5, rng.next() - 0.5) * r_m * 0.7,
		"h": h, "size_m": size_m,
		"r_m": r_m,
		"tone": tone, "variant": int(rng.next() * float(FxData.i(o, "variants"))),
		"life": fixed_life if fixed_life > 0.0 else FxPuff.life_s(o, i),
		"wind": wind, "dir": 0.0 if is_nan(heading) else heading,
	}
	_add_puff(p)
	return 1

func _wind(o: Dictionary, rng: Mulberry32) -> Vector2:
	var w := FxData.arr(o, "wind_mps")
	var j := FxData.f(o, "wind_jitter_mps")
	return Vector2(float(w[0]) + (rng.next() - 0.5) * 2.0 * j, float(w[1]) + (rng.next() - 0.5) * 2.0 * j)

func _new_id() -> int:
	_next_id += 1
	return _next_id

func _add_puff(p: Dictionary) -> void:
	if not puffs.is_empty() and float(p["born"]) < float((puffs[puffs.size() - 1] as Dictionary)["born"]):
		_dirty = true
	puffs.append(p)
	if puffs.size() > common_max_puffs:
		# The oldest by birth go first: deterministic, and what the eye misses least.
		_sort_if_dirty()
		puffs.remove_at(0)

func _sort_if_dirty() -> void:
	if _dirty:
		puffs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["born"]) < float(b["born"]) or (float(a["born"]) == float(b["born"]) and int(a["id"]) < int(b["id"])))
		_dirty = false

# --- A puff at a time ----------------------------------------------------------------------------------------

# {alive, pos (world m), h, alpha, scale (1 = as baked relative to r_m), age_u} at game time t.
func puff_state(p: Dictionary, t: float) -> Dictionary:
	var age := t - float(p["born"])
	var life := float(p["life"])
	if age < 0.0 or age >= life:
		return {"alive": false}
	var u := age / maxf(life, 1e-6)
	var kind: String = p["kind"]
	if kind == "ember" or kind == "scar_ember":
		var a := 1.0 - u
		if kind == "scar_ember":
			# an ember glows, dims and glows again on its way out: blink by the game clock
			var blink := fmod(age * 3.0 + float(int(p["id"]) % 7), 1.0)
			a = (1.0 - u * u) * (0.55 + 0.45 * float(blink < 0.62))
		return {"alive": true, "pos": (p["pos"] as Vector2) + (p["wind"] as Vector2) * age, "h": float(p["h"]), "alpha": clampf(a, 0.0, 1.0), "scale": 1.0, "u": u}
	var o: Dictionary = set_defs.get(p["set"], smoke_o)
	var thrown := Vector2.ZERO
	if p.has("vel"):
		# a burst throws its smoke outward, fast, then drag takes it: v x tau x (1 - e^(-age / tau))
		var tau := maxf(float(p["vel_tau"]), 1e-3)
		thrown = (p["vel"] as Vector2) * (tau * (1.0 - exp(-age / tau)))
	return {
		"alive": true,
		"pos": (p["pos"] as Vector2) + (p["wind"] as Vector2) * age + thrown,
		"h": float(p["h"]) + float(p.get("rise", 0.0)) * age,
		"alpha": FxPuff.alpha_at(o, u),
		"scale": FxPuff.grow_at(o, u),
		"u": u,
	}

func alive_puffs(t: float) -> Array:
	_sort_if_dirty()
	var out: Array = []
	for p in puffs:
		if float(p["born"]) > t:
			continue
		var s := puff_state(p, t)
		if bool(s["alive"]):
			out.append([p, s])
	return out

# Forgets what is long dead (older than 10 s past its end at `t`). Never removes a scar.
func prune(t: float) -> void:
	var keep: Array[Dictionary] = []
	for p in puffs:
		if t <= float(p["born"]) + float(p["life"]) + 10.0:
			keep.append(p)
	puffs = keep
	var kb: Array[Dictionary] = []
	for b in bursts:
		if t <= float(b["t0"]) + float(b["end_s"]) + 10.0:
			kb.append(b)
	bursts = kb
	var kd: Array[Dictionary] = []
	for d in debris:
		if t <= float(d["t0"]) + float(d["land_s"]) + float(d["rest_s"]) + 10.0:
			kd.append(d)
	debris = kd
	var kdr: Array[Dictionary] = []
	for dr in drops:
		if t <= float(dr["t1"]) + 10.0:
			kdr.append(dr)
	drops = kdr

# --- Out of control -------------------------------------------------------------------------------------------------

# Called each frame a plane is falling out of control (from World.sample): the trail of
# heavy smoke it leaves, the embers it sheds, and the pose the layer hangs its flame on.
func ride(unit_id: String, world_pos: Vector2, height_m: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
	var fall := FxData.grp(crash_o, "falling")
	var smoke_key := _smoke_key(FxData.s(fall, "smoke_option"))
	var o := _fall_smoke(smoke_key, fall)
	var i := FxData.f(fall, "intensity")
	var made := _emit_trail(unit_id, "fall", o, "fall:" + smoke_key, i, FxData.i(fall, "tone"), FxData.f(fall, "interval_s"), world_pos, height_m, t, size_m, heading, FxData.f(fall, "life_s"))
	var fl := FxData.grp(fall, "flame")
	if fire_on and FxData.b(fl, "enabled"):
		var every := FxData.f(fl, "ember_every_s")
		if every > 0.0:
			made += _shed_embers(unit_id, fl, every, world_pos, height_m, t, size_m)
	riders[unit_id] = {"pos": world_pos, "h": height_m, "heading": heading, "size_m": size_m, "t": t}
	return made

# The smoke option a crash's smoke is drawn in: the crash option's own, or the board's override.
func _smoke_key(declared: String) -> String:
	return crash_smoke_override if crash_smoke_override != "" else declared

# Thick smoke casts a ground shadow (Alex 2026-10-10), whatever the damage-smoke option says: the crash's groups
# carry ground_shadow and shadow_min_tone, which the sets derived from the option take.
func _shadow_flags(po: Dictionary, grp: Dictionary) -> void:
	po["ground_shadow"] = FxData.b(grp, "ground_shadow")
	po["shadow_min_tone"] = FxData.i(grp, "shadow_min_tone")
	# a dense crash burst, plume, column or trail overlaps many puffs: a translucent option is drawn at its burst_alpha
	po["peak_alpha"] = FxData.f(po, "burst_alpha")

func _fall_smoke(smoke_key: String, fall: Dictionary) -> Dictionary:
	var id := "fall:" + smoke_key
	if not set_defs.has(id):
		var po := data.smoke_option(smoke_key).duplicate(true)
		_shadow_flags(po, fall)
		set_defs[id] = po
	return set_defs[id]

func _shed_embers(unit_id: String, fl: Dictionary, every: float, pos: Vector2, h: float, t: float, size_m: float) -> int:
	var st: Dictionary = _emit_state(unit_id, "ember")
	var made := 0
	if not st.has("t") or t < float(st["t"]) - 1e-9:
		st["t"] = t
		st["next"] = t + every
		if not st.has("high"):
			st["high"] = t
		return 0
	var nxt: float = st["next"]
	while nxt <= t + 1e-9:
		if nxt > float(st["high"]):
			var rng := Mulberry32.new(FxBake.seed_of(world_seed, unit_id + "ember", int(round(nxt * 1000.0))))
			var a := rng.next() * TAU
			var p := {
				"id": _new_id(), "unit": unit_id, "kind": "ember", "set": "", "born": nxt,
				"pos": pos + Vector2.from_angle(a) * size_m * 0.3, "h": h, "size_m": size_m, "r_m": 0.0,
				"tone": 0, "variant": 0, "life": FxData.f(fl, "ember_life_s") * (0.7 + rng.next() * 0.6),
				"wind": Vector2.from_angle(a) * (2.0 + rng.next() * 3.0),
			}
			_add_puff(p)
			st["high"] = nxt
			made += 1
		nxt += every
	st["t"] = t
	st["next"] = nxt
	return made

# --- A mid-air explosion ---------------------------------------------------------------------------------------------------

func explode_midair(unit_id: String, world_pos: Vector2, height_m: float, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
	riders.erase(unit_id)
	var mid := FxData.grp(crash_o, "midair")
	var b := FxData.grp(crash_o, "burst")
	var rng := Mulberry32.new(FxBake.seed_of(world_seed, unit_id + "mid", int(round(t * 1000.0))))
	bursts.append({
		"id": _new_id(), "unit": unit_id, "phase": "midair", "t0": t, "pos": world_pos, "h": maxf(height_m, 0.0),
		"size_m": size_m, "seed": int(rng.next() * 2147483647.0), "end_s": FxData.f(b, "end_s"),
		"radius_m": _burst_radius_m(b, size_m) * FxData.f(mid, "radius_scale"),
	})
	_add_smoke_burst(unit_id, "mid", FxData.grp(mid, "smoke_burst"), world_pos, height_m, t, size_m, rng)
	_add_plume(unit_id, "mid", FxData.grp(mid, "plume"), world_pos, height_m, t, size_m, rng)
	_add_debris(unit_id, FxData.grp(mid, "debris"), world_pos, height_m, t, size_m, rng)

func _burst_radius_m(b: Dictionary, size_m: float) -> float:
	return FxData.f(b, "radius_frac") * common_ref_plane_m * size_factor(size_m)

# The plume's puffs, born over the first moments, long-lived.
func _add_plume(unit_id: String, phase: String, pl: Dictionary, pos: Vector2, h: float, t: float, size_m: float, rng: Mulberry32, base_m: float = -1.0) -> void:
	var smoke_key := _smoke_key(FxData.s(pl, "smoke_option"))
	var id := "plume:%s:%s:%s" % [crash_name, phase, smoke_key]
	if not set_defs.has(id):
		var po := data.smoke_option(smoke_key).duplicate(true)
		po["radius_frac"] = FxData.arr(pl, "radius_frac").duplicate()
		var life := FxData.f(pl, "life_s")
		po["life_s"] = [life, life]
		po["grow"] = FxData.arr(pl, "grow").duplicate()
		po["hold"] = FxData.f(pl, "hold")
		po["fade_power"] = FxData.f(pl, "fade_power")
		po["alpha_steps"] = []
		_shadow_flags(po, pl)
		set_defs[id] = po
	var o: Dictionary = set_defs[id]
	var rf := FxData.arr(pl, "radius_frac")
	var sf := size_factor(size_m)
	var unit_m := base_m if base_m > 0.0 else common_ref_plane_m * sf   # metres a radius_frac of 1 stands for
	var n := FxData.i(pl, "count")
	for k in n:
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * FxData.f(pl, "spread_frac") * unit_m
		var born := t + FxData.f(pl, "delay_s") + float(k) * FxData.f(pl, "interval_s")
		_add_puff({
			"id": _new_id(), "unit": unit_id, "kind": "plume", "set": id, "born": born,
			"pos": pos + Vector2.from_angle(a) * d, "h": maxf(h, 0.0), "size_m": size_m,
			"r_m": lerpf(float(rf[0]), float(rf[1]), rng.next()) * unit_m,
			"tone": FxData.i(pl, "tone"), "variant": int(rng.next() * float(FxData.i(o, "variants"))),
			"life": FxData.f(pl, "life_s"), "wind": _wind(o, rng),
		})

# The wreck keeps smoking (Alex 2026-10-09: "an explosion, then smoking"): a column of puffs from
# the wreck for the data's duration, born at a rate that falls as the wreck burns out, narrowing
# and greying from the heavy tone to the thin one, each puff drifting downwind and rising.
func _add_smolder(unit_id: String, sm: Dictionary, pos: Vector2, t: float, size_m: float, rng: Mulberry32, base_m: float = -1.0, id_tag: String = "") -> void:
	var smoke_key := _smoke_key(FxData.s(sm, "smoke_option"))
	var id := "smolder:%s:%s%s" % [crash_name, smoke_key, id_tag]
	var rf := FxData.arr(sm, "radius_frac")
	if not set_defs.has(id):
		var po := data.smoke_option(smoke_key).duplicate(true)
		po["radius_frac"] = [minf(float(rf[0]), float(rf[1])), maxf(float(rf[0]), float(rf[1]))]
		var life := FxData.f(sm, "life_s")
		po["life_s"] = [life, life]
		po["grow"] = FxData.arr(sm, "grow").duplicate()
		po["hold"] = FxData.f(sm, "hold")
		po["fade_power"] = FxData.f(sm, "fade_power")
		po["alpha_steps"] = []
		po["wind_jitter_mps"] = FxData.f(sm, "wind_jitter_mps")
		_shadow_flags(po, sm)
		set_defs[id] = po
	var o: Dictionary = set_defs[id]
	var dur := FxData.f(sm, "duration_s")
	var iv := FxData.arr(sm, "interval_s")
	var edges := FxData.arr(sm, "tone_edges_frac")
	var sf := size_factor(size_m)
	var unit_m := base_m if base_m > 0.0 else common_ref_plane_m * sf
	var el := FxData.f(sm, "delay_s")
	var guard := 0
	while el < dur and guard < 2000:
		guard += 1
		var fr := el / dur
		var tone := 2
		if fr >= float(edges[1]):
			tone = 0
		elif fr >= float(edges[0]):
			tone = 1
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * 0.25 * unit_m
		_add_puff({
			"id": _new_id(), "unit": unit_id, "kind": "smolder", "set": id, "born": t + el,
			"pos": pos + Vector2.from_angle(a) * d, "h": 0.0, "rise": FxData.f(sm, "rise_mps"), "size_m": size_m,
			"r_m": lerpf(float(rf[0]), float(rf[1]), fr) * unit_m * (0.8 + rng.next() * 0.4),
			"tone": tone, "variant": int(rng.next() * float(FxData.i(o, "variants"))),
			"life": FxData.f(sm, "life_s"), "wind": _wind(o, rng),
		})
		# the interval stretches from its first value to its second over the duration
		el += lerpf(float(iv[0]), float(iv[1]), fr)

# THE SMOKE BURST (no fire: Alex 2026-10-10): an explosion is a quick thick burst of smoke. Puffs of the
# smoke option, in the heavy tone, thrown outward fast from the burst point (v, slowed by drag) while they swell
# quickly, rising a little, then hanging and fading very slowly like any plume. Thick, so it casts a shadow.
func _add_smoke_burst(unit_id: String, phase: String, sb: Dictionary, pos: Vector2, h: float, t: float, size_m: float, rng: Mulberry32, base_m: float = -1.0) -> void:
	var smoke_key := _smoke_key(FxData.s(sb, "smoke_option"))
	var id := "burst:%s:%s:%s" % [crash_name, phase, smoke_key]
	var rf := FxData.arr(sb, "radius_frac")
	if not set_defs.has(id):
		var po := data.smoke_option(smoke_key).duplicate(true)
		po["radius_frac"] = [minf(float(rf[0]), float(rf[1])), maxf(float(rf[0]), float(rf[1]))]
		var life := FxData.f(sb, "life_s")
		po["life_s"] = [life, life]
		po["grow"] = FxData.arr(sb, "grow").duplicate()
		po["grow_tau"] = FxData.f(sb, "grow_tau")
		po["hold"] = FxData.f(sb, "hold")
		po["fade_power"] = FxData.f(sb, "fade_power")
		po["alpha_steps"] = []
		_shadow_flags(po, sb)
		set_defs[id] = po
	var o: Dictionary = set_defs[id]
	var sf := size_factor(size_m)
	var unit_m := base_m if base_m > 0.0 else common_ref_plane_m * sf
	var v_k := base_m if base_m > 0.0 else sf   # speeds: m/s x size factor, or (with a base) fractions of the base per second
	var sp := FxData.arr(sb, "speed_mps")
	for k in FxData.i(sb, "count"):
		var a := rng.next() * TAU
		var v := lerpf(float(sp[0]), float(sp[1]), rng.next()) * v_k
		_add_puff({
			"id": _new_id(), "unit": unit_id, "kind": "burst", "set": id,
			"born": t + FxData.f(sb, "delay_s") + float(k) * FxData.f(sb, "interval_s"),
			"pos": pos + Vector2.from_angle(a) * rng.next() * 0.15 * unit_m, "h": maxf(h, 0.0),
			"rise": FxData.f(sb, "rise_mps"), "size_m": size_m,
			"r_m": lerpf(float(rf[0]), float(rf[1]), rng.next()) * unit_m,
			"tone": FxData.i(sb, "tone"), "variant": int(rng.next() * float(FxData.i(o, "variants"))),
			"life": FxData.f(sb, "life_s"), "wind": _wind(o, rng),
			"vel": Vector2.from_angle(a) * v, "vel_tau": FxData.f(sb, "vel_tau_s"),
		})

func _add_debris(unit_id: String, d: Dictionary, pos: Vector2, h: float, t: float, size_m: float, rng: Mulberry32) -> void:
	var sp := FxData.arr(d, "speed_mps")
	var spin := FxData.arr(d, "spin_dps")
	var g := FxData.f(d, "gravity_mps2")
	var land := sqrt(2.0 * maxf(h, 0.0) / maxf(g, 1e-3))
	for k in FxData.i(d, "count"):
		var a := rng.next() * TAU
		var v := lerpf(float(sp[0]), float(sp[1]), rng.next())
		debris.append({
			"id": _new_id(), "unit": unit_id, "t0": t, "pos0": pos, "h0": maxf(h, 0.0),
			"v": Vector2.from_angle(a) * v * size_factor(size_m), "tau": FxData.f(d, "drag_tau_s"), "g": g,
			"land_s": land, "rest_s": FxData.f(d, "rest_s"), "size_m": size_m,
			"spin0": rng.next() * TAU, "spin": deg_to_rad(lerpf(float(spin[0]), float(spin[1]), rng.next())),
			"variant": int(rng.next() * float(FxData.i(d, "shard_variants"))),
		})

# A piece of debris at game time t: {alive, pos, h, rot, landed, alpha} or {alive: false}.
func debris_state(d: Dictionary, t: float) -> Dictionary:
	var age := t - float(d["t0"])
	if age < 0.0:
		return {"alive": false}
	var land := float(d["land_s"])
	var tau := maxf(float(d["tau"]), 1e-3)
	var tt := minf(age, land)
	var pos: Vector2 = (d["pos0"] as Vector2) + (d["v"] as Vector2) * (tau * (1.0 - exp(-tt / tau)))
	if age < land:
		var h := float(d["h0"]) + float(d.get("vz", 0.0)) * age - 0.5 * float(d["g"]) * age * age
		return {"alive": true, "pos": pos, "h": maxf(h, 0.0), "rot": float(d["spin0"]) + float(d["spin"]) * age, "landed": false, "alpha": 1.0}
	var rest := float(d["rest_s"])
	var since := age - land
	if rest <= 0.0 or since >= rest:
		return {"alive": false}
	return {"alive": true, "pos": pos, "h": 0.0, "rot": float(d["spin0"]) + float(d["spin"]) * land, "landed": true, "alpha": 1.0 - since / rest}

# --- The ground impact ------------------------------------------------------------------------------------------------------------

func impact(unit_id: String, ground_pos: Vector2, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
	riders.erase(unit_id)
	var imp := FxData.grp(crash_o, "impact")
	var b := FxData.grp(crash_o, "burst")
	var rng := Mulberry32.new(FxBake.seed_of(world_seed, unit_id + "hit", int(round(t * 1000.0))))
	bursts.append({
		"id": _new_id(), "unit": unit_id, "phase": "impact", "t0": t, "pos": ground_pos, "h": 0.0,
		"size_m": size_m, "seed": int(rng.next() * 2147483647.0), "end_s": FxData.f(b, "end_s"),
		"radius_m": _burst_radius_m(b, size_m) * FxData.f(imp, "radius_scale"),
	})
	_add_smoke_burst(unit_id, "hit", FxData.grp(imp, "smoke_burst"), ground_pos, 0.0, t, size_m, rng)
	_add_plume(unit_id, "hit", FxData.grp(imp, "plume"), ground_pos, 0.0, t, size_m, rng)
	_add_smolder(unit_id, FxData.grp(imp, "smolder"), ground_pos, t, size_m, rng)
	add_scar(unit_id, ground_pos, t, size_m, (rng.next() * TAU) if is_nan(heading) else heading, int(rng.next() * 2147483647.0))

# The mark that stays. Also the way to put one back when a game in progress is loaded or joined
# (the crash events are replayed through this with their own times).
func add_scar(unit_id: String, ground_pos: Vector2, t: float, size_m: float, rot: float, seed_v: int) -> void:
	var sc := FxData.grp(FxData.grp(crash_o, "impact"), "scar")
	scars.append({"id": _new_id(), "unit": unit_id, "t0": t, "pos": ground_pos, "size_m": size_m, "rot": rot, "seed": seed_v,
		"variant": seed_v % maxi(FxData.i(sc, "variants"), 1)})
	var n := FxData.i(sc, "embers") if fire_on else 0
	if n > 0:
		var rng := Mulberry32.new(FxBake.seed_of(world_seed, unit_id + "emb", seed_v))
		var R := FxData.f(sc, "radius_frac") * common_ref_plane_m * size_factor(size_m)
		for k in n:
			var a := rng.next() * TAU
			var d := sqrt(rng.next()) * R * FxData.f(sc, "ember_spread_frac")
			_add_puff({
				"id": _new_id(), "unit": unit_id, "kind": "scar_ember", "set": "", "born": t + 0.4 + rng.next() * 1.5,
				"pos": ground_pos + Vector2.from_angle(a) * d, "h": 0.0, "size_m": size_m, "r_m": 0.0,
				"tone": 0, "variant": 0, "life": FxData.f(sc, "ember_life_s") * (0.6 + rng.next() * 0.8), "wind": Vector2.ZERO,
			})

# The flipbook frame a burst shows at game time t, or -1.
func burst_frame(b: Dictionary, t: float) -> int:
	var frames := FxData.arr(burst_def(b), "frames_s")
	return FxBurst.frame_index(frames, float(b["end_s"]), t - float(b["t0"]))

# The flipbook's data for a burst: the crash option's burst group, or the strike's flash group (flak, bomb, ruin).
func burst_def(b: Dictionary) -> Dictionary:
	match str(b.get("grp", "crash")):
		"flak":
			return FxData.grp(flak_o, "flash")
		"bomb":
			return FxData.grp(bomb_o, "flash")
		"ruin":
			return FxData.grp(ruin_o, "flash")
	return FxData.grp(crash_o, "burst")

# A scar's strength at t: it blackens over the first moments, then stays for the rest of the game.
func scar_alpha(s: Dictionary, t: float) -> float:
	var age := t - float(s["t0"])
	if age < 0.0:
		return 0.0
	return clampf(age / 1.5, 0.0, 1.0)

# =====================================================================================================================
# THE STRIKE (Track X2, 2026-10-10): flak, bombs and the radio tower. Everything below follows the same rules as
# the rest: pure arithmetic from (data, seed, the calls made), game time, metres above the ground, nothing
# random but the call's own seed. A strike's smoke is the damage smoke's (the crash's smoke override applies).
# =====================================================================================================================

# A seed from the call's own arguments: the same call draws the same effect on every peer, and two shots at one
# moment draw different ones.
func _seed_call(tag: String, key: String, t: float) -> int:
	return FxBake.seed_of(world_seed, tag + "|" + key, int(round(t * 1000.0)))

# --- Flak -----------------------------------------------------------------------------------------------------------------

# A flak shell bursts near its target at game time t. `target_pos` and `height_m` are the target's centre (the
# "fire" event's tx, ty and theight_m, the height above the ground); `hit` is the shot's own roll. A HIT bursts on
# the target; a MISS bursts beside it, short or over (the sim says only that it missed; where is the effects' call,
# proposed in data: flak.options.X.burst.miss_offset_m). `shot_id` tells two shots at one moment apart (any
# string); `size_m` overrides the option's burst size.
func flak_burst(target_pos: Vector2, height_m: float, t: float, hit: bool, shot_id: String = "", size_m: float = 0.0) -> void:
	var o := flak_o
	var fl := FxData.grp(o, "flash")
	var bg := FxData.grp(o, "burst")
	var size := size_m if size_m > 0.0 else FxData.f(bg, "size_m")
	var rng := Mulberry32.new(_seed_call("flak", "%s|%.1f,%.1f" % [shot_id, target_pos.x, target_pos.y], t))
	var a0 := rng.next() * TAU
	var pos := target_pos
	var h := height_m
	if hit:
		var ho := FxData.arr(bg, "hit_offset_m")
		pos += Vector2.from_angle(a0) * lerpf(float(ho[0]), float(ho[1]), rng.next())
	else:
		var mo := FxData.arr(bg, "miss_offset_m")
		var dh := FxData.arr(bg, "miss_dh_m")
		pos += Vector2.from_angle(a0) * lerpf(float(mo[0]), float(mo[1]), rng.next())
		h += lerpf(float(dh[0]), float(dh[1]), rng.next())
	h = maxf(h, FxData.f(bg, "min_height_m"))
	var id := "flak:%s" % flak_name
	if not set_defs.has(id):
		var po := FxData.grp(o, "puff").duplicate(true)
		po["ground_shadow"] = FxData.b(bg, "ground_shadow")
		po["shadow_min_tone"] = FxData.i(bg, "shadow_min_tone")
		set_defs[id] = po
	var po2: Dictionary = set_defs[id]
	var hs := FxData.f(fl, "hit_scale") if hit else 1.0
	bursts.append({
		"id": _new_id(), "unit": shot_id, "phase": "flak", "grp": "flak", "hit": hit, "t0": t, "pos": pos, "h": h,
		"size_m": size, "seed": int(rng.next() * 2147483647.0), "end_s": FxData.f(fl, "end_s"),
		"radius_m": FxData.f(fl, "radius_frac") * size * hs,
	})
	var n := FxData.i(bg, "puffs_hit") if hit else FxData.i(bg, "puffs_miss")
	var rf := FxData.arr(bg, "radius_frac")
	var life := FxData.f(bg, "life_s") * (FxData.f(bg, "hit_life_scale") if hit else 1.0)
	var rs := FxData.f(bg, "hit_radius_scale") if hit else 1.0
	for k in n:
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * FxData.f(bg, "spread_frac") * size * (0.3 if k == 0 else 1.0)
		_add_puff({
			"id": _new_id(), "unit": shot_id, "kind": "flak", "set": id,
			"born": t + FxData.f(bg, "delay_s") + float(k) * FxData.f(bg, "interval_s"),
			"pos": pos + Vector2.from_angle(a) * d, "h": h, "size_m": size, "rise": FxData.f(bg, "rise_mps"),
			"r_m": lerpf(float(rf[0]), float(rf[1]), rng.next()) * size * rs,
			"tone": FxData.i(bg, "tone_hit") if hit else FxData.i(bg, "tone_miss"),
			"variant": int(rng.next() * float(FxData.i(po2, "variants"))),
			"life": life * (0.9 + rng.next() * 0.2), "wind": _wind(po2, rng),
		})

# --- Bombs --------------------------------------------------------------------------------------------------------------------

# A bomb in the air: released at `t_release` from `from_pos` at `height_m` above the ground, landing at `to_pos`
# at `t_impact` (the sim's bomb record: x0, y0, h0, x, y, and the release and impact times in game seconds).
# Horizontally it flies a straight line; its height falls as h0 (1 - u^2), u the share of the fall flown, as
# Bombs.bomb_position says. It is drawn (with a shadow by the altitude rule) from release to impact.
func bomb_drop(unit_id: String, bomb_id: int, from_pos: Vector2, height_m: float, t_release: float, to_pos: Vector2, t_impact: float) -> void:
	drops.append({"id": _new_id(), "unit": unit_id, "bomb": bomb_id, "from": from_pos, "to": to_pos,
		"h0": maxf(height_m, 0.0), "t0": t_release, "t1": maxf(t_impact, t_release + 0.01)})

# {alive, pos, h, heading, u} of a falling bomb at game time t.
func drop_state(d: Dictionary, t: float) -> Dictionary:
	var t0: float = d["t0"]
	var t1: float = d["t1"]
	if t < t0 or t >= t1:
		return {"alive": false}
	var u := (t - t0) / (t1 - t0)
	var a: Vector2 = d["from"]
	var b: Vector2 = d["to"]
	return {"alive": true, "pos": a.lerp(b, u), "h": float(d["h0"]) * (1.0 - u * u), "heading": (b - a).angle() if a.distance_to(b) > 0.01 else 0.0, "u": u}

# A bomb lands at game time t. `blast_m` is the sim's blast radius (the bomb_impact event's): the flash, the smoke,
# the clods and the crater are sized by it (fractions of it, in data: bomb.options.X). The crater stays.
func bomb_impact(ground_pos: Vector2, t: float, blast_m: float = 45.0, unit_id: String = "", bomb_id: int = 0) -> void:
	var o := bomb_o
	var fl := FxData.grp(o, "flash")
	var rng := Mulberry32.new(_seed_call("bomb", "%s|%d|%.1f,%.1f" % [unit_id, bomb_id, ground_pos.x, ground_pos.y], t))
	var tag := "bomb:" + bomb_name
	bursts.append({
		"id": _new_id(), "unit": unit_id, "phase": "bomb", "grp": "bomb", "hit": false, "t0": t, "pos": ground_pos, "h": 0.0,
		"size_m": blast_m, "seed": int(rng.next() * 2147483647.0), "end_s": FxData.f(fl, "end_s"),
		"radius_m": FxData.f(fl, "radius_frac") * blast_m,
	})
	_add_smoke_burst(unit_id, tag, FxData.grp(o, "smoke_burst"), ground_pos, 0.0, t, blast_m, rng, blast_m)
	_add_plume(unit_id, tag, FxData.grp(o, "plume"), ground_pos, 0.0, t, blast_m, rng, blast_m)
	_add_clods(unit_id, "clod", FxData.grp(o, "debris"), ground_pos, 0.0, t, blast_m, rng, blast_m)
	add_crater(unit_id, ground_pos, t, blast_m, int(rng.next() * 2147483647.0))

# Pieces of earth (or, for the tower, bars of lattice) thrown up: `kind` is "clod" or "bar". Speeds are fractions of
# `base_m` per second, vertical speeds m/s.
func _add_clods(unit_id: String, kind: String, d: Dictionary, pos: Vector2, h0: float, t: float, size_m: float, rng: Mulberry32, base_m: float) -> void:
	var sp := FxData.arr(d, "speed_frac")
	var up := FxData.arr(d, "up_mps")
	var spin := FxData.arr(d, "spin_dps")
	var g := FxData.f(d, "gravity_mps2")
	var variants := FxData.i(d, "clod_variants" if kind == "clod" else "bar_variants")
	for k in FxData.i(d, "count"):
		var a := rng.next() * TAU
		var v := lerpf(float(sp[0]), float(sp[1]), rng.next()) * base_m
		var vz := lerpf(float(up[0]), float(up[1]), rng.next())
		var land := (vz + sqrt(vz * vz + 2.0 * g * h0)) / g
		debris.append({
			"id": _new_id(), "unit": unit_id, "kind": kind, "t0": t, "pos0": pos, "h0": h0, "vz": vz,
			"v": Vector2.from_angle(a) * v, "tau": FxData.f(d, "drag_tau_s"), "g": g, "land_s": land, "rest_s": FxData.f(d, "rest_s"),
			"size_m": size_m, "spin0": rng.next() * TAU, "spin": deg_to_rad(lerpf(float(spin[0]), float(spin[1]), rng.next())),
			"variant": int(rng.next() * float(variants)),
		})

# The pit a bomb leaves. Also the way to put one back when a game in progress is loaded or joined (the bomb
# events are replayed through bomb_impact with their own times, or add_crater alone puts the bare mark down).
func add_crater(unit_id: String, ground_pos: Vector2, t: float, blast_m: float, seed_v: int) -> void:
	var cr := FxData.grp(bomb_o, "crater")
	var rng := Mulberry32.new(seed_v)
	craters.append({"id": _new_id(), "unit": unit_id, "t0": t, "pos": ground_pos, "size_m": blast_m, "seed": seed_v,
		"variant": seed_v % maxi(FxData.i(cr, "variants"), 1), "rot": rng.next() * TAU})

# A crater's strength at t: it darkens over its first moments (under the smoke), then stays for the rest of the game.
func crater_alpha(c: Dictionary, t: float) -> float:
	var age := t - float(c["t0"])
	if age < 0.0:
		return 0.0
	return clampf(age / maxf(FxData.f(FxData.grp(bomb_o, "crater"), "fade_in_s"), 1e-6), 0.0, 1.0)

# --- The radio tower ------------------------------------------------------------------------------------------------------------

# The tower is destroyed at game time t (the "down" event, fate "destroyed"): the flash, the blast's smoke, the mast
# coming down (or flung apart, by the option), the column of smoke that thins over turns, and the ruin that stays
# for the rest of the game. `heading` is the tower unit's heading (the markers' convention: the hut turns with it);
# `size_m` the unit's size (12 m). Calling it again with the true time puts the whole picture back for a
# late joiner, the column and all (the same call draws the same effect); add_ruin() alone puts down the bare ruin.
func ruin(unit_id: String, world_pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0) -> void:
	var o := ruin_o
	var fl := FxData.grp(o, "flash")
	var rng := Mulberry32.new(_seed_call("ruin", "%s|%s" % [unit_id, kind], t))
	var seed_v := int(rng.next() * 2147483647.0)
	var rec := add_ruin(unit_id, world_pos, t, kind, size_m, heading, seed_v)
	var is_tower := kind == "radio_tower"
	var tag := "ruin:" + ruin_name
	bursts.append({
		"id": _new_id(), "unit": unit_id, "phase": "tower", "grp": "ruin", "hit": false, "t0": t, "pos": world_pos, "h": 0.0,
		"size_m": size_m, "seed": int(rng.next() * 2147483647.0), "end_s": FxData.f(fl, "end_s"),
		"radius_m": FxData.f(fl, "radius_frac") * size_m,
	})
	_add_smoke_burst(unit_id, tag, FxData.grp(o, "smoke_burst"), world_pos, 0.0, t, size_m, rng, size_m)
	var col := FxData.grp(o, "collapse")
	if is_tower and FxData.s(col, "mode") == "topple":
		var H := float(tower_model().p["height"])
		var end_pos := world_pos + Vector2.from_angle(float(rec["fall_rad"])) * H * FxData.f(col, "end_frac")
		_add_smoke_burst(unit_id, tag + ":end", FxData.grp(o, "end_burst"), end_pos, 0.0, t, size_m, rng, size_m)
	var deb := FxData.grp(o, "debris")
	if is_tower and FxData.i(deb, "count") > 0:
		_add_clods(unit_id, "bar", deb, world_pos, FxData.f(deb, "h0_m"), t, size_m, rng, size_m)
	_add_plume(unit_id, tag, FxData.grp(o, "plume"), world_pos, 0.0, t, size_m, rng, size_m)
	_add_smolder(unit_id, FxData.grp(o, "smolder"), world_pos, t, size_m, rng, size_m, ":" + tag)

# The ruin alone (a game in progress put back): the same record ruin() makes from `seed_v`; returns it.
func add_ruin(unit_id: String, world_pos: Vector2, t: float, kind: String, size_m: float, heading: float, seed_v: int) -> Dictionary:
	var variants := maxi(FxData.i(ruin_o, "variants"), 1)
	var rec := {"id": _new_id(), "unit": unit_id, "kind": kind, "t0": t, "pos": world_pos, "heading": heading, "size_m": size_m,
		"seed": seed_v, "variant": seed_v % variants, "fall_rad": float((seed_v / 7) % 62832) / 10000.0}
	ruins.append(rec)
	return rec

# The sheet's variant of the tower: the unit marker's (ui.json unit_art.variant.radio_tower), so the ruin is made of the
# parts of the very tower that stood there; the option's own `model.variant` only when the UI data does not name one.
func tower_variant() -> int:
	var ui: RefCounted = load("res://scripts/ui/ui_style.gd").shared()
	if ui != null and ui.has_method("lookup"):
		var v: Variant = ui.lookup("unit_art.variant.radio_tower")
		if v is float or v is int:
			return int(v)
	return FxData.i(FxData.grp(ruin_o, "model"), "variant")

func tower_model() -> FxRuin.Model:
	var st: FxStyle = FxStyle.shared()
	return FxRuin.tower_model(st.scene_seed, tower_variant())

# Which frame of the mast's fall a ruin shows at game time t: an index into the option's collapse frames_s, or -1
# (not yet, or over: the mast then lies in the lying sprite).
func ruin_collapse_frame(r: Dictionary, t: float) -> int:
	var col := FxData.grp(ruin_o, "collapse")
	if FxData.s(col, "mode") != "topple" or str(r.get("kind", "radio_tower")) != "radio_tower":
		return -1
	var age := t - float(r["t0"])
	if age < 0.0 or age >= FxData.f(col, "duration_s"):
		return -1
	return FxBurst.frame_index(FxData.arr(col, "frames_s"), FxData.f(col, "duration_s"), age)

# Whether the lying mast shows at game time t (once it is down, or at once for an option whose mast lies at the blast).
func ruin_lying(r: Dictionary, t: float) -> bool:
	if not FxData.b(FxData.grp(ruin_o, "lattice"), "fallen") or str(r.get("kind", "radio_tower")) != "radio_tower":
		return false
	var age := t - float(r["t0"])
	if age < 0.0:
		return false
	var col := FxData.grp(ruin_o, "collapse")
	if FxData.s(col, "mode") == "topple":
		return age >= FxData.f(col, "duration_s")
	return true

# What stays at the foot of the mast shows from the blast (a quick fade-in under the flash).
func ruin_alpha(r: Dictionary, t: float) -> float:
	var age := t - float(r["t0"])
	if age < 0.0:
		return 0.0
	return clampf(age / maxf(FxData.f(FxData.grp(ruin_o, "remains"), "fade_in_s"), 1e-6), 0.0, 1.0)
