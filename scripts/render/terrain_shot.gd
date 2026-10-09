extends SceneTree

# A look at the terrain without touching main.gd (Track T). WINDOWED ONLY --
# under --headless the renderer is a dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"     # autoloads load under --script; keep Steam out of it
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/terrain_shot.gd -- 20261009 tmp/terrain/terrain_20261009.png
#
# Writes two 1280x720 framings onto the same spot of the map: <png> at zoom 1,
# centred on a lee-facing scarp near the map centre (the upland's shadow falls
# toward the viewer's lower right), and <png stem>_wide.png at a wider zoom.
# Optional key=value arguments after the two: x=<m> y=<m> (the spot, metres),
# zoom=<wide zoom>, style=hachures|contours (a preview override of
# draw.style; the data switch is the real one), masks=1 (also dump the level
# masks and one shadow mask).
#
# Frame, bottom to top (terrain_draw.gd / terrain_shadows.gd give the order):
# paper ground (Track R's ink_ground.gd: tint, specks, fibres, dirt; plain
# paper if it does not load), the level fill, contours and hachures, terrain
# shadows per receiver level, tree shadows per receiver level, the trees
# (Track R's buildTreeSprite port, ink_sprites.gd; a one-scallop stand-in if it
# does not load), grain. No props, walls or houses: terrain only.

const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const Grain = preload("res://scripts/render/grain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const SIZE := Vector2i(1280, 720)
const WIDE_ZOOM := 0.35
const SPRITE_BATCH := 256

var _sprites_script: Script = null
var _ground_script: Script = null
var _sprite_cache: Dictionary = {}   # tree seed -> [texture, half]

func _initialize() -> void:
	var code := _run()
	quit(code)

func _run() -> int:
	if DisplayServer.get_name() == "headless":
		printerr("[terrain-shot] needs a windowed run: under --headless nothing is drawn")
		return 1
	var args := OS.get_cmdline_user_args()
	var seed_value := int(args[0]) if args.size() > 0 else 20261009
	var out := args[1] if args.size() > 1 else "tmp/terrain/terrain_%d.png" % seed_value
	var opts: Dictionary = {}
	for i in range(2, args.size()):
		var kv := args[i].split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	if out.is_relative_path():
		out = ProjectSettings.globalize_path("res://").path_join(out)
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())

	_sprites_script = _try_load("res://scripts/render/ink_sprites.gd", "build_tree_sprite")
	_ground_script = _try_load("res://scripts/render/ink_ground.gd", "build_ground")
	print("[terrain-shot] tree sprites: %s; ground: %s" % [
		"ink_sprites.gd build_tree_sprite (Track R's buildTreeSprite port)" if _sprites_script else "STAND-IN one-scallop canopy (ink_sprites.gd did not load)",
		"ink_ground.gd build_ground (paper tint shader, specks, fibres, dirt)" if _ground_script else "STAND-IN flat paper (ink_ground.gd did not load)"])

	var P := RenderParams.new()
	P.L["road"] = false
	var t0 := Time.get_ticks_usec()
	var terrain := Terrain.new(seed_value)
	if not terrain.ok():
		printerr("[terrain-shot] terrain data errors: ", terrain.errors, terrain.data.errors)
		return 1
	var td := TerrainDraw.new(terrain, P)
	if opts.has("style"):
		td.style = opts["style"]
	var ts := TerrainShadows.new(terrain, P)
	print("[terrain-shot] map %s x %s m from %s, %s px/m; level paper %s" % [terrain.map_w, terrain.map_h,
		terrain.bounds_source, terrain.px_per_m, td.level_paper.map(func(c: Color) -> String: return "#" + c.to_html(false))])

	var focus: Vector2
	if opts.has("x") and opts.has("y"):
		focus = Vector2(float(opts["x"]), float(opts["y"])) * terrain.px_per_m
	else:
		focus = _find_scarp(terrain, ts.dir)
	print("[terrain-shot] focus (m) ", focus / terrain.px_per_m, "  setup %.0f ms" % _ms(t0))

	var wide := float(opts.get("zoom", WIDE_ZOOM))
	var shots := [[out, 1.0], [out.get_basename() + "_wide.png", wide]]
	for s: Array in shots:
		var img := _render(terrain, td, ts, P, focus, s[1], seed_value, opts.get("masks", "") == "1", s[0])
		var err := img.save_png(s[0])
		if err != OK:
			printerr("[terrain-shot] could not write ", s[0], ": ", error_string(err))
			return 1
		print("[terrain-shot] saved ", s[0])
	return 0

func _render(terrain: Terrain, td: TerrainDraw, ts: TerrainShadows, P: RenderParams, focus: Vector2,
		zoom: float, seed_value: int, dump: bool, out: String) -> Image:
	var t_all := Time.get_ticks_usec()
	var origin := focus - Vector2(SIZE) * 0.5 / zoom
	var view := Transform2D(Vector2(zoom, 0.0), Vector2(0.0, zoom), -origin * zoom)
	var rect := TerrainDraw.view_rect(view, SIZE)

	var t0 := Time.get_ticks_usec()
	var trees := terrain.trees_in_rect_px(rect.grow(ts.reach_px()))
	var t_gen := _ms(t0)
	var counts := [0, 0, 0]
	for t: Dictionary in trees:
		counts[t.level] += 1

	t0 = Time.get_ticks_usec()
	var built := _sync_sprites(trees, P)
	var t_sprites := _ms(t0)

	t0 = Time.get_ticks_usec()
	var ground: Texture2D = null
	if _ground_script != null:
		ground = _ground_script.call("build_ground", SIZE, [], P, true)
	var t_ground := _ms(t0)

	t0 = Time.get_ticks_usec()
	var masks := td.level_masks(view, SIZE)
	var t_masks := _ms(t0)

	t0 = Time.get_ticks_usec()
	var g := InkCanvas.new(SIZE)
	if ground != null:
		g.draw_image(ground, 0.0, 0.0, float(SIZE.x), float(SIZE.y))
	else:
		g.fill_color = P.PAPER
		g.fill_rect(0.0, 0.0, float(SIZE.x), float(SIZE.y))
	td.draw_level_fill(g, masks)
	td.draw_linework(g, view, rect)
	var t_line := _ms(t0)

	t0 = Time.get_ticks_usec()
	var sp := ShadowPass.new(SIZE)
	var shade := ts.cast_terrain(g, sp, masks, view, rect)
	var prisms := ts.last_count
	var by_height := trees.duplicate()
	by_height.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ha: float = a.base + a.h
		var hb: float = b.base + b.h
		return ha < hb or (ha == hb and a.y < b.y))
	ts.cast_trees(g, sp, masks, by_height, view, shade)
	var casts := ts.last_count
	var t_shadow := _ms(t0)
	if dump:
		_dump_masks(masks, ts, terrain, view, rect, by_height, out)

	t0 = Time.get_ticks_usec()
	g.save()
	g.set_transform_matrix(view)
	var drawn := 0
	for t: Dictionary in by_height:
		var s: float = t.half * 2.0
		if not rect.grow(t.half).has_point(Vector2(t.x, t.y)):
			continue
		g.draw_image(t.sprite, t.x - t.half, t.y - t.half, s, s)
		drawn += 1
	g.restore()
	Grain.apply(g, Grain.build_texture(SIZE, seed_value), P.grain)
	var img := g.finish_image()
	var t_frame := _ms(t0)
	sp.canvas.discard()
	print("[terrain-shot] zoom %.2f: view %.0f x %.0f px (%.0f x %.0f m); %d trees in reach (levels %s), %d drawn; %d scarp prisms, %d tree shadow casts" % [
		zoom, rect.size.x, rect.size.y, rect.size.x / terrain.px_per_m, rect.size.y / terrain.px_per_m,
		trees.size(), counts, drawn, prisms, casts])
	print("[terrain-shot] timings ms: generate %.0f, sprites %.0f (%d built), ground %.0f, masks %.0f, fill+linework %.0f, shadows %.0f, trees+grain+readback %.0f; total %.0f" % [
		t_gen, t_sprites, built, t_ground, t_masks, t_line, t_shadow, t_frame, _ms(t_all)])
	return img

# Sprites for every tree, cached by seed across framings; rendered in batches.
func _sync_sprites(trees: Array, P: RenderParams) -> int:
	var owners: Array = []
	var canvases: Array = []
	for t: Dictionary in trees:
		var hit: Variant = _sprite_cache.get(t.seed)
		if hit != null:
			t.sprite = hit[0]
			t.half = hit[1]
			continue
		var c: InkCanvas
		if _sprites_script != null:
			c = _sprites_script.call("build_tree_sprite", t, P)
		else:
			c = _standin_sprite(t, P)
		owners.append(t)
		canvases.append(c)
	for b in range(0, canvases.size(), SPRITE_BATCH):
		var imgs := InkCanvas.render_all(canvases.slice(b, b + SPRITE_BATCH))
		for k in imgs.size():
			var t: Dictionary = owners[b + k]
			t.sprite = ImageTexture.create_from_image(imgs[k])
			_sprite_cache[t.seed] = [t.sprite, t.half]
	return canvases.size()

# STAND-IN canopy when ink_sprites.gd is unavailable: one scalloped outline.
static func _standin_sprite(t: Dictionary, P: RenderParams) -> InkCanvas:
	var r: float = t.r
	var half := ceili(r * 1.3 + 4.0)
	t.half = half
	var g := InkCanvas.new(Vector2i(half * 2, half * 2))
	g.set_transform(1, 0, 0, 1, half, half)
	var rng := Mulberry32.new(t.seed)
	var n := maxi(5, roundi(4.5 + r / 3.0))
	var ph := rng.next() * PI
	g.begin_path()
	var steps := n * 9
	for i in steps + 1:
		var th := float(i) / steps * TAU
		var rr := r * (1.0 - 0.2 + 0.2 * pow(absf(sin(n * th / 2.0 + ph)), 0.55))
		if i == 0:
			g.move_to(cos(th) * rr, sin(th) * rr)
		else:
			g.line_to(cos(th) * rr, sin(th) * rr)
	g.close_path()
	g.fill_color = P.CREAM
	g.fill()
	g.stroke_color = P.INK
	g.line_width = P.lw * float(P.linework.get("tree_outline", 1.0))
	g.stroke()
	return g

# A spot on a long lee-facing scarp (its low side faces away from the sun)
# near the middle of the map: the middle of the longest such run.
static func _find_scarp(terrain: Terrain, dir: Vector2) -> Vector2:
	var centre := Vector2(terrain.map_x + terrain.map_w * 0.5, terrain.map_y + terrain.map_h * 0.5) * terrain.px_per_m
	var cc := terrain.chunk_of(centre.x / terrain.px_per_m, centre.y / terrain.px_per_m)
	var best := centre
	var best_score := -INF
	for cy in range(cc.y - 4, cc.y + 5):
		for cx in range(cc.x - 4, cc.x + 5):
			if not terrain.chunk_in_map(cx, cy):
				continue
			for ch: Dictionary in terrain.chains_px(cx, cy, 0):
				var pts: PackedVector2Array = ch.pts
				var run := 0.0
				var run_start := 0
				for i in pts.size() - 1:
					var d := pts[i + 1] - pts[i]
					var l := d.length()
					if l > 0.0 and Vector2(d.y, -d.x).dot(dir) / l > 0.55:
						if run == 0.0:
							run_start = i
						run += l
						var mid := pts[(run_start + i + 1) / 2]
						var score := run - 0.15 * mid.distance_to(centre)
						# prefer groves on both sides (the grove field, as the placement reads it)
						var up := mid - dir * 70.0
						var low := mid + dir * 110.0
						if _grove(terrain, up) > terrain.veg_threshold[1] + 0.04 and _grove(terrain, low) > terrain.veg_threshold[0] + 0.04:
							score += 900.0
						# the upland side must be level 1 and the frame free of the top
						# level, for a clean two-level picture
						if score > best_score and terrain.level_at_px(mid.x - dir.x * 60.0, mid.y - dir.y * 60.0) == 1 \
								and _max_level_near(terrain, mid) <= 1:
							best_score = score
							best = mid
					else:
						run = 0.0
	return best

static func _max_level_near(terrain: Terrain, p: Vector2) -> int:
	var top := 0
	for j in range(-4, 5):
		for i in range(-6, 7):
			top = maxi(top, terrain.level_at_px(p.x + i * 110.0, p.y + j * 95.0))
	return top

static func _grove(terrain: Terrain, p: Vector2) -> float:
	return ValueNoise.fbm(p.x * terrain.density_per_px, p.y * terrain.density_per_px, terrain.density_seed, terrain.density_octaves)

func _dump_masks(masks: Array, ts: TerrainShadows, terrain: Terrain, view: Transform2D, rect: Rect2,
		trees: Array, out: String) -> void:
	var stem := out.get_basename()
	for k in masks.size():
		(masks[k] as ImageTexture).get_image().save_png("%s_mask%d.png" % [stem, k + 1])
	var sp := ShadowPass.new(SIZE)
	ts.add_terrain_silhouettes(sp, 0, view, rect)
	ts.cut_to_receiver(sp, masks, 0)
	sp.canvas.finish_image().save_png("%s_shadow_r0.png" % stem)
	var sp2 := ShadowPass.new(SIZE)
	ts.add_tree_silhouettes(sp2, trees, 0, view)
	ts.cut_to_receiver(sp2, masks, 0)
	sp2.canvas.finish_image().save_png("%s_treeshadow_r0.png" % stem)

static func _try_load(path: String, method: String) -> Script:
	if not ResourceLoader.exists(path):
		return null
	var s: Resource = load(path)
	if s == null or not (s is Script) or not (s as Script).can_instantiate():
		return null
	for m: Dictionary in (s as Script).get_script_method_list():
		if m.get("name", "") == method:
			return s
	return null

static func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0
