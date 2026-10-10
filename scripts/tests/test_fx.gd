extends "res://scripts/test_support/test_case.gd"

# THE EFFECTS (Track X: damage smoke and the three phases of a death). Headless: the
# numbers, not the pixels (scripts/fx/fx_board.gd and fx_gallery_shot.gd are the looks).
#
#   1. data/fx/fx.json: every value is a PROPOSED value record with a reason; every
#      colour role resolves to a palette colour; the INTERIM fire (treatment 6 of docs/proposals/
#      fire-in-ink.md) sits in the sRGB gamut at or below the side accents' chroma and 0.12 from
#      both in OKLab, the flash is lighter than every fill; the OKLCH maths reproduces Alex's side colours
#   2. damage smoke: none at full health; the puff rate, size and tone follow the
#      data and grow as health falls; puffs are left on the emission grid; their fade
#      follows the data (hold, the power curve, the palette's alpha steps) and ends at
#      the life the data gives; the smoke leaves at the plane's tail
#   3. determinism: two runs of the same calls make the same field, whatever the
#      cadence of the calls (emit_path), and a scrub back and forth makes no duplicates
#   4. the three phases: a mid-air explosion (burst at its height, pieces that fall by
#      the data's gravity and land, smoke left in the sky); out of control (a trail and
#      a rider while the sim flies it); the ground impact (burst, plume, a scar that
#      stays); FAST FLASHES WITH A VERY SLOW DECAY holds for every option's data
#   5. the shadow rule: 1% of the height along the light, the unit markers' own
#   6. the layer allocates nothing it does not free (nodes, puffs, caches), caps its puffs
#   7. the boards' records exist and choose nothing
#   8. round 2 of the damage smoke: C0 is round 1's C; the levers (no scallops, open arcs, streaming, cool
#      wash, dashed and ageing rings) and the plain white / grey smoke are in the data; thick smoke casts a
#      shadow; every option draws in every tone and stage; every frame of the board exists at native size

const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxField = preload("res://scripts/fx/fx_field.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

func setup(_main) -> void:
	var data := FxData.new()
	if not check(data.ok(), "fx.json loads: %s" % str(data.errors)):
		finish()
		return
	var st := FxStyle.new(data)
	if not check(st.ok(), "the effects' style resolves: %s" % str(st.errors)):
		finish()
		return
	_check_data(data, st)
	_check_smoke(data, st)
	_check_determinism(data)
	_check_crash(data)
	_check_draw_crash(data, st)
	_check_shadow(st)
	_check_layer(data)
	_check_r2(data, st)
	_check_boards()
	check(FxData.shared().ok(), "no data error was raised by any of the above: %s" % str(FxData.shared().errors))
	finish()

# --- 1. The data ------------------------------------------------------------------------------------------

# Every leaf of the file but the "_" keys is a value record, a role record or a group.
func _walk_records(node: Variant, path: String, out: Array[String]) -> void:
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	if d.has("value"):
		if not (d.get("_proposed") == true or d.has("decision")):
			out.append("%s is not marked _proposed or backed by a decision" % path)
		if not (d.get("_reason") is String) or str(d.get("_reason")).strip_edges() == "":
			out.append("%s has no _reason" % path)
		return
	for k: String in d:
		if k.begins_with("_"):
			continue
		var v: Variant = d[k]
		if not (v is Dictionary):
			out.append("%s.%s is a bare value, not a value record" % [path, k])
			continue
		_walk_records(v, path + "." + k, out)

func _check_data(data: FxData, st: FxStyle) -> void:
	var bad: Array[String] = []
	for sec: String in ["accents", "common", "working_default", "fire_switch", "smoke", "crash"]:
		var node: Variant = data.raw.get(sec)
		if node is Dictionary and sec in ["smoke", "crash"]:
			node = (node as Dictionary).get("options")
			for opt: String in (node as Dictionary):
				if opt.begins_with("_"):
					continue
				_walk_records((node as Dictionary)[opt], "%s.%s" % [sec, opt], bad)
		else:
			_walk_records(node, sec, bad)
	for name: String in data.role_names():
		var r: Dictionary = data.role(name)
		if r.get("_proposed") != true or str(r.get("_reason", "")) == "":
			bad.append("role %s is not a proposed record with a reason" % name)
	check(bad.is_empty(), "every value in fx.json is a proposed value record: %s" % str(bad.slice(0, 5)))
	eq(data.smoke_option_names(), ["A", "B", "C", "D"], "four proposed damage-smoke options")
	eq(data.crash_option_names(), ["A", "B", "C", "D"], "four proposed crash options")
	# Every role an option names exists.
	var missing: Array[String] = []
	for kind: String in ["smoke", "crash"]:
		for name: String in (data.smoke_option_names() if kind == "smoke" else data.crash_option_names()):
			var o := data.smoke_option(name) if kind == "smoke" else data.crash_option(name)
			_roles_in(o, "%s.%s" % [kind, name], st, missing)
	check(missing.is_empty(), "every colour role an option names is in the roles: %s" % str(missing.slice(0, 5)))
	# The OKLCH maths is Alex's: it reproduces his side colours.
	var a := FxStyle.to_oklch(st.palette["side_a"])
	var b := FxStyle.to_oklch(st.palette["side_b"])
	near(a[0], 0.551, 0.004, "side A lightness")
	near(a[1], 0.100, 0.004, "side A chroma")
	near(a[2], 30.0, 2.0, "side A hue")
	near(b[2], 260.0, 2.0, "side B hue")
	var back := FxStyle.oklch(0.551, 0.100, 30.0)
	eq(back.to_html(false).to_upper(), "A45A4E", "oklch(0.551 0.100 30) is Alex's brick red")
	# The INTERIM fire (fire research, treatment 6: Alex rejected the orange): the gate invariants that document proposes.
	var f: Array = data.fire_oklch()
	var fc: Color = st.palette["fire"]
	var fo := FxStyle.to_oklch(fc)
	near(fo[0], float(f[0]), 0.012, "the scorch round-trips through sRGB in lightness (in gamut)")
	near(fo[1], float(f[1]), 0.012, "and in chroma")
	eq([float(f[0]), float(f[1]), float(f[2])], [0.70, 0.085, 70.0], "the interim scorch is the research's oklch(0.70 0.085 70), not the rejected orange")
	check(float(f[1]) <= a[1], "fire chroma is at or below the side colours' (it never out-shouts them): %.3f vs %.3f" % [float(f[1]), a[1]])
	check(_delta_e(fc, st.palette["side_a"]) >= 0.12 and _delta_e(fc, st.palette["side_b"]) >= 0.12, "fire is at least 0.12 from both side colours in OKLab (brick red is not fire)")
	check(float(f[2]) > 55.0 and float(f[2]) < 85.0, "its hue is on the warm paper-ink axis (hue %.0f)" % float(f[2]))
	var fl := FxStyle.to_oklch(st.palette["flash"])
	var cool := FxStyle.to_oklch(st.palette["fire_cool"])
	near(cool[0], 0.60, 0.012, "the cooling step: lightness 0.60")
	check(cool[1] <= 0.05 and cool[1] < float(f[1]), "and a lower chroma than the scorch (%.3f)" % cool[1])
	var top_fill := 0.0
	for k in ["object_fill", "wall_fill", "rock_fill", "roof_lit"]:
		top_fill = maxf(top_fill, float(FxStyle.to_oklch(st.palette[k])[0]))
	check(fl[0] >= top_fill + 0.02, "the flash is lighter than every fill by at least 0.02 (%.3f vs %.3f)" % [fl[0], top_fill])
	check(st.has_role("fire.cool") and not st.has_role("fire.pale"), "the cooling role replaces the old pale fire (which went peach)")
	check(float(FxStyle.to_oklch(st.color("burst.core"))[0]) >= top_fill + 0.02, "the burst's core role is the knock-out step, lighter than every fill")
	# The pen's ink is the palette's ink, exactly.
	eq(st.color("ink").to_html(false), st.palette["ink"].to_html(false), "the ink role is the palette's ink (the pen keys on it)")

# The distance between two colours in OKLab.
func _delta_e(c1: Color, c2: Color) -> float:
	var a := FxStyle.to_oklch(c1)
	var b := FxStyle.to_oklch(c2)
	var a1 := float(a[1]) * cos(deg_to_rad(float(a[2])))
	var b1 := float(a[1]) * sin(deg_to_rad(float(a[2])))
	var a2 := float(b[1]) * cos(deg_to_rad(float(b[2])))
	var b2 := float(b[1]) * sin(deg_to_rad(float(b[2])))
	return sqrt(pow(float(a[0]) - float(b[0]), 2.0) + pow(a1 - a2, 2.0) + pow(b1 - b2, 2.0))

func _roles_in(v: Variant, path: String, st: FxStyle, missing: Array[String]) -> void:
	if v is Dictionary:
		for k: String in v:
			var x: Variant = v[k]
			if (k.ends_with("_role") or k == "fire_role" or k == "core_role" or k == "pale_role") and x is String:
				if not st.has_role(x):
					missing.append("%s.%s=%s" % [path, k, x])
			elif (k == "lit_roles" or k == "shade_roles") and x is Array:
				for r in x:
					if not st.has_role(str(r)):
						missing.append("%s.%s=%s" % [path, k, r])
			else:
				_roles_in(x, path + "." + k, st, missing)

# --- 2. Damage smoke -----------------------------------------------------------------------------------------

func _line_sampler(t: float) -> Dictionary:
	return {"x": 1000.0 + 100.0 * t, "y": 2000.0, "height_m": 400.0, "heading": 0.0}

func _check_smoke(data: FxData, st: FxStyle) -> void:
	for name: String in data.smoke_option_names():
		var o := data.smoke_option(name)
		# none at full health, then more as it falls
		eq(FxPuff.intensity(o, 1.0), 0.0, "%s: no smoke at full health" % name)
		var i23 := FxPuff.intensity(o, 2.0 / 3.0)
		var i13 := FxPuff.intensity(o, 1.0 / 3.0)
		var i0 := FxPuff.intensity(o, 0.0)
		check(i23 > 0.0 and i23 < i13 and i13 < i0 and near(i0, 1.0, 1e-9, "%s: the last pip is the heaviest the option makes" % name), "%s: intensity rises as health falls (%.2f, %.2f, %.2f)" % [name, i23, i13, i0])
		check(FxPuff.interval_s(o, i13) < FxPuff.interval_s(o, i23), "%s: puffs come faster as health falls" % name)
		check(FxPuff.radius_m(o, i13, 9.0) > FxPuff.radius_m(o, i23, 9.0), "%s: puffs grow as health falls" % name)
		check(FxPuff.life_s(o, i13) > FxPuff.life_s(o, i23), "%s: heavier smoke lasts longer" % name)
		check(FxPuff.tone_of(o, i0) >= FxPuff.tone_of(o, i23), "%s: the tone does not lighten as health falls" % name)
		eq(FxPuff.tone_of(o, i0), 2, "%s: the last pip is the heavy tone" % name)
		# the fade follows the data
		var hold := FxData.f(o, "hold")
		eq(FxPuff.alpha_at(o, 0.0), 1.0, "%s: a puff is born at full strength" % name)
		eq(FxPuff.alpha_at(o, 1.0), 0.0, "%s: and is gone at the end of its life" % name)
		var prev := 2.0
		var steps := FxData.arr(o, "alpha_steps")
		for k in 21:
			var u := float(k) / 20.0
			var a := FxPuff.alpha_at(o, u)
			check(a <= prev + 1e-9, "%s: the fade never brightens (u %.2f)" % [name, u])
			prev = a
			if steps.size() > 0 and a > 0.0:
				var ok_step := false
				for s in steps:
					if absf(float(s) - a) < 1e-9:
						ok_step = true
				check(ok_step, "%s: alpha %.3f at u %.2f is one of the palette steps" % [name, a, u])
			elif steps.is_empty() and u > hold and u < 1.0:
				var want := pow(1.0 - (u - hold) / (1.0 - hold), FxData.f(o, "fade_power"))
				near(a, want, 1e-9, "%s: the fade is the data's power curve at u %.2f" % [name, u])
		check(FxPuff.grow_at(o, 1.0) > FxPuff.grow_at(o, 0.0), "%s: smoke swells as it hangs" % name)
		near(FxPuff.grow_at(o, 0.0), float(FxData.arr(o, "grow")[0]), 1e-9, "%s: born at the data's first scale" % name)
		near(FxPuff.grow_at(o, 1.0), float(FxData.arr(o, "grow")[1]), 1e-9, "%s: ends at its second" % name)

	# Emission through the field, option A.
	var fld := FxField.new(data)
	fld.select("A", "A")
	var o := fld.smoke_o
	eq(fld.emit_damage_smoke("p1", Vector2(1000, 2000), 400.0, 1.0, 0.0), 0, "a plane at full health leaves no smoke")
	eq(fld.puffs.size(), 0, "so there are none")
	var health := 0.5
	var i := FxPuff.intensity(o, health)
	var iv := FxPuff.interval_s(o, i)
	var made := 0
	for k in 301:
		var t := float(k) / 60.0   # 5 s at 60 calls a second
		var p := _line_sampler(t)
		made += fld.emit_damage_smoke("p2", Vector2(float(p["x"]), float(p["y"])), 400.0, health, t, 9.0, 0.0)
	eq(made, int(floor(5.0 / iv + 1e-9)) + 1, "5 s of a half-health plane leaves one puff per %.3f s (the data's interval)" % iv)
	eq(fld.puffs.size(), made, "and the field holds them")
	var worst := 0.0
	for k in fld.puffs.size():
		var p: Dictionary = fld.puffs[k]
		worst = maxf(worst, absf(float(p["born"]) - float(k) * iv))
		check(p["h"] == 400.0, "a puff is left at the plane's altitude")
		near(float(p["life"]), FxPuff.life_s(o, i), 1e-9, "a puff lives the data's life for its intensity")
		eq(p["tone"], FxPuff.tone_of(o, i), "and has the tone for it")
	check(worst < 1e-6, "puffs are born on the emission grid (worst error %s s)" % str(worst))
	# the smoke leaves from the tail (behind the plane along its heading), not from its middle
	var p0: Dictionary = fld.puffs[10]
	var plane_x := 1000.0 + 100.0 * float(p0["born"])
	check(float((p0["pos"] as Vector2).x) < plane_x - 0.35 * 9.0 + float(p0["r_m"]) * 0.36 + 1e-6, "the smoke leaves at the plane's tail")
	# life: alive for exactly its life
	var p1: Dictionary = fld.puffs[5]
	eq(bool(fld.puff_state(p1, float(p1["born"]) - 0.01)["alive"]), false, "not yet born before its time")
	eq(bool(fld.puff_state(p1, float(p1["born"]) + float(p1["life"]) * 0.99)["alive"]), true, "alive near the end of its life")
	eq(bool(fld.puff_state(p1, float(p1["born"]) + float(p1["life"]) + 0.001)["alive"]), false, "gone after it")
	var s_mid := fld.puff_state(p1, float(p1["born"]) + float(p1["life"]) * 0.5)
	near(float(s_mid["alpha"]), FxPuff.alpha_at(o, 0.5), 1e-9, "the field's alpha is the generator's at half its life")
	var drift: Vector2 = (s_mid["pos"] as Vector2) - (p1["pos"] as Vector2)
	check(drift.length() > 0.0, "smoke drifts")
	near(drift.x, float((p1["wind"] as Vector2).x) * float(p1["life"]) * 0.5, 1e-3, "by its wind, over its age")
	# the turn-scale persistence: a heavy trail is still there three turns on, and gone by its life
	var five := 5.0
	var alive_t := fld.alive_puffs(five * 4.0).size()
	check(alive_t > 0, "smoke from the first turn is still hanging four turns later (alive %d)" % alive_t)
	eq(fld.alive_puffs(5.0 + 100.0).size(), 0, "and is all gone long after")
	# the cap
	var capped := FxField.new(data)
	capped.common_max_puffs = 50
	capped.select("A", "A")
	for k in 200:
		capped.emit_damage_smoke("p9", Vector2(float(k), 0.0), 100.0, 0.1, float(k) * 0.1, 9.0, 0.0)
	eq(capped.puffs.size(), 50, "the layer caps its puffs")
	check(float((capped.puffs[0] as Dictionary)["born"]) > float((capped.puffs[capped.puffs.size() - 1] as Dictionary)["born"]) - 50.0 * 0.5, "the oldest go first")

# --- 3. Determinism ------------------------------------------------------------------------------------------------

func _digest(f: FxField) -> int:
	return hash(var_to_str([f.puffs, f.bursts, f.debris, f.scars]))

func _run_calls(data: FxData, step: float, crash: String) -> FxField:
	var f := FxField.new(data)
	f.world_seed = 20261009
	f.select("A", crash)
	var t := 0.0
	while t <= 6.0 + 1e-9:
		var p := _line_sampler(t)
		f.emit_damage_smoke("p1", Vector2(float(p["x"]), float(p["y"])), 400.0, 0.3, t, 9.0, 0.0)
		t += step
	f.explode_midair("p3", Vector2(1500, 2100), 350.0, 7.0, 9.0, 0.3)
	f.impact("p4", Vector2(1600, 2300), 8.0, 12.0, 1.0)
	return f

func _check_determinism(data: FxData) -> void:
	var a := _run_calls(data, 1.0 / 60.0, "A")
	var b := _run_calls(data, 1.0 / 60.0, "A")
	eq(_digest(a), _digest(b), "two runs of the same calls make the same field")
	check(a.puffs.size() > 40, "(and it is not an empty one: %d puffs)" % a.puffs.size())
	var c := _run_calls(data, 1.0 / 60.0, "B")
	check(_digest(a) != _digest(c), "a different option makes a different field")
	# a different cadence: the same puffs are born at the same times (the grid), within the chord error
	var d := _run_calls(data, 1.0 / 30.0, "A")
	var born_a: Array = []
	var born_d: Array = []
	for p in a.puffs:
		if p["kind"] == "smoke":
			born_a.append(snappedf(float(p["born"]), 1e-6))
	for p in d.puffs:
		if p["kind"] == "smoke":
			born_d.append(snappedf(float(p["born"]), 1e-6))
	eq(born_a, born_d, "the emission grid does not depend on how often the host calls")
	# emit_path is exact: one call or six, the same puffs
	var f1 := FxField.new(data)
	var f2 := FxField.new(data)
	f1.select("A", "A")
	f2.select("A", "A")
	var sm := func(t: float) -> Dictionary: return _line_sampler(t)
	f1.emit_path("p1", sm, 0.0, 6.0, 0.4, 9.0)
	for k in 6:
		f2.emit_path("p1", sm, float(k), float(k + 1), 0.4, 9.0)
	eq(f1.puffs.size(), f2.puffs.size(), "emit_path: the same number of puffs in one call or six")
	var same := true
	for k in mini(f1.puffs.size(), f2.puffs.size()):
		same = same and absf(float(f1.puffs[k]["born"]) - float(f2.puffs[k]["born"])) < 1e-9 and (f1.puffs[k]["pos"] as Vector2).is_equal_approx(f2.puffs[k]["pos"])
	check(same, "emit_path: the same births and places")
	# a scrub back and forth makes no duplicates
	var g := FxField.new(data)
	g.select("A", "A")
	var n0 := 0
	for k in 181:
		var t := float(k) / 60.0
		var p := _line_sampler(t)
		g.emit_damage_smoke("p1", Vector2(float(p["x"]), float(p["y"])), 400.0, 0.3, t, 9.0, 0.0)
	n0 = g.puffs.size()
	for k in range(180, 60, -1):
		var t := float(k) / 60.0
		var p := _line_sampler(t)
		g.emit_damage_smoke("p1", Vector2(float(p["x"]), float(p["y"])), 400.0, 0.3, t, 9.0, 0.0)
	eq(g.puffs.size(), n0, "playing back to 1 s leaves no new puffs")
	for k in range(60, 181):
		var t := float(k) / 60.0
		var p := _line_sampler(t)
		g.emit_damage_smoke("p1", Vector2(float(p["x"]), float(p["y"])), 400.0, 0.3, t, 9.0, 0.0)
	eq(g.puffs.size(), n0, "and playing forward again makes none")
	eq(g.alive_puffs(0.5).size() < n0, true, "a scrub back shows only what had been born by then")

# --- 4. The three phases ---------------------------------------------------------------------------------------------

func _check_crash(data: FxData) -> void:
	for name: String in data.crash_option_names():
		var f := FxField.new(data)
		f.select("A", name)
		var co := f.crash_o
		var b := FxData.grp(co, "burst")
		# FAST FLASHES WITH A VERY SLOW DECAY, in the data of every option
		var frames := FxData.arr(b, "frames_s")
		var early := 0
		for t in frames:
			if float(t) <= 0.5:
				early += 1
		check(early >= 4, "%s: the flash is drawn in %d frames within half a second (fast)" % [name, early])
		check(float(frames[frames.size() - 1]) >= 5.0 and FxData.f(b, "end_s") >= 8.0, "%s: the flipbook lingers to %.0f s (very slow decay)" % [name, FxData.f(b, "end_s")])
		for k in range(1, frames.size()):
			check(float(frames[k]) > float(frames[k - 1]), "%s: frames in time order" % name)
		var imp := FxData.grp(co, "impact")
		var mid := FxData.grp(co, "midair")
		check(FxData.f(FxData.grp(imp, "plume"), "life_s") >= 36.0 and FxData.f(FxData.grp(mid, "plume"), "life_s") >= 36.0, "%s: the plumes last 7 turns or more (smoke decays very slowly)" % name)
		# --- (a) mid-air
		f.explode_midair("m1", Vector2(2000, 2000), 400.0, 10.0, 9.0, 0.0)
		eq(f.bursts.size(), 1, "%s: one burst" % name)
		var bu: Dictionary = f.bursts[0]
		eq(bu["phase"], "midair", "%s: it is a mid-air burst" % name)
		near(float(bu["h"]), 400.0, 1e-9, "%s: at the plane's altitude" % name)
		eq(f.burst_frame(bu, 9.0), -1, "%s: nothing before the flash" % name)
		eq(f.burst_frame(bu, 10.0), 0, "%s: the first frame at the flash" % name)
		check(f.burst_frame(bu, 10.0 + 0.2) >= 3, "%s: by 0.2 s the flipbook is well on" % name)
		eq(f.burst_frame(bu, 10.0 + FxData.f(b, "end_s") + 0.01), -1, "%s: and over after its end" % name)
		eq(f.debris.size(), FxData.i(FxData.grp(mid, "debris"), "count"), "%s: the data's number of pieces" % name)
		var g := FxData.f(FxData.grp(mid, "debris"), "gravity_mps2")
		var d0: Dictionary = f.debris[0]
		near(float(d0["land_s"]), sqrt(2.0 * 400.0 / g), 1e-9, "%s: a piece lands when the data's gravity says" % name)
		var last_h := 1e9
		for k in 20:
			var s := f.debris_state(d0, 10.0 + float(k) * float(d0["land_s"]) / 20.0)
			check(bool(s["alive"]), "%s: a piece in the air is alive" % name)
			check(float(s["h"]) <= last_h + 1e-9, "%s: a falling piece only falls (its shadow gap only closes)" % name)
			last_h = float(s["h"])
		var landed := f.debris_state(d0, 10.0 + float(d0["land_s"]) + 0.5)
		if float(d0["rest_s"]) > 0.0:
			check(bool(landed["alive"]) and bool(landed["landed"]) and float(landed["h"]) == 0.0, "%s: it lies on the ground a while" % name)
		eq(bool(f.debris_state(d0, 10.0 + float(d0["land_s"]) + float(d0["rest_s"]) + 0.1)["alive"]), false, "%s: then it is gone" % name)
		var sky := 0
		for p in f.puffs:
			if p["kind"] == "plume":
				sky += 1
				near(float(p["h"]), 400.0, 1e-9, "%s: the smoke is left in the sky at 400 m" % name)
		eq(sky, FxData.i(FxData.grp(mid, "plume"), "count"), "%s: the sky plume has the data's puffs" % name)
		# --- (b) out of control
		var r := FxField.new(data)
		r.select("A", name)
		var fall := FxData.grp(r.crash_o, "falling")
		var iv := FxData.f(fall, "interval_s")
		var n := 0
		for k in 421:
			var t := float(k) / 30.0
			var h := 400.0 * (1.0 - t / 14.0)
			n += r.ride("f1", Vector2(2000.0 + 50.0 * t, 2000.0), h, t, 9.0, 0.0)
		var trail := 0
		for p in r.puffs:
			if p["kind"] == "fall":
				trail += 1
		check(absi(trail - (int(floor(14.0 / iv + 1e-9)) + 1)) <= 1, "%s: a falling plane leaves a puff every %.2f s (%d over 14 s)" % [name, iv, trail])
		check(r.riders.has("f1"), "%s: the layer knows where to hang the flame" % name)
		var h_first: float = (r.puffs[0] as Dictionary)["h"]
		var h_last: float = 0.0
		for p in r.puffs:
			if p["kind"] == "fall":
				h_last = float(p["h"])
		check(h_first > h_last, "%s: the trail's puffs are left at the plane's falling height (their shadow gaps close along it)" % name)
		var fl := FxData.grp(fall, "flame")
		var embers := 0
		for p in r.puffs:
			if p["kind"] == "ember":
				embers += 1
		check(not r.fire_on, "%s: the fire switch is off in the data (Alex: no fire for now)" % name)
		eq(embers, 0, "%s: no embers while the fire is off" % name)
		# the machinery is still there behind the switch
		var rf := FxField.new(data)
		rf.select("A", name)
		rf.fire_on = true
		for k in 421:
			var tt := float(k) / 30.0
			rf.ride("f1", Vector2(2000.0 + 50.0 * tt, 2000.0), 400.0 * (1.0 - tt / 14.0), tt, 9.0, 0.0)
		var embers_on := 0
		for p in rf.puffs:
			if p["kind"] == "ember":
				embers_on += 1
		if FxData.b(fl, "enabled") and FxData.f(fl, "ember_every_s") > 0.0:
			check(embers_on > 20, "%s: switched on, a burning plane sheds embers (%d)" % [name, embers_on])
		else:
			eq(embers_on, 0, "%s: this option sheds none" % name)
		var smoke_trail := 0
		for p in r.puffs:
			if p["kind"] == "fall":
				smoke_trail += 1
		check(smoke_trail > 20 and (r.puffs[0] as Dictionary)["tone"] >= 1, "%s: an out-of-control plane trails heavy smoke with the fire off (%d puffs)" % [name, smoke_trail])
		check(FxPuff.casts_shadow(r.set_defs["fall:" + FxData.s(fall, "smoke_option")], int(FxData.i(fall, "tone"))), "%s: the falling trail is thick: it casts a shadow" % name)
		# --- (c) the ground impact
		r.impact("f1", Vector2(2700, 2000), 14.0, 9.0, 0.3)
		check(not r.riders.has("f1"), "%s: the crash ends the fall" % name)
		var hit: Dictionary = r.bursts[r.bursts.size() - 1]
		eq(hit["phase"], "impact", "%s: a ground burst" % name)
		eq(float(hit["h"]), 0.0, "%s: on the ground" % name)
		eq(r.scars.size(), 1, "%s: a scar" % name)
		eq(r.scar_alpha(r.scars[0], 13.0), 0.0, "%s: no scar before the crash" % name)
		eq(r.scar_alpha(r.scars[0], 14.0 + 100000.0), 1.0, "%s: and it stays for the rest of the game" % name)
		var ground := 0
		var last_death := 0.0
		for p in r.puffs:
			if p["kind"] == "plume":
				ground += 1
				last_death = maxf(last_death, float(p["born"]) + float(p["life"]))
		eq(ground, FxData.i(FxData.grp(imp, "plume"), "count"), "%s: the plume has the data's puffs" % name)
		check(last_death - 14.0 >= 36.0, "%s: the plume is gone only %.0f s later" % [name, last_death - 14.0])
		var sc := FxData.grp(imp, "scar")
		var ember_n := 0
		for p in r.puffs:
			if p["kind"] == "scar_ember":
				ember_n += 1
		eq(ember_n, 0, "%s: no scar embers while the fire is off" % name)
		var ri := FxField.new(data)
		ri.select("A", name)
		ri.fire_on = true
		ri.impact("f1", Vector2(2700, 2000), 14.0, 9.0, 0.3)
		var ember_on := 0
		for p in ri.puffs:
			if p["kind"] == "scar_ember":
				ember_on += 1
		eq(ember_on, FxData.i(sc, "embers"), "%s: switched on, the scar's embers come back" % name)
		# THE SMOKE BURST (no fire): a quick thick burst of smoke, thrown out and then hanging, casting a shadow
		var sbg := FxData.grp(imp, "smoke_burst")
		var burst: Array = []
		for p in r.puffs:
			if p["kind"] == "burst":
				burst.append(p)
		eq(burst.size(), FxData.i(sbg, "count"), "%s: the impact's smoke burst has the data's puffs" % name)
		var last_b := 0.0
		for p in burst:
			last_b = maxf(last_b, float(p["born"]) - 14.0)
			check(float(p["life"]) >= 30.0, "%s: a burst puff lasts %.0f s (very slow decay)" % [name, float(p["life"])])
			eq(int(p["tone"]), FxData.i(sbg, "tone"), "%s: the burst is in the data's tone" % name)
		check(last_b <= 0.5, "%s: the burst is over in half a second (FAST): %.2f s" % [name, last_b])
		check(FxPuff.casts_shadow(r.set_defs[(burst[0] as Dictionary)["set"]], int(FxData.i(sbg, "tone"))) or FxData.i(sbg, "tone") < 1, "%s: a thick burst casts a ground shadow" % name)
		var b0: Dictionary = burst[0]
		var d1 := ((r.puff_state(b0, float(b0["born"]) + 1.0)["pos"] as Vector2) - (b0["pos"] as Vector2) - (b0["wind"] as Vector2) * 1.0).length()
		var d3 := ((r.puff_state(b0, float(b0["born"]) + 3.0)["pos"] as Vector2) - (b0["pos"] as Vector2) - (b0["wind"] as Vector2) * 3.0).length()
		var d8 := ((r.puff_state(b0, float(b0["born"]) + 8.0)["pos"] as Vector2) - (b0["pos"] as Vector2) - (b0["wind"] as Vector2) * 8.0).length()
		check(d1 > 3.0 and (d8 - d3) < 0.15 * d3, "%s: the burst is thrown out fast, then hangs (%.1f m at 1 s, %.1f at 3 s, %.1f at 8 s)" % [name, d1, d3, d8])
		check(float(r.puff_state(b0, float(b0["born"]) + 1.0)["scale"]) > float(r.puff_state(b0, float(b0["born"]) + 0.02)["scale"]) * 1.4, "%s: and it swells quickly" % name)
		# the mid-air burst hangs at the plane's height, so its shadow gap shows the altitude
		var rm := FxField.new(data)
		rm.select("A", name)
		rm.explode_midair("m1", Vector2(2000, 2000), 400.0, 10.0, 9.0, 0.0)
		var mid_n := 0
		for p in rm.puffs:
			if p["kind"] == "burst":
				mid_n += 1
				near(float(p["h"]), 400.0, 1e-9, "%s: the mid-air smoke burst is at 400 m" % name)
		eq(mid_n, FxData.i(FxData.grp(FxData.grp(rm.crash_o, "midair"), "smoke_burst"), "count"), "%s: the mid-air burst has the data's puffs" % name)
		# any smoke variant can be the crash's smoke
		var ro := FxField.new(data)
		ro.select("A", name, "C6")
		ro.impact("f1", Vector2(2700, 2000), 0.0, 9.0, 0.3)
		var found := false
		for k: String in ro.set_defs:
			if k.begins_with("burst:") and k.ends_with(":C6"):
				found = true
				eq(FxData.s(ro.set_defs[k], "form"), "arcs", "the crash's smoke can be drawn in another option (C6's form)")
		check(found, "%s: the smoke override reaches the burst" % name)
		# AN EXPLOSION, THEN A SMOKING WRECK (Alex): the wreck keeps smoking for turns, thinning as it goes
		var smo := FxData.grp(imp, "smolder")
		var dur := FxData.f(smo, "duration_s")
		var col: Array = []
		for p in r.puffs:
			if p["kind"] == "smolder":
				col.append(p)
		check(col.size() > 20, "%s: the wreck smokes in a column of puffs (%d)" % [name, col.size()])
		check(dur >= 36.0, "%s: for %.0f s, seven turns or more" % [name, dur])
		var gap_ok := true
		var tone_ok := true
		var gaps: Array = []
		for k in range(1, col.size()):
			gaps.append(float(col[k]["born"]) - float(col[k - 1]["born"]))
			if int(col[k]["tone"]) > int(col[k - 1]["tone"]):
				tone_ok = false
		for k in range(1, gaps.size()):
			if float(gaps[k]) + 1e-9 < float(gaps[k - 1]):
				gap_ok = false
		check(gap_ok, "%s: the puffs come further apart as the wreck burns out" % name)
		check(tone_ok, "%s: the column greys from the heavy tone toward the thin and never darkens again" % name)
		eq(int(col[0]["tone"]), 2, "%s: it starts heavy" % name)
		eq(int(col[col.size() - 1]["tone"]), 0, "%s: and ends thin" % name)
		check(float(col[col.size() - 1]["born"]) - 14.0 > dur * 0.9, "%s: the last puff of the column is born near the end of its duration" % name)
		check(float(col[0]["r_m"]) > float(col[col.size() - 1]["r_m"]), "%s: the column narrows" % name)
		var alive_5 := 0
		var alive_15 := 0
		for pr in col:
			if bool(r.puff_state(pr, 14.0 + 5.0)["alive"]):
				alive_5 += 1
			if bool(r.puff_state(pr, 14.0 + 15.0)["alive"]):
				alive_15 += 1
		check(alive_5 > 3 and alive_15 > 3, "%s: the wreck is smoking one turn later (%d puffs) and three turns later (%d)" % [name, alive_5, alive_15])
		var end_t := 0.0
		for pr in col:
			end_t = maxf(end_t, float(pr["born"]) + float(pr["life"]))
		var alive_end := 0
		for pr in col:
			if bool(r.puff_state(pr, end_t + 0.01)["alive"]):
				alive_end += 1
		eq(alive_end, 0, "%s: and it stops smoking in the end (the scar and the wreck stay)" % name)
		var wreck := FxData.arr(sc, "wreck_pieces")
		check(wreck.size() >= 2 and wreck.has("fuselage"), "%s: the scar carries a wreck: %s" % [name, str(wreck)])
		# a bigger plane, a bigger burst, but not in proportion
		var small := r.size_factor(9.0)
		var big := r.size_factor(20.0)
		near(small, 1.0, 1e-9, "%s: a 9 m plane is the reference" % name)
		check(big > 1.0 and big < 20.0 / 9.0, "%s: a 20 m bomber's burst is bigger but not 2.2 times" % name)

# Every burst frame, flame, ember, piece, scar and wreck of every crash option can be drawn (the drawing layer
# records headless; a missing data key is recorded by FxData and fails the last check of setup()).
func _check_draw_crash(data: FxData, st: FxStyle) -> void:
	var n := 0
	for name: String in data.crash_option_names():
		var co := data.crash_option(name)
		var b := FxData.grp(co, "burst")
		for ground in [false, true]:
			for t in FxData.arr(b, "frames_s"):
				var g := InkCanvas.new(Vector2i(120, 120))
				FxBurst.draw_burst(g, st, b, float(t), 7, 30.0, Vector2(60, 60), ground)
				g.discard()
				n += 1
		var fl := FxData.grp(FxData.grp(co, "falling"), "flame")
		var g2 := InkCanvas.new(Vector2i(60, 60))
		FxBurst.draw_flame(g2, st, fl, 5, 25.0, 10.0, Vector2(30, 3))
		FxBurst.draw_ember(g2, st, fl, 1.4, Vector2(10, 10))
		g2.discard()
		var deb := FxData.grp(FxData.grp(co, "midair"), "debris")
		for masked in [false, true]:
			var g3 := InkCanvas.new(Vector2i(30, 30))
			FxBurst.draw_shard(g3, st, deb, 3, 5.0, Vector2(15, 15), masked)
			g3.discard()
		var g4 := InkCanvas.new(Vector2i(120, 120))
		FxBurst.draw_scar(g4, st, FxData.grp(FxData.grp(co, "impact"), "scar"), 9, 30.0, Vector2(60, 60), 36.0)
		g4.discard()
		n += 4
	# ... and with the fire switched on (the machinery is still there)
	st.fire_on = true
	for name: String in data.crash_option_names():
		var co := data.crash_option(name)
		var b := FxData.grp(co, "burst")
		for t in FxData.arr(b, "frames_s"):
			var g := InkCanvas.new(Vector2i(120, 120))
			FxBurst.draw_burst(g, st, b, float(t), 7, 30.0, Vector2(60, 60), true)
			g.discard()
			n += 1
	st.fire_on = false
	check(n > 100, "every crash option's burst frames (fire off and on), flame, ember, piece, scar and wreck can be drawn (%d drawings)" % n)

# --- 5. The shadow rule ----------------------------------------------------------------------------------------------

func _check_shadow(st: FxStyle) -> void:
	var ui := UiStyle.new()
	if not check(ui.ok(), "the UI style loads (to compare the shadow rule)"):
		return
	for h in [0.0, 120.0, 400.0, 1000.0]:
		var mine := st.plane_shadow_offset_m(h)
		var theirs: Vector2 = ui.plane_shadow_offset_m(h)
		check(mine.is_equal_approx(theirs), "the shadow of a thing at %.0f m sits where the plane's does" % h)
	near(st.plane_shadow_offset_m(400.0).length(), 400.0 * 0.01 / tan(deg_to_rad(46.0)), 1e-5, "1% of 400 m, away from the sun at 46 degrees")
	check(st.plane_shadow_offset_m(1000.0).length() > st.plane_shadow_offset_m(120.0).length(), "the gap closes as the thing nears the ground")
	eq(st.plane_shadow_offset_m(0.0), Vector2.ZERO, "and is nothing on the ground")

# --- 6. The layer frees what it allocates ---------------------------------------------------------------------------------------

func _check_layer(data: FxData) -> void:
	var orphans_before := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var nodes_before := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2.0, 2.0), 0.0, Vector2.ZERO), 20261009)
	layer.true_scale = 2.0
	check(not layer.is_fire(), "the layer runs with the fire switched off")
	check(layer.ground_node != null and layer.shadow_node != null and layer.air_node != null and layer.top_node != null, "the layer builds its four passes")
	var children: Array[Node] = [layer.ground_node, layer.shadow_node, layer.air_node, layer.top_node]
	for k in 120:
		var t := float(k) / 30.0
		layer.emit_damage_smoke("p1", Vector2(1000.0 + 100.0 * t, 2000.0), 400.0, 0.3, t, 9.0, 0.0)
		layer.falling("p2", Vector2(1500.0, 2000.0 + 20.0 * t), 400.0 - 50.0 * t, t, 9.0, 1.0)
	layer.explode_midair("p3", Vector2(1800, 2000), 300.0, 2.0)
	layer.impact("p4", Vector2(1900, 2100), 3.0)
	layer.add_scar("p5", Vector2(2000, 2200), 3.5)
	layer.set_time(4.0)
	await get_tree().process_frame
	await get_tree().process_frame   # (headless: nothing is drawn, nothing is baked, nothing breaks)
	var st := layer.stats()
	check(int(st["puffs"]) > 40 and int(st["bursts"]) == 2 and int(st["scars"]) == 2 and int(st["debris"]) > 0, "the layer holds what was asked of it: %s" % str(st))
	eq(int(st["bakes"]), 0, "headless: no art is baked (the dummy renderer draws nothing)")
	layer.clear()
	var cleared := layer.stats()
	eq([cleared["puffs"], cleared["bursts"], cleared["debris"], cleared["scars"], cleared["riders"]], [0, 0, 0, 0, 0], "clear() empties the field")
	for k in 40:
		layer.emit_damage_smoke("p1", Vector2(float(k), 0.0), 100.0, 0.3, float(k) * 0.2, 9.0, 0.0)
	check(layer.field.puffs.size() > 0, "and it can be used again")
	remove_child(layer)
	layer.free()
	for c in children:
		check(not is_instance_valid(c), "freeing the layer frees its pass nodes")
	await get_tree().process_frame
	eq(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT), orphans_before, "no orphan node is left behind")
	eq(Performance.get_monitor(Performance.OBJECT_NODE_COUNT), nodes_before, "and the node count is what it was")
	# a field that is dropped holds nothing (RefCounted)
	var weak: WeakRef
	var f := FxField.new(data)
	f.select("A", "A")
	f.explode_midair("x", Vector2.ZERO, 100.0, 0.0)
	weak = weakref(f)
	f = null
	eq(weak.get_ref(), null, "a dropped field is freed (no cycle)")

# --- 8. Damage smoke, round 2 (variants/damage-smoke-r2/) ---------------------------------------------------------------------

func _check_r2(data: FxData, st: FxStyle) -> void:
	eq(data.smoke_r2_option_names(), ["C0", "C1", "C2", "C3", "C4", "C5", "C6", "W1", "W2", "W3"], "round 2: the reference, six contour variants and three plain ones")
	# every value is a proposed record, every role resolves
	var bad: Array[String] = []
	var r2: Dictionary = ((data.raw.get("smoke_r2") as Dictionary).get("options") as Dictionary)
	for opt: String in r2:
		_walk_records(r2[opt], "smoke_r2." + opt, bad)
	check(bad.is_empty(), "round 2: every value is a proposed value record: %s" % str(bad.slice(0, 4)))
	var missing: Array[String] = []
	for name: String in data.smoke_r2_option_names():
		_roles_in(data.smoke_option(name), "smoke_r2." + name, st, missing)
	check(missing.is_empty(), "round 2: every colour role an option names exists: %s" % str(missing.slice(0, 4)))
	# C0 is round 1's C, unchanged
	eq(data.smoke_option("C0"), data.smoke_option("C"), "C0 is today's C exactly")
	var c0 := data.smoke_option("C0")
	check(not FxData.b(c0, "ground_shadow"), "C0, the reference, casts no shadow (as it did)")
	# thick smoke casts a shadow in every variant, thin smoke does not
	for name: String in data.smoke_r2_option_names():
		if name == "C0":
			continue
		var o := data.smoke_option(name)
		check(FxData.b(o, "ground_shadow"), "%s: thick smoke casts a ground shadow (Alex)" % name)
		check(not FxPuff.casts_shadow(o, 0) and FxPuff.casts_shadow(o, 1) and FxPuff.casts_shadow(o, 2), "%s: from the medium tone up, not the thin" % name)
	# the levers
	var c1 := data.smoke_option("C1")
	eq(FxData.f(c1, "lobe_amp"), 0.0, "C1: no scallops (round lobes)")
	check(FxData.b(c1, "outline_union") and not FxData.b(c1, "ticks"), "C1: one smooth outline, no cusp ticks")
	eq(FxData.s(data.smoke_option("C2"), "form"), "arcs", "C2: open arcs")
	check(FxData.arr(data.smoke_option("C2"), "arc_sweep_deg")[1] < 360, "C2: an arc never closes")
	for name: String in ["C3", "C6"]:
		var o := data.smoke_option(name)
		check(FxData.f(o, "stretch") > 1.5, "%s: streams along the flight path" % name)
		var sv := FxPuff.stretch_xy(o)
		check(sv.x > 1.0 and sv.y < 1.0 and absf(sv.x * sv.y - 1.0) < 0.35, "%s: longer along the path, area roughly kept (%s)" % [name, str(sv)])
	eq(FxPuff.stretch_xy(c0), Vector2.ONE, "a round puff is not stretched")
	var c4 := data.smoke_option("C4")
	for r in FxData.arr(c4, "lit_roles"):
		var col: Color = st.color(str(r))
		check(col.a < 0.5 and col.b >= col.r, "C4: the core is a light cool wash (%s alpha %.2f)" % [r, col.a])
	# ageing: rings and outline thin and break in stages, never come back
	for name: String in ["C5", "C6"]:
		var o := data.smoke_option(name)
		eq(FxData.i(o, "stages"), 3, "%s: three age stages" % name)
		eq(FxPuff.stage_of(o, 0.0), 0, "%s: a fresh puff is stage 0" % name)
		eq(FxPuff.stage_of(o, 0.3), 1, "%s: a quarter through its life it is stage 1" % name)
		eq(FxPuff.stage_of(o, 0.9), 2, "%s: late in its life, stage 2" % name)
		var keep := FxData.arr(o, "stage_ring_keep")
		check(keep.size() == 3 and float(keep[0]) >= float(keep[1]) and float(keep[1]) >= float(keep[2]) and float(keep[2]) < float(keep[0]), "%s: the rings thin as it ages: %s" % [name, str(keep)])
	eq(FxData.s(data.smoke_option("C5"), "ring_style"), "dashed", "C5: dashed ring lines")
	# the plain translucent smoke
	var flash := FxStyle.to_oklch(st.palette["flash"])
	near(flash[0], 0.967, 0.01, "the white is the knock-out step, lightness 0.967")
	check(flash[1] < 0.03, "and it has almost no chroma (%.3f): no new hue" % flash[1])
	var w1 := data.smoke_option("W1")
	eq(FxData.s(w1, "form"), "soft", "W1: soft translucent puffs")
	var roles := FxData.arr(w1, "lit_roles")
	eq(roles.size(), 9, "W1: a wash for each of three stages and three tones")
	for stage in 3:
		for tone in 3:
			var col: Color = st.color(str(roles[stage * 3 + tone]))
			check(col.a > 0.0 and col.a < 0.7, "W1: stage %d tone %d is translucent (alpha %.2f): the map shows through" % [stage, tone, col.a])
			var ok := FxStyle.to_oklch(col)
			check(ok[1] < 0.05, "W1: stage %d tone %d has paper-level chroma at most (%.3f): no new hue" % [stage, tone, ok[1]])
	for tone in 3:
		var lw: float = FxStyle.to_oklch(st.color(str(roles[tone])))[0]
		var lg: float = FxStyle.to_oklch(st.color(str(roles[3 + tone])))[0]
		var gr: float = FxStyle.to_oklch(st.color(str(roles[6 + tone])))[0]
		check(lw > lg and lg > gr, "W1: tone %d goes white, then light grey, then grey (L %.2f, %.2f, %.2f)" % [tone, lw, lg, gr])
		var a_w: float = st.color(str(roles[tone])).a
		var a_g: float = st.color(str(roles[6 + tone])).a
		check(a_w > a_g, "W1: tone %d thins as it greys (alpha %.2f to %.2f)" % [tone, a_w, a_g])
	check(not FxData.arr(w1, "lit_roles").has("ink"), "W1: no ink outline in it")
	check(FxData.f(w1, "soft_steps") >= 2, "W1: stepped washes, not a gradient")
	for name: String in ["W2", "W3"]:
		eq(FxData.s(data.smoke_option(name), "form"), "soft", "%s: soft translucent puffs" % name)
		eq(FxData.i(data.smoke_option(name), "stages"), 1, "%s: one colour at every age" % name)
	# every option, tone, stage and form can be DRAWN (headless: the drawing layer records, nothing renders):
	# a missing data key would be recorded by FxData and fail the last check of setup()
	var n_drawn := 0
	for kind: String in ["smoke", "r2"]:
		var names: Array = data.smoke_option_names() if kind == "smoke" else data.smoke_r2_option_names()
		for name: String in names:
			var o := data.smoke_option(name)
			for tone in 3:
				for stage in maxi(FxData.i(o, "stages"), 1):
					var g := InkCanvas.new(Vector2i(80, 80))
					FxPuff.draw_puff(g, st, o, tone, 12345 + tone, 20.0, Vector2(40, 40), stage)
					g.discard()
					n_drawn += 1
				var m := InkCanvas.new(Vector2i(80, 80))
				FxPuff.draw_mask(m, st, o, tone, 12345 + tone, 20.0, Vector2(40, 40))
				m.discard()
	check(n_drawn >= 60, "every smoke option can be drawn in every tone and stage (%d drawings)" % n_drawn)
	# the field carries the way a puff was flying, for the streaming options
	var f := FxField.new(data)
	f.select("C3", "A")
	f.emit_damage_smoke("p1", Vector2(100, 100), 400.0, 0.4, 0.0, 9.0, 0.7)
	check(f.puffs.size() == 1 and absf(float((f.puffs[0] as Dictionary)["dir"]) - 0.7) < 1e-9, "a puff remembers the heading it was left on (streaming turns it to it)")
	# the boards' records and every frame, at native size
	var path := "res://variants/damage-smoke-r2/board.json"
	if check(FileAccess.file_exists(path), "damage-smoke-r2: board.json exists"):
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if check(j is Dictionary, "damage-smoke-r2: board.json parses"):
			check((j as Dictionary).get("chosen", 1) == null, "damage-smoke-r2: nothing is chosen")
			eq(((j as Dictionary).get("options", []) as Array).size(), 10, "damage-smoke-r2: ten options")
	var lp := "res://variants/damage-smoke-r2/frames.json"
	if check(FileAccess.file_exists(lp), "damage-smoke-r2: frames.json exists"):
		var l: Variant = JSON.parse_string(FileAccess.get_file_as_string(lp))
		if check(l is Dictionary, "damage-smoke-r2: frames.json parses"):
			var opts_l: Array = (l as Dictionary).get("options", [])
			eq(opts_l.size(), 10, "frames.json lists ten options")
			var size_a: Array = (l as Dictionary).get("size_px", [0, 0])
			var counted := 0
			var missing_f: Array[String] = []
			for e in opts_l:
				var rows: Array = (e as Dictionary).get("rows", [])
				check(rows.size() >= 4, "%s: at least four rows (thin, thick, grove, ribbon; the others beside C0)" % (e as Dictionary).get("option"))
				for r in rows:
					check(str((r as Dictionary).get("title", "")) != "", "every row has a title")
					for fr in (r as Dictionary).get("frames", []):
						counted += 1
						var rel := str((fr as Dictionary).get("file", ""))
						var ap := ProjectSettings.globalize_path("res://variants/damage-smoke-r2/" + rel)
						if not FileAccess.file_exists(ap):
							missing_f.append(rel)
						check(str((fr as Dictionary).get("caption", "")) != "", "every frame has a caption: %s" % rel)
			check(missing_f.is_empty(), "every listed frame exists as its own PNG: %s" % str(missing_f.slice(0, 3)))
			check(counted > 150, "frames.json lists %d frames" % counted)
			# a frame is the native size
			var im := Image.load_from_file(ProjectSettings.globalize_path("res://variants/damage-smoke-r2/frames/W1_r2_0.png"))
			if check(im != null and not im.is_empty(), "a frame loads"):
				eq([im.get_width(), im.get_height()], [int(size_a[0]), int(size_a[1])], "and it is the native size listed")

# --- 7. The boards ------------------------------------------------------------------------------------------------------------

func _check_boards() -> void:
	for id: String in ["damage-smoke", "crash-explosion"]:
		var path := "res://variants/%s/board.json" % id
		if not check(FileAccess.file_exists(path), "%s: board.json exists" % id):
			continue
		var j: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not check(j is Dictionary, "%s: board.json parses" % id):
			continue
		var d: Dictionary = j
		eq(d.get("id"), id, "%s: its id" % id)
		eq(int(d.get("seed", 0)), 20261009, "%s: seed 20261009" % id)
		check(d.has("chosen") and d["chosen"] == null, "%s: nothing is chosen" % id)
		eq((d.get("options", []) as Array).size(), 4, "%s: four options" % id)
		for o in d.get("options", []):
			check((o as Dictionary).has("parameters") and (o as Dictionary).has("file"), "%s: option %s carries its parameter set and its sheet" % [id, (o as Dictionary).get("name")])
