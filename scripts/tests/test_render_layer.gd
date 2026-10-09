extends "res://scripts/test_support/test_case.gd"

# THE DRAWING PORT'S HEADLESS CHECKS (scripts/render/): everything about the
# port of the prototype's draw routines that can be decided without pixels on
# a screen. Pixels themselves need a windowed run (render.ps1 -Scene) and are
# judged against a browser capture by eye; this is what keeps them honest
# between those looks.
#
#   1. RNG DRAW COUNTS. Every sprite builder -- buildTreeSprite, buildPropSprite,
#      drawWall, drawHouse, drawRoad, buildGround's specks and dirt -- takes
#      exactly as many rng() draws from its own mulberry32(seed) as the
#      prototype's own code does for the same object. The expected counts come
#      from the prototype's functions run under node against a stand-in canvas
#      (reference/port_check/prototype_render_sample.js ->
#      expected_render_20261009.json); the objects are built from fixed seeds
#      by scripts/world/ here and by the prototype's makers there. One draw
#      too many or too few and every later lobe, ring break, stipple dot and
#      pebble of that object lands somewhere else -- this is what keeps the
#      stream aligned. Drawing happens on real InkCanvases, which accept every
#      call headless (the dummy renderer just never produces an image); each
#      is discarded unrendered.
#   2. SCALLOP GEOMETRY: one scallop() contour, inputs drawn from
#      mulberry32(20261009) as drawLobe draws them, against the prototype's
#      points to 1e-3 px (engine sin / cos / pow; bit-exactness is not
#      required, Alex 2026-10-09) and its segment indices exactly (they steer
#      which ring segments are drawn, i.e. the stream).
#   3. THE PAPER, GDScript path: Paper.build_image with the ground's pixel
#      function on a 48x30 stage, against the prototype's 1/3-res tint as its
#      Uint8ClampedArray stored it.
#   4. GRAIN DETERMINISM: same seed, same bytes; another seed, other bytes.
#   5. THE PARITY SWITCH: apply_prototype_defaults puts every parameter that
#      carries a prototype_default back to it (the game frame uses the data
#      default; a parity frame the prototype's), the pen included.
#   6. THE PEN (linework.pen, Alex's "shadow side"): on a circle, either
#      winding, the width factor is shadow_factor where the outline faces
#      away from the sun and lit_factor where it faces it; an open line's ends
#      taper to end_floor of its middle; an INK stroke is drawn as a ribbon
#      and a black (mask) stroke is not; "even" leaves every stroke even.
#   7. FAST NOISE: scripts/render/fast_noise.gd gives exactly core/noise.gd's
#      values (the drawing layer uses it for speed; the RNG draw counts above
#      depend on it being exact).

const RenderParams = preload("res://scripts/world/render_params.gd")
const SceneGen = preload("res://scripts/world/scene_gen.gd")
const Structures = preload("res://scripts/world/structures.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const InkStructs = preload("res://scripts/render/ink_structs.gd")
const InkGround = preload("res://scripts/render/ink_ground.gd")
const InkRenderer = preload("res://scripts/render/ink_renderer.gd")
const Paper = preload("res://scripts/render/paper.gd")
const Grain = preload("res://scripts/render/grain.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const FastNoise = preload("res://scripts/render/fast_noise.gd")

const FIXTURE := "res://reference/port_check/expected_render_20261009.json"
const SEED := 20261009
# How far to look for the probe value when counting draws (the road takes ~13k).
const MAX_DRAWS := 200000

var P: RenderParams

func setup(_main) -> void:
	timeout_seconds = 120.0
	P = RenderParams.new()
	if not check(P.ok(), "render params load: %s" % ", ".join(P.errors)):
		finish()
		return
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE)) if FileAccess.file_exists(FIXTURE) else null
	if not check(raw is Dictionary, "fixture %s exists and parses" % FIXTURE):
		finish()
		return
	var fx: Dictionary = raw
	var t0 := Time.get_ticks_usec()
	_check_draw_counts(fx)
	_check_scallop(fx.get("scallop", {}))
	_check_paper(fx.get("paper", {}))
	_check_grain()
	_check_parity_switch()
	_check_pen()
	_check_fast_noise()
	print("test_render_layer: checks ran in %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()

# --- 1. draw counts -----------------------------------------------------------------

# How many draws `rng` (made as mulberry32(seed)) has given: its next value is
# found in a fresh stream of the same seed. A 32-bit value repeating within
# the first 200k draws by chance is a ~5e-5 event; the counts are small ints.
static func draws_taken(seed_value: int, rng: Mulberry32) -> int:
	var probe := rng.next()
	var fresh := Mulberry32.new(seed_value)
	for k in MAX_DRAWS:
		if fresh.next() == probe:
			return k
	return -1

func _check_draw_counts(fx: Dictionary) -> void:
	var gen := SceneGen.new(1280.0, 720.0, P)  # makers + road at the default stage
	var summary: Array[String] = []

	# Trees: makeTree(mulberry32(maker_seed), 100, 100) then syncTree -> buildTreeSprite.
	for e: Dictionary in fx.get("trees", []):
		var t := gen.make_tree(Mulberry32.new(int(e.maker_seed)), 100.0, 100.0)
		gen.sync_tree(t)
		if not eq(t.seed, int(e.seed), "tree maker %d mints the prototype's seed" % int(e.maker_seed)):
			continue
		var rng := Mulberry32.new(t.seed)
		InkSprites.build_tree_sprite(t, P, rng).discard()
		eq(draws_taken(t.seed, rng), int(e.draws), "buildTreeSprite draws for tree seed %d (r %.2f, big %s)" % [t.seed, t.r, t.big])
		eq(int(t.half), ceili(t.r * 1.3 + 4.0), "tree half")
	summary.append("%d trees" % fx.get("trees", []).size())

	# Props: each type twice.
	for e: Dictionary in fx.get("props", []):
		var p := gen.make_prop(Mulberry32.new(int(e.maker_seed)), 200.0, 200.0)
		if not eq(p.type, str(e.type), "prop maker %d makes the prototype's type" % int(e.maker_seed)):
			continue
		var rng := Mulberry32.new(p.seed)
		InkSprites.build_prop_sprite(p, P, rng).discard()
		eq(draws_taken(p.seed, rng), int(e.draws), "buildPropSprite draws for a %s, seed %d" % [p.type, p.seed])
	summary.append("%d props" % fx.get("props", []).size())

	# Walls: makeFort(mulberry32(5), 640, 300, 340, -.3) -- ring, divider, inner ring.
	var walls := Structures.make_fort(Mulberry32.new(5), 640.0, 300.0, 340.0, -0.3, P)
	var fw: Array = fx.get("walls", [])
	if eq(walls.size(), fw.size(), "the fixed fort has the prototype's wall count"):
		for i in walls.size():
			var w: Dictionary = walls[i]
			Structures.sync_struct(w, P)
			var e: Dictionary = fw[i]
			if not (eq(w.seed, int(e.seed), "wall %d seed" % i) and eq(w.pts.size(), int(e.n), "wall %d centre-line samples" % i)):
				continue
			var rng := Mulberry32.new(w.seed)
			InkStructs.build_struct_sprite(w, P, rng).discard()
			eq(draws_taken(w.seed, rng), int(e.draws), "drawWall draws for the %s wall, seed %d" % [w.gen.type, w.seed])
	summary.append("%d walls" % fw.size())

	# Houses: with and without a wing, with and without a chimney.
	for e: Dictionary in fx.get("houses", []):
		var h := Structures.make_house(Mulberry32.new(int(e.maker_seed)), 500.0, 400.0, 0.4)
		Structures.sync_struct(h, P)
		if not (eq(h.seed, int(e.seed), "house maker %d seed" % int(e.maker_seed))
				and eq(h.parts.size(), int(e.parts), "house maker %d parts" % int(e.maker_seed))):
			continue
		var rng := Mulberry32.new(h.seed)
		InkStructs.build_struct_sprite(h, P, rng).discard()
		eq(draws_taken(h.seed, rng), int(e.draws), "drawHouse draws for house seed %d (%d parts, chimney %s)" % [h.seed, h.parts.size(), h.chimney])
	summary.append("%d houses" % fx.get("houses", []).size())

	# The road at 1280x720: drawRoad's mulberry32(77).
	var road: Dictionary = fx.get("road", {})
	if eq(gen.roadPts.size(), int(road.get("road_samples", -1)), "road samples at 1280x720"):
		var rng := Mulberry32.new(77)
		var g := InkCanvas.new(Vector2i(1280, 720), 1)
		InkGround.draw_road(g, gen.roadPts, P, rng)
		g.discard()
		eq(draws_taken(77, rng), _stream_draws(road, 77), "drawRoad draws at 1280x720")

	# The ground on a small stage: specks and dirt from mulberry32(4242), then
	# drawRoad from mulberry32(77) over that stage's road.
	var gd: Dictionary = fx.get("ground", {})
	var gw := float(gd.get("W", 0))
	var gh := float(gd.get("H", 0))
	var small := SceneGen.new(gw, gh, P)
	if eq(small.roadPts.size(), int(gd.get("road_samples", -1)), "road samples at %dx%d" % [int(gw), int(gh)]):
		var rng := Mulberry32.new(4242)
		var road_rng := Mulberry32.new(77)
		var g := InkCanvas.new(Vector2i(int(gw), int(gh)), 1)
		InkGround.draw_ground(g, gw, gh, small.roadPts, P, null, rng, road_rng)
		g.discard()
		eq(draws_taken(4242, rng), _stream_draws(gd, 4242), "buildGround specks + dirt draws at %dx%d" % [int(gw), int(gh)])
		eq(draws_taken(77, road_rng), _stream_draws(gd, 77), "buildGround's drawRoad draws at %dx%d" % [int(gw), int(gh)])
	print("draw counts checked: ", ", ".join(summary), ", the road, the ground")

static func _stream_draws(entry: Dictionary, seed_value: int) -> int:
	for s: Dictionary in entry.get("streams", []):
		if int(s.seed) == seed_value:
			return int(s.draws)
	return -2

# --- 2. scallop ------------------------------------------------------------------------

func _check_scallop(sc: Dictionary) -> void:
	if not check(sc.has("points"), "fixture has a scallop sample"):
		return
	# const rng=mulberry32(SEED), n=Math.max(5,Math.round(4.5+R/3)), ph=rng()*Math.PI,
	#   ns=(rng()*1e6)|0, amps=Array.from({length:n},()=>.13+rng()*.12);
	var R: float = sc.R
	var n := maxi(5, roundi(4.5 + R / 3.0))
	eq(n, int(sc.n), "scallop lobe count")
	var rng := Mulberry32.new(SEED)
	var ph := rng.next() * PI
	var ns := int(rng.next() * 1e6)
	var amps := PackedFloat64Array()
	for _i in n:
		amps.push_back(0.13 + rng.next() * 0.12)
	near(ph, float(sc.ph), 1e-12, "scallop phase")
	eq(ns, int(sc.ns), "scallop noise seed")
	near(P.wob, float(sc.wob), 0.0, "P.wob is the prototype's")
	var out: Array = InkSprites.scallop(float(sc.x), float(sc.y), R, n, ph, amps, P.wob, ns)
	var pts: PackedVector2Array = out[0]
	var idx: PackedInt32Array = out[1]
	var want: Array = sc.points
	if not eq(pts.size(), want.size(), "scallop point count (n*9+1)"):
		return
	var worst := 0.0
	var idx_bad := 0
	for i in pts.size():
		var w: Array = want[i]
		worst = maxf(worst, pts[i].distance_to(Vector2(w[0], w[1])))
		if idx[i] != int(w[2]):
			idx_bad += 1
	check(worst <= 1e-3, "scallop points within 1e-3 px of the prototype's (worst %s)" % String.num_scientific(worst))
	eq(idx_bad, 0, "scallop segment indices equal the prototype's")
	print("scallop: %d points, worst %s px" % [pts.size(), String.num_scientific(worst)])

# --- 3. paper --------------------------------------------------------------------------

func _check_paper(pp: Dictionary) -> void:
	if not check(pp.has("rgb"), "fixture has a paper sample"):
		return
	var size := Vector2i(int(pp.W), int(pp.H))
	var S := int(pp.S)
	eq(S, InkGround.PAPER_SCALE, "paper scale is the prototype's S")
	var small := Paper.small_size(size, S)
	eq(small, Vector2i(int(pp.lw), int(pp.lh)), "paper small-image size (ceil(W/S)+1, ceil(H/S)+1)")
	var img := Paper.build_image(size, S, InkGround.paper_pixel(P))
	if not eq(img.get_size(), size, "paper image is the stage size"):
		return
	# Small pixel (x, y) lands, upscaled, centred on frame pixel (x*S + 1, y*S + 1)
	# at S = 3 (paper.gd: the prototype's half-cell shift), where bilinear is exact.
	var rgb: Array = pp.rgb
	var compared := 0
	var worst := 0
	for y in small.y:
		for x in small.x:
			var fxp := x * S + 1
			var fyp := y * S + 1
			if fxp >= size.x or fyp >= size.y:
				continue
			var c := img.get_pixel(fxp, fyp)
			var w: Array = rgb[y * small.x + x]
			worst = maxi(worst, maxi(absi(c.r8 - int(w[0])), maxi(absi(c.g8 - int(w[1])), absi(c.b8 - int(w[2])))))
			compared += 1
	check(compared > 100, "paper: enough samples compared (%d)" % compared)
	eq(worst, 0, "paper tint equals the prototype's Uint8ClampedArray values (%d samples)" % compared)
	print("paper: %d samples, worst %d levels" % [compared, worst])

# --- 4. grain --------------------------------------------------------------------------

func _check_grain() -> void:
	var size := Vector2i(64, 40)
	var a := Grain.build_image(size, SEED).get_data()
	var b := Grain.build_image(size, SEED).get_data()
	var c := Grain.build_image(size, SEED + 1).get_data()
	eq(a.size(), size.x * size.y * 4, "grain is RGBA8 at the stage size")
	check(a == b, "grain: same seed, same bytes")
	check(a != c, "grain: another seed, other bytes")
	# v=255-rng()*24 (or a 150..210 fleck); g = v-2, b = v-6, opaque.
	var bad := 0
	for i in range(0, a.size(), 4):
		var v := int(a[i])
		if v < 150 or int(a[i + 1]) - v < -3 or int(a[i + 1]) - v > -1 or int(a[i + 2]) - v < -7 or int(a[i + 2]) - v > -5 or a[i + 3] != 255:
			bad += 1
	eq(bad, 0, "grain pixels are warm near-white (or a fleck), opaque")

# --- 5. parity switch ------------------------------------------------------------------

func _check_parity_switch() -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(P.source_path))
	var prm: Dictionary = (raw as Dictionary).get("parameters", {}) if raw is Dictionary else {}
	var entry: Dictionary = prm.get("shadow_strength", {})
	var q := RenderParams.new()
	near(q.shadowStr, float(entry.get("default", NAN)), 0.0, "the game frame uses shadow_strength's data default")
	var lines := InkRenderer.apply_prototype_defaults(q)
	if entry.has("prototype_default"):
		near(q.shadowStr, float(entry.prototype_default), 0.0, "a parity frame uses shadow_strength's prototype_default")
		check(lines.size() >= 1, "apply_prototype_defaults reports what it changed")
	else:
		near(q.shadowStr, float(entry.get("default", NAN)), 0.0, "no prototype_default: a parity frame keeps the default")

# --- 6. the pen ------------------------------------------------------------------------

func _check_pen() -> void:
	var cfg: Dictionary = InkCanvas.pen_config().duplicate()
	check(cfg.has("lit") and cfg.has("shadow") and cfg.has("open") and cfg.has("floor"), "pen config read from linework.pen")
	cfg["mode"] = "shadow_side"
	var sd := Vector2(1.0, 1.0).normalized()
	cfg["shadow_dir"] = sd
	for winding: float in [1.0, -1.0]:
		var pts := PackedVector2Array()
		for i in 72:
			var a := winding * float(i) * TAU / 72.0
			pts.push_back(Vector2(cos(a), sin(a)) * 20.0)
		var f := InkCanvas.pen_factors(pts, true, cfg)
		var away := 0
		var toward := 0
		for i in pts.size():
			if pts[i].normalized().dot(sd) > pts[away].normalized().dot(sd):
				away = i
			if pts[i].normalized().dot(sd) < pts[toward].normalized().dot(sd):
				toward = i
		check(f[away] > f[toward], "pen: a circle (winding %+d) is heavier on its shadow side (%.3f) than its lit side (%.3f)" % [winding, f[away], f[toward]])
		near(f[away], float(cfg.shadow), 0.01, "pen: the shadow-side factor is shadow_factor")
		near(f[toward], float(cfg.lit), 1e-6, "pen: the lit-side factor is lit_factor")
	var line := PackedVector2Array()
	for i in 41:
		line.push_back(Vector2(float(i), 0.0))
	var g := InkCanvas.pen_factors(line, false, cfg)
	check(g[0] < g[20] and g[40] < g[20], "pen: an open line's ends (%.3f, %.3f) are thinner than its middle (%.3f)" % [g[0], g[40], g[20]])
	near(g[20], float(cfg.open), 1e-9, "pen: an open line's middle is open_line_factor")
	near(g[0], float(cfg.open) * float(cfg.floor), 1e-9, "pen: an open line's end is end_floor of it")
	# The stroke routine applies it to ink and only to ink, with no opt-in.
	var was := InkCanvas.pen_mode()
	InkCanvas.set_pen_mode("shadow_side")
	var ink: Color = InkCanvas.pen_config().ink
	var c := InkCanvas.new(Vector2i(64, 64), 1)
	c.stroke_color = ink
	c.global_alpha = 0.6
	c.begin_path()
	for p in line:
		c.line_to(p.x + 10.0, 20.0 + p.y)
	c.stroke()
	check(_last_ribbon(c), "pen: an ink stroke is drawn as a ribbon")
	c.stroke_color = Color.BLACK
	c.stroke()
	check(not _last_ribbon(c), "pen: a black (shadow mask) stroke is not")
	InkCanvas.set_pen_mode("even")
	c.stroke_color = ink
	c.stroke()
	check(not _last_ribbon(c), "pen: mode even leaves ink strokes even")
	c.discard()
	InkCanvas.set_pen_mode(was)

static func _last_ribbon(c: InkCanvas) -> bool:
	c._flush_batch()
	var op: Array = c._ops[c._ops.size() - 1]
	return op[0] == InkCanvas._OP_TRIS and bool(op[4])

# --- 7. fast noise --------------------------------------------------------------------------

func _check_fast_noise() -> void:
	var rng := Mulberry32.new(SEED + 3)
	var bad := 0
	for _i in 3000:
		var x := (rng.next() - 0.5) * 2e5
		var y := (rng.next() - 0.5) * 2e5
		var sd := int((rng.next() - 0.5) * 4.2e9)
		if FastNoise.vnoise(x, y, sd) != ValueNoise.vnoise(x, y, sd):
			bad += 1
		if FastNoise.fbm(x * 0.01, y * 0.01, sd, 4) != ValueNoise.fbm(x * 0.01, y * 0.01, sd, 4):
			bad += 1
		var i := int((rng.next() - 0.5) * 4.2e9)
		if FastNoise.hash2(i, -i, sd) != ValueNoise.hash2(i, -i, sd):
			bad += 1
	eq(bad, 0, "fast_noise.gd equals core/noise.gd bit for bit (9000 samples, negative and huge inputs)")
