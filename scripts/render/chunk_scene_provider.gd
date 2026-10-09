extends "res://scripts/render/chunk_provider.gd"

# THE STAND-IN chunk content (before Track T's terrain, and still the only
# source of forts, houses and props on a map): the prototype's own scene
# generator (scripts/world/scene_gen.gd's makers, can_place and spatial hash;
# structures.gd's forts and houses) run per chunk, seeded from (world seed,
# chunk), drawn in the prototype's own pass order. map_view.provider in
# render_defaults.json picks it ("scene") or Track T's terrain ("terrain").
#
# WHAT A CHUNK HOLDS (from (seed, cx, cy) alone, never from bake order):
#   structures  a fort (the prototype's makeFort, size 340) with
#               map_view.standin.fort_chance, a house with house_chance, each
#               at a seeded spot kept struct_margin_px inside the chunk, so no
#               structure crosses a border; placed first, as newScene does.
#   props       with prop_cluster_chance, newScene's 70-dart prop cluster
#               round a seeded centre (canPlace forced, as there).
#   trees       newScene's tree loop over the chunk: W*H/75 darts, the grove
#               field fbm(x*.006, y*.006, seed%9973+3, 3) taken at WORLD
#               coordinates so groves run on across borders, makeTree,
#               syncTree, canPlace.
#   no road     the prototype's road is one spline per stage.
# BORDERS. pre(X) is the chunk's trees and props placed with no regard to its
# neighbours. Its final set is pre(X) minus every tree or prop that overlaps
# (the prototype's collision radii) one of pre(L) for the four neighbours
# BEFORE it in (cy, cx) order: W, NW, N, NE. Removal never admits anything
# pre(X) lacked, so no two final objects of neighbouring chunks overlap, and
# final(X) depends on five pre() sets -- pure functions of seed and
# coordinates. (Track T's terrain.gd uses the same rule.) Caches are guarded
# by a mutex: content is generated on worker threads.
#
# THE BAKE (stages), the prototype's render() per chunk:
#   gather   (worker) the chunk's and its 8 neighbours' objects within
#            reach_px of the chunk, copied; trees sorted by h, then y, then x
#   sprites  (baker) a sprite for each
#   ground   (worker, in parallel) paper, specks, fibres, dirt
#   masks    (worker) castShadows for props, structures, trees: three masks
#   frame    (worker) prop shadows, props, structure shadows, structures,
#            tree shadows, trees, grain -> the chunk

const SceneGen = preload("res://scripts/world/scene_gen.gd")
const Structures = preload("res://scripts/world/structures.gd")
const Geometry = preload("res://scripts/core/geometry.gd")

# Salts for the per-chunk streams (code constants, not tunables).
const SALT_STRUCTS := 0x51A7
const SALT_PROPS := 0x9A0B
const SALT_TREES := 0x7EE5

var fort_chance: float
var house_chance: float
var prop_cluster_chance: float
var struct_margin_px: float

var _mutex := Mutex.new()
var _pre: Dictionary = {}       # Vector2i -> {trees, props, structs}
var _final: Dictionary = {}     # Vector2i -> {trees, props, structs}
var _sg: SceneGen               # cr() / max_cr() for the border pass

# `params`: a RenderParams this provider owns (it switches the road off);
# `view_cfg`: the map_view section of render_defaults.json.
func _init(seed_v: int, params: RenderParams, view_cfg: Dictionary) -> void:
	seed_value = seed_v
	P = params
	P.L["road"] = false
	chunk_px = int(view_cfg.get("chunk_px", 1024))
	var st: Dictionary = view_cfg.get("standin", {})
	fort_chance = float(st.get("fort_chance", 0.0))
	house_chance = float(st.get("house_chance", 0.0))
	prop_cluster_chance = float(st.get("prop_cluster_chance", 0.0))
	struct_margin_px = float(st.get("struct_margin_px", 24.0))
	_sg = SceneGen.new(float(chunk_px), float(chunk_px), P)

func stages() -> Array:
	return [
		{"name": "gather", "thread": "worker", "fn": _gather},
		{"builtin": "sprites"},
		{"name": "ground", "thread": "worker", "parallel": true, "fn": _ground},
		{"name": "masks", "thread": "worker", "fn": _masks},
		{"name": "frame", "thread": "worker", "join": true, "final": true, "fn": _frame},
	]

func clear_cache() -> void:
	_mutex.lock()
	_pre.clear()
	_final.clear()
	_mutex.unlock()

# The longest tree shadow (h = r * height * 1.15 for the biggest r, cast by
# 1/tan(elevation)) plus its canopy stretched along the sun; structures are
# measured from their bounds by the same amount.
func reach_px() -> float:
	var r_max := P.treeSize * (1.0 + P.sizeVar) * P.big_tree_scale
	var L := 1.0 / tan(P.elev * PI / 180.0)
	var stretch := minf(P.canopy_shadow_stretch_max, 1.0 + L * 0.3)
	var half := r_max * 1.3 + 4.0
	return r_max * P.height * 1.15 * L + half * stretch + 4.0

func chunk_content(c: Vector2i) -> Dictionary:
	return objects(c)

# Generation ahead of need (chunk_baker.gd warm), one chunk at a time.
func warm_lane() -> String:
	return "scene"

func warm_chunk(c: Vector2i) -> void:
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			objects(Vector2i(cx, cy))

# --- content ----------------------------------------------------------------------------

# The chunk's own objects, final (after the border rule).
func objects(c: Vector2i) -> Dictionary:
	_mutex.lock()
	var hit: Variant = _final.get(c)
	_mutex.unlock()
	if hit != null:
		return hit
	var own := _pre_objects(c)
	var reach := 2.0 * _sg.max_cr()
	var rect := chunk_rect(c).grow(reach)
	var others: Array = []
	for nb: Vector2i in [Vector2i(c.x - 1, c.y), Vector2i(c.x - 1, c.y - 1), Vector2i(c.x, c.y - 1), Vector2i(c.x + 1, c.y - 1)]:
		var pre := _pre_objects(nb)
		for o: Dictionary in pre.trees + pre.props:
			if rect.has_point(Vector2(o.x, o.y)):
				others.append(o)
	var keep := func(o: Dictionary) -> bool:
		var co := _sg.cr(o)
		for b: Dictionary in others:
			var dx: float = b.x - o.x
			var dy: float = b.y - o.y
			var rr: float = co + _sg.cr(b)
			if dx * dx + dy * dy < rr * rr:
				return false
		return true
	var out := {"trees": own.trees.filter(keep), "props": own.props.filter(keep), "structs": own.structs}
	_mutex.lock()
	if not _final.has(c):
		_final[c] = out
	out = _final[c]
	_mutex.unlock()
	return out

# pre(X): the chunk's objects with no regard to its neighbours.
func _pre_objects(c: Vector2i) -> Dictionary:
	_mutex.lock()
	var hit: Variant = _pre.get(c)
	_mutex.unlock()
	if hit != null:
		return hit
	var W := float(chunk_px)
	var ox := float(c.x * chunk_px)
	var oy := float(c.y * chunk_px)
	var gen := SceneGen.new(W, W, P)   # the chunk's local frame (0..W); the road is off
	var structs: Array = []
	var rs := Mulberry32.new(chunk_seed(seed_value, c, SALT_STRUCTS))
	# A fort: makeFort(rng, x, y, fs, rot) with the prototype's fs=min(W*.78,H*.5,340).
	if rs.next() < fort_chance:
		var fs := minf(minf(W * 0.78, W * 0.5), 340.0)
		var fx := W * (0.25 + rs.next() * 0.5)
		var fy := W * (0.25 + rs.next() * 0.5)
		var frot := (rs.next() - 0.5) * PI
		var fseed := rs.next_seed()
		_add_structs(gen, structs, Structures.make_fort(Mulberry32.new(fseed), fx, fy, fs, frot, P),
			Structures.make_fort(Mulberry32.new(fseed), fx + ox, fy + oy, fs, frot, P), W)
	# A house: makeHouse(rng, x, y, rot), clear of the fort.
	if rs.next() < house_chance:
		var hx := W * (0.1 + rs.next() * 0.8)
		var hy := W * (0.1 + rs.next() * 0.8)
		var hrot := (rs.next() - 0.5) * PI
		var hseed := rs.next_seed()
		var clear := true
		for s: Dictionary in gen.structs:
			if Structures.s_dist(s, hx, hy) < P.houseSize * 2.0:
				clear = false
		if clear:
			_add_structs(gen, structs, [Structures.make_house(Mulberry32.new(hseed), hx, hy, hrot)],
				[Structures.make_house(Mulberry32.new(hseed), hx + ox, hy + oy, hrot)], W)
	# A prop cluster: newScene's 70 darts round a centre, canPlace forced.
	var rp := Mulberry32.new(chunk_seed(seed_value, c, SALT_PROPS))
	if rp.next() < prop_cluster_chance:
		var cx := W * (0.15 + rp.next() * 0.7)
		var cy := W * (0.15 + rp.next() * 0.7)
		for _i in 70:
			var a := rp.next() * PI * 2.0
			var d := sqrt(rp.next()) * 52.0
			var x := cx + cos(a) * d
			var y := cy + sin(a) * d * 0.8
			var p := gen.make_prop(rp, x, y)
			if x >= 0.0 and y >= 0.0 and x < W and y < W and gen.can_place(x, y, gen.cr(p), true):
				gen.props.append(p)
				gen.g_add(p)
	# Trees: newScene's tree loop, the grove field at world coordinates.
	var rt := Mulberry32.new(chunk_seed(seed_value, c, SALT_TREES))
	var tries := roundi(W * W / 75.0)
	var density_seed := seed_value % 9973 + 3
	for _i in tries:
		var x := rt.next() * W
		var y := rt.next() * W
		var f := ValueNoise.fbm((x + ox) * 0.006, (y + oy) * 0.006, density_seed, 3)
		if f < 0.5 or rt.next() > (f - 0.5) * 3.2:
			continue
		var t := gen.make_tree(rt, x, y)
		gen.sync_tree(t)
		if gen.can_place(x, y, gen.cr(t), true):
			gen.trees.append(t)
			gen.g_add(t)
	var out := {"trees": _to_world(gen.trees, ox, oy, c), "props": _to_world(gen.props, ox, oy, c), "structs": structs}
	_mutex.lock()
	if not _pre.has(c):
		_pre[c] = out
	out = _pre[c]
	_mutex.unlock()
	return out

# Structures enter the local generator (so trees and props avoid them) and,
# as world-coordinate twins made from the same seed, the chunk's list -- only
# when every piece stays struct_margin_px inside the chunk.
func _add_structs(gen: SceneGen, out: Array, local: Array, world: Array, W: float) -> void:
	for s: Dictionary in local:
		Structures.sync_struct(s, P)
		if s.bx < struct_margin_px or s.by < struct_margin_px or s.bx + s.bw > W - struct_margin_px or s.by + s.bh > W - struct_margin_px:
			return
	for s: Dictionary in local:
		gen.add_struct(s)
	for s: Dictionary in world:
		Structures.sync_struct(s, P)
		out.append(s)

static func _to_world(list: Array, ox: float, oy: float, c: Vector2i) -> Array:
	var out: Array = []
	for o: Dictionary in list:
		var w := o.duplicate()
		w.x = ox + float(o.x)
		w.y = oy + float(o.y)
		w["chunk"] = c
		out.append(w)
	return out

# --- the bake -----------------------------------------------------------------------------

func _gather(job: Dictionary) -> Dictionary:
	var c: Vector2i = job.c
	var rect: Rect2 = job.rect
	var grown := rect.grow(reach_px())
	var trees: Array = []
	var props: Array = []
	var structs: Array = []
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			var o := objects(Vector2i(cx, cy))
			for t: Dictionary in o.trees:
				if grown.has_point(Vector2(t.x, t.y)):
					trees.append(t.duplicate())
			for p: Dictionary in o.props:
				if grown.has_point(Vector2(p.x, p.y)):
					props.append(p.duplicate())
			for s: Dictionary in o.structs:
				if grown.intersects(Rect2(s.bx, s.by, s.bw, s.bh)):
					structs.append(s.duplicate())
	trees.sort_custom(tree_less)
	return {"data": {"trees": trees, "props": props, "structs": structs, "sprite_objects": props + structs + trees}}

func _ground(job: Dictionary) -> Dictionary:
	return {"data": {"g": record_ground(job.view, job.rect, job.size, job.c)}}

func _masks(job: Dictionary) -> Array:
	var out: Array = []
	for name: String in ["props", "structs", "trees"]:
		var m := new_mask(job.size, job.view)
		_cast_shadows(m, job.view, job.data[name])
		out.append(m)
	return out

func _frame(job: Dictionary) -> Array:
	var g: InkCanvas = job.data.g
	var view: Transform2D = job.view
	var masks: Array = job.data.masks
	composite_mask(g, masks[0])
	g.set_transform_matrix(view)
	for o: Dictionary in job.data.props:
		var s: float = o.half * 2.0
		g.draw_image(o.sprite, o.x - o.half, o.y - o.half, s, s)
	composite_mask(g, masks[1])
	for o: Dictionary in job.data.structs:
		g.draw_image(o.sprite, o.bx, o.by, o.bw, o.bh)
	composite_mask(g, masks[2])
	for o: Dictionary in job.data.trees:
		var s: float = o.half * 2.0
		g.draw_image(o.sprite, o.x - o.half, o.y - o.half, s, s)
	apply_grain(g)
	return [g]

# castShadows(list) onto mask `m` (holding the view transform): prism hulls
# for walls and houses, trunk strokes and stretched canopies for trees, three
# stepped copies for props (ink_renderer.gd's cast_shadows under a view).
func _cast_shadows(m: InkCanvas, view: Transform2D, list: Array) -> void:
	var az := (P.sunAz + 90.0) * PI / 180.0
	var dx := cos(az)
	var dy := sin(az)
	var L := 1.0 / tan(P.elev * PI / 180.0)
	var stretch := minf(P.canopy_shadow_stretch_max, 1.0 + L * 0.3)
	var sil := ShadowPass._silhouette_material()
	for o: Dictionary in list:
		if o.kind == "wall" or o.kind == "house":
			var shift := Vector2(dx * o.h * L, dy * o.h * L)
			m.begin_path()
			if o.kind == "house":
				for p: Dictionary in o.geo:
					_add_prism(m, to_v2(p.corners), shift)
			else:
				var Lp := to_v2(o.L)
				var Rp := to_v2(o.R)
				var n: int = o.pts.size()
				var lim := n if o.closed else n - 1
				for i in lim:
					var j := (i + 1) % n
					_add_prism(m, PackedVector2Array([Lp[i], Lp[j], Rp[j], Rp[i]]), shift)
				for cap: Array in o.caps:
					_add_prism(m, to_v2(cap), shift)
			m.fill()
			continue
		var off: float = o.h * L
		var sx: float = o.x + dx * off
		var sy: float = o.y + dy * off
		var half: float = o.half
		var s := half * 2.0
		if o.kind == "tree":
			m.line_width = maxf(1.5, o.r * 0.12)
			m.begin_path()
			m.move_to(o.x, o.y)
			m.line_to(sx, sy)
			m.stroke()
			m.save()
			m.set_transform_matrix(view * Transform2D(0.0, Vector2(sx, sy)) * Transform2D(az, Vector2.ZERO) \
				* Transform2D(Vector2(stretch, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) * Transform2D(-az, Vector2.ZERO))
			m.draw_image_with_material(o.sprite, -half, -half, s, s, sil)
			m.restore()
		else:
			for k in range(1, 4):
				var f := k / 3.0
				m.draw_image_with_material(o.sprite, o.x + dx * off * f - half, o.y + dy * off * f - half, s, s, sil)

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

# The prototype's tree order (h, then y), with x to make it total.
static func tree_less(a: Dictionary, b: Dictionary) -> bool:
	if a.h != b.h:
		return a.h < b.h
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x
