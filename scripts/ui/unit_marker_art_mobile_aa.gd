extends RefCounted

# THE MOBILE ANTI-AIRCRAFT GUN in ink (Track M2U, mission 2, 2026-10-11): a light AA gun on a tracked or half-tracked
# chassis, drawn the way the unit sheet draws its vehicles (reference/mockups/unit_sheet.html genTank / buildTank /
# drawTankGround / drawTankUpper; scripts/ui/unit_marker_art.gd gen_tank / build_tank / draw_tank) and its guns the way the
# anti-aircraft battery's are (unit_marker_art_static.gd gen_aa / draw_aa_upper: a cradle, a shield, barrels drawn RAISED
# and so foreshortened by their elevation). A NEW generator; the sheet has no entry for it, so the seed index continues
# the sheet's UNITS list (data/ui/unit_art_mission2.json mobile_aa.sheet_index, 7).
#
#   var art := UnitMarkerArtMobileAA.art_for(style, accent, ppm)     # what unit_marker_art.gd's one dispatch line calls
#   art.texture    the vehicle, STRAIGHT alpha, nose up (-y), unit centre at art.origin (the marker turns it)
#   art.mask       its footprint (white, straight alpha) for the shadow
#
# THREE LOOKS, the sheet's way of having variants (data/ui/unit_art_mission2.json mobile_aa.looks), judged on the board
# variants/mobile-aa/ (scripts/ui/boards/mobile_aa_board_shot.gd): A a half-track with a quad mount, B a tracked hull with
# an open twin turret, C a light carrier with a ring mount. Which one the game draws is ui.json unit_art.variant.mobile_aa
# when it has it, else the data's default_look (PROPOSED; Alex picks from the board).
#
# THE SHEET'S FRAME: x to starboard, y aft, nose toward -y, metres. A MOBILE unit is baked nose up and the marker
# rotates the sprite and its mask (as the planes and the tank are); the pen works in PIXELS.
# ONE ACCENT ZONE (decision unit-sheet-choices; the style guide's rule): a recognition panel in the side's colour, on the
# cab roof (A), the engine deck (B, as the tank's) or the rear deck (C). Nowhere else on the vehicle.
# COLOUR is a role (ink.fill, ink.rock, ink.slope ... from the palette, and data's roles); material is linework. No hex.
#
# This file preloads unit_marker_art.gd; unit_marker_art.gd reaches it with load() (never a preload: two scripts that
# preload each other hang the run).

const A = preload("res://scripts/ui/unit_marker_art.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkRoles = preload("res://scripts/render/ink_roles.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const SILHOUETTE := "mobile_aa"
const DATA_PATH := "res://data/ui/unit_art_mission2.json"

static var _data: Dictionary = {}
static var _models: Dictionary = {}
static var _roles: Dictionary = {}

# A TRACE of the sub-draws that ran to their end, for the test (test_mission2_units): with `tracing` on, each sub-draw
# appends its name as its LAST statement, so a runtime error that aborts one half-way leaves its name out.
static var tracing: bool = false
static var trace: Array[String] = []

static func _t(what: String) -> void:
	if tracing:
		trace.append(what)

# --- data -------------------------------------------------------------------------------------------

static func data() -> Dictionary:
	if _data.is_empty():
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
		if v is Dictionary:
			_data = v
		else:
			push_error("unit_marker_art_mobile_aa: %s does not parse as a JSON object" % DATA_PATH)
	return _data

static func val(rec: Variant) -> Variant:
	if rec is Dictionary and (rec as Dictionary).has("value"):
		return (rec as Dictionary)["value"]
	return rec

static func looks() -> Array:
	return (data()["mobile_aa"] as Dictionary)["looks"]

static func default_look() -> int:
	return int(val((data()["mobile_aa"] as Dictionary)["default_look"]))

# The look the game draws: ui.json unit_art.variant.mobile_aa when the style has it, else the data's default.
static func look_of(st: RefCounted) -> int:
	var v: Variant = st.lookup("unit_art.variant." + SILHOUETTE)
	if v is float or v is int:
		return clampi(int(v), 0, looks().size() - 1)
	return default_look()

# The height the vehicle's shadow is lifted by, metres: ui.json marker.cast_height_m.mobile_aa (the marker layer reads the same number).
static func cast_height_m(st: RefCounted) -> float:
	var v: Variant = st.lookup("marker.cast_height_m.mobile_aa")
	return float(v) if (v is float or v is int) else 0.0

# The data's colour roles (concrete, roof_shaded ...) resolved against the style's palette.
static func roles(st: RefCounted) -> Dictionary:
	if _roles.is_empty():
		var errs: Array = []
		_roles = InkRoles.resolve_all(st, data()["roles"], errs)
		for e: Variant in errs:
			push_error("unit_marker_art_mobile_aa: " + str(e))
	return _roles

static func _rr(rng: Mulberry32, pair: Variant) -> float:
	var a: Array = pair
	return A._r(rng, float(a[0]), float(a[1]))

# --- the model ------------------------------------------------------------------------------------------

static func model_for(st: RefCounted, look: int = -1) -> A.Model:
	if look < 0:
		look = look_of(st)
	var key := "%s|%d|%d" % [SILHOUETTE, look, st.scene_seed]
	if _models.has(key):
		return _models[key]
	var m := A.Model.new()
	m.silhouette = SILHOUETTE
	m.variant = look
	m.seed = A.unit_seed(st.scene_seed, int(val((data()["mobile_aa"] as Dictionary)["sheet_index"])), look)
	m.p = gen(look, Mulberry32.new(m.seed))
	m.G = build(m.p)
	_models[key] = m
	return m

# genMobileAA(look, rng): every draw in the data's order (the ranges, then the gun count, then the rivets).
static func gen(look: int, rng: Mulberry32) -> Dictionary:
	var L: Dictionary = looks()[look]
	var p := {}
	p.look = look
	p.kind = str(L["id"])
	var ranges: Dictionary = L["ranges"]
	for key: String in ranges:
		p[key] = _rr(rng, ranges[key])
	p.guns = int(A._pick_w(rng, L["guns"]))
	p.rivets = rng.next() < float(L["rivets_chance"])
	p.crates = int(round(float(p.crates)))
	return p

static func build(p: Dictionary) -> Dictionary:
	match str(p.kind):
		"halftrack":
			return _build_halftrack(p)
		"turret":
			return _build_turret(p)
	return _build_carrier(p)

# place(pts, cx, cy, a): rotate by `a`, then move to (cx, cy).
static func place(pts: PackedVector2Array, cx: float, cy: float, a: float) -> PackedVector2Array:
	var c := cos(a)
	var s := sin(a)
	var out := PackedVector2Array()
	for q in pts:
		out.append(Vector2(cx + q.x * c - q.y * s, cy + q.x * s + q.y * c))
	return out

# The barrels of a mount at (cx, cy) pointing along `az` (radians, -PI/2 = forward): thin rectangles raised and so
# FORESHORTENED by cos(elevation) (the battery's rule), each with a hider (a flash hider) at its end; and the barrel lines
# for a cast shadow, with heights.
static func _barrels(G: Dictionary, p: Dictionary, cx: float, cy: float, az: float, start: float, spread: float) -> void:
	var el: float = deg_to_rad(float(p.elev_deg))
	var length: float = float(p.barrel_len) * cos(el)
	var offs: Array = [0.0]
	if int(p.guns) == 2:
		offs = [-spread * 0.5, spread * 0.5]
	elif int(p.guns) == 4:
		offs = [-spread * 1.5, -spread * 0.5, spread * 0.5, spread * 1.5]
	var barrels: Array = []
	var hiders: Array = []
	for o: float in offs:
		barrels.append(place(A.rect_p(start, o - 0.06, start + length, o + 0.06), cx, cy, az))
		hiders.append(place(A.rect_p(start + length - 0.24, o - 0.09, start + length, o + 0.09), cx, cy, az))
	G.barrels = barrels
	G.hiders = hiders

# The cradle and shield of a mount at (cx, cy) facing `az`.
static func _cradle_shield(G: Dictionary, cx: float, cy: float, az: float, shield_r: float) -> void:
	G.cradle = place(A.rrect(0.12, 0.0, 1.2, 0.84, 0.16), cx, cy, az)
	var sh := PackedVector2Array()
	var shi := PackedVector2Array()
	for i in 9:
		var a := -0.95 + 1.9 * float(i) / 8.0
		sh.append(Vector2(cos(a) * shield_r, sin(a) * shield_r))
		shi.append(Vector2(cos(a) * (shield_r - 0.14), sin(a) * (shield_r - 0.14)))
	shi.reverse()
	sh.append_array(shi)
	G.shield = place(sh, cx, cy, az)

static func _tracks(W: float, tw: float, y_mid: float, len: float) -> Array:
	return [A.rrect(W / 2.0 - tw / 2.0, y_mid, tw, len, 0.22), A.rrect(-(W / 2.0 - tw / 2.0), y_mid, tw, len, 0.22)]

static func _guides(W: float, tw: float, y_a: float, y_b: float) -> Array:
	return [PackedVector2Array([Vector2(W / 2.0 - tw / 2.0, y_a), Vector2(W / 2.0 - tw / 2.0, y_b)]),
		PackedVector2Array([Vector2(-(W / 2.0 - tw / 2.0), y_a), Vector2(-(W / 2.0 - tw / 2.0), y_b)])]

# --- look A: the half-track with a quad mount ----------------------------------------------------------

static func _build_halftrack(p: Dictionary) -> Dictionary:
	var G := {}
	var L: float = p.length
	var W: float = p.width
	var tw: float = p.track_w
	var tl: float = p.track_len
	var y0 := -L / 2.0
	var y1 := L / 2.0
	var bw := W - 0.2
	var bon_w := bw * 0.82
	var cab_y0: float = y0 + float(p.bonnet)
	var cab_y1: float = cab_y0 + float(p.cab)
	G.tracks = _tracks(W, tw, y1 - tl / 2.0 - 0.02, tl)
	G.trackGuides = _guides(W, tw, y1 - tl + 0.25, y1 - 0.2)
	var wheels: Array = []
	for sx: float in [1.0, -1.0]:
		wheels.append(A.rrect(sx * (W / 2.0 - float(p.wheel_w) / 2.0), y0 + 1.15, p.wheel_w, p.wheel_len, 0.12))
	G.wheels = wheels
	G.hull = PackedVector2Array([Vector2(-bon_w / 2.0 + 0.2, y0), Vector2(bon_w / 2.0 - 0.2, y0), Vector2(bon_w / 2.0, y0 + 0.25),
		Vector2(bon_w / 2.0, cab_y0), Vector2(bw / 2.0, cab_y0 + 0.12), Vector2(bw / 2.0, y1 - 0.12), Vector2(bw / 2.0 - 0.12, y1),
		Vector2(-bw / 2.0 + 0.12, y1), Vector2(-bw / 2.0, y1 - 0.12), Vector2(-bw / 2.0, cab_y0 + 0.12), Vector2(-bon_w / 2.0, cab_y0),
		Vector2(-bon_w / 2.0, y0 + 0.25)])
	G.bonnetLine = PackedVector2Array([Vector2(0.0, y0 + 0.3), Vector2(0.0, cab_y0 - 0.05)])
	var grille: Array = []
	for k in 3:
		var gx := (float(k) - 1.0) * 0.28
		grille.append(PackedVector2Array([Vector2(gx, y0 + 0.08), Vector2(gx, y0 + 0.4)]))
	G.grille = grille
	G.screen = A.rect_p(-bw * 0.4, cab_y0 + 0.14, bw * 0.4, cab_y0 + 0.52)   # the windscreen: glass
	G.screenLine = PackedVector2Array([Vector2(0.0, cab_y0 + 0.14), Vector2(0.0, cab_y0 + 0.52)])
	G.roof = A.rect_p(-bw * 0.36, cab_y0 + 0.62, bw * 0.36, cab_y1 - 0.22)
	G.panel = A.rect_p(-bw * 0.27, cab_y0 + 0.82, bw * 0.27, cab_y1 - 0.42)   # accent zone: the recognition panel on the cab roof
	G.cabLine = PackedVector2Array([Vector2(-bw / 2.0 + 0.1, cab_y1), Vector2(bw / 2.0 - 0.1, cab_y1)])
	G.bed = A.rect_p(-bw / 2.0 + 0.17, cab_y1 + 0.1, bw / 2.0 - 0.17, y1 - 0.15)
	var my: float = p.mount_y
	var mr: float = p.mount_r
	G.mount = A.circ(Vector2(0.0, my), mr, 28)
	G.mount_r_in = mr * 0.78
	G.mount_c = Vector2(0.0, my)
	var az := -PI / 2.0
	_cradle_shield(G, 0.0, my, az, mr * 1.02)
	_barrels(G, p, 0.0, my, az, 0.45, 0.28)
	G.seats = [A.circ(Vector2(-0.45, my + 0.62), 0.17, 10), A.circ(Vector2(0.45, my + 0.62), 0.17, 10)]
	var crates: Array = []
	for k in int(p.crates):
		var sx := -1.0 if (k % 2) == 1 else 1.0
		crates.append(A.rrect(sx * (bw / 2.0 - 0.5), y1 - 0.6 - float(k / 2) * 0.55, 0.55, 0.42, 0.05))
	G.crates = crates
	var sil: Array = [G.tracks[0], G.tracks[1], G.hull, wheels[0], wheels[1]]
	sil.append_array(G.barrels)
	G.sil = sil
	G.ext = sil.duplicate()
	return G

static func _draw_halftrack(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, rl: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var cream := ink.fill
	var along := V.tv(Vector2(1.0, 0.0))
	_draw_tracks(g, pn, G, V, ink, along)
	for w: PackedVector2Array in G.wheels:   # tyres: the rock fill, tread lines across
		var o := A._path(pn, w, {"fill": ink.rock, "weight": 0.0})
		A.hatch_lines(g, ink, o, V.tv(Vector2(0.0, 1.0)), maxf(1.4, 0.1 * ppm), {"alpha": 0.7, "weight": 0.55, "rng": A._rng(pn), "jit": 0.2})
		A.stroke_o(g, ink, o, 1.0)
	var hull_o := A._path(pn, G.hull, {"fill": cream, "weight": 0.0})
	if ppm > 4.0:
		for gl: PackedVector2Array in G.grille:
			A._line(pn, gl, {"alpha": 0.7, "weight": 0.6})
		A._line(pn, G.bonnetLine, {"alpha": 0.5, "breaks": 0.15})
	var scr := A._path(pn, G.screen, {"fill": ink.glass_lit, "weight": 0.0})
	A.shade_side(g, scr, A._cen(scr), ink.sd, ink.glass_shaded)
	A.stroke_o(g, ink, scr, 0.8)
	if ppm > 5.0:
		A._line(pn, G.screenLine, {"alpha": 0.6, "weight": 0.5})
	A._path(pn, G.roof, {"fill": cream, "weight": 0.7, "alpha": 0.9})
	A.accent_panel(pn, G.panel, accent)
	A._line(pn, G.cabLine, {"alpha": 0.65, "breaks": 0.1})
	var bed_o := A._path(pn, G.bed, {"fill": cream, "weight": 0.8, "alpha": 0.9})
	A.edge_hatch(g, ink, hull_o, minf(4.0, 0.35 * ppm), A._rng(pn))
	A.stroke_o(g, ink, hull_o, 1.2)
	if bool(p.rivets):
		A.rivets(g, ink, V, PackedVector2Array([G.bed[0], G.bed[3]]), A._rng(pn))
		A.rivets(g, ink, V, PackedVector2Array([G.bed[1], G.bed[2]]), A._rng(pn))
	for c: PackedVector2Array in G.crates:
		A._path(pn, c, {"fill": cream, "weight": 0.8})
	_draw_mount(g, pn, G, V, ink, bed_o)
	_t("halftrack")

# --- look B: the tracked hull with an open twin turret -------------------------------------------------

static func _build_turret(p: Dictionary) -> Dictionary:
	var G := {}
	var L: float = p.length
	var W: float = p.width
	var tw: float = p.track_w
	var y0 := -L / 2.0
	var hx := W / 2.0 - tw * 0.86
	var cf := 0.32
	var cy: float = float(p.glacis) * 0.55
	G.tracks = _tracks(W, tw, 0.03, L - 0.1)
	G.trackGuides = _guides(W, tw, -L / 2.0 + 0.25, L / 2.0 - 0.2)
	G.hull = PackedVector2Array([Vector2(-hx + cf, y0), Vector2(hx - cf, y0), Vector2(hx, y0 + cy), Vector2(hx, L / 2.0 - 0.18),
		Vector2(hx - 0.18, L / 2.0), Vector2(-hx + 0.18, L / 2.0), Vector2(-hx, L / 2.0 - 0.18), Vector2(-hx, y0 + cy)])
	G.glacis = PackedVector2Array([Vector2(-hx + cf, y0), Vector2(hx - cf, y0), Vector2(hx, y0 + cy), Vector2(hx, y0 + float(p.glacis)),
		Vector2(-hx, y0 + float(p.glacis)), Vector2(-hx, y0 + cy)])
	G.glacisLine = PackedVector2Array([Vector2(-hx, y0 + float(p.glacis)), Vector2(hx, y0 + float(p.glacis))])
	var dy0: float = L / 2.0 - float(p.deck)
	G.deckLine = PackedVector2Array([Vector2(-hx + 0.1, dy0), Vector2(hx - 0.1, dy0)])
	var gy0 := dy0 + 0.16
	var gy1: float = gy0 + float(p.deck) * 0.36
	G.grilles = [A.rrect((-hx + 0.28 - 0.16) / 2.0, (gy0 + gy1) / 2.0, hx - 0.44, gy1 - gy0, 0.06),
		A.rrect((hx - 0.28 + 0.16) / 2.0, (gy0 + gy1) / 2.0, hx - 0.44, gy1 - gy0, 0.06)]
	G.panel = A.rect_p(-hx * 0.66, gy1 + 0.16, hx * 0.66, L / 2.0 - 0.28)   # accent zone: the engine-deck recognition panel, as the tank's
	G.driver = A.rrect(-hx * 0.45, y0 + float(p.glacis) + 0.36, 0.6, 0.46, 0.12)
	G.exhaust = [A.circ(Vector2(-hx * 0.62, L / 2.0 - 0.14), 0.12, 10), A.circ(Vector2(hx * 0.62, L / 2.0 - 0.14), 0.12, 10)]
	# the open turret: an eight-sided tub with the crew's heads in it
	var tr: float = p.turret_r
	var ty: float = p.turret_y
	var oct := PackedVector2Array()
	var inner := PackedVector2Array()
	for i in 8:
		var a := (float(i) + 0.5) / 8.0 * TAU
		oct.append(Vector2(cos(a) * tr, ty + sin(a) * tr))
		inner.append(Vector2(cos(a) * (tr - float(p.wall)), ty + sin(a) * (tr - float(p.wall))))
	G.turret = oct
	G.floor = inner
	G.tc = Vector2(0.0, ty)
	G.seats = [A.circ(Vector2(-0.38, ty + 0.35), 0.2, 12), A.circ(Vector2(0.38, ty + 0.35), 0.2, 12)]
	G.drums = [A.circ(Vector2(-tr * 0.62, ty - 0.1), 0.2, 12), A.circ(Vector2(tr * 0.62, ty - 0.1), 0.2, 12)]
	var az := -PI / 2.0
	G.cradle = place(A.rrect(0.1, 0.0, 1.0, 0.8, 0.14), 0.0, ty, az)
	G.shield = PackedVector2Array()
	_barrels(G, p, 0.0, ty, az, 0.5, 0.36)
	var stow: Array = []
	for k in int(p.crates):
		var sx := -1.0 if (k % 2) == 1 else 1.0
		stow.append(A.rrect(sx * (W / 2.0 - tw / 2.0), 0.9 if k > 0 else 1.3, tw * 0.84, 0.7, 0.06))
	G.stow = stow
	var sil: Array = [G.tracks[0], G.tracks[1], G.hull, oct]
	sil.append_array(G.barrels)
	G.sil = sil
	G.ext = sil.duplicate()
	return G

static func _draw_turret(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, rl: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var cream := ink.fill
	var along := V.tv(Vector2(1.0, 0.0))
	_draw_tracks(g, pn, G, V, ink, along)
	var hull_o := A._path(pn, G.hull, {"fill": cream, "weight": 0.0})
	var gn := V.tv(Vector2(0.0, -1.0))
	if gn.dot(ink.sd) > 0.2:   # the sloped plate away from the sun
		A._path(pn, G.glacis, {"fill": ink.slope, "weight": 0.0, "clip": hull_o})
	A._line(pn, G.glacisLine, {"alpha": 0.7, "weight": 0.65, "breaks": 0.12})
	A._line(pn, G.deckLine, {"alpha": 0.6, "breaks": 0.15})
	for gr: PackedVector2Array in G.grilles:
		var o := A._path(pn, gr, {"weight": 0.6, "alpha": 0.8})
		A.hatch_lines(g, ink, o, along, maxf(1.5, 0.13 * ppm), {"alpha": 0.55, "weight": 0.5, "rng": A._rng(pn)})
	A._path(pn, G.driver, {"fill": cream, "weight": 0.65})
	for e: PackedVector2Array in G.exhaust:
		A._path(pn, e, {"fill": cream, "weight": 0.6})
	A.edge_hatch(g, ink, hull_o, minf(4.0, 0.4 * ppm), A._rng(pn))
	A.accent_panel(pn, G.panel, accent)
	A.stroke_o(g, ink, hull_o, 1.2)
	for sw: PackedVector2Array in G.stow:
		A._path(pn, sw, {"fill": cream, "weight": 0.85})
	# the tub: walls in the cream, the floor lower (shaded on the side away from the sun), the crew
	var t_o := A._path(pn, G.turret, {"fill": cream, "weight": 0.0})
	A.shade_side(g, t_o, V.tp(G.tc), ink.sd, ink.fill_shaded)
	A.edge_hatch(g, ink, t_o, minf(5.0, float(p.turret_r) * 0.4 * ppm), A._rng(pn))
	A.stroke_o(g, ink, t_o, 1.2)
	var f_o := A._path(pn, G.floor, {"fill": ink.fill_shaded, "weight": 0.0})
	A.shade_side(g, f_o, V.tp(G.tc), -ink.sd, cream)   # the floor is lit on the side the wall casts no shade on
	A.stroke_o(g, ink, f_o, 0.8, 0.9)
	for s: PackedVector2Array in G.seats:
		A._path(pn, s, {"fill": cream, "weight": 0.65})
	for d: PackedVector2Array in G.drums:
		var d_o := A._path(pn, d, {"fill": cream, "weight": 0.7})
		if ppm > 7.0:
			A._path(pn, A.circ(A._cen(d), 0.1, 8), {"weight": 0.45, "alpha": 0.6})
		A.stroke_o(g, ink, d_o, 0.7, 0.9)
	var c_o := A._path(pn, G.cradle, {"fill": cream, "weight": 0.0})
	A.shade_side(g, c_o, V.tp(G.tc), ink.sd, ink.fill_shaded)
	A.stroke_o(g, ink, c_o, 0.9)
	_draw_barrels(g, pn, G, V, ink)
	_t("turret")

# --- look C: the light carrier with a ring mount ----------------------------------------------------------

static func _build_carrier(p: Dictionary) -> Dictionary:
	var G := {}
	var L: float = p.length
	var W: float = p.width
	var tw: float = p.track_w
	var y0 := -L / 2.0
	var y1 := L / 2.0
	var hx := W / 2.0 - tw * 0.86
	var cab_y1: float = y0 + float(p.cab)
	G.tracks = _tracks(W, tw, 0.03, L - 0.1)
	G.trackGuides = _guides(W, tw, y0 + 0.25, y1 - 0.2)
	G.hull = PackedVector2Array([Vector2(-hx + 0.3, y0), Vector2(hx - 0.3, y0), Vector2(hx, y0 + 0.3), Vector2(hx, y1 - 0.15),
		Vector2(hx - 0.15, y1), Vector2(-hx + 0.15, y1), Vector2(-hx, y1 - 0.15), Vector2(-hx, y0 + 0.3)])
	G.screen = A.rect_p(-hx * 0.75, y0 + 0.28, hx * 0.75, y0 + 0.66)
	G.screenLine = PackedVector2Array([Vector2(0.0, y0 + 0.28), Vector2(0.0, y0 + 0.66)])
	G.cab = A.rect_p(-hx * 0.88, y0 + 0.78, hx * 0.88, cab_y1 - 0.12)   # the cab block's roof
	G.cabLine = PackedVector2Array([Vector2(-hx + 0.08, cab_y1), Vector2(hx - 0.08, cab_y1)])
	G.deck = A.rect_p(-hx + 0.16, cab_y1 + 0.12, hx - 0.16, y1 - 0.14)
	var my: float = p.mount_y
	var rr: float = p.ring_r
	var rw: float = p.ring_w
	G.ring_outer = A.circ(Vector2(0.0, my), rr + rw / 2.0, 36)
	G.ring_inner = A.circ(Vector2(0.0, my), rr - rw / 2.0, 36)
	G.ring_c = Vector2(0.0, my)
	G.mount = A.circ(Vector2(0.0, my), p.mount_r, 24)
	G.mount_r_in = float(p.mount_r) * 0.78
	G.mount_c = Vector2(0.0, my)
	var az := -PI / 2.0
	_cradle_shield(G, 0.0, my, az, float(p.mount_r) * 1.05)
	_barrels(G, p, 0.0, my, az, 0.4, 0.26)
	G.seats = [A.circ(Vector2(-0.4, my + 0.15), 0.16, 10)]
	G.panel = A.rect_p(-hx * 0.5, my + rr + rw / 2.0 + 0.2, hx * 0.5, y1 - 0.26)   # accent zone: the recognition strip across the rear deck
	var crates: Array = []
	for k in int(p.crates):
		var sx := -1.0 if (k % 2) == 1 else 1.0
		crates.append(A.rrect(sx * (hx - 0.5), my - 0.2 + float(k / 2) * 0.6, 0.55, 0.45, 0.05))
	G.crates = crates
	var sil: Array = [G.tracks[0], G.tracks[1], G.hull]
	sil.append_array(G.barrels)
	G.sil = sil
	G.ext = sil.duplicate()
	return G

static func _draw_carrier(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, rl: Dictionary) -> void:
	var G := M.G
	var p := M.p
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var cream := ink.fill
	var along := V.tv(Vector2(1.0, 0.0))
	_draw_tracks(g, pn, G, V, ink, along)
	var hull_o := A._path(pn, G.hull, {"fill": cream, "weight": 0.0})
	var scr := A._path(pn, G.screen, {"fill": ink.glass_lit, "weight": 0.0})
	A.shade_side(g, scr, A._cen(scr), ink.sd, ink.glass_shaded)
	A.stroke_o(g, ink, scr, 0.8)
	if ppm > 5.0:
		A._line(pn, G.screenLine, {"alpha": 0.6, "weight": 0.5})
	A._path(pn, G.cab, {"fill": cream, "weight": 0.7, "alpha": 0.9})
	A._line(pn, G.cabLine, {"alpha": 0.65, "breaks": 0.1})
	A._path(pn, G.deck, {"fill": cream, "weight": 0.8, "alpha": 0.9})
	A.accent_panel(pn, G.panel, accent)
	A.edge_hatch(g, ink, hull_o, minf(4.0, 0.35 * ppm), A._rng(pn))
	A.stroke_o(g, ink, hull_o, 1.2)
	for c: PackedVector2Array in G.crates:
		A._path(pn, c, {"fill": cream, "weight": 0.8})
	# the ring: a low armoured wall round the pedestal, shaded on the faces turned from the sun
	var ro := A._path(pn, G.ring_outer, {"fill": cream, "weight": 0.0})
	A.shade_side(g, ro, V.tp(G.ring_c), ink.sd, ink.fill_shaded)
	A.edge_hatch(g, ink, ro, minf(4.0, float(p.ring_w) * 0.9 * ppm), A._rng(pn), 1)
	A.stroke_o(g, ink, ro, 1.0)
	var ri := A._path(pn, G.ring_inner, {"fill": cream, "weight": 0.0})
	A.shade_side(g, ri, V.tp(G.ring_c), -ink.sd, ink.fill_shaded)   # the inside face of the wall is shaded on the side nearer the sun
	A.stroke_o(g, ink, ri, 0.85)
	_draw_mount(g, pn, G, V, ink, PackedVector2Array())
	_t("carrier")

# --- shared drawing ----------------------------------------------------------------------------------------------

static func _draw_tracks(g, pn: A.Pen, G: Dictionary, V: A.View, ink: A.Ink, along: Vector2) -> void:
	var ppm := V.ppm
	for t: PackedVector2Array in G.tracks:
		var o := A._path(pn, t, {"fill": ink.rock, "weight": 0.0})
		A.hatch_lines(g, ink, o, along, maxf(1.5, 0.12 * ppm), {"alpha": 0.72, "weight": 0.6, "rng": A._rng(pn), "jit": 0.25})   # track links
		A.stroke_o(g, ink, o, 1.1)
	if ppm > 6.0:
		for t: PackedVector2Array in G.trackGuides:
			A._line(pn, t, {"alpha": 0.5, "weight": 0.5, "breaks": 0.2})
	_t("tracks")

# The pedestal mount of a half-track and a carrier: the turntable, the gunners' seats, the cradle, the shield and the barrels.
static func _draw_mount(g, pn: A.Pen, G: Dictionary, V: A.View, ink: A.Ink, _bed_o: PackedVector2Array) -> void:
	var ppm := V.ppm
	var cream := ink.fill
	var mc: Vector2 = G.mount_c
	A._path(pn, G.mount, {"fill": cream, "weight": 1.0})
	if ppm > 6.0:
		A._path(pn, A.circ(mc, float(G.mount_r_in), 24), {"weight": 0.55, "alpha": 0.6, "breaks": 0.22})
	for s: PackedVector2Array in G.seats:
		A._path(pn, s, {"fill": cream, "weight": 0.6})
	var c_o := A._path(pn, G.cradle, {"fill": cream, "weight": 0.0})
	A.shade_side(g, c_o, V.tp(mc), ink.sd, ink.fill_shaded)   # shadeDome
	A.stipple(g, ink, c_o, {"rng": A._rng(pn), "density": 1.6, "away": V.tp(mc)})
	A.stroke_o(g, ink, c_o, 1.0)
	if G.shield.size() > 0:
		var s_o := A._path(pn, G.shield, {"fill": cream, "weight": 0.0})
		A.edge_hatch(g, ink, s_o, minf(3.0, 0.25 * ppm), A._rng(pn), 1)
		A.stroke_o(g, ink, s_o, 0.9)
	_draw_barrels(g, pn, G, V, ink)
	_t("mount")

static func _draw_barrels(_g, pn: A.Pen, G: Dictionary, _V: A.View, ink: A.Ink) -> void:
	var cream := ink.fill
	for i in (G.barrels as Array).size():
		A._path(pn, G.barrels[i], {"fill": cream, "weight": 0.8})
		A._path(pn, G.hiders[i], {"fill": cream, "weight": 0.75})
	_t("barrels")

# drawMobileAA: the ground layer and the upper layer onto one canvas.
static func draw(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color, rl: Dictionary) -> void:
	match str(M.p.kind):
		"halftrack":
			_draw_halftrack(g, M, V, ink, accent, rl)
		"turret":
			_draw_turret(g, M, V, ink, accent, rl)
		_:
			_draw_carrier(g, M, V, ink, accent, rl)

# --- the bake and the cache ------------------------------------------------------------------------------------------

static func bake(st: RefCounted, M: A.Model, accent: Color, ppm: float) -> A.Art:
	var margin: float = st.num("unit_art.bake_margin_px")
	var box := A.extent_box(M)
	var size := Vector2i(ceili(box.size.x * ppm + 2.0 * margin), ceili(box.size.y * ppm + 2.0 * margin))
	var V := A.View.new(-box.position.x * ppm + margin, -box.position.y * ppm + margin, ppm, 0.0)
	var ink := A.ink_consts(st)
	var art_canvas = InkCanvas.new(size)
	art_canvas.line_cap = "round"
	draw(art_canvas, M, V, ink, accent, roles(st))
	# The shadow mask: the footprint (tracks, hull, wheels, barrels), unwobbled, filled as one.
	var mask_canvas = InkCanvas.new(size)
	mask_canvas.begin_path()
	for poly: PackedVector2Array in M.G.sil:
		A.add_poly(mask_canvas, V.tps(poly), true)
	mask_canvas.fill_color = Color.WHITE   # a mask, not a drawn colour: the shadow role tints it
	mask_canvas.fill()
	var imgs := InkCanvas.render_all([art_canvas, mask_canvas])
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(V.x, V.y)
	art.size_px = size
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far
	if imgs.size() == 2 and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(A._straight(imgs[1], true))
	return art

# The baked art for the mobile gun in a side's accent at `ppm`, from unit_marker_art.gd's cache or baked now. null headless.
static func art_for(st: RefCounted, accent: Color, ppm: float) -> A.Art:
	var lo: float = st.num("unit_art.min_bake_ppm")
	var hi: float = st.num("unit_art.max_bake_ppm")
	var q := snappedf(clampf(ppm, lo, hi), 0.01)
	var look := look_of(st)
	var key := "%s|%d|%s|%.2f|%s" % [SILHOUETTE, look, accent.to_html(), q, InkCanvas.pen_key()]
	if A._art.has(key):
		var hit: A.Art = A._art[key]
		A._art.erase(key)   # LRU: a hit moves to the back
		A._art[key] = hit
		return hit
	if not A.can_bake():
		return null
	var art := bake(st, model_for(st, look), accent, q)
	A._art[key] = art
	A._trim(int(st.num("unit_art.cache_max")))
	return art
