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
#   9. THE STRIKE (Track X2): flak bursts (a fast flash, a puff that hangs for turns, hits and misses), bomb impacts (flash, thick
#      shadowed smoke, clods, a crater that stays, a stick of six, a falling bomb that follows the sim), the radio tower's ruin
#      (the sheet's model, the fall, the column that thins, the ruin that stays and is restored); the boards' records

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
	await _check_layer(data)
	_check_r2(data, st)
	_check_strike(data, st)
	await _check_strike_layer(data)
	_check_boards()
	_check_strike_boards()
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
			# Alex 2026-10-10 (decision damage-smoke): W1, soft white to grey.
			check(str((j as Dictionary).get("chosen", "")).begins_with("W1"), "damage-smoke-r2: Alex chose W1")
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
			check(counted > 150, "frames.json lists %d frames" % counted)
			# The frames themselves are regenerated by scripts/fx/fx_board.gd (what=smoke2) and kept
			# out of git (variants/*/frames/), so a fresh checkout has none: check them only when present.
			var first := ProjectSettings.globalize_path("res://variants/damage-smoke-r2/frames/W1_r2_0.png")
			if FileAccess.file_exists(first):
				check(missing_f.is_empty(), "every listed frame exists as its own PNG: %s" % str(missing_f.slice(0, 3)))
				var im := Image.load_from_file(first)
				if check(im != null and not im.is_empty(), "a frame loads"):
					eq([im.get_width(), im.get_height()], [int(size_a[0]), int(size_a[1])], "and it is the native size listed")
			else:
				print("test_fx: the round-2 frames are not on disk (regenerate with fx_board.gd what=smoke2); skipping the frame files")

# --- 9. The strike (Track X2, 2026-10-10): flak, bombs, the radio tower -------------------------------------------------------------
#
#   flak: data holds four proposed options with palette roles only; a burst is a FAST flash (frames inside half a second) and a
#   puff that hangs for turns (very slow decay), at the target's height, its shadow by the altitude rule; a hit bursts on the
#   target, a miss beside it, a hit is bigger; the same call draws the same burst, two shots at one moment differ
#   bombs: a bomb's flash, its thick shadowed smoke burst thrown out and then hanging, its clods thrown up and landing by the data's
#   gravity, the crater that stays; a stick makes one of each in the sim's order; a falling bomb follows the sim's own arithmetic
#   the tower: the sheet's model (the same parts as the unit marker's), the flash, the mast's fall by the data's frames, the column
#   of smoke that thins over turns, the ruin that stays (and is restored the same, and for a late joiner)
#   the boards' records exist (frames only when present)

const FxRuin = preload("res://scripts/fx/fx_ruin.gd")
const FxBomb = preload("res://scripts/fx/fx_bomb.gd")
const FxFlash = preload("res://scripts/fx/fx_flash.gd")

func _strike_digest(f: FxField) -> int:
	return hash(var_to_str([f.puffs, f.bursts, f.debris, f.scars, f.craters, f.ruins, f.drops]))

func _check_strike(data: FxData, st: FxStyle) -> void:
	eq(data.flak_option_names(), ["F1", "F2", "F3", "F4"], "four proposed flak options")
	eq(data.bomb_option_names(), ["B1", "B2", "B3", "B4"], "four proposed bomb options")
	eq(data.ruin_option_names(), ["R1", "R2", "R3", "R4"], "four proposed ruin options")
	# every value is a proposed record, every role exists and is hue-free paper-and-ink
	var bad: Array[String] = []
	var missing: Array[String] = []
	for kind: String in ["flak", "bomb", "ruin"]:
		var opts: Dictionary = (data.raw.get(kind) as Dictionary).get("options")
		for name: String in opts:
			if name.begins_with("_"):
				continue
			_walk_records(opts[name], "%s.%s" % [kind, name], bad)
			var o: Dictionary = data.flak_option(name) if kind == "flak" else (data.bomb_option(name) if kind == "bomb" else data.ruin_option(name))
			_roles_in(o, "%s.%s" % [kind, name], st, missing)
			check(str(opts[name].get("_note", "")).begins_with("PROPOSED"), "%s %s is labelled proposed" % [kind, name])
	check(bad.is_empty(), "every strike value is a proposed value record: %s" % str(bad.slice(0, 4)))
	check(missing.is_empty(), "every colour role a strike option names exists: %s" % str(missing.slice(0, 4)))
	for k: String in ["flak", "bomb", "ruin"]:
		var wd: Dictionary = (data.raw.get("working_default") as Dictionary).get(k)
		check(wd.get("_proposed") == true, "the working default %s is a proposed record, not a decision" % k)
	for rname: String in data.role_names():
		if rname.begins_with("flak.") or rname.begins_with("bomb.") or rname.begins_with("ruin."):
			var c: Color = st.color(rname)
			var l := FxStyle.to_oklch(c)
			check(float(l[1]) < 0.055, "role %s has paper-and-ink chroma at most (%.3f): no new hue" % [rname, float(l[1])])
	# the flak washes lighten with age and are darker than the damage smoke's whites at every age
	for tone in 3:
		var l0: float = FxStyle.to_oklch(st.color("flak.wash.0.%d" % tone))[0]
		var l1: float = FxStyle.to_oklch(st.color("flak.wash.1.%d" % tone))[0]
		var l2: float = FxStyle.to_oklch(st.color("flak.wash.2.%d" % tone))[0]
		check(l0 < l1 and l1 < l2, "flak tone %d lightens as the puff ages (L %.2f, %.2f, %.2f)" % [tone, l0, l1, l2])
	# --- flak: timing, size, place
	for name: String in data.flak_option_names():
		var f := FxField.new(data)
		f.world_seed = 20261009
		f.select_strike(name)
		var o := f.flak_o
		var fl := FxData.grp(o, "flash")
		var bg := FxData.grp(o, "burst")
		var frames := FxData.arr(fl, "frames_s")
		var early := 0
		for t in frames:
			if float(t) <= 0.5:
				early += 1
		check(early >= 4, "%s: the flash is drawn in %d frames within half a second (fast)" % [name, early])
		check(FxData.f(bg, "life_s") >= 10.0, "%s: a burst hangs %.0f s, two turns or more (very slow decay)" % [name, FxData.f(bg, "life_s")])
		var target := Vector2(2000.0, 1500.0)
		f.flak_burst(target, 400.0, 10.0, true, "aa/1")
		f.flak_burst(target, 400.0, 10.0, false, "aa/2")
		eq(f.bursts.size(), 2, "%s: a burst each" % name)
		var hb: Dictionary = f.bursts[0]
		var mb: Dictionary = f.bursts[1]
		eq(f.burst_frame(hb, 9.99), -1, "%s: nothing before the flash" % name)
		eq(f.burst_frame(hb, 10.0), 0, "%s: the first frame at the burst" % name)
		check(f.burst_frame(hb, 10.2) >= 2, "%s: by 0.2 s the flipbook is well on" % name)
		eq(f.burst_frame(hb, 10.0 + FxData.f(fl, "end_s") + 0.01), -1, "%s: and over after its end" % name)
		check(float(hb["radius_m"]) > float(mb["radius_m"]), "%s: a hit's flash is bigger than a miss's" % name)
		var ho := FxData.arr(bg, "hit_offset_m")
		var mo := FxData.arr(bg, "miss_offset_m")
		var dh := FxData.arr(bg, "miss_dh_m")
		check((hb["pos"] as Vector2).distance_to(target) <= float(ho[1]) + 1e-6, "%s: a hit bursts on its target (%.1f m off)" % [name, (hb["pos"] as Vector2).distance_to(target)])
		var md := (mb["pos"] as Vector2).distance_to(target)
		check(md >= float(mo[0]) - 1e-6 and md <= float(mo[1]) + 1e-6, "%s: a miss bursts beside it, %.0f m off (data %s)" % [name, md, str(mo)])
		check(absf(float(hb["h"]) - 400.0) < 1e-9, "%s: a hit bursts at the target's height" % name)
		check(float(mb["h"]) >= 400.0 + float(dh[0]) - 1e-6 and float(mb["h"]) <= 400.0 + float(dh[1]) + 1e-6, "%s: a miss bursts within the data's height band (%.0f m)" % [name, float(mb["h"])])
		var hp: Array = []
		var mp: Array = []
		for p in f.puffs:
			if p["kind"] == "flak":
				if (p["unit"] as String) == "aa/1":
					hp.append(p)
				else:
					mp.append(p)
		eq(hp.size(), FxData.i(bg, "puffs_hit"), "%s: a hit leaves the data's number of puffs" % name)
		eq(mp.size(), FxData.i(bg, "puffs_miss"), "%s: a miss, its own" % name)
		var set_o: Dictionary = f.set_defs["flak:" + name]
		for p in hp:
			near(float(p["life"]) / (FxData.f(bg, "life_s") * FxData.f(bg, "hit_life_scale")), 1.0, 0.1001, "%s: a puff lives the data's life" % name)
			eq(int(p["tone"]), FxData.i(bg, "tone_hit"), "%s: a hit is in its dense tone" % name)
			check(float(p["born"]) - 10.0 < 0.3, "%s: the puffs come at the burst (%.2f s)" % [name, float(p["born"]) - 10.0])
			check(float(p["h"]) == float(hb["h"]), "%s: at the burst's height, so its shadow gap is the altitude rule's" % name)
		check(FxPuff.casts_shadow(set_o, 2) and FxPuff.casts_shadow(set_o, 1) and not FxPuff.casts_shadow(set_o, 0), "%s: a dense burst casts a ground shadow, thin ones none" % name)
		var p0: Dictionary = hp[0]
		var alive_hang := f.puff_state(p0, float(p0["born"]) + float(p0["life"]) * 0.4)
		check(bool(alive_hang["alive"]) and float(alive_hang["alpha"]) > 0.0, "%s: a puff still hangs at two fifths of its life" % name)
		eq(bool(f.puff_state(p0, float(p0["born"]) + float(p0["life"]) + 0.01)["alive"]), false, "%s: and is gone after its life" % name)
		var big0 := float(f.puff_state(p0, float(p0["born"]) + 0.01)["scale"])
		var big1 := float(f.puff_state(p0, float(p0["born"]) + 1.0)["scale"])
		check(big1 > big0 * 1.2, "%s: it swells in its first second (%.2f to %.2f)" % [name, big0, big1])
	# --- determinism and the late joiner
	var fa := FxField.new(data)
	var fb := FxField.new(data)
	for f: FxField in [fa, fb]:
		f.world_seed = 20261009
		f.flak_burst(Vector2(1000, 1000), 300.0, 5.0, false, "x")
		f.flak_burst(Vector2(1000, 1000), 300.0, 5.0, false, "y")
		f.bomb_impact(Vector2(1200, 1100), 6.0, 45.0, "b", 0)
		f.bomb_drop("b", 1, Vector2(400, 1100), 400.0, 2.0, Vector2(1210, 1100), 11.0)
		f.ruin("t1", Vector2(1500, 1500), 7.0, "radio_tower", 12.0, 0.0)
	eq(_strike_digest(fa), _strike_digest(fb), "two runs of the same strike calls make the same field")
	check(fa.bursts[0]["pos"] != fa.bursts[1]["pos"] or fa.bursts[0]["seed"] != fa.bursts[1]["seed"], "two shots at one moment burst differently (the shot id tells them apart)")
	var fo := FxField.new(data)
	fo.world_seed = 20261009
	fo.select_strike("F2", "B2", "R2")
	fo.flak_burst(Vector2(1000, 1000), 300.0, 5.0, false, "x")
	check(_strike_digest(fo) != _strike_digest(fa), "a different option makes a different field")
	var fw := FxField.new(data)
	fw.world_seed = 777
	fw.ruin("t1", Vector2(1500, 1500), 7.0, "radio_tower", 12.0, 0.0)
	check(fw.ruins[0]["seed"] != fa.ruins[0]["seed"], "another world seed makes another ruin")
	# --- bombs
	for name: String in data.bomb_option_names():
		var f := FxField.new(data)
		f.world_seed = 20261009
		f.select_strike("", name)
		var o := f.bomb_o
		var fl := FxData.grp(o, "flash")
		var blast := 45.0
		var frames := FxData.arr(fl, "frames_s")
		var early := 0
		for t in frames:
			if float(t) <= 0.5:
				early += 1
		check(early >= 4, "%s: the bomb's flash is drawn in %d frames within half a second (fast)" % [name, early])
		check(float(frames[frames.size() - 1]) >= 1.5 and FxData.f(fl, "end_s") >= 2.5, "%s: the flipbook lingers to %.1f s (a slow decay)" % [name, FxData.f(fl, "end_s")])
		f.bomb_impact(Vector2(2000, 2000), 10.0, blast, "b", 3)
		eq(f.bursts.size(), 1, "%s: one flash" % name)
		var bu: Dictionary = f.bursts[0]
		eq(bu["phase"], "bomb", "%s: a bomb's flash" % name)
		near(float(bu["radius_m"]), FxData.f(fl, "radius_frac") * blast, 1e-9, "%s: the flash is the data's fraction of the blast radius" % name)
		eq(f.burst_frame(bu, 9.9), -1, "%s: nothing before the impact" % name)
		eq(f.burst_frame(bu, 10.0), 0, "%s: the first frame at the impact" % name)
		eq(f.burst_frame(bu, 10.0 + FxData.f(fl, "end_s") + 0.01), -1, "%s: over after its end" % name)
		# the smoke burst: the data's puffs, thrown out fast, then hanging, thick (casts a shadow), a very slow decay
		var sbg := FxData.grp(o, "smoke_burst")
		var burst: Array = []
		for p in f.puffs:
			if p["kind"] == "burst":
				burst.append(p)
		eq(burst.size(), FxData.i(sbg, "count"), "%s: the smoke burst has the data's puffs" % name)
		var last_b := 0.0
		for p in burst:
			last_b = maxf(last_b, float(p["born"]) - 10.0)
			check(float(p["life"]) >= 28.0, "%s: a smoke puff lasts %.0f s (very slow decay)" % [name, float(p["life"])])
			eq(int(p["tone"]), FxData.i(sbg, "tone"), "%s: in the data's thick tone" % name)
		check(last_b <= 0.5, "%s: the burst is over in half a second (FAST): %.2f s" % [name, last_b])
		check(FxPuff.casts_shadow(f.set_defs[(burst[0] as Dictionary)["set"]], FxData.i(sbg, "tone")), "%s: thick smoke casts a ground shadow" % name)
		var b0: Dictionary = burst[0]
		var d1 := ((f.puff_state(b0, float(b0["born"]) + 1.0)["pos"] as Vector2) - (b0["pos"] as Vector2) - (b0["wind"] as Vector2) * 1.0).length()
		var d8 := ((f.puff_state(b0, float(b0["born"]) + 8.0)["pos"] as Vector2) - (b0["pos"] as Vector2) - (b0["wind"] as Vector2) * 8.0).length()
		check(d1 > 3.0 and (d8 - d1) < 0.5 * d1, "%s: thrown out fast, then it hangs (%.1f m at 1 s, %.1f at 8 s)" % [name, d1, d8])
		var rfr := FxData.arr(sbg, "radius_frac")
		check(float(b0["r_m"]) / blast >= float(rfr[0]) - 1e-9 and float(b0["r_m"]) / blast <= float(rfr[1]) + 1e-9, "%s: its radius is a fraction of the blast radius, in the data's band" % name)
		# the clods: thrown up, they rise and fall by the data's gravity, lie a while, are gone
		var deb := FxData.grp(o, "debris")
		eq(f.debris.size(), FxData.i(deb, "count"), "%s: the data's number of clods" % name)
		var g := FxData.f(deb, "gravity_mps2")
		var d: Dictionary = f.debris[0]
		near(float(d["land_s"]), 2.0 * float(d["vz"]) / g, 1e-9, "%s: a clod lands when the data's gravity says" % name)
		var apex := 0.0
		var prev := -1.0
		var rises := false
		var falls := false
		for k in 21:
			var s := f.debris_state(d, 10.0 + float(k) * float(d["land_s"]) / 20.0)
			var hh := float(s["h"])
			if prev >= 0.0:
				rises = rises or hh > prev + 1e-9
				falls = falls or hh < prev - 1e-9
			prev = hh
			apex = maxf(apex, hh)
			check(hh >= -1e-9, "%s: a clod is never under the ground" % name)
		check(rises and falls and apex > 1.0, "%s: a clod goes up and comes down (apex %.1f m)" % [name, apex])
		var landed := f.debris_state(d, 10.0 + float(d["land_s"]) + 0.5)
		check(bool(landed["alive"]) and bool(landed["landed"]) and float(landed["h"]) == 0.0, "%s: it lies on the ground a while" % name)
		eq(bool(f.debris_state(d, 10.0 + float(d["land_s"]) + float(d["rest_s"]) + 0.1)["alive"]), false, "%s: then it is gone" % name)
		# the crater stays
		eq(f.craters.size(), 1, "%s: a crater" % name)
		var cr: Dictionary = f.craters[0]
		eq(f.crater_alpha(cr, 9.9), 0.0, "%s: none before the impact" % name)
		check(f.crater_alpha(cr, 10.0 + 0.3) > 0.0 and f.crater_alpha(cr, 10.0 + 0.3) < 1.0, "%s: it darkens over its first moments, under the smoke" % name)
		eq(f.crater_alpha(cr, 10.0 + 100000.0), 1.0, "%s: and stays for the rest of the game" % name)
		near(float(cr["size_m"]), blast, 1e-9, "%s: sized by the blast radius" % name)
		f.prune(1e6)
		eq(f.craters.size(), 1, "%s: pruning forgets the dead smoke but never a crater" % name)
		# a stick of six, as the sim spaces it: one of each, in time order
		var sf := FxField.new(data)
		sf.select_strike("", name)
		for i in 6:
			sf.bomb_impact(Vector2(3000.0 + 10.2 * float(i), 2000.0), 20.0 + 0.12 * float(i), blast, "stick", i)
		eq(sf.craters.size(), 6, "%s: a stick of six leaves six craters" % name)
		eq(sf.bursts.size(), 6, "%s: and six flashes, 0.12 s apart" % name)
		near(float(sf.bursts[5]["t0"]) - float(sf.bursts[0]["t0"]), 0.6, 1e-9, "%s: in the sim's order" % name)
		check(sf.alive_puffs(21.0).size() > 0 and sf.alive_puffs(21.0 + 100.0).size() == 0, "%s: the stick's smoke hangs and is gone long after" % name)
	# --- a falling bomb follows the sim's own arithmetic
	var ff := FxField.new(data)
	var rec := {"id": "u/1/0/2", "unit": "u", "drop_index": 0, "bomb": 2, "release_turn": 1, "release_t": 0.5, "x0": 100.0, "y0": 300.0, "h0": 113.0,
		"x": 520.0, "y": 340.0, "fall_s": 4.8, "impact_turn": 1, "impact_t": 5.3}
	ff.bomb_drop("u", 2, Vector2(100.0, 300.0), 113.0, 0.5, Vector2(520.0, 340.0), 5.3)
	var dr: Dictionary = ff.drops[0]
	eq(bool(ff.drop_state(dr, 0.4)["alive"]), false, "a bomb is not drawn before its release")
	eq(bool(ff.drop_state(dr, 5.3)["alive"]), false, "nor after it lands")
	var Bombs: GDScript = load("res://scripts/sim/bombs.gd") if ResourceLoader.exists("res://scripts/sim/bombs.gd") else null
	var last_h := 1e9
	for k in 9:
		var t := 0.5 + 4.8 * float(k + 1) / 10.0
		var s := ff.drop_state(dr, t)
		check(bool(s["alive"]), "a bomb is in the air at %.2f s" % t)
		check(float(s["h"]) < last_h, "and only falls")
		last_h = float(s["h"])
		var u := (t - 0.5) / 4.8
		near(float(s["h"]), 113.0 * (1.0 - u * u), 1e-9, "its height is h0 (1 - u^2)")
		if Bombs != null:
			var sim: Dictionary = Bombs.bomb_position(rec, 1, t, 5.0)
			near(float(s["h"]), float(sim["height_m"]), 1e-6, "its height is the sim's bomb_position (%.2f s)" % t)
			check((s["pos"] as Vector2).is_equal_approx(Vector2(float(sim["x"]), float(sim["y"]))), "and so is its place")
	# --- the radio tower
	var M := FxRuin.tower_model(st.scene_seed, 0)
	var sheet_ok: bool = float(M.p["base"]) >= 5.4 and float(M.p["base"]) <= 6.6 and float(M.p["height"]) >= 23.0 and float(M.p["height"]) <= 27.0 and int(M.p["sections"]) >= 5 and int(M.p["sections"]) <= 8
	check(sheet_ok, "the tower is the unit sheet's: %.1f m base, %.0f m tall, %d sections, %s bracing" % [float(M.p["base"]), float(M.p["height"]), int(M.p["sections"]), str(M.p["brace"])])
	eq(FxRuin.tower_model(st.scene_seed, 0), M, "the model is made once")
	var UA: GDScript = load("res://scripts/ui/unit_marker_art.gd")
	var ustyle := UiStyle.new()
	if UA != null and UA.has_method("is_static") and UA.is_static("radio_tower") and ustyle.ok():
		var theirs = UA.model_for(ustyle, "radio_tower")
		var same := true
		for k: String in M.p:
			same = same and theirs.p.get(k) == M.p[k]
		check(same, "the ruin is made of the parts of the very tower the unit marker draws (same seed, same parameters)")
	eq(M.G["legs"].size(), 4, "four legs")
	eq(M.G["footings"].size(), 4, "four footings")
	near(M.G["levels"][M.G["levels"].size() - 1], float(M.p["height"]), 1e-9, "the lattice reaches the tower's height")
	for name: String in data.ruin_option_names():
		var f := FxField.new(data)
		f.world_seed = 20261009
		f.select_strike("", "", name)
		var o := f.ruin_o
		var col := FxData.grp(o, "collapse")
		var fl := FxData.grp(o, "flash")
		f.ruin("t1", Vector2(2000, 2000), 10.0, "radio_tower", 12.0, 0.0)
		eq(f.ruins.size(), 1, "%s: a ruin" % name)
		var r: Dictionary = f.ruins[0]
		eq(f.ruin_alpha(r, 9.9), 0.0, "%s: none before the blast" % name)
		eq(f.ruin_alpha(r, 10.0 + 100000.0), 1.0, "%s: and it stays for the rest of the game" % name)
		var bu: Dictionary = f.bursts[0]
		eq(bu["phase"], "tower", "%s: the blast's flash" % name)
		near(float(bu["radius_m"]), FxData.f(fl, "radius_frac") * 12.0, 1e-9, "%s: the flash is the data's fraction of the tower's size" % name)
		check(r["variant"] == int(r["seed"]) % FxData.i(o, "variants"), "%s: the ruin's variant comes from its seed" % name)
		check(float(r["fall_rad"]) >= 0.0 and float(r["fall_rad"]) <= TAU + 0.01, "%s: the mast falls one way, from the seed" % name)
		# the fall
		var mode := FxData.s(col, "mode")
		var dur := FxData.f(col, "duration_s")
		var fs := FxData.arr(col, "frames_s")
		if mode == "topple":
			eq(f.ruin_collapse_frame(r, 9.9), -1, "%s: the mast stands before the blast" % name)
			eq(f.ruin_collapse_frame(r, 10.0), 0, "%s: it begins to tip at the blast" % name)
			var k_last := f.ruin_collapse_frame(r, 10.0 + dur - 0.01)
			eq(k_last, fs.size() - 1, "%s: through the data's %d drawn angles" % [name, fs.size()])
			eq(f.ruin_collapse_frame(r, 10.0 + dur + 0.01), -1, "%s: then it lies" % name)
			check(f.ruin_lying(r, 10.0 + dur + 0.01) and not f.ruin_lying(r, 10.0 + dur - 0.01), "%s: the mast lies from the moment it is down" % name)
			check(dur <= 3.0, "%s: it falls in %.1f s (fast)" % [name, dur])
			var ends := 0
			for p in f.puffs:
				if p["kind"] == "burst" and absf((p["pos"] as Vector2).distance_to(Vector2(2000, 2000)) - 0.0) > 5.0:
					ends += 1
			check(ends > 0, "%s: a second burst of dust where the mast lands" % name)
		else:
			eq(f.ruin_collapse_frame(r, 10.5), -1, "%s: no mast falls" % name)
			eq(f.ruin_lying(r, 11.0), FxData.b(FxData.grp(o, "lattice"), "fallen"), "%s: the lattice lies at the blast only if the option says" % name)
		if FxData.i(FxData.grp(o, "debris"), "count") > 0:
			var bars := 0
			for d in f.debris:
				if d["kind"] == "bar":
					bars += 1
			eq(bars, FxData.i(FxData.grp(o, "debris"), "count"), "%s: bars of lattice are flung out" % name)
		# the column of smoke that thins over turns
		var smo := FxData.grp(o, "smolder")
		var colm: Array = []
		for p in f.puffs:
			if p["kind"] == "smolder":
				colm.append(p)
		check(colm.size() > 30, "%s: the ruin smokes in a column of puffs (%d)" % [name, colm.size()])
		check(FxData.f(smo, "duration_s") >= 60.0, "%s: for %.0f s, twelve turns or more" % [name, FxData.f(smo, "duration_s")])
		var gaps_ok := true
		var tone_ok := true
		var prev_gap := 0.0
		for k in range(1, colm.size()):
			var gap := float(colm[k]["born"]) - float(colm[k - 1]["born"])
			gaps_ok = gaps_ok and gap + 1e-9 >= prev_gap
			prev_gap = gap
			tone_ok = tone_ok and int(colm[k]["tone"]) <= int(colm[k - 1]["tone"])
		check(gaps_ok, "%s: the puffs come further apart as the column thins" % name)
		check(tone_ok and int(colm[0]["tone"]) == 2 and int(colm[colm.size() - 1]["tone"]) == 0, "%s: it greys from the heavy tone to the thin" % name)
		check(float(colm[0]["r_m"]) > float(colm[colm.size() - 1]["r_m"]), "%s: and narrows" % name)
		var a5 := 0
		var a45 := 0
		var a_end := 0
		var end_t := 0.0
		for p in colm:
			end_t = maxf(end_t, float(p["born"]) + float(p["life"]))
			if bool(f.puff_state(p, 10.0 + 5.0)["alive"]):
				a5 += 1
			if bool(f.puff_state(p, 10.0 + 45.0)["alive"]):
				a45 += 1
		for p in colm:
			if bool(f.puff_state(p, end_t + 0.01)["alive"]):
				a_end += 1
		check(a5 > 3 and a45 > 3, "%s: one turn later %d puffs are smoking, nine turns later %d" % [name, a5, a45])
		eq(a_end, 0, "%s: and it stops in the end (the ruin stays)" % name)
		f.prune(1e6)
		eq(f.ruins.size(), 1, "%s: pruning never forgets the ruin" % name)
		# a late joiner: the same call with the true time draws the same picture, and the bare ruin restores the same record
		var fl2 := FxField.new(data)
		fl2.world_seed = 20261009
		fl2.select_strike("", "", name)
		fl2.ruin("t1", Vector2(2000, 2000), 10.0, "radio_tower", 12.0, 0.0)
		var g2 := FxField.new(data)
		g2.world_seed = 20261009
		g2.select_strike("", "", name)
		var rec2 := g2.add_ruin("t1", Vector2(2000, 2000), 10.0, "radio_tower", 12.0, 0.0, int(r["seed"]))
		eq([rec2["variant"], rec2["fall_rad"], rec2["seed"]], [r["variant"], r["fall_rad"], r["seed"]], "%s: the bare ruin restores the same variant and fall" % name)
		var g3 := FxField.new(data)
		g3.world_seed = 20261009
		g3.select_strike("", "", name)
		g3.ruin("t1", Vector2(2000, 2000), 10.0, "radio_tower", 12.0, 0.0)
		eq(_strike_digest(fl2), _strike_digest(g3), "%s: a replay with the true time draws the same picture, the column and all" % name)
	# a destroyed battery (any kind but the tower): the flash, smoke and column, a scorch and pit that stay; no mast
	for name: String in data.ruin_option_names():
		var fk := FxField.new(data)
		fk.world_seed = 20261009
		fk.select_strike("", "", name)
		fk.ruin("aa1", Vector2(1000, 1000), 10.0, "anti_aircraft_battery", 14.0, 0.0)
		eq(fk.ruins.size(), 1, "%s: a destroyed battery leaves a ruin record" % name)
		eq(fk.ruins[0]["kind"], "anti_aircraft_battery", "%s: of its kind" % name)
		eq(fk.ruin_collapse_frame(fk.ruins[0], 10.2), -1, "%s: no mast falls from a battery" % name)
		eq(fk.ruin_lying(fk.ruins[0], 12.0), false, "%s: none lies" % name)
		var bars_k := 0
		var smolder_k := 0
		for d in fk.debris:
			if d["kind"] == "bar":
				bars_k += 1
		for p in fk.puffs:
			if p["kind"] == "smolder":
				smolder_k += 1
		eq(bars_k, 0, "%s: no lattice is flung out of a battery" % name)
		check(smolder_k > 30, "%s: but it smokes in a column (%d puffs)" % [name, smolder_k])
	# --- every flash frame, puff, crater, clod, bomb, bar and the whole ruin can be DRAWN (headless: the drawing layer records)
	var n_drawn := 0
	for name: String in data.flak_option_names():
		var o := data.flak_option(name)
		var fl := FxData.grp(o, "flash")
		for hit in [false, true]:
			for t in FxData.arr(fl, "frames_s"):
				var gg := InkCanvas.new(Vector2i(160, 160))
				var def := fl.duplicate()
				def["hit"] = hit
				FxBurst.draw_burst(gg, st, def, float(t), 11, 40.0, Vector2(80, 80), false)
				gg.discard()
				n_drawn += 1
		var po := FxData.grp(o, "puff").duplicate(true)
		for tone in 3:
			for stage in maxi(FxData.i(po, "stages"), 1):
				var g3 := InkCanvas.new(Vector2i(100, 100))
				FxPuff.draw_puff(g3, st, po, tone, 777 + tone, 22.0, Vector2(50, 50), stage)
				g3.discard()
				n_drawn += 1
			var g4 := InkCanvas.new(Vector2i(100, 100))
			FxPuff.draw_mask(g4, st, po, tone, 777 + tone, 22.0, Vector2(50, 50))
			g4.discard()
	for name: String in data.bomb_option_names():
		var o := data.bomb_option(name)
		var fl := FxData.grp(o, "flash")
		for t in FxData.arr(fl, "frames_s"):
			var gg := InkCanvas.new(Vector2i(160, 160))
			FxBurst.draw_burst(gg, st, fl, float(t), 11, 40.0, Vector2(80, 80), true)
			gg.discard()
			n_drawn += 1
		var gc := InkCanvas.new(Vector2i(120, 120))
		FxBomb.draw_crater(gc, st, FxData.grp(o, "crater"), 5, 20.0, Vector2(60, 60))
		gc.discard()
		for m in [false, true]:
			var gk := InkCanvas.new(Vector2i(30, 30))
			FxBomb.draw_clod(gk, st, FxData.grp(o, "debris"), 3, 5.0, Vector2(15, 15), m)
			gk.discard()
			var gb := InkCanvas.new(Vector2i(40, 40))
			FxBomb.draw_bomb(gb, st, FxData.grp(o, "fall"), 9.0, Vector2(20, 20), m)
			gb.discard()
		n_drawn += 5
	var roles := {"cream": "ruin.cream", "rock": "ruin.rock", "roof": "ruin.roof", "wk": 1.5}
	var gs := InkCanvas.new(Vector2i(300, 300))
	FxRuin.draw_standing(gs, st, M, 4.0, Vector2(150, 150), st.palette["side_a"], roles, PI / 2.0)
	gs.discard()
	var gsm := InkCanvas.new(Vector2i(300, 300))
	FxRuin.draw_standing_mask(gsm, st, M, 4.0, Vector2(150, 150), PI / 2.0)
	gsm.discard()
	for name: String in data.ruin_option_names():
		var o := data.ruin_option(name)
		var fl := FxData.grp(o, "flash")
		for t in FxData.arr(fl, "frames_s"):
			var gg := InkCanvas.new(Vector2i(200, 200))
			FxBurst.draw_burst(gg, st, fl, float(t), 11, 50.0, Vector2(100, 100), true)
			gg.discard()
			n_drawn += 1
		var gr := InkCanvas.new(Vector2i(300, 300))
		FxRuin.draw_remains(gr, st, M, FxData.grp(o, "remains"), 4.0, Vector2(150, 150), 9, PI / 2.0)
		gr.discard()
		var gro := InkCanvas.new(Vector2i(300, 300))
		FxRuin.draw_remains(gro, st, M, FxData.grp(o, "remains"), 4.0, Vector2(150, 150), 9, PI / 2.0, false)
		gro.discard()
		var brk := FxRuin.lattice_break(o, M, 9)
		for th in [0.0, 0.5, PI * 0.5]:
			var gl := InkCanvas.new(Vector2i(300, 200))
			FxRuin.draw_lattice(gl, st, M, 4.0, Vector2(40, 100), th, float(brk["roll"]) * th / (PI * 0.5), brk if th >= PI * 0.5 else {}, 9, roles)
			gl.discard()
		var gbar := InkCanvas.new(Vector2i(60, 30))
		FxRuin.draw_bar(gbar, st, 10.0, 4, Vector2(30, 15), false)
		gbar.discard()
		n_drawn += 5
	check(n_drawn > 150, "every strike flash, puff, crater, clod, bomb, ruin and mast can be drawn (%d drawings)" % n_drawn)
	# the standing tower geometry is the sheet's (the unit marker's, to the footing)
	check(M.G["hut"].size() == 4 and M.G["cable"].size() == 2, "the hut and its cable")

# The layer's calls (headless: state only, nothing drawn or baked).
func _check_strike_layer(data: FxData) -> void:
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2.0, 2.0), 0.0, Vector2.ZERO), 20261009)
	layer.true_scale = 2.0
	layer.flak_burst(Vector2(1000, 1000), 400.0, 1.0, true, "a")
	layer.flak_burst(Vector2(1000, 1000), 400.0, 1.2, false, "b")
	layer.bomb_drop("u", 0, Vector2(100, 100), 400.0, 0.0, Vector2(500, 100), 9.0)
	layer.bomb_impact(Vector2(500, 100), 9.0, 45.0, "u", 0)
	layer.ruin("t", Vector2(800, 800), 10.0, "radio_tower", 12.0, 0.0)
	layer.add_crater("u", Vector2(900, 900), 3.0, 45.0, 123)
	layer.add_ruin("t2", Vector2(1200, 1200), 4.0, "radio_tower", 12.0, 0.0, 321)
	layer.set_time(11.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var s := layer.stats()
	eq([s["craters"], s["ruins"], s["drops"]], [2, 2, 1], "the layer holds the strike: %s" % str(s))
	check(int(s["bursts"]) == 4 and int(s["puffs"]) > 60 and int(s["debris"]) > 5, "its flashes, smoke and clods: %s" % str(s))
	eq(int(s["bakes"]), 0, "headless: no art is baked")
	layer.select_strike("F3", "B3", "R3")
	eq([layer.field.flak_name, layer.field.bomb_name, layer.field.ruin_name], ["F3", "B3", "R3"], "select_strike chooses the strike's options")
	layer.select_strike("", "B1", "")
	eq([layer.field.flak_name, layer.field.bomb_name, layer.field.ruin_name], ["F3", "B1", "R3"], "and an empty name keeps the current one")
	layer.clear()
	var c := layer.stats()
	eq([c["puffs"], c["bursts"], c["debris"], c["craters"], c["ruins"], c["drops"]], [0, 0, 0, 0, 0, 0], "clear() empties the strike too")
	remove_child(layer)
	layer.free()

# The boards' records (variants/flak, bomb-impact, tower-ruin): nothing chosen, every frame listed, and the frames themselves when on disk.
func _check_strike_boards() -> void:
	for id: String in ["flak", "bomb-impact", "tower-ruin"]:
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
		var rec: Variant = d.get("recommendation")
		check(rec is Dictionary and (rec as Dictionary).get("_proposed") == true and str((rec as Dictionary).get("option", "")) != "", "%s: the recommendation is labelled proposed" % id)
		eq((d.get("options", []) as Array).size(), 4, "%s: four options" % id)
		for o in d.get("options", []):
			check((o as Dictionary).has("parameters") and (o as Dictionary).has("file"), "%s: option %s carries its parameter set and its sheet" % [id, (o as Dictionary).get("name")])
		var lp := "res://variants/%s/frames.json" % id
		if not check(FileAccess.file_exists(lp), "%s: frames.json exists" % id):
			continue
		var l: Variant = JSON.parse_string(FileAccess.get_file_as_string(lp))
		if not check(l is Dictionary, "%s: frames.json parses" % id):
			continue
		var listed: Array = (l as Dictionary).get("options", [])
		eq(listed.size(), 4, "%s: frames.json lists four options" % id)
		var counted := 0
		var missing_f: Array[String] = []
		var first_rel := ""
		var first_size: Array = []
		for e in listed:
			var rows: Array = (e as Dictionary).get("rows", [])
			check(rows.size() >= 3, "%s %s: at least three rows" % [id, (e as Dictionary).get("option")])
			for r in rows:
				check(str((r as Dictionary).get("title", "")) != "", "every row has a title")
				for fr in (r as Dictionary).get("frames", []):
					counted += 1
					var rel := str((fr as Dictionary).get("file", ""))
					if first_rel == "":
						first_rel = rel
						first_size = (r as Dictionary).get("size_px", [0, 0])
					if not FileAccess.file_exists(ProjectSettings.globalize_path("res://variants/%s/%s" % [id, rel])):
						missing_f.append(rel)
					check(str((fr as Dictionary).get("caption", "")) != "", "every frame has a caption: %s" % rel)
		check(counted >= 60, "%s: frames.json lists %d frames" % [id, counted])
		# The frames are regenerated by scripts/fx/fx_board_strike.gd and kept out of git (variants/*/frames/), so a fresh
		# checkout has none: the files are checked only when present.
		var first_abs := ProjectSettings.globalize_path("res://variants/%s/%s" % [id, first_rel])
		if FileAccess.file_exists(first_abs):
			check(missing_f.is_empty(), "%s: every listed frame exists as its own PNG: %s" % [id, str(missing_f.slice(0, 3))])
			var im := Image.load_from_file(first_abs)
			if check(im != null and not im.is_empty(), "%s: a frame loads" % id):
				eq([im.get_width(), im.get_height()], [int(first_size[0]), int(first_size[1])], "%s: and it is the native size listed" % id)
		else:
			print("test_fx: the %s frames are not on disk (regenerate with fx_board_strike.gd); skipping the frame files" % id)

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
