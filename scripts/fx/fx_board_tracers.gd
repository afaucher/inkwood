extends "res://scripts/fx/fx_board_strike.gd"

# THE TRACERS BOARD (Track TR, 2026-10-11): variants/tracers/. WINDOWED ONLY -- under --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/fx/fx_board_tracers.gd -- [out=variants] [options=T1,T2] [only=<row key>]
#
# The strike board's machinery (fx_board_strike.gd: the rig, the sheets, the compare sheet, board.json) with the tracers' scenario.
# ALL OPTIONS ARE PROPOSED; nothing is chosen here (Alex asked for "tracers for machine guns", decision tracers-mg; the look is his to pick).
#
# THE SCENE IS THE REAL SIM. A light fighter (side A) chases a bomber (side B) over the village, 150 m behind, both at 400 m; the
# World resolves one turn and every "fire" event of it (the fighter's twin wing guns, the bomber's tail turret firing back) is fed to
# the effects layer by FxTracer.feed_event, the call the game's CombatFeed makes. Hits and misses are the sim's rolls (the seeds are
# picked to show a miss volley and a hit). Beside them, as in the game: the damage smoke W1 after each hit (from the sim's hit events),
# flak F2 from the village battery, and the side-coloured wingtip ribbon (decision wingtip-trails) under the effects. Planes at the
# sandbox's drawn scale (a light fighter 36 px at zoom 1), the map at 2 px/m, zoom 1.0 and 2.0 close in and 0.6 and 0.35 (the
# planning view) out.

const World = preload("res://scripts/sim/world.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const FxTracer = preload("res://scripts/fx/fx_tracer.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")

const TURN_S := 5.0
const SEED_MISS := 1       # a seed whose first two volleys (0.5 s and 1.0 s) all miss
const SEED_HIT := 51       # a seed whose second volley (1.0 s) lands one hit and misses with the other gun, five hits in the turn
const SEED_FIGHT := 8        # two fighters on the bomber: six hits in the turn
const DTS := [0.02, 0.05, 0.10, 0.20, 0.32, 0.44]

var _start := Vector2.ZERO       # the bomber's start, west of the battery

func _run() -> void:
	rig = FxRig.new(self)
	await rig.setup()
	fxs = rig.fxs
	fxd = rig.fxd
	if not fxs.ok() or not rig.ui_style.ok():
		printerr("[fx-tracers] style errors: ", fxs.errors, rig.ui_style.errors)
		quit(1)
		return
	# the ribbons go UNDER the smoke, as the game mounts them (ui.json marker.trails.under_smoke)
	var below := FxPass.new()
	below.name = "RibbonsBelow"
	below.kind = "ribbons"
	below.layer = rig.proxy
	rig.layer.add_child(below)
	rig.layer.move_child(below, 0)
	rig.proxy.below_node = below
	rig.proxy.ribbons_below = true
	var WL: GDScript = load("res://scripts/world/world_layout.gd")
	var layout = WL.new(FxRig.SEED)
	var sites: Dictionary = layout.sites()
	TOWER = sites["radio_tower"]
	BATTERY = (sites["aa_battery"] as Array)[0]
	_start = BATTERY + Vector2(-260.0, 30.0)
	print("[fx-tracers] the battery site ", BATTERY, ", the bomber starts ", _start)
	await _tracer_board()
	rig.view.queue_free()
	await rig.frames(2)
	quit(1 if rig.failures > 0 else 0)

# --- The sim ------------------------------------------------------------------------------------------------------------------------

const FxPass = preload("res://scripts/fx/fx_pass.gd")

# The units of a scenario: id -> {type, side, start (world m), speed, heading}. Side A is the players' (allies), side B the enemy (axis).
func _units(extra_fighter: bool) -> Dictionary:
	var u := {
		"bomber": {"type": "bomber", "side": "side_b", "sim_side": "axis", "start": _start, "speed": 85.0, "heading": 0.0},
		"fighter": {"type": "light_fighter", "side": "side_a", "sim_side": "allies", "start": _start + Vector2(-150.0, -16.0), "speed": 100.0, "heading": 0.0},
	}
	if extra_fighter:
		u["fighter2"] = {"type": "light_fighter", "side": "side_a", "sim_side": "allies", "start": _start + Vector2(-175.0, 8.0), "speed": 100.0, "heading": 0.0}
	return u

# Resolves one turn: {world, units, fires (the fire events), hits (the hit events)}.
func _scenario(seed_value: int, extra_fighter: bool = false) -> Dictionary:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	var us := _units(extra_fighter)
	for id: String in us:
		var s: Dictionary = us[id]
		w.add_unit({"id": id, "type": s["type"], "side": s["sim_side"], "controller": "player", "x": (s["start"] as Vector2).x, "y": (s["start"] as Vector2).y,
			"heading": s["heading"], "speed": s["speed"], "altitude_band": "medium"})
	w.commit("local")
	var r := w.resolve()
	var fires: Array = []
	var hits: Array = []
	for ev: Dictionary in r.get("events", []):
		if ev["type"] == "fire":
			fires.append(ev)
		elif ev["type"] == "hit":
			hits.append(ev)
	return {"world": w, "units": us, "fires": fires, "hits": hits}

# A unit's pose tau seconds into the turn; before the turn (a tail from the start) it is where it would have been flying straight.
func _pose(sc: Dictionary, id: String, tau: float) -> Dictionary:
	var u: Dictionary = (sc["units"] as Dictionary)[id]
	if tau < 0.0:
		var h := float(u["heading"])
		var p: Vector2 = (u["start"] as Vector2) + Vector2.from_angle(h) * float(u["speed"]) * tau
		return {"pos": p, "heading": h}
	var s: Dictionary = (sc["world"] as World).sample(id, tau, "history")
	return {"pos": Vector2(float(s["x"]), float(s["y"])), "heading": float(s["heading"])}

func _planes(sc: Dictionary, tau: float) -> Array:
	var out: Array = []
	for id: String in sc["units"]:
		var u: Dictionary = sc["units"][id]
		var p := _pose(sc, id, tau)
		out.append(rig.plane(p["pos"], p["heading"], 400.0, u["side"], u["type"]))
	out.append(rig.plane(BATTERY, 0.0, 0.0, "side_b", "anti_aircraft_battery"))
	return out

# The wingtip ribbons of every plane at tau, for the camera as it is NOW (called once the camera has moved): the records
# WingtipTrails.collect() would make, built from the same poses (a unit's own accent, a one-turn window, faded as the game fades it).
func _ribbons(sc: Dictionary, tau: float, zoom: float) -> Array:
	var out: Array = []
	var win := rig.ui_style.num("marker.trails.window_turns") * TURN_S
	var power := rig.ui_style.num("marker.trails.fade_power")
	var min_alpha := rig.ui_style.num("marker.trails.min_alpha")
	var step := rig.ui_style.num("marker.trails.sample_s")
	for id: String in sc["units"]:
		var u: Dictionary = sc["units"][id]
		var half_m := UnitMarkerArt.half_span_m(rig.ui_style, str(u["type"])) * rig.true_scale_at(zoom)
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		var centre := PackedVector2Array()
		var age := PackedFloat64Array()
		var stp := PackedInt32Array()
		var k := 0
		while true:
			var tt := tau - float(k) * step
			var a := clampf((tau - tt) / win, 0.0, 1.0)
			if pow(1.0 - a, power) < min_alpha:
				break
			var p := _pose(sc, id, tt)
			var wp: Vector2 = p["pos"]
			var side_v := Vector2.from_angle(float(p["heading"]) + PI / 2.0) * half_m
			left.append(rig.view.world_to_screen(wp - side_v))
			right.append(rig.view.world_to_screen(wp + side_v))
			centre.append(rig.view.world_to_screen(wp))
			age.append(a)
			stp.append(0)
			k += 1
		if left.size() < 2:
			continue
		out.append({"unit": id, "side": str(u["sim_side"]), "own": str(u["side"]) == "side_a", "accent": fxs.palette[str(u["side"])], "left": left, "right": right,
			"centre": centre, "age": age, "step": stp, "half_span_px": (left[0] as Vector2).distance_to(right[0]) * 0.5})
	return out

# Replays a scenario into the effects layer: every fire event through the game's own call, the smoke after each hit, and (flak = true) the
# village battery's flak at the bomber, a burst every half second from 1.5 s, one of them a hit.
func _play(sc: Dictionary, option_name: String, flak: bool) -> void:
	_fx_reset()
	rig.fx.select_tracers(option_name)
	var w: World = sc["world"]
	var us: Dictionary = sc["units"]
	for ev: Dictionary in sc["fires"]:
		var sid := str(ev["unit"])
		var tid := str(ev["target"])
		var s: Dictionary = w.sample(sid, float(ev["t"]), "history")
		var centre := Vector2(float(s["x"]), float(s["y"]))
		var accent := str((us[sid] as Dictionary)["side"])
		# the target flies on while the round does: aim where it will be on arrival, as the feed does
		var p0: Dictionary = w.sample(tid, float(ev["t"]), "history")
		var p1: Dictionary = w.sample(tid, float(ev["t"]) + rig.fx.tracer_flight_s(), "history")
		var lead := Vector2(float(p1["x"]) - float(p0["x"]), float(p1["y"]) - float(p0["y"]))
		FxTracer.feed_event(rig.fx, ev, T0 + float(ev["t"]), centre, w.units[tid].def.size_m, accent, 1.0, true, true, lead)
	# damage smoke from each hit on (W1, the decided smoke): the health fraction after the hit, until the next hit or the turn's end
	for id: String in us:
		var mine: Array = []
		for ev: Dictionary in sc["hits"]:
			if str(ev["unit"]) == id:
				mine.append(ev)
		var full := float(w.units[id].def.health)
		for i in mine.size():
			var t0 := float(mine[i]["t"])
			var t1 := float(mine[i + 1]["t"]) if i + 1 < mine.size() else TURN_S
			var frac := clampf(float(mine[i]["health"]) / full, 0.0, 1.0)
			var sampler := func(tg: float) -> Dictionary:
				var sm: Dictionary = w.sample(id, tg - T0, "history")
				return {"x": sm["x"], "y": sm["y"], "height_m": 400.0, "heading": sm["heading"]}
			rig.fx.emit_path(id, sampler, T0 + t0, T0 + t1, frac, float(w.units[id].def.size_m))
	if flak:
		for k in 8:
			var tau := 1.5 + 0.5 * float(k)
			var bp: Dictionary = w.sample("bomber", tau, "history")
			rig.fx.flak_burst(Vector2(float(bp["x"]), float(bp["y"])), 400.0, T0 + tau, k == 4, "aa%d/%d" % [k % 2, k / 2])

# One frame record: the planes and ribbons are those of game second `tau`; `at` is where the camera looks (world m).
func _tframe(sc: Dictionary, tau: float, zoom: float, at: Vector2, cap: String, with_ribbons: bool = true) -> Dictionary:
	var f := _frame(tau, zoom, at, _planes(sc, tau), cap)
	if with_ribbons:
		f["ribbons"] = func() -> Array: return _ribbons(sc, tau, zoom)
	return f

func _mid(sc: Dictionary, tau: float, bias: float = 0.0) -> Vector2:
	var a: Vector2 = _pose(sc, "fighter", tau)["pos"]
	var b: Vector2 = _pose(sc, "bomber", tau)["pos"]
	return (a + b) * 0.5 + Vector2(bias, 0.0)

# --- Rows -----------------------------------------------------------------------------------------------------------------------

func _tracer_rows(option_name: String, sc_miss: Dictionary, sc_hit: Dictionary, sc_fight: Dictionary) -> Array:
	var rows: Array = []
	var setup_miss := func() -> void: _play(sc_miss, option_name, false)
	var setup_hit := func() -> void: _play(sc_hit, option_name, false)
	var setup_hit_flak := func() -> void: _play(sc_hit, option_name, true)
	var setup_fight := func() -> void: _play(sc_fight, option_name, true)
	# a. a miss volley, 1.0 (zoom 1: the plane is 36 px)
	var te := 0.5
	var frames: Array = []
	for dt: float in DTS:
		frames.append(_tframe(sc_miss, te + dt, 1.0, _mid(sc_miss, te, 12.0), "%.2f s after the roll" % dt))
	rows.append(_row("miss", "a. A MISS: the fighter's twin guns and the bomber's tail turret fire; every round goes by (the roll is at 0.5 s)", CROP, setup_miss, frames, 2))
	# b. a hit and a miss, zoom 1.0
	te = 1.0
	frames = []
	for dt: float in DTS:
		frames.append(_tframe(sc_hit, te + dt, 1.0, _mid(sc_hit, te, 12.0), "%.2f s after the roll" % dt))
	rows.append(_row("hit", "b. A HIT AND A MISS: one of the fighter's guns misses, the other lands on the bomber (the roll is at 1.0 s); its damage smoke (W1) starts", CROP, setup_hit, frames, 2))
	# c. close in (zoom 2): the bomber's tail and the rounds arriving
	frames = []
	for dt: float in [0.06, 0.10, 0.14, 0.24]:
		var b: Vector2 = _pose(sc_hit, "bomber", te)["pos"]
		frames.append(_tframe(sc_hit, te + dt, 2.0, b + Vector2(-30.0, 4.0), "%.2f s, zoom 2 (the closest the camera goes)" % dt))
	rows.append(_row("close", "c. CLOSE IN (zoom 2.0): the bomber's tail, its turret firing back, the fighter's rounds arriving", CROP, setup_hit, frames, 1))
	# d. the pass at play, zoom 0.6, flak and smoke and ribbons
	frames = []
	for tau: float in [1.1, 2.1, 3.1, 4.1, 5.0]:
		frames.append(_tframe(sc_hit, tau, 0.6, _mid(sc_hit, tau, 10.0), "%.1f s into the turn" % tau))
	rows.append(_row("pass", "d. THE PASS AT PLAY (zoom 0.6): the whole turn's fire, flak F2 from the village, the bomber's smoke W1, the wingtip ribbons", WIDE, setup_hit_flak, frames, 1))
	# e. the planning zoom
	frames = []
	for tau: float in [1.1, 2.1, 3.1, 4.1, 5.0]:
		frames.append(_tframe(sc_hit, tau, 0.35, _mid(sc_hit, tau, 10.0), "%.1f s into the turn" % tau))
	rows.append(_row("plan", "e. THE PLANNING VIEW (zoom 0.35): the same turn; the planes are 14 px", WIDE, setup_hit_flak, frames, 1))
	# f. the real rate: two fighters and the bomber
	frames = []
	for tau: float in [1.1, 2.1, 3.1, 4.1]:
		frames.append(_tframe(sc_fight, tau, 0.6, _mid(sc_fight, tau, 10.0), "%.1f s into the turn" % tau))
	rows.append(_row("fight", "f. THE REAL RATE (zoom 0.6): two fighters on the bomber, as the sim rolls them, with the flak, the smoke and the ribbons", WIDE, setup_fight, frames, 1))
	return rows

# --- The board --------------------------------------------------------------------------------------------------------------------------

# A row run with the camera first, then the per-frame ribbons (the frame's "ribbons" callable builds them once the camera has moved).
func _run_row(r: Dictionary) -> Dictionary:
	if (r["setup"] as Callable).is_valid():
		(r["setup"] as Callable).call()
	var imgs: Array = []
	var caps: Array = []
	for f: Dictionary in r["frames"]:
		rig.fx.set_time(T0 + float(f["dt"]))
		rig.set_planes(f["planes"])
		rig.set_towers([])
		var pre := Callable()
		if f.has("ribbons"):
			var rb: Callable = f["ribbons"]
			pre = func() -> void: rig.proxy.ribbons = rb.call()
		else:
			rig.proxy.ribbons = []
		var img: Image = await rig.grab(f["center"], float(f["zoom"]), r["crop"], pre)
		imgs.append(img)
		caps.append(str(f["cap"]))
	print("[fx-tracers] row %s: %d frames (%s, tracers %d)" % [r["key"], imgs.size(), str(rig.fx.stats()), rig.fx.field.tracers.records.size() if rig.fx.field.tracers != null else 0])
	return {"key": r["key"], "title": r["title"], "frames": imgs, "caps": caps, "key_frame": int(r["key_frame"]), "crop": r["crop"]}

func _tracer_board() -> void:
	var book := FxTracer.Book.new(fxd)
	var names: Array = _names(book.option_names())
	var sc_miss := _scenario(SEED_MISS)
	var sc_hit := _scenario(SEED_HIT)
	var sc_fight := _scenario(SEED_FIGHT, true)
	print("[fx-tracers] fire events: miss seed %d: %d, hit seed %d: %d, fight seed %d: %d; hits %d / %d / %d" % [SEED_MISS, sc_miss["fires"].size(), SEED_HIT, sc_hit["fires"].size(), SEED_FIGHT, sc_fight["fires"].size(), sc_miss["hits"].size(), sc_hit["hits"].size(), sc_fight["hits"].size()])
	var data := {}
	var specimens := {}
	for name: String in names:
		var rows: Array = []
		for r: Dictionary in _tracer_rows(name, sc_miss, sc_hit, sc_fight):
			if _only != "" and str(r["key"]) != _only:
				continue
			rows.append(await _run_row(r))
		data[name] = rows
		specimens[name] = await _specimen_tracers(name)
	await _write_board({
		"id": "tracers", "kind": "tracers", "title": "Machine-gun tracers",
		"question": "How is a machine gun's tracer drawn: a short-lived line of fire from the gun toward its target in the map's own materials (ink, paper, the side accents), no glow, no new hue; a hit ends on the target and a miss passes beside it. (Alex 2026-10-11, the second playtest: 'We should show tracers for machine guns.'; scope, decision tracers-mg: 'Tracers for mg only for now, we may want to revisit for other direct fire weapons like the tank'.)",
		"source": "scripts/fx/fx_board_tracers.gd over the real map (terrain provider) at 2 px/m, planes at the sandbox's own scale (36 px at zoom 1); the scene is one resolved turn of the real sim, its fire events fed through FxTracer.feed_event (the call the game's CombatFeed makes), the tracers FxLayer.tracer",
		"intro": "A light fighter (side A, 100 m/s) chases a bomber (side B, 85 m/s) 150 m ahead, both at 400 m; the sim resolves a turn and every fire event is drawn: the fighter's twin wing guns (two tracers a roll), the bomber's tail turret firing back, hits and misses as the sim rolled them (most rolls miss). Rows a to c are close (zoom 1.0 and 2.0), d to f the turn at play and at the planning zoom 0.35, beside the damage smoke W1, flak F2 and the wingtip ribbons. Time runs left to right. The second plane of row f is another side-A fighter. Sun from the NW, shadows 44%. NO FIRE, no glow, no new hue. ALL OPTIONS ARE PROPOSED; none is chosen.",
		"held": {"scene": "one resolved turn of the real sim over the village: a light fighter (side A) 150 m behind a bomber (side B), both at 400 m, the fighter 16 m to its left; seeds %d (a miss volley), %d (a hit) and %d (two fighters); every fire event drawn" % [SEED_MISS, SEED_HIT, SEED_FIGHT], "light": "sun azimuth 315, elevation 46; shadow strength 0.44", "pen": "shadow side", "fire": "none", "weapons": "the machine guns of data/fx/fx.json tracers.weapons (PROPOSED list; the scope is Alex's)", "fog": "all units seen"},
		"recommendation": {"option": "T2", "_proposed": true, "_reason": "PROPOSED by Track TR, not Alex's call: T2 (a paper-light streak with an ink edge) reads as a bright round, which is what a tracer is, without a glow or a new hue: the ink edge keeps it visible on forest, hatching and the ribbons, it is the most visible of the thin marks at the planning zoom, and its fading hairline shows who fired at whom. T5 is the same streak in plain ink with hit and miss marks, if Alex wants every roll's outcome marked; T4 is the most ink-like close in but smears at the planning zoom; T1 is the loudest and echoes the planner's dashed lines; T3 (side colours) is too faint over the blue shadows."},
	}, names, data, specimens)
	_patch_board_json()

# board.json as _write_board made it, with this board's date, area and the decision it answers.
func _patch_board_json() -> void:
	var path := out_dir.path_join("tracers").path_join("board.json")
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (v is Dictionary):
		printerr("[fx-tracers] board.json did not read back")
		rig.failures += 1
		return
	var d: Dictionary = v
	d["date"] = "2026-10-11"
	d["decision"] = "tracers-mg"
	d["parameter"] = "data/fx/fx.json#tracers.options (every value a proposed record); the working default is working_default.tracers"
	_write_json(path, d)

func _option_of(kind: String, name: String) -> Dictionary:
	if kind == "tracers":
		return FxData.unwrap(((fxd.raw["tracers"] as Dictionary)["options"] as Dictionary)[name])
	return super._option_of(kind, name)

# --- The specimen: on paper, beside a tree and a fighter ---------------------------------------------------------------------

class _SpecNode extends Node2D:
	const FxT = preload("res://scripts/fx/fx_tracer.gd")
	var book: RefCounted = null
	var style: RefCounted = null
	var items: Array = []     # {rec, age, a, b, ppm}
	func _draw() -> void:
		for it: Dictionary in items:
			var rec: Dictionary = it["rec"]
			var st: Dictionary = book.state(rec, float(rec["born"]) + float(it["age"]))
			if bool(st["alive"]):
				FxT.draw_one(self, book, style, rec, st, it["a"], it["b"], float(it["ppm"]))

func _specimen_tracers(name: String) -> Image:
	var book := FxTracer.Book.new(fxd)
	book.select(name)
	var life := FxData.f(FxData.grp(book.opt, "timing"), "life_s")
	var ages: Array = [0.02, 0.05, 0.12, life * 0.45, life * 0.8]
	var ppm := _ppm1()
	var items: Array = []
	var n := 0
	for hit: bool in [true, false]:
		for k in ages.size():
			n += 1
			var shot := "spec/%d" % n
			var a := Vector2(200.0 + float(k) * 236.0, 56.0 if hit else 140.0)
			var muzzle_w := Vector2(0.0, 0.0)
			var aim_w := Vector2(150.0, 0.0) / 2.0   # (150 px at the map's 2 px/m)
			book.add(FxRig.SEED, shot, "wing_guns", muzzle_w, muzzle_w, aim_w, 9.0, 0.0, hit, "side_a" if k % 2 == 0 else "side_b")
			var rec: Dictionary = book.records[book.records.size() - 1]
			var ln := book.line_world(rec, 1.0)
			# world metres to px at 2 px/m, to the cell
			var pa: Vector2 = a + (ln["a"] as Vector2) * 2.0
			var pb: Vector2 = a + (ln["b"] as Vector2) * 2.0
			items.append({"rec": rec, "age": ages[k], "a": pa, "b": pb, "ppm": ppm})
	return await rig.specimen(Vector2i(1400, 190), func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(40, 60), cl, 19.0)
		_plane_specimen(cl, Vector2(110, 60))
		var sn := _SpecNode.new()
		sn.book = book
		sn.style = fxs
		sn.items = items
		cl.add_child(sn)
	)
