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

var data: FxData
var world_seed: int = 20261009
var smoke_name: String = "A"
var crash_name: String = "A"
var smoke_o: Dictionary = {}            # the damage-smoke option
var crash_o: Dictionary = {}            # the crash option (groups)
var common_ref_plane_m: float = 9.0
var common_size_exp: float = 0.75
var common_max_puffs: int = 1500

var puffs: Array[Dictionary] = []
var bursts: Array[Dictionary] = []
var debris: Array[Dictionary] = []
var scars: Array[Dictionary] = []
var set_defs: Dictionary = {}           # set id -> the smoke option dictionary its puffs are baked and faded by
var riders: Dictionary = {}             # unit id -> the last pose given to ride()

var _emit: Dictionary = {}              # unit id -> emitter state
var _next_id: int = 0
var _dirty: bool = false

func _init(fx_data: FxData = null) -> void:
	data = fx_data if fx_data != null else FxData.shared()
	common_ref_plane_m = data.common_num("ref_plane_m")
	common_size_exp = data.common_num("size_exp")
	common_max_puffs = int(data.common_num("max_puffs"))
	select(data.working_default("smoke"), data.working_default("crash"))

# Chooses the options the field runs (until Alex chooses; the data's working defaults otherwise).
func select(smoke: String, crash: String) -> void:
	smoke_name = smoke
	crash_name = crash
	smoke_o = data.smoke_option(smoke)
	crash_o = data.crash_option(crash)
	set_defs.clear()
	set_defs["smoke"] = smoke_o

func clear() -> void:
	puffs.clear()
	bursts.clear()
	debris.clear()
	scars.clear()
	riders.clear()
	_emit.clear()
	_next_id = 0
	_dirty = false

func counts() -> Dictionary:
	return {"puffs": puffs.size(), "bursts": bursts.size(), "debris": debris.size(), "scars": scars.size(), "riders": riders.size()}

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
		"wind": wind,
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
	return {
		"alive": true,
		"pos": (p["pos"] as Vector2) + (p["wind"] as Vector2) * age,
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

# --- Out of control -------------------------------------------------------------------------------------------------

# Called each frame a plane is falling out of control (from World.sample): the trail of
# heavy smoke it leaves, the embers it sheds, and the pose the layer hangs its flame on.
func ride(unit_id: String, world_pos: Vector2, height_m: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
	var fall := FxData.grp(crash_o, "falling")
	var smoke_key := FxData.s(fall, "smoke_option")
	var o := _fall_smoke(smoke_key)
	var i := FxData.f(fall, "intensity")
	var made := _emit_trail(unit_id, "fall", o, "fall:" + smoke_key, i, FxData.i(fall, "tone"), FxData.f(fall, "interval_s"), world_pos, height_m, t, size_m, heading, FxData.f(fall, "life_s"))
	var fl := FxData.grp(fall, "flame")
	if FxData.b(fl, "enabled"):
		var every := FxData.f(fl, "ember_every_s")
		if every > 0.0:
			made += _shed_embers(unit_id, fl, every, world_pos, height_m, t, size_m)
	riders[unit_id] = {"pos": world_pos, "h": height_m, "heading": heading, "size_m": size_m, "t": t}
	return made

func _fall_smoke(smoke_key: String) -> Dictionary:
	var id := "fall:" + smoke_key
	if not set_defs.has(id):
		set_defs[id] = data.smoke_option(smoke_key)
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
	_add_plume(unit_id, "mid", FxData.grp(mid, "plume"), world_pos, height_m, t, size_m, rng)
	_add_debris(unit_id, FxData.grp(mid, "debris"), world_pos, height_m, t, size_m, rng)

func _burst_radius_m(b: Dictionary, size_m: float) -> float:
	return FxData.f(b, "radius_frac") * common_ref_plane_m * size_factor(size_m)

# The plume's puffs, born over the first moments, long-lived.
func _add_plume(unit_id: String, phase: String, pl: Dictionary, pos: Vector2, h: float, t: float, size_m: float, rng: Mulberry32) -> void:
	var smoke_key := FxData.s(pl, "smoke_option")
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
		set_defs[id] = po
	var o: Dictionary = set_defs[id]
	var rf := FxData.arr(pl, "radius_frac")
	var sf := size_factor(size_m)
	var n := FxData.i(pl, "count")
	for k in n:
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * FxData.f(pl, "spread_frac") * common_ref_plane_m * sf
		var born := t + FxData.f(pl, "delay_s") + float(k) * FxData.f(pl, "interval_s")
		_add_puff({
			"id": _new_id(), "unit": unit_id, "kind": "plume", "set": id, "born": born,
			"pos": pos + Vector2.from_angle(a) * d, "h": maxf(h, 0.0), "size_m": size_m,
			"r_m": lerpf(float(rf[0]), float(rf[1]), rng.next()) * common_ref_plane_m * sf,
			"tone": FxData.i(pl, "tone"), "variant": int(rng.next() * float(FxData.i(o, "variants"))),
			"life": FxData.f(pl, "life_s"), "wind": _wind(o, rng),
		})

# The wreck keeps smoking (Alex 2026-10-09: "an explosion, then smoking"): a column of puffs from
# the wreck for the data's duration, born at a rate that falls as the wreck burns out, narrowing
# and greying from the heavy tone to the thin one, each puff drifting downwind and rising.
func _add_smolder(unit_id: String, sm: Dictionary, pos: Vector2, t: float, size_m: float, rng: Mulberry32) -> void:
	var smoke_key := FxData.s(sm, "smoke_option")
	var id := "smolder:%s:%s" % [crash_name, smoke_key]
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
		set_defs[id] = po
	var o: Dictionary = set_defs[id]
	var dur := FxData.f(sm, "duration_s")
	var iv := FxData.arr(sm, "interval_s")
	var edges := FxData.arr(sm, "tone_edges_frac")
	var sf := size_factor(size_m)
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
		var d := sqrt(rng.next()) * 0.25 * common_ref_plane_m * sf
		_add_puff({
			"id": _new_id(), "unit": unit_id, "kind": "smolder", "set": id, "born": t + el,
			"pos": pos + Vector2.from_angle(a) * d, "h": 0.0, "rise": FxData.f(sm, "rise_mps"), "size_m": size_m,
			"r_m": lerpf(float(rf[0]), float(rf[1]), fr) * common_ref_plane_m * sf * (0.8 + rng.next() * 0.4),
			"tone": tone, "variant": int(rng.next() * float(FxData.i(o, "variants"))),
			"life": FxData.f(sm, "life_s"), "wind": _wind(o, rng),
		})
		# the interval stretches from its first value to its second over the duration
		el += lerpf(float(iv[0]), float(iv[1]), fr)

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
		var h := float(d["h0"]) - 0.5 * float(d["g"]) * age * age
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
	_add_plume(unit_id, "hit", FxData.grp(imp, "plume"), ground_pos, 0.0, t, size_m, rng)
	_add_smolder(unit_id, FxData.grp(imp, "smolder"), ground_pos, t, size_m, rng)
	add_scar(unit_id, ground_pos, t, size_m, (rng.next() * TAU) if is_nan(heading) else heading, int(rng.next() * 2147483647.0))

# The mark that stays. Also the way to put one back when a game in progress is loaded or joined
# (the crash events are replayed through this with their own times).
func add_scar(unit_id: String, ground_pos: Vector2, t: float, size_m: float, rot: float, seed_v: int) -> void:
	var sc := FxData.grp(FxData.grp(crash_o, "impact"), "scar")
	scars.append({"id": _new_id(), "unit": unit_id, "t0": t, "pos": ground_pos, "size_m": size_m, "rot": rot, "seed": seed_v,
		"variant": seed_v % maxi(FxData.i(sc, "variants"), 1)})
	var n := FxData.i(sc, "embers")
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
	var frames := FxData.arr(FxData.grp(crash_o, "burst"), "frames_s")
	return FxBurst.frame_index(frames, float(b["end_s"]), t - float(b["t0"]))

# A scar's strength at t: it blackens over the first moments, then stays for the rest of the game.
func scar_alpha(s: Dictionary, t: float) -> float:
	var age := t - float(s["t0"])
	if age < 0.0:
		return 0.0
	return clampf(age / 1.5, 0.0, 1.0)
