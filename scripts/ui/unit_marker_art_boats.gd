extends RefCounted

# THE BOATS AND THE BRIDGE IN THE GAME (Track BB, 2026-10-11): the patrol boat, the supply boat and the bridge drawn by the generators the
# boards were made with (scripts/render/boat_art.gd, bridge_art.gd; data/world/boats.json, bridges.json), baked ONCE into textures the
# way the planes, the cruiser and the military complex are, in place of the stand-in arrow. unit_marker_art.gd reaches this file with load()
# (never a preload: this file preloads that one) from its one dispatch line in art_for.
#
#   var art := UnitMarkerArtBoats.art_for(style, "patrol_boat", accent, ppm, rot)   # what the dispatch line calls
#   var ruin := UnitMarkerArtBoats.ruin_art(style, "bridge", ppm, rot)             # a destroyed one, for the effects layer
#
# ALEX'S CHOICES (data/decisions/decisions.json): the patrol boat is P1, the Cutter, the supply boat S2, the Barge with deck cargo
# (boat-looks); the wake is the ink V (boat-wake); the stone arch with a flat deck (bridge-look); boats at the planes' scale and the river
# 26 m at the road (water-layer); a bridge that takes a lot to shoot down (bridge-durability). EVERYTHING ELSE HERE IS PROPOSED by Track BB.
#
# THE BOATS (silhouettes patrol_boat, supply_boat) follow the cruiser's pattern (unit_marker_art_ship.gd): baked NOSE UP and turned by the
# marker like a plane, at the planes' scale (the same pixels per metre as a plane at every zoom, the marker rule), one accent zone (a painted
# recognition panel), and a WAKE on a texture of its own, shown only while the boat is under way. The shadow is the one place it goes further:
# the sheet's castShadows rule throws each part's footprint by ITS height, and a nose-up sprite cannot carry a shadow that falls the same way
# on the screen at every heading, so the parts are sorted by height into three masks (the hull and the low gear, the house and the funnel, the
# mast and the derrick) and the marker draws each as STEPPED COPIES of itself at heights between its base and its top, the prototype's own way
# of throwing a prop's shadow (Art.shadow_parts; the layer's cast rule lifts each copy). So the cutter's house and mast throw their long
# shadows and the hull its short one, at every heading. The lighting inside the art turns with the sprite, as the planes' does (documented).
#
# THE BRIDGE (silhouette bridge) is MAP SCENERY and a MARKER: drawn at the MAP's scale, not the planes' (the marker's `map_scale` makes its
# drawn scale exactly the map's, so the Art's ppm is the map's px per metre), baked ALREADY TURNED by its heading like the tower
# (Art.screen_aligned), its mask the CAST SHADOW (the roadway's slab, the piers, the wing walls), the road's ruts run across the deck. A static
# unit, so it is in sight like the tower and its marker goes at its down event; its RUIN (the middle arch gone, blocks in the river) is the
# effects layer's, kind "bridge" (scripts/fx/fx_layer.gd). Why a marker and not baked into the map: data/world/bridges.json game.marker_not_map.
#
# A DESTROYED BOAT is not drawn here at all: it SINKS (Alex, decision ship-sinks). The sim lowers its height below 0 m to the water's floor
# (World._fall_step) and the marker draws this same intact art under the water layer's own depth wash (scripts/ui/unit_sunk.gd).
#
# COLOUR is a ROLE (data/world/boats.json and bridges.json roles); material is linework. No hex.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const BridgeArt = preload("res://scripts/render/bridge_art.gd")
const BoatFrame = preload("res://scripts/render/boat_frame.gd")
const BridgeFrame = preload("res://scripts/render/bridge_frame.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

const WATER_PATH := "res://data/world/water.json"
const WAKE_SEED := 7919

const BOATS := {"patrol_boat": "patrol", "supply_boat": "supply"}
const BRIDGE := "bridge"

static func is_boat(silhouette: String) -> bool:
	return BOATS.has(silhouette)

static func is_bridge(silhouette: String) -> bool:
	return silhouette == BRIDGE

# Whether a destroyed unit of this kind is drawn by ruin_art (the effects layer asks): the bridge's ruin. A boat has none: it sinks (below).
static func has_ruin(kind: String) -> bool:
	return kind == BRIDGE

# Drawn at the MAP's scale by the marker (k = 1), not the planes'.
static func is_map_scale(silhouette: String) -> bool:
	return silhouette == BRIDGE

# --- data ---------------------------------------------------------------------------------------------------------

static func _game(file: String) -> Dictionary:
	return (BoatArt.data() if file == "boats" else BridgeArt.data())["game"]

static func val(rec: Variant) -> Variant:
	return BoatArt.val(rec)

# The look the game draws for a boat kind ("patrol" / "supply"): data boats.json game.looks (Alex's boat-looks).
static func look_of(kind: String) -> String:
	return str((_game("boats")["looks"] as Dictionary)[kind])

# The share of a destroyed unit's size_m its flash (and the bridge's smoke) are sized by (fx_field and combat_feed ask): the bridge's own, and a
# sinking boat's down flash (data/world/boats.json game.sunk.effects_size_frac, proposed).
static func effects_frac(kind: String) -> float:
	if kind == BRIDGE:
		return float(val(_game("bridges")["effects_size_frac"]))
	if BOATS.has(kind):
		return float(val((_game("boats")["sunk"] as Dictionary)["effects_size_frac"]))
	return 1.0

# The river's width at the road, metres: data/world/water.json river.shape.crossing_half_width_m x 2 (Alex: 26 m), else the bridge data's.
static func river_width_m() -> float:
	if FileAccess.file_exists(WATER_PATH):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(WATER_PATH))
		if v is Dictionary:
			var shape: Variant = (((v as Dictionary).get("river", {}) as Dictionary).get("shape", {}) as Dictionary).get("crossing_half_width_m")
			if shape != null:
				return 2.0 * float(val(shape))
	return float(val(_game("bridges")["river_w_fallback_m"]))

static func _q(st: RefCounted, ppm: float) -> float:
	return snappedf(clampf(ppm, float(st.num("unit_art.min_bake_ppm")), float(st.num("unit_art.max_bake_ppm"))), 0.01)

static func _cached(key: String) -> A.Art:
	if A._art.has(key):
		var hit: A.Art = A._art[key]
		A._art.erase(key)   # LRU: a hit moves to the back
		A._art[key] = hit
		return hit
	return null

static func _put(st: RefCounted, key: String, art: A.Art) -> void:
	A._art[key] = art
	A._trim(int(st.num("unit_art.cache_max")))

# --- the dispatch ---------------------------------------------------------------------------------------------------

# The standing art of a silhouette in a side's accent at `ppm` (the marker's want), from the cache or baked now. `rot` is the marker's
# sprite angle (heading + 90 degrees): only the bridge, baked already turned, uses it.
static func art_for(st: RefCounted, silhouette: String, accent: Color, ppm: float, rot: float = 0.0) -> A.Art:
	var q := _q(st, ppm)
	if is_bridge(silhouette):
		rot = wrapf(rot, -PI, PI)
		var key := "bridge|%.2f|%s|%.3f" % [q, InkCanvas.pen_key(), snappedf(rot, 0.005)]
		var hit := _cached(key)
		if hit != null:
			return hit
		if not A.can_bake():
			return null
		var art := _bake_bridge(st, q, rot, false)
		_put(st, key, art)
		return art
	if not is_boat(silhouette):
		return null
	var key2 := "%s|%s|%.2f|%s" % [silhouette, accent.to_html(), q, InkCanvas.pen_key()]
	var hit2 := _cached(key2)
	if hit2 != null:
		return hit2
	if not A.can_bake():
		return null
	var art2 := _bake_boat(st, silhouette, accent, q)
	_put(st, key2, art2)
	return art2

# The destroyed art of a kind (the bridge's ruin), baked already turned by `rot` (the sprite angle), for the effects layer.
static func ruin_art(st: RefCounted, kind: String, ppm: float, rot: float = 0.0) -> A.Art:
	var q := _q(st, ppm)
	rot = wrapf(rot, -PI, PI)
	var key := "%s|ruin|%.2f|%s|%.3f" % [kind, q, InkCanvas.pen_key(), snappedf(rot, 0.005)]
	var hit := _cached(key)
	if hit != null:
		return hit
	if not A.can_bake():
		return null
	var art: A.Art = null
	if is_bridge(kind):
		art = _bake_bridge(st, q, rot, true)
	if art != null:
		_put(st, key, art)
	return art

# --- shared pieces ----------------------------------------------------------------------------------------------------

static func _ext_box(polys: Array) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for poly: PackedVector2Array in polys:
		for q in poly:
			lo = lo.min(q)
			hi = hi.max(q)
	return Rect2(lo, hi - lo)

static func _fill_mask(canvas, polys: Array) -> void:
	canvas.begin_path()
	for poly: PackedVector2Array in polys:
		if poly.size() >= 3:
			A.add_poly(canvas, poly, true)
	canvas.fill_color = Color.WHITE   # a mask, not a drawn colour: the shadow role tints it
	canvas.fill()

# --- the boats ----------------------------------------------------------------------------------------------------------

# The wake's box in the boat's frame, metres (the cruiser's rule): from the bow to `wake_len` aft of the stern, as wide as the V gets.
static func wake_box(p: Dictionary, wake_len: float, spread_deg: float) -> Rect2:
	var half: float = float(p.beam) / 2.0 + 0.55 + 0.12 * float(p.length) + wake_len * tan(deg_to_rad(spread_deg)) + 1.5
	return Rect2(Vector2(-half, -float(p.length) / 2.0 - 1.0), Vector2(2.0 * half, float(p.length) + wake_len + 3.0))

# One cast entry of the model as the footprint polygons it shades, in px, with its base and top heights (metres above the water).
static func _cast_parts(M: BoatArt.Model, V: A.View) -> Array:
	var out: Array = []
	for c: Dictionary in M.G.casts:
		match str(c["kind"]):
			"prism":
				var polys: Array = []
				for poly: PackedVector2Array in c["polys"]:
					polys.append(V.tps(poly))
				out.append({"polys": polys, "b": float(c["b"]), "h": float(c["h"])})
			"line":
				for ln: PackedVector3Array in c["lines"]:
					var a := V.tp(Vector2(ln[0].x, ln[0].y))
					var b := V.tp(Vector2(ln[1].x, ln[1].y))
					var d := b - a
					if d.length() < 0.001:
						d = Vector2(1.0, 0.0)
					var w := maxf(float(c["w"]) * V.ppm, float(c["min_px"]))
					var nrm := Vector2(-d.y, d.x).normalized() * w * 0.5
					out.append({"polys": [PackedVector2Array([a + nrm, b + nrm, b - nrm, a - nrm])], "b": minf(ln[0].z, ln[1].z), "h": maxf(ln[0].z, ln[1].z)})
	return out

static func _bake_boat(st: RefCounted, silhouette: String, accent: Color, ppm: float) -> A.Art:
	var kind: String = BOATS[silhouette]
	var M := BoatArt.model(st, kind, look_of(kind))
	var margin: float = st.num("unit_art.bake_margin_px")
	var box := _ext_box(M.G.ext)
	var size := Vector2i(ceili(box.size.x * ppm + 2.0 * margin), ceili(box.size.y * ppm + 2.0 * margin))
	var V := A.View.new(-box.position.x * ppm + margin, -box.position.y * ppm + margin, ppm, 0.0)
	var ink := A.ink_consts(st)
	var rl := BoatFrame.roles(st)
	var art_canvas = InkCanvas.new(size)
	art_canvas.line_cap = "round"
	BoatArt.draw_boat(art_canvas, M, V, ink, rl, accent)
	# the shadow's three masks, by height
	var fb: float = M.p.freeboard
	var sh: Dictionary = _game("boats")["shadow"]
	var top_low: float = fb + float(val(sh["hull_class_top_above_freeboard_m"]))
	var top_mid: float = fb + float(val(sh["works_class_top_above_freeboard_m"]))
	var copies: Array = val(sh["copies"])
	var classes: Array = [{"polys": [], "b": 1e9, "h": 0.0}, {"polys": [], "b": 1e9, "h": 0.0}, {"polys": [], "b": 1e9, "h": 0.0}]
	for part: Dictionary in _cast_parts(M, V):
		var ci := 0 if float(part["h"]) <= top_low else (1 if float(part["h"]) <= top_mid else 2)
		var cl: Dictionary = classes[ci]
		(cl["polys"] as Array).append_array(part["polys"])
		cl["b"] = minf(float(cl["b"]), float(part["b"]))
		cl["h"] = maxf(float(cl["h"]), float(part["h"]))
	var canvases: Array = [art_canvas]
	var used: Array = []
	for ci in 3:
		var cl: Dictionary = classes[ci]
		if (cl["polys"] as Array).is_empty():
			continue
		var mc = InkCanvas.new(size)
		_fill_mask(mc, cl["polys"])
		canvases.append(mc)
		used.append(ci)
	# the wake, on a canvas of its own: under the shadow and the boat, shown only while the boat is under way
	var wl: float = M.p.wake_len
	var wake_kind: String = str(val(_game("boats")["wake"]))
	var wbox := wake_box(M.p, wl, float(val(BoatArt.data()["wakes"]["spread_deg"])))
	var wsize := Vector2i(ceili(wbox.size.x * ppm + 2.0 * margin), ceili(wbox.size.y * ppm + 2.0 * margin))
	var WV := A.View.new(-wbox.position.x * ppm + margin, -wbox.position.y * ppm + margin, ppm, 0.0)
	var wake_canvas = InkCanvas.new(wsize)
	wake_canvas.line_cap = "round"
	if wake_kind != "none":
		BoatArt.draw_wake(wake_canvas, M, WV, ink, rl, wake_kind, M.seed + WAKE_SEED)
	canvases.append(wake_canvas)
	var imgs: Array = InkCanvas.render_all(canvases)
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(V.x, V.y)
	art.size_px = size
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far
	if imgs.is_empty() or imgs[0] == null or imgs[0].is_empty():
		return art
	art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
	# the LOW mask is the marker's own shadow (lifted by cast_height_m); the others are its extra copies
	var parts: Array = []
	for k in used.size():
		var ci: int = used[k]
		var cl: Dictionary = classes[ci]
		var tex := ImageTexture.create_from_image(A._straight(imgs[1 + k], true))
		var n := int(copies[ci])
		var heights: Array = []
		var b: float = float(cl["b"]) if ci > 0 else 0.0
		for i in n:
			heights.append(lerpf(b, float(cl["h"]), float(i + 1) / float(n)))
		if ci == 0:
			art.mask = tex
			art.cast_height_m = float(heights[n - 1])
			heights.remove_at(n - 1)   # the marker's own shadow is the top copy
		parts.append({"tex": tex, "heights": heights})
	art.shadow_parts = parts
	if wake_kind != "none" and imgs[imgs.size() - 1] != null and not imgs[imgs.size() - 1].is_empty():
		art.wake = ImageTexture.create_from_image(A._straight(imgs[imgs.size() - 1], false))
		art.wake_origin = Vector2(WV.x, WV.y)
	return art

# --- the bridge ------------------------------------------------------------------------------------------------------------------

static func bridge_model(st: RefCounted, ruin: bool) -> BridgeArt.Model:
	return BridgeArt.model(st, str(val(_game("bridges")["kind"])), ruin, river_width_m())

# Every footprint the bridge draws, in the bridge's frame (metres), for the texture's box.
static func _bridge_polys(M: BridgeArt.Model) -> Array:
	var out: Array = []
	for key: String in ["deck", "parapets", "wings", "abutments", "chords", "caps"]:
		if M.G.has(key):
			for poly: Variant in M.G[key]:
				if poly is PackedVector2Array:
					out.append(poly)
	if M.G.has("piers"):
		for pr: Dictionary in M.G["piers"]:
			out.append(pr["poly"])
	if M.G.has("rubble"):
		for r: Dictionary in M.G["rubble"]:
			out.append(r["poly"])
	return out

# The bridge (or its ruin) baked at the MAP's scale `ppm`, already turned: its x axis along the road's heading (the sprite angle rot - 90 degrees).
static func _bake_bridge(st: RefCounted, ppm: float, rot: float, ruin: bool) -> A.Art:
	var M := bridge_model(st, ruin)
	var margin: float = st.num("unit_art.bake_margin_px")
	var vrot := rot - PI / 2.0
	var ink := A.ink_consts(st)
	var rl := BridgeFrame.roles(st)
	var k: Vector2 = st.shadow_dir() * st.sun_len() * ppm
	var v0 := A.View.new(0.0, 0.0, ppm, vrot)
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for poly: PackedVector2Array in _bridge_polys(M):
		for q in v0.tps(poly):
			lo = lo.min(q)
			hi = hi.max(q)
	var sh_polys: Array = BridgeArt.shadow_polys(M, v0, k)
	for poly: PackedVector2Array in sh_polys:
		for q in poly:
			lo = lo.min(q)
			hi = hi.max(q)
	for ln: PackedVector2Array in BridgeArt.water_marks(M):
		for q in v0.tps(ln):
			lo = lo.min(q)
			hi = hi.max(q)
	var size := Vector2i(ceili(hi.x - lo.x + 2.0 * margin), ceili(hi.y - lo.y + 2.0 * margin))
	var V := A.View.new(-lo.x + margin, -lo.y + margin, ppm, vrot)
	var canvas = InkCanvas.new(size)
	canvas.line_cap = "round"
	# the ink lines that say a thing stands in the water, under the bridge
	var wm: Dictionary = BridgeArt.data()["ripples"]
	canvas.stroke_color = ink.ink
	canvas.line_width = float(wm["weight"]) * ink.lw
	canvas.global_alpha = float(wm["alpha"])
	for ln: PackedVector2Array in BridgeArt.water_marks(M):
		canvas.begin_path()
		A.add_poly(canvas, V.tps(ln), false)
		canvas.stroke()
	canvas.global_alpha = 1.0
	BridgeArt.draw_bridge(canvas, M, V, ink, rl)
	# the cast shadow, in the same frame, as the mask
	var mask = InkCanvas.new(size)
	var mpolys: Array = []
	for poly: PackedVector2Array in BridgeArt.shadow_polys(M, V, k):
		mpolys.append(poly)
	_fill_mask(mask, mpolys)
	var imgs: Array = InkCanvas.render_all([canvas, mask])
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(V.x, V.y)
	art.size_px = size
	art.screen_aligned = true
	art.rot = rot
	var far := 0.0
	for poly: PackedVector2Array in _bridge_polys(M):
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far   # the marker draws it at k = 1 (map_scale): its own metres are the map's
	if imgs.size() == 2 and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(A._straight(imgs[1], true))
	return art
