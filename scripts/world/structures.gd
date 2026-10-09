extends RefCounted

# Walls, ramparts and houses: the GEOMETRY half of the prototype's structures
# (reference/inkwood-renderer.html, "structures: walls / ramparts (centerline +
# width) and gable-roof houses"), ported for the scene generator. No canvases,
# no sprites: drawWall / drawHouse / castShadows belong to the drawing layer and
# read the fields these functions write.
#
#   prototype          here
#   rrectLocal         rrect_local
#   wallCenterline     wall_centerline
#   wallGeom           wall_geom
#   houseParts         house_parts       (+ house_tf, the parts' tf as a static)
#   makeHouse          make_house
#   makeWall           make_wall
#   makeFort           make_fort
#   syncStruct         sync_struct       (geometry, h, bounds -- not the canvas)
#   sDist              s_dist
#
# FLOAT64 END TO END. Every coordinate is a GDScript float (a double) and a
# point is an [x, y] Array of two floats, exactly the prototype's shape --
# never a Vector2, which is float32 and would round every value that s_dist
# then feeds into a placement decision. Math.hypot / cos / sin / atan2 are
# JsMath's (V8's own algorithms), the arithmetic is in the prototype's order of
# operations, and the result matches the browser bit for bit
# (scripts/tests/test_scene_gen.gd). Where a GDScript line has to differ from
# the JavaScript to keep that true, the comment says why; the usual reason is
# that `i/n` on two ints is integer division in GDScript and float division in
# JavaScript, so the int is cast.
#
# STRUCT DICTIONARIES carry the prototype's field names:
#   wall:  kind="wall", gen, ws, hs, closed, caps, seed, key
#          + (sync_struct / wall_geom) pts, nrm, L, R, hw, outline, edges, caps, h, bx, by, bw, bh
#   house: kind="house", x, y, rot, parts, hs, chimney, seed, key
#          + (sync_struct / house_parts) geo, h, bx, by, bw, bh
# gen is {type: "rrect", cx, cy, w, d, r, rot} | {type: "line", cx, cy, rot, lx,
# d, ringWs} | {type: "free", pts}. A house part is {ox, oy, w, d, r}; a geo
# entry is {cx, cy, w, d, cc, ss, tf, corners} with tf a Callable (lx, ly) ->
# [x, y], the prototype's closure; house_tf(part, lx, ly) is the same thing as a
# plain function. outline is an Array of point lists; edges an Array of
# {p: point list, closed: bool}.
#
# THE `caps` FIELD CHANGES TYPE, as in the prototype: makeWall's `caps` is a
# bool (draw round end caps on an open wall), and wallGeom's Object.assign
# overwrites it with the cap POLYGONS (an Array, empty for closed or capless
# walls), which is what castShadows iterates. wall_geom reads the flag with
# JavaScript truthiness (an Array, even an empty one, is true) so a second
# wall_geom on the same struct behaves as the prototype's does -- which is to
# say, a capless wall grows caps on re-sync. That is a prototype quirk, ported
# rather than fixed: sync_struct only re-runs geometry when its key changes.

const JsMath = preload("res://scripts/core/js_math.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

# --- rounded rectangle ---------------------------------------------------------

# function rrectLocal(w,d,r,step): a rounded rectangle centred on the origin,
# walked clockwise from the top edge, about `step` px between points.
static func rrect_local(w: float, d: float, r: float, step: float) -> Array:
	var pts: Array = []
	var hx := w / 2.0
	var hy := d / 2.0
	_rr_seg(pts, -hx + r, -hy, hx - r, -hy, step)
	_rr_arc(pts, hx - r, -hy + r, -PI / 2.0, r, step)
	_rr_seg(pts, hx, -hy + r, hx, hy - r, step)
	_rr_arc(pts, hx - r, hy - r, 0.0, r, step)
	_rr_seg(pts, hx - r, hy, -hx + r, hy, step)
	_rr_arc(pts, -hx + r, hy - r, PI / 2.0, r, step)
	_rr_seg(pts, -hx, hy - r, -hx, -hy + r, step)
	_rr_arc(pts, -hx + r, -hy + r, PI, r, step)
	return pts

# seg=(x0,y0,x1,y1)=>{const n=Math.max(1,Math.ceil(Math.hypot(x1-x0,y1-y0)/step));
#   for(let i=0;i<n;i++){const t=i/n;pts.push([x0+(x1-x0)*t,y0+(y1-y0)*t]);}}
static func _rr_seg(pts: Array, x0: float, y0: float, x1: float, y1: float, step: float) -> void:
	var n: int = maxi(1, ceili(JsMath.hypot(x1 - x0, y1 - y0) / step))
	for i in n:
		var t: float = float(i) / n
		pts.append([x0 + (x1 - x0) * t, y0 + (y1 - y0) * t])

# arc=(cx,cy,a0)=>{const n=Math.max(2,Math.ceil(r*Math.PI/2/step));
#   for(let i=0;i<n;i++){const a=a0+i/n*Math.PI/2;pts.push([cx+Math.cos(a)*r,cy+Math.sin(a)*r]);}}
static func _rr_arc(pts: Array, cx: float, cy: float, a0: float, r: float, step: float) -> void:
	var n: int = maxi(2, ceili(r * PI / 2.0 / step))
	for i in n:
		var a: float = a0 + float(i) / n * PI / 2.0
		pts.append([cx + JsMath.cos(a) * r, cy + JsMath.sin(a) * r])

# --- walls -------------------------------------------------------------------------

# function wallCenterline(s): the wall's centre line in world space.
static func wall_centerline(s: Dictionary, P: RenderParams) -> Array:
	var g: Dictionary = s.gen
	if g.type == "free":
		return g.pts
	var c: float = JsMath.cos(g.rot)
	var sn: float = JsMath.sin(g.rot)
	# tf=q=>[g.cx+q[0]*c-q[1]*sn, g.cy+q[0]*sn+q[1]*c]
	var local: Array
	if g.type == "rrect":
		local = rrect_local(g.w, g.d, g.r, 3.0)
	else:
		# divider: spans the ring's inner edge to inner edge, overlapping it
		# slightly so the T-junction merges.
		#   const y=g.d/2-P.wallW*g.ringWs/2+2.5, pts=[];
		#   const n=Math.max(2,Math.ceil(2*y/3)); for(let i=0;i<=n;i++) pts.push([g.lx,-y+2*y*i/n]);
		var y: float = g.d / 2.0 - P.wallW * g.ringWs / 2.0 + 2.5
		var n: int = maxi(2, ceili(2.0 * y / 3.0))
		local = []
		for i in n + 1:
			local.append([g.lx, -y + 2.0 * y * i / n])
	var cx: float = g.cx
	var cy: float = g.cy
	var out: Array = []
	for q: Array in local:
		out.append([cx + q[0] * c - q[1] * sn, cy + q[0] * sn + q[1] * c])
	return out

# JavaScript truthiness of the `caps` field (see the header).
static func _truthy(v: Variant) -> bool:
	if v is bool:
		return v
	return v != null

# function wallGeom(s): the two wobbled edges either side of the centre line,
# the per-sample normals, the fill outline, the stroked edges and the end caps.
static func wall_geom(s: Dictionary, P: RenderParams) -> void:
	var pts: Array = wall_centerline(s, P)
	var n := pts.size()
	var hw: float = P.wallW * s.ws / 2.0
	var closed: bool = s.closed
	var seed_value: int = s.seed
	var nrm: Array = []
	var Lp: Array = []
	var Rp: Array = []
	for i in n:
		var a: Array = pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b: Array = pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var tx: float = b[0] - a[0]
		var ty: float = b[1] - a[1]
		# l=Math.hypot(tx,ty)||1 -- `||` replaces 0 (and NaN) with 1.
		var l: float = JsMath.hypot(tx, ty)
		if l == 0.0 or is_nan(l):
			l = 1.0
		var nx: float = -ty / l
		var ny: float = tx / l
		# `i*.18`: i is an int here and a double there; int * float promotes, same value.
		var eL: float = (ValueNoise.vnoise(i * 0.18, 1.3, seed_value) * 2.0 - 1.0) * P.wob * 1.3
		var eR: float = (ValueNoise.vnoise(i * 0.18, 5.1, seed_value) * 2.0 - 1.0) * P.wob * 1.3
		var p: Array = pts[i]
		nrm.append([nx, ny])
		Lp.append([p[0] + nx * (hw + eL), p[1] + ny * (hw + eL)])
		Rp.append([p[0] - nx * (hw + eR), p[1] - ny * (hw + eR)])
	var outline: Array
	var edges: Array
	var caps: Array = []
	if closed:
		outline = [Lp, Rp]
		edges = [{"p": Lp, "closed": true}, {"p": Rp, "closed": true}]
	elif _truthy(s.caps):
		var a0: float = JsMath.atan2(nrm[n - 1][1], nrm[n - 1][0])
		var a1: float = JsMath.atan2(nrm[0][1], nrm[0][0])
		var ce: Array = _cap(pts, n - 1, a0, hw)
		var cs: Array = _cap(pts, 0, a1 + PI, hw)
		var rev: Array = Rp.duplicate()
		rev.reverse()
		var loop: Array = Lp + ce + rev + cs
		outline = [loop]
		edges = [{"p": loop, "closed": true}]
		caps = [ce + [Lp[n - 1], Rp[n - 1]], cs + [Lp[0], Rp[0]]]
	else:
		var rev: Array = Rp.duplicate()
		rev.reverse()
		outline = [Lp + rev]
		edges = [{"p": Lp, "closed": false}, {"p": Rp, "closed": false}]
	# Object.assign(s,{pts,nrm,L:Lp,R:Rp,hw,outline,edges,caps});
	s.pts = pts
	s.nrm = nrm
	s.L = Lp
	s.R = Rp
	s.hw = hw
	s.outline = outline
	s.edges = edges
	s.caps = caps

# cap=(i,startAng)=>{const c=[];for(let k=1;k<8;k++){const a=startAng-k*Math.PI/8;
#   c.push([pts[i][0]+Math.cos(a)*hw,pts[i][1]+Math.sin(a)*hw]);}return c;};
static func _cap(pts: Array, i: int, start_ang: float, hw: float) -> Array:
	var c: Array = []
	var p: Array = pts[i]
	for k in range(1, 8):
		var a: float = start_ang - k * PI / 8.0
		c.append([p[0] + JsMath.cos(a) * hw, p[1] + JsMath.sin(a) * hw])
	return c

# function makeWall(rng,gen,o): the defaults, a seed minted from rng, then o's
# overrides on top (Object.assign).
static func make_wall(rng: Mulberry32, gen: Dictionary, o: Dictionary) -> Dictionary:
	var s := {"kind": "wall", "gen": gen, "ws": 1.0, "hs": 1.0, "closed": false, "caps": true,
		"seed": rng.next_seed(), "key": ""}
	s.merge(o, true)
	return s

# function makeFort(rng,x,y,size,rot): a rounded-rectangle ring, a divider wall
# across it and, four times in five, a smaller inner ring in the left cell.
# The rng() calls happen in this order: Df, ring seed, lx, divider seed, the
# inner-ring roll, inner seed -- the roll is drawn before the size tests, as
# `rng()<.8&&cellW>24&&cellD>20` evaluates left to right.
static func make_fort(rng: Mulberry32, x: float, y: float, size: float, rot: float, P: RenderParams) -> Array:
	var Wf: float = size
	var Df: float = size * (0.55 + rng.next() * 0.1)
	var r: float = minf(Df * 0.28, 26.0)
	var c: float = JsMath.cos(rot)
	var sn: float = JsMath.sin(rot)
	var out: Array = [make_wall(rng, {"type": "rrect", "cx": x, "cy": y, "w": Wf, "d": Df, "r": r, "rot": rot},
		{"closed": true, "caps": false})]
	var lx: float = -Wf * (0.06 + rng.next() * 0.14)
	out.append(make_wall(rng, {"type": "line", "cx": x, "cy": y, "rot": rot, "lx": lx, "d": Df, "ringWs": 1.0},
		{"ws": 0.85, "hs": 0.9, "caps": false}))
	var cellW: float = lx + Wf / 2.0 - P.wallW * 1.6 - 10.0
	var cellD: float = Df - P.wallW * 1.6 - 12.0
	var roll: float = rng.next()
	if roll < 0.8 and cellW > 24.0 and cellD > 20.0:
		var lcx: float = (-Wf / 2.0 + lx) / 2.0
		out.append(make_wall(rng, {"type": "rrect", "cx": x + lcx * c, "cy": y + lcx * sn, "w": cellW, "d": cellD,
			"r": minf(8.0, cellD * 0.25), "rot": rot}, {"closed": true, "caps": false, "ws": 0.5, "hs": 0.45}))
	return out

# --- houses ------------------------------------------------------------------------

# function houseParts(s): each part's centre, size, rotation (as cos/sin) and
# world-space corners. S = P.houseSize scales the unit-sized parts.
static func house_parts(s: Dictionary, P: RenderParams) -> Array:
	var S: float = P.houseSize
	var rot0: float = s.rot
	var c: float = JsMath.cos(rot0)
	var sn: float = JsMath.sin(rot0)
	var sx: float = s.x
	var sy: float = s.y
	var geo: Array = []
	for p: Dictionary in s.parts:
		var cx: float = sx + (p.ox * c - p.oy * sn) * S
		var cy: float = sy + (p.ox * sn + p.oy * c) * S
		var rot: float = rot0 + p.r
		var w: float = p.w * S
		var d: float = p.d * S
		var cc: float = JsMath.cos(rot)
		var ss: float = JsMath.sin(rot)
		# tf=(lx,ly)=>[cx+lx*cc-ly*ss,cy+lx*ss+ly*cc]
		var tf := func(lx: float, ly: float) -> Array:
			return [cx + lx * cc - ly * ss, cy + lx * ss + ly * cc]
		var part := {"cx": cx, "cy": cy, "w": w, "d": d, "cc": cc, "ss": ss, "tf": tf}
		part.corners = [house_tf(part, -w / 2.0, -d / 2.0), house_tf(part, w / 2.0, -d / 2.0),
			house_tf(part, w / 2.0, d / 2.0), house_tf(part, -w / 2.0, d / 2.0)]
		geo.append(part)
	return geo

# A geo part's tf as a plain function: part-local (lx, ly) to world [x, y].
static func house_tf(part: Dictionary, lx: float, ly: float) -> Array:
	var cx: float = part.cx
	var cy: float = part.cy
	var cc: float = part.cc
	var ss: float = part.ss
	return [cx + lx * cc - ly * ss, cy + lx * ss + ly * cc]

# function makeHouse(rng,x,y,rot): a main block and, three times in five, a
# wing at right angles. rng() order: main w, main d, the wing roll, (wing d2,
# w2, side), hs, chimney, seed -- object literals evaluate in source order.
static func make_house(rng: Mulberry32, x: float, y: float, rot: float) -> Dictionary:
	var w0: float = 1.3 + rng.next() * 0.5
	var d0: float = 0.72 + rng.next() * 0.15
	var parts: Array = [{"ox": 0.0, "oy": 0.0, "w": w0, "d": d0, "r": 0.0}]
	if rng.next() < 0.6:
		var m: Dictionary = parts[0]
		var d2: float = 0.55 + rng.next() * 0.12
		var w2: float = 0.8 + rng.next() * 0.35
		var side: float = -1.0 if rng.next() < 0.5 else 1.0
		parts.append({"ox": m.w / 2.0 - d2 / 2.0 - 0.05, "oy": side * (m.d / 2.0 + w2 / 2.0 - 0.25),
			"w": w2, "d": d2, "r": PI / 2.0})
	var hs: float = 0.85 + rng.next() * 0.3
	var chimney: bool = rng.next() < 0.6
	var seed_value: int = rng.next_seed()
	return {"kind": "house", "x": x, "y": y, "rot": rot, "parts": parts, "hs": hs, "chimney": chimney,
		"seed": seed_value, "key": ""}

# --- both ----------------------------------------------------------------------------

# function syncStruct(s), the geometry half: h (the prism height the shadow
# pass extrudes by), the wall or house geometry, and the sprite bounds bx, by,
# bw, bh (the outline's box grown by 6 px, floored and ceiled to whole px). The
# canvas it then draws is the drawing layer's. Geometry is recomputed only when
# the key changes, as in the prototype; the key's members are the prototype's
# (the drawing layer's sprite cache keys on it too).
static func sync_struct(s: Dictionary, P: RenderParams) -> void:
	var key := "%s|%s|%s|%s|%s|%s" % [P.lw, P.wob, P.sunAz, P.wallW, P.houseSize, P.shadowCol.to_html(false)]
	s.h = (P.wallH if s.kind == "wall" else P.houseSize * 0.9) * s.hs
	if key == s.get("key", ""):
		return
	s.key = key
	var pts: Array
	if s.kind == "wall":
		wall_geom(s, P)
		pts = s.L + s.R
	else:
		s.geo = house_parts(s, P)
		pts = []
		for part: Dictionary in s.geo:
			pts.append_array(part.corners)
	var x0 := 1e9
	var y0 := 1e9
	var x1 := -1e9
	var y1 := -1e9
	for p: Array in pts:
		x0 = minf(x0, p[0])
		y0 = minf(y0, p[1])
		x1 = maxf(x1, p[0])
		y1 = maxf(y1, p[1])
	x0 = floorf(x0 - 6.0)
	y0 = floorf(y0 - 6.0)
	x1 = ceilf(x1 + 6.0)
	y1 = ceilf(y1 + 6.0)
	s.bx = x0
	s.by = y0
	s.bw = x1 - x0
	s.bh = y1 - y0

# function sDist(s,x,y): signed-ish distance from (x, y) to the structure --
# for a wall, to the nearest centre-line sample less the half width; for a
# house, the box SDF of the nearest part. canPlace rejects an object closer
# than 0.6 of its collision radius, and addStruct clears objects the same way,
# so this is a decision function: every hypot in it is V8's.
static func s_dist(s: Dictionary, x: float, y: float) -> float:
	var m := 1e9
	if s.kind == "wall":
		for p: Array in s.pts:
			var d: float = JsMath.hypot(p[0] - x, p[1] - y)
			if d < m:
				m = d
		return m - s.hw
	for p: Dictionary in s.geo:
		var dx: float = x - p.cx
		var dy: float = y - p.cy
		var lx: float = dx * p.cc + dy * p.ss
		var ly: float = -dx * p.ss + dy * p.cc
		var qx: float = absf(lx) - p.w / 2.0
		var qy: float = absf(ly) - p.d / 2.0
		var d: float = JsMath.hypot(maxf(qx, 0.0), maxf(qy, 0.0)) + minf(maxf(qx, qy), 0.0)
		if d < m:
			m = d
	return m
