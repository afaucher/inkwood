extends RefCounted

# The effects' colours and the light, from data (working rules 4 and 6): every
# colour the effects draw is a ROLE (data/fx/fx.json roles) that names a palette
# colour of data/params/render_defaults.json, optionally mixed toward another
# palette colour, shaded toward the shadow tint by one of the palette's own mix
# fractions, and given an alpha -- the same schema as data/ui/ui.json, resolved
# here in one fixed order: base, toward, shade, alpha. No hex literal is in any
# draw code. Hue stays reserved for paper, ink, shadow and the accents; the
# accents are the two side colours (Alex) and the effects' own base colours in fx.json
# `accents`, given in OKLCH: `fire` (the scorch) and `fire_cool` (the cooling step), INTERIM
# working values (the fire research's treatment 6, docs/proposals/fire-in-ink.md, after Alex
# rejected the first orange; proposed, pending his pick) and `flash`, the knock-out step.
# Any accent with an oklch value there is a base a role may name.
#
#   var st := FxStyle.shared()
#   st.color("smoke.lit.0")     # a role -> Color
#   st.ink()                    # the palette's ink, exactly (the pen keys on it)
#   st.shadow_dir(), st.plane_shadow_offset_m(height_m)    # the map's light
#
# A role the data does not hold is an ERROR (recorded and pushed once); the
# getter returns a loud magenta so the caller can go on.

const RENDER_PATH := "res://data/params/render_defaults.json"
const PALETTE_KEYS := ["paper", "ink", "object_fill", "wall_fill", "rock_fill", "roof_lit", "dirt"]

var data: RefCounted
var palette: Dictionary = {}     # name -> Color: PALETTE_KEYS + shadow, side_a, side_b, fire
var mixes: Dictionary = {}       # roof_shaded_shadow_mix, wall_slope_shadow_mix -> float
var params: Dictionary = {}      # render parameter name -> default
var linework: Dictionary = {}    # element -> multiplier
var detail_light := Vector2.ZERO
var scene_seed: int = 0
# The fire switch: false draws no flash, flames or embers (fx.json fire_switch.enabled; Alex: no fire for now).
var fire_on: bool = false
var errors: Array[String] = []

var _roles: Dictionary = {}
var _warned: Dictionary = {}

static var _shared: RefCounted = null

static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/fx/fx_style.gd").new()
	return _shared

func _init(fx_data: RefCounted = null) -> void:
	data = fx_data if fx_data != null else load("res://scripts/fx/fx_data.gd").shared()
	var r: Variant = JSON.parse_string(FileAccess.get_file_as_string(RENDER_PATH)) if FileAccess.file_exists(RENDER_PATH) else null
	if r is Dictionary:
		_load_render(r)
	else:
		_err("%s did not load" % RENDER_PATH)
	fire_on = data.fire_enabled()
	var fo: Array = data.fire_oklch()
	palette["fire"] = oklch(float(fo[0]), float(fo[1]), float(fo[2]))
	# any other accent given in OKLCH is a base colour of its own (round 2: `flash`, the knock-out step)
	var acc: Variant = data.raw.get("accents")
	if acc is Dictionary:
		for k: String in acc:
			var rec: Variant = (acc as Dictionary)[k]
			if k.begins_with("_") or k == "fire" or not (rec is Dictionary):
				continue
			var v: Variant = data.unwrap((rec as Dictionary).get("oklch"))
			if v is Array and (v as Array).size() == 3:
				palette[k] = oklch(float(v[0]), float(v[1]), float(v[2]))
	for name: String in data.role_names():
		_roles[name] = _resolve(name, data.role(name))

func ok() -> bool:
	return errors.is_empty() and data.ok()

# --- Getters ---------------------------------------------------------------------------------

func color(role: String) -> Color:
	if _roles.has(role):
		return _roles[role]
	_err_once("role:" + role, "fx.json roles has no role '%s'" % role)
	return Color(1.0, 0.0, 1.0)

func has_role(role: String) -> bool:
	return _roles.has(role)

# The palette's ink, opaque: the drawing layer's pen is applied to strokes of EXACTLY this colour.
func ink() -> Color:
	return palette["ink"]

func param(name: String) -> float:
	var v: Variant = params.get(name)
	if v is float or v is int:
		return float(v)
	_err_once("param:" + name, "render_defaults.json parameters has no number '%s'" % name)
	return 0.0

func line_weight() -> float:
	return param("line_weight")

func wobble() -> float:
	return param("hand_wobble")

func lw(element: String) -> float:
	var v: Variant = linework.get(element)
	if v is float or v is int:
		return float(v)
	_err_once("lw:" + element, "render_defaults.json linework has no '%s'" % element)
	return 1.0

# --- The light (the map's sun, as the prototype computes it) ---------------------------------------

# The direction shadows fall, unit vector, screen axes (y down).
func shadow_dir() -> Vector2:
	var az := deg_to_rad(param("sun_direction") + 90.0)
	return Vector2(cos(az), sin(az))

func sun_len() -> float:
	return 1.0 / tan(deg_to_rad(param("sun_elevation")))

# Where a plane's shadow (or a puff's, a falling piece's) sits from the thing at
# `height_m` above the surface under it: cast as if it flew at height x
# aircraft_shadow_altitude_scale, away from the sun, no stretch (Alex, decision
# unit-sheet-choices). The same rule as UiStyle.plane_shadow_offset_m.
func plane_shadow_offset_m(height_m: float) -> Vector2:
	return shadow_dir() * (maxf(height_m, 0.0) * param("aircraft_shadow_altitude_scale") * sun_len())

# --- Colour maths ---------------------------------------------------------------------------------------

# OKLCH (L 0..1, C, h in degrees) to an sRGB Color, clipped to the gamut.
static func oklch(L: float, C: float, h_deg: float) -> Color:
	var a := C * cos(deg_to_rad(h_deg))
	var b := C * sin(deg_to_rad(h_deg))
	var l_ := L + 0.3963377774 * a + 0.2158037573 * b
	var m_ := L - 0.1055613458 * a - 0.0638541728 * b
	var s_ := L - 0.0894841775 * a - 1.2914855480 * b
	var l := l_ * l_ * l_
	var m := m_ * m_ * m_
	var s := s_ * s_ * s_
	var r := 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
	var g := -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
	var bl := -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	return Color8(roundi(_gamma(r) * 255.0), roundi(_gamma(g) * 255.0), roundi(_gamma(bl) * 255.0))

static func _gamma(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 12.92 * x if x <= 0.0031308 else 1.055 * pow(x, 1.0 / 2.4) - 0.055

# The prototype's mix(a, b, t): per channel a + (b - a) * t, rounded to 8 bits.
static func mix8(a: Color, b: Color, t: float) -> Color:
	return Color8(
		roundi(a.r8 + (b.r8 - a.r8) * t),
		roundi(a.g8 + (b.g8 - a.g8) * t),
		roundi(a.b8 + (b.b8 - a.b8) * t))

# OKLCH of a Color (for the swatch board's read-outs).
static func to_oklch(c: Color) -> Array:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	var L := 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
	var a := 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
	var bb := 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	var h := rad_to_deg(atan2(bb, a))
	if h < 0.0:
		h += 360.0
	return [L, sqrt(a * a + bb * bb), h]

static func _lin(x: float) -> float:
	return x / 12.92 if x <= 0.04045 else pow((x + 0.055) / 1.055, 2.4)

# --- Loading ---------------------------------------------------------------------------------------------

func _load_render(d: Dictionary) -> void:
	scene_seed = int(d.get("scene_seed", 0))
	var pal: Variant = d.get("palette")
	if not (pal is Dictionary):
		_err("render_defaults.json has no palette")
		return
	var p: Dictionary = pal
	for k: String in PALETTE_KEYS:
		_palette_hex(k, p.get(k))
	var acc: Variant = p.get("accents")
	if acc is Dictionary:
		for k: String in ["side_a", "side_b"]:
			_palette_hex(k, (acc as Dictionary).get(k))
	for k: String in ["roof_shaded_shadow_mix", "wall_slope_shadow_mix"]:
		var v: Variant = p.get(k)
		if v is float or v is int:
			mixes[k] = float(v)
		else:
			_err("render_defaults.json palette has no number '%s'" % k)
	var prm: Variant = d.get("parameters")
	if prm is Dictionary:
		for k: String in (prm as Dictionary):
			var e: Variant = (prm as Dictionary)[k]
			if e is Dictionary and (e as Dictionary).has("default"):
				params[k] = (e as Dictionary)["default"]
	var tint_name := str(params.get("shadow_tint", ""))
	var tints: Variant = p.get("shadow_tints")
	if tints is Dictionary and (tints as Dictionary).has(tint_name):
		_palette_hex("shadow", (tints as Dictionary)[tint_name])
	else:
		_err("shadow tint '%s' is not in palette.shadow_tints" % tint_name)
	var lwk: Variant = d.get("linework")
	if lwk is Dictionary:
		for k: String in (lwk as Dictionary):
			var v: Variant = (lwk as Dictionary)[k]
			if v is float or v is int:
				linework[k] = float(v)
		var dl: Variant = (lwk as Dictionary).get("detail_light")
		if dl is Dictionary:
			detail_light = Vector2(float((dl as Dictionary).get("x", 0.0)), float((dl as Dictionary).get("y", 0.0)))
		else:
			_err("render_defaults.json has no linework.detail_light")

func _palette_hex(key: String, v: Variant) -> void:
	if v is String and Color.html_is_valid(v):
		palette[key] = Color.html(v)
	else:
		_err("render_defaults.json palette '%s' is not a colour" % key)

func _resolve(name: String, def: Dictionary) -> Color:
	var base := str(def.get("base", ""))
	if not palette.has(base):
		_err("fx.json role '%s': base '%s' is not a palette colour" % [name, base])
		return Color(1.0, 0.0, 1.0)
	var c: Color = palette[base]
	if def.has("toward"):
		var to := str(def["toward"])
		if palette.has(to):
			c = mix8(c, palette[to], float(def.get("t", 0.0)))
		else:
			_err("fx.json role '%s': toward '%s' is not a palette colour" % [name, to])
	if def.has("shade"):
		var m := str(def["shade"])
		if mixes.has(m) and palette.has("shadow"):
			c = mix8(palette["shadow"], c, 1.0 - float(mixes[m]))
		else:
			_err("fx.json role '%s': shade '%s' is not a palette mix fraction" % [name, m])
	if def.has("alpha"):
		var a: Variant = def["alpha"]
		if a is String:
			c.a = param(a)
		elif a is float or a is int:
			c.a = float(a)
		else:
			_err("fx.json role '%s': alpha must be a number or a parameter name" % name)
	return c

func _err(message: String) -> void:
	errors.append(message)
	push_error("FxStyle: " + message)

func _err_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	_err(message)
