extends "res://scripts/test_support/test_case.gd"

# THE PORT CHECK for execution-plan component 2 (seeded RNG, noise, hull,
# splines). reference/port_check/expected_seed_20261009.json is what the
# PROTOTYPE'S OWN CODE prints when reference/port_check/prototype_sample.js
# runs it under node; this test recomputes every entry with the GDScript port
# and compares.
#
# RNG, noise and the float64 geometry are compared to TOLERANCE (relative,
# 1e-9); Vector2 geometry to 1e-3 px, since Vector2 stores float32 in a
# standard Godot build (see geometry.gd). Expected values are decoded from the
# fixture's bytes, never its decimals (Godot's float parser is not exact past
# 15 digits), and the bytes are printed on a mismatch for diagnosis.
#
# NOT BIT-EXACT, BY DECISION. Alex, 2026-10-09: bit-exactness with the browser
# is not required; visual parity is. The port happens to match node bit for
# bit today; the tolerance is what lets engine math onto the placement path
# without failing the gate on last-bit noise.
#
# The sample is also PRINTED, so the .log shows the values side by side with
# what node printed when the fixture was made.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
# Not `Noise`: that is a native class (FastNoiseLite's base) and a const may
# not shadow it -- a parse error.
const ValueNoise = preload("res://scripts/core/noise.gd")
const Geometry = preload("res://scripts/core/geometry.gd")

const FIXTURE := "res://reference/port_check/expected_seed_20261009.json"
const GEOMETRY_TOLERANCE := 1e-3
const TOLERANCE := 1e-9

static func bits(x: float) -> String:
	return PackedFloat64Array([x]).to_byte_array().hex_encode()

static func _close(a: float, b: float) -> bool:
	return absf(a - b) <= TOLERANCE * maxf(1.0, maxf(absf(a), absf(b)))

# Inputs come in as bytes as well (xbits/ybits in the fixture): Godot's float
# parser -- literals, to_float and JSON.parse_string alike -- is not correctly
# rounded past 15 significant digits, so a 17-digit input could land one ulp off
# before the port even runs. Decoding the bytes keeps the check about the port.
static func _f64(hex: Variant) -> float:
	return str(hex).hex_decode().decode_double(0)

func exact(actual: float, entry: Dictionary, label: String) -> bool:
	var expected_bits := str(entry["bits"])
	var ok := _close(actual, _f64(expected_bits))
	if not ok:
		fail("%s -- prototype %s (%s), port %s (%s)" % [label, entry["value"], expected_bits, actual, bits(actual)])
	return ok

func near_point(actual: Vector2, expected: Array, label: String) -> bool:
	var ok := near(actual.x, float(expected[0]), GEOMETRY_TOLERANCE, label + ".x")
	return near(actual.y, float(expected[1]), GEOMETRY_TOLERANCE, label + ".y") and ok

static func to_points(rows: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for r in rows:
		out.append(Vector2(float(r[0]), float(r[1])))
	return out

func setup(_main) -> void:
	if not check(FileAccess.file_exists(FIXTURE), "fixture exists: %s (run `node reference/port_check/prototype_sample.js`)" % FIXTURE):
		finish()
		return
	var fx: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	if not check(fx is Dictionary, "fixture parses"):
		finish()
		return
	var seed_value: int = int(fx["seed"])
	eq(seed_value, 20261009, "the fixture is for the project's fixed scene seed")

	# --- mulberry32 ------------------------------------------------------------
	var rng := Mulberry32.new(seed_value)
	var rng_values: Array[float] = []
	for i in (fx["rng"] as Array).size():
		var v := rng.next()
		rng_values.append(v)
		exact(v, fx["rng"][i], "rng[%d]" % i)
	print("rng(%d) first %d: %s" % [seed_value, rng_values.size(), _fmt(rng_values)])

	# --- next_seed: the sub-seed mint every tree, prop, wall and house uses -----
	var mint: Dictionary = fx["next_seed"]
	var mint_rng := Mulberry32.new(int(mint["seed"]))
	var minted: Array[int] = []
	for i in (mint["values"] as Array).size():
		var v := mint_rng.next_seed()
		minted.append(v)
		eq(v, int(mint["values"][i]), "next_seed[%d]" % i)
	print("next_seed(%d) first %d: %s" % [int(mint["seed"]), minted.size(), minted])

	# --- hash2 -----------------------------------------------------------------
	var hash_values: Array[float] = []
	for e in fx["hash2"]:
		var v := ValueNoise.hash2(int(e["i"]), int(e["j"]), int(e["s"]))
		hash_values.append(v)
		exact(v, e, "hash2(%d, %d, %d)" % [int(e["i"]), int(e["j"]), int(e["s"])])
	print("hash2: %s" % _fmt(hash_values))

	# --- vnoise ----------------------------------------------------------------
	var vn_values: Array[float] = []
	for e in fx["vnoise"]:
		var v := ValueNoise.vnoise(_f64(e["xbits"]), _f64(e["ybits"]), int(e["s"]))
		vn_values.append(v)
		exact(v, e, "vnoise(%s, %s, %d)" % [e["x"], e["y"], int(e["s"])])
	print("vnoise: %s" % _fmt(vn_values))

	# --- fbm -------------------------------------------------------------------
	var fbm_values: Array[float] = []
	for e in fx["fbm"]:
		var v := ValueNoise.fbm(_f64(e["xbits"]), _f64(e["ybits"]), int(e["s"]), int(e["o"]))
		fbm_values.append(v)
		exact(v, e, "fbm(%s, %s, %d, %d)" % [e["x"], e["y"], int(e["s"]), int(e["o"])])
	print("fbm: %s" % _fmt(fbm_values))

	# --- the scene generator's chain: rng -> position -> density field ----------
	# The shape of newScene()'s tree loop: x = rng()*W, y = rng()*H,
	# f = fbm(x*.006, y*.006, seed%9973+3, 3), from a fresh stream. (The real
	# newScene draws the fort, house and props first and takes an extra rng()
	# per candidate when f >= .5; this is the end-to-end check that the stream
	# and the noise agree when consumed together, not a replay of the scene.)
	var scene: Dictionary = fx["scene_sample"]
	var srng := Mulberry32.new(seed_value)
	var w: float = float(scene["w"])
	var h: float = float(scene["h"])
	var s: int = seed_value % 9973 + 3
	eq(s, int(scene["s"]), "density-field seed is seed % 9973 + 3")
	var scene_lines: Array[String] = []
	for i in (scene["draws"] as Array).size():
		var e: Dictionary = scene["draws"][i]
		var x := srng.next() * w
		var y := srng.next() * h
		var f := ValueNoise.fbm(x * 0.006, y * 0.006, s, 3)
		exact(x, e["x"], "scene draw %d x" % i)
		exact(y, e["y"], "scene draw %d y" % i)
		exact(f, e["f"], "scene draw %d density" % i)
		scene_lines.append("(%.3f, %.3f) f=%.6f" % [x, y, f])
	print("scene draws: ", ", ".join(scene_lines))

	# --- hull (geometry: tolerance) -------------------------------------------
	var hull_fx: Dictionary = fx["hull"]
	var hull_out := Geometry.hull(to_points(hull_fx["points"]))
	if eq(hull_out.size(), (hull_fx["hull"] as Array).size(), "hull vertex count"):
		for i in hull_out.size():
			near_point(hull_out[i], hull_fx["hull"][i], "hull[%d]" % i)
	print("hull: %d of %d points, first %s" % [hull_out.size(), (hull_fx["points"] as Array).size(), hull_out[0] if hull_out.size() > 0 else "-"])

	# --- catmull-rom (the road) -----------------------------------------------
	var road_fx: Dictionary = fx["catmull_rom"]
	var road := Geometry.catmull_rom(to_points(road_fx["control"]), float(road_fx["spacing"]))
	if eq(road.size(), int(road_fx["count"]), "road sample count"):
		for e in road_fx["samples"]:
			var i: int = int(e["i"])
			near_point(road[i], [e["x"], e["y"]], "road[%d]" % i)
	print("road: %d samples, first %s, last %s" % [road.size(), road[0], road[road.size() - 1]])

	# --- catmull-rom in float64: BIT FOR BIT --------------------------------------
	# The scene generator places against the road (roadDist, the house), so its
	# float64 variant must match the prototype exactly, not to a tolerance. The
	# control points come in as bytes, like every other exact input.
	var road64 := Geometry.catmull_rom_f64(_pairs(road_fx["control_bits"]), float(road_fx["spacing"]))
	if eq(road64.size() / 2, int(road_fx["count"]), "road (f64) sample count"):
		for e in road_fx["samples"]:
			var i: int = int(e["i"])
			exact_bits(road64[i * 2], e["xbits"], "road64[%d].x" % i)
			exact_bits(road64[i * 2 + 1], e["ybits"], "road64[%d].y" % i)
	print("road (f64): %d samples, first (%s, %s), last (%s, %s)" % [road64.size() / 2,
		_fmt([road64[0]]), _fmt([road64[1]]), _fmt([road64[road64.size() - 2]]), _fmt([road64[road64.size() - 1]])])

	# --- chaikin + resample (a freehand wall), open and closed ----------------
	var wall_fx: Dictionary = fx["wall"]
	var src := to_points(wall_fx["src"])
	for mode in ["open", "closed"]:
		var closed: bool = mode == "closed"
		var pts := Geometry.resample(Geometry.chaikin(Geometry.chaikin(Geometry.resample(src, 6.0, closed), closed), closed), 3.0, closed)
		var want: Dictionary = wall_fx[mode]
		if eq(pts.size(), int(want["count"]), "%s wall point count" % mode):
			for e in want["samples"]:
				var i: int = int(e["i"])
				near_point(pts[i], [e["x"], e["y"]], "%s wall[%d]" % [mode, i])
		print("%s wall: %d points, first %s, last %s" % [mode, pts.size(), pts[0], pts[pts.size() - 1]])

	# --- chaikin + resample in float64: BIT FOR BIT --------------------------------
	# Freehand walls (structures.gd, gen.type "free") go through these, and their
	# points feed sDist, a placement decision. resample measures with
	# JsMath.hypot, V8's; with sqrt(x*x + y*y) this check fails.
	var src64 := _pairs(wall_fx["src_bits"])
	for mode in ["open", "closed"]:
		var closed: bool = mode == "closed"
		var pts64 := Geometry.resample_f64(Geometry.chaikin_f64(Geometry.chaikin_f64(Geometry.resample_f64(src64, 6.0, closed), closed), closed), 3.0, closed)
		var want: Dictionary = wall_fx[mode]
		if eq(pts64.size() / 2, int(want["count"]), "%s wall (f64) point count" % mode):
			for e in want["samples"]:
				var i: int = int(e["i"])
				exact_bits(pts64[i * 2], e["xbits"], "%s wall64[%d].x" % [mode, i])
				exact_bits(pts64[i * 2 + 1], e["ybits"], "%s wall64[%d].y" % [mode, i])
		print("%s wall (f64): %d points, first (%s, %s), last (%s, %s)" % [mode, pts64.size() / 2,
			_fmt([pts64[0]]), _fmt([pts64[1]]), _fmt([pts64[pts64.size() - 2]]), _fmt([pts64[pts64.size() - 1]])])

	finish()

# Points given as 32 hex digits each (x then y) to a flat PackedFloat64Array.
static func _pairs(rows: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for r in rows:
		var b: PackedByteArray = str(r).hex_decode()
		out.append(b.decode_double(0))
		out.append(b.decode_double(8))
	return out

func exact_bits(actual: float, expected_bits: Variant, label: String) -> bool:
	var want := str(expected_bits)
	var ok := _close(actual, _f64(want))
	if not ok:
		fail("%s -- prototype %s (%s), port %s (%s)" % [label, String.num(_f64(want), 17), want, String.num(actual, 17), bits(actual)])
	return ok

# 17 significant digits, trailing zeros dropped -- what prototype_sample.js
# prints with toPrecision(17), so the two logs read digit for digit. Godot's `%`
# has no %g (it prints the format string back and logs an error), so the
# decimals are counted from the value's power of ten and String.num, which
# strips trailing zeros itself, does the rest.
static func _fmt(values: Array[float]) -> String:
	var parts: Array[String] = []
	for v in values:
		var e := 0
		if v != 0.0:
			e = floori(log(absf(v)) / log(10.0))
			if absf(v) >= pow(10.0, e + 1):
				e += 1
			elif absf(v) < pow(10.0, e):
				e -= 1
		parts.append(String.num(v, maxi(0, 16 - e)))
	return ", ".join(parts)
