extends RefCounted

# THE STATIC GROUND UNITS in ink: the anti-aircraft battery and the radio tower, as the unit
# sheet draws them (reference/mockups/unit_sheet.html genAA / buildAA / prepAA / drawAAGround /
# drawAAUpper / bandGeom / drawBand, and genTower / buildTower / drawTowerGround /
# drawTowerUpper), ported onto the drawing layer (Track U3, the strike, 2026-10-10) in the way the
# planes and the tank are in unit_marker_art.gd, whose pen and helpers this file uses. Each
# exists ONCE in the strike, never moves and never turns, which changes two things from a plane:
#
#   BAKED IN THE SCREEN'S FRAME. A plane is baked nose up and the marker turns the sprite, which
#   leaves its baked light turned with it (a documented departure). A static unit has one heading
#   for good, so it is baked ALREADY TURNED (the sheet's View rotation): the light on it is the
#   map's at any heading, and the sprite is not rotated at all. The Art says so (screen_aligned,
#   rot) and the marker poses it that way; the cache key carries the rotation.
#
#   A CAST SHADOW, NOT A FOOTPRINT. A plane's shadow is its silhouette offset by its height. A
#   tower is 23 to 27 m tall and stands still: its shadow is the sheet's maskOps for a ground unit
#   (the prototype's castShadows), every part cast along the shadow direction by its height x the
#   sun's length: prisms (the hut, the gun shield) as hulls of the footprint and the footprint
#   raised, the sandbag ring as the hull of each segment and the same segment raised, the lattice
#   members and the barrels as lines with their heights, the platform as a floating polygon at the
#   top. So the tower's shadow reaches height x 0.97 (sun elevation 46 degrees) metres away from
#   the sun, drawn at the same scale as the tower. The mask (Art.mask) is that shadow, in the same
#   frame and size as the art, and the marker's shadow group tints it at the map's shadow strength.
#
# THE SEED. unitSeed(ui, variant) on the scene seed with the sheet's UNITS index (battery 4, tower
# 6), as the planes' are, so the unit on the map is the unit Alex saw on the sheet (and the tower's
# ruin, scripts/fx/fx_ruin.gd, is made of the same parts: it takes the same seed).
#
# ONE ACCENT ZONE EACH (decision unit-sheet-choices): the battery's ground panel (accent_panel),
# the radio hut's roof panel.
#
# This file preloads unit_marker_art.gd; unit_marker_art.gd reaches it with load() when it first
# needs it (never a preload: two scripts that preload each other hang the run).

const A = preload("res://scripts/ui/unit_marker_art.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

# --- shape helpers (metres) -------------------------------------------------------------------

# place(pts, cx, cy, a): rotate by `a`, then move to (cx, cy).
static func place(pts: PackedVector2Array, cx: float, cy: float, a: float) -> PackedVector2Array:
	var c := cos(a)
	var s := sin(a)
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2(cx + p.x * c - p.y * s, cy + p.x * s + p.y * c))
	return out

# offsetPoly: a smooth convex outline moved `d` metres along its vertex normals, toward the centre
# (a negative d grows it).
static func offset_poly(pts: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := pts.size()
	var c := A._cen(pts)
	var out := PackedVector2Array()
	for i in n:
		var a := pts[(i - 1 + n) % n]
		var b := pts[(i + 1) % n]
		var tx := b.x - a.x
		var ty := b.y - a.y
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		var nx := -ty / l
		var ny := tx / l
		if (pts[i].x - c.x) * nx + (pts[i].y - c.y) * ny > 0.0:
			nx = -nx
			ny = -ny
		out.append(Vector2(pts[i].x + nx * d, pts[i].y + ny * d))
	return out

static func _flat(pts: PackedVector3Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.append(Vector2(q.x, q.y))
	return out

# resample(src, step, closed): points every `step` along the polyline (px).
static func resample(src: PackedVector2Array, step: float, closed: bool) -> PackedVector2Array:
	var pts := PackedVector2Array(src)
	if closed:
		pts.append(src[0])
	var out := PackedVector2Array([pts[0]])
	var acc := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		while acc + seg >= step:
			var t := (step - acc) / seg
			a = a + (b - a) * t
			out.append(a)
			seg = a.distance_to(b)
			acc = 0.0
		acc += seg
	if not closed:
		var e := pts[pts.size() - 1]
		var l := out[out.size() - 1]
		if e.distance_to(l) > step * 0.3:
			out.append(e)
	elif out.size() > 2:
		var l2 := out[out.size() - 1]
		if l2.distance_to(out[0]) < step * 0.5:
			out.remove_at(out.size() - 1)
	return out

# --- the anti-aircraft battery -------------------------------------------------------------------

# genAA(rng): every draw in the sheet's order.
static func gen_aa(rng: Mulberry32) -> Dictionary:
	var p := {}
	p.radius = A._r(rng, 3.7, 4.3)
	p.band = A._r(rng, 0.8, 1.1)
	p.gap_deg = A._r(rng, 32.0, 48.0)
	p.gap_dir_deg = A._r(rng, 70.0, 115.0)
	p.guns = int(A._pick_w(rng, [[1, 0.34], [2, 0.33], [4, 0.33]]))
	p.barrel_len = A._r(rng, 2.2, 3.2)
	p.elev_deg = A._r(rng, 38.0, 62.0)
	p.gun_az_deg = A._r(rng, -135.0, -45.0)
	p.mount_r = A._r(rng, 1.0, 1.3)
	p.crates = 2 + int(floorf(rng.next() * 3.0))
	p.bag_h = A._r(rng, 1.0, 1.25)
	p.bag_len = A._r(rng, 0.5, 0.65)
	return p

# buildAA(p): the geometry, metres. The shadows are described in shadow_prims.
static func build_aa(p: Dictionary) -> Dictionary:
	var G := {}
	var d2r := PI / 180.0
	var rc: float = p.radius - p.band / 2.0
	var gap: float = p.gap_deg * d2r
	var gd: float = p.gap_dir_deg * d2r
	var a0 := gd + gap / 2.0
	var a1 := gd + TAU - gap / 2.0
	var n := ceili((a1 - a0) * rc / 0.25)
	var ring := PackedVector2Array()
	for i in n + 1:
		var a := a0 + (a1 - a0) * float(i) / float(n)
		ring.append(Vector2(cos(a) * rc, sin(a) * rc))
	G.ring = ring
	G.inner = A.circ(Vector2.ZERO, p.radius - p.band, 40)
	G.outer = A.circ(Vector2.ZERO, p.radius, 40)
	G.mount = A.circ(Vector2.ZERO, p.mount_r, 28)
	var az: float = p.gun_az_deg * d2r
	var el: float = p.elev_deg * d2r
	var length: float = p.barrel_len * cos(el)   # barrels drawn foreshortened by their elevation
	G.cradle = place(A.rrect(0.12, 0.0, 1.2, 0.84, 0.16), 0.0, 0.0, az)
	var sh := PackedVector2Array()
	var shi := PackedVector2Array()
	for i in 9:
		var a := -0.95 + 1.9 * float(i) / 8.0
		sh.append(Vector2(cos(a) * 1.0, sin(a) * 1.0))
		shi.append(Vector2(cos(a) * 0.86, sin(a) * 0.86))
	shi.reverse()
	sh.append_array(shi)
	G.shield = place(sh, 0.0, 0.0, az)
	var offs: Array = [0.0]
	if p.guns == 2:
		offs = [-0.2, 0.2]
	elif p.guns == 4:
		offs = [-0.42, -0.14, 0.14, 0.42]
	var barrels: Array = []
	var hiders: Array = []
	for o: float in offs:
		barrels.append(place(A.rect_p(0.45, o - 0.06, 0.45 + length, o + 0.06), 0.0, 0.0, az))
		hiders.append(place(A.rect_p(0.45 + length - 0.24, o - 0.09, 0.45 + length, o + 0.09), 0.0, 0.0, az))
	G.barrels = barrels
	G.hiders = hiders
	var seats: Array = []
	for s: float in [-1.0, 1.0]:
		seats.append(place(A.circ(Vector2(-0.32, s * 0.62), 0.17, 10), 0.0, 0.0, az))
	G.seats = seats
	var crates: Array = []
	for k in int(p.crates):
		var a := az + PI + 0.7 + float(k) * 0.42
		var r: float = p.radius - p.band - 0.5
		crates.append({"c": Vector2(cos(a) * r, sin(a) * r), "a": a})
	G.crates = crates
	var pa := az + PI - 0.75
	var pr: float = (p.radius - p.band) * 0.56
	G.panel = place(A.rect_p(-0.7, -0.38, 0.7, 0.38), cos(pa) * pr, sin(pa) * pr, pa + PI / 2.0)   # accent zone: the ground recognition panel
	G.ext = [G.outer]
	# The barrels' shadow lines, with heights: the gun rises from zp at its breech to zt at its muzzle.
	var zp := 1.35
	var zt: float = zp + p.barrel_len * sin(el)
	var lines: Array = []
	for o: float in offs:
		var q0 := place(PackedVector2Array([Vector2(0.45, o)]), 0.0, 0.0, az)[0]
		var q1 := place(PackedVector2Array([Vector2(0.45 + length, o)]), 0.0, 0.0, az)[0]
		lines.append(PackedVector3Array([Vector3(q0.x, q0.y, zp), Vector3(q1.x, q1.y, zt)]))
	G.barrel_lines = lines
	return G

# prepAA(I): the sandbag ring as a band of the prototype's wall geometry, in px.
static func prep_aa(M: A.Model, V: A.View, ink: A.Ink) -> Dictionary:
	var c := resample(V.tps(M.G.ring), 3.0, false)
	var band := band_geom(c, float(M.p.band) / 2.0 * V.ppm, (M.seed % 99991) + 17, false, true, ink)
	band["h"] = float(M.p.bag_h) * V.ppm
	return band

# bandGeom(pts, hw, seed, closed, caps): the prototype's wallGeom, fed a centreline in px.
static func band_geom(pts: PackedVector2Array, hw: float, seed_value: int, closed: bool, caps: bool, ink: A.Ink) -> Dictionary:
	var n := pts.size()
	var nrm := PackedVector2Array()
	var lp := PackedVector2Array()
	var rp := PackedVector2Array()
	var k := minf(1.0, hw / 6.0)   # edge noise eased on narrow bands
	for i in n:
		var a := pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b := pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var tx := b.x - a.x
		var ty := b.y - a.y
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		var nx := -ty / l
		var ny := tx / l
		var e_l := (ValueNoise.vnoise(float(i) * 0.18, 1.3, seed_value) * 2.0 - 1.0) * ink.wob * 1.3 * k
		var e_r := (ValueNoise.vnoise(float(i) * 0.18, 5.1, seed_value) * 2.0 - 1.0) * ink.wob * 1.3 * k
		nrm.append(Vector2(nx, ny))
		lp.append(Vector2(pts[i].x + nx * (hw + e_l), pts[i].y + ny * (hw + e_l)))
		rp.append(Vector2(pts[i].x - nx * (hw + e_r), pts[i].y - ny * (hw + e_r)))
	var ce := PackedVector2Array()
	var cs := PackedVector2Array()
	var edges: Array = []
	var cap_polys: Array = []
	if closed:
		edges = [{"p": lp, "closed": true}, {"p": rp, "closed": true}]
	elif caps:
		var a0 := atan2(nrm[n - 1].y, nrm[n - 1].x)
		var a1 := atan2(nrm[0].y, nrm[0].x)
		for q in range(1, 8):
			var ang := a0 - float(q) * PI / 8.0
			ce.append(pts[n - 1] + Vector2(cos(ang), sin(ang)) * hw)
		for q in range(1, 8):
			var ang2 := a1 + PI - float(q) * PI / 8.0
			cs.append(pts[0] + Vector2(cos(ang2), sin(ang2)) * hw)
		var loop := PackedVector2Array(lp)
		loop.append_array(ce)
		var rrev := PackedVector2Array(rp)
		rrev.reverse()
		loop.append_array(rrev)
		loop.append_array(cs)
		edges = [{"p": loop, "closed": true}]
		var cap_e := PackedVector2Array(ce)
		cap_e.append(lp[n - 1])
		cap_e.append(rp[n - 1])
		var cap_s := PackedVector2Array(cs)
		cap_s.append(lp[0])
		cap_s.append(rp[0])
		cap_polys = [cap_e, cap_s]
	else:
		var open_loop := PackedVector2Array(lp)
		var rr := PackedVector2Array(rp)
		rr.reverse()
		open_loop.append_array(rr)
		edges = [{"p": open_loop, "closed": true}]
	return {"pts": pts, "nrm": nrm, "L": lp, "R": rp, "hw": hw, "ce": ce, "cs": cs, "caps": cap_polys, "closed": closed, "seed": seed_value, "edges": edges}

# dirt(g, o, rng, density): the prototype's dirt stipple, DIRT squares at .15-.40, only inside `o`.
static func dirt(g, ink: A.Ink, o: PackedVector2Array, rng: Mulberry32, density: float) -> void:
	var bb := A._bbox(o)
	var cnt := roundi(bb.size.x * bb.size.y / 100.0 * density * ink.stip)
	g.fill_color = ink.dirt
	for _i in cnt:
		var x := bb.position.x + rng.next() * bb.size.x
		var y := bb.position.y + rng.next() * bb.size.y
		g.global_alpha = 0.15 + rng.next() * 0.25
		var s := 0.6 + rng.next() * 0.8
		if Geometry2D.is_point_in_polygon(Vector2(x + s * 0.5, y + s * 0.5), o):
			g.fill_rect(x, y, s, s)
	g.global_alpha = 1.0

# drawBand(g, s, o): the prototype's drawWall with sandbag courses (staggered joints) in place of the
# double crest line. `bag` is the bag's length in px (0: none).
static func draw_band(g, ink: A.Ink, s: Dictionary, fill_c: Color, slope_c: Color, bag: float) -> void:
	var rng := Mulberry32.new(int(s["seed"]))
	var pts: PackedVector2Array = s["pts"]
	var nrm: PackedVector2Array = s["nrm"]
	var lp: PackedVector2Array = s["L"]
	var rp: PackedVector2Array = s["R"]
	var hw: float = s["hw"]
	var closed: bool = s["closed"]
	var n := pts.size()
	var sd := ink.sd
	var lim := n if closed else n - 1
	g.line_cap = "round"
	g.fill_color = fill_c
	g.global_alpha = 1.0
	g.fill_band(lp, rp, closed, s["ce"], s["cs"])
	g.stroke_color = slope_c
	g.line_width = hw * 0.7
	g.line_cap = "butt"
	g.global_alpha = 0.6
	for side: float in [1.0, -1.0]:
		g.begin_path()
		var pen_down := false
		for k in lim + 1:
			var i := k % n
			var fx := nrm[i].x * side
			var fy := nrm[i].y * side
			if fx * sd.x + fy * sd.y < 0.2:
				pen_down = false
				continue
			var x := pts[i].x + fx * hw * 0.55
			var y := pts[i].y + fy * hw * 0.55
			if not pen_down:
				g.move_to(x, y)
				pen_down = true
			else:
				g.line_to(x, y)
		g.stroke()
	g.global_alpha = 1.0
	g.line_cap = "round"
	g.fill_color = ink.ink
	for i in n:
		for _k in 3:
			var t := rng.next() * 2.0 - 1.0
			if rng.next() > (0.25 + absf(t) * 0.6) * ink.stip:
				continue
			g.global_alpha = 0.18 + rng.next() * 0.25
			g.fill_rect(pts[i].x + nrm[i].x * t * hw * 0.95, pts[i].y + nrm[i].y * t * hw * 0.95, 0.8, 0.8)
	g.stroke_color = ink.ink
	g.line_width = 0.55 * ink.lw
	g.global_alpha = 0.5
	for side: float in [1.0, -1.0]:
		var e: PackedVector2Array = lp if side > 0.0 else rp
		g.begin_path()
		for i in range(0, n, 2):
			var fx := nrm[i].x * side
			var fy := nrm[i].y * side
			var f := fx * sd.x + fy * sd.y
			if f < 0.2 or rng.next() > 0.85:
				continue
			var ln := hw * (0.28 + rng.next() * 0.3) * minf(1.0, f + 0.3)
			g.move_to(e[i].x, e[i].y)
			g.line_to(e[i].x - fx * ln, e[i].y - fy * ln)
		g.stroke()
	if bag >= 3.0:   # two courses of bags, joints staggered by half a bag
		g.global_alpha = 0.6
		g.line_width = 0.55 * ink.lw
		g.begin_path()
		var acc := 0.0
		for i in range(1, n):
			var d := pts[i].distance_to(pts[i - 1])
			for sk: Array in [[1.0, 0.0], [-1.0, 0.5]]:
				var side: float = sk[0]
				var off: float = sk[1]
				if floorf(acc / bag + off) != floorf((acc + d) / bag + off):
					var x := pts[i].x
					var y := pts[i].y
					g.move_to(x + nrm[i].x * side * hw * 0.1, y + nrm[i].y * side * hw * 0.1)
					g.line_to(x + nrm[i].x * side * hw * 0.9, y + nrm[i].y * side * hw * 0.9)
			acc += d
		g.stroke()
	g.global_alpha = 0.5   # the seam between the courses: a broken crest line
	g.line_width = 0.65 * ink.lw
	g.begin_path()
	var pd := false
	for k in lim + 1:
		var i := k % n
		if ValueNoise.vnoise(float(k) * 0.06, 2.0, int(s["seed"]) + 3) < 0.22:
			pd = false
			continue
		var off := (ValueNoise.vnoise(float(k) * 0.15, 8.0, int(s["seed"])) - 0.5) * ink.wob * 1.2 * minf(1.0, hw / 6.0)
		var x := pts[i].x + nrm[i].x * off
		var y := pts[i].y + nrm[i].y * off
		if not pd:
			g.move_to(x, y)
			pd = true
		else:
			g.line_to(x, y)
	g.stroke()
	g.global_alpha = 1.0
	g.line_width = 1.15 * ink.lw
	g.begin_path()
	for e2: Dictionary in s["edges"]:
		A.add_poly(g, e2["p"], bool(e2["closed"]))
	g.stroke()

static func draw_aa_ground(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, band: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	dirt(g, ink, V.tps(G.inner), A._rng(pn), 3.2)   # trodden pit floor
	draw_band(g, ink, band, ink.wall, ink.wall_slope, float(p.bag_len) * ppm)   # the sandbag ring: the prototype's wall band, coursed
	for c: Dictionary in G.crates:
		var s := 0.3
		var cc: Vector2 = c.c
		var box := place(A.rect_p(-s, -s * 0.75, s, s * 0.75), cc.x, cc.y, float(c.a) + PI / 2.0)
		var ins := place(A.rect_p(-s * 0.6, -s * 0.45, s * 0.6, s * 0.45), cc.x, cc.y, float(c.a) + PI / 2.0)
		A._path(pn, box, {"fill": ink.fill, "weight": 0.95})
		if ppm > 9.0:
			A._path(pn, ins, {"weight": 0.7, "alpha": 0.8})
			A._line(pn, PackedVector2Array([ins[0], ins[2]]), {"weight": 0.7, "alpha": 0.8})
	A.accent_panel(pn, G.panel, accent)

static func draw_aa_upper(g, M: A.Model, V: A.View, ink: A.Ink) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 9)
	var ppm := V.ppm
	var cream := ink.fill
	A._path(pn, G.mount, {"fill": cream, "weight": 1.0})
	if ppm > 6.0:
		A._path(pn, A.circ(Vector2.ZERO, float(p.mount_r) * 0.78, 24), {"weight": 0.55, "alpha": 0.6, "breaks": 0.22})
	for s: PackedVector2Array in G.seats:
		A._path(pn, s, {"fill": cream, "weight": 0.6})
	var c_o := A._path(pn, G.cradle, {"fill": cream, "weight": 0.0})
	A.shade_side(g, c_o, V.tp(Vector2.ZERO), ink.sd, ink.fill_shaded)   # shadeDome
	A.stipple(g, ink, c_o, {"rng": A._rng(pn), "density": 1.6, "away": V.tp(Vector2.ZERO)})
	A.stroke_o(g, ink, c_o, 1.0)
	var s_o := A._path(pn, G.shield, {"fill": cream, "weight": 0.0})
	A.edge_hatch(g, ink, s_o, minf(3.0, 0.25 * ppm), A._rng(pn), 1)
	A.stroke_o(g, ink, s_o, 0.9)
	for i in (G.barrels as Array).size():
		A._path(pn, G.barrels[i], {"fill": cream, "weight": 0.8})
		A._path(pn, G.hiders[i], {"fill": cream, "weight": 0.75})

# --- the radio tower ------------------------------------------------------------------------------

# genTower(rng): every draw in the sheet's order.
static func gen_tower(rng: Mulberry32) -> Dictionary:
	var p := {}
	p.base = A._r(rng, 5.4, 6.6)
	p.top = A._r(rng, 1.0, 1.8)
	p.height = A._r(rng, 23.0, 27.0)
	p.sections = 5 + int(floorf(rng.next() * 4.0))
	p.brace = "X" if rng.next() < 0.5 else "Z"
	p.hut_w = A._r(rng, 3.6, 4.6)
	p.hut_d = A._r(rng, 2.6, 3.2)
	p.hut_h = A._r(rng, 2.6, 3.2)
	p.hut_side = str(A._pick_w(rng, [["west", 0.5], ["north", 0.5]]))
	p.aerial_arm = A._r(rng, 2.2, 3.4)
	return p

# buildTower(p): the lattice as 3D members (x, y, z metres), the footprint parts in plan.
static func build_tower(p: Dictionary) -> Dictionary:
	var G := {}
	var b2: float = p.base / 2.0
	var t2: float = p.top / 2.0
	var H: float = p.height
	var N: int = p.sections
	var corners: Array = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var levels: Array = []
	for k in N + 1:
		levels.append(H * float(k) / float(N))
	G.levels = levels
	var hs := func(z: float) -> float: return b2 + (t2 - b2) * z / H
	var legs: Array = []
	for c: Vector2 in corners:
		legs.append(PackedVector3Array([Vector3(c.x * b2, c.y * b2, 0.0), Vector3(c.x * t2, c.y * t2, H)]))
	G.legs = legs
	var girts: Array = []
	for k in range(1, N):
		var z: float = levels[k]
		var h: float = hs.call(z)
		for f in 4:
			var a: Vector2 = corners[f]
			var b: Vector2 = corners[(f + 1) % 4]
			girts.append(PackedVector3Array([Vector3(a.x * h, a.y * h, z), Vector3(b.x * h, b.y * h, z)]))
	G.girts = girts
	var braces: Array = []
	for f in 4:
		var a: Vector2 = corners[f]
		var b: Vector2 = corners[(f + 1) % 4]
		for k in N:
			var z0: float = levels[k]
			var z1: float = levels[k + 1]
			var h0: float = hs.call(z0)
			var h1: float = hs.call(z1)
			if p.brace == "X" or k % 2 == 0:
				braces.append(PackedVector3Array([Vector3(a.x * h0, a.y * h0, z0), Vector3(b.x * h1, b.y * h1, z1)]))
			if p.brace == "X" or k % 2 == 1:
				braces.append(PackedVector3Array([Vector3(b.x * h0, b.y * h0, z0), Vector3(a.x * h1, a.y * h1, z1)]))
	G.braces = braces
	var base_sq := PackedVector2Array()
	for c: Vector2 in corners:
		base_sq.append(Vector2(c.x * b2, c.y * b2))
	G.baseSq = base_sq
	G.platform = A.rect_p(-t2 - 0.35, -t2 - 0.35, t2 + 0.35, t2 + 0.35)
	var arms: Array = []
	for c: Vector2 in corners:
		arms.append(PackedVector3Array([Vector3(c.x * (t2 + 0.35), c.y * (t2 + 0.35), H + 0.4),
			Vector3(c.x * (t2 + 0.35 + p.aerial_arm * 0.7), c.y * (t2 + 0.35 + p.aerial_arm * 0.7), H + 0.4)]))
	G.arms = arms
	var footings: Array = []
	for c: Vector2 in corners:
		footings.append(A.rect_p(c.x * b2 - 0.45, c.y * b2 - 0.45, c.x * b2 + 0.45, c.y * b2 + 0.45))
	G.footings = footings
	var off: float = b2 + 1.9 + p.hut_d / 2.0
	var west: bool = p.hut_side == "west"
	var hut: PackedVector2Array = A.rect_p(-off - p.hut_d / 2.0, -p.hut_w / 2.0, -off + p.hut_d / 2.0, p.hut_w / 2.0) if west \
		else A.rect_p(-p.hut_w / 2.0, -off - p.hut_d / 2.0, p.hut_w / 2.0, -off + p.hut_d / 2.0)
	G.hut = hut
	var hc := A._cen(hut)
	var hw2 := Vector2(p.hut_d / 2.0, p.hut_w / 2.0) if west else Vector2(p.hut_w / 2.0, p.hut_d / 2.0)
	G.hutPanel = A.rect_p(hc.x - hw2.x * 0.55, hc.y - hw2.y * 0.5, hc.x + hw2.x * 0.55, hc.y + hw2.y * 0.5)   # accent zone: painted panel on the hut roof
	G.hutEave = offset_poly(hut, 0.3)
	G.vent = A.circ(Vector2(hc.x + hw2.x * 0.68, hc.y - hw2.y * 0.68), 0.22, 10)
	if west:
		G.cable = PackedVector2Array([Vector2(hc.x + p.hut_d / 2.0, hc.y + 0.6), Vector2(-b2, 0.6)])
	else:
		G.cable = PackedVector2Array([Vector2(hc.x + 0.6, hc.y + p.hut_d / 2.0), Vector2(0.6, -b2)])
	var ext: Array = []
	for f: PackedVector2Array in footings:
		ext.append(f)
	ext.append(hut)
	for a: PackedVector3Array in arms:
		ext.append(_flat(a))
	G.ext = ext
	return G

static func draw_tower_ground(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color) -> void:
	var G := M.G
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	dirt(g, ink, V.tps(offset_poly(G.baseSq, -0.6)), A._rng(pn), 2.6)
	A._line(pn, G.cable, {"alpha": 0.6, "weight": 0.6, "breaks": 0.35, "freq": 0.25})
	for f: PackedVector2Array in G.footings:
		A._path(pn, f, {"fill": ink.rock, "weight": 0.8})
	var h_o := A._path(pn, G.hut, {"fill": ink.roof, "weight": 0.0})
	if ppm > 3.0:
		A._path(pn, G.hutEave, {"weight": 0.5, "alpha": 0.4})
	A.accent_panel(pn, G.hutPanel, accent)
	A._path(pn, G.vent, {"fill": ink.fill, "weight": 0.6})
	A.stroke_o(g, ink, h_o, 1.2)

static func draw_tower_upper(g, M: A.Model, V: A.View, ink: A.Ink) -> void:
	var G := M.G
	var pn := A.Pen.new(g, V, ink, M.seed + 9)
	var ppm := V.ppm
	for s: PackedVector3Array in G.girts:
		A._line(pn, _flat(s), {"weight": 0.5, "alpha": 0.6, "breaks": 0.12})
	for s: PackedVector3Array in G.braces:
		A._line(pn, _flat(s), {"weight": 0.45, "alpha": 0.62})
	for s: PackedVector3Array in G.legs:
		A._line(pn, _flat(s), {"weight": 0.95, "alpha": 1.0})
	for a: PackedVector3Array in G.arms:
		A._line(pn, _flat(a), {"weight": 0.55, "alpha": 0.8})
		var q := V.tp(Vector2(a[1].x, a[1].y))
		g.fill_color = ink.ink
		g.begin_path()
		g.arc(q.x, q.y, 0.8, 0.0, TAU)
		g.fill()
	var o := A._path(pn, G.platform, {"fill": ink.fill, "weight": 0.0})
	A.hatch_lines(g, ink, o, V.tv(Vector2(1.0, 0.0)), maxf(1.3, 0.2 * ppm), {"alpha": 0.45, "weight": 0.45})
	A.stroke_o(g, ink, o, 0.9)

# --- the cast shadow ---------------------------------------------------------------------------------------

# The sheet's maskOps for a ground unit, as primitives in px under View V: [{kind: "fill", pts} |
# {kind: "stroke", pts: [Vector2...], w}], each point already moved along the shadow by its height. Every part
# is cast along the shadow direction by its height x the sun's length (UiStyle.sun_len): the prototype's rule.
static func shadow_prims(M: A.Model, V: A.View, ink: A.Ink, st: UiStyle, band: Dictionary) -> Array:
	var G := M.G
	var p := M.p
	var out: Array = []
	var sd := ink.sd
	var k := V.ppm * st.sun_len()
	if M.silhouette == "anti_aircraft_battery":
		# the sandbag ring: each segment of the band and the same segment raised by the bag's height
		var hh := float(band["h"]) * st.sun_len()
		var off := sd * hh
		var lp: PackedVector2Array = band["L"]
		var rp: PackedVector2Array = band["R"]
		var n := lp.size()
		var lim := n if bool(band["closed"]) else n - 1
		for i in lim:
			var j := (i + 1) % n
			out.append({"kind": "fill", "pts": _raised_hull(PackedVector2Array([lp[i], lp[j], rp[j], rp[i]]), off)})
		for cp: PackedVector2Array in band["caps"]:
			out.append({"kind": "fill", "pts": _raised_hull(cp, off)})
		# the gun mount: the cradle and the shield as prisms 1.55 m high
		for poly: PackedVector2Array in [G.cradle, G.shield]:
			out.append({"kind": "fill", "pts": _prism_hull(V.tps(poly), sd * 1.55 * k)})
		# the barrels: lines with their heights
		for ln: PackedVector3Array in G.barrel_lines:
			out.append({"kind": "stroke", "pts": _lift(V, ln, sd, k), "w": maxf(0.9, 0.13 * V.ppm)})
	elif M.silhouette == "radio_tower":
		out.append({"kind": "fill", "pts": _prism_hull(V.tps(G.hut), sd * float(p.hut_h) * k)})
		for ln: PackedVector3Array in G.legs:
			out.append({"kind": "stroke", "pts": _lift(V, ln, sd, k), "w": maxf(1.1, 0.32 * V.ppm)})
		for ln: PackedVector3Array in G.girts:
			out.append({"kind": "stroke", "pts": _lift(V, ln, sd, k), "w": maxf(0.7, 0.12 * V.ppm)})
		for ln: PackedVector3Array in G.braces:
			out.append({"kind": "stroke", "pts": _lift(V, ln, sd, k), "w": maxf(0.7, 0.12 * V.ppm)})
		# the platform floats at the top: the polygon moved by the full height
		var plat := V.tps(G.platform)
		var moved := PackedVector2Array()
		for q in plat:
			moved.append(q + sd * float(p.height) * k)
		out.append({"kind": "fill", "pts": moved})
		for ln: PackedVector3Array in G.arms:
			out.append({"kind": "stroke", "pts": _lift(V, ln, sd, k), "w": maxf(0.6, 0.08 * V.ppm)})
	return out

# hull(pts + pts moved by `off`): a raised part's shadow.
static func _raised_hull(pts: PackedVector2Array, off: Vector2) -> PackedVector2Array:
	var all := PackedVector2Array(pts)
	for q in pts:
		all.append(q + off)
	return Geometry2D.convex_hull(all)

# A prism: its footprint (px) and the footprint moved by `off`.
static func _prism_hull(foot: PackedVector2Array, off: Vector2) -> PackedVector2Array:
	return _raised_hull(foot, off)

# A 3D line's points in px: the plan position moved along the shadow by the height.
static func _lift(V: A.View, ln: PackedVector3Array, sd: Vector2, k: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in ln:
		out.append(V.tp(Vector2(q.x, q.y)) + sd * q.z * k)
	return out

# --- the bake ---------------------------------------------------------------------------------------------------

# One static unit baked at `ppm` and already turned by `rot` (the sheet's View rotation: the marker's
# sprite angle, heading + 90 degrees): the art, and the cast shadow as the mask, in one frame and size.
static func bake(st: UiStyle, M: A.Model, accent: Color, ppm: float, rot: float) -> A.Art:
	var margin: float = st.num("unit_art.bake_margin_px")
	var ink := A.ink_consts(st)
	var is_aa := M.silhouette == "anti_aircraft_battery"
	# 1. where everything reaches, in a provisional frame (a shift of the whole picture changes nothing)
	var v0 := A.View.new(0.0, 0.0, ppm, rot)
	var band0: Dictionary = prep_aa(M, v0, ink) if is_aa else {}
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for poly: PackedVector2Array in M.G.ext:
		for q in v0.tps(poly):
			lo = lo.min(q)
			hi = hi.max(q)
	for pr: Dictionary in shadow_prims(M, v0, ink, st, band0):
		var half := float(pr.get("w", 0.0)) * 0.5
		for q: Vector2 in pr["pts"]:
			lo = lo.min(q - Vector2(half, half))
			hi = hi.max(q + Vector2(half, half))
	if is_aa:
		for q: Vector2 in band0["L"]:
			lo = lo.min(q)
			hi = hi.max(q)
		for q: Vector2 in band0["R"]:
			lo = lo.min(q)
			hi = hi.max(q)
	var size := Vector2i(ceili(hi.x - lo.x + 2.0 * margin), ceili(hi.y - lo.y + 2.0 * margin))
	var v := A.View.new(-lo.x + margin, -lo.y + margin, ppm, rot)
	# 2. the art
	var canvas := InkCanvas.new(size)
	canvas.line_cap = "round"
	if is_aa:
		var band := prep_aa(M, v, ink)
		draw_aa_ground(canvas, M, v, ink, accent, band)
		draw_aa_upper(canvas, M, v, ink)
	else:
		draw_tower_ground(canvas, M, v, ink, accent)
		draw_tower_upper(canvas, M, v, ink)
	# 3. the cast shadow, white, as one mask (overlaps merge: one alpha channel, tinted once by the layer)
	var mask := InkCanvas.new(size)
	mask.line_cap = "round"
	mask.fill_color = Color.WHITE
	mask.stroke_color = Color.WHITE
	var band_v: Dictionary = prep_aa(M, v, ink) if is_aa else {}
	mask.begin_path()
	for pr: Dictionary in shadow_prims(M, v, ink, st, band_v):
		if pr["kind"] == "fill":
			A.add_poly(mask, pr["pts"], true)
	mask.fill()
	for pr: Dictionary in shadow_prims(M, v, ink, st, band_v):
		if pr["kind"] == "stroke":
			mask.line_width = float(pr["w"])
			mask.begin_path()
			A.add_poly(mask, pr["pts"], false)
			mask.stroke()
	var imgs := InkCanvas.render_all([canvas, mask])
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(v.x, v.y)
	art.size_px = size
	art.screen_aligned = true
	art.rot = rot
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far
	if imgs.size() == 2 and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(A._straight(imgs[1], true))
	return art


# =====================================================================================================================
# THE MILITARY COMPLEX (Track M2U, mission 2, 2026-10-11): the second mission's target, a fenced compound of a main
# building (a hangar, a factory hall or a barracks range), sheds, tanks or a chimney, a yard with vehicles and crates, a gate and
# a gatehouse, drawn in the VILLAGE'S building language (scripts/render/ink_structs.gd draw_house: each roof in two
# halves, the half turned from the sun in the shaded roof tone, an inset eave line, the outline, the ridge; the wall fill and
# its slope tone; the prism shadow of the part heights) and in the unit sheet's pen. A static target that never turns, so it is
# BAKED ALREADY TURNED by its heading like the tower and the battery (Art.screen_aligned).
#
#   var art := UnitMarkerArtStatic.complex_art(style, accent, ppm, rot)        # standing; what the one dispatch line calls
#   var ruin := UnitMarkerArtStatic.complex_ruin_art(style, ppm, rot)          # destroyed, R1's language; for the effects layer
#   art.mask      the CAST SHADOW (every part by its height), as the tower's
#
# DRAWN AT THE MAP'S SCALE, not the units' (the brief: "a static target drawn at the map's scale"; the way a bridge is): the
# marker layer sizes a marker at the plane rule, 4 px per metre at zoom 1 against the map's 2, so the geometry is drawn at
# data military_complex.map_scale_factor (PROPOSED, 0.5) of the baked scale and the Art's `ppm` stays the layer's, which is
# what the marker multiplies by (Art.extent_m is in the layer's metres too, so the hit radius is the drawn one).
#
# THREE LOOKS, judged on variants/military-complex/ (scripts/ui/boards/military_complex_board_shot.gd): A a hangar yard, B
# works with a saw-tooth hall and a chimney, C barracks and a depot in a low wall. Which one the game draws is ui.json
# unit_art.variant.military_complex when it has it, else the data's default_look (PROPOSED).
# ONE ACCENT ZONE: a recognition panel painted on the main roof (the radio tower's hut roof panel, as it were). COLOUR is a
# role (the palette's, plus data's roles block); material is linework. No hex.

const MC_DATA_PATH := "res://data/ui/unit_art_mission2.json"
const MC_SILHOUETTE := "military_complex"
const InkRoles = preload("res://scripts/render/ink_roles.gd")

static var _mc_all: Dictionary = {}
static var _mc_models: Dictionary = {}
static var _mc_roles: Dictionary = {}

# A TRACE of the sub-draws that ran to their end, for the test (test_mission2_units): with `mc_tracing` on, each sub-draw appends
# its name as its LAST statement, so a runtime error that aborts one half-way leaves its name out.
static var mc_tracing: bool = false
static var mc_trace: Array[String] = []

static func _mct(what: String) -> void:
	if mc_tracing:
		mc_trace.append(what)

static func mc_all() -> Dictionary:
	if _mc_all.is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(MC_DATA_PATH))
		if v is Dictionary:
			_mc_all = v
		else:
			push_error("unit_marker_art_static: %s does not parse as a JSON object" % MC_DATA_PATH)
	return _mc_all

static func mc_data() -> Dictionary:
	return mc_all()["military_complex"]

static func mc_val(rec: Variant) -> Variant:
	if rec is Dictionary and (rec as Dictionary).has("value"):
		return (rec as Dictionary)["value"]
	return rec

static func mc_looks() -> Array:
	return mc_data()["looks"]

static func mc_look_of(st: RefCounted) -> int:
	var v: Variant = st.lookup("unit_art.variant." + MC_SILHOUETTE)
	if v is float or v is int:
		return clampi(int(v), 0, mc_looks().size() - 1)
	return int(mc_val(mc_data()["default_look"]))

# The geometry's share of the marker's baked scale (data map_scale_factor).
static func mc_scale_factor() -> float:
	return float(mc_val(mc_data()["map_scale_factor"]))

# The share of the complex's size_m the effects layer sizes a destroyed complex's flash and smoke by (data ruin.effects_size_frac).
static func mc_effects_frac() -> float:
	return float(mc_val((mc_data()["ruin"] as Dictionary)["effects_size_frac"]))

static func mc_roles(st: RefCounted) -> Dictionary:
	if _mc_roles.is_empty():
		var errs: Array = []
		_mc_roles = InkRoles.resolve_all(st, mc_all()["roles"], errs)
		for e: Variant in errs:
			push_error("unit_marker_art_static: " + str(e))
	return _mc_roles

static func _mc_rr(rng: Mulberry32, pair: Variant) -> float:
	var a: Array = pair
	return A._r(rng, float(a[0]), float(a[1]))

static func mc_model(st: RefCounted, look: int = -1) -> A.Model:
	if look < 0:
		look = mc_look_of(st)
	var key := "%s|%d|%d" % [MC_SILHOUETTE, look, st.scene_seed]
	if _mc_models.has(key):
		return _mc_models[key]
	var m := A.Model.new()
	m.silhouette = MC_SILHOUETTE
	m.variant = look
	m.seed = A.unit_seed(st.scene_seed, int(mc_val(mc_data()["sheet_index"])), look)
	m.p = gen_complex(look, Mulberry32.new(m.seed))
	m.G = build_complex(m.p)
	_mc_models[key] = m
	return m

# genComplex(look, rng): every draw in the data's order, then the spare jitter stream.
static func gen_complex(look: int, rng: Mulberry32) -> Dictionary:
	var d := mc_data()
	var L: Dictionary = (d["looks"] as Array)[look]
	var p := {}
	p.look = look
	p.kind = str(L["id"])
	var fp: Array = mc_val(d["footprint_m"])
	p.fw = float(fp[0])
	p.fd = float(fp[1])
	p.fence = str(L["fence"])
	p.gate = str(L["gate"])
	p.main_w = _mc_rr(rng, (L["main"] as Dictionary)["w"])
	p.main_d = _mc_rr(rng, (L["main"] as Dictionary)["d"])
	var ranges: Dictionary = L["ranges"]
	for key: String in ranges:
		p[key] = _mc_rr(rng, ranges[key])
	p.jseed = int(rng.next() * 2147483646.0)
	return p

# --- the geometry (metres; x east, y south; the compound's centre is the origin) --------------------------------------

static func _rot_rect(c: Vector2, w: float, d: float, rot: float) -> PackedVector2Array:
	return place(A.rect_p(-w / 2.0, -d / 2.0, w / 2.0, d / 2.0), c.x, c.y, rot)

# One thing standing in the compound: kind, a name, its centre, its size (w along its own x, d along its own y), its turn,
# the height of its crown and of its eaves (metres, for the cast shadow) and its footprint.
static func _part(kind: String, name: String, c: Vector2, w: float, d: float, rot: float, h: float, eave: float = -1.0) -> Dictionary:
	var poly := A.circ(c, w / 2.0, 24) if kind == "tank" else _rot_rect(c, w, d, rot)
	return {"kind": kind, "name": name, "c": c, "w": w, "d": d, "rot": rot, "h": h, "eave": h * 0.62 if eave < 0.0 else eave, "poly": poly}

# The fence or wall ring as an open polyline with the gate's gap: from one side of the gate round to the other.
static func _ring(hx: float, hy: float, gate: String, gh: float) -> PackedVector2Array:
	if gate == "west":
		return PackedVector2Array([Vector2(-hx, gh), Vector2(-hx, hy), Vector2(hx, hy), Vector2(hx, -hy), Vector2(-hx, -hy), Vector2(-hx, -gh)])
	return PackedVector2Array([Vector2(gh, hy), Vector2(hx, hy), Vector2(hx, -hy), Vector2(-hx, -hy), Vector2(-hx, hy), Vector2(-gh, hy)])

# The accent panel on a roof of centre c and size (w, d): a rectangle `pw` long beside x offset fx, on each of the two halves
# (north first), taking most of the half's pitch.
static func _panels(c: Vector2, w: float, d: float, fx: float, pw: float) -> Array:
	var ph := d * 0.34
	var x0 := c.x + fx
	var gap := d * 0.08
	return [A.rect_p(x0, c.y - gap - ph, x0 + pw, c.y - gap), A.rect_p(x0, c.y + gap, x0 + pw, c.y + gap + ph)]

static func _jit(rng: Mulberry32, amp: float) -> Vector2:
	var a := rng.next() - 0.5
	var b := rng.next() - 0.5
	return Vector2(a, b) * 2.0 * amp

static func build_complex(p: Dictionary) -> Dictionary:
	var G := {}
	var hts: Dictionary = mc_val(mc_data()["heights_m"])
	var hx: float = float(p.fw) / 2.0 - 4.0
	var hy: float = float(p.fd) / 2.0 - 4.0
	var jr := Mulberry32.new(int(p.jseed))
	var J: float = float(p.jitter)
	var parts: Array = []
	var gate_half := 4.5
	var gate_pt := Vector2(0.0, hy)
	var routes: Array = []
	G.apron = PackedVector2Array()
	G.pipes = []
	G.heaps = []
	var panels: Array = []   # the accent panel's two places, one on each roof half: the lit half's is drawn
	var mw: float = p.main_w
	var md: float = p.main_d
	match str(p.kind):
		"hangar_yard":
			var mc := Vector2(-3.0, -hy + 3.5 + md / 2.0) + _jit(jr, J)
			parts.append(_part("barrel", "main", mc, mw, md, 0.0, float(hts["hangar"]), float(hts["hangar"]) * 0.62))
			var ap := float(p.apron_extra)
			G.apron = A.rect_p(mc.x - mw / 2.0 - 3.0, mc.y + md / 2.0, mc.x + mw / 2.0 + 3.0, mc.y + md / 2.0 + ap)
			var sw: float = p.shed_w
			var sd_: float = p.shed_d
			var sx := hx - 3.5 - sw / 2.0
			var s1 := Vector2(sx, -hy + 6.0 + sd_ / 2.0) + _jit(jr, J) * 0.5
			var s2 := Vector2(sx, s1.y + sd_ + 3.6) + _jit(jr, J) * 0.5
			parts.append(_part("gable", "shed", s1, sw, sd_, 0.0, float(hts["shed"])))
			parts.append(_part("gable", "shed", s2, sw, sd_, 0.0, float(hts["shed"])))
			var tr: float = p.tank_r
			parts.append(_part("tank", "tank", Vector2(-hx + 4.0 + tr, 3.0), tr * 2.0, tr * 2.0, 0.0, float(hts["tank"])))
			parts.append(_part("tank", "tank", Vector2(-hx + 4.0 + tr, 3.0 + 2.0 * tr + 2.6), tr * 2.0, tr * 2.0, 0.0, float(hts["tank"])))
			var nt := clampi(int(round(float(p.trucks))), 1, 5)
			for i in nt:
				var q := Vector2(-16.0 + float(i) * 9.5, hy - 10.5) + _jit(jr, J) * 0.4
				parts.append(_part("truck", "truck", q, 5.6, 2.4, (jr.next() - 0.5) * 0.3 + (PI if i % 2 == 1 else 0.0), float(hts["truck"])))
			parts.append(_part("gable", "gatehouse", Vector2(-10.0, hy - 2.2), 4.6, 3.2, 0.0, float(hts["gatehouse"])))
			parts.append(_part("tower", "tower", Vector2(hx - 1.6, -hy + 1.6), 2.4, 2.4, 0.0, float(hts["tower"])))
			parts.append(_part("tower", "tower", Vector2(-hx + 1.6, hy - 1.6), 2.4, 2.4, 0.0, float(hts["tower"])))
			panels = _panels(mc, mw, md, mw * 0.12, 7.0)
			routes = [[gate_pt, Vector2(0.0, hy - 14.0), Vector2(mc.x, mc.y + md / 2.0 + ap * 0.5)]]
		"works":
			var mc := Vector2(-hx + 5.0 + mw / 2.0, -hy + 3.5 + md / 2.0) + _jit(jr, J)
			parts.append(_part("saw", "main", mc, mw, md, 0.0, float(hts["hall"]), float(hts["hall"]) * 0.8))
			var bw: float = p.boiler_w
			var bd: float = p.boiler_d
			var bc := Vector2(mc.x + mw / 2.0 + 4.0 + bw / 2.0, mc.y + 1.0) + _jit(jr, J) * 0.5
			parts.append(_part("gable", "boiler", bc, bw, bd, 0.0, float(hts["shed"]) + 1.5))
			var stw: float = p.stack_w
			# the chimney stands at the east end of the boiler house, so its long shadow falls across open ground to the south-east
			parts.append(_part("stack", "stack", Vector2(bc.x + bw / 2.0 + 2.6, bc.y - bd / 2.0 + 1.6), stw, stw, 0.0, float(hts["stack"])))
			G.pipes = [PackedVector2Array([Vector2(mc.x + mw / 2.0, bc.y - 0.5), Vector2(bc.x - bw / 2.0, bc.y - 0.5)]),
				PackedVector2Array([Vector2(mc.x + mw / 2.0, bc.y + 0.5), Vector2(bc.x - bw / 2.0, bc.y + 0.5)])]
			var sw: float = p.shed_w
			var sd_: float = p.shed_d
			for k in 3:
				var q := Vector2(mc.x - mw / 2.0 + 3.0 + sw / 2.0, mc.y + md / 2.0 + 5.0 + sd_ / 2.0 + float(k) * (sd_ + 2.6)) + _jit(jr, J) * 0.4
				parts.append(_part("gable", "shed", q, sw, sd_, 0.0, float(hts["shed"])))
			G.heaps = [{"c": Vector2(hx - 11.0, hy - 9.0), "r": float(p.heap_r)}]
			for i in 2:
				parts.append(_part("truck", "truck", Vector2(6.0 + float(i) * 8.0, hy - 5.0 - float(i) * 3.0) + _jit(jr, J) * 0.3, 5.6, 2.4, (jr.next() - 0.5) * 0.3 + (PI if i == 1 else 0.0), float(hts["truck"])))
			parts.append(_part("gable", "gatehouse", Vector2(-hx + 4.0, 8.5), 3.2, 4.6, 0.0, float(hts["gatehouse"])))
			parts.append(_part("tower", "tower", Vector2(hx - 1.6, hy - 1.6), 2.4, 2.4, 0.0, float(hts["tower"])))
			parts.append(_part("tower", "tower", Vector2(-hx + 1.6, -hy + 1.6), 2.4, 2.4, 0.0, float(hts["tower"])))
			gate_pt = Vector2(-hx, 0.0)
			var pr := A.rect_p(mc.x - mw * 0.1 - 4.0, mc.y - 2.7, mc.x - mw * 0.1 + 4.0, mc.y + 2.7)   # across the teeth, mid-hall (a canton in a corner would read as a flag)
			panels = [pr, pr]
			routes = [[gate_pt, Vector2(-hx + 10.0, 2.0), Vector2(mc.x, mc.y + md / 2.0 + 2.5), Vector2(bc.x, bc.y + bd / 2.0 + 4.0)]]
		_:
			var north := Vector2(0.0, -hy + 2.5 + md / 2.0) + _jit(jr, J) * 0.5
			parts.append(_part("gable", "main", north, mw, md, 0.0, float(hts["barracks"])))
			var swd: float = p.side_w
			var sdp: float = p.side_d
			var sy := north.y + md / 2.0 + 2.0 + sdp / 2.0
			parts.append(_part("gable", "range", Vector2(-hx + 3.5 + swd / 2.0, sy) + _jit(jr, J) * 0.4, sdp, swd, PI / 2.0, float(hts["barracks"])))
			parts.append(_part("gable", "range", Vector2(hx - 3.5 - swd / 2.0, sy) + _jit(jr, J) * 0.4, sdp, swd, PI / 2.0, float(hts["barracks"])))
			var dw: float = p.depot_w
			var dd: float = p.depot_d
			parts.append(_part("gable", "depot", Vector2(hx - 3.5 - dw / 2.0, sy + sdp / 2.0 + 2.5 + dd / 2.0) + _jit(jr, J) * 0.3, dw, dd, 0.0, float(hts["shed"]) + 1.0))
			var nt := clampi(int(round(float(p.trucks))), 1, 5)
			for i in nt:
				var q := Vector2(-12.0 + float(i) * 6.8, sy + 2.0 + float(i % 2) * 5.0) + _jit(jr, J) * 0.4
				parts.append(_part("truck", "truck", q, 5.6, 2.4, (jr.next() - 0.5) * 0.3 + (PI / 2.0 if i % 2 == 1 else 0.0), float(hts["truck"])))
			parts.append(_part("crates", "crates", Vector2(-hx + 10.0, hy - 7.0), 5.0, 2.6, 0.0, 1.8))
			parts.append(_part("crates", "crates", Vector2(-hx + 16.0, hy - 6.5), 2.6, 2.6, 0.0, 1.8))
			parts.append(_part("gable", "gatehouse", Vector2(-gate_half - 3.2, hy - 2.2), 4.6, 3.2, 0.0, float(hts["gatehouse"])))
			G.flag = Vector2(0.0, sy - 2.0)
			panels = _panels(north, mw, md, mw * 0.2, 7.0)
			routes = [[gate_pt, Vector2(0.0, sy + 6.0), Vector2(0.0, sy - 4.0)]]
	G.parts = parts
	G.panels = panels   # accent zone: the recognition panel on the main roof, on whichever half is lit (draw_complex chooses)
	G.hx = hx
	G.hy = hy
	G.gate = str(p.gate)
	G.gate_half = gate_half
	G.gate_pt = gate_pt
	G.routes = routes
	G.ring = _ring(hx, hy, str(p.gate), gate_half)
	G.yard = A.rect_p(-hx + 1.0, -hy + 1.0, hx - 1.0, hy - 1.0)
	var ext: Array = [A.rect_p(-hx - 1.0, -hy - 1.0, hx + 1.0, hy + 1.0)]
	for pt: Dictionary in parts:
		ext.append(pt["poly"])
	G.ext = ext
	return G

# --- drawing -------------------------------------------------------------------------------------------------------------------

static func _dir_of(V: A.View, rot: float, v: Vector2) -> Vector2:
	return V.tv(v.rotated(rot))

# A roof in the village's two halves along its long axis: the half turned from the sun in the shaded roof tone, ribs across the pitch
# (corrugated sheet in place of the village's thatch strokes), an inset eave line, the outline, the ridge.
static func _draw_roof(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, part: Dictionary, barrel: bool) -> void:
	var c: Vector2 = part["c"]
	var w: float = part["w"]
	var d: float = part["d"]
	var rot: float = part["rot"]
	var ppm := V.ppm
	var dark: Color = rl["roof_shaded"]
	var rib_sp := 1.5 if ppm > 3.0 else 3.0
	var shaded_o := PackedVector2Array()
	for sg: float in [-1.0, 1.0]:
		var half := place(A.rect_p(-w / 2.0, minf(0.0, sg * d / 2.0), w / 2.0, maxf(0.0, sg * d / 2.0)), c.x, c.y, rot)
		var shaded := _dir_of(V, rot, Vector2(0.0, sg)).dot(ink.sd) > 0.0
		var o := A._path(pn, half, {"fill": dark if shaded else ink.roof, "weight": 0.0})
		if shaded:
			shaded_o = o
		if ppm > 1.2:
			var x := -w / 2.0 + 0.9
			var rng := A._rng(pn)
			while x < w / 2.0 - 0.6:
				if rng.next() > 0.12:
					A._line(pn, place(PackedVector2Array([Vector2(x, sg * 0.35), Vector2(x, sg * (d / 2.0 - 0.35))]), c.x, c.y, rot), {"alpha": 0.3, "weight": 0.45})
				x += rib_sp
	if barrel and ppm > 1.2:   # the vault: two lines along each half
		for sg: float in [-1.0, 1.0]:
			for f: float in [0.34, 0.68]:
				A._line(pn, place(PackedVector2Array([Vector2(-w / 2.0 + 0.5, sg * d / 2.0 * f), Vector2(w / 2.0 - 0.5, sg * d / 2.0 * f)]), c.x, c.y, rot), {"alpha": 0.3, "weight": 0.45, "breaks": 0.1})
	if shaded_o.size() > 2:
		A.edge_hatch(g, ink, shaded_o, minf(4.0, 0.3 * ppm), A._rng(pn))
	if ppm > 3.0 and not barrel:
		A._path(pn, place(A.rect_p(-w / 2.0 + 1.0, -d / 2.0 + 1.0, w / 2.0 - 1.0, d / 2.0 - 1.0), c.x, c.y, rot), {"weight": 0.5, "alpha": 0.4})
	A._path(pn, part["poly"], {"weight": 1.2})
	A._line(pn, place(PackedVector2Array([Vector2(-w / 2.0, 0.0), Vector2(w / 2.0, 0.0)]), c.x, c.y, rot), {"weight": 1.05, "alpha": 1.0})
	_mct("roof")

# A saw-tooth roof: a long slope turned from the sun in the shaded roof tone and a narrow glazed face, over and over.
static func _draw_saw(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, part: Dictionary, teeth: int) -> void:
	var c: Vector2 = part["c"]
	var w: float = part["w"]
	var d: float = part["d"]
	var rot: float = part["rot"]
	var ppm := V.ppm
	var dark: Color = rl["roof_shaded"]
	var pitch := d / float(teeth)
	for i in teeth:
		var y0 := -d / 2.0 + float(i) * pitch
		var wide := place(A.rect_p(-w / 2.0, y0, w / 2.0, y0 + pitch * 0.62), c.x, c.y, rot)
		var o := A._path(pn, wide, {"fill": dark, "weight": 0.0})
		if ppm > 1.2:
			A.hatch_lines(g, ink, o, V.tv(Vector2(1.0, 0.0).rotated(rot)), maxf(1.8, 0.14 * ppm * 6.0), {"alpha": 0.14, "weight": 0.4})
		var glaze := place(A.rect_p(-w / 2.0, y0 + pitch * 0.62, w / 2.0, y0 + pitch), c.x, c.y, rot)
		var go := A._path(pn, glaze, {"fill": ink.roof, "weight": 0.0})
		if ppm > 2.0:
			A.hatch_lines(g, ink, go, V.tv(Vector2(0.0, 1.0).rotated(rot)), maxf(3.0, 0.25 * ppm * 3.0), {"alpha": 0.4, "weight": 0.45})
		A._line(pn, place(PackedVector2Array([Vector2(-w / 2.0, y0), Vector2(w / 2.0, y0)]), c.x, c.y, rot), {"alpha": 0.7, "weight": 0.6})
		A._line(pn, place(PackedVector2Array([Vector2(-w / 2.0, y0 + pitch * 0.62), Vector2(w / 2.0, y0 + pitch * 0.62)]), c.x, c.y, rot), {"alpha": 0.7, "weight": 0.6})
	A._path(pn, part["poly"], {"weight": 1.2})
	_mct("saw")

static func _draw_tank_cyl(g, pn: A.Pen, V: A.View, ink: A.Ink, part: Dictionary) -> void:
	var c: Vector2 = part["c"]
	var r: float = float(part["w"]) / 2.0
	var ppm := V.ppm
	var o := A._path(pn, part["poly"], {"fill": ink.fill, "weight": 0.0})
	A.shade_side(g, o, V.tp(c), ink.sd, ink.fill_shaded)
	A.edge_hatch(g, ink, o, minf(4.0, 0.3 * ppm), A._rng(pn))
	A.stroke_o(g, ink, o, 1.1)
	if ppm > 1.5:
		A._path(pn, A.circ(c, r * 0.72, 20), {"weight": 0.5, "alpha": 0.45})
	if ppm > 3.0:
		A._path(pn, A.circ(c + Vector2(-r * 0.2, -r * 0.2), r * 0.18, 10), {"fill": ink.fill, "weight": 0.6})
	_mct("tank")

static func _draw_stack(g, pn: A.Pen, V: A.View, ink: A.Ink, part: Dictionary) -> void:
	var c: Vector2 = part["c"]
	var w: float = part["w"]
	var ppm := V.ppm
	var o := A._path(pn, part["poly"], {"fill": ink.fill, "weight": 0.0})
	A.hatch_lines(g, ink, o, V.tv(Vector2(1.0, 1.0).normalized()), maxf(1.6, 0.15 * ppm * 4.0), {"alpha": 0.35, "weight": 0.45})
	A.shade_side(g, o, V.tp(c), ink.sd, ink.fill_shaded)
	A.stroke_o(g, ink, o, 1.2)
	A._path(pn, place(A.rect_p(-w * 0.28, -w * 0.28, w * 0.28, w * 0.28), c.x, c.y, 0.0), {"fill": ink.fill_shaded, "weight": 0.8})
	_mct("stack")

static func _draw_tower(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, part: Dictionary) -> void:
	var c: Vector2 = part["c"]
	var dark: Color = rl["roof_shaded"]
	var rs := 1.7   # the hip roof of the watch platform: half its side
	var corners := [Vector2(-rs, -rs), Vector2(rs, -rs), Vector2(rs, rs), Vector2(-rs, rs)]
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var mid := (a + b) * 0.5
		var shaded := V.tv(mid.normalized()).dot(ink.sd) > 0.0
		A._path(pn, PackedVector2Array([c + a, c + b, c]), {"fill": dark if shaded else ink.roof, "weight": 0.0})
	A._path(pn, PackedVector2Array([c + corners[0], c + corners[1], c + corners[2], c + corners[3]]), {"weight": 1.0})
	for i in 2:
		A._line(pn, PackedVector2Array([c + corners[i], c + corners[i + 2]]), {"alpha": 0.7, "weight": 0.6})
	_mct("tower")

static func _draw_truck(g, pn: A.Pen, V: A.View, ink: A.Ink, part: Dictionary) -> void:
	var c: Vector2 = part["c"]
	var w: float = part["w"]
	var d: float = part["d"]
	var rot: float = part["rot"]
	var ppm := V.ppm
	var box := place(A.rect_p(-w / 2.0, -d / 2.0, w / 2.0 - 1.9, d / 2.0), c.x, c.y, rot)
	var cab := place(A.rect_p(w / 2.0 - 1.8, -d / 2.0 + 0.1, w / 2.0, d / 2.0 - 0.1), c.x, c.y, rot)
	var wind := place(A.rect_p(w / 2.0 - 0.7, -d / 2.0 + 0.3, w / 2.0 - 0.25, d / 2.0 - 0.3), c.x, c.y, rot)
	var o := A._path(pn, box, {"fill": ink.fill, "weight": 0.9})
	if ppm > 2.4:
		for k in 3:
			var x := -w / 2.0 + 0.9 + float(k) * 1.2
			A._line(pn, place(PackedVector2Array([Vector2(x, -d / 2.0 + 0.2), Vector2(x, d / 2.0 - 0.2)]), c.x, c.y, rot), {"alpha": 0.35, "weight": 0.45})
	A.edge_hatch(g, ink, o, minf(3.0, 0.2 * ppm), A._rng(pn))
	A._path(pn, cab, {"fill": ink.fill, "weight": 0.9})
	A._path(pn, wind, {"fill": ink.glass_lit, "weight": 0.5})
	_mct("truck")

static func _draw_crates(g, pn: A.Pen, V: A.View, ink: A.Ink, part: Dictionary) -> void:
	var c: Vector2 = part["c"]
	var w: float = part["w"]
	var d: float = part["d"]
	var cols := maxi(1, int(round(w / 2.6)))
	var cw := w / float(cols)
	for i in cols:
		var q := Vector2(c.x - w / 2.0 + (float(i) + 0.5) * cw, c.y)
		var o := A._path(pn, A.rect_p(q.x - cw * 0.46, q.y - d * 0.46, q.x + cw * 0.46, q.y + d * 0.46), {"fill": ink.fill, "weight": 0.9})
		if V.ppm > 2.0:
			A._line(pn, PackedVector2Array([Vector2(q.x - cw * 0.46, q.y - d * 0.46), Vector2(q.x + cw * 0.46, q.y + d * 0.46)]), {"alpha": 0.5, "weight": 0.5})
			A._line(pn, PackedVector2Array([Vector2(q.x + cw * 0.46, q.y - d * 0.46), Vector2(q.x - cw * 0.46, q.y + d * 0.46)]), {"alpha": 0.5, "weight": 0.5})
	_mct("crates")

# A heap of coal or earth: a lumpy blob in the dirt colour with stipple and hatching on the side away from the sun.
static func _heap_poly(c: Vector2, r: float, seed_value: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 14:
		var a := float(i) / 14.0 * TAU
		var rr := r * (0.78 + 0.34 * ValueNoise.vnoise(cos(a) * 1.3 + 4.0, sin(a) * 1.3 + 4.0, seed_value))
		pts.append(Vector2(c.x + cos(a) * rr, c.y + sin(a) * rr * 0.85))
	return pts

static func _draw_heap(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, h: Dictionary, seed_value: int) -> void:
	var poly := _heap_poly(h["c"], float(h["r"]), seed_value)
	var o := A._path(pn, poly, {"fill": rl["heap"], "weight": 0.0})
	A.stipple(g, ink, o, {"rng": A._rng(pn), "density": 6.0, "r": 0.5, "alpha": 0.6})
	A.edge_hatch(g, ink, o, minf(4.0, 0.3 * V.ppm), A._rng(pn))
	A.stroke_o(g, ink, o, 1.0)
	_mct("heap")

# Tyre tracks across the yard: two broken lines a vehicle's width apart along each route.
static func _draw_routes(pn: A.Pen, G: Dictionary) -> void:
	for route: Array in G.routes:
		for side: float in [-0.9, 0.9]:
			var pts := PackedVector2Array()
			for i in route.size():
				var a: Vector2 = route[i]
				var tdir: Vector2 = (route[mini(i + 1, route.size() - 1)] - route[maxi(i - 1, 0)]).normalized()
				pts.append(a + Vector2(-tdir.y, tdir.x) * side)
			A._line(pn, pts, {"alpha": 0.32, "weight": 0.55, "breaks": 0.28, "freq": 0.09})
	_mct("routes")

static func _draw_fence(g, pn: A.Pen, V: A.View, ink: A.Ink, G: Dictionary, band: Dictionary, style: String) -> void:
	var ppm := V.ppm
	if style == "wall":
		draw_band(g, ink, band, ink.wall, ink.wall_slope, 0.0)
		_mct("fence")
		return
	var ring: PackedVector2Array = G.ring
	A._path(pn, ring, {"closed": false, "weight": 0.7, "alpha": 0.85, "breaks": 0.06, "wob": 0.5})
	# posts every 4 m, bigger at the corners and the gate
	var px := resample(V.tps(ring), 4.0 * ppm, false)
	g.fill_color = ink.ink
	g.global_alpha = 0.9
	g.begin_path()
	for q in px:
		g.move_to(q.x + 0.55, q.y)
		g.arc(q.x, q.y, 0.55, 0.0, TAU)
	g.fill()
	g.global_alpha = 1.0
	var ge: Array = [ring[0], ring[ring.size() - 1]]
	g.fill_color = ink.ink
	g.begin_path()
	for q: Vector2 in ge:
		var s := V.tp(q)
		g.move_to(s.x + 1.3, s.y)
		g.arc(s.x, s.y, 1.3, 0.0, TAU)
	g.fill()
	# the gate stands open: a leaf swung inward
	var a: Vector2 = ring[0]
	var inward := (Vector2(0.0, -1.0) if str(G.gate) == "south" else Vector2(1.0, 0.0))
	A._line(pn, PackedVector2Array([a, a + inward * G.gate_half * 0.9 + (Vector2(-1.0, 0.0) if str(G.gate) == "south" else Vector2(0.0, -1.0)) * 0.6]), {"alpha": 0.85, "weight": 0.8})
	_mct("fence")

static func _wall_band(V: A.View, ink: A.Ink, G: Dictionary, seed_value: int) -> Dictionary:
	var c := resample(V.tps(G.ring), 3.0, false)
	var b := band_geom(c, 0.9 * V.ppm, seed_value, false, true, ink)
	b["h"] = float(mc_val(mc_data()["fence_h_m"])) * V.ppm   # (only the shadow reads it)
	return b

# drawComplex: the ground (yard, apron, tracks, fence, vehicles) and then the buildings, one canvas.
static func draw_complex(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, rl: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	# the yard: packed earth, a faint wash and stipple
	var yard_o := A._path(pn, G.yard, {"fill": rl["yard"], "weight": 0.0})
	dirt(g, ink, yard_o, A._rng(pn), 2.4)
	_draw_routes(pn, G)
	if (G.apron as PackedVector2Array).size() > 0:
		var ao := A._path(pn, G.apron, {"fill": rl["concrete"], "weight": 0.8, "alpha": 0.8})
		if ppm > 1.2:
			var ar := _bbox_m(G.apron)
			var x := ar.position.x + 6.0
			while x < ar.end.x - 1.0:
				A._line(pn, PackedVector2Array([Vector2(x, ar.position.y), Vector2(x, ar.end.y)]), {"alpha": 0.25, "weight": 0.45})
				x += 6.0
			A._line(pn, PackedVector2Array([Vector2(ar.position.x, ar.position.y + ar.size.y * 0.5), Vector2(ar.end.x, ar.position.y + ar.size.y * 0.5)]), {"alpha": 0.25, "weight": 0.45})
	var band: Dictionary = _wall_band(V, ink, G, (M.seed % 99991) + 31) if str(p.fence) == "wall" else {}
	_draw_fence(g, pn, V, ink, G, band, str(p.fence))
	for pp: PackedVector2Array in G.pipes:
		A._line(pn, pp, {"alpha": 0.8, "weight": 0.8})
	for h: Dictionary in G.heaps:
		_draw_heap(g, pn, V, ink, rl, h, M.seed % 997)
	if G.has("flag"):
		var fq := V.tp(G.flag)
		g.fill_color = ink.ink
		g.begin_path()
		g.move_to(fq.x + 1.0, fq.y)
		g.arc(fq.x, fq.y, 1.0, 0.0, TAU)
		g.fill()
	# the low things, then the buildings
	for pt: Dictionary in G.parts:
		match str(pt["kind"]):
			"truck":
				_draw_truck(g, pn, V, ink, pt)
			"crates":
				_draw_crates(g, pn, V, ink, pt)
			"tank":
				_draw_tank_cyl(g, pn, V, ink, pt)
	for pt: Dictionary in G.parts:
		match str(pt["kind"]):
			"barrel":
				_draw_roof(g, pn, V, ink, rl, pt, true)
			"gable":
				_draw_roof(g, pn, V, ink, rl, pt, false)
			"saw":
				_draw_saw(g, pn, V, ink, rl, pt, int(p.teeth))
	for pt: Dictionary in G.parts:
		match str(pt["kind"]):
			"stack":
				_draw_stack(g, pn, V, ink, pt)
			"tower":
				_draw_tower(g, pn, V, ink, rl, pt)
	var lit_north := V.tv(Vector2(0.0, -1.0)).dot(ink.sd) <= 0.0
	A.accent_panel(pn, (G.panels as Array)[0 if lit_north else 1], accent)
	_mct("complex")

static func _bbox_m(poly: PackedVector2Array) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for q in poly:
		lo = lo.min(q)
		hi = hi.max(q)
	return Rect2(lo, hi - lo)

# --- the cast shadow of the standing compound ----------------------------------------------------------------------------------

static func complex_shadow_prims(M: A.Model, V: A.View, ink: A.Ink, st: UiStyle, band: Dictionary) -> Array:
	var G := M.G
	var out: Array = []
	var k := V.ppm * st.sun_len()
	var sd := ink.sd
	for pt: Dictionary in G.parts:
		var kind := str(pt["kind"])
		var poly_px := V.tps(pt["poly"])
		var h: float = pt["h"]
		match kind:
			"barrel", "gable":
				# the walls to the eaves, the roof to the ridge: the convex hull of the footprint, the footprint at the eave height
				# and the ridge raised to its height
				var all := PackedVector2Array(poly_px)
				for q in poly_px:
					all.append(q + sd * float(pt["eave"]) * k)
				var c: Vector2 = pt["c"]
				var w: float = pt["w"]
				for sx: float in [-1.0, 1.0]:
					all.append(V.tp(c + Vector2(sx * w / 2.0, 0.0).rotated(float(pt["rot"]))) + sd * h * k)
				out.append({"kind": "fill", "pts": Geometry2D.convex_hull(all)})
			"saw", "stack", "truck", "crates", "tank":
				out.append({"kind": "fill", "pts": _prism_hull(poly_px, sd * h * k)})
			"tower":
				var c: Vector2 = pt["c"]
				var roof := V.tps(A.rect_p(c.x - 1.7, c.y - 1.7, c.x + 1.7, c.y + 1.7))
				var all := PackedVector2Array(poly_px)
				for q in roof:
					all.append(q + sd * h * k)
				out.append({"kind": "fill", "pts": Geometry2D.convex_hull(all)})
	if G.has("flag"):
		var fb := V.tp(G.flag)
		out.append({"kind": "stroke", "pts": PackedVector2Array([fb, fb + sd * 11.0 * k]), "w": maxf(0.9, 0.12 * V.ppm)})
	for hp: Dictionary in G.heaps:
		out.append({"kind": "fill", "pts": _prism_hull(V.tps(_heap_poly(hp["c"], float(hp["r"]), M.seed % 997)), sd * 1.8 * k)})
	if not band.is_empty():
		var hh := float(mc_val(mc_data()["fence_h_m"])) * k
		var lp: PackedVector2Array = band["L"]
		var rp: PackedVector2Array = band["R"]
		var n := lp.size()
		for i in n - 1:
			var j := i + 1
			out.append({"kind": "fill", "pts": _raised_hull(PackedVector2Array([lp[i], lp[j], rp[j], rp[i]]), sd * hh)})
	return out

# --- the destroyed compound (R1's language) ------------------------------------------------------------------------------------

static func _crater(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, c: Vector2, r: float, rng: Mulberry32) -> void:
	A._path(pn, A.circ(c, r * 1.2, 22), {"fill": rl["lip"], "weight": 0.0})
	var o := A._path(pn, A.circ(c, r, 22), {"fill": rl["pit"], "weight": 0.9, "alpha": 0.85, "wob": 1.4})
	g.fill_color = rl["scar_dot"]
	g.begin_path()
	var any := false
	for _i in int(r * r * V.ppm * V.ppm * 0.05):
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * r * 0.95
		var q := V.tp(c + Vector2(cos(a), sin(a)) * d)
		g.move_to(q.x + 0.6, q.y)
		g.arc(q.x, q.y, 0.6, 0.0, TAU)
		any = true
	if any:
		g.fill()
	A.edge_hatch(g, ink, o, minf(4.0, 0.4 * V.ppm), rng, 1)
	_mct("crater")

# A heap of broken polygons round `c` within (rx, ry): torn roof and broken masonry, a little shadow offset under each.
static func _rubble(g, pn: A.Pen, V: A.View, ink: A.Ink, rl: Dictionary, c: Vector2, rx: float, ry: float, count: int, rng: Mulberry32, shadows: Array) -> void:
	for j in count:
		var a := rng.next() * TAU
		var dd := sqrt(rng.next())
		var q := c + Vector2(cos(a) * dd * rx, sin(a) * dd * ry)
		var m := 5 + int(rng.next() * 3.0)
		var rr := 0.6 + rng.next() * 1.1
		var poly := PackedVector2Array()
		for i in m:
			var aa := float(i) / float(m) * TAU + (rng.next() - 0.5) * 0.7
			poly.append(q + Vector2(cos(aa), sin(aa)) * rr * (0.55 + rng.next() * 0.45))
		shadows.append(poly)
		A._path(pn, poly, {"fill": rl["ruin_roof"] if j % 2 == 0 else rl["ruin_rock"], "weight": 0.8})
	_mct("rubble")

static func draw_complex_ruin(g, M: A.Model, V: A.View, ink: A.Ink, rl: Dictionary, shadows: Array) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 17)
	var rng := Mulberry32.new(M.seed + 23)
	var ppm := V.ppm
	var rd: Dictionary = mc_data()["ruin"]
	# 1. the yard still there, trodden, under the scorch
	var yard_o := A._path(pn, G.yard, {"fill": rl["yard"], "weight": 0.0})
	dirt(g, ink, yard_o, A._rng(pn), 1.8)
	# 2. the scorch: dirt stipple, thick in the middle and thinning out, with ink hatch on the side away from the sun
	var main_c := Vector2.ZERO
	for pt: Dictionary in G.parts:
		if str(pt["name"]) == "main":
			main_c = pt["c"]
	var sr: float = float(mc_val(rd["scorch_r_m"]))
	g.fill_color = rl["scar_dot"]
	g.begin_path()
	var n_dots := int(PI * sr * sr * ppm * ppm * 0.16)
	for _i in n_dots:
		var a := rng.next() * TAU
		var d := sr * pow(rng.next(), 0.7)
		var q := V.tp(main_c + Vector2(cos(a), sin(a)) * d)
		g.global_alpha = 0.3 + 0.5 * rng.next()
		g.move_to(q.x + 0.55, q.y)
		g.arc(q.x, q.y, 0.55, 0.0, TAU)
	g.fill()
	g.global_alpha = 1.0
	# 3. what is left of the buildings
	var keep: float = float(mc_val(rd["wall_keep"]))
	for pt: Dictionary in G.parts:
		var kind := str(pt["kind"])
		var c: Vector2 = pt["c"]
		var w: float = pt["w"]
		var d: float = pt["d"]
		if absf(sin(float(pt["rot"]))) > 0.5:   # turned a quarter: the footprint's extent along x and y swap
			w = pt["d"]
			d = pt["w"]
		match kind:
			"barrel", "saw":
				# walls standing, the floor black, a torn piece of roof lying across the hole
				var floor_o := A._path(pn, pt["poly"], {"fill": rl["ruin_char"], "weight": 0.0})
				A.hatch_lines(g, ink, floor_o, V.tv(Vector2(1.0, 1.0).normalized()), maxf(2.0, 0.2 * ppm * 3.0), {"alpha": 0.25, "weight": 0.45})
				var ring := PackedVector2Array(pt["poly"])
				for i in 4:
					if rng.next() < keep:
						var a: Vector2 = ring[i]
						var b: Vector2 = ring[(i + 1) % 4]
						# a broken run of the wall: most of the side, a bite out of it
						var t0 := rng.next() * 0.25
						var t1 := 1.0 - rng.next() * 0.3
						var wp := PackedVector2Array([a.lerp(b, t0), a.lerp(b, t1)])
						A._line(pn, wp, {"weight": 2.2, "alpha": 1.0})
						shadows.append(PackedVector2Array([wp[0], wp[1], wp[1] + Vector2(0.3, 0.3), wp[0] + Vector2(0.3, 0.3)]))
					else:
						A._line(pn, PackedVector2Array([ring[i].lerp(ring[(i + 1) % 4], 0.0), ring[i].lerp(ring[(i + 1) % 4], 0.22)]), {"weight": 1.6, "alpha": 0.9})
				A._path(pn, pt["poly"], {"weight": 0.9, "alpha": 0.5, "breaks": 0.3})
				# the torn roof lying across the hole
				var ang := (rng.next() - 0.5) * 0.4
				var off := Vector2(w * 0.12, d * 0.08)
				var roof := PackedVector2Array()
				for q in A.rect_p(-w * 0.2, -d * 0.28, w * 0.2, d * 0.28):
					roof.append(c + off + q.rotated(ang))
				var ro := A._path(pn, roof, {"fill": rl["ruin_roof"], "weight": 1.0})
				A.hatch_lines(g, ink, ro, V.tv(Vector2(0.0, 1.0).rotated(ang)), maxf(2.0, 0.15 * ppm * 3.0), {"alpha": 0.3, "weight": 0.45})
				shadows.append(roof)
				_rubble(g, pn, V, ink, rl, c, w * 0.42, d * 0.4, int(mc_val(rd["rubble_pieces"])), rng, shadows)
			"gable":
				if str(pt["name"]) == "gatehouse":
					_rubble(g, pn, V, ink, rl, c, w * 0.5, d * 0.5, 4, rng, shadows)
				else:
					_rubble(g, pn, V, ink, rl, c, w * 0.42, d * 0.4, 8, rng, shadows)
					# one wall stub standing at the end
					var e0 := c + Vector2(w * 0.5 * (1.0 if rng.next() < 0.5 else -1.0), -d * 0.5)
					A._line(pn, PackedVector2Array([e0, e0 + Vector2(0.0, d * 0.7)]), {"weight": 1.8, "alpha": 1.0})
			"tank":
				# burst: the ring broken, the pit black, a piece of the shell lying aside
				var r := w / 2.0
				A._path(pn, A.circ(c, r, 20), {"fill": rl["ruin_char"], "weight": 1.0, "breaks": 0.3, "alpha": 0.9})
				A._path(pn, A.circ(c, r * 0.6, 16), {"fill": rl["pit"], "weight": 0.6, "alpha": 0.6})
				var qa := c + Vector2(r * 1.4, r * 0.9)
				var piece := PackedVector2Array()
				for i in 8:
					var aa := float(i) / 8.0 * TAU
					piece.append(qa + Vector2(cos(aa) * r * 0.7, sin(aa) * r * 0.4))
				A._path(pn, piece, {"fill": rl["ruin_rock"], "weight": 0.9})
				shadows.append(piece)
			"stack":
				# the base left, the shaft down across the yard in two pieces
				A._path(pn, pt["poly"], {"fill": rl["ruin_rock"], "weight": 1.0, "breaks": 0.2})
				var fa := 0.9 + (rng.next() - 0.5) * 0.4
				var dirv := Vector2.from_angle(fa)
				var nrm := Vector2(-dirv.y, dirv.x)
				for seg in 2:
					var s0: float = 2.0 + float(seg) * 11.5
					var s1: float = s0 + (9.0 if seg == 0 else 7.5)
					var q0: Vector2 = c + dirv * s0
					var q1: Vector2 = c + dirv * s1
					var rect := PackedVector2Array([q0 + nrm * 1.0, q1 + nrm * 0.9, q1 - nrm * 0.9, q0 - nrm * 1.0])
					var ro := A._path(pn, rect, {"fill": rl["ruin_rock"], "weight": 1.0})
					A.hatch_lines(g, ink, ro, V.tv(nrm), maxf(2.0, 0.2 * ppm * 3.0), {"alpha": 0.35, "weight": 0.45})
					shadows.append(rect)
			"tower":
				if rng.next() < 0.5:
					A._path(pn, A.rect_p(c.x - 0.7, c.y - 0.7, c.x + 0.7, c.y + 0.7), {"fill": rl["ruin_rock"], "weight": 0.9})
					A._line(pn, PackedVector2Array([c, c + Vector2(1.4, 0.8)]), {"weight": 1.2, "alpha": 0.9})
				else:
					_rubble(g, pn, V, ink, rl, c, 1.4, 1.4, 3, rng, shadows)
			"truck":
				# a burnt-out wreck
				var o := A._path(pn, pt["poly"], {"fill": rl["ruin_char"], "weight": 1.0, "alpha": 0.9})
				A.hatch_lines(g, ink, o, V.tv(Vector2(1.0, 0.0)), maxf(1.8, 0.14 * ppm * 3.0), {"alpha": 0.3, "weight": 0.45})
			"crates":
				_rubble(g, pn, V, ink, rl, c, w * 0.5, d * 0.5, 4, rng, shadows)
	for hp: Dictionary in G.heaps:
		_draw_heap(g, pn, V, ink, rl, hp, M.seed % 997)
	# 4. the apron: cracked
	if (G.apron as PackedVector2Array).size() > 0:
		A._path(pn, G.apron, {"fill": rl["concrete"], "weight": 0.8, "alpha": 0.8})
		var ar := _bbox_m(G.apron)
		for k in 3:
			var x0 := ar.position.x + ar.size.x * (0.2 + 0.28 * float(k)) + (rng.next() - 0.5) * 3.0
			A._line(pn, PackedVector2Array([Vector2(x0, ar.position.y), Vector2(x0 + (rng.next() - 0.5) * 6.0, ar.end.y)]), {"alpha": 0.5, "weight": 0.6, "breaks": 0.25})
	# 5. the fence: some panels still standing
	var fk: float = float(mc_val(rd["fence_keep"]))
	var ring: PackedVector2Array = G.ring
	for si in range(1, ring.size()):
		var a: Vector2 = ring[si - 1]
		var b: Vector2 = ring[si]
		var seg_n := maxi(1, int(a.distance_to(b) / 4.0))
		for t in seg_n:
			var q0 := a.lerp(b, float(t) / float(seg_n))
			var q1 := a.lerp(b, float(t + 1) / float(seg_n))
			if rng.next() < fk:
				A._line(pn, PackedVector2Array([q0, q1]), {"alpha": 0.8, "weight": 0.7})
			elif rng.next() < 0.4:
				A._line(pn, PackedVector2Array([q0, q0 + (q1 - q0).rotated(0.9) * 0.4]), {"alpha": 0.7, "weight": 0.6})
	# 6. the craters, the biggest on the main building
	var nc := int(mc_val(rd["craters"]))
	var cr: Array = mc_val(rd["crater_r_m"])
	for k in nc:
		var q := main_c + (Vector2(0.0, 0.0) if k == 0 else Vector2((rng.next() - 0.5) * 18.0, (rng.next() - 0.5) * 14.0))
		var r := _mc_lerp(float(cr[0]), float(cr[1]), 1.0 if k == 0 else rng.next() * 0.7)
		_crater(g, pn, V, ink, rl, q, r, rng)
	_mct("ruin")

static func _mc_lerp(a: float, b: float, t: float) -> float:
	return a + (b - a) * t

# The ruin's cast shadow: the lying pieces and the stubs, low (the heights are a metre or two).
static func complex_ruin_prims(M: A.Model, V: A.View, ink: A.Ink, st: UiStyle, pieces: Array) -> Array:
	var out: Array = []
	var k := V.ppm * st.sun_len()
	for poly_m: PackedVector2Array in pieces:
		out.append({"kind": "fill", "pts": _prism_hull(V.tps(poly_m), ink.sd * 1.4 * k)})
	return out

# --- the bake -----------------------------------------------------------------------------------------------------------------------------------

# The complex baked at `ppm` (the marker's want) and already turned by `rot`; geometry at the map's scale (map_scale_factor).
static func bake_complex(st: UiStyle, M: A.Model, accent: Color, ppm: float, rot: float, ruined: bool) -> A.Art:
	var margin: float = st.num("unit_art.bake_margin_px")
	var ink := A.ink_consts(st)
	var rl := mc_roles(st)
	var gp := ppm * mc_scale_factor()
	var v0 := A.View.new(0.0, 0.0, gp, rot)
	var ruin_pieces: Array = []
	# a dry run of the ruin collects its lying pieces (for the shadow) without drawing: a throwaway canvas
	var band0: Dictionary = _wall_band(v0, ink, M.G, (M.seed % 99991) + 31) if str(M.p.fence) == "wall" and not ruined else {}
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for poly: PackedVector2Array in M.G.ext:
		for q in v0.tps(poly):
			lo = lo.min(q)
			hi = hi.max(q)
	var prims0: Array = []
	if not ruined:
		prims0 = complex_shadow_prims(M, v0, ink, st, band0)
	else:
		var probe := InkCanvas.new(Vector2i(8, 8))
		draw_complex_ruin(probe, M, v0, ink, rl, ruin_pieces)
		probe.discard()
		prims0 = complex_ruin_prims(M, v0, ink, st, ruin_pieces)
	for pr: Dictionary in prims0:
		var half := float(pr.get("w", 0.0)) * 0.5
		for q: Vector2 in pr["pts"]:
			lo = lo.min(q - Vector2(half, half))
			hi = hi.max(q + Vector2(half, half))
	if not band0.is_empty():
		for q: Vector2 in band0["L"]:
			lo = lo.min(q)
			hi = hi.max(q)
		for q: Vector2 in band0["R"]:
			lo = lo.min(q)
			hi = hi.max(q)
	var size := Vector2i(ceili(hi.x - lo.x + 2.0 * margin), ceili(hi.y - lo.y + 2.0 * margin))
	var v := A.View.new(-lo.x + margin, -lo.y + margin, gp, rot)
	var canvas := InkCanvas.new(size)
	canvas.line_cap = "round"
	var pieces: Array = []
	var band: Dictionary = _wall_band(v, ink, M.G, (M.seed % 99991) + 31) if str(M.p.fence) == "wall" and not ruined else {}
	if ruined:
		draw_complex_ruin(canvas, M, v, ink, rl, pieces)
	else:
		draw_complex(canvas, M, v, ink, accent, rl)
	var mask := InkCanvas.new(size)
	mask.line_cap = "round"
	mask.fill_color = Color.WHITE
	mask.stroke_color = Color.WHITE
	var prims: Array = complex_ruin_prims(M, v, ink, st, pieces) if ruined else complex_shadow_prims(M, v, ink, st, band)
	mask.begin_path()
	for pr: Dictionary in prims:
		if pr["kind"] == "fill":
			A.add_poly(mask, pr["pts"], true)
	mask.fill()
	for pr: Dictionary in prims:
		if pr["kind"] == "stroke":
			mask.line_width = float(pr["w"])
			mask.begin_path()
			A.add_poly(mask, pr["pts"], false)
			mask.stroke()
	var imgs := InkCanvas.render_all([canvas, mask])
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(v.x, v.y)
	art.size_px = size
	art.screen_aligned = true
	art.rot = rot
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far * mc_scale_factor()   # in the marker's metres: the marker multiplies by the layer's px per metre
	if imgs.size() == 2 and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(A._straight(imgs[1], true))
	return art

static func _complex_cached(st: RefCounted, accent: Color, ppm: float, rot: float, ruined: bool) -> A.Art:
	var lo: float = st.num("unit_art.min_bake_ppm")
	var hi: float = st.num("unit_art.max_bake_ppm")
	var q := snappedf(clampf(ppm, lo, hi), 0.01)
	var look := mc_look_of(st)
	rot = wrapf(rot, -PI, PI)
	var key := "%s|%d|%s|%.2f|%s|%.3f%s" % [MC_SILHOUETTE, look, "" if ruined else accent.to_html(), q, InkCanvas.pen_key(), snappedf(rot, 0.005), "|ruin" if ruined else ""]
	if A._art.has(key):
		var hit: A.Art = A._art[key]
		A._art.erase(key)   # LRU
		A._art[key] = hit
		return hit
	if not A.can_bake():
		return null
	var art := bake_complex(st as UiStyle, mc_model(st, look), accent, q, rot, ruined)
	A._art[key] = art
	A._trim(int(st.num("unit_art.cache_max")))
	return art

# The standing compound for a side's accent at `ppm`, turned by `rot` (the marker's sprite angle), from the cache or baked now.
static func complex_art(st: RefCounted, accent: Color, ppm: float, rot: float = 0.0) -> A.Art:
	return _complex_cached(st, accent, ppm, rot, false)

# The destroyed compound (R1's language), the same compound with parts taken away; for the effects layer (kind "military_complex").
static func complex_ruin_art(st: RefCounted, ppm: float, rot: float = 0.0) -> A.Art:
	return _complex_cached(st, Color.WHITE, ppm, rot, true)
