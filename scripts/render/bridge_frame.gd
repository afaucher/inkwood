extends RefCounted

# ONE FRAME of the bridges' board (Track BB): a bridge (or its ruin) over a river between two banks, the
# village road running onto it from both sides, in the game's own order -- the water, the ink lines that say
# a thing stands in it, the banks, the road, every shadow merged into one translucent fill at the map's
# shadow strength, the bridge -- onto ONE InkCanvas, rendered to an Image. WINDOWED ONLY.
#
#   var img := BridgeFrame.render(style, Vector2i(300, 210), {"zoom": 1.0, "kind": "arch", "ruin": false, "seed": 1})
#
# The scale is the MAP's (a bridge is scenery, like a house): px per metre = the map's px per metre x zoom.
# The road runs west to east along x, the river north to south along y, the sun is the map's (NW), so the
# shadow falls to the south-east: onto the water on the downstream side of the roadway and across the east
# bank. The water, the banks and the bank's hachures are PLACEHOLDERS (Track WB's board, variants/water/,
# decides the water); the bridge, its shadow and the road are the proposal.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkRoles = preload("res://scripts/render/ink_roles.gd")
const BridgeArt = preload("res://scripts/render/bridge_art.gd")
const Water = preload("res://scripts/render/water_placeholder.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

static var _roles_cache: Dictionary = {}
static var _wb := false      # the river is Track WB's proposed default water (data/world/water.json), read: shallows with a shelf channel

static func roles(st: RefCounted) -> Dictionary:
	if _roles_cache.is_empty():
		var errs: Array = []
		_roles_cache = InkRoles.resolve_all(st, BridgeArt.data()["roles"], errs)
		for e: Variant in errs:
			push_error("bridge_frame: " + str(e))
		_wb = Water.adopt_wb(st, _roles_cache)
		if _wb:
			_roles_cache["water_placeholder"] = _roles_cache["water_shallows"]
			var sh: Color = _roles_cache["water_shelf"]
			_roles_cache["submerged"] = Color(sh.r, sh.g, sh.b, 0.5)
	return _roles_cache

static func map_ppm() -> float:
	return float(BridgeArt.val(BridgeArt.data()["road_px_per_m"]))

# The shore: x of the bank's edge at y (metres), straight under the bridge and wobbling away from it.
static func shore_x(river_w: float, side: float, y: float, seed_value: int) -> float:
	var k := smoothstep(10.0, 30.0, absf(y))
	var wob := (ValueNoise.vnoise(y * 0.07, 3.1 + side, seed_value) - 0.5) * 7.0 * k
	return side * (river_w / 2.0 + wob)

static func land_poly(river_w: float, side: float, half_w: float, half_h: float, seed_value: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var y := -half_h
	while y <= half_h + 0.01:
		pts.append(Vector2(shore_x(river_w, side, y, seed_value), y))
		y += 2.0
	pts.append(Vector2(side * half_w, half_h))
	pts.append(Vector2(side * half_w, -half_h))
	return pts

static func render(st: RefCounted, size: Vector2i, o: Dictionary) -> Image:
	var rl := roles(st)
	var ink := A.ink_consts(st)
	var zoom: float = float(o["zoom"])
	var ppm := map_ppm() * zoom
	var seed_value: int = int(o.get("seed", 1))
	var M := BridgeArt.model(st, str(o["kind"]), bool(o.get("ruin", false)), float(o.get("river_w", -1.0)))
	var half_w := float(size.x) / ppm / 2.0 + 4.0
	var half_h := float(size.y) / ppm / 2.0 + 4.0
	var origin := Vector2(float(size.x), float(size.y)) / 2.0
	var V := A.View.new(origin.x, origin.y, ppm, 0.0)
	var g := InkCanvas.new(size)
	g.line_cap = "round"
	var W: float = M.p.river_w
	# the water, the marks that say a thing stands in it
	Water.sea(g, Rect2(Vector2.ZERO, Vector2(size)), ppm, rl, ink.lw, seed_value)
	if _wb:
		# Track WB's default river: the shallows along the banks, the shelf down the middle (a parabolic section), a thin ink line at the step
		var chan := PackedVector2Array()
		var chan_l := PackedVector2Array()
		var yy := -half_h
		while yy <= half_h + 0.01:
			chan.append(Vector2(shore_x(W, 1.0, yy, seed_value) * 0.42, yy))
			chan_l.append(Vector2(shore_x(W, -1.0, yy, seed_value) * 0.42, yy))
			yy += 2.0
		chan_l.reverse()
		chan.append_array(chan_l)
		var chan_px := V.tps(chan)
		g.begin_path()
		A.add_poly(g, chan_px, true)
		g.fill_color = rl["water_shelf"]
		g.fill()
		g.stroke_color = ink.ink
		g.line_width = 0.5 * ink.lw
		g.global_alpha = 0.35
		g.begin_path()
		A.add_poly(g, chan_px, true)
		g.stroke()
		g.global_alpha = 1.0
	var wm: Dictionary = BridgeArt.data()["ripples"]
	g.stroke_color = ink.ink
	g.line_cap = "round"
	g.line_width = float(wm["weight"]) * ink.lw
	g.global_alpha = float(wm["alpha"])
	for ln: PackedVector2Array in BridgeArt.water_marks(M):
		g.begin_path()
		A.add_poly(g, V.tps(ln), false)
		g.stroke()
	g.global_alpha = 1.0
	# the banks
	var banks: Array = []
	for side: float in [-1.0, 1.0]:
		var poly := land_poly(W, side, half_w, half_h, seed_value)
		banks.append(poly)
		var px := V.tps(poly)
		g.begin_path()
		A.add_poly(g, px, true)
		g.fill_color = rl["land_placeholder"]
		g.fill()
		# a few specks of dirt on the paper: a placeholder for the ground
		g.fill_color = ink.dirt
		var cnt := int(float(size.x * size.y) * 0.006)
		for i in cnt:
			var x := ValueNoise.hash2(i, 5, seed_value + int(side) * 17) * float(size.x)
			var y := ValueNoise.hash2(i, 9, seed_value + int(side) * 17) * float(size.y)
			if Geometry2D.is_point_in_polygon(Vector2(x, y), px):
				g.global_alpha = 0.12 + ValueNoise.hash2(i, 13, seed_value) * 0.22
				g.fill_rect(x, y, 0.9, 0.9)
		g.global_alpha = 1.0
		# the shore line and the hachures inward from where the bank faces away from the sun
		var shore := PackedVector2Array()
		var y2 := -half_h
		while y2 <= half_h + 0.01:
			shore.append(Vector2(shore_x(W, side, y2, seed_value), y2))
			y2 += 2.0
		g.stroke_color = ink.ink
		g.line_width = 1.1 * ink.lw
		g.global_alpha = 0.9
		g.begin_path()
		A.add_poly(g, V.tps(shore), false)
		g.stroke()
		if side < 0.0:
			g.line_width = 0.5 * ink.lw
			g.global_alpha = 0.5
			g.begin_path()
			for i in range(0, shore.size(), 1):
				var q := shore[i]
				var a := V.tp(q)
				var b := V.tp(q + Vector2(-1.6 - 1.0 * ValueNoise.hash2(i, 3, seed_value), 0.0))
				if i % 2 == 0:
					g.move_to(a.x, a.y)
					g.line_to(b.x, b.y)
			g.stroke()
		g.global_alpha = 1.0
	# the road onto the bridge from both sides
	var L: float = M.p.len
	BridgeArt.draw_road(g, V, ink, rl, [Vector2(-half_w, -L / 2.0 - 1.0), Vector2(L / 2.0 + 1.0, half_w)], seed_value + 3, true, [], 1.0)
	# every shadow, one translucent fill
	var k: Vector2 = st.shadow_dir() * st.sun_len() * ppm
	var polys: Array = BridgeArt.shadow_polys(M, V, k)
	# the banks cast on the water only: each edge's swept quad, with the bank itself cut out of it
	for bp: PackedVector2Array in banks:
		var bpx := V.tps(bp)
		var n := bpx.size()
		for i in n:
			var a := bpx[i]
			var b := bpx[(i + 1) % n]
			var s1 := k * 1.4
			if absf((b - a).cross(s1)) < 0.02:
				continue
			for piece: PackedVector2Array in Geometry2D.clip_polygons(PackedVector2Array([a, b, b + s1, a + s1]), bpx):
				polys.append(piece)
	g.begin_path()
	for poly: PackedVector2Array in polys:
		A.add_poly(g, poly, true)
	var sc: Color = rl["shadow"]
	g.fill_color = Color(sc.r, sc.g, sc.b, 1.0)
	g.global_alpha = sc.a
	g.fill()
	g.global_alpha = 1.0
	BridgeArt.draw_bridge(g, M, V, ink, rl)
	var imgs := InkCanvas.render_all([g])
	return imgs[0]
