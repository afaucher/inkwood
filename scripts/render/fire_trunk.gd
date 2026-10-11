extends RefCounted

# A BURNT-OUT TREE ON THE MAP (track 'Forest fire', decision forest-fire, 2026-10-11). Alex: "lets burn down to the trunks?" and
# "a burnt-out tree gives no woods cover". When a tree burns out the chunks its canopy or shadow touches are baked again with that
# tree drawn as a TRUNK: no canopy, a charred trunk in ink, a faint scorch on the ground round it and a small shadow of its own.
# The look is a PROPOSED stand-in (a board of 3 to 4 options will swap it); every number is in data/fx/fx.json, block
# "forest_fire".trunk, every colour is a palette ROLE there (no hex), and the whole look sits in this one file so a board can vary it.
#
#   var look := FireTrunk.look()                       # on the main thread, once: the block's numbers and roles resolved
#   FireTrunk.draw_ground(g, trunks, P, look)          # the scorched ground, ink on a chunk canvas (map px; the transform is the caller's)
#   FireTrunk.draw_trunks(g, trunks, P, look)          # the charred trunks, after the shadows (draw() does both)
#   FireTrunk.add_shadows(sp, trunks, receiver, view, ts, look)   # the trunks' own small shadows, into a tree-class ShadowPass
#
# `trunks` are the terrain's tree records (x, y, r, h, seed, base, level: world px) of the trees that are burnt out; the provider
# (chunk_terrain_provider.gd) sorts them out of a chunk's trees by place. Everything is drawn as single-piece paints (a dot, a
# tick, a disc): a translucent path of several pieces makes a canvas group, which costs a pass over the whole chunk (the ground's
# fibres taught this, CLAUDE.md), and a chunk may hold a hundred trunks.

const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

const SALT := 0x7F1E
const MIN_RING_PX := 1.02   # a closed ring stroked at one pixel or less is painted as a canvas group (InkCanvas.stroke: the hairline rule)

# The block's numbers and its colour roles, resolved. Made on the main thread (FxStyle may load files); read on any.
class Look:
	var r_frac := 0.14
	var r_min_px := 1.6
	var height_frac := 0.3
	var shadow_width_frac := 0.9
	var edge_lw := 0.9
	var scorch_r_frac := 0.55
	var dots_per_r := 1.1
	var ticks := 5
	var tick_len := Vector2(0.2, 0.42)
	var fill := Color.BLACK
	var edge := Color.BLACK
	var scorch := Color.BLACK
	var dot := Color.BLACK
	var tick := Color.BLACK
	var ok := false

static func look(data: FxData = null, style: FxStyle = null) -> Look:
	var d: FxData = data if data != null else FxData.shared()
	var st: FxStyle = style if style != null else FxStyle.shared()
	var L := Look.new()
	var raw: Variant = d.raw.get("forest_fire")
	if not (raw is Dictionary) or not ((raw as Dictionary).get("trunk") is Dictionary):
		push_error("FireTrunk: fx.json has no forest_fire.trunk block")
		return L
	var k: Dictionary = FxData.unwrap((raw as Dictionary)["trunk"])
	L.r_frac = FxData.f(k, "trunk_r_frac")
	L.r_min_px = FxData.f(k, "trunk_r_min_px")
	L.height_frac = FxData.f(k, "height_frac")
	L.shadow_width_frac = FxData.f(k, "shadow_width_frac")
	L.edge_lw = FxData.f(k, "edge_lw")
	L.scorch_r_frac = FxData.f(k, "scorch_r_frac")
	L.dots_per_r = FxData.f(k, "scorch_dots_per_r")
	L.ticks = FxData.i(k, "ticks")
	var tl := FxData.arr(k, "tick_len_frac")
	L.tick_len = Vector2(float(tl[0]), float(tl[1]))
	L.fill = st.color(FxData.s(k, "fill_role"))
	L.edge = st.color(FxData.s(k, "edge_role"))
	L.scorch = st.color(FxData.s(k, "scorch_role"))
	L.dot = st.color(FxData.s(k, "scorch_dot_role"))
	L.tick = st.color(FxData.s(k, "tick_role"))
	L.ok = true
	return L

# The trunk's radius and height (world px) for a tree record.
static func trunk_radius(t: Dictionary, L: Look) -> float:
	return maxf(L.r_min_px, float(t["r"]) * L.r_frac)

static func trunk_height(t: Dictionary, L: Look) -> float:
	return float(t["h"]) * L.height_frac

# --- Ink -----------------------------------------------------------------------------------------------------------------

# Every trunk, in the two layers below (what a tool or a test draws in one call).
static func draw(g: InkCanvas, trunks: Array, P: RenderParams, L: Look) -> int:
	draw_ground(g, trunks, P, L)
	return draw_trunks(g, trunks, P, L)

# The scorched ground round each trunk: a faint wash and stipple, as ink on `g` (map px under the caller's transform). It goes down with
# the ground's linework, UNDER the shadows, so a canopy's shadow falls across it as across any ground.
static func draw_ground(g: InkCanvas, trunks: Array, _P: RenderParams, L: Look) -> int:
	var n := 0
	for t: Dictionary in trunks:
		var rng := Mulberry32.new((int(t.get("seed", 0)) ^ SALT) & 0x7FFFFFFF)
		var x: float = t["x"]
		var y: float = t["y"]
		var sr: float = float(t["r"]) * L.scorch_r_frac
		# the scorch: a wobbling blob of the faint role, one piece
		var nb := 9
		var ph := rng.next() * TAU
		g.begin_path()
		for i in nb:
			var a := ph + float(i) / float(nb) * TAU
			var rad := sr * (0.78 + rng.next() * 0.4)
			if i == 0:
				g.move_to(x + cos(a) * rad, y + sin(a) * rad)
			else:
				g.line_to(x + cos(a) * rad, y + sin(a) * rad)
		g.close_path()
		g.fill_color = L.scorch
		g.fill()
		# stipple on it: small squares, each its own piece
		g.fill_color = L.dot
		for _i in int(sr * L.dots_per_r):
			var a2 := rng.next() * TAU
			var d := sqrt(rng.next()) * sr
			var s := 0.9 + rng.next() * 0.7
			g.fill_rect(x + cos(a2) * d - s * 0.5, y + sin(a2) * d - s * 0.5, s, s)
		n += 1
	return n

# The charred trunks themselves: short root marks and the disc with its ink outline. They go down AFTER the shadows (the provider's frame
# stage, before the canopies), so the trunk is ink-dark and not tinted by its own shadow, which starts at its foot.
static func draw_trunks(g: InkCanvas, trunks: Array, P: RenderParams, L: Look) -> int:
	var n := 0
	for t: Dictionary in trunks:
		var rng := Mulberry32.new((int(t.get("seed", 0)) ^ (SALT + 1)) & 0x7FFFFFFF)
		var x: float = t["x"]
		var y: float = t["y"]
		var r: float = t["r"]
		var tr := trunk_radius(t, L)
		# short charred marks from the trunk outward, each a single segment
		g.stroke_color = L.tick
		g.line_width = 0.8 * float(P.lw)
		g.line_cap = "round"
		var a0 := rng.next() * TAU
		for i in L.ticks:
			var a3 := a0 + float(i) / float(maxi(L.ticks, 1)) * TAU + (rng.next() - 0.5) * 0.6
			var l0 := tr * 1.15
			var l1 := l0 + r * lerpf(L.tick_len.x, L.tick_len.y, rng.next())
			g.begin_path()
			g.move_to(x + cos(a3) * l0, y + sin(a3) * l0)
			g.line_to(x + cos(a3) * l1, y + sin(a3) * l1)
			g.stroke()
		# the charred trunk: a filled disc, its ink outline
		g.begin_path()
		g.arc(x, y, tr, 0.0, TAU)
		g.fill_color = L.fill
		g.fill()
		g.stroke_color = L.edge
		g.line_width = maxf(L.edge_lw * float(P.lw), MIN_RING_PX)   # (never a hairline: a hairline ring is a translucent canvas group)
		g.stroke()
		n += 1
	return n

# --- Shadow --------------------------------------------------------------------------------------------------------------------

# The trunks' own small shadows into the tree class's silhouette canvas for `receiver` (TerrainShadows.add_tree_silhouettes' trunk
# stroke without a canopy): a stroke from the foot to the top of a trunk of height_frac x the tree's height, along the sun's
# shadow. Returns how many were added (the provider keeps a part only when it holds something).
static func add_shadows(sp: ShadowPass, trunks: Array, receiver: int, view: Transform2D, ts: TerrainShadows, L: Look) -> int:
	var m: InkCanvas = sp.canvas
	var zr: float = float(ts.terrain.heights_m[receiver]) * float(ts.terrain.px_per_m)
	var count := 0
	m.stroke_color = Color.BLACK
	m.line_cap = "round"
	for t: Dictionary in trunks:
		var base: float = t.get("base", 0.0)
		var top := base + trunk_height(t, L)
		if top <= zr:
			continue
		var w := maxf(1.0, trunk_radius(t, L) * 2.0 * L.shadow_width_frac)
		var pos := Vector2(t["x"], t["y"])
		var foot: Vector2 = pos + ts.dir * ((maxf(base, zr) - zr) * ts.L)
		var s: Vector2 = pos + ts.dir * ((top - zr) * ts.L)
		var lvl: int = t.get("level", 0)
		if lvl > receiver and not ts._reaches_level(s, foot, w, receiver):
			continue
		m.save()
		m.set_transform_matrix(view)
		m.line_width = w
		m.begin_path()
		m.move_to(foot.x, foot.y)
		m.line_to(s.x, s.y)
		m.stroke()
		m.restore()
		count += 1
	return count
