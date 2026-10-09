extends RefCounted

# Walls and houses, the drawing half, ported line for line from the
# prototype (reference/inkwood-renderer.html) onto InkCanvas:
#
#   prototype               here
#   addPoly(g,p,closed)     add_poly(g, p, closed)          (p: PackedVector2Array or [x, y] Arrays)
#   mix(a,b,t)              mix(a, b, t)                    (Colors; channels rounded as the prototype does)
#   shadowDir()             shadow_dir(P) -> Vector2
#   drawWall(g,s)           draw_wall(g, s, P, rng = null)
#   drawHouse(g,s)          draw_house(g, s, P, rng = null)
#   syncStruct's canvas     build_struct_sprite(s, P) -> InkCanvas (unrendered), sized bw x bh at (bx, by)
#
# The GEOMETRY (wallGeom, houseParts, the bounds bx/by/bw/bh, the prism
# height h) is scripts/world/structures.gd's: sync_struct fills s.pts, s.nrm,
# s.L, s.R, s.hw, s.outline, s.edges, s.caps for a wall and s.geo for a house,
# as float64 [x, y] Arrays with the prototype's field names. This file only
# reads them.
#
# THE RNG STREAM: drawWall and drawHouse each draw from their own
# mulberry32(s.seed) in the prototype's order. Several draws sit behind a
# geometric test (`if(f<.2||rng()>.85)` draws only when the slope faces away
# from the sun), so those tests are made on the float64 normals scene
# generation wrote, not on float32 copies -- the decision, not the pixel, is
# what keeps the stream aligned. The pixels are drawn from Vector2.
#
# Colour mixes and line weights: the shaded roof is mix(P.shadowCol, ROOF, .58)
# and the wall slope mix(P.shadowCol, WALL, .7) in the prototype; data carries
# them as the SHADOW's share (palette.roof_shaded_shadow_mix 0.42,
# palette.wall_slope_shadow_mix 0.30), read here from the params file because
# RenderParams does not expose them (see palette_extras). Wall edges (1.15)
# and the house outline (1.2) come from P.linework; the other multipliers are
# the prototype's literals, each on its line.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Structures = preload("res://scripts/world/structures.gd")

# palette.* entries RenderParams does not expose, read once per params file.
static var _extras: Dictionary = {}

# {roof_shaded_shadow_mix, wall_slope_shadow_mix} from P's own data file.
static func palette_extras(P: RenderParams) -> Dictionary:
	if not _extras.has(P.source_path):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(P.source_path))
		var pal: Dictionary = (raw as Dictionary).get("palette", {}) if raw is Dictionary else {}
		var out := {}
		for k: String in ["roof_shaded_shadow_mix", "wall_slope_shadow_mix"]:
			var v: Variant = pal.get(k)
			if v is float or v is int:
				out[k] = float(v)
			else:
				push_error("InkStructs: palette.%s missing in %s" % [k, P.source_path])
				out[k] = NAN
		_extras[P.source_path] = out
	return _extras[P.source_path]

# function addPoly(g,p,closed){g.moveTo(p[0][0],p[0][1]);for(...)g.lineTo(p[i][0],p[i][1]);if(closed)g.closePath();}
static func add_poly(g: InkCanvas, p: Variant, closed: bool) -> void:
	if p is PackedVector2Array:
		var v: PackedVector2Array = p
		g.move_to(v[0].x, v[0].y)
		for i in range(1, v.size()):
			g.line_to(v[i].x, v[i].y)
	else:
		var a: Array = p
		g.move_to(a[0][0], a[0][1])
		for i in range(1, a.size()):
			g.line_to(a[i][0], a[i][1])
	if closed:
		g.close_path()

# const mix=(a,b,t)=>{...`rgb(${pa.map((v,i)=>Math.round(v+(pb[i]-v)*t))})`};
# Each channel is rounded to an integer, as the prototype's rgb() string does.
static func mix(a: Color, b: Color, t: float) -> Color:
	return Color8(roundi(a.r8 + (b.r8 - a.r8) * t), roundi(a.g8 + (b.g8 - a.g8) * t), roundi(a.b8 + (b.b8 - a.b8) * t))

# function shadowDir(){const az=(P.sunAz+90)*Math.PI/180; return [Math.cos(az),Math.sin(az)];}
static func shadow_dir(P: RenderParams) -> Vector2:
	var az := (P.sunAz + 90.0) * PI / 180.0
	return Vector2(cos(az), sin(az))

# [x, y] Arrays -> PackedVector2Array, for drawing (and the shadow pass's hulls).
static func to_v2(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = Vector2(pts[i][0], pts[i][1])
	return out

# --- walls ------------------------------------------------------------------------

# function drawWall(g,s): the rampart band, its tonal slope away from the sun,
# stipple, hatching down the shaded slope, a broken double crest line, the
# outer edges, and pebbles breaking up the edges.
static func draw_wall(g: InkCanvas, s: Dictionary, P: RenderParams, rng: Mulberry32 = null) -> void:
	if rng == null:
		rng = Mulberry32.new(s.seed)  # const rng=mulberry32(s.seed)
	var pts: Array = s.pts  # {pts,nrm,L:Lp,R:Rp,hw}=s  -- float64 [x, y] Arrays
	var nrm: Array = s.nrm
	var Lp: Array = s.L
	var Rp: Array = s.R
	var hw: float = s.hw
	var n := pts.size()
	var sd := shadow_dir(P)  # [sdx,sdy]=shadowDir()
	var sdx: float = sd.x
	var sdy: float = sd.y
	var closed: bool = s.closed
	var lim := n if closed else n - 1
	var Lv := to_v2(Lp)
	var Rv := to_v2(Rp)
	g.line_cap = "round"  # g.lineJoin="round"; g.lineCap="round";
	# g.beginPath(); s.outline.forEach(o=>addPoly(g,o,true)); g.fillStyle=WALL; g.fill("evenodd");
	# The even-odd outline is fill_band (ink_canvas.gd): the two rings of a
	# closed wall, or L + end cap + reversed R + start cap for a capped one.
	g.fill_color = P.WALL
	var caps: Array = s.caps
	if closed:
		g.fill_band(Lv, Rv, true)
	elif caps.size() == 2:
		var ce: Array = caps[0].slice(0, caps[0].size() - 2)  # caps=[ce.concat([Lp[n-1],Rp[n-1]]), cs.concat([Lp[0],Rp[0]])]
		var cs: Array = caps[1].slice(0, caps[1].size() - 2)
		g.fill_band(Lv, Rv, false, to_v2(ce), to_v2(cs))
	else:
		g.fill_band(Lv, Rv, false)
	# tonal slope on the side facing away from the sun
	g.stroke_color = mix(P.shadowCol, P.WALL, 1.0 - palette_extras(P)["wall_slope_shadow_mix"])  # JS: mix(P.shadowCol,WALL,.7)
	g.line_width = hw * 0.7
	g.line_cap = "butt"
	g.global_alpha = 0.6
	for side: float in [1.0, -1.0]:
		g.begin_path()
		var pen := false
		for k in lim + 1:
			var i := k % n
			var fx: float = nrm[i][0] * side
			var fy: float = nrm[i][1] * side
			if fx * sdx + fy * sdy < 0.2:
				pen = false
				continue
			var x: float = pts[i][0] + fx * hw * 0.55
			var y: float = pts[i][1] + fy * hw * 0.55
			if not pen:
				g.move_to(x, y)
				pen = true
			else:
				g.line_to(x, y)
		g.stroke()
	g.global_alpha = 1.0
	g.line_cap = "round"
	# stipple, denser toward the edges
	g.fill_color = P.INK
	for i in n:
		for _k in 3:
			var t := rng.next() * 2.0 - 1.0
			if rng.next() > 0.25 + absf(t) * 0.6:
				continue
			g.global_alpha = 0.18 + rng.next() * 0.25
			g.fill_rect(pts[i][0] + nrm[i][0] * t * hw * 0.95, pts[i][1] + nrm[i][1] * t * hw * 0.95, 0.8, 0.8)
	# hatching down the shaded slope
	g.stroke_color = P.INK
	g.line_width = 0.55 * P.lw
	g.global_alpha = 0.5
	for side: float in [1.0, -1.0]:
		var E: Array = Lp if side > 0 else Rp
		g.begin_path()
		for i in range(0, n, 2):  # for(let i=0;i<n;i+=2)
			var fx: float = nrm[i][0] * side
			var fy: float = nrm[i][1] * side
			var f: float = fx * sdx + fy * sdy
			if f < 0.2 or rng.next() > 0.85:  # || short-circuits: no draw on the lit side
				continue
			var ln: float = hw * (0.28 + rng.next() * 0.3) * minf(1.0, f + 0.3)  # JS: len
			g.move_to(E[i][0], E[i][1])
			g.line_to(E[i][0] - fx * ln, E[i][1] - fy * ln)
		g.stroke()
	# double crest line along the top of the rampart
	g.global_alpha = 0.5
	g.line_width = 0.65 * P.lw
	var seed_value: int = s.seed
	var crest := [0.24, -0.24]
	for ci in 2:  # [.24,-.24].forEach((c,ci)=>{
		var c: float = crest[ci]
		g.begin_path()
		var pen := false
		for k in lim + 1:
			var i := k % n
			if ValueNoise.vnoise(k * 0.06, ci * 4.1 + 2.0, seed_value + 3) < 0.22:
				pen = false
				continue
			var o: float = hw * c + (ValueNoise.vnoise(k * 0.15, float(ci + 8), seed_value) - 0.5) * P.wob * 1.2
			var x: float = pts[i][0] + nrm[i][0] * o
			var y: float = pts[i][1] + nrm[i][1] * o
			if not pen:
				g.move_to(x, y)
				pen = true
			else:
				g.line_to(x, y)
		g.stroke()
	# outer edges
	g.global_alpha = 1.0
	g.line_width = P.linework["wall_edges"] * P.lw  # JS: 1.15*P.lw
	g.begin_path()
	for e: Dictionary in s.edges:  # s.edges.forEach(e=>addPoly(g,e.p,e.closed))
		add_poly(g, e.p, e.closed)
	g.stroke()
	# pebbles sitting on the edges break up the line
	g.line_width = 0.55 * P.lw
	for side: float in [1.0, -1.0]:
		var E: Array = Lp if side > 0 else Rp
		for i in range(0, n, 2):
			if rng.next() < 0.45:
				continue
			var r := 0.6 + rng.next() * 1.1
			var o := (rng.next() * 1.8 - 0.4) * side
			g.begin_path()
			g.arc(E[i][0] + nrm[i][0] * o, E[i][1] + nrm[i][1] * o, r, 0.0, PI * 2.0)
			g.fill_color = P.WALL
			g.fill()
			g.global_alpha = 0.8
			g.stroke()
			g.global_alpha = 1.0

# --- houses -----------------------------------------------------------------------

# function drawHouse(g,s): per part, the two roof halves (the one facing away
# from the sun in the shaded roof tone) with broken thatch strokes, an inset
# eave line, the outline, the ridge, and a chimney on the main part.
static func draw_house(g: InkCanvas, s: Dictionary, P: RenderParams, rng: Mulberry32 = null) -> void:
	if rng == null:
		rng = Mulberry32.new(s.seed)  # const rng=mulberry32(s.seed)
	var sd := shadow_dir(P)  # [sdx,sdy]=shadowDir()
	var dark := mix(P.shadowCol, P.ROOF, 1.0 - palette_extras(P)["roof_shaded_shadow_mix"])  # JS: mix(P.shadowCol,ROOF,.58)
	g.line_cap = "round"  # g.lineJoin="round"; g.lineCap="round";
	g.stroke_color = P.INK
	var geo: Array = s.geo
	for pi in geo.size():  # s.geo.forEach((pt,pi)=>{
		var pt: Dictionary = geo[pi]
		var w: float = pt.w  # const {w,d,tf,cc,ss}=pt
		var d: float = pt.d
		var cc: float = pt.cc
		var ss: float = pt.ss
		var tf := func(lx: float, ly: float) -> Vector2:  # pt.tf, as a Vector2 for drawing
			var q: Array = Structures.house_tf(pt, lx, ly)
			return Vector2(q[0], q[1])
		for sg: float in [-1.0, 1.0]:
			var fx := -sg * ss  # roof-half normal in world space
			var fy := sg * cc
			g.begin_path()
			add_poly(g, PackedVector2Array([tf.call(-w / 2.0, 0.0), tf.call(w / 2.0, 0.0), tf.call(w / 2.0, sg * d / 2.0), tf.call(-w / 2.0, sg * d / 2.0)]), true)
			g.fill_color = dark if fx * sd.x + fy * sd.y > 0 else P.ROOF
			g.fill()
			g.line_width = 0.5 * P.lw
			g.global_alpha = 0.5
			g.begin_path()
			# for(let lx=-w/2+1.8;lx<w/2-1;lx+=2.4){ if(rng()>.78) continue; ... }
			# A while loop: the step must run on the skipped iterations too, as
			# the for loop's update does, or the count of draws changes.
			var lx := -w / 2.0 + 1.8
			while lx < w / 2.0 - 1.0:
				if rng.next() <= 0.78:
					var j := (rng.next() - 0.5) * 0.6
					var a: Vector2 = tf.call(lx + j, sg * 0.8)
					var b: Vector2 = tf.call(lx + j * 0.5, sg * (d / 2.0 - 1.0))
					g.move_to(a.x, a.y)
					g.line_to(b.x, b.y)
				lx += 2.4
			g.stroke()
			g.global_alpha = 1.0
		g.line_width = 0.5 * P.lw
		g.global_alpha = 0.4
		g.begin_path()
		add_poly(g, PackedVector2Array([tf.call(-w / 2.0 + 1.3, -d / 2.0 + 1.3), tf.call(w / 2.0 - 1.3, -d / 2.0 + 1.3),
			tf.call(w / 2.0 - 1.3, d / 2.0 - 1.3), tf.call(-w / 2.0 + 1.3, d / 2.0 - 1.3)]), true)
		g.stroke()
		g.global_alpha = 1.0
		g.line_width = P.linework["house_outline"] * P.lw  # JS: 1.2*P.lw
		g.begin_path()
		add_poly(g, pt.corners, true)
		g.stroke()
		g.line_width = 1.05 * P.lw
		g.begin_path()
		var r0: Vector2 = tf.call(-w / 2.0, 0.0)
		var r1: Vector2 = tf.call(w / 2.0, 0.0)
		g.move_to(r0.x, r0.y)
		g.line_to(r1.x, r1.y)
		g.stroke()
		if pi == 0 and s.chimney:
			var q := PackedVector2Array([tf.call(w * 0.22 - 1.5, -d * 0.22 - 1.5), tf.call(w * 0.22 + 1.5, -d * 0.22 - 1.5),
				tf.call(w * 0.22 + 1.5, -d * 0.22 + 1.5), tf.call(w * 0.22 - 1.5, -d * 0.22 + 1.5)])
			g.begin_path()
			add_poly(g, q, true)
			g.fill_color = P.CREAM
			g.fill()
			g.line_width = 0.8 * P.lw
			g.stroke()

# --- the sprite ---------------------------------------------------------------------

# syncStruct's canvas: (bx, by, bw, bh) from structures.gd's sync_struct, the
# canvas translated so world coordinates draw in place.
#   const c=document.createElement("canvas"); c.width=Math.ceil((x1-x0)*DPR); c.height=Math.ceil((y1-y0)*DPR);
#   const g=c.getContext("2d"); g.setTransform(DPR,0,0,DPR,-x0*DPR,-y0*DPR);
#   if(s.kind==="wall") drawWall(g,s); else drawHouse(g,s);
static func build_struct_sprite(s: Dictionary, P: RenderParams, rng: Mulberry32 = null) -> InkCanvas:
	var g := InkCanvas.new(Vector2i(ceili(s.bw), ceili(s.bh)))
	g.set_transform(1, 0, 0, 1, -s.bx, -s.by)
	if s.kind == "wall":
		draw_wall(g, s, P, rng)
	else:
		draw_house(g, s, P, rng)
	return g
