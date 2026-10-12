extends RefCounted

# THE BRIDGES IN INK (Track BB, 2026-10-10): a stone arch, a steel truss and a wooden trestle where the
# village road crosses a river, drawn the way the buildings are (the roof halves, the slope tone on the
# faces away from the sun, the ridge line, the prism shadow) and written the way boat_art.gd and
# unit_marker_art.gd are: gen(rng) -> parameters in metres, build(p) -> geometry in metres, draw onto an
# InkCanvas through the same pen and helpers. NEW generators; NOTHING IS IN THE GAME YET: the look is
# chosen on a board (variants/bridge/, scripts/ui/boards/bridge_board_shot.gd).
#
#   var M := BridgeArt.model(style, "arch", false)          # false = intact, true = destroyed
#   BridgeArt.draw_road(g, V, ink, roles, [[x0, x1]], seed)  # the village road's own look, on the banks
#   BridgeArt.draw_bridge(g, M, V, ink, roles)               # the bridge (or its ruin)
#   BridgeArt.shadow_polys(M, V, k)                          # the cast shadow, px, for ONE translucent fill
#   BridgeArt.water_marks(M)                                 # the ink lines round piers, piles and rubble, metres
#
# THE FRAME: the bridge's own, metres. x runs ALONG the road (west to east on the board), y ACROSS it (the
# river runs along y, from the top of the frame to the bottom, so a pier's upstream side is -y). The
# origin is the middle of the span. A bridge is MAP SCENERY: the View's scale is the map's, not the units'.
#
# THE ROAD. The deck carries the village road's own look (scripts/render/village_draw.gd draw_road): eight
# wobbly broken lines at the road's offsets, dirt specks across it, pebbles along the verges. They are in
# map px in the village code (the road's half width is 16 px); here they are divided by the map's px per
# metre (data/world/bridges.json road_px_per_m), so the lines are in metres and the deck is as wide as the
# road. The deck is drawn as a surface in its own material (stone, planks) and the road's lines run on top.
#
# THE RUIN is the same parts with a stretch of them taken away and rubble put where they fell (the radio
# tower's ruin, scripts/fx/fx_ruin.gd, is made of the same parts as the tower).
#
# COLOUR is a ROLE (data/world/bridges.json roles, resolved by ink_roles.gd); material is linework. No hex.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const S = preload("res://scripts/ui/unit_marker_art_static.gd")
const B = preload("res://scripts/render/boat_art.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const DATA_PATH := "res://data/world/bridges.json"
const RENDER_PATH := "res://data/params/render_defaults.json"

class Model:
	var kind: String      # "arch" | "truss" | "trestle"
	var ruin: bool
	var seed: int
	var p: Dictionary
	var G: Dictionary

static var _data: Dictionary = {}
static var _render: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if v is Dictionary:
			_data = v
		else:
			push_error("bridge_art: %s does not parse as a JSON object" % DATA_PATH)
	return _data

static func _render_defaults() -> Dictionary:
	if _render.is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(RENDER_PATH))
		if v is Dictionary:
			_render = v
	return _render

static func val(rec: Variant) -> Variant:
	if rec is Dictionary and (rec as Dictionary).has("value"):
		return (rec as Dictionary)["value"]
	return rec

static func kinds() -> Array:
	return ["arch", "truss", "trestle"]

static func model(st: RefCounted, kind: String, ruin: bool, river_w: float = -1.0) -> Model:
	var d: Dictionary = data()
	var m := Model.new()
	m.kind = kind
	m.ruin = ruin
	# the sheet's seed rule on the scene seed; the ruin is the SAME bridge (same seed) with parts taken away
	m.seed = A.unit_seed(st.scene_seed, 9 + kinds().find(kind), 0)
	var rng := Mulberry32.new(m.seed)
	m.p = gen(kind, d, rng, ruin, river_w)
	m.G = build(m.p)
	return m

static func _rr(rng: Mulberry32, pair: Variant) -> float:
	var a: Array = pair
	return A._r(rng, float(a[0]), float(a[1]))

static func gen(kind: String, d: Dictionary, rng: Mulberry32, ruin: bool, river_w: float = -1.0) -> Dictionary:
	var p := {}
	var kd: Dictionary = d[kind]
	p.kind = kind
	p.ruin = ruin
	p.river_w = _rr(rng, kd["river_w"])
	if river_w > 0.0:
		p.river_w = river_w     # a board's range check: the same bridge over a narrower or a wider river
	p.deck_w = float(val(d["deck_width_m"]))
	p.abut = float(val(d["abutment_len_m"]))
	p.len = float(p.river_w) + 2.0 * float(p.abut)
	p.fall_seed = int(rng.next() * 2147483646.0)
	match kind:
		"arch":
			p.arches = clampi(int(round(float(p.river_w) / float(val(kd["arch_span_m"])))), 1, 4)
			p.pier_w = _rr(rng, kd["pier_w"])
			p.cutwater = _rr(rng, kd["cutwater_m"])
			p.parapet_w = _rr(rng, kd["parapet_w"])
			p.wing = _rr(rng, kd["wing_m"])
			p.crown_h = float(val(kd["crown_h"]))
			p.parapet_h = float(val(kd["parapet_h"])) if kd.has("parapet_h") else 1.1
			p.pier_h = float(val(kd["pier_h"]))
			p.slab_h = float(val(kd["slab_h"]))
			p.humped_deck = bool(val(kd["humped_deck"])) if kd.has("humped_deck") else true
		"truss":
			var pl := _rr(rng, kd["panel_len"])
			p.panels = maxi(4, int(round(float(p.river_w) / pl)))
			p.panel_len = float(p.river_w) / float(p.panels)
			p.chord_w = _rr(rng, kd["chord_w"])
			p.deck_h = float(val(kd["deck_h"]))
			p.truss_h = float(val(kd["truss_h"]))
		_:
			var sp := _rr(rng, kd["bent_sp"])
			p.bents = maxi(6, int(round(float(p.river_w) / sp)))
			p.bent_sp = float(p.river_w) / float(p.bents)
			p.cap_over = _rr(rng, kd["cap_over_m"])
			p.piles = int(kd["piles"])
			p.deck_h = float(val(kd["deck_h"]))
	p.ruin_d = (kd["ruin"] as Dictionary)
	return p

# --- geometry helpers ---------------------------------------------------------------------------------------

# A strip of width w along a polyline, as one closed polygon.
static func _strip(pts: PackedVector2Array, w: float) -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var a := pts[maxi(i - 1, 0)]
		var b := pts[mini(i + 1, n - 1)]
		var d := (b - a).normalized()
		var nrm := Vector2(-d.y, d.x) * w * 0.5
		left.append(pts[i] + nrm)
		right.append(pts[i] - nrm)
	right.reverse()
	left.append_array(right)
	return left

# A rectangle x0..x1 by y0..y1 whose short ends may be torn: each end vertex row moved inward by up to jl / jr.
static func _piece(x0: float, x1: float, y0: float, y1: float, jl: float, jr: float, rng: Mulberry32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := maxi(1, int(ceil(absf(y1 - y0) / 1.3)))
	pts.append(Vector2(x0 + (rng.next() * jl if jl > 0.0 else 0.0), y0))
	pts.append(Vector2(x1 - (rng.next() * jr if jr > 0.0 else 0.0), y0))
	if jr > 0.0:
		for i in range(1, steps):
			pts.append(Vector2(x1 - rng.next() * jr, lerpf(y0, y1, float(i) / float(steps))))
	pts.append(Vector2(x1 - (rng.next() * jr if jr > 0.0 else 0.0), y1))
	pts.append(Vector2(x0 + (rng.next() * jl if jl > 0.0 else 0.0), y1))
	if jl > 0.0:
		for i in range(steps - 1, 0, -1):
			pts.append(Vector2(x0 + rng.next() * jl, lerpf(y0, y1, float(i) / float(steps))))
	return pts

static func _rot(pts: PackedVector2Array, ang: float, pivot: Vector2, shift: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var c := cos(ang)
	var s := sin(ang)
	for q in pts:
		var d := q - pivot
		out.append(pivot + Vector2(d.x * c - d.y * s, d.x * s + d.y * c) + shift)
	return out

# A rough convex block of rubble: n points round an anisotropic ellipse, turned by a.
static func _block(rng: Mulberry32, c: Vector2, r: float) -> PackedVector2Array:
	var n := 5 + int(rng.next() * 3.0)
	var a0 := rng.next() * TAU
	var rx := r * (0.7 + rng.next() * 0.6)
	var ry := r * (0.55 + rng.next() * 0.5)
	var pts := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU + (rng.next() - 0.5) * 0.5
		var k := 0.8 + rng.next() * 0.35
		var q := Vector2(cos(a) * rx * k, sin(a) * ry * k)
		pts.append(c + Vector2(q.x * cos(a0) - q.y * sin(a0), q.x * sin(a0) + q.y * cos(a0)))
	return pts

static func _pile_poly(c: Vector2, r: float) -> PackedVector2Array:
	return A.circ(c, r, 10)

# --- build ----------------------------------------------------------------------------------------------------------

static func build(p: Dictionary) -> Dictionary:
	match str(p.kind):
		"arch":
			return _build_arch(p)
		"truss":
			return _build_truss(p)
	return _build_trestle(p)

static func _prism(polys: Array, b: float, h: float) -> Dictionary:
	return {"kind": "prism", "polys": polys, "b": b, "h": h}

static func _line3(lines: Array, w: float, min_px: float) -> Dictionary:
	return {"kind": "line", "lines": lines, "w": w, "min_px": min_px}

static func _l3(a: Vector2, za: float, b: Vector2, zb: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(a.x, a.y, za), Vector3(b.x, b.y, zb)])

# The abutment and its wing walls are the same for every kind: a stone block under the deck's end, wider than it.
static func _abutments(p: Dictionary, G: Dictionary) -> void:
	var W: float = p.river_w
	var dw: float = p.deck_w
	var ab: float = p.abut
	G.abutments = [A.rect_p(-W / 2.0 - ab, -dw / 2.0 - 1.4, -W / 2.0 + 0.4, dw / 2.0 + 1.4),
		A.rect_p(W / 2.0 - 0.4, -dw / 2.0 - 1.4, W / 2.0 + ab, dw / 2.0 + 1.4)]

static func _ruin_rubble(p: Dictionary, G: Dictionary, x0: float, x1: float, n: int, rng: Mulberry32) -> void:
	var dw: float = p.deck_w
	G.rubble = []
	for i in n:
		var cx := x0 + (x1 - x0) * rng.next()
		var cy := (rng.next() - 0.35) * (dw + 16.0)
		var big := rng.next() < 0.22
		var blk := _block(rng, Vector2(cx, cy), 0.8 + rng.next() * (2.1 if big else 1.0))
		(G.rubble as Array).append({"poly": blk, "kind": "stone"})

static func _build_arch(p: Dictionary) -> Dictionary:
	var W: float = p.river_w
	var dw: float = p.deck_w
	var L: float = p.len
	var n: int = p.arches
	var pw: float = p.pier_w
	var pt: float = p.parapet_w
	var span := (W - float(n - 1) * pw) / float(n)
	var rng := Mulberry32.new(int(p.fall_seed))
	var G := {}
	G.span = span
	# arches: [x0, x1] of each opening; piers between them
	G.arch_x = []
	G.piers = []
	var x := -W / 2.0
	for i in n:
		(G.arch_x as Array).append(Vector2(x, x + span))
		x += span
		if i < n - 1:
			var xp := x + pw / 2.0
			var c: float = p.cutwater
			var hw := dw / 2.0 + 0.5
			var poly := PackedVector2Array([Vector2(xp - pw / 2.0, -hw), Vector2(xp, -hw - c), Vector2(xp + pw / 2.0, -hw), Vector2(xp + pw / 2.0, hw),
				Vector2(xp, hw + c), Vector2(xp - pw / 2.0, hw)])
			(G.piers as Array).append({"poly": poly, "x": xp})
			x += pw
	_abutments(p, G)
	# what stays: the whole length, or (ruin) everything but the middle arch and a little of each pier
	var keep: Array = [Vector2(-L / 2.0, L / 2.0)]
	var mid: int = n / 2
	var cut0 := 0.0
	var cut1 := 0.0
	if p.ruin:
		var am: Vector2 = (G.arch_x as Array)[mid]
		cut0 = am.x - 0.3
		cut1 = am.y + 0.3
		keep = [Vector2(-L / 2.0, cut0), Vector2(cut1, L / 2.0)]
	G.cut = Vector2(cut0, cut1)
	G.keep = keep
	G.deck = []
	G.parapets = []
	G.cut_edges = []
	for k in keep.size():
		var seg: Vector2 = keep[k]
		var jl := 0.0 if seg.x <= -L / 2.0 + 0.01 else 2.4
		var jr := 0.0 if seg.y >= L / 2.0 - 0.01 else 2.4
		(G.deck as Array).append(_piece(seg.x, seg.y, -dw / 2.0, dw / 2.0, jl, jr, rng))
		for s: float in [-1.0, 1.0]:
			var y0 := s * dw / 2.0
			var y1 := s * (dw / 2.0 + pt)
			(G.parapets as Array).append(_piece(seg.x, seg.y, minf(y0, y1), maxf(y0, y1), jl * 1.4, jr * 1.4, rng))
	# wing walls: the parapet flares out onto the bank
	G.wings = []
	for e: float in [-1.0, 1.0]:
		for s: float in [-1.0, 1.0]:
			var a := Vector2(e * L / 2.0, s * (dw / 2.0 + pt / 2.0))
			var wlen: float = p.wing
			var b := Vector2(e * (L / 2.0 + wlen), s * (dw / 2.0 + pt / 2.0 + wlen * 0.55))
			var mid_pt := a.lerp(b, 0.5) + Vector2(0.0, s * 0.35)
			(G.wings as Array).append(_strip(PackedVector2Array([a, mid_pt, b]), pt))
	# humps: each arch's roadway is a roof of two halves with a ridge at its crown
	G.humps = []
	for i in n:
		var ax: Vector2 = (G.arch_x as Array)[i]
		var xa: float = ax.x - pw / 2.0 if i > 0 else -L / 2.0
		var xb: float = ax.y + pw / 2.0 if i < n - 1 else L / 2.0
		if p.ruin and i == mid:
			continue
		(G.humps as Array).append({"x0": xa, "x1": xb, "xm": (ax.x + ax.y) / 2.0})
	# the ruin: stone blocks in the river, and broken pier tops
	G.rubble = []
	if p.ruin:
		var rd: Dictionary = p.ruin_d
		var cnt := int(A._r(rng, float((rd["rubble_blocks"] as Array)[0]), float((rd["rubble_blocks"] as Array)[1])))
		_ruin_rubble(p, G, cut0 - 1.0, cut1 + 1.0, cnt, rng)
		# a few slabs of the roadway, flat, with the road's mark on them
		for i in 3:
			var c := Vector2(lerpf(cut0, cut1, 0.2 + 0.6 * rng.next()), (rng.next() - 0.3) * dw)
			var slab := S.place(A.rect_p(-2.4, -1.6, 2.4, 1.6), c.x, c.y, (rng.next() - 0.5) * 1.2)
			(G.rubble as Array).append({"poly": slab, "kind": "slab"})
	# the cast shadow: the roadway slab floats on its arches; the piers and abutments are solid
	var crown: float = p.crown_h
	var casts: Array = []
	# THE LOW BRIDGE (decision line-of-fire, Alex): the deck is level with the banks and the parapets are 1 m (data arch.crown_h 0, arch.parapet_h 1),
	# so the shadow is the parapets' metre and nothing under the roadway: no prism starts below the surface (a negative height would throw the
	# shadow toward the light).
	var parapet_h: float = p.parapet_h
	casts.append(_prism(G.deck, maxf(crown - float(p.slab_h) - 0.5, 0.0), maxf(crown, 0.0)))
	casts.append(_prism(G.parapets, maxf(crown - 0.4, 0.0), crown + parapet_h))
	var pier_polys: Array = []
	for pr: Dictionary in G.piers:
		pier_polys.append(pr.poly)
	casts.append(_prism(pier_polys, 0.0, float(p.pier_h)))
	casts.append(_prism(G.abutments, 0.0, float(p.pier_h)))
	casts.append(_prism(G.wings, 0.0, minf(1.6, parapet_h)))
	var rp: Array = []
	for r: Dictionary in G.rubble:
		rp.append(r.poly)
	if rp.size() > 0:
		casts.append(_prism(rp, 0.0, 1.0))
	G.casts = casts
	return G

static func _build_truss(p: Dictionary) -> Dictionary:
	var W: float = p.river_w
	var dw: float = p.deck_w
	var L: float = p.len
	var N: int = p.panels
	var pl: float = p.panel_len
	var cw: float = p.chord_w
	var zd: float = p.deck_h
	var zt: float = zd + float(p.truss_h)
	var yc := dw / 2.0 + cw / 2.0 + 0.45
	var rng := Mulberry32.new(int(p.fall_seed))
	var G := {}
	_abutments(p, G)
	# panel points
	var xs: Array = []
	for k in N + 1:
		xs.append(-W / 2.0 + float(k) * pl)
	G.xs = xs
	# what stays (panel indices): all, or (ruin) a stub from each abutment
	var ka := 0
	var kb := N
	var tilt := 0.0
	if p.ruin:
		var rd: Dictionary = p.ruin_d
		var sw: Array = rd["stub_w"]
		ka = maxi(2, int(round(float(sw[0]) * float(N))))
		kb = N - maxi(1, int(round(float(sw[1]) * float(N))))
		tilt = deg_to_rad(A._r(rng, float((rd["tilt_deg"] as Array)[0]), float((rd["tilt_deg"] as Array)[1])))
	G.ka = ka
	G.kb = kb
	var keep: Array = [Vector2(-L / 2.0, L / 2.0)]
	if p.ruin:
		keep = [Vector2(-L / 2.0, float(xs[ka])), Vector2(float(xs[kb]), L / 2.0)]
	G.keep = keep
	G.deck = []
	for k in keep.size():
		var seg: Vector2 = keep[k]
		var jl := 0.0 if seg.x <= -L / 2.0 + 0.01 else 2.6
		var jr := 0.0 if seg.y >= L / 2.0 - 0.01 else 2.6
		(G.deck as Array).append(_piece(seg.x, seg.y, -dw / 2.0, dw / 2.0, jl, jr, rng))
	# the members: in plan the sides of the truss are edge-on, so what is drawn is the top chords, the
	# struts across and the X bracing; the uprights and diagonals matter for the SHADOW (3D lines)
	var in_keep := func(k0: int, k1: int) -> bool:
		return not p.ruin or k1 <= ka or k0 >= kb
	G.chords = []
	G.struts = []
	G.braces = []
	G.joints = []
	var cast_lines: Array = []
	var chord_lines: Array = []
	var web_lines: Array = []
	var brace_lines: Array = []
	for s: float in [-1.0, 1.0]:
		var runs: Array = [Vector2i(0, N)]
		if p.ruin:
			runs = [Vector2i(0, ka), Vector2i(kb, N)]
		for rr: Vector2i in runs:
			if rr.y <= rr.x:
				continue
			var pts := PackedVector2Array()
			for k in range(rr.x, rr.y + 1):
				pts.append(Vector2(float(xs[k]), s * yc))
			(G.chords as Array).append(_strip(pts, cw))
			chord_lines.append(_l3(pts[0], zt, pts[pts.size() - 1], zt))
			chord_lines.append(_l3(pts[0], zd - 0.3, pts[pts.size() - 1], zd - 0.3))
			for k in range(rr.x, rr.y + 1):
				(G.joints as Array).append(Vector2(float(xs[k]), s * yc))
				web_lines.append(_l3(Vector2(float(xs[k]), s * yc), zd, Vector2(float(xs[k]), s * yc), zt))
			for k in range(rr.x, rr.y):
				# Pratt: the diagonals lean toward the middle of the span
				var lean_in: bool = k < N / 2
				var a := Vector2(float(xs[k] if lean_in else xs[k + 1]), s * yc)
				var b := Vector2(float(xs[k + 1] if lean_in else xs[k]), s * yc)
				web_lines.append(_l3(a, zd, b, zt))
	for k in N + 1:
		if p.ruin and k > ka and k < kb:
			continue
		var heavy := k == 0 or k == N
		(G.struts as Array).append({"line": PackedVector2Array([Vector2(float(xs[k]), -yc), Vector2(float(xs[k]), yc)]), "heavy": heavy})
		brace_lines.append(_l3(Vector2(float(xs[k]), -yc), zt, Vector2(float(xs[k]), yc), zt))
	for k in N:
		if p.ruin and k >= ka and k < kb:
			continue
		var a1 := Vector2(float(xs[k]), -yc)
		var b1 := Vector2(float(xs[k + 1]), yc)
		var a2 := Vector2(float(xs[k]), yc)
		var b2 := Vector2(float(xs[k + 1]), -yc)
		(G.braces as Array).append(PackedVector2Array([a1, b1]))
		(G.braces as Array).append(PackedVector2Array([a2, b2]))
		brace_lines.append(_l3(a1, zt, b1, zt))
		brace_lines.append(_l3(a2, zt, b2, zt))
	# the ruin: bent, torn ends at the stubs, and the fallen middle lying in the river
	G.torn = []
	G.fallen = {}
	G.rubble = []
	if p.ruin:
		for e in 2:
			var xe: float = float(xs[ka]) if e == 0 else float(xs[kb])
			var dirn := -1.0 if e == 0 else 1.0
			for s: float in [-1.0, 1.0]:
				for j in 3:
					var a := Vector2(xe, s * yc + (rng.next() - 0.5) * 0.4)
					var b := a + Vector2(dirn * (1.5 + rng.next() * 3.0), s * (0.8 + rng.next() * 2.2) + (rng.next() - 0.5) * 1.4)
					(G.torn as Array).append(PackedVector2Array([a, b]))
		# the fallen section: the removed deck, chords, struts and braces turned by the tilt about the stub's end
		# and slid downstream
		var pivot := Vector2(float(xs[ka]), 0.0)
		var shift := Vector2(2.5, 5.5)
		var f := {"deck": PackedVector2Array(), "chords": [], "struts": [], "braces": [], "joints": []}
		f.deck = _rot(_piece(float(xs[ka]) + 1.0, float(xs[kb]) - 1.0, -dw / 2.0, dw / 2.0, 1.4, 1.4, rng), tilt, pivot, shift)
		for s: float in [-1.0, 1.0]:
			var pts := PackedVector2Array()
			for k in range(ka, kb + 1):
				pts.append(Vector2(float(xs[k]), s * yc))
			# a twisted top chord: it kinks halfway
			var mid_i := pts.size() / 2
			pts[mid_i] += Vector2(0.0, s * 1.6)
			(f.chords as Array).append(_rot(_strip(pts, cw), tilt, pivot, shift))
			for k in range(ka, kb + 1):
				(f.joints as Array).append(_rot(PackedVector2Array([Vector2(float(xs[k]), s * yc)]), tilt, pivot, shift)[0])
		for k in range(ka + 1, kb):
			(f.struts as Array).append(_rot(PackedVector2Array([Vector2(float(xs[k]), -yc), Vector2(float(xs[k]), yc)]), tilt, pivot, shift))
		for k in range(ka, kb):
			if rng.next() < 0.8:
				(f.braces as Array).append(_rot(PackedVector2Array([Vector2(float(xs[k]), -yc), Vector2(float(xs[k + 1]), yc)]), tilt, pivot, shift))
			if rng.next() < 0.8:
				(f.braces as Array).append(_rot(PackedVector2Array([Vector2(float(xs[k]), yc), Vector2(float(xs[k + 1]), -yc)]), tilt, pivot, shift))
		G.fallen = f
		# planks adrift
		var rd2: Dictionary = p.ruin_d
		var np := int(A._r(rng, float((rd2["planks"] as Array)[0]), float((rd2["planks"] as Array)[1])))
		for i in np:
			var c := Vector2(lerpf(float(xs[ka]), float(xs[kb]), rng.next()), dw * 0.5 + 2.0 + rng.next() * 12.0)
			var len_m := 2.5 + rng.next() * 4.0
			(G.rubble as Array).append({"poly": S.place(A.rect_p(-len_m / 2.0, -0.28, len_m / 2.0, 0.28), c.x, c.y, (rng.next() - 0.5) * 1.5), "kind": "plank"})
	# the cast shadow
	var casts: Array = []
	casts.append(_prism(G.deck, zd - 0.9, zd))
	casts.append(_prism(G.abutments, 0.0, zd))
	casts.append(_line3(chord_lines, 0.9, 1.0))
	casts.append(_line3(web_lines, 0.4, 1.0))
	casts.append(_line3(brace_lines, 0.3, 0.9))
	if p.ruin:
		var fd: Dictionary = G.fallen
		var low: Array = [fd.deck]
		for c: PackedVector2Array in fd.chords:
			low.append(c)
		casts.append(_prism(low, 0.0, 1.1))
		var rp: Array = []
		for r: Dictionary in G.rubble:
			rp.append(r.poly)
		casts.append(_prism(rp, 0.0, 0.4))
	G.casts = casts
	return G

static func _build_trestle(p: Dictionary) -> Dictionary:
	var W: float = p.river_w
	var dw: float = p.deck_w
	var L: float = p.len
	var nb: int = p.bents
	var sp: float = p.bent_sp
	var zd: float = p.deck_h
	var co: float = p.cap_over
	var rng := Mulberry32.new(int(p.fall_seed))
	var G := {}
	_abutments(p, G)
	var xs: Array = []
	for j in nb + 1:
		xs.append(-W / 2.0 + float(j) * sp)
	G.xs = xs
	var gone0 := -1
	var gone1 := -1
	if p.ruin:
		var gb: int = int((p.ruin_d as Dictionary)["gone_bents"])
		gone0 = (nb + 1) / 2 - gb / 2
		gone1 = gone0 + gb - 1
	G.gone = Vector2i(gone0, gone1)
	var keep: Array = [Vector2(-L / 2.0, L / 2.0)]
	if p.ruin:
		keep = [Vector2(-L / 2.0, float(xs[gone0 - 1]) + 1.2), Vector2(float(xs[gone1 + 1]) - 1.2, L / 2.0)]
	G.keep = keep
	G.deck = []
	for k in keep.size():
		var seg: Vector2 = keep[k]
		var jl := 0.0 if seg.x <= -L / 2.0 + 0.01 else 2.0
		var jr := 0.0 if seg.y >= L / 2.0 - 0.01 else 2.0
		(G.deck as Array).append(_piece(seg.x, seg.y, -dw / 2.0, dw / 2.0, jl, jr, rng))
	# bents: a cap beam across, outer piles in the water beyond the deck's edge
	G.caps = []
	G.piles = []
	G.stubs = []
	var pile_lines: Array = []
	var brace_lines: Array = []
	for j in nb + 1:
		var x: float = xs[j]
		var is_gone: bool = p.ruin and j >= gone0 and j <= gone1
		var ys: Array = []
		for i in int(p.piles):
			ys.append(-dw / 2.0 - co * 0.55 + (dw + co * 1.1) * float(i) / float(int(p.piles) - 1))
		if is_gone:
			# broken pile stubs, a ragged bit of cap
			for y: float in ys:
				if rng.next() < 0.55:
					(G.stubs as Array).append(Vector2(x + (rng.next() - 0.5) * 0.4, y))
			continue
		(G.caps as Array).append(A.rect_p(x - 0.4, -dw / 2.0 - co, x + 0.4, dw / 2.0 + co))
		if j < nb and not (p.ruin and j + 1 >= gone0 and j <= gone1):
			for sy: float in [-1.0, 1.0]:
				var ya: float = sy * (dw / 2.0 + co * 0.55)
				brace_lines.append(_l3(Vector2(x, ya), 0.6, Vector2(float(xs[j + 1]), ya), zd - 1.6))
				brace_lines.append(_l3(Vector2(x, ya), zd - 1.6, Vector2(float(xs[j + 1]), ya), 0.6))
		for y: float in ys:
			(G.piles as Array).append(Vector2(x, y))
			pile_lines.append(_l3(Vector2(x, y), 0.0, Vector2(x, y), zd - 0.8))
	# the rails: a post every three metres and two rails, along both edges, over the deck's pieces
	G.rails = []
	G.posts = []
	var post_lines: Array = []
	var rail_lines: Array = []
	for k in keep.size():
		var seg: Vector2 = keep[k]
		for s: float in [-1.0, 1.0]:
			var y := s * (dw / 2.0 - 0.28)
			(G.rails as Array).append(PackedVector2Array([Vector2(seg.x + (1.0 if seg.x > -L / 2.0 + 0.01 else 0.0), y), Vector2(seg.y - (1.0 if seg.y < L / 2.0 - 0.01 else 0.0), y)]))
			rail_lines.append(_l3(Vector2(seg.x, y), zd + 1.0, Vector2(seg.y, y), zd + 1.0))
			var xp := seg.x + 1.5
			while xp < seg.y - 0.8:
				(G.posts as Array).append(Vector2(xp, y))
				post_lines.append(_l3(Vector2(xp, y), zd, Vector2(xp, y), zd + 1.1))
				xp += 3.0
	# the ruin: timbers and planks adrift downstream
	G.rubble = []
	if p.ruin:
		var rd: Dictionary = p.ruin_d
		var nt := int(A._r(rng, float((rd["timbers"] as Array)[0]), float((rd["timbers"] as Array)[1])))
		for i in nt:
			var c := Vector2(lerpf(float(xs[gone0]) - 3.0, float(xs[gone1]) + 8.0, rng.next()), dw * 0.5 + 1.5 + rng.next() * 15.0)
			var long := rng.next() < 0.4
			var len_m := (4.0 + rng.next() * 3.0) if long else (2.0 + rng.next() * 2.0)
			var wd := 0.5 if long else 0.3
			(G.rubble as Array).append({"poly": S.place(A.rect_p(-len_m / 2.0, -wd / 2.0, len_m / 2.0, wd / 2.0), c.x, c.y, (rng.next() - 0.5) * 2.0), "kind": "timber" if long else "plank"})
	var casts: Array = []
	casts.append(_prism(G.deck, zd - 0.8, zd))
	casts.append(_prism(G.abutments, 0.0, zd))
	casts.append(_line3(pile_lines, 0.6, 1.0))
	casts.append(_line3(brace_lines, 0.3, 0.9))
	casts.append(_line3(post_lines, 0.22, 0.8))
	casts.append(_line3(rail_lines, 0.2, 0.8))
	casts.append(_prism(G.caps, zd - 1.2, zd - 0.8))
	if p.ruin:
		var rp: Array = []
		for r: Dictionary in G.rubble:
			rp.append(r.poly)
		casts.append(_prism(rp, 0.0, 0.3))
	G.casts = casts
	return G

# --- the shadow -------------------------------------------------------------------------------------------------

static func shadow_polys(M: Model, V: A.View, k: Vector2) -> Array:
	var out: Array = []
	for c: Dictionary in M.G.casts:
		match str(c["kind"]):
			"prism":
				for poly: PackedVector2Array in c["polys"]:
					out.append_array(B.prism_px(V.tps(poly), k * float(c["b"]), k * float(c["h"])))
			"line":
				for ln: PackedVector3Array in c["lines"]:
					var a := V.tp(Vector2(ln[0].x, ln[0].y)) + k * ln[0].z
					var b := V.tp(Vector2(ln[1].x, ln[1].y)) + k * ln[1].z
					var w := maxf(float(c["w"]) * V.ppm, float(c["min_px"]))
					var d := b - a
					if d.length() < 0.001:
						d = Vector2(1.0, 0.0)
					var nrm := Vector2(-d.y, d.x).normalized() * w * 0.5
					out.append(PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm]))
	return out

# The ink lines on the water that say a thing stands in it (metres): a short broken V off the downstream side
# (+y, the river runs down the frame) of every pier, pile and stub, a short arc against the upstream side.
static func water_marks(M: Model) -> Array:
	var out: Array = []
	var G := M.G
	var p := M.p
	if M.kind == "arch":
		for pr: Dictionary in G.piers:
			var xp: float = pr.x
			var hw: float = float(p.deck_w) / 2.0 + 0.5 + float(p.cutwater)
			var pw: float = p.pier_w
			for s: float in [-1.0, 1.0]:
				out.append(PackedVector2Array([Vector2(xp + s * pw * 0.45, hw - 0.2), Vector2(xp + s * (pw * 0.5 + 1.8), hw + 4.0), Vector2(xp + s * (pw * 0.5 + 3.2), hw + 9.0)]))
			out.append(PackedVector2Array([Vector2(xp - pw * 0.9, -hw - 0.9), Vector2(xp - pw * 0.4, -hw - 1.5), Vector2(xp, -hw - 1.7), Vector2(xp + pw * 0.4, -hw - 1.5), Vector2(xp + pw * 0.9, -hw - 0.9)]))
	elif M.kind == "trestle":
		for q: Vector2 in G.piles:
			if absf(q.y) < float(p.deck_w) / 2.0:
				continue
			var s := signf(q.y)
			if s > 0.0:
				out.append(PackedVector2Array([Vector2(q.x - 0.2, q.y + 0.3), Vector2(q.x - 0.9, q.y + 3.0), Vector2(q.x - 1.3, q.y + 5.5)]))
				out.append(PackedVector2Array([Vector2(q.x + 0.2, q.y + 0.3), Vector2(q.x + 0.9, q.y + 3.0), Vector2(q.x + 1.3, q.y + 5.5)]))
			else:
				out.append(PackedVector2Array([Vector2(q.x - 0.8, q.y - 0.7), Vector2(q.x, q.y - 1.1), Vector2(q.x + 0.8, q.y - 0.7)]))
		for q: Vector2 in G.stubs:
			out.append(PackedVector2Array([Vector2(q.x - 0.3, q.y + 0.4), Vector2(q.x - 1.0, q.y + 3.2)]))
			out.append(PackedVector2Array([Vector2(q.x + 0.3, q.y + 0.4), Vector2(q.x + 1.0, q.y + 3.2)]))
	for r: Dictionary in G.rubble:
		var c: Vector2 = A._cen(r.poly)
		var rad := 0.0
		for q in (r.poly as PackedVector2Array):
			rad = maxf(rad, q.distance_to(c))
		if str(r.kind) == "stone" or str(r.kind) == "slab":
			var ring := PackedVector2Array()
			for i in 11:
				var a := -0.2 + float(i) / 10.0 * (PI + 0.4)
				ring.append(c + Vector2(cos(a) * (rad + 0.7), sin(a) * (rad + 0.7) * 0.8))
			out.append(ring)
			out.append(PackedVector2Array([c + Vector2(-rad * 0.6, rad + 0.5), c + Vector2(-rad * 0.9 - 0.8, rad + 3.2)]))
			out.append(PackedVector2Array([c + Vector2(rad * 0.6, rad + 0.5), c + Vector2(rad * 0.9 + 0.8, rad + 3.2)]))
		else:
			out.append(PackedVector2Array([c + Vector2(-rad * 0.5, 0.9), c + Vector2(-rad * 0.5 - 0.5, 2.6)]))
	return out

# --- the road --------------------------------------------------------------------------------------------------------

static func _road_params() -> Dictionary:
	var d := _render_defaults()
	var c: Dictionary = d["constants"]
	var lw: Dictionary = (d["linework"] as Dictionary)
	return {"half_px": float(c["road_half_width_px"]), "ruts": float(lw["road_ruts"])}

# The village road's look over the x intervals (metres): dirt specks across it, the eight wobbly broken lines
# at the road's offsets, and (verges=true) pebbles along both edges. `clip` is an optional Array of polygons
# in px the marks are kept inside (the deck's pieces); `line_scale` thins the lines (a deck carries them a
# little fainter than bare road). Marks are in px at the map's scale, so they follow `V.ppm`.
static func draw_road(g, V: A.View, ink: A.Ink, roles: Dictionary, intervals: Array, seed_value: int, verges: bool, clip: Array, line_scale: float, specks: bool = true, weight_mul: float = 1.0, speck_mul: float = 1.0) -> void:
	var rp := _road_params()
	var ppm_map: float = float(val(data()["road_px_per_m"]))
	var half_px: float = rp["half_px"]
	var s_px := V.ppm / ppm_map              # one map px, in screen px
	var inside := func(q: Vector2) -> bool:
		if clip.is_empty():
			return true
		for poly: PackedVector2Array in clip:
			if Geometry2D.is_point_in_polygon(q, poly):
				return true
		return false
	var step := 1.0 / ppm_map * 2.0   # one sample per two map px
	var line_defs := [[-9.0, 0.6], [-7.2, 0.35], [-10.9, 0.3], [9.0, 0.6], [7.2, 0.35], [10.9, 0.3], [-half_px, 0.3], [half_px, 0.3]]
	# dirt specks
	if specks:
		g.fill_color = ink.dirt
		for iv: Vector2 in intervals:
			var i0 := int(floor(iv.x / step))
			var i1 := int(ceil(iv.y / step))
			for i in range(i0, i1 + 1):
				var rng := Mulberry32.new(int(ValueNoise.hash2(i, 0x71A1, seed_value) * 2147483647.0))
				for _k in 6:
					var t := rng.next() * 2.0 - 1.0
					if rng.next() > 1.0 - absf(t) * 0.65:
						continue
					var off := t * half_px * 1.5 / ppm_map
					var x := float(i) * step + (rng.next() - 0.5) * 3.0 / ppm_map
					var y := off + (rng.next() - 0.5) * 3.0 / ppm_map
					if x < iv.x or x > iv.y:
						continue
					var q := V.tp(Vector2(x, y))
					var al := 0.14 + rng.next() * 0.2
					if not inside.call(q):
						continue
					g.global_alpha = minf(al * speck_mul, 0.9)
					var sz := maxf(0.9 * s_px, 0.7)
					g.fill_rect(q.x, q.y, sz, sz)
		g.global_alpha = 1.0
	# the eight lines
	g.stroke_color = ink.ink
	g.line_cap = "round"
	for li in line_defs.size():
		var o_m: float = float((line_defs[li] as Array)[0]) / ppm_map
		var alpha: float = float((line_defs[li] as Array)[1]) * line_scale
		var ns := 1000 + li * 13
		g.global_alpha = alpha
		g.line_width = float(rp["ruts"]) * ink.lw * weight_mul
		g.begin_path()
		for iv: Vector2 in intervals:
			var i0 := int(floor(iv.x / step))
			var i1 := int(ceil(iv.y / step))
			var run := PackedVector2Array()
			for i in range(i0, i1 + 2):
				var broken := ValueNoise.vnoise(float(i) * 0.045 * 2.0, 3.3, ns) < 0.3
				var x := clampf(float(i) * step, iv.x, iv.y)
				if broken or i > i1:
					if run.size() > 1:
						_stroke_run(g, run, clip)
					run = PackedVector2Array()
					continue
				var j := (ValueNoise.vnoise(float(i) * 0.09 * 2.0, 1.7, ns + 5) - 0.5) * 2.6 * (0.35 + ink.wob) / ppm_map
				run.append(V.tp(Vector2(x, o_m + j)))
			if run.size() > 1:
				_stroke_run(g, run, clip)
		g.stroke()
	g.global_alpha = 1.0
	# pebbles along the verges
	if verges:
		for iv: Vector2 in intervals:
			var i0 := int(floor(iv.x / step))
			var i1 := int(ceil(iv.y / step))
			for i in range(i0 + (5 - i0 % 5) % 5, i1 + 1, 5):
				var rng := Mulberry32.new(int(ValueNoise.hash2(i, 0x71A2, seed_value) * 2147483647.0))
				if rng.next() < 0.45:
					continue
				var off := (-1.0 if rng.next() < 0.5 else 1.0) * (half_px + 1.0 + rng.next() * 8.0) / ppm_map
				var rr := (0.6 + rng.next() * 1.4) * s_px
				var q := V.tp(Vector2(float(i) * step, off))
				g.begin_path()
				g.arc(q.x, q.y, maxf(rr, 0.6), 0.0, TAU)
				var pb: Color = roles["pebble"]
				g.global_alpha = pb.a
				g.fill_color = Color(pb.r, pb.g, pb.b, 1.0)
				g.fill()
				g.global_alpha = 0.55
				g.line_width = 0.6 * ink.lw
				g.stroke()
		g.global_alpha = 1.0

static func _stroke_run(g, run: PackedVector2Array, clip: Array) -> void:
	if clip.is_empty():
		A.add_poly(g, run, false)
		return
	for poly: PackedVector2Array in clip:
		for part: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(run, poly):
			if part.size() >= 2:
				A.add_poly(g, part, false)

# --- draw: the bridge -------------------------------------------------------------------------------------------------

static func draw_bridge(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary) -> void:
	match M.kind:
		"arch":
			_draw_arch(g, M, V, ink, roles)
		"truss":
			_draw_truss(g, M, V, ink, roles)
		_:
			_draw_trestle(g, M, V, ink, roles)

static func _stone_courses(g, ink: A.Ink, o_px: PackedVector2Array, V: A.View, rng: Mulberry32, sp_m: float, alpha: float) -> void:
	# courses of stone: lines across the block with the odd staggered joint
	var bb := A._bbox(o_px)
	var sp := maxf(sp_m * V.ppm, 2.2)
	g.stroke_color = ink.ink
	g.line_width = 0.5 * ink.lw
	g.global_alpha = alpha
	g.begin_path()
	var y := bb.position.y + sp
	while y < bb.end.y:
		var seg := PackedVector2Array([Vector2(bb.position.x - 1.0, y), Vector2(bb.end.x + 1.0, y)])
		for part: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(seg, o_px):
			if part.size() >= 2 and rng.next() > 0.12:
				g.move_to(part[0].x, part[0].y)
				g.line_to(part[1].x, part[1].y)
		y += sp
	g.stroke()
	g.global_alpha = 1.0

static func _ruin_blocks(pn: A.Pen, g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary) -> void:
	var ppm := V.ppm
	for r: Dictionary in M.G.rubble:
		var kind := str(r.kind)
		if kind == "stone" or kind == "slab":
			var o := A._path(pn, r.poly, {"fill": roles["rubble"], "weight": 0.0})
			A.shade_side(g, o, V.tp(A._cen(r.poly)), ink.sd, roles["rubble_slope"])
			A.edge_hatch(g, ink, o, minf(3.0, 0.7 * ppm), A._rng(pn))
			A.stroke_o(g, ink, o, 0.9)
			if kind == "slab" and ppm > 1.2:
				var c: Vector2 = A._cen(r.poly)
				A._line(pn, PackedVector2Array([c + Vector2(-2.0, -0.4), c + Vector2(2.0, -0.4)]), {"alpha": 0.5, "weight": 0.5, "breaks": 0.2})
				A._line(pn, PackedVector2Array([c + Vector2(-2.0, 0.5), c + Vector2(2.0, 0.5)]), {"alpha": 0.5, "weight": 0.5, "breaks": 0.2})
		else:
			var o2 := A._path(pn, r.poly, {"fill": roles["timber"], "weight": 0.8})
			if kind == "timber" and ppm > 1.4:
				var cc: Vector2 = A._cen(r.poly)
				A._path(pn, A.circ(cc, 0.12, 6), {"weight": 0.4, "alpha": 0.5})

static func _road_on_deck(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary, line_scale: float, specks: bool, weight_mul: float = 1.5, speck_mul: float = 2.2) -> void:
	var clip: Array = []
	for poly: PackedVector2Array in M.G.deck:
		clip.append(V.tps(poly))
	var iv: Array = []
	for seg: Vector2 in M.G.keep:
		iv.append(seg)
	draw_road(g, V, ink, roles, iv, M.seed + 11, false, clip, line_scale, specks, weight_mul, speck_mul)

static func _draw_arch(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var dw: float = p.deck_w
	if M.ruin:
		_ruin_blocks(pn, g, M, V, ink, roles)
	# piers and abutments: the stone under it all
	for pr: Dictionary in G.piers:
		var o := A._path(pn, pr.poly, {"fill": roles["stone_rock"], "weight": 0.0})
		if ppm > 1.2:
			_stone_courses(g, ink, o, V, A._rng(pn), 0.9, 0.4)
		A.shade_side(g, o, V.tp(Vector2(pr.x, 0.0)), ink.sd, roles["stone_rock_slope"])
		A.edge_hatch(g, ink, o, minf(4.0, 0.9 * ppm), A._rng(pn))
		A.stroke_o(g, ink, o, 1.1)
	for ab: PackedVector2Array in G.abutments:
		var ao := A._path(pn, ab, {"fill": roles["stone_rock"], "weight": 0.0})
		A.edge_hatch(g, ink, ao, minf(4.0, 0.9 * ppm), A._rng(pn))
		A.stroke_o(g, ink, ao, 1.1)
	# the roadway: each piece, its two halves per arch, its ridges
	var deck_px: Array = []
	for poly: PackedVector2Array in G.deck:
		var o := A._path(pn, poly, {"fill": roles["stone"], "weight": 0.0})
		deck_px.append(o)
		A.stipple(g, ink, o, {"rng": A._rng(pn), "density": 2.4, "r": 0.45, "alpha": 0.42})
	# (Alex 2026-10-10: the shaded halves read as blue stripes across the deck. With humped_deck false the deck is one
	# flat stone surface; the arches show in the piers, the cutwaters and the shadow on the water.)
	for hmp: Dictionary in (G.humps if bool(p.get("humped_deck", true)) else []):
		var half_rect := V.tps(A.rect_p(float(hmp.xm), -dw / 2.0 - 0.5, float(hmp.x1), dw / 2.0 + 0.5))
		for o: PackedVector2Array in deck_px:
			for part: PackedVector2Array in Geometry2D.intersect_polygons(o, half_rect):
				g.begin_path()
				A.add_poly(g, part, true)
				g.fill_color = roles["stone_slope"]
				g.fill()
		A._line(pn, PackedVector2Array([Vector2(float(hmp.xm), -dw / 2.0), Vector2(float(hmp.xm), dw / 2.0)]), {"alpha": 0.6, "weight": 0.8})
	_road_on_deck(g, M, V, ink, roles, 1.0, true)
	for o: PackedVector2Array in deck_px:
		A.stroke_o(g, ink, o, 1.0)
		if M.ruin:
			A.edge_hatch(g, ink, o, minf(3.0, 0.7 * ppm), A._rng(pn))
	# the parapets, the wing walls: stone bands with the slope tone on the face away from the sun and a coping line
	var bands: Array = []
	bands.append_array(G.parapets)
	bands.append_array(G.wings)
	for band: PackedVector2Array in bands:
		var bo := A._path(pn, band, {"fill": roles["stone"], "weight": 0.0})
		A.shade_side(g, bo, V.tp(A._cen(band)), ink.sd, roles["stone_slope"])
		A.edge_hatch(g, ink, bo, minf(3.0, 0.8 * ppm), A._rng(pn))
		A.stroke_o(g, ink, bo, 1.0)
	if ppm > 1.4:
		for band: PackedVector2Array in G.parapets:
			var c := A._cen(band)
			var bb := A._bbox(band)
			A._line(pn, PackedVector2Array([Vector2(bb.position.x + 0.4, c.y), Vector2(bb.end.x - 0.4, c.y)]), {"alpha": 0.45, "weight": 0.5, "breaks": 0.15})

static func _draw_truss(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var dw: float = p.deck_w
	# the fallen middle first: it lies in the water, under what stands
	if M.ruin:
		_ruin_blocks(pn, g, M, V, ink, roles)
		var f: Dictionary = G.fallen
		var fo := A._path(pn, f.deck, {"fill": roles["timber"], "weight": 0.9})
		if ppm > 1.4:
			_planks_across(g, ink, fo, V, A._rng(pn), 1.1)
		for ch: PackedVector2Array in f.chords:
			A._path(pn, ch, {"fill": roles["steel"], "weight": 0.9})
		for st_line: PackedVector2Array in f.struts:
			A._line(pn, st_line, {"weight": 0.55, "alpha": 0.6})
		for br: PackedVector2Array in f.braces:
			A._line(pn, br, {"weight": 0.5, "alpha": 0.55})
		# half under the water: the placeholder wash laid over the wreck
		g.begin_path()
		A.add_poly(g, fo, true)
		var sub: Color = roles["submerged"]
		g.fill_color = Color(sub.r, sub.g, sub.b, 1.0)
		g.global_alpha = sub.a
		g.fill()
		g.global_alpha = 1.0
	for ab: PackedVector2Array in G.abutments:
		var ao := A._path(pn, ab, {"fill": roles["stone_rock"], "weight": 0.0})
		if ppm > 1.2:
			_stone_courses(g, ink, ao, V, A._rng(pn), 0.9, 0.4)
		A.edge_hatch(g, ink, ao, minf(4.0, 0.9 * ppm), A._rng(pn))
		A.stroke_o(g, ink, ao, 1.1)
	var deck_px: Array = []
	for poly: PackedVector2Array in G.deck:
		var o := A._path(pn, poly, {"fill": roles["timber"], "weight": 0.0})
		deck_px.append(o)
		if ppm > 1.4:
			_planks_across(g, ink, o, V, A._rng(pn), 0.9)
	_road_on_deck(g, M, V, ink, roles, 1.0, false)
	for o: PackedVector2Array in deck_px:
		A.stroke_o(g, ink, o, 1.0)
	# kerb lines under the trusses
	if ppm > 1.0:
		for seg: Vector2 in G.keep:
			for s: float in [-1.0, 1.0]:
				A._line(pn, PackedVector2Array([Vector2(seg.x, s * dw / 2.0), Vector2(seg.y, s * dw / 2.0)]), {"alpha": 0.6, "weight": 0.6})
	# the top lateral bracing over the roadway: X bracing between the struts, then the struts
	for br: PackedVector2Array in G.braces:
		A._line(pn, br, {"weight": 0.55, "alpha": 0.7})
	for sd: Dictionary in G.struts:
		A._line(pn, sd.line, {"weight": 1.0 if sd.heavy else 0.75, "alpha": 0.95})
	for e: PackedVector2Array in G.torn:
		A._line(pn, e, {"weight": 0.6, "alpha": 0.75, "breaks": 0.1})
	# the top chords: flat strips, the side of the truss seen edge-on
	for ch: PackedVector2Array in G.chords:
		var co := A._path(pn, ch, {"fill": roles["steel"], "weight": 0.0})
		A.shade_side(g, co, V.tp(A._cen(ch)), ink.sd, roles["stone_slope"])
		A.edge_hatch(g, ink, co, minf(3.0, 0.7 * ppm), A._rng(pn))
		A.stroke_o(g, ink, co, 1.0)
	if ppm > 1.4:
		g.fill_color = ink.ink
		g.global_alpha = 0.8
		g.begin_path()
		for q: Vector2 in G.joints:
			var qq := V.tp(q)
			g.move_to(qq.x + 0.7, qq.y)
			g.arc(qq.x, qq.y, 0.7, 0.0, TAU)
		g.fill()
		g.global_alpha = 1.0

static func _planks_across(g, ink: A.Ink, o_px: PackedVector2Array, V: A.View, rng: Mulberry32, sp_m: float) -> void:
	# deck planks: lines across the road, one every sp_m metres, from a stream per plank
	var bb := A._bbox(o_px)
	var sp := maxf(sp_m * V.ppm, 1.6)
	g.stroke_color = ink.ink
	g.line_width = 0.5 * ink.lw
	g.global_alpha = 0.5
	g.begin_path()
	var x := bb.position.x + sp * 0.5
	while x < bb.end.x:
		var seg := PackedVector2Array([Vector2(x, bb.position.y - 1.0), Vector2(x, bb.end.y + 1.0)])
		for part: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(seg, o_px):
			if part.size() >= 2 and rng.next() > 0.08:
				g.move_to(part[0].x, part[0].y)
				g.line_to(part[1].x, part[1].y)
		x += sp
	g.stroke()
	g.global_alpha = 1.0

static func _draw_trestle(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var dw: float = p.deck_w
	if M.ruin:
		_ruin_blocks(pn, g, M, V, ink, roles)
		for q: Vector2 in G.stubs:
			A._path(pn, A.circ(q, 0.46, 8), {"fill": roles["timber"], "weight": 0.85, "wob": 0.6})
	for ab: PackedVector2Array in G.abutments:
		var ao := A._path(pn, ab, {"fill": roles["stone_rock"], "weight": 0.0})
		if ppm > 1.2:
			_stone_courses(g, ink, ao, V, A._rng(pn), 0.9, 0.4)
		A.edge_hatch(g, ink, ao, minf(4.0, 0.9 * ppm), A._rng(pn))
		A.stroke_o(g, ink, ao, 1.1)
	# the piles that stand in the water beyond the deck's edge, and the cap beams across them
	for q: Vector2 in G.piles:
		if absf(q.y) > dw / 2.0:
			A._path(pn, A.circ(q, 0.46, 10), {"fill": roles["timber_new"], "weight": 0.85})
	for cap: PackedVector2Array in G.caps:
		A._path(pn, cap, {"fill": roles["timber"], "weight": 0.8})
	var deck_px: Array = []
	for poly: PackedVector2Array in G.deck:
		var o := A._path(pn, poly, {"fill": roles["timber"], "weight": 0.0})
		deck_px.append(o)
		if ppm > 1.2:
			_planks_across(g, ink, o, V, A._rng(pn), 0.9)
	_road_on_deck(g, M, V, ink, roles, 1.0, true, 1.6, 1.6)
	for o: PackedVector2Array in deck_px:
		A.edge_hatch(g, ink, o, minf(3.0, 0.7 * ppm), A._rng(pn))
		A.stroke_o(g, ink, o, 1.1)
	for r: PackedVector2Array in G.rails:
		A._line(pn, r, {"weight": 0.9, "alpha": 0.9})
		A._line(pn, PackedVector2Array([r[0] + Vector2(0.0, 0.0), r[1]]), {"weight": 0.5, "alpha": 0.5})
	if ppm > 1.0:
		g.fill_color = ink.ink
		g.global_alpha = 0.85
		g.begin_path()
		for q: Vector2 in G.posts:
			var qq := V.tp(q)
			g.move_to(qq.x + maxf(0.6, 0.2 * ppm), qq.y)
			g.arc(qq.x, qq.y, maxf(0.6, 0.2 * ppm), 0.0, TAU)
		g.fill()
		g.global_alpha = 1.0
