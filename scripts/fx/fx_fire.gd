extends RefCounted

# THE FOREST FIRE'S SMOKE (track 'Forest fire', decision forest-fire, 2026-10-11): one column of today's W1 smoke
# (decision damage-smoke) rising from every burning tree, as a STAND-IN look that a board of 3 to 4 options will swap.
# Alex: "the fire is actually just smoke coming from the trees". No flame and no fire colour (decision fire-colour):
# the fire machinery's switch stays off. Every number here is PROPOSED and lives in data/fx/fx.json, block
# "forest_fire".smoke -- the one block a board varies.
#
#   var fire := FxFire.new(FxData.shared())
#   fire.turn_seconds = 5.0
#   fire.set_feed(world.fire.feed())          # the sim's feed, pure data (below)
#   fire.puffs_at(t)                          # [{col, tree, pos, h, r_m, alpha, tone, stage, variant, u}] -- the headless view
#   fire.columns_at(t), fire.burnt_at(t)      # the columns smoking at game time t; the trees that are trunks as of t
#   fire.draw_shadows(layer, item, view)      # the FxLayer's passes call these two (fx_layer.gd draw_pass)
#   fire.draw_air(layer, item, view)
#
# THE FEED (one Dictionary per tree ever lit; the sim builder's `world.fire.feed()`):
#   {"id": String, "x_m": float, "y_m": float, "r_m": float, "lit_turn": int, "lit_t": float, "out_turn": int}
# A tree BURNS from (lit_turn, lit_t) through the END of out_turn and is a TRUNK from out_turn + 1 on. Game time is
# the effects layer's: (turn - 1) x turn_seconds + the second of the turn. An out_turn below lit_turn is "not known
# yet": the tree burns on. The feed is all this reads, so a late joiner and every peer draw the same smoke.
#
# A COLUMN is a stream of W1 puffs born on a fixed grid from the tree's lit time (the first one AT lit_t: it appears
# almost at once, Alex's fast flash) at forest_fire.smoke.interval_s, each moved a little later by a hash of the
# tree's place so neighbours do not pulse together. A puff is a PURE FUNCTION of (the tree, k, the game time): nothing
# is stored, a scrub back and forth is safe, and a column that has burnt out is gone `life_s` after its last puff.
# Thick (tone 2) while the tree burns, the medium tone for its last `dying_s`, the thin tone for `tail_s` after
# burn-out; it rises and drifts on the W1 option's wind, and thick smoke casts a shadow by the planes' altitude rule
# (decision smoke-shadow). Sizes follow the MAP's metres (a column stands on a tree), not the planes' drawn scale.
#
# THE WIND (decision coastal-wind, 2026-10-11, and wind-with-height: "The wind should pick up as the smoke rises"): with a wind set (set_wind: a
# Wind, scripts/sim/wind.gd, at(game_s) -> the air's velocity near the ground in m/s, world axes; height_factor(h) -> how much faster it blows at
# height h) a puff's direction and base speed are the wind's at its BIRTH time, and it drifts by that times D(age), the integral of the height factor
# over the puff's climb (fx_wind_profile.gd): the plume stands over its tree and bends downwind as it rises, faster the higher it is. The climb is the
# column's own (forest_fire.smoke: it starts at base_height_m with rise_mps and slows with time constant rise_tau_s, as a real plume does).
# THE ZONE: the sim sweeps the untrackable zone (the canopy grown by reach_m) downwind by `smoke.drift_s` seconds of the NEAR-GROUND wind
# (data/sim/fire.json, read here, not copied). A gain on the wind makes the low smoke end there: a puff drift_s old has drifted exactly wind x drift_s
# (the gain is drift_s / D(drift_s)); the smoke above and older than that trails further, by the height factor, as the wind picks up. No wind, or
# a Wind without height_factor: the option's own data wind, or the same wind at every height (D = age). The wind is sampled on a 0.25 s grid and
# cached (a puff is made again every frame).
#
# COST. The puffs of a frame are made once per game time (not per pass, not per camera move) into packed arrays,
# and drawn with one draw call each. Past forest_fire.smoke.draw_budget puffs in a frame, a fixed share (chosen by a
# hash of the puff, so a puff is kept or dropped for its whole life) is skipped and the rest drawn larger
# (stats().thinned): a grove of hundreds of burning trees stays cheap.

const FxData = preload("res://scripts/fx/fx_data.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxWindProfile = preload("res://scripts/fx/fx_wind_profile.gd")

const SET_ID := "forest_fire"
const DSTEP := 0.05          # seconds between the entries of the drift table
const TONES := 3

var data: FxData
var turn_seconds: float = 5.0
# (world metres: Vector2) -> bool: is the ground there in the player's sight? Unset: every column shows. With
# forest_fire.smoke.smoke_when_hidden false (the default) a column out of sight is not made.
var visible_at: Callable = Callable()
# () -> Variant: changes when what visible_at answers changes (the fog's circles); the frame's puffs are made again then.
var sight_sig: Callable = Callable()

# The air: a Wind (at(game_s) -> Vector2 m/s) or null (the option's own data wind). Set through set_wind().
var wind: Object = null
var cfg: Dictionary = {}               # forest_fire.smoke, unwrapped
var option: Dictionary = {}            # the smoke option the set is baked from (W1 + the block's shadow and strength keys)
var errors: Array[String] = []

# the feed, as packed arrays (a few thousand trees are cheap to scan every frame)
var _n := 0
var _ids := PackedStringArray()
var _x := PackedFloat64Array()
var _y := PackedFloat64Array()
var _r := PackedFloat64Array()
var _lit_turn := PackedInt32Array()
var _lit_t := PackedFloat64Array()
var _out_turn := PackedInt32Array()
var _seed := PackedInt32Array()
var _t_on := PackedFloat64Array()
var _t_end := PackedFloat64Array()     # the end of out_turn (INF: not known yet)
var _t_gone := PackedFloat64Array()    # the game time after which the column has nothing left to draw
var _burnt_order := PackedInt32Array() # tree indices with a known end, by end
var _version := 0

# the option's numbers, read once (FxPuff's formulas, inlined for the loop)
var _hold := 0.0
var _fade_pow := 1.0
var _peak := 1.0
var _g0 := 1.0
var _g1 := 1.0
var _gtau := 0.2
var _gnorm := 1.0
var _stage_n := 1
var _stage_edge := PackedFloat64Array()
var _variants := 1
var _steps: Array = []
var _wind := Vector2.ZERO
var _wind_jitter := 0.0
var _drift_s := -1.0                   # data/sim/fire.json smoke.drift_s (-1: the sim does not have it yet)
var _drift_gain := 1.0                 # the wind's gain on a puff's drift: drift_s / D(drift_s) (1 when drift_s is not known)
var _rise_tau := 0.0                   # forest_fire.smoke.rise_tau_s: the time constant the climb slows with (0: a constant climb)
var _profile: RefCounted = null        # the wind's factor by height (fx_wind_profile.gd)
var _dtab := PackedFloat64Array()      # D(age) every DSTEP s along the column's climb
var _wind_cache: Dictionary = {}       # int (0.25 s) -> Vector2: wind.at() x the gain
var _wind_probe := Vector2.INF         # the wind at a fixed time: a Wind changed in place empties the cache
var _iv := 1.2
var _jit := 0.3
var _life := 6.0
var _h0 := 25.0
var _rise := 9.0
var _spread := 0.35
var _rf0 := 0.3
var _rf1 := 0.55
var _tone_scale := PackedFloat64Array([0.7, 0.85, 1.0])
var _tone_burn := 2
var _tone_dying := 1
var _tone_tail := 0
var _dying := 2.5
var _tail := 2.5
var _budget := 1500
var _map_scale := true
var _hidden_ok := false
var _shadow := true
var _shadow_min_tone := 1

# the frame's puffs (world metres; made by _compute for one game time)
var _key_t := NAN
var _key_ver := -1
var _key_sig: Variant = null
var _key_hidden := -1.0
var _pn := 0
var _pw := PackedVector2Array()
var _ph := PackedFloat32Array()
var _pr := PackedFloat32Array()
var _pa := PackedFloat32Array()
var _pt := PackedInt32Array()
var _pv := PackedInt32Array()
var _pcol := PackedInt32Array()
var _pu := PackedFloat32Array()
var _pstage := PackedInt32Array()
var _thinned := 0
var _columns := 0
var _compute_us := 0
var _draw_us := 0
var _computes := 0
var _burnt_cache: Array = []
var _burnt_cache_n := -1
var _burnt_cache_ver := -1

func _init(fx_data: FxData = null) -> void:
	data = fx_data if fx_data != null else FxData.shared()
	reload()

# Reads the block again (a board or a test changes the data).
func reload() -> void:
	var raw: Variant = data.raw.get("forest_fire")
	if not (raw is Dictionary) or not ((raw as Dictionary).get("smoke") is Dictionary):
		errors.append("fx.json has no forest_fire.smoke block")
		return
	cfg = FxData.unwrap((raw as Dictionary)["smoke"])
	var o: Dictionary = data.smoke_option(FxData.s(cfg, "smoke_option")).duplicate(true)
	# the column's own keys: thick smoke casts a shadow (decision smoke-shadow), and the strength it is held to
	o["ground_shadow"] = FxData.b(cfg, "ground_shadow")
	o["shadow_min_tone"] = FxData.i(cfg, "shadow_min_tone")
	o["peak_alpha"] = FxData.f(o, "peak_alpha") * FxData.f(cfg, "peak_alpha")
	option = o
	_hold = FxData.f(o, "hold")
	_fade_pow = FxData.f(o, "fade_power")
	_peak = FxData.f(o, "peak_alpha")
	var g := FxData.arr(o, "grow")
	_g0 = float(g[0])
	_g1 = float(g[1])
	_gtau = maxf(FxData.f(o, "grow_tau"), 1e-3)
	_gnorm = 1.0 - exp(-1.0 / _gtau)
	_stage_n = maxi(FxData.i(o, "stages"), 1)
	_stage_edge = PackedFloat64Array()
	if _stage_n > 1:
		for x in FxData.arr(o, "stage_edges"):
			_stage_edge.append(float(x))
	_variants = maxi(FxData.i(o, "variants"), 1)
	_steps = FxData.arr(o, "alpha_steps")
	var w := FxData.arr(o, "wind_mps")
	var ws := FxData.f(cfg, "wind_scale")
	_wind = Vector2(float(w[0]), float(w[1])) * ws
	_wind_jitter = FxData.f(o, "wind_jitter_mps") * ws
	_iv = maxf(FxData.f(cfg, "interval_s"), 0.05)
	_jit = FxData.f(cfg, "interval_jitter")
	_life = maxf(FxData.f(cfg, "life_s"), 0.1)
	_h0 = FxData.f(cfg, "base_height_m")
	_rise = FxData.f(cfg, "rise_mps")
	_rise_tau = FxData.f(cfg, "rise_tau_s")
	_spread = FxData.f(cfg, "spread_frac")
	var rf := FxData.arr(cfg, "radius_frac_of_tree")
	_rf0 = float(rf[0])
	_rf1 = float(rf[1])
	_tone_scale = PackedFloat64Array()
	for x in FxData.arr(cfg, "tone_radius_scale"):
		_tone_scale.append(float(x))
	_tone_burn = FxData.i(cfg, "tone_burning")
	_tone_dying = FxData.i(cfg, "tone_dying")
	_tone_tail = FxData.i(cfg, "tone_tail")
	_dying = FxData.f(cfg, "dying_s")
	_tail = FxData.f(cfg, "tail_s")
	_budget = maxi(FxData.i(cfg, "draw_budget"), 1)
	_map_scale = FxData.b(cfg, "map_scale")
	_hidden_ok = FxData.b(cfg, "smoke_when_hidden")
	_shadow = FxData.b(cfg, "ground_shadow")
	_shadow_min_tone = FxData.i(cfg, "shadow_min_tone")
	_drift_s = read_drift_s()
	_rebuild_drift()
	_rebuild_times()
	_dirty_frame()

# The sim's drift_s (seconds of near-ground wind by which its smoke zone sits downwind; -1: none) and the gain on the wind that follows from it.
# reload() reads the data's; a board or a test may set another.
func set_drift_s(s: float) -> void:
	_drift_s = s
	_rebuild_drift()

# The wind's factor by height, the column's drift table D(age) along its climb, and the gain that makes a puff drift_s old sit wind x drift_s from
# its tree. Run when the wind, drift_s or the data change.
func _rebuild_drift() -> void:
	_profile = FxWindProfile.from_wind(wind)
	var n := int(ceil((_life + 1.0) / DSTEP)) + 2
	_dtab = (_profile as FxWindProfile).drift_table(_h0, _rise, _rise_tau, DSTEP, n)
	_drift_gain = 1.0
	if _drift_s > 0.0:
		_drift_gain = clampf(_drift_s / maxf(drift_integral(_drift_s), 1e-6), 0.4, 2.5)
	_wind_cache.clear()
	_dirty_frame()

# D(age): the seconds of near-ground wind a puff of this age has drifted by (the age itself in a wind that is the same at every height).
func drift_integral(age: float) -> float:
	var last := _dtab.size() - 1
	var x := clampf(age, 0.0, float(last) * DSTEP) / DSTEP
	var i := mini(int(x), last - 1)
	return lerpf(_dtab[i], _dtab[i + 1], x - float(i))

# data/sim/fire.json smoke.drift_s: the seconds of drift by which the sim places the untrackable smoke zone downwind of the smoking trees
# (decision coastal-wind). -1 when the file does not have it. Read, never copied: the sim's number is the one the drawing follows.
static func read_drift_s(path: String = "res://data/sim/fire.json") -> float:
	if not FileAccess.file_exists(path):
		return -1.0
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (raw is Dictionary):
		return -1.0
	var sm: Variant = (raw as Dictionary).get("smoke")
	if not (sm is Dictionary):
		return -1.0
	var rec: Variant = (sm as Dictionary).get("drift_s")
	var v: Variant = (rec as Dictionary).get("value") if rec is Dictionary else rec
	return float(v) if (v is float or v is int) else -1.0

# The wind (null: the option's own data wind). The frame's puffs are made again.
func set_wind(w: Object) -> void:
	wind = w
	_wind_probe = Vector2.INF
	_rebuild_drift()

# The air's drift velocity for a puff born at game time b (m/s): the wind there times the gain, on a 0.25 s grid.
func _wind_at(b: float) -> Vector2:
	var key := roundi(b * 4.0)
	var v: Variant = _wind_cache.get(key)
	if v == null:
		v = (wind.at(float(key) * 0.25) as Vector2) * _drift_gain
		_wind_cache[key] = v
	return v

func drift_s() -> float:
	return _drift_s

func drift_gain() -> float:
	return _drift_gain

# --- The feed ------------------------------------------------------------------------------------------------------

func clear() -> void:
	set_feed([])

func active() -> bool:
	return _n > 0

func tree_count() -> int:
	return _n

func version() -> int:
	return _version

# Takes the whole feed (the sim's `world.fire.feed()`: it only ever grows). Unreadable entries are skipped.
func set_feed(feed: Array) -> void:
	_ids = PackedStringArray()
	_x = PackedFloat64Array()
	_y = PackedFloat64Array()
	_r = PackedFloat64Array()
	_lit_turn = PackedInt32Array()
	_lit_t = PackedFloat64Array()
	_out_turn = PackedInt32Array()
	_seed = PackedInt32Array()
	for e in feed:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		if not (d.has("x_m") and d.has("y_m")):
			continue
		var x := float(d["x_m"])
		var y := float(d["y_m"])
		_ids.append(str(d.get("id", "")))
		_x.append(x)
		_y.append(y)
		_r.append(maxf(float(d.get("r_m", 4.0)), 0.5))
		_lit_turn.append(int(d.get("lit_turn", 1)))
		_lit_t.append(float(d.get("lit_t", 0.0)))
		_out_turn.append(int(d.get("out_turn", -1)))
		_seed.append(place_seed(x, y))
	_n = _ids.size()   # (entries without a place were skipped)
	_pn = 0
	_columns = 0
	_thinned = 0
	_version += 1
	_rebuild_times()
	_dirty_frame()

# A hash of the tree's PLACE (not its id): the same tree draws the same column on every peer, and the id's format is
# the sim's business.
static func place_seed(x_m: float, y_m: float) -> int:
	return ((int(roundf(x_m * 8.0)) * 73856093) ^ (int(roundf(y_m * 8.0)) * 19349663)) & 0x7FFFFFFF

func _rebuild_times() -> void:
	_t_on = PackedFloat64Array()
	_t_end = PackedFloat64Array()
	_t_gone = PackedFloat64Array()
	_t_on.resize(_n)
	_t_end.resize(_n)
	_t_gone.resize(_n)
	var known: Array = []
	for i in _n:
		_t_on[i] = float(_lit_turn[i] - 1) * turn_seconds + _lit_t[i]
		if _out_turn[i] >= _lit_turn[i]:
			_t_end[i] = float(_out_turn[i]) * turn_seconds
			_t_gone[i] = _t_end[i] + _tail + _life
			known.append(i)
		else:
			_t_end[i] = INF
			_t_gone[i] = INF
	known.sort_custom(func(a: int, b: int) -> bool: return _t_end[a] < _t_end[b] or (_t_end[a] == _t_end[b] and a < b))
	_burnt_order = PackedInt32Array(known)
	_burnt_cache_n = -1

func set_turn_seconds(s: float) -> void:
	if not is_equal_approx(s, turn_seconds):
		turn_seconds = s
		_rebuild_times()
		_dirty_frame()

func _dirty_frame() -> void:
	_key_t = NAN
	_key_ver = -1

# --- Burning and burnt ---------------------------------------------------------------------------------------------

# The trees that are TRUNKS as of game time t (burnt out: the end of their out_turn has passed), by the order they went
# out: [{id, x_m, y_m, r_m}]. The map bakes these. The array is the same object until the count changes.
func burnt_at(t: float) -> Array:
	var lo := 0
	var hi := _burnt_order.size()
	while lo < hi:   # the first tree still burning at t
		var mid := (lo + hi) >> 1
		if _t_end[_burnt_order[mid]] <= t + 1e-6:
			lo = mid + 1
		else:
			hi = mid
	if lo == _burnt_cache_n and _burnt_cache_ver == _version:
		return _burnt_cache
	var out: Array = []
	for k in lo:
		var i := _burnt_order[k]
		out.append({"id": _ids[i], "x_m": _x[i], "y_m": _y[i], "r_m": _r[i]})
	_burnt_cache = out
	_burnt_cache_n = lo
	_burnt_cache_ver = _version
	return out

# How many trees are burning at game time t (lit, and not yet burnt out), whether or not they are in sight.
func burning_count(t: float) -> int:
	var c := 0
	for i in _n:
		if t >= _t_on[i] and t < _t_end[i]:
			c += 1
	return c

# --- The frame's puffs ---------------------------------------------------------------------------------------------

# Makes the puffs of game time t (cached by t, the feed and the sight signature).
func _compute(t: float) -> void:
	var sig: Variant = sight_sig.call() if sight_sig.is_valid() else null
	var windy := wind != null
	if windy:
		var probe: Vector2 = wind.at(1234.5)
		if probe != _wind_probe:   # (a Wind changed in place, or a new one: what was cached is the old air)
			_wind_probe = probe
			_wind_cache.clear()
			_key_t = NAN
	if t == _key_t and _version == _key_ver and sig == _key_sig:
		return
	var t0 := Time.get_ticks_usec()
	_key_t = t
	_key_ver = _version
	_key_sig = sig
	_computes += 1
	var cols := PackedInt32Array()
	var kmin_a := PackedInt32Array()
	var kmax_a := PackedInt32Array()
	var est := 0
	var filter := visible_at.is_valid() and not _hidden_ok
	for i in _n:
		if t < _t_on[i] or t >= _t_gone[i]:
			continue
		var rel := t - _t_on[i]
		var kmax := floori(rel / _iv)
		if is_finite(_t_end[i]):
			kmax = mini(kmax, floori((_t_end[i] + _tail - _t_on[i]) / _iv))
		var kmin := maxi(0, floori((rel - _life - _jit * _iv) / _iv))
		if kmax < kmin:
			continue
		if filter and not bool(visible_at.call(Vector2(_x[i], _y[i]))):
			continue
		cols.append(i)
		kmin_a.append(kmin)
		kmax_a.append(kmax)
		est += kmax - kmin + 1
	_columns = cols.size()
	# past the budget a fixed share of the puffs is kept (by a hash of the puff, so a puff is kept or dropped for its whole life: nothing
	# flickers) and the kept ones are drawn larger, so a dense grove still reads as smoke
	var keep := 1.0
	var size_k := 1.0
	_thinned = 0
	if est > _budget:
		keep = 0.9 * float(_budget) / float(est)   # (a share, not a count: the hash lets a few more through than the share says; 0.9 keeps it under the budget)
		size_k = minf(1.0 / sqrt(keep), 1.6)
	_pn = 0
	_pw.resize(est)
	_ph.resize(est)
	_pr.resize(est)
	_pa.resize(est)
	_pt.resize(est)
	_pv.resize(est)
	_pcol.resize(est)
	_pu.resize(est)
	_pstage.resize(est)
	var n := 0
	for c in cols.size():
		var i := cols[c]
		var sd := _seed[i]
		var x := _x[i]
		var y := _y[i]
		var r := _r[i]
		var t_on := _t_on[i]
		var t_end := _t_end[i]
		var born_until := t_end + _tail
		for k in range(kmin_a[c], kmax_a[c] + 1):
			# four small hashes of (place, k): every random number of the puff, with no state
			var h1 := (sd * 374761393 + k * 668265263 + 1274126177) & 0x7FFFFFFF
			h1 = ((h1 ^ (h1 >> 15)) * 1274126177) & 0x7FFFFFFF
			h1 = ((h1 ^ (h1 >> 13)) * 668265263) & 0x7FFFFFFF
			h1 ^= h1 >> 16
			var b := t_on + float(k) * _iv
			if k > 0:
				b += float(h1 & 0x7FFF) / 32768.0 * _jit * _iv
			if b > t or b > born_until:
				continue
			var age := t - b
			if age >= _life:
				continue
			if keep < 1.0 and float((h1 >> 4) & 0x7FFF) / 32768.0 >= keep:
				_thinned += 1
				continue
			var u := age / _life
			var h2 := (sd * 668265263 + k * 374761393 + 668265263 * 3) & 0x7FFFFFFF
			h2 = ((h2 ^ (h2 >> 15)) * 374761393) & 0x7FFFFFFF
			h2 = ((h2 ^ (h2 >> 13)) * 1274126177) & 0x7FFFFFFF
			h2 ^= h2 >> 16
			var h3 := (sd * 1274126177 + k * 374761393 + 668265263 * 5) & 0x7FFFFFFF
			h3 = ((h3 ^ (h3 >> 15)) * 668265263) & 0x7FFFFFFF
			h3 = ((h3 ^ (h3 >> 13)) * 374761393) & 0x7FFFFFFF
			h3 ^= h3 >> 16
			var h4 := (sd * 374761393 + k * 1274126177 + 374761393 * 7) & 0x7FFFFFFF
			h4 = ((h4 ^ (h4 >> 15)) * 1274126177) & 0x7FFFFFFF
			h4 = ((h4 ^ (h4 >> 13)) * 668265263) & 0x7FFFFFFF
			h4 ^= h4 >> 16
			var tone := _tone_tail
			if b < t_end - _dying:
				tone = _tone_burn
			elif b < t_end:
				tone = _tone_dying
			var ang := float(h2 & 0xFFFF) / 65536.0 * TAU
			var dist := sqrt(float((h2 >> 16) & 0x7FFF) / 32768.0) * _spread * r
			var jx := (float(h3 & 0x7FFF) / 32768.0 - 0.5) * 2.0 * _wind_jitter
			var jy := (float((h3 >> 15) & 0xFFFF) / 65536.0 - 0.5) * 2.0 * _wind_jitter
			# the option's growth and fade at this age (fx_puff.gd grow_at / alpha_at / stage_of, inlined)
			var e := (1.0 - exp(-u / _gtau)) / _gnorm
			var grow := _g0 + (_g1 - _g0) * e
			var a := 1.0
			if u > _hold:
				a = pow(1.0 - (u - _hold) / maxf(1.0 - _hold, 1e-6), _fade_pow)
			a *= _peak
			if not _steps.is_empty():
				a = FxPuff.alpha_at(option, u)
			var st := 0
			for edge in _stage_edge:
				if u >= edge:
					st += 1
			st = mini(st, _stage_n - 1)
			var rr := r * (_rf0 + (_rf1 - _rf0) * float(h4 & 0x7FFF) / 32768.0) * _tone_scale[clampi(tone, 0, TONES - 1)] * grow * size_k
			if windy:
				# the air at the puff's birth, scaled by the integral of the height factor over the climb so far, plus the spread
				var bw := _wind_at(b)
				var dd := drift_integral(age)
				_pw[n] = Vector2(x + cos(ang) * dist + bw.x * dd + jx * age, y + sin(ang) * dist + bw.y * dd + jy * age)
			else:
				_pw[n] = Vector2(x + cos(ang) * dist + (_wind.x + jx) * age, y + sin(ang) * dist + (_wind.y + jy) * age)
			_ph[n] = _h0 + (_rise * age if _rise_tau <= 0.0 else _rise * _rise_tau * (1.0 - exp(-age / _rise_tau)))
			_pr[n] = rr
			_pa[n] = a
			_pt[n] = tone
			_pv[n] = int(float((h4 >> 15) & 0xFFFF) / 65536.0 * float(_variants)) + _variants * st
			_pcol[n] = i
			_pu[n] = u
			_pstage[n] = st
			n += 1
	_pn = n
	_compute_us += Time.get_ticks_usec() - t0

# The puffs at game time t, as records (the headless view of exactly what is drawn): {col, tree, pos (world m), h (m above
# the ground), r_m, alpha, tone, stage, variant, u}. `tree` is the feed's id.
func puffs_at(t: float) -> Array:
	_compute(t)
	var out: Array = []
	for j in _pn:
		out.append({"col": _pcol[j], "tree": _ids[_pcol[j]], "pos": _pw[j], "h": _ph[j], "r_m": _pr[j], "alpha": _pa[j],
			"tone": _pt[j], "stage": _pstage[j], "variant": _pv[j] % _variants, "u": _pu[j]})
	return out

# How many columns are smoking at game time t, and how many puffs they make.
func columns_at(t: float) -> int:
	_compute(t)
	return _columns

func puff_count_at(t: float) -> int:
	_compute(t)
	return _pn

func stats() -> Dictionary:
	return {"trees": _n, "columns": _columns, "puffs": _pn, "thinned": _thinned, "computes": _computes,
		"compute_ms": _compute_us / 1000.0, "draw_ms": _draw_us / 1000.0}

func reset_timing() -> void:
	_compute_us = 0
	_draw_us = 0
	_computes = 0

# --- Drawing (called by FxLayer.draw_pass) ----------------------------------------------------------------------------------------

# The screen transform of the layer's mapping, made once a pass: world metres -> screen px, and px per metre.
func _frame_xf(layer: Object) -> Dictionary:
	var m: Object = layer.mapping
	var o: Vector2 = m.world_to_screen(Vector2.ZERO)
	var ex: Vector2 = m.world_to_screen(Vector2(1.0, 0.0)) - o
	var ey: Vector2 = m.world_to_screen(Vector2(0.0, 1.0)) - o
	return {"xf": Transform2D(ex, ey, o), "ppm": sqrt(absf(ex.cross(ey)))}

func _ensure_set(layer: Object) -> void:
	if not layer.field.set_defs.has(SET_ID):
		layer.field.set_defs[SET_ID] = option   # (FxLayer.select() clears the registry; a draw puts it back)

# Where the smoke's ground shadow falls, in screen px, for a puff `h` metres up: the planes' altitude rule (1% of the height
# along the light) at the map's scale (or the planes', with map_scale off).
func shadow_offset_px(layer: Object, xf: Transform2D, h: float, scale_k: float) -> Vector2:
	var unit: Vector2 = layer.style.plane_shadow_offset_m(1.0)
	return xf.basis_xform(unit * h * scale_k)

func draw_shadows(layer: Object, item: CanvasItem, view: Rect2) -> void:
	if _n == 0 or not _shadow:
		return
	_compute(layer.now)
	if _pn == 0:
		return
	var t0 := Time.get_ticks_usec()
	_ensure_set(layer)
	var fr := _frame_xf(layer)
	var xf: Transform2D = fr["xf"]
	var scale_k := 1.0 if _map_scale else float(layer.true_scale)
	var ppm: float = float(fr["ppm"]) * scale_k
	var q: float = layer.quantize(ppm)
	var ps = layer._puffs_for(SET_ID, q, FxData.f(cfg, "puff_size_m"))
	if ps == null:
		return
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var tint: Color = layer._tint
	var min_px: float = layer.data.common_num("min_shadow_px")
	var unit: Vector2 = layer.style.plane_shadow_offset_m(1.0)
	var basis_off := xf.basis_xform(unit * scale_k)
	var rad: Array = ps.radius_px
	var org: Array = ps.origin
	var masks: Array = ps.mask
	var variants: int = ps.variants
	for j in _pn:
		var tone := _pt[j]
		if tone < _shadow_min_tone or _pa[j] < 0.25:
			continue
		var off := basis_off * _ph[j]
		if off.length() < min_px:
			continue
		var sp := xf * _pw[j] + off
		if not view.has_point(sp):
			continue
		var sc := _pr[j] * ppm / float(rad[tone])
		var og: Vector2 = org[tone]
		item.draw_texture_rect((masks[tone] as Array)[_pv[j] % variants], Rect2(sp - og * sc, og * (2.0 * sc)), false, tint)
	_draw_us += Time.get_ticks_usec() - t0

func draw_air(layer: Object, item: CanvasItem, view: Rect2) -> void:
	if _n == 0:
		return
	_compute(layer.now)
	if _pn == 0:
		return
	var t0 := Time.get_ticks_usec()
	_ensure_set(layer)
	var fr := _frame_xf(layer)
	var xf: Transform2D = fr["xf"]
	var scale_k := 1.0 if _map_scale else float(layer.true_scale)
	var ppm: float = float(fr["ppm"]) * scale_k
	var q: float = layer.quantize(ppm)
	var ps = layer._puffs_for(SET_ID, q, FxData.f(cfg, "puff_size_m"))
	if ps == null:
		return
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var rad: Array = ps.radius_px
	var org: Array = ps.origin
	var texs: Array = ps.tex
	for j in _pn:
		var sp := xf * _pw[j]
		if not view.has_point(sp):
			continue
		var tone := _pt[j]
		var sc := _pr[j] * ppm / float(rad[tone])
		var og: Vector2 = org[tone]
		item.draw_texture_rect((texs[tone] as Array)[_pv[j]], Rect2(sp - og * sc, og * (2.0 * sc)), false, Color(1.0, 1.0, 1.0, _pa[j]))
	_draw_us += Time.get_ticks_usec() - t0
