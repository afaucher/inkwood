extends RefCounted

# The prototype's object sprites, ported line for line from
# reference/inkwood-renderer.html onto the drawing layer (InkCanvas):
#
#   prototype                                here
#   scallop(cx,cy,R,n,ph,amps,wob,ns)        scallop(...) -> [PackedVector2Array points, PackedInt32Array idx]
#   tracePath(g,pts)                         trace_path(g, pts)
#   drawLobe(g,L,rng)                        draw_lobe(g, L, rng, P)
#   buildTreeSprite(t)                       build_tree_sprite(t, P, rng = null) -> InkCanvas (unrendered)
#   buildPropSprite(p)                       build_prop_sprite(p, P, rng = null) -> InkCanvas (unrendered)
#
# The builders return the canvas UNRENDERED and set `half` on the object, so
# the caller (ink_renderer.gd, syncTree / syncProp) can render every sprite of
# a frame in ONE engine frame with InkCanvas.render_all and then set `sprite`.
#
# THE RNG STREAM IS THE CONTRACT. Each builder draws from its own
# mulberry32(seed) in exactly the prototype's order -- every rng() call in the
# same sequence, including the draws whose result is thrown away (a ring
# segment that is not drawn, a stipple dot on the lit side) -- so the same
# seed gives the same lobes, ring breaks, ticks and stipple as the browser.
# scripts/tests/test_render_layer.gd counts the draws against the prototype's
# own code (reference/port_check/prototype_render_sample.js). `rng` is a
# parameter only so that test can hand in its own generator; normally it is
# null and the builder makes mulberry32(seed) itself, as the prototype does.
#
# BIT-EXACTNESS IS NOT REQUIRED (Alex, 2026-10-09): sin / cos / pow are the
# engine's and points are Vector2 (float32). What must match is the stream
# order, the formulas, the draw order and the compositing. Integer-valued
# decisions that steer the stream (a scallop point's segment index) come from
# multiplications and divisions only, which are the same doubles as in V8.
#
# P is a RenderParams (scripts/world/render_params.gd): the prototype's `P`
# under its own names, colours (P.INK, P.CREAM, P.ROCK), the light (P.LX,
# P.LY) and the per-element line weights (P.linework) from
# data/params/render_defaults.json. The few line-weight multipliers that file
# does not carry stay the prototype's literals, each on its line.
#
# Canvas lineJoin is always "round" on InkCanvas; the prototype sets it to
# "round" everywhere it draws, so those statements have no GDScript line.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

# --- scallop contour: |sin| bumps give rounded lobes with inward cusps ----------

# function scallop(cx,cy,R,n,ph,amps,wob,ns): n*9+1 points round a circle of
# radius R, each pushed in by its segment's amplitude except at the bump tops,
# wobbled by noise. JS returns [x, y, idx] triples; here the points and the
# segment indices are two parallel arrays.
static func scallop(cx: float, cy: float, R: float, n: int, ph: float, amps: PackedFloat64Array,
		wob: float, ns: int) -> Array:
	var pts := PackedVector2Array()  # const pts=[]
	var idxs := PackedInt32Array()   # (JS: the idx is the third member of each point)
	var steps := n * 9
	for i in steps + 1:  # for(let i=0;i<=steps;i++)
		var th := float(i) / float(steps) * PI * 2.0  # JS: i/steps*Math.PI*2 (float division there)
		var u := float(n) * th / 2.0 + ph
		var idx := int(floorf(u / PI)) % n  # Math.floor(u/Math.PI)%n -- u >= 0, so % agrees
		var a := amps[idx]
		var rr := R * (1.0 - a + a * pow(absf(sin(u)), 0.55))
		rr *= 1.0 + wob * 0.08 * (ValueNoise.vnoise(cos(th) * 1.6 + 7.0, sin(th) * 1.6 + 7.0, ns) * 2.0 - 1.0)
		pts.push_back(Vector2(cx + cos(th) * rr, cy + sin(th) * rr))  # pts.push([...,...,idx])
		idxs.push_back(idx)
	return [pts, idxs]

# function tracePath(g,pts){g.beginPath(); ...moveTo / lineTo...; g.closePath();}
static func trace_path(g: InkCanvas, pts: PackedVector2Array) -> void:
	g.begin_path()
	for i in pts.size():
		var p := pts[i]
		if i:
			g.line_to(p.x, p.y)
		else:
			g.move_to(p.x, p.y)
	g.close_path()

# function drawLobe(g,L,rng): one floret -- a cream scallop with an ink
# outline, P.rings nested broken rings shifted toward the light, cusp ticks,
# and stipple on the side away from the light. L = {x, y, R}.
static func draw_lobe(g: InkCanvas, L: Dictionary, rng: Mulberry32, P: RenderParams) -> void:
	var x: float = L.x  # const {x,y,R}=L
	var y: float = L.y
	var R: float = L.R
	var n := maxi(5, roundi(4.5 + R / 3.0))  # Math.max(5,Math.round(4.5+R/3)) -- positive, so roundi agrees
	var ph := rng.next() * PI
	var ns := int(rng.next() * 1e6)  # (rng()*1e6)|0
	var amps := PackedFloat64Array()  # Array.from({length:n},()=>.13+rng()*.12)
	for _i in n:
		amps.push_back(0.13 + rng.next() * 0.12)
	var outline: Array = scallop(x, y, R, n, ph, amps, P.wob, ns)
	trace_path(g, outline[0])
	g.fill_color = P.CREAM
	g.fill()
	g.stroke_color = P.INK
	g.line_width = P.linework["tree_outline"] * P.lw  # JS: 1.25*P.lw
	g.stroke()
	# nested, broken contour rings shifted toward the light: reads as a raised floret
	for k in range(1, P.rings + 1):  # for(let k=1;k<=P.rings;k++)
		var s := 1.0 - k * (0.68 / (P.rings + 0.4))
		var nk := maxi(3, n - k)
		var am := PackedFloat64Array()  # Array.from({length:nk},()=>.15+rng()*.12)
		for _i in nk:
			am.push_back(0.15 + rng.next() * 0.12)
		var ring: Array = scallop(x + P.LX * R * 0.1 * k, y + P.LY * R * 0.1 * k, R * s, nk, ph + k * 0.7, am, P.wob, ns + k * 31)
		var rp: PackedVector2Array = ring[0]
		var ri: PackedInt32Array = ring[1]
		g.line_width = P.linework["tree_inner_rings"] * P.lw  # JS: .85*P.lw
		g.global_alpha = 0.88
		g.begin_path()
		var seg := -1
		var draw := false
		for j in rp.size():  # for(const p of ring)
			if ri[j] != seg:
				seg = ri[j]
				draw = rng.next() < 0.8
				if draw:
					g.move_to(rp[j].x, rp[j].y)
				continue
			if draw:
				g.line_to(rp[j].x, rp[j].y)
		g.stroke()
		g.global_alpha = 1.0
	# short ticks from cusps toward the centre
	g.line_width = P.linework["cusp_ticks"] * P.lw  # JS: .75*P.lw
	g.begin_path()
	for m in range(1, n + 1):  # for(let m=1;m<=n;m++)
		if rng.next() > 0.55:
			continue
		var th := 2.0 * (m * PI - ph) / n
		var rr := R * (1.0 - amps[m % n])
		var cx := x + cos(th) * rr
		var cy := y + sin(th) * rr
		g.move_to(cx, cy)
		g.line_to(cx - cos(th) * R * 0.15, cy - sin(th) * R * 0.15)
	g.stroke()
	# stipple on the side away from the light
	g.fill_color = P.INK
	g.global_alpha = 0.55
	var dots := roundi(R * 0.6)  # Math.round(R*.6)
	for _i in dots:
		var a := rng.next() * PI * 2.0
		var d := sqrt(rng.next()) * R * 0.78
		var dx := cos(a)
		var dy := sin(a)
		if dx * P.LX + dy * P.LY > -0.15:
			continue
		g.begin_path()
		g.arc(x + dx * d, y + dy * d, 0.45, 0.0, PI * 2.0)
		g.fill()
	g.global_alpha = 1.0

# --- trees ------------------------------------------------------------------------

# function buildTreeSprite(t): 3-7 outer lobes round the trunk, far-from-light
# first, then a crown lobe on top. The canvas is 2*half square with the origin
# at its centre; t.half is set here, t.sprite by the caller once it renders.
static func build_tree_sprite(t: Dictionary, P: RenderParams, rng: Mulberry32 = null) -> InkCanvas:
	var r: float = t.r
	var half := ceili(r * 1.3 + 4.0)
	var size := half * 2
	var g := InkCanvas.new(Vector2i(size, size))  # c.width=c.height=Math.ceil(size*DPR) -- DPR is 1
	g.set_transform(1, 0, 0, 1, half, half)  # g.setTransform(DPR,0,0,DPR,half*DPR,half*DPR)
	g.line_cap = "round"  # g.lineJoin="round"; g.lineCap="round";
	if rng == null:
		rng = Mulberry32.new(t.seed)  # const rng=mulberry32(t.seed)
	var nOuter := mini(7, 3 + floori(r / 11.0) + (1 if rng.next() < 0.5 else 0))
	var a0 := rng.next() * PI * 2.0
	var lobes: Array[Dictionary] = []
	for i in nOuter:
		var a := a0 + float(i) / float(nOuter) * PI * 2.0 + (rng.next() - 0.5) * 0.5  # JS: i/nOuter (float division)
		var d := r * (0.36 + rng.next() * 0.14)
		lobes.append({"x": cos(a) * d, "y": sin(a) * d, "R": r * (0.34 + rng.next() * 0.16)})
	var lx := P.LX
	var ly := P.LY
	# lobes.sort((p,q)=>(p.x*LX+p.y*LY)-(q.x*LX+q.y*LY));       // far-from-light lobes first
	lobes.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return p.x * lx + p.y * ly < q.x * lx + q.y * ly)
	# crown on top -- x, y, R drawn in that order (object literal order)
	var crown_x: float = (rng.next() - 0.5) * r * 0.12
	var crown_y: float = (rng.next() - 0.5) * r * 0.12
	lobes.append({"x": crown_x, "y": crown_y, "R": r * (0.48 + rng.next() * 0.1)})
	for L in lobes:
		draw_lobe(g, L, rng, P)
	t.half = half  # t.sprite=c; t.half=half;  (sprite: set by the caller after rendering)
	return g

# --- props ------------------------------------------------------------------------

# function buildPropSprite(p): a barrel (two rings and a stave line), a crate
# (box, inner box, diagonal) or a rock (a 7-gon in rock fill with a crack and
# three unrotated hatch strokes). Only the rock draws from its rng.
static func build_prop_sprite(p: Dictionary, P: RenderParams, rng: Mulberry32 = null) -> InkCanvas:
	var s: float = p.s
	var half := ceili(s * 1.9 + 3.0)
	var g := InkCanvas.new(Vector2i(half * 2, half * 2))  # c.width=c.height=Math.ceil(half*2*DPR) -- DPR is 1
	g.set_transform(1, 0, 0, 1, half, half)  # g.setTransform(DPR,0,0,DPR,half*DPR,half*DPR)
	g.rotate(p.rot)
	g.line_cap = "round"  # g.lineJoin="round"; g.lineCap="round";
	g.stroke_color = P.INK
	g.line_width = 0.95 * P.lw
	if rng == null:
		rng = Mulberry32.new(p.seed)  # const rng=mulberry32(p.seed)
	if p.type == "barrel":
		g.begin_path()
		g.arc(0, 0, s, 0, PI * 2.0)
		g.fill_color = P.CREAM
		g.fill()
		g.stroke()
		g.line_width = 0.7 * P.lw
		g.begin_path()
		g.arc(0, 0, s * 0.64, 0, PI * 2.0)
		g.stroke()
		g.begin_path()
		g.move_to(-s * 0.64, 0)
		g.line_to(s * 0.64, 0)
		g.stroke()
	elif p.type == "crate":
		var a := s * 0.85
		g.begin_path()
		g.rect(-a, -a, a * 2.0, a * 2.0)
		g.fill_color = P.CREAM
		g.fill()
		g.stroke()
		g.line_width = 0.7 * P.lw
		g.begin_path()
		g.rect(-a * 0.6, -a * 0.6, a * 1.2, a * 1.2)
		g.move_to(-a * 0.6, -a * 0.6)
		g.line_to(a * 0.6, a * 0.6)
		g.stroke()
	else:
		var n := 7
		var v := PackedVector2Array()
		for i in n:
			var a := float(i) / float(n) * PI * 2.0 + (rng.next() - 0.5) * 0.5  # JS: i/n (float division)
			var rr := s * (0.72 + rng.next() * 0.4)
			v.push_back(Vector2(cos(a) * rr, sin(a) * rr))
		g.begin_path()  # v.forEach((q,i)=>i?g.lineTo(q[0],q[1]):g.moveTo(q[0],q[1]))
		for i in v.size():
			if i:
				g.line_to(v[i].x, v[i].y)
			else:
				g.move_to(v[i].x, v[i].y)
		g.close_path()
		g.fill_color = P.ROCK
		g.fill()
		g.stroke()
		g.line_width = 0.6 * P.lw
		g.begin_path()
		g.move_to(v[0].x * 0.55, v[0].y * 0.55)
		g.line_to(v[3].x * 0.2, v[3].y * 0.2)
		g.stroke()
		g.set_transform(1, 0, 0, 1, half, half)  # g.setTransform(DPR,0,0,DPR,half*DPR,half*DPR) -- drops the rotation
		g.global_alpha = 0.6
		g.begin_path()
		for i in 3:
			var o := s * (0.1 + i * 0.22)
			g.move_to(o, s * 0.55 - o * 0.2)
			g.line_to(o + s * 0.25, s * 0.3 - o * 0.2)
		g.stroke()
		g.global_alpha = 1.0
	p.half = half  # p.sprite=c; p.half=half;  (sprite: set by the caller after rendering)
	return g
