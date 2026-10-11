extends RefCounted

# A PLACEHOLDER SEA AND RIVER for the boats' and the bridges' boards (Track BB, 2026-10-10): a flat
# wash of the role water_placeholder (data/world/boats.json: the one shadow tint mixed toward paper),
# short ruled ripple strokes in ink at a low alpha, and -- for the bridge board -- a bank: paper land
# with a hand-wobbled shore line and a few inked hachures on the shadow side. NOT THE WATER'S LOOK:
# that is Track WB's board (variants/water/), whose chosen look replaces this file's wash when it
# exists. It is here only so a boat, a wake and a bridge's shadow can be judged on something blue.
#
# Everything is a function of the position and the seed, so two frames of one board put the same
# ripple in the same place.

const A = preload("res://scripts/ui/unit_marker_art.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

# The sea over the whole of `rect` (px). `scale` is the map's px per metre x the zoom: ripple spacing
# follows it (a ripple is a thing of the map, not of the screen), kept readable at the planning zoom.
static func sea(g, rect: Rect2, scale: float, roles: Dictionary, ink_lw: float, seed_value: int) -> void:
	g.fill_color = roles["water_placeholder"]
	g.fill_rect(rect.position.x, rect.position.y, rect.size.x, rect.size.y)
	ripples(g, rect, scale, roles, ink_lw, seed_value, null)

# Ripples over `rect`, skipping any cell whose centre `keep_out` (a Callable(Vector2) -> bool, true = skip) refuses.
static func ripples(g, rect: Rect2, scale: float, roles: Dictionary, ink_lw: float, seed_value: int, keep_out: Variant) -> void:
	var sp := clampf(22.0 * scale / 2.0 * 1.3, 9.0, 46.0)   # a ripple every ~2 x 10 m at the map's scale
	var col: Color = roles["ripple_placeholder"]
	if col.a <= 0.001:
		return
	g.stroke_color = (roles["ink"] as Color)
	g.line_width = 0.5 * ink_lw
	g.global_alpha = col.a
	g.begin_path()
	var cols := int(ceil(rect.size.x / sp)) + 1
	var rows := int(ceil(rect.size.y / (sp * 0.62))) + 1
	for j in rows:
		for i in cols:
			var h := ValueNoise.hash2(i + int(rect.position.x / sp), j + int(rect.position.y / sp), seed_value)
			if h < 0.42:
				continue
			var cx := rect.position.x + (float(i) + ValueNoise.hash2(i, j, seed_value + 3)) * sp
			var cy := rect.position.y + (float(j) + ValueNoise.hash2(i, j, seed_value + 7)) * sp * 0.62
			if keep_out is Callable and (keep_out as Callable).call(Vector2(cx, cy)):
				continue
			var ln := sp * (0.3 + 0.5 * ValueNoise.hash2(i, j, seed_value + 11))
			g.move_to(cx - ln / 2.0, cy)
			g.line_to(cx - ln * 0.15, cy - ln * 0.07)
			g.line_to(cx + ln * 0.15, cy + ln * 0.07)
			g.line_to(cx + ln / 2.0, cy)
	g.stroke()
	g.global_alpha = 1.0

# Paper land on the polygon `land` (px): the paper colour, the shore line wobbled by a value noise, and short
# hachures inward from the edges that face away from the sun (the prototype's slope hatching). Drawn OVER the sea.
static func bank(g, land: PackedVector2Array, roles: Dictionary, ink_lw: float, sd: Vector2, seed_value: int) -> void:
	var edge := PackedVector2Array()
	var n := land.size()
	for i in n:
		edge.append(land[i])
	g.begin_path()
	A.add_poly(g, edge, true)
	g.fill_color = roles["land_placeholder"]
	g.fill()
	g.stroke_color = roles["ink"]
	g.line_width = 1.1 * ink_lw
	g.global_alpha = 0.9
	g.begin_path()
	A.add_poly(g, edge, true)
	g.stroke()
	g.global_alpha = 1.0

# --- Track WB's proposed default water, READ (not copied) ---------------------------------------------------------

const WB_PATH := "res://data/world/water.json"

# The three depth steps of Track WB's working-default water (data/world/water.json draw.palette: an OKLCH hue, and per
# step a lightness below the paper's and a chroma): [shallows, shelf, deep] as Colors, or [] when the file is not there
# or has another shape (the boards then fall back to the placeholder role). Read at render time, so whatever Track WB
# tunes is what a boat is drawn over; nothing of theirs is edited or called but this data.
static func wb_steps(st: RefCounted) -> Array:
	if not FileAccess.file_exists(WB_PATH):
		return []
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(WB_PATH))
	if not (v is Dictionary):
		return []
	var pal: Variant = ((v as Dictionary).get("draw", {}) as Dictionary).get("palette")
	if not (pal is Dictionary):
		return []
	var p: Dictionary = pal
	for k: String in ["hue_deg", "lightness_below_paper", "chroma"]:
		if not (p.get(k) is Dictionary) or not (p[k] as Dictionary).has("value"):
			return []
	var hue: float = float((p["hue_deg"] as Dictionary)["value"])
	var dl: Array = (p["lightness_below_paper"] as Dictionary)["value"]
	var ch: Array = (p["chroma"] as Dictionary)["value"]
	if dl.size() != 3 or ch.size() != 3:
		return []
	var paper_l := _oklab_l(st.palette["paper"])
	var out: Array = []
	for i in 3:
		out.append(oklch_to_color(paper_l - float(dl[i]), float(ch[i]), hue))
	return out

static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func _enc(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 12.92 * x if x <= 0.0031308 else 1.055 * pow(x, 1.0 / 2.4) - 0.055

static func _oklab_l(c: Color) -> float:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l_ := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m_ := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s_ := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_

static func oklch_to_color(L: float, C: float, h_deg: float) -> Color:
	var a := C * cos(deg_to_rad(h_deg))
	var b := C * sin(deg_to_rad(h_deg))
	var l_ := L + 0.3963377774 * a + 0.2158037573 * b
	var m_ := L - 0.1055613458 * a - 0.0638541728 * b
	var s_ := L - 0.0894841775 * a - 1.2914855480 * b
	var l := l_ * l_ * l_
	var m := m_ * m_ * m_
	var s := s_ * s_ * s_
	return Color(_enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
		_enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
		_enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))

# Folds Track WB's steps into a board's resolved roles: water_placeholder becomes the SHELF (an open coast), water_shallows /
# water_shelf / water_deep are added, and the placeholder ripple strokes are switched off (option A, WB's default, draws none).
# Returns true when WB's data was used.
static func adopt_wb(st: RefCounted, roles: Dictionary) -> bool:
	var steps := wb_steps(st)
	if steps.size() != 3:
		return false
	roles["water_shallows"] = steps[0]
	roles["water_shelf"] = steps[1]
	roles["water_deep"] = steps[2]
	roles["water_placeholder"] = steps[1]
	var rp: Color = roles["ripple_placeholder"]
	rp.a = 0.0
	roles["ripple_placeholder"] = rp
	return true
