extends RefCounted

# ONE FRAME of the boats' board (Track BB): boats and planes on the placeholder sea, in the game's own
# order -- the water, the wakes, every shadow merged into one translucent fill at the map's shadow
# strength, the boats, the planes -- onto ONE InkCanvas, rendered to an Image. WINDOWED ONLY.
#
#   var img := BoatFrame.render(style, Vector2i(420, 230), {
#       "ppm": 4.0,                 # px per metre the boats and planes are drawn at (the plane rule)
#       "map_ppm": 2.0,             # px per metre of the MAP at this zoom (the ripples follow it)
#       "wake": "ink_v",
#       "boats": [{"kind": "patrol", "look": "p1", "side": "a", "pos": Vector2(120, 60), "heading": 0.0, "wake": true}],
#       "planes": [{"type": "light_fighter", "side": "a", "pos": Vector2(340, 60), "heading": 0.0, "alt_m": 400.0}],
#       "seed": 1})
#
# heading is the game's: 0 points along +x (east), clockwise positive on screen. The art is drawn with
# the View turned by heading + 90 degrees (the models point their bow/nose toward -y), so the light on
# every drawn thing is the map's at any heading.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkRoles = preload("res://scripts/render/ink_roles.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const Water = preload("res://scripts/render/water_placeholder.gd")

static var _roles_cache: Dictionary = {}
static var _wb := false      # the sea is Track WB's proposed default water (data/world/water.json), read; else the placeholder

static func roles(st: RefCounted) -> Dictionary:
	if _roles_cache.is_empty():
		var errs: Array = []
		_roles_cache = InkRoles.resolve_all(st, BoatArt.data()["roles"], errs)
		for e: Variant in errs:
			push_error("boat_frame: " + str(e))
		_wb = Water.adopt_wb(st, _roles_cache)
	return _roles_cache

static func render(st: RefCounted, size: Vector2i, o: Dictionary) -> Image:
	var rl: Dictionary = roles(st).duplicate()
	if o.has("water"):
		rl["water_placeholder"] = o["water"]
	var ink := A.ink_consts(st)
	var ppm: float = o["ppm"]
	var g := InkCanvas.new(size)
	g.line_cap = "round"
	var seed_value: int = int(o.get("seed", 1))
	Water.sea(g, Rect2(Vector2.ZERO, Vector2(size)), float(o["map_ppm"]), rl, ink.lw, seed_value)
	var boats: Array = o.get("boats", [])
	var planes: Array = o.get("planes", [])
	var models: Array = []
	for b: Dictionary in boats:
		var m := BoatArt.model(st, str(b["kind"]), str(b["look"]))
		var v := A.View.new((b["pos"] as Vector2).x, (b["pos"] as Vector2).y, float(b.get("ppm", ppm)), float(b.get("heading", 0.0)) + PI / 2.0)
		models.append([m, v, b])
	# wakes first: the shadow and the boat fall on them
	for e: Array in models:
		var b: Dictionary = e[2]
		if bool(b.get("wake", true)) and str(o.get("wake", "ink_v")) != "none":
			BoatArt.draw_wake(g, e[0], e[1], ink, rl, str(o.get("wake", "ink_v")), seed_value + int((b["pos"] as Vector2).x) * 7 + int((b["pos"] as Vector2).y))
	# every shadow, one translucent fill
	var polys: Array = []
	for e: Array in models:
		var kb: Vector2 = st.shadow_dir() * st.sun_len() * float((e[1] as A.View).ppm)
		polys.append_array(BoatArt.shadow_polys(e[0], e[1], kb))
	var pmods: Array = []
	for pl: Dictionary in planes:
		var pm := A.model_for(st, str(pl["type"]))
		var pp: float = float(pl.get("ppm", ppm))
		var pv := A.View.new((pl["pos"] as Vector2).x, (pl["pos"] as Vector2).y, pp, float(pl.get("heading", 0.0)) + PI / 2.0)
		pmods.append([pm, pv, pl])
		var off: Vector2 = st.plane_shadow_offset_m(float(pl.get("alt_m", 400.0))) * pp
		for poly: PackedVector2Array in pm.G.sil:
			polys.append(BoatArt.shift_px(pv.tps(poly), off))
	if polys.size() > 0:
		g.begin_path()
		for poly: PackedVector2Array in polys:
			A.add_poly(g, poly, true)
		var sc: Color = rl["shadow"]
		g.fill_color = Color(sc.r, sc.g, sc.b, 1.0)
		g.global_alpha = sc.a
		g.fill()
		g.global_alpha = 1.0
	for e: Array in models:
		var b: Dictionary = e[2]
		BoatArt.draw_boat(g, e[0], e[1], ink, rl, rl["side_" + str(b["side"])])
	for e: Array in pmods:
		var pl: Dictionary = e[2]
		A.draw_plane(g, e[0], e[1], ink, rl["side_" + str(pl["side"])])
	var imgs := InkCanvas.render_all([g])
	return imgs[0]
