extends RefCounted

# The prototype's frame, ported line for line from reference/inkwood-renderer.html:
# syncTree / syncProp / syncStruct (the sprite cache), castShadows, drawSprites
# and render() with its exact pass order:
#
#   ground (paper + road)  ->  prop shadows  ->  props  ->  structure shadows
#   ->  walls and houses  ->  tree shadows (sorted by h, then y)  ->  trees  ->  grain
#
# Usage:
#   var gen := SceneGen.new(1280, 720, RenderParams.new()); gen.generate(20261009)
#   var r := InkRenderer.new(gen)          # resize(): buildGround(); buildGrain()
#   var img: Image = r.render()            # render(): sprites (cached by key), then the frame
#   r.timings                              # ms per stage of the last build and render
# or in one call (the --render-scene entry point, scripts/app/main.gd):
#   InkRenderer.render_scene(20261009, Vector2i(1280, 720), {"grain": false, "parity": true})
#
# The routines themselves are in ink_sprites.gd (trees, props), ink_structs.gd
# (walls, houses) and ink_ground.gd (paper, road, grain); the substrate is
# ink_canvas.gd, shadow_pass.gd, paper.gd and grain.gd. The scene -- every
# object's position, seed and geometry -- is scripts/world/scene_gen.gd's;
# this file reads it and fills the drawing fields the prototype keeps on each
# object: `key`, `sprite`, `half` (trees and props), `sprite` and `sprite_key`
# (structures; their `key` is sync_struct's geometry key).
#
# SPRITES ARE CACHED BY THE PROTOTYPE'S KEYS: a tree's sprite is rebuilt when
# r.toFixed(1)|rings|wob|lw changes, a prop's when lw does, a structure's when
# its geometry key does (lw|wob|sunAz|wallW|houseSize|shadowCol). Every sprite
# a render needs is recorded first and drawn in one engine frame
# (InkCanvas.render_all), in batches of SPRITE_BATCH canvases.
#
# PARITY vs GAME VALUES: the frame uses data/params/render_defaults.json as it
# stands -- including decisions taken since the prototype (shadow_strength
# 0.44, Alex 2026-10-09). A parity render ("parity": true) sets every
# parameter that carries a `prototype_default` back to it (today only
# shadow_strength -> 0.92), so the frame can be compared with the browser
# prototype at its own defaults.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const InkStructs = preload("res://scripts/render/ink_structs.gd")
const InkGround = preload("res://scripts/render/ink_ground.gd")
const Grain = preload("res://scripts/render/grain.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const SceneGen = preload("res://scripts/world/scene_gen.gd")
const Structures = preload("res://scripts/world/structures.gd")

const _SELF_PATH := "res://scripts/render/ink_renderer.gd"

# Canvases per render_all: each holds two viewports (SSAA and resolve) until drawn.
const SPRITE_BATCH := 256

var gen: SceneGen
var P: RenderParams
var W: int
var H: int
var paper_shader := false
var grain_seed: int
var ground: ImageTexture
# What the ground was built for: the prototype rebuilds it when lw or wob
# moves (rebuildGroundSoon) or the paper / road pass is toggled (buildGround).
var ground_key := ""
var grainC: ImageTexture  # the prototype's grainC
var timings: Dictionary = {}

func _init(scene: SceneGen, use_paper_shader: bool = false, grain_seed_value: int = -1) -> void:
	gen = scene
	P = scene.P
	W = int(scene.W)
	H = int(scene.H)
	paper_shader = use_paper_shader
	grain_seed = grain_seed_value if grain_seed_value >= 0 else scene.sceneSeed

# function resize(): ... buildGround(); buildGrain(); -- the per-stage-size layers.
func build_layers() -> void:
	ground_key = _ground_key()
	var t0 := Time.get_ticks_usec()
	var paper: Texture2D = null
	if P.L.paper:
		paper = InkGround.build_paper(Vector2i(W, H), P, paper_shader)
	timings["paper"] = _ms(t0)
	var t1 := Time.get_ticks_usec()
	ground = InkGround.build_ground(Vector2i(W, H), gen.roadPts, P, paper_shader, paper)
	timings["ground_ink"] = _ms(t1)
	timings["ground"] = _ms(t0)
	if grainC == null:  # buildGrain() runs on resize only
		t0 = Time.get_ticks_usec()
		grainC = InkGround.build_grain(Vector2i(W, H), grain_seed)
		timings["grain"] = _ms(t0)

# The inputs buildGround reads that can change without a resize.
func _ground_key() -> String:
	return "%s|%s|%s|%s" % [str(P.lw), str(P.wob), P.L.paper, P.L.road]

# --- sync: the sprite cache ---------------------------------------------------------

# function syncTree(t): r and h from P (scene_gen's geometry half), then the
# sprite when its key changed. Returns the canvas to render, or null.
func sync_tree(t: Dictionary) -> InkCanvas:
	gen.sync_tree(t)  # t.r=...; t.h=...;
	# const key=t.r.toFixed(1)+"|"+P.rings+"|"+P.wob+"|"+P.lw;
	var key := "%.1f|%d|%s|%s" % [t.r, P.rings, str(P.wob), str(P.lw)]
	if key != t.get("key", ""):
		t.key = key
		return InkSprites.build_tree_sprite(t, P)  # buildTreeSprite(t)
	return null

# function syncProp(p){const key=String(P.lw); if(key!==p.key){p.key=key; buildPropSprite(p);}}
func sync_prop(p: Dictionary) -> InkCanvas:
	var key := str(P.lw)
	if key != p.get("key", ""):
		p.key = key
		return InkSprites.build_prop_sprite(p, P)
	return null

# function syncStruct(s): geometry, h and bounds are structures.gd's
# sync_struct (which keeps s.key); the sprite is redrawn when that key moved
# past the one the sprite was drawn for.
func sync_struct(s: Dictionary) -> InkCanvas:
	Structures.sync_struct(s, P)
	if s.key != s.get("sprite_key", ""):
		s.sprite_key = s.key
		return InkStructs.build_struct_sprite(s, P)
	return null

# Every object whose key changed gets a fresh sprite, rendered in batches.
func sync_all() -> void:
	var t0 := Time.get_ticks_usec()
	var owners: Array[Dictionary] = []
	var canvases: Array = []
	var n_trees := 0
	for t: Dictionary in gen.trees:  # trees.forEach(syncTree)
		var c := sync_tree(t)
		if c != null:
			owners.append(t)
			canvases.append(c)
			n_trees += 1
	var t_trees := _ms(t0)
	for p: Dictionary in gen.props:  # props.forEach(syncProp)
		var c := sync_prop(p)
		if c != null:
			owners.append(p)
			canvases.append(c)
	for s: Dictionary in gen.structs:  # structs.forEach(syncStruct)
		var c := sync_struct(s)
		if c != null:
			owners.append(s)
			canvases.append(c)
	timings["sprites_record"] = _ms(t0)
	timings["tree_sprites_record"] = t_trees
	timings["sprites_built"] = canvases.size()
	timings["tree_sprites_built"] = n_trees
	var t1 := Time.get_ticks_usec()
	for b in range(0, canvases.size(), SPRITE_BATCH):
		var imgs := InkCanvas.render_all(canvases.slice(b, b + SPRITE_BATCH))
		for k in imgs.size():
			owners[b + k].sprite = ImageTexture.create_from_image(imgs[k])
	timings["sprites_render"] = _ms(t1)
	timings["sprites"] = _ms(t0)

# --- shadow pass ---------------------------------------------------------------------

# function castShadows(list): every silhouette of `list` into one mask --
# prism hulls for walls and houses, trunk strokes and stretched canopies for
# trees, three stepped copies for props -- tinted once and composited at
# P.shadowStr onto `ctx`.
func cast_shadows(ctx: InkCanvas, sp: ShadowPass, list: Array) -> void:
	var m := sp.canvas  # const m=mctx; ...clearRect... (a fresh mask per pass: ShadowPass clears after compositing)
	var az := (P.sunAz + 90.0) * PI / 180.0  # shadow points away from the sun
	var dx := cos(az)
	var dy := sin(az)
	var L := 1.0 / tan(P.elev * PI / 180.0)
	var stretch := minf(P.canopy_shadow_stretch_max, 1.0 + L * 0.3)  # Math.min(2.4,1+L*.3)
	m.stroke_color = Color.BLACK  # m.strokeStyle="#000"; m.lineCap="round";
	m.line_cap = "round"
	for o: Dictionary in list:
		# const off=o.h*L, sx=o.x+dx*off, sy=o.y+dy*off, s=o.half*2;  -- below, past the
		# structure branch: a wall has no x, y or half (JS computes NaN and never reads it)
		if o.kind == "wall" or o.kind == "house":
			# prism shadow: convex hull of each footprint piece and its copy shifted by height
			var shift := Vector2(dx * o.h * L, dy * o.h * L)  # offx, offy
			m.fill_color = Color.BLACK  # m.fillStyle="#000"
			m.begin_path()
			if o.kind == "house":
				for p: Dictionary in o.geo:
					_add_prism(m, InkStructs.to_v2(p.corners), shift)
			else:
				var Lp := InkStructs.to_v2(o.L)
				var Rp := InkStructs.to_v2(o.R)
				var n: int = o.pts.size()
				var lim := n if o.closed else n - 1
				for i in lim:
					var j := (i + 1) % n
					_add_prism(m, PackedVector2Array([Lp[i], Lp[j], Rp[j], Rp[i]]), shift)
				for c: Array in o.caps:  # o.caps.forEach(add)
					_add_prism(m, InkStructs.to_v2(c), shift)
			m.fill()
			continue
		var off: float = o.h * L
		var sx: float = o.x + dx * off
		var sy: float = o.y + dy * off
		var s: float = o.half * 2.0
		if o.kind == "tree":
			m.line_width = maxf(1.5, o.r * 0.12)
			m.begin_path()
			m.move_to(o.x, o.y)
			m.line_to(sx, sy)
			m.stroke()
			# m.save(); m.translate(sx,sy); m.rotate(az); m.scale(stretch,1); m.rotate(-az);
			# m.drawImage(o.sprite,-o.half,-o.half,s,s); m.restore();
			var xf := Transform2D(0.0, Vector2(sx, sy)) * Transform2D(az, Vector2.ZERO) \
				* Transform2D(Vector2(stretch, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) * Transform2D(-az, Vector2.ZERO)
			sp.draw_silhouette_texture(o.sprite, xf, Rect2(-o.half, -o.half, s, s))
		else:
			for k in range(1, 4):  # for(let k=1;k<=3;k++)
				var f := k / 3.0
				sp.draw_silhouette_texture(o.sprite, Transform2D.IDENTITY,
					Rect2(o.x + dx * off * f - o.half, o.y + dy * off * f - o.half, s, s))
	# m.globalCompositeOperation="source-in"; m.fillStyle=P.shadowCol; m.fillRect(...);
	# ctx.globalAlpha=P.shadowStr; ctx.drawImage(mask,0,0);
	sp.composite(ctx, P.shadowCol, P.shadowStr)

# add=q=>{const hh=hull(q.concat(q.map(p=>[p[0]+offx,p[1]+offy]))); addPoly(m,hh,true);}
static func _add_prism(m: InkCanvas, q: PackedVector2Array, shift: Vector2) -> void:
	var all := q.duplicate()
	for p in q:
		all.push_back(p + shift)
	var hh := Geometry.hull(all)
	if hh.size() >= 3:
		InkStructs.add_poly(m, hh, true)

# function drawSprites(list){for(const o of list){const s=o.half*2; ctx.drawImage(o.sprite,o.x-o.half,o.y-o.half,s,s);}}
static func draw_sprites(ctx: InkCanvas, list: Array) -> void:
	for o: Dictionary in list:
		var s: float = o.half * 2.0
		ctx.draw_image(o.sprite, o.x - o.half, o.y - o.half, s, s)

# --- the frame ------------------------------------------------------------------------

# function render(): the passes in the prototype's order. Builds the ground
# and grain first if they do not exist yet (the prototype's resize()), and the
# ground again when lw, wob or the paper / road pass changed since it was built
# (the prototype's rebuildGroundSoon / the toggles' buildGround).
func render() -> Image:
	var t_all := Time.get_ticks_usec()
	if ground == null or ground_key != _ground_key():
		build_layers()
	sync_all()  # trees.forEach(syncTree); props.forEach(syncProp); ... structs.forEach(syncStruct);
	var t0 := Time.get_ticks_usec()
	var ctx := InkCanvas.new(Vector2i(W, H))
	ctx.draw_image(ground, 0.0, 0.0, float(W), float(H))  # ctx.drawImage(ground,0,0)
	var sp := ShadowPass.new(Vector2i(W, H))
	if P.L.shadows:
		cast_shadows(ctx, sp, gen.props)
	if P.L.objects:
		draw_sprites(ctx, gen.props)
	if P.L.shadows:
		cast_shadows(ctx, sp, gen.structs)
	if P.L.objects:
		for s: Dictionary in gen.structs:
			ctx.draw_image(s.sprite, s.bx, s.by, s.bw, s.bh)
	# const sorted=trees.slice().sort((a,b)=>a.h-b.h||a.y-b.y);
	var sorted: Array = gen.trees.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.h < b.h or (a.h == b.h and a.y < b.y))
	if P.L.shadows:
		cast_shadows(ctx, sp, sorted)
	if P.L.objects:
		draw_sprites(ctx, sorted)
	sp.canvas.discard()  # the fresh mask the last composite left behind
	if P.L.grain and P.grain > 0:
		Grain.apply(ctx, grainC, P.grain)  # globalCompositeOperation="multiply"; globalAlpha=P.grain
	if P.L.grid:
		_draw_grid(ctx)
	var img := ctx.finish_image()
	timings["frame"] = _ms(t0)
	timings["render"] = _ms(t_all)
	return img

# The collision-grid debug overlay (P.L.grid): occupied cells and the lattice.
# Debug only; its two reds are the prototype's literals.
func _draw_grid(ctx: InkCanvas) -> void:
	ctx.fill_color = Color8(214, 58, 50, 33)  # rgba(214,58,50,.13)
	for k: Vector2i in gen.grid.keys():
		ctx.fill_rect(k.x * P.CELL, k.y * P.CELL, P.CELL, P.CELL)
	ctx.stroke_color = Color8(214, 58, 50, 204)  # rgba(214,58,50,.8)
	ctx.line_width = 1.2
	ctx.begin_path()
	var x := 0.0
	while x <= W:
		ctx.move_to(x, 0)
		ctx.line_to(x, H)
		x += P.CELL
	var y := 0.0
	while y <= H:
		ctx.move_to(0, y)
		ctx.line_to(W, y)
		y += P.CELL
	ctx.stroke()

# --- one call: generate, draw -------------------------------------------------------------

# newScene(seed) at `size` and its frame. Options:
#   grain         bool, default true   -- false is the prototype's "Grain" pass unticked
#   parity        bool, default false  -- parameters back to their prototype_default (see the header)
#   paper_shader  bool, default false  -- the paper tint on the GPU instead of GDScript
# Prints the timings. Returns null (after printing why) if the params do not load.
static func render_scene(seed_value: int, size: Vector2i, options: Dictionary = {}) -> Image:
	var t0 := Time.get_ticks_usec()
	var P := RenderParams.new()
	if not P.ok():
		printerr("[render-scene] render params did not load: ", ", ".join(P.errors))
		return null
	if not bool(options.get("grain", true)):
		P.L["grain"] = false
	if bool(options.get("parity", false)):
		for line in apply_prototype_defaults(P):
			print("[render-scene] parity: ", line)
	var gen := SceneGen.new(float(size.x), float(size.y), P)
	gen.generate(seed_value)
	var t_gen := _ms(t0)
	var r: Variant = load(_SELF_PATH).new(gen, bool(options.get("paper_shader", false)))
	var img: Image = r.render()
	var t: Dictionary = r.timings
	print("[render-scene] seed %d %dx%d: %s" % [seed_value, size.x, size.y, gen.count_line()])
	print("[render-scene] scene generation: %.0f ms" % t_gen)
	print("[render-scene] paper tint (%s): %.0f ms; ground ink (specks, dirt, road): %.0f ms; grain: %.0f ms" % [
		"shader" if r.paper_shader else "GDScript fbm", t.get("paper", 0.0), t.get("ground_ink", 0.0), t.get("grain", 0.0)])
	print("[render-scene] %d tree sprites: record %.0f ms; all %d sprites: record %.0f ms, render_all + readback %.0f ms" % [
		t.get("tree_sprites_built", 0), t.get("tree_sprites_record", 0.0), t.get("sprites_built", 0),
		t.get("sprites_record", 0.0), t.get("sprites_render", 0.0)])
	print("[render-scene] frame (ground, 3 shadow passes, objects, grain): %.0f ms" % t.get("frame", 0.0))
	print("[render-scene] render() total %.0f ms; with generation %.0f ms" % [t.get("render", 0.0), _ms(t0)])
	return img

# Sets every P parameter whose data entry carries a `prototype_default` to
# that value (render_defaults.json keeps the prototype's value beside a
# decided one). Returns a line per change. Only parameters RenderParams maps
# are touched; the map is the prototype's name for each data key.
static func apply_prototype_defaults(P: RenderParams) -> Array[String]:
	const NAMES := {"brush_size": "brush", "density": "density", "canopy_size": "treeSize",
		"size_variation": "sizeVar", "inner_contour_rings": "rings", "tree_height": "height",
		"wall_width": "wallW", "wall_height": "wallH", "house_size": "houseSize", "sun_direction": "sunAz",
		"sun_elevation": "elev", "shadow_strength": "shadowStr", "line_weight": "lw", "hand_wobble": "wob",
		"paper_grain": "grain"}
	var out: Array[String] = []
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(P.source_path))
	var prm: Dictionary = (raw as Dictionary).get("parameters", {}) if raw is Dictionary else {}
	for key: String in prm:
		var entry: Variant = prm[key]
		if not (entry is Dictionary and (entry as Dictionary).has("prototype_default") and NAMES.has(key)):
			continue
		var v: Variant = entry["prototype_default"]
		var name: String = NAMES[key]
		var was: Variant = P.get(name)
		P.set(name, int(v) if name == "rings" else float(v))
		out.append("P.%s %s -> %s (parameters.%s.prototype_default)" % [name, str(was), str(P.get(name)), key])
	return out

static func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0
