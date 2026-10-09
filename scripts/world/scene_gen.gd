extends RefCounted

# Scene generation, ported from the prototype (reference/inkwood-renderer.html):
# which objects exist, where, with which seeds and geometry -- everything BEFORE
# drawing. newScene, buildRoad, the object model (makeTree, makeProp, syncTree,
# cr, maxCr), the spatial hash (gAdd, gRebuild, gQuery), roadDist, canPlace and
# addStruct live here; the structures' geometry is in structures.gd.
#
#   var gen := SceneGen.new(1280.0, 720.0, RenderParams.new())   # resize(): W, H, buildRoad()
#   gen.generate(20261009)                                       # newScene(20261009)
#   gen.trees / gen.props / gen.structs / gen.roadPts / gen.grid
#
# SAME SEED, SAME SCENE, BIT FOR BIT. scripts/tests/test_scene_gen.gd compares
# every tree, prop, struct and road sample against what the prototype's own
# code produces under node (reference/port_check/prototype_scene.js). That
# holds because:
#   - all of it runs in float64: GDScript floats, [x, y] Arrays of floats,
#     PackedFloat64Array. NEVER Vector2 (float32 in a standard build) anywhere
#     a value feeds a decision -- canPlace, roadDist, sDist, the grid. Vector2
#     is the drawing layer's, converted at its boundary;
#   - the arithmetic is in the prototype's order of operations, one double
#     rounding per operator, as in JavaScript;
#   - Math.hypot / cos / sin / atan2 / round are JsMath's, V8's algorithms;
#   - ONE mulberry32 stream is threaded through the whole scene in the
#     prototype's order: makeFort's two placement draws, makeFort (and the
#     makeWall seeds inside it), the house, 70 prop darts, then W*H/75 tree
#     darts. makeTree and makeProp consume the stream BEFORE canPlace decides,
#     so a rejected dart still uses its draws. Sub-generators (each tree, prop,
#     wall, house) get their own seed from `(rng()*2147483647)|0`, which is
#     Mulberry32.next_seed().
#
# OBJECTS ARE DICTIONARIES WITH THE PROTOTYPE'S FIELD NAMES, so drawing code
# ports line for line:
#   tree:  kind="tree", x, y, seed, sr, hr, big, r, h, key
#   prop:  kind="prop", x, y, type ("rock" | "barrel" | "crate"), s, rot, seed, h, key
#   wall / house: see structures.gd
#   roadPts[i]: {x, y, nx, ny} -- the sample and its unit normal
# Points are [x, y] Arrays of two floats throughout. `key` is the prototype's
# sprite-cache key, left "" here: building sprites (and setting key, sprite,
# half) is the drawing layer's syncTree / syncProp. sync_tree below is the
# geometry half only: r and h.
#
# The generator's own numbers (70 prop darts, the .006 density scale, the fort
# and house placement fractions, the road's control points) are the
# prototype's formulas and stay in the code as its literals, each next to the
# line it ports; the tunable values (P.*, CELL, ROAD_HALF, the big-tree and
# collision constants, the prop mix) come from data/params/render_defaults.json
# through RenderParams.
#
# grid: the prototype keys cells by the string "cx,cy"; here the key is
# Vector2i(cx, cy). Cell indices are small integers, exact in int32, so the
# key type changes nothing about which objects share a cell or the order they
# were added in.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const JsMath = preload("res://scripts/core/js_math.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Structures = preload("res://scripts/world/structures.gd")

var W: float = 0.0
var H: float = 0.0
var P: RenderParams
var trees: Array = []
var props: Array = []
var structs: Array = []
var grid: Dictionary = {}    # Vector2i -> Array of trees and props
var roadPts: Array = []      # {x, y, nx, ny}
var sceneSeed: int = 1

# roadPts' x, y as flat pairs: the same doubles, laid out for roadDist's inner
# loop, which runs over every road sample for every dart that reaches it.
var _road_xy := PackedFloat64Array()

# resize() for the scene half: the stage size, then buildRoad(). (The ground
# and grain canvases it also rebuilds are the drawing layer's.)
func _init(w: float, h: float, params: RenderParams) -> void:
	W = w
	H = h
	P = params
	build_road()

# --- object model ----------------------------------------------------------------

# function makeTree(rng,x,y){return {kind:"tree",x,y,seed:(rng()*2147483647)|0,
#   sr:rng()*2-1,hr:rng(),big:rng()<.1,r:0,h:0,key:""};}
func make_tree(rng: Mulberry32, x: float, y: float) -> Dictionary:
	var seed_value: int = rng.next_seed()
	var sr: float = rng.next() * 2.0 - 1.0
	var hr: float = rng.next()
	var big: bool = rng.next() < P.big_tree_chance
	return {"kind": "tree", "x": x, "y": y, "seed": seed_value, "sr": sr, "hr": hr, "big": big,
		"r": 0.0, "h": 0.0, "key": ""}

# function makeProp(rng,x,y){const u=rng(), type=u<.5?"rock":u<.8?"barrel":"crate",
#   s=type==="rock"?2.2+rng()*3.6:3+rng()*2.2;
#   return {kind:"prop",x,y,type,s,rot:rng()*Math.PI*2,seed:(rng()*2147483647)|0,
#     h:s*(type==="rock"?.8:type==="barrel"?1.5:1.3),key:""};}
# The .5 / .8 thresholds are the cumulative prop mix from data (0.5 + 0.3 is
# exactly the double 0.8).
func make_prop(rng: Mulberry32, x: float, y: float) -> Dictionary:
	var u: float = rng.next()
	var rock: float = P.prop_mix["rock"]
	var type: String = "rock" if u < rock else ("barrel" if u < rock + P.prop_mix["barrel"] else "crate")
	# One draw for the size whichever branch: written as an if so that is
	# visible rather than resting on the conditional expression's laziness.
	var s: float
	if type == "rock":
		s = 2.2 + rng.next() * 3.6
	else:
		s = 3.0 + rng.next() * 2.2
	var rot: float = rng.next() * PI * 2.0
	var seed_value: int = rng.next_seed()
	var h: float = s * (0.8 if type == "rock" else (1.5 if type == "barrel" else 1.3))
	return {"kind": "prop", "x": x, "y": y, "type": type, "s": s, "rot": rot, "seed": seed_value, "h": h, "key": ""}

# function syncTree(t), the geometry half:
#   t.r=P.treeSize*(1+P.sizeVar*t.sr)*(t.big?1.45:1); t.h=t.r*P.height*(.85+.3*t.hr);
func sync_tree(t: Dictionary) -> void:
	t.r = P.treeSize * (1.0 + P.sizeVar * t.sr) * (P.big_tree_scale if t.big else 1.0)
	t.h = t.r * P.height * (0.85 + 0.3 * t.hr)

# const cr=o=>o.kind==="tree"?o.r*.72:o.s*1.25;  -- an object's collision radius.
func cr(o: Dictionary) -> float:
	if o.kind == "tree":
		return o.r * P.tree_collision_radius
	return o.s * P.prop_collision_radius

# const maxCr=()=>Math.max(P.treeSize*(1+P.sizeVar)*1.45*.72,10);
# The largest collision radius any object can have: how far gQuery must look.
func max_cr() -> float:
	return maxf(P.treeSize * (1.0 + P.sizeVar) * P.big_tree_scale * P.tree_collision_radius, 10.0)

# --- structures ----------------------------------------------------------------------

# function addStruct(s): geometry, then (collision on) clear every tree and
# prop the structure now covers, and rebuild the grid.
func add_struct(s: Dictionary) -> void:
	Structures.sync_struct(s, P)
	structs.append(s)
	if P.collide:
		var keep := func(o: Dictionary) -> bool: return Structures.s_dist(s, o.x, o.y) > cr(o) * 0.6
		trees = trees.filter(keep)
		props = props.filter(keep)
		g_rebuild()

# --- spatial hash (the red grid in the reference) ------------------------------------

func _cell(x: float, y: float) -> Vector2i:
	return Vector2i(floori(x / P.CELL), floori(y / P.CELL))

# function gAdd(o){const k=Math.floor(o.x/CELL)+","+Math.floor(o.y/CELL); ... a.push(o);}
func g_add(o: Dictionary) -> void:
	var k := _cell(o.x, o.y)
	if not grid.has(k):
		grid[k] = []
	(grid[k] as Array).append(o)

# function gRebuild(){grid=new Map(); trees.forEach(gAdd); props.forEach(gAdd);}
func g_rebuild() -> void:
	grid = {}
	for t: Dictionary in trees:
		g_add(t)
	for p: Dictionary in props:
		g_add(p)

# function gQuery(x,y,rad,fn): call fn(o) for every object in the cells that
# the box [x-rad, x+rad] x [y-rad, y+rad] touches, column by column.
func g_query(x: float, y: float, rad: float, fn: Callable) -> void:
	var c0 := floori((x - rad) / P.CELL)
	var c1 := floori((x + rad) / P.CELL)
	var r0 := floori((y - rad) / P.CELL)
	var r1 := floori((y + rad) / P.CELL)
	for cx in range(c0, c1 + 1):
		for cy in range(r0, r1 + 1):
			var a: Variant = grid.get(Vector2i(cx, cy))
			if a != null:
				for o: Dictionary in a:
					fn.call(o)

# --- placement -------------------------------------------------------------------------

# function roadDist(x,y){let m=1e9; for(const p of roadPts){const dx=p.x-x,dy=p.y-y,
#   d=dx*dx+dy*dy; if(d<m)m=d;} return Math.sqrt(m);}
# sqrt is IEEE-exact in both, so this one needs no JsMath.
func road_dist(x: float, y: float) -> float:
	var m := 1e9
	var xy := _road_xy
	for i in range(0, xy.size(), 2):
		var dx: float = xy[i] - x
		var dy: float = xy[i + 1] - y
		var d: float = dx * dx + dy * dy
		if d < m:
			m = d
	return sqrt(m)

# function canPlace(x,y,c,force): inside the stage (10 px slack); then, when
# collision is on or forced: off the road, clear of every structure, and not
# overlapping any tree or prop.
func can_place(x: float, y: float, c: float, force: bool) -> bool:
	if x < -10.0 or y < -10.0 or x > W + 10.0 or y > H + 10.0:
		return false
	if not (force or P.collide):
		return true
	if P.L.road and road_dist(x, y) < P.ROAD_HALF + c * 0.6:
		return false
	for s: Dictionary in structs:
		if Structures.s_dist(s, x, y) < c * 0.6:
			return false
	# gQuery(x,y,c+maxCr(),o=>{ if(!ok) return; const dx=o.x-x,dy=o.y-y,rr=c+cr(o);
	#   if(dx*dx+dy*dy<rr*rr) ok=false; });
	# Inlined rather than a Callable per object (the lambda costs more than the
	# test); the cells and the test are gQuery's, and the first hit decides.
	var rad: float = c + max_cr()
	var c0 := floori((x - rad) / P.CELL)
	var c1 := floori((x + rad) / P.CELL)
	var r0 := floori((y - rad) / P.CELL)
	var r1 := floori((y + rad) / P.CELL)
	for cx in range(c0, c1 + 1):
		for cy in range(r0, r1 + 1):
			var a: Variant = grid.get(Vector2i(cx, cy))
			if a == null:
				continue
			for o: Dictionary in a:
				var dx: float = o.x - x
				var dy: float = o.y - y
				var rr: float = c + cr(o)
				if dx * dx + dy * dy < rr * rr:
					return false
	return true

# --- road ---------------------------------------------------------------------------------

# function buildRoad(): a Catmull-Rom spline through five control points given
# as fractions of the stage, sampled about every 3 px, then a unit normal per
# sample from its neighbours (one-sided at the ends):
#   const a=pts[Math.max(i-1,0)],b=pts[Math.min(i+1,pts.length-1)],tx=b.x-a.x,ty=b.y-a.y,
#     l=Math.hypot(tx,ty)||1; pts[i].nx=-ty/l; pts[i].ny=tx/l;
func build_road() -> void:
	var c := PackedFloat64Array()
	for p: Array in [[-0.1, 0.86], [0.2, 0.77], [0.47, 0.84], [0.75, 0.71], [1.1, 0.64]]:
		c.append(p[0] * W)
		c.append(p[1] * H)
	var xy := Geometry.catmull_rom_f64(c, 3.0)
	var n := xy.size() / 2
	var pts: Array = []
	for i in n:
		var a := maxi(i - 1, 0) * 2
		var b := mini(i + 1, n - 1) * 2
		var tx: float = xy[b] - xy[a]
		var ty: float = xy[b + 1] - xy[a + 1]
		var l: float = JsMath.hypot(tx, ty)
		if l == 0.0 or is_nan(l):
			l = 1.0
		pts.append({"x": xy[i * 2], "y": xy[i * 2 + 1], "nx": -ty / l, "ny": tx / l})
	roadPts = pts
	_road_xy = xy

# --- scene -------------------------------------------------------------------------------

# function newScene(seed)
func generate(seed_value: int) -> void:
	sceneSeed = seed_value
	trees = []
	props = []
	structs = []
	grid = {}
	var rng := Mulberry32.new(seed_value)
	# tries=Math.round(W*H/75)
	var tries: int = int(JsMath.round(W * H / 75.0))
	# fs=Math.min(W*.78,H*.5,340)
	var fs: float = minf(minf(W * 0.78, H * 0.5), 340.0)

	# makeFort(rng,W*(.45+rng()*.1),H*.3,fs,-.35+(rng()-.5)*.4).forEach(addStruct);
	# JavaScript evaluates the arguments left to right; taken into locals so
	# the order of the two draws is explicit.
	var fx: float = W * (0.45 + rng.next() * 0.1)
	var fy: float = H * 0.3
	var frot: float = -0.35 + (rng.next() - 0.5) * 0.4
	for s: Dictionary in Structures.make_fort(rng, fx, fy, fs, frot, P):
		add_struct(s)

	if roadPts.size() > 0:
		# const c=roadPts[Math.floor(roadPts.length*(.66+rng()*.12))], off=ROAD_HALF+P.houseSize*1.5;
		# addStruct(makeHouse(rng,c.x-c.nx*off,c.y-c.ny*off,Math.atan2(-c.nx,c.ny)));
		var c: Dictionary = roadPts[floori(roadPts.size() * (0.66 + rng.next() * 0.12))]
		var off: float = P.ROAD_HALF + P.houseSize * 1.5
		add_struct(Structures.make_house(rng, c.x - c.nx * off, c.y - c.ny * off, JsMath.atan2(-c.nx, c.ny)))

	if roadPts.size() > 0:
		# const c=roadPts[Math.floor(roadPts.length*.42)], cx=c.x-c.nx*48, cy=c.y-c.ny*48;
		var c: Dictionary = roadPts[floori(roadPts.size() * 0.42)]
		var cx: float = c.x - c.nx * 48.0
		var cy: float = c.y - c.ny * 48.0
		for i in 70:
			# const a=rng()*Math.PI*2, d=Math.sqrt(rng())*52, x=cx+Math.cos(a)*d, y=cy+Math.sin(a)*d*.8;
			var a: float = rng.next() * PI * 2.0
			var d: float = sqrt(rng.next()) * 52.0
			var x: float = cx + JsMath.cos(a) * d
			var y: float = cy + JsMath.sin(a) * d * 0.8
			var p := make_prop(rng, x, y)
			if can_place(x, y, cr(p), true):
				props.append(p)
				g_add(p)

	var density_seed: int = seed_value % 9973 + 3
	for i in tries:
		# const x=rng()*W,y=rng()*H, f=fbm(x*.006,y*.006,seed%9973+3,3);
		# if(f<.5||rng()>(f-.5)*3.2) continue;   -- the second draw only when f >= .5
		var x: float = rng.next() * W
		var y: float = rng.next() * H
		var f: float = ValueNoise.fbm(x * 0.006, y * 0.006, density_seed, 3)
		if f < 0.5 or rng.next() > (f - 0.5) * 3.2:
			continue
		var t := make_tree(rng, x, y)
		sync_tree(t)
		if can_place(x, y, cr(t), true):
			trees.append(t)
			g_add(t)

# The prototype's status line: "N trees · M props · K structures".
func count_line() -> String:
	return "%d trees, %d props, %d structures" % [trees.size(), props.size(), structs.size()]
