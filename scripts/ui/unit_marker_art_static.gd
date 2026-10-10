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
