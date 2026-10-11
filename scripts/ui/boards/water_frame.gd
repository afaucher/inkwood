extends RefCounted

# ONE FRAME OF THE WATER BOARD (Track WB, 2026-10-10): the map as the game's own drawing layer draws it, with
# the generator's water (scripts/world/water_gen.gd) laid in by scripts/render/water_draw.gd. WINDOWED ONLY.
# Not the chunk baker (Track P is changing it, and water is not wired into it): a single 1280 x 720 frame
# composed in the baker's own pass order -- terrain_shot.gd's way, with the village and the water added:
#
#   paper ground + the village's road and fields   (ink_ground.gd, village_draw.gd)        -> `ground`, once
#   pale band on the land (C, E)  ->  the blue WASH  ->  the level fill  ->  the water's ink / pale lines
#     ->  the terrain's contours and hachures (terrain_draw.gd)
#   TERRAIN shadows -> STRUCTURE shadows -> structures -> TREE shadows -> trees (never on water) -> grain
#
# Everything an option does not change is made ONCE per view (prepare: the ground, the level masks, the
# water's masks, the sprites, the three shadow class masks) and every option is recorded over it (render),
# so the options differ in the water's look and nothing else: the board's whole point.
#
#   var wf := WaterFrame.new(water)                        # a WaterGen (its Terrain and layout are used)
#   var base := wf.prepare(focus_m, 0.35, extras)          # RENDERS the shared pieces
#   var img := wf.render(base, wf.draw.option("A"))        # an Image, 1280 x 720
#
# `extras` puts illustrative things on the map (never generated; the board says so): {"trees": [[x_m, y_m, seed]],
# "houses": [[x_m, y_m, rot, seed]], "clear": [[x_m, y_m, r_m]]} (the terrain's own trees within r of a point are left out, so
# the placed ones are what the eye sees). A tree standing in water is dropped.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkGround = preload("res://scripts/render/ink_ground.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const InkStructs = preload("res://scripts/render/ink_structs.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const Grain = preload("res://scripts/render/grain.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const VillageDraw = preload("res://scripts/render/village_draw.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const SceneGen = preload("res://scripts/world/scene_gen.gd")
const Structures = preload("res://scripts/world/structures.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const COMPOSITE_SHADER = preload("res://scripts/render/shaders/shadow_composite.gdshader")

const SIZE := Vector2i(1280, 720)
const SPRITE_BATCH := 128

# One view's shared pieces.
class Base:
	var focus_m := Vector2.ZERO
	var zoom := 1.0
	var view := Transform2D.IDENTITY
	var rect := Rect2()
	var ground: Texture2D = null
	var paper: Texture2D = null
	var level_masks: Array = []
	var fm = null
	var shade: Texture2D = null
	var struct_cls: Texture2D = null
	var tree_cls: Texture2D = null
	var trees: Array = []
	var structs: Array = []
	var counts := {}

var water: RefCounted
var terrain: RefCounted
var P: RenderParams
var draw: WaterDraw
var td: TerrainDraw
var ts: TerrainShadows
var vd: VillageDraw
var errors: Array[String] = []

var _sprites: Dictionary = {}     # tree seed -> [texture, half]
var _grain: ImageTexture = null
var _shadow_mat: ShaderMaterial = null
var _gen: SceneGen = null

func _init(w: RefCounted, hue_override: float = -1.0) -> void:
	water = w
	terrain = w.terrain()
	P = RenderParams.new()
	P.L["road"] = false
	td = TerrainDraw.new(terrain, P)
	ts = TerrainShadows.new(terrain, P)
	vd = VillageDraw.new(terrain, P)
	draw = WaterDraw.new(P, hue_override)
	errors.append_array(td.errors)
	errors.append_array(vd.errors)
	errors.append_array(draw.errors)
	_gen = SceneGen.new(1.0, 1.0, P)
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = COMPOSITE_SHADER
	_shadow_mat.set_shader_parameter("tint", Vector3(P.shadowCol.r, P.shadowCol.g, P.shadowCol.b))
	_shadow_mat.set_shader_parameter("strength", P.shadowStr)

func ppm() -> float:
	return terrain.px_per_m

# The world-px -> frame-px transform for a frame centred on `focus_m` at `zoom`.
func view_of(focus_m: Vector2, zoom: float) -> Transform2D:
	var origin := focus_m * ppm() - Vector2(SIZE) * 0.5 / zoom
	return Transform2D(Vector2(zoom, 0.0), Vector2(0.0, zoom), -origin * zoom)

# --- preparing the shared pieces -----------------------------------------------------------------------------

func prepare(focus_m: Vector2, zoom: float, extras: Dictionary = {}) -> Base:
	var b := Base.new()
	b.focus_m = focus_m
	b.zoom = zoom
	b.view = view_of(focus_m, zoom)
	b.rect = TerrainDraw.view_rect(b.view, SIZE)
	var reach := ts.reach_px()
	# the paper, then the ground (paper, specks, fibres, dirt; the village's road and fields) as one texture
	b.paper = InkGround.build_paper(SIZE, P, true)
	var g0 := InkCanvas.new(SIZE)
	InkGround.draw_ground(g0, float(SIZE.x), float(SIZE.y), [], P, b.paper)
	var vil: Variant = terrain.village()
	if vil != null:
		g0.set_transform_matrix(b.view)
		vd.draw_ground(g0, vil, b.rect)
	b.ground = g0.finish_texture()
	b.level_masks = td.level_masks(b.view, SIZE)
	b.fm = draw.make_masks(water, b.view, SIZE, b.rect)
	# the trees: the terrain's, never in water (nor with a trunk in the shallows), and the board's own
	var trees: Array = []
	var dropped := 0
	var clear: Array = extras.get("clear", [])
	for t: Dictionary in terrain.trees_in_rect_px(b.rect.grow(reach)):
		var cleared := false
		for c: Array in clear:
			if Vector2(t.x, t.y).distance_to(Vector2(float(c[0]), float(c[1])) * ppm()) < float(c[2]) * ppm():
				cleared = true
		if cleared:
			continue
		if _stands_dry(t.x, t.y):
			trees.append(t.duplicate())
		else:
			dropped += 1
	for e: Array in extras.get("trees", []):
		var t := _demo_tree(e)
		if _stands_dry(t.x, t.y):
			trees.append(t)
	trees.sort_custom(func(a: Dictionary, c: Dictionary) -> bool:
		var ha: float = a.base + a.h
		var hc: float = c.base + c.h
		return ha < hc or (ha == hc and a.y < c.y))
	b.trees = trees
	b.counts["trees"] = trees.size()
	b.counts["trees_dropped_in_water"] = dropped
	# the village's structures and the board's houses
	var structs: Array = []
	var vl: Variant = vil
	if vl != null:
		for s: Dictionary in vl.structs_in_rect(b.rect.grow(reach)):
			structs.append(s.duplicate())
	for e: Array in extras.get("houses", []):
		var h := Structures.make_house(Mulberry32.new(int(e[3])), float(e[0]) * ppm(), float(e[1]) * ppm(), float(e[2]))
		Structures.sync_struct(h, P)
		h["role"] = "house"
		structs.append(h)
	b.structs = structs
	b.counts["structs"] = structs.size()
	_sync_sprites(trees, structs)
	# the three shadow classes, once (masks: premultiplied black, alpha = coverage)
	var dummy := InkCanvas.new(Vector2i(8, 8), 1)
	var sp := ShadowPass.new(SIZE)
	b.shade = ts.cast_terrain(dummy, sp, b.level_masks, b.view, b.rect)
	b.struct_cls = _struct_class(b, sp, dummy)
	b.tree_cls = ts.cast_trees(dummy, sp, b.level_masks, trees, b.view, b.shade)
	dummy.discard()
	sp.canvas.discard()
	if _grain == null:
		_grain = Grain.build_texture(SIZE, int(terrain.seed_value))
	return b

# Whether a tree at world px (x, y) stands on dry land: not in water, nor within 6 m of it (a trunk in the shallows).
func _stands_dry(x_px: float, y_px: float) -> bool:
	var m := Vector2(x_px, y_px) / ppm()
	if water.is_wet(m.x, m.y):
		return false
	for k in 4:
		var q := m + Vector2.from_angle(float(k) * PI * 0.5) * 6.0
		if water.is_wet(q.x, q.y):
			return false
	return true

func _demo_tree(e: Array) -> Dictionary:
	var t := _gen.make_tree(Mulberry32.new(int(e[2])), float(e[0]) * ppm(), float(e[1]) * ppm())
	_gen.sync_tree(t)
	t["level"] = 0
	t["base"] = 0.0
	t["base_m"] = 0.0
	return t

# A sprite for every tree and structure (cached by the object's seed across views), rendered in batches.
func _sync_sprites(trees: Array, structs: Array) -> void:
	var owners: Array = []
	var canvases: Array = []
	for t: Dictionary in trees:
		var hit: Variant = _sprites.get("t%d|%.1f" % [t.seed, t.r])
		if hit != null:
			t["sprite"] = hit[0]
			t["half"] = hit[1]
			continue
		canvases.append(InkSprites.build_tree_sprite(t, P))
		owners.append(t)
	for s: Dictionary in structs:
		var hit: Variant = _sprites.get("s%d|%s" % [s.seed, s.kind])
		if hit != null:
			s["sprite"] = hit
			continue
		canvases.append(InkStructs.build_struct_sprite(s, P))
		owners.append(s)
	for i in range(0, canvases.size(), SPRITE_BATCH):
		var imgs := InkCanvas.render_all(canvases.slice(i, i + SPRITE_BATCH))
		for k in imgs.size():
			var o: Dictionary = owners[i + k]
			var tex := ImageTexture.create_from_image(imgs[k])
			if o.kind == "tree":
				o["sprite"] = tex
				_sprites["t%d|%.1f" % [o.seed, o.r]] = [tex, o.half]
			else:
				o["sprite"] = tex
				_sprites["s%d|%s" % [o.seed, o.kind]] = tex

# The structure class mask (the village's houses and walls, and the board's houses): castShadows' wall and house branch
# as the chunk provider records it, cut to level 0 (water is level 0) and out of the terrain's shade.
func _struct_class(b: Base, sp: ShadowPass, dummy: InkCanvas) -> Texture2D:
	if b.structs.is_empty():
		return null
	var m := sp.canvas
	m.set_transform_matrix(b.view)
	m.fill_color = Color.BLACK
	m.begin_path()
	for o: Dictionary in b.structs:
		var shift := ts.dir * (float(o.h) * ts.L)
		if o.kind == "house":
			for p: Dictionary in o.geo:
				_add_prism(m, _v2(p.corners), shift)
		else:
			var Lp := _v2(o.L)
			var Rp := _v2(o.R)
			var n: int = o.pts.size()
			var lim := n if o.closed else n - 1
			for i in lim:
				var j := (i + 1) % n
				_add_prism(m, PackedVector2Array([Lp[i], Lp[j], Rp[j], Rp[i]]), shift)
			for cap: Array in o.caps:
				_add_prism(m, _v2(cap), shift)
	m.fill()
	ts.cut_to_receiver(sp, b.level_masks, 0, b.shade)
	var part := sp.canvas.finish_texture()
	sp.clear()
	return ts.composite_parts(dummy, sp, [part])

static func _v2(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Array in pts:
		out.append(Vector2(p[0], p[1]))
	return out

static func _add_prism(m: InkCanvas, q: PackedVector2Array, shift: Vector2) -> void:
	var all := q.duplicate()
	for p in q:
		all.push_back(p + shift)
	var hh := Geometry.hull(all)
	if hh.size() >= 3:
		m.move_to(hh[0].x, hh[0].y)
		for i in range(1, hh.size()):
			m.line_to(hh[i].x, hh[i].y)
		m.close_path()

# --- recording one option over the shared pieces -----------------------------------------------------------------

func render(b: Base, opt: Dictionary) -> Image:
	var g := InkCanvas.new(SIZE)
	g.draw_image(b.ground, 0.0, 0.0, float(SIZE.x), float(SIZE.y))
	var up: Texture2D = b.level_masks[0]
	draw.draw_halo(g, opt, b.fm, up)
	draw.draw_wash(g, opt, b.fm, up, b.paper)
	td.draw_level_fill(g, b.level_masks)
	draw.draw_lines(g, opt, water, b.view, b.rect)
	td.draw_linework(g, b.view, b.rect)
	_composite(g, b.shade)
	_composite(g, b.struct_cls)
	g.set_transform_matrix(b.view)
	if P.L.objects:
		for o: Dictionary in b.structs:
			g.draw_image(o.sprite, o.bx, o.by, o.bw, o.bh)
	_composite(g, b.tree_cls)
	g.set_transform_matrix(b.view)
	if P.L.objects:
		for t: Dictionary in b.trees:
			var s: float = t.half * 2.0
			g.draw_image(t.sprite, t.x - t.half, t.y - t.half, s, s)
	Grain.apply(g, _grain, P.grain)
	return g.finish_image()

func _composite(g: InkCanvas, mask: Texture2D) -> void:
	if mask == null or not P.L.shadows:
		return
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(mask, 0.0, 0.0, float(SIZE.x), float(SIZE.y), _shadow_mat)
	g.restore()
