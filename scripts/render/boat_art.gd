extends RefCounted

# THE BOATS IN INK (Track BB, 2026-10-10): a patrol boat and a supply boat, drawn in the style of the
# unit sheet's small cruiser (reference/mockups/unit_sheet.html genCruiser / buildCruiser /
# drawCruiserGround / drawCruiserUpper) and written the way unit_marker_art.gd and
# unit_marker_art_static.gd write the planes, the tank and the static units: gen(rng) -> parameters
# in metres, build(p) -> geometry in metres, draw onto an InkCanvas through the same pen and helpers.
# NEW generators for NEW boats; nothing is ported from the sheet but the style and the helpers, and
# NOTHING IS IN THE GAME YET: the look is chosen on a board (variants/boats/, scripts/ui/boards/
# boats_board_shot.gd), then ported into the marker layer as the planes were.
#
#   var M := BoatArt.model(style, "patrol", "p1")          # parameters + geometry, metres
#   BoatArt.draw_wake(g, M, V, ink, roles, "ink_v")         # under the shadow
#   BoatArt.draw_boat(g, M, V, ink, roles, side_accent)     # the boat (hull, deck, upper works)
#   BoatArt.shadow_polys(M, V, k_px_per_m)                  # the cast shadow, in px, for ONE translucent fill
#
# THE FRAME is the sheet's: x to starboard, y aft, the bow toward -y, metres; a View (unit_marker_art.gd
# View) maps metres to pixels and may be ROTATED (the static units are baked already turned, so the
# light on a boat is the map's at any heading; a boat that is baked nose up and turned by the marker, as
# the planes are, would carry its light with it -- a documented departure the lead can choose).
#
# THE SEED. unitSeed(unit_index, variant) on the scene seed, as the planes'. The sheet's UNITS list
# ends at the radio tower (6); the patrol boat is 7 and the supply boat 8 (data/world/boats.json).
#
# COLOUR is a ROLE (data/world/boats.json roles, resolved by ink_roles.gd): the hull, the house, the
# tarpaulin, the foam are the paper ramp and the ink; the side's accent is on ONE zone only (a painted
# recognition panel: the patrol boat's engine casing, the supply boat's house roof or hold tarpaulin).
# Material is linework (planks, rivets, battens, stipple). No hex in this file.
#
# THE SHADOW on the water is the sheet's castShadows rule: a part of height h above the water throws
# its footprint h x (the sun's length) away from the sun; a solid part (hull, house, funnel, cargo)
# is a prism (its footprint swept from its base height to its top), a thin one (mast, derrick, rail,
# gun barrel) a line. shadow_polys returns the union as polygons in px for one fill.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const S = preload("res://scripts/ui/unit_marker_art_static.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const DATA_PATH := "res://data/world/boats.json"

class Model:
	var kind: String      # "patrol" | "supply"
	var look: String
	var seed: int
	var p: Dictionary
	var G: Dictionary

static var _data: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if v is Dictionary:
			_data = v
		else:
			push_error("boat_art: %s does not parse as a JSON object" % DATA_PATH)
	return _data

# A value record's value, or the plain value.
static func val(rec: Variant) -> Variant:
	if rec is Dictionary and (rec as Dictionary).has("value"):
		return (rec as Dictionary)["value"]
	return rec

static func looks_of(kind: String) -> Array:
	var out: Array = []
	var d: Dictionary = data()[kind]
	for k: String in (d["looks"] as Dictionary):
		out.append(k)
	return out

static func model(st: RefCounted, kind: String, look_id: String) -> Model:
	var d: Dictionary = data()[kind]
	var look: Dictionary = (d["looks"] as Dictionary)[look_id]
	var m := Model.new()
	m.kind = kind
	m.look = look_id
	m.seed = A.unit_seed(st.scene_seed, int(val(d["unit_index"])), int(look["variant"]))
	var rng := Mulberry32.new(m.seed)
	m.p = gen(kind, look, d, rng)
	m.G = build(m.p)
	return m

# --- gen ---------------------------------------------------------------------------------------------

static func _rr(rng: Mulberry32, pair: Variant) -> float:
	var a: Array = pair
	return A._r(rng, float(a[0]), float(a[1]))

static func gen(kind: String, look: Dictionary, d: Dictionary, rng: Mulberry32) -> Dictionary:
	var p := {}
	p.kind = kind
	p.look = str(look.get("title", ""))
	p.length = _rr(rng, look["length"])
	p.beam = _rr(rng, look["beam"])
	p.bow = _rr(rng, look["bow"])
	p.bow_exp = _rr(rng, look["bow_exp"])
	p.stern = str(look["stern"])
	p.stern_len = _rr(rng, look["stern_len"])
	p.stern_taper = _rr(rng, look["stern_taper"])
	p.freeboard = float(val(d["freeboard_m"]))
	p.gunwale = float(val(d["gunwale_m"]))
	p.wake_len = float(val(d["wake_len_m"]))
	p.detail = int(look["detail"])
	p.house_at = _rr(rng, look["house_at"])
	p.house_len = _rr(rng, look["house_len"])
	p.house_wid = _rr(rng, look["house_wid"])
	p.funnel = bool(look["funnel"])
	p.cargo_seed = int(rng.next() * 2147483646.0)
	if kind == "patrol":
		p.mount_r = _rr(rng, look["mount_r"])
		p.barrel_len = _rr(rng, look["barrel_len"])
		for key: String in ["fore", "aft"]:
			var m: Dictionary = look[key]
			p[key] = {"mount": str(m["mount"]), "barrels": int(m["barrels"]), "at": _rr(rng, m["at"])}
		p.mast = bool(look["mast"])
		p.dinghy = bool(look["dinghy"])
		p.rafts = bool(look["rafts"])
		p.charges = bool(look["charges"])
		p.panel_at = _rr(rng, look["panel_at"])
	else:
		var hs: Array = look["hatches"]
		var cs: Array = []
		for t: Variant in hs:
			cs.append(float(t))
		p.hatches = cs
		p.hatch_len = _rr(rng, look["hatch_len"])
		p.hatch_wid = _rr(rng, look["hatch_wid"])
		p.derrick = bool(look["derrick"])
		p.cargo = str(look["cargo"])
		var cn: Array = look["cargo_n"]
		p.cargo_n = int(A._r(rng, float(cn[0]), float(cn[1])))
		p.panel = str(look["panel"])
	return p

# --- build: shared hull ----------------------------------------------------------------------------------

static func _y(L: float, t: float) -> float:
	return -L / 2.0 + t * L

# Half the beam at t (0 = the bow, 1 = the stern).
static func hb(p: Dictionary, t: float) -> float:
	var B: float = p.beam
	var bow: float = p.bow
	if t < bow:
		var u := t / bow
		return B / 2.0 * pow(sin(u * PI / 2.0), float(p.bow_exp))
	var ts: float = 1.0 - float(p.stern_len)
	if t <= ts:
		return B / 2.0
	var u2 := (t - ts) / (1.0 - ts)
	if p.stern == "transom":
		return B / 2.0 * (1.0 - float(p.stern_taper) * u2 * u2)
	return B / 2.0 * sqrt(maxf(0.0, 1.0 - u2 * u2 * 0.85))

static func _hull(p: Dictionary) -> PackedVector2Array:
	var L: float = p.length
	var n := 56
	var pts := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / float(n)
		pts.append(Vector2(hb(p, t), _y(L, t)))
	if p.stern == "round":
		var r1 := hb(p, 1.0)
		for k in range(1, 8):
			var a := float(k) / 8.0 * PI
			pts.append(Vector2(cos(a) * r1, L / 2.0 + sin(a) * r1 * 0.8))
	for i in range(n, 0, -1):
		var t := float(i) / float(n)
		pts.append(Vector2(-hb(p, t), _y(L, t)))
	return pts

static func build(p: Dictionary) -> Dictionary:
	if p.kind == "patrol":
		return _build_patrol(p)
	return _build_supply(p)

# A cast entry. kind "prism": a footprint standing from `b` to `h` metres above the water. "line": a thin
# part, each end at its own height (a Vector3 list [x, y, z0], [x, y, z1]), w metres wide, never under
# minPx. "float": a polygon held at height h (no extrusion).
static func _prism(polys: Array, b: float, h: float) -> Dictionary:
	return {"kind": "prism", "polys": polys, "b": b, "h": h}

static func _line3(lines: Array, w: float, min_px: float) -> Dictionary:
	return {"kind": "line", "lines": lines, "w": w, "min_px": min_px}

static func _ell(cx: float, cy: float, rx: float, ry: float, n: int = 20) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		out.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
	return out

# A gun mount: the sheet's gun house, the battery's shield and barrels, in boat metres. a = the way it points.
static func _mount(c: Vector2, a: float, r: float, barrels: int, blen: float, kind: String) -> Dictionary:
	var m := {"c": c, "a": a, "r": r, "kind": kind}
	m.base = A.circ(c, r, 18)
	var sh := PackedVector2Array()
	var shi := PackedVector2Array()
	for i in 9:
		var t := -1.15 + 2.3 * float(i) / 8.0
		sh.append(Vector2(cos(t), sin(t)) * r * 1.08)
		shi.append(Vector2(cos(t), sin(t)) * r * 0.84)
	shi.reverse()
	sh.append_array(shi)
	m.shield = S.place(sh, c.x, c.y, a)
	var dir := Vector2(cos(a), sin(a))
	var perp := Vector2(-dir.y, dir.x)
	var offs: Array = [0.0] if barrels == 1 else [-0.24, 0.24]
	var bars: Array = []
	for o: float in offs:
		bars.append(PackedVector2Array([c + dir * r * 0.55 + perp * o, c + dir * (r * 0.55 + blen) + perp * o]))
	m.barrels = bars
	m.ring = A.circ(c, r * 1.55, 22) if kind == "tub" else PackedVector2Array()
	return m

static func _build_patrol(p: Dictionary) -> Dictionary:
	var L: float = p.length
	var B: float = p.beam
	var fb: float = p.freeboard
	var G := {}
	G.hull = _hull(p)
	G.deck = S.offset_poly(G.hull, p.gunwale)
	G.mounts = []
	for key: String in ["fore", "aft"]:
		var m: Dictionary = p[key]
		if str(m["mount"]) == "none":
			continue
		var c := Vector2(0.0, _y(L, float(m["at"])))
		var a := -PI / 2.0 if key == "fore" else PI / 2.0
		(G.mounts as Array).append(_mount(c, a, p.mount_r, int(m["barrels"]), p.barrel_len, str(m["mount"])))
	var yh := _y(L, float(p.house_at))
	var hl: float = L * float(p.house_len)
	var hw: float = B * float(p.house_wid)
	G.house = A.rrect(0.0, yh, hw, hl, 0.55)
	G.wheel = A.rrect(0.0, yh - hl * 0.14, hw * 0.74, hl * 0.56, 0.4)
	G.wheel_front = PackedVector2Array([Vector2(-hw * 0.34, yh - hl * 0.14 - hl * 0.19), Vector2(hw * 0.34, yh - hl * 0.14 - hl * 0.19)])
	G.skylight = A.rect_p(-hw * 0.2, yh + hl * 0.26, hw * 0.2, yh + hl * 0.42)
	G.house_inset = S.offset_poly(G.house, 0.4)
	G.funnel = {}
	if p.funnel:
		G.funnel = {"c": Vector2(0.0, yh + hl * 0.5 + 1.15), "rx": 0.85, "ry": 1.25}
	G.mast = {}
	if p.mast:
		G.mast = {"c": Vector2(0.0, yh - hl * 0.05), "yard": B * 0.78, "r": 0.32}
	G.panel = A.rect_p(-B * 0.2, _y(L, float(p.panel_at)) - L * 0.034, B * 0.2, _y(L, float(p.panel_at)) + L * 0.034)
	G.dinghy = PackedVector2Array()
	if p.dinghy:
		G.dinghy = _ell(B * 0.2, _y(L, float(p.house_at)) + hl * 0.62, 0.8, 2.3, 16)
	G.rafts = []
	if p.rafts:
		for s: float in [-1.0, 1.0]:
			(G.rafts as Array).append(A.circ(Vector2(s * (B * 0.32), yh + hl * 0.12), 0.55, 12))
	G.charges = []
	if p.charges:
		for s: float in [-1.0, 1.0]:
			(G.charges as Array).append(A.rect_p(s * 0.75 - 0.28, _y(L, 0.935) - 0.6, s * 0.75 + 0.28, _y(L, 0.935) + 0.6))
	G.capstan = A.circ(Vector2(0.0, _y(L, 0.075)), 0.4, 10)
	G.chain = PackedVector2Array([Vector2(-0.5, _y(L, 0.03)), Vector2(0.0, _y(L, 0.075)), Vector2(0.5, _y(L, 0.03))])
	G.bollards = []
	for t: float in [0.1, 0.52, 0.66, 0.94]:
		for s: float in [1.0, -1.0]:
			(G.bollards as Array).append(Vector2(s * (hb(p, t) - 0.75), _y(L, t)))
	# the turtle back: the foredeck's break line (broken line across the deck)
	G.turtle = PackedVector2Array([Vector2(-hb(p, 0.42) * 0.78, _y(L, 0.42)), Vector2(0.0, _y(L, 0.405)), Vector2(hb(p, 0.42) * 0.78, _y(L, 0.42))])
	G.casts = []
	(G.casts as Array).append(_prism([G.hull], 0.0, fb))
	for m: Dictionary in G.mounts:
		(G.casts as Array).append(_prism([m.base], fb, fb + 1.5))
		var bl: Array = []
		for b: PackedVector2Array in m.barrels:
			bl.append(PackedVector3Array([Vector3(b[0].x, b[0].y, fb + 1.2), Vector3(b[1].x, b[1].y, fb + 1.3)]))
		(G.casts as Array).append(_line3(bl, 0.2, 0.9))
	(G.casts as Array).append(_prism([G.house], fb, fb + 2.4))
	(G.casts as Array).append(_prism([G.wheel], fb, fb + 4.3))
	if p.funnel:
		(G.casts as Array).append(_prism([_ell(G.funnel.c.x, G.funnel.c.y, G.funnel.rx, G.funnel.ry, 16)], fb, fb + 4.6))
	if p.mast:
		var mc: Vector2 = G.mast.c
		(G.casts as Array).append(_line3([PackedVector3Array([Vector3(mc.x, mc.y, fb + 4.3), Vector3(mc.x, mc.y, fb + 10.0)]),
			PackedVector3Array([Vector3(-G.mast.yard / 2.0, mc.y, fb + 8.6), Vector3(G.mast.yard / 2.0, mc.y, fb + 8.6)])], 0.25, 0.8))
	if p.dinghy:
		(G.casts as Array).append(_prism([G.dinghy], fb, fb + 0.7))
	var ext: Array = [G.hull]
	for m: Dictionary in G.mounts:
		ext.append(PackedVector2Array(m.barrels[0]))
	G.ext = ext
	return G

static func _build_supply(p: Dictionary) -> Dictionary:
	var L: float = p.length
	var B: float = p.beam
	var fb: float = p.freeboard
	var G := {}
	G.hull = _hull(p)
	G.deck = S.offset_poly(G.hull, p.gunwale)
	var rng := Mulberry32.new(int(p.cargo_seed))
	# the house (and its roof's accent zone)
	var yh := _y(L, float(p.house_at))
	var hl: float = L * float(p.house_len)
	var hw: float = B * float(p.house_wid)
	G.house = A.rrect(0.0, yh, hw, hl, 0.6)
	G.house_inset = S.offset_poly(G.house, 0.45)
	G.wheel = A.rrect(0.0, yh - hl * 0.16, hw * 0.78, hl * 0.4, 0.45)
	G.wheel_front = PackedVector2Array([Vector2(-hw * 0.3, yh - hl * 0.16 - hl * 0.14), Vector2(hw * 0.3, yh - hl * 0.16 - hl * 0.14)])
	G.skylight = A.rect_p(-hw * 0.18, yh + hl * 0.18, hw * 0.18, yh + hl * 0.34)
	G.panel = PackedVector2Array()
	if p.panel == "roof":
		G.panel = A.rect_p(-hw * 0.28, yh + hl * 0.05, hw * 0.28, yh + hl * 0.44) if hl > 5.0 else A.rect_p(-hw * 0.26, yh - hl * 0.1, hw * 0.26, yh + hl * 0.3)
	G.funnel = {}
	if p.funnel:
		G.funnel = {"c": Vector2(0.0, yh + hl * 0.2), "rx": minf(1.15, hw * 0.24), "ry": minf(1.6, hl * 0.19)}
	# hatches: coaming, tarpaulin, battens, ties
	G.hatches = []
	var hatch_polys: Array = []
	for t: float in p.hatches:
		var yc := _y(L, t)
		var hl2: float = L * float(p.hatch_len)
		var hw2: float = minf(B * float(p.hatch_wid), hb(p, t) * 2.0 - 1.6)
		var poly := A.rect_p(-hw2 / 2.0, yc - hl2 / 2.0, hw2 / 2.0, yc + hl2 / 2.0)
		var coam := A.rect_p(-hw2 / 2.0 - 0.3, yc - hl2 / 2.0 - 0.3, hw2 / 2.0 + 0.3, yc + hl2 / 2.0 + 0.3)
		var battens: Array = []
		var by := yc - hl2 / 2.0 + 1.0
		while by < yc + hl2 / 2.0 - 0.5:
			battens.append(PackedVector2Array([Vector2(-hw2 / 2.0 + 0.1, by), Vector2(hw2 / 2.0 - 0.1, by)]))
			by += 1.35
		var ties: Array = [PackedVector2Array([Vector2(-hw2 / 2.0, yc - hl2 / 2.0), Vector2(hw2 / 2.0, yc + hl2 / 2.0)]),
			PackedVector2Array([Vector2(hw2 / 2.0, yc - hl2 / 2.0), Vector2(-hw2 / 2.0, yc + hl2 / 2.0)])]
		(G.hatches as Array).append({"poly": poly, "coaming": coam, "battens": battens, "ties": ties, "c": Vector2(0.0, yc), "w": hw2, "l": hl2})
		hatch_polys.append(coam)
	if p.panel == "tarp" and (G.hatches as Array).size() > 0:
		var h0: Dictionary = G.hatches[0]
		G.panel = A.rect_p(-h0.w * 0.3, h0.c.y - h0.l * 0.1, h0.w * 0.3, h0.c.y + h0.l * 0.1)
	# derrick: a mast and a boom on the foredeck
	G.derrick = {}
	if p.derrick:
		var mc := Vector2(0.0, _y(L, 0.115))
		G.derrick = {"c": mc, "boom": PackedVector2Array([mc, mc + Vector2(B * 0.42, -B * 0.55)]), "stay": PackedVector2Array([mc, mc + Vector2(-B * 0.3, L * 0.07)]), "r": 0.38}
	# deck cargo: slots along the deck, one item to port and one to starboard in each, of three kinds
	# (a block of crates, a cluster of barrels, a tarpaulined stack) picked from the boat's own stream
	G.crates = []
	G.barrels = []
	G.stacks = []
	var cargo_polys: Array = []
	if p.cargo != "none":
		var lo := 0.2
		var hi: float = float(p.house_at) - float(p.house_len) / 2.0 - 0.025
		if (G.hatches as Array).size() > 0:
			lo = float(p.hatches[(p.hatches as Array).size() - 1]) + float(p.hatch_len) / 2.0 + 0.02
		var n: int = p.cargo_n
		n = clampi(n, 1, maxi(1, int(floor((hi - lo) * L / 3.6))))
		for i in n:
			var t := lo + (hi - lo) * (float(i) + 0.5) / float(n)
			var yc := _y(L, t)
			var half := hb(p, t) - 0.95
			var slot := (hi - lo) * L / float(n)
			for side: float in [-1.0, 1.0]:
				var kind := int(rng.next() * 3.0)
				var cw := minf(half * 0.95, 2.9)
				var cx := side * (half - cw * 0.5)
				var yj := yc + (rng.next() - 0.5) * 0.8
				if kind == 0:
					var a := (rng.next() - 0.5) * 0.12
					var sz := Vector2(cw, minf(slot - 0.5, 2.2 + rng.next() * 0.8))
					for j in 2:
						var cr := S.place(A.rect_p(-sz.x / 2.0, -sz.y / 4.0 - 0.02, sz.x / 2.0, sz.y / 4.0 + 0.02), cx + (rng.next() - 0.5) * 0.3, yj + (float(j) - 0.5) * sz.y * 0.5, a)
						(G.crates as Array).append(cr)
						cargo_polys.append(cr)
				elif kind == 1:
					var rb := 0.5
					var cells := [Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(-1.0, 0.0), Vector2(0.5, 0.87), Vector2(-0.5, 0.87), Vector2(0.5, -0.87), Vector2(-0.5, -0.87)]
					for ci in cells.size():
						var bp := Vector2(cx, yj) + (cells[ci] as Vector2) * rb * 1.02
						if absf(bp.x) > half - rb * 0.5:
							continue
						var bc := A.circ(bp, rb, 10)
						(G.barrels as Array).append(bc)
						cargo_polys.append(bc)
				else:
					var st := A.rrect(cx, yj, cw, minf(slot - 0.5, 2.6 + rng.next() * 0.8), 0.7)
					(G.stacks as Array).append({"poly": st, "c": Vector2(cx, yj)})
					cargo_polys.append(st)
	# small gear
	G.bollards = []
	for t: float in [0.06, 0.5, 0.95]:
		for s: float in [1.0, -1.0]:
			(G.bollards as Array).append(Vector2(s * (hb(p, t) - 0.7), _y(L, t)))
	G.capstan = A.circ(Vector2(0.0, _y(L, 0.06)), 0.45, 10)
	G.casts = []
	(G.casts as Array).append(_prism([G.hull], 0.0, fb))
	(G.casts as Array).append(_prism(hatch_polys, fb, fb + 0.55))
	(G.casts as Array).append(_prism(cargo_polys, fb, fb + 1.7))
	(G.casts as Array).append(_prism([G.house], fb, fb + 3.0))
	(G.casts as Array).append(_prism([G.wheel], fb, fb + 5.0))
	if p.funnel:
		(G.casts as Array).append(_prism([_ell(G.funnel.c.x, G.funnel.c.y, G.funnel.rx, G.funnel.ry, 16)], fb, fb + 6.2))
	if p.derrick:
		var dc: Vector2 = G.derrick.c
		var bm: PackedVector2Array = G.derrick.boom
		(G.casts as Array).append(_line3([PackedVector3Array([Vector3(dc.x, dc.y, fb), Vector3(dc.x, dc.y, fb + 9.0)]),
			PackedVector3Array([Vector3(bm[0].x, bm[0].y, fb + 8.0), Vector3(bm[1].x, bm[1].y, fb + 4.5)])], 0.25, 0.8))
	G.ext = [G.hull]
	return G

# --- the shadow ----------------------------------------------------------------------------------------------

# The cast shadow as polygons in px, for ONE translucent fill (overlaps merge, never darken twice). `k` is
# the drawn shadow offset per metre of height in px: the map's shadow direction x the sun's length x the
# px per metre.
static func shadow_polys(M: Model, V: A.View, k: Vector2) -> Array:
	var out: Array = []
	for c: Dictionary in M.G.casts:
		match str(c["kind"]):
			"prism":
				for poly: PackedVector2Array in c["polys"]:
					out.append_array(prism_px(V.tps(poly), k * float(c["b"]), k * float(c["h"])))
			"float":
				for poly: PackedVector2Array in c["polys"]:
					out.append(shift_px(V.tps(poly), k * float(c["h"])))
			"line":
				for ln: PackedVector3Array in c["lines"]:
					var a := V.tp(Vector2(ln[0].x, ln[0].y)) + k * ln[0].z
					var b := V.tp(Vector2(ln[1].x, ln[1].y)) + k * ln[1].z
					var w := maxf(float(c["w"]) * V.ppm, float(c["min_px"]))
					var d := (b - a)
					if d.length() < 0.001:
						d = Vector2(1.0, 0.0)
					var nrm := Vector2(-d.y, d.x).normalized() * w * 0.5
					out.append(PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm]))
	return out

static func shift_px(poly: PackedVector2Array, off: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in poly:
		out.append(q + off)
	return out

# A footprint standing from offset s0 to s1: the footprint at each end and a quad per edge between them.
static func prism_px(poly: PackedVector2Array, s0: Vector2, s1: Vector2) -> Array:
	var out: Array = [shift_px(poly, s0), shift_px(poly, s1)]
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var quad := PackedVector2Array([a + s0, b + s0, b + s1, a + s1])
		if absf((b - a).cross(s1 - s0)) > 0.02:
			out.append(quad)
	return out

# --- draw: the boat --------------------------------------------------------------------------------------------

static func _planks(g, ink: A.Ink, o_px: PackedVector2Array, V: A.View, rng: Mulberry32, sp: float) -> void:
	var ax := V.tv(Vector2(0.0, 1.0))
	var nrm := Vector2(-ax.y, ax.x)
	var bb := A._bbox(o_px)
	var c := bb.position + bb.size * 0.5
	var R := bb.size.length() / 2.0 + 2.0
	g.stroke_color = ink.ink
	g.line_width = 0.5 * ink.lw
	g.global_alpha = 0.4
	g.begin_path()
	var d := -R
	while d <= R:
		var t := -R + rng.next() * 20.0
		while t < R:
			var ln := 10.0 + rng.next() * 26.0
			if rng.next() < 0.78:
				var seg := PackedVector2Array([c + nrm * d + ax * t, c + nrm * d + ax * (t + ln)])
				for part: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(seg, o_px):
					if part.size() < 2:
						continue
					g.move_to(part[0].x, part[0].y)
					for qi in range(1, part.size()):
						g.line_to(part[qi].x, part[qi].y)
			t += ln + 1.6
		d += sp
	g.stroke()
	g.global_alpha = 1.0

static func _dots(g, ink: A.Ink, V: A.View, pts: Array, r_px: float, alpha: float) -> void:
	g.fill_color = ink.ink
	g.global_alpha = alpha
	g.begin_path()
	for b: Vector2 in pts:
		var q := V.tp(b)
		g.move_to(q.x + r_px, q.y)
		g.arc(q.x, q.y, r_px, 0.0, TAU)
	g.fill()
	g.global_alpha = 1.0

# Parallel hatch lines kept INSIDE an outline (px). (Geometry2D.clip_polyline_with_polygon is a DIFFERENCE: it keeps
# what lies outside the polygon; intersect_polyline_with_polygon is the inside.)
static func _hatch_inside(g, ink: A.Ink, o_px: PackedVector2Array, dir: Vector2, sp: float, alpha: float, weight: float) -> void:
	var bb := A._bbox(o_px)
	var c := bb.position + bb.size * 0.5
	var R := bb.size.length() / 2.0 + 1.0
	var nrm := Vector2(-dir.y, dir.x)
	g.stroke_color = ink.ink
	g.line_width = weight * ink.lw
	g.global_alpha = alpha
	g.begin_path()
	var d := -R
	while d <= R:
		var seg := PackedVector2Array([c + nrm * d - dir * R, c + nrm * d + dir * R])
		for part: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(seg, o_px):
			if part.size() >= 2:
				g.move_to(part[0].x, part[0].y)
				g.line_to(part[1].x, part[1].y)
		d += sp
	g.stroke()
	g.global_alpha = 1.0

static func _dome(g, ink: A.Ink, o_px: PackedVector2Array, V: A.View, c: Vector2, fill_shaded: Color) -> void:
	A.shade_side(g, o_px, V.tp(c), ink.sd, fill_shaded)

static func draw_boat(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary, accent: Color) -> void:
	if M.kind == "patrol":
		_draw_patrol(g, M, V, ink, roles, accent)
	else:
		_draw_supply(g, M, V, ink, roles, accent)

static func _gun_mount(pn: A.Pen, g, ink: A.Ink, V: A.View, roles: Dictionary, m: Dictionary) -> void:
	var ppm := V.ppm
	var c: Vector2 = m.c
	var gear: Color = roles["deck_gear"]
	if str(m.kind) == "tub":
		var ro := A._path(pn, m.ring, {"fill": roles["house_roof"], "weight": 0.9})
		if ppm > 2.0:
			A._path(pn, A.circ(c, float(m.r) * 1.3, 18), {"weight": 0.5, "alpha": 0.6})
	var o := A._path(pn, m.base, {"fill": gear, "weight": 0.0})
	_dome(g, ink, o, V, c, roles["hull_shaded"])
	A.stroke_o(g, ink, o, 0.9)
	if str(m.kind) == "shield":
		A._path(pn, m.shield, {"fill": gear, "weight": 0.75})
	var bw := clampf(0.24 * ppm, 0.8, 1.7)
	for b: PackedVector2Array in m.barrels:
		if ppm > 2.6:
			var d: Vector2 = (b[1] - b[0]).normalized()
			var nn := Vector2(-d.y, d.x) * 0.16
			A._path(pn, PackedVector2Array([b[0] + nn, b[1] + nn, b[1] - nn, b[0] - nn]), {"fill": gear, "weight": 0.7})
		else:
			A._line(pn, b, {"alpha": 0.9, "weight": bw})
	if ppm > 3.0:
		var tip: Vector2 = (m.barrels[0] as PackedVector2Array)[1]
		A._path(pn, A.circ(tip, 0.13, 6), {"fill": gear, "weight": 0.5})

static func _draw_patrol(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary, accent: Color) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var detail: int = p.detail
	var hull_o := A._path(pn, G.hull, {"fill": roles["hull_patrol"], "weight": 0.0})
	if detail >= 1:
		if ppm > 2.6:
			_planks(g, ink, V.tps(G.deck), V, A._rng(pn), 2.3)
		A._path(pn, G.deck, {"weight": 0.6, "alpha": 0.55, "breaks": 0.15})
	if detail >= 2 and p.look.begins_with("Whaleback"):
		A._line(pn, G.turtle, {"alpha": 0.7, "weight": 0.65, "breaks": 0.1})
	A.edge_hatch(g, ink, hull_o, minf(5.0, 1.0 * ppm), A._rng(pn))
	if detail >= 2:
		A._line(pn, G.chain, {"alpha": 0.7, "weight": 0.6})
		A._path(pn, G.capstan, {"fill": roles["deck_gear"], "weight": 0.7})
		if ppm > 2.2:
			_dots(g, ink, V, G.bollards, maxf(0.5, 0.2 * ppm), 0.7)
	A.accent_panel(pn, G.panel, accent)
	for ch: PackedVector2Array in G.charges:
		A._path(pn, ch, {"fill": roles["deck_gear"], "weight": 0.7})
		if ppm > 3.0:
			A._line(pn, PackedVector2Array([Vector2(ch[0].x, (ch[0].y + ch[2].y) / 2.0), Vector2(ch[1].x, (ch[0].y + ch[2].y) / 2.0)]), {"alpha": 0.5})
	if G.dinghy.size() > 0:
		A._path(pn, G.dinghy, {"fill": roles["deck_gear"], "weight": 0.8})
		if ppm > 3.0:
			var dc := A._cen(G.dinghy)
			A._path(pn, PackedVector2Array(Array(G.dinghy).map(func(q: Vector2) -> Vector2: return q + (dc - q) * 0.3)), {"weight": 0.5, "alpha": 0.6})
	for rf: PackedVector2Array in G.rafts:
		A._path(pn, rf, {"fill": roles["deck_gear"], "weight": 0.7})
	A.stroke_o(g, ink, hull_o, 1.2)
	# ---- the upper works
	for m: Dictionary in G.mounts:
		if (m.a as float) < 0.0:
			_gun_mount(pn, g, ink, V, roles, m)
	var h_o := A._path(pn, G.house, {"fill": roles["deck_gear"], "weight": 0.0})
	A.edge_hatch(g, ink, h_o, minf(4.0, 0.9 * ppm), A._rng(pn))
	A.stroke_o(g, ink, h_o, 1.1)
	if detail >= 1 and ppm > 2.5:
		A._path(pn, G.house_inset, {"weight": 0.5, "alpha": 0.4})
	var w_o := A._path(pn, G.wheel, {"fill": roles["house_roof"], "weight": 0.0})
	A.edge_hatch(g, ink, w_o, minf(4.0, 0.9 * ppm), A._rng(pn))
	A.stroke_o(g, ink, w_o, 1.0)
	A._line(pn, G.wheel_front, {"weight": 0.85, "alpha": 0.9})
	if detail >= 2 and ppm > 3.0:
		A._path(pn, G.skylight, {"weight": 0.5, "alpha": 0.6})
	if p.funnel:
		var f: Dictionary = G.funnel
		var fo := A._path(pn, _ell(f.c.x, f.c.y, f.rx, f.ry, 22), {"fill": roles["deck_gear"], "weight": 0.0})
		_dome(g, ink, fo, V, f.c, roles["hull_shaded"])
		A.stroke_o(g, ink, fo, 1.0)
		var mouth := A._path(pn, _ell(f.c.x, f.c.y, f.rx * 0.58, f.ry * 0.66, 16), {"fill": Color(ink.ink.r, ink.ink.g, ink.ink.b, 0.5), "weight": 0.7})
		var dd := V.tv(Vector2(1.0, 1.0)) / sqrt(2.0)
		_hatch_inside(g, ink, mouth, dd, 1.1, 0.7, 0.55)
	if p.mast:
		var mc: Dictionary = G.mast
		A._line(pn, PackedVector2Array([Vector2(-mc.yard / 2.0, mc.c.y), Vector2(mc.yard / 2.0, mc.c.y)]), {"weight": 0.75, "alpha": 0.9})
		A._path(pn, A.circ(mc.c, mc.r, 10), {"fill": roles["deck_gear"], "weight": 0.8})
	for m: Dictionary in G.mounts:
		if (m.a as float) > 0.0:
			_gun_mount(pn, g, ink, V, roles, m)

static func _draw_supply(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary, accent: Color) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var detail: int = p.detail
	var hull_o := A._path(pn, G.hull, {"fill": roles["hull_supply"], "weight": 0.0})
	if ppm > 2.6:
		_planks(g, ink, V.tps(G.deck), V, A._rng(pn), 2.3)
	A._path(pn, G.deck, {"weight": 0.6, "alpha": 0.55, "breaks": 0.15})
	A.edge_hatch(g, ink, hull_o, minf(5.0, 1.1 * ppm), A._rng(pn))
	if detail >= 2:
		A._path(pn, G.capstan, {"fill": roles["deck_gear"], "weight": 0.7})
		if ppm > 2.2:
			_dots(g, ink, V, G.bollards, maxf(0.5, 0.22 * ppm), 0.7)
	# hatches: coaming, then the tarpaulin in its own tone with battens and (detail 2) ties
	for h: Dictionary in G.hatches:
		var co := A._path(pn, h.coaming, {"fill": roles["hatch_coaming"], "weight": 0.85})
		var tp_o := A._path(pn, h.poly, {"fill": roles["cargo_tarp"], "weight": 0.6})
		A.stipple(g, ink, tp_o, {"rng": A._rng(pn), "density": 4.0, "r": 0.45})
		if ppm > 2.4:
			for b: PackedVector2Array in h.battens:
				A._line(pn, b, {"alpha": 0.55, "weight": 0.5})
		if detail >= 2 and ppm > 3.0:
			for tline: PackedVector2Array in h.ties:
				A._line(pn, tline, {"alpha": 0.45, "weight": 0.5, "breaks": 0.2})
	if str(p.panel) == "tarp" and G.panel.size() > 0:
		A.accent_panel(pn, G.panel, accent)
	# deck cargo
	for cr: PackedVector2Array in G.crates:
		var co2 := A._path(pn, cr, {"fill": roles["cargo_crate"], "weight": 0.85})
		A.edge_hatch(g, ink, co2, minf(3.0, 0.6 * ppm), A._rng(pn))
		if ppm > 3.2:
			var cc := A._cen(cr)
			A._line(pn, PackedVector2Array([cc + Vector2(-0.5, 0.0), cc + Vector2(0.5, 0.0)]), {"alpha": 0.5})
	for bc: PackedVector2Array in G.barrels:
		var bo := A._path(pn, bc, {"fill": roles["cargo_crate"], "weight": 0.7})
		if ppm > 3.0:
			A._path(pn, A.circ(A._cen(bc), 0.26, 8), {"weight": 0.45, "alpha": 0.6})
	for sk: Dictionary in G.stacks:
		var so := A._path(pn, sk.poly, {"fill": roles["cargo_tarp"], "weight": 0.0})
		_dome(g, ink, so, V, sk.c, roles["cargo_tarp_shaded"])
		A.stipple(g, ink, so, {"rng": A._rng(pn), "density": 4.0, "r": 0.45})
		A.stroke_o(g, ink, so, 1.0)
		var sc: Vector2 = sk.c
		A._line(pn, PackedVector2Array([sc + Vector2(-1.2, 0.0), sc + Vector2(1.2, 0.0)]), {"alpha": 0.6, "weight": 0.6})
		if ppm > 3.0:
			A._line(pn, PackedVector2Array([sc + Vector2(-0.6, -0.9), sc + Vector2(0.6, 0.9)]), {"alpha": 0.4, "weight": 0.5})
	A.stroke_o(g, ink, hull_o, 1.2)
	# the house
	var h_o := A._path(pn, G.house, {"fill": roles["house"], "weight": 0.0})
	A.edge_hatch(g, ink, h_o, minf(4.0, 0.9 * ppm), A._rng(pn))
	A.stroke_o(g, ink, h_o, 1.1)
	if ppm > 2.5:
		A._path(pn, G.house_inset, {"weight": 0.5, "alpha": 0.4})
	if str(p.panel) == "roof":
		A.accent_panel(pn, G.panel, accent)
	var w_o := A._path(pn, G.wheel, {"fill": roles["house_roof"], "weight": 0.0})
	A.edge_hatch(g, ink, w_o, minf(4.0, 0.9 * ppm), A._rng(pn))
	A.stroke_o(g, ink, w_o, 1.0)
	A._line(pn, G.wheel_front, {"weight": 0.85, "alpha": 0.9})
	if p.funnel:
		var f: Dictionary = G.funnel
		var fo := A._path(pn, _ell(f.c.x, f.c.y, f.rx, f.ry, 22), {"fill": roles["house"], "weight": 0.0})
		_dome(g, ink, fo, V, f.c, roles["hull_shaded"])
		A.stroke_o(g, ink, fo, 1.0)
		var mouth := A._path(pn, _ell(f.c.x, f.c.y, f.rx * 0.58, f.ry * 0.66, 16), {"fill": Color(ink.ink.r, ink.ink.g, ink.ink.b, 0.5), "weight": 0.7})
		var dd := V.tv(Vector2(1.0, 1.0)) / sqrt(2.0)
		_hatch_inside(g, ink, mouth, dd, 1.1, 0.7, 0.55)
	if p.derrick:
		var d: Dictionary = G.derrick
		A._line(pn, d.boom, {"weight": 1.0, "alpha": 0.95})
		A._line(pn, d.stay, {"weight": 0.5, "alpha": 0.6})
		A._path(pn, A.circ(d.c, d.r, 10), {"fill": roles["deck_gear"], "weight": 0.8})

# A wake line drawn in pieces of falling alpha: full to the first third of its length, then 60 percent, then 30.
static func _faded(pn: A.Pen, ln: PackedVector2Array, alpha: float, weight: float, breaks: float) -> void:
	var n := ln.size()
	var cuts := [0, int(float(n) * 0.4), int(float(n) * 0.7), n - 1]
	var mul := [1.0, 0.6, 0.3]
	for i in 3:
		var a: int = cuts[i]
		var b: int = mini(cuts[i + 1] + 1, n - 1)
		if b - a < 1:
			continue
		A._line(pn, ln.slice(a, b + 1), {"alpha": alpha * float(mul[i]), "weight": weight, "breaks": breaks, "freq": 0.05})

# --- draw: the wake ----------------------------------------------------------------------------------------------

# The wake under the shadow and under the boat. `kind` is one of data wakes: ink_v, foam, wash.
static func draw_wake(g, M: Model, V: A.View, ink: A.Ink, roles: Dictionary, kind: String, seed_value: int) -> void:
	var w: Dictionary = data()["wakes"]
	var p := M.p
	var L: float = p.length
	var wl: float = p.wake_len
	var tan_a := tan(deg_to_rad(float(val(w["spread_deg"]))))
	var rng := Mulberry32.new(seed_value)
	var pn := A.Pen.new(g, V, ink, seed_value)
	match kind:
		"ink_v":
			var rec: Dictionary = w["ink_v"]
			var outer: Array = []
			var inner: Array = []
			for s: float in [1.0, -1.0]:
				var l1 := PackedVector2Array()
				# along the hull from the bow, then out in the V
				for i in 13:
					var t := 0.012 + float(i) / 12.0 * 0.988
					l1.append(Vector2(s * (hb(p, t) + 0.55 + t * 0.12 * L), _y(L, t)))
				var x0: float = abs(l1[l1.size() - 1].x)
				for i in range(1, 11):
					var u := float(i) / 10.0 * wl
					l1.append(Vector2(s * (x0 + u * tan_a), L / 2.0 + u))
				outer.append(l1)
				var l2 := PackedVector2Array()
				for i in 9:
					var t2 := 0.38 + float(i) / 8.0 * 0.62
					l2.append(Vector2(s * (hb(p, t2) + 0.35 + (t2 - 0.38) * 0.1 * L), _y(L, t2)))
				var x1: float = abs(l2[l2.size() - 1].x)
				for i in range(1, 8):
					var u2 := float(i) / 7.0 * wl * 0.62
					l2.append(Vector2(s * (x1 + u2 * tan_a * 0.7), L / 2.0 + u2))
				inner.append(l2)
			for ln: PackedVector2Array in outer:
				_faded(pn, ln, float(rec["line_alpha"]), float(rec["weight"]), 0.14)
			for ln: PackedVector2Array in inner:
				_faded(pn, ln, float(rec["inner_alpha"]), float(rec["weight"]) * 0.9, 0.2)
			A._line(pn, PackedVector2Array([Vector2(0.0, L / 2.0 + 1.0), Vector2(0.0, L / 2.0 + wl * 0.82)]), {"alpha": float(rec["inner_alpha"]), "weight": float(rec["weight"]), "breaks": 0.35, "freq": 0.07})
			# crest ticks across the V: short strokes pointing back toward the boat
			var every: float = float(rec["tick_every_m"])
			g.stroke_color = ink.ink
			g.line_width = 0.5 * ink.lw
			g.global_alpha = float(rec["tick_alpha"])
			g.begin_path()
			for ln: PackedVector2Array in outer:
				var u := 0.0
				var prev := ln[0]
				var acc := every * 0.5
				for i in range(1, ln.size()):
					var q := ln[i]
					var seg := prev.distance_to(q)
					while acc < seg:
						var pos := prev.lerp(q, acc / seg)
						var dirn := (q - prev).normalized()
						var nrm := Vector2(-dirn.y, dirn.x)
						if pos.y > -L / 2.0 + 2.0 and rng.next() > 0.18:
							var s_side := 1.0 if pos.x > 0.0 else -1.0
							var a0 := V.tp(pos)
							var a1 := V.tp(pos + (-dirn * 0.9 + nrm * s_side * 0.6) * 1.0)
							g.move_to(a0.x, a0.y)
							g.line_to(a1.x, a1.y)
						acc += every
					acc -= seg
					prev = q
			g.stroke()
			g.global_alpha = 1.0
		"foam":
			var rec2: Dictionary = w["foam"]
			var area: float = wl * (float(p.beam) + wl * tan_a * 2.0) * 0.5
			var cnt := maxi(40, int(area * V.ppm * V.ppm * float(rec2["dots_per_100px2"]) / 100.0))
			var rr: Array = rec2["radius_px"]
			var foam: Color = roles["wake_foam"]
			var inkdot: Color = roles["wake_dot_ink"]
			g.begin_path()
			var pts: Array = []
			var ink_pts: Array = []
			for i in cnt:
				var u := pow(rng.next(), 1.4) * wl
				var half := hb(p, 1.0) * 0.9 + u * tan_a * 0.62
				var x: float
				if rng.next() < float(rec2["edge_share"]):
					x = (half - rng.next() * (0.7 + u * 0.05)) * (1.0 if rng.next() < 0.5 else -1.0)
				else:
					x = (rng.next() - 0.5) * 2.0 * (hb(p, 1.0) * 0.8 + u * 0.1)
				var pt := Vector2(x, L / 2.0 + u)
				if rng.next() < float(rec2["ink_share"]):
					ink_pts.append(pt)
				else:
					pts.append(pt)
			# bow spray along the hull's first third
			for i in int(L * 1.6):
				var t := rng.next() * 0.42
				var s := 1.0 if rng.next() < 0.5 else -1.0
				var pt2 := Vector2(s * (hb(p, t) + 0.25 + rng.next() * 0.9), _y(L, t))
				if rng.next() < 0.2:
					ink_pts.append(pt2)
				else:
					pts.append(pt2)
			g.fill_color = Color(foam.r, foam.g, foam.b, 1.0)
			g.global_alpha = foam.a
			g.begin_path()
			for b: Vector2 in pts:
				var q := V.tp(b)
				var r: float = float(rr[0]) + rng.next() * (float(rr[1]) - float(rr[0]))
				g.move_to(q.x + r, q.y)
				g.arc(q.x, q.y, r, 0.0, TAU)
			g.fill()
			g.fill_color = ink.ink
			g.global_alpha = inkdot.a
			g.begin_path()
			for b: Vector2 in ink_pts:
				var q := V.tp(b)
				var r2: float = float(rr[0]) + rng.next() * (float(rr[1]) - float(rr[0])) * 0.8
				g.move_to(q.x + r2, q.y)
				g.arc(q.x, q.y, r2, 0.0, TAU)
			g.fill()
			g.global_alpha = 1.0
		"wash":
			var rec3: Dictionary = w["wash"]
			var wash: Color = roles["wake_wash"]
			var layers: int = int(rec3["layers"])
			# layers stacked so the trail is densest at the stern and fades out: each layer is a little shorter than the
			# last, ragged-edged by its own noise, and its alpha is the share that adds up to the role's alpha at the stern
			var a_layer := 1.0 - pow(1.0 - wash.a, 1.0 / float(layers))
			for li in layers:
				var f := 1.0 - float(li) / float(layers) * 0.78
				var len_m := wl * f
				var left := PackedVector2Array()
				var right := PackedVector2Array()
				var n := 30
				for i in n + 1:
					var uu := float(i) / float(n)
					var u := uu * len_m
					var env := 1.0 - smoothstep(0.25, 1.0, uu)
					var base := (hb(p, 1.0) * 0.85 + u * tan_a * 0.42) * pow(env, 0.6)
					var rag := (ValueNoise.vnoise(u * 0.3, 2.2 + float(li) * 3.1, seed_value) - 0.5) * 2.6 * minf(1.0, 0.25 + u / 10.0) * pow(env, 0.6)
					var half := maxf(0.0, base + rag)
					left.append(Vector2(-half, L / 2.0 - 0.6 + u))
					right.append(Vector2(half, L / 2.0 - 0.6 + u))
				var poly := PackedVector2Array()
				poly.append_array(right)
				var lrev := PackedVector2Array(left)
				lrev.reverse()
				poly.append_array(lrev)
				g.begin_path()
				A.add_poly(g, V.tps(poly), true)
				g.fill_color = Color(wash.r, wash.g, wash.b, 1.0)
				g.global_alpha = a_layer
				g.fill()
				g.global_alpha = 1.0
			# bow slivers
			g.fill_color = Color(wash.r, wash.g, wash.b, 1.0)
			g.global_alpha = wash.a * 0.7
			for s: float in [1.0, -1.0]:
				var sl := PackedVector2Array()
				for i in 10:
					var t := 0.02 + float(i) / 9.0 * 0.5
					sl.append(Vector2(s * (hb(p, t) + 0.15), _y(L, t)))
				for i in range(9, -1, -1):
					var t := 0.02 + float(i) / 9.0 * 0.5
					sl.append(Vector2(s * (hb(p, t) + 0.45 + t * 0.02 * L + 0.9 * sin(t / 0.52 * PI)), _y(L, t)))
				g.begin_path()
				A.add_poly(g, V.tps(sl), true)
				g.fill()
			g.global_alpha = 1.0
			# the two outer edges, broken ink
			for s: float in [1.0, -1.0]:
				var el := PackedVector2Array()
				for i in 11:
					var u := float(i) / 10.0 * wl * 0.8
					el.append(Vector2(s * (hb(p, 1.0) * 0.95 + u * tan_a * 0.9), L / 2.0 - 0.6 + u))
				A._line(pn, el, {"alpha": float(rec3["edge_alpha"]), "weight": 0.5, "breaks": 0.3, "freq": 0.06})
