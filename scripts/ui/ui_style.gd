extends RefCounted

# The interface's style: every colour, size and font the UI draws with, read
# from data (working rules 4 and 6). Two files:
#
#   data/params/render_defaults.json   the map's palette (paper, ink, fills, the
#                                      chosen shadow tint, the side accents, the
#                                      shadow-mix fractions) and the light (sun
#                                      direction and elevation, shadow strength,
#                                      the aircraft shadow altitude scale), line
#                                      weight and hand wobble -- read as DATA,
#                                      not through another track's code
#   data/ui/ui.json                    the UI's own roles, sizes and fonts, all
#                                      proposed (Track U)
#
#   var st := UiStyle.shared()            # loaded once, shared by every UI node
#   st.color("card_fill")                 # a role -> Color, resolved at load
#   st.num("roster.row_px")               # a number from ui.json
#   st.side_color("allies")               # the side's accent (ui.json sides.accent)
#
# A ROLE IS NEVER A HEX: it names a palette colour, optionally shaded toward the
# shadow tint by one of the palette's own mix fractions (as the prototype shades
# a roof), mixed toward another palette colour, and given an alpha. Roles are
# resolved once, at load. A role, number or key the code asks for that the data
# does not hold is an ERROR (recorded in `errors` and pushed), never a default
# in code; the getter returns a loud placeholder so the caller can go on and
# every problem shows in one run.

const UI_PATH := "res://data/ui/ui.json"
const RENDER_PATH := "res://data/params/render_defaults.json"

# Palette keys a role may name as its base (render_defaults.json palette).
const PALETTE_KEYS := ["paper", "ink", "object_fill", "wall_fill", "rock_fill", "roof_lit", "dirt"]

var ui: Dictionary = {}
var palette: Dictionary = {}       # key -> Color: PALETTE_KEYS + shadow, side_a, side_b
var mixes: Dictionary = {}         # roof_shaded_shadow_mix, wall_slope_shadow_mix -> float
var params: Dictionary = {}        # render parameter name -> its default (number or string)
var scene_seed: int = 0
var detail_light := Vector2.ZERO   # linework.detail_light
var errors: Array[String] = []

var _roles: Dictionary = {}        # role -> Color
var _fonts: Dictionary = {}        # "regular" / "italic" -> SystemFont
var _warned: Dictionary = {}

static var _shared: RefCounted = null

static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/ui/ui_style.gd").new()
	return _shared

func _init(ui_path: String = UI_PATH, render_path: String = RENDER_PATH) -> void:
	var r: Variant = _read(render_path)
	if r is Dictionary:
		_load_render(r)
	var u: Variant = _read(ui_path)
	if u is Dictionary:
		ui = u
		_load_roles()

func ok() -> bool:
	return errors.is_empty()

# --- Getters -------------------------------------------------------------------

func color(role: String) -> Color:
	if _roles.has(role):
		return _roles[role]
	_err_once("role:" + role, "ui.json roles has no role '%s'" % role)
	return Color(1.0, 0.0, 1.0)

func has_role(role: String) -> bool:
	return _roles.has(role)

# A number from ui.json by dotted path, e.g. "roster.row_px".
func num(path: String) -> float:
	var v: Variant = lookup(path)
	if v is float or v is int:
		return float(v)
	_err_once("num:" + path, "ui.json has no number at '%s'" % path)
	return 0.0

# Sets a number of ui.json at run time, by dotted path: a HOST KNOB, not a way
# around the data (Track A: marker.true_scale follows the plane-size knob and
# the zoom; marker.playback_speed the playback knob). The path must already
# exist and hold a number. Returns whether it was set.
func set_num(path: String, value: float) -> bool:
	var parts := path.split(".")
	var cur: Variant = ui
	for i in parts.size() - 1:
		if not (cur is Dictionary) or not (cur as Dictionary).has(parts[i]):
			return false
		cur = (cur as Dictionary)[parts[i]]
	var key := parts[parts.size() - 1]
	if not (cur is Dictionary) or not ((cur as Dictionary).get(key) is float or (cur as Dictionary).get(key) is int):
		return false
	(cur as Dictionary)[key] = value
	return true

func flag(path: String) -> bool:
	var v: Variant = lookup(path)
	if v is bool:
		return v
	_err_once("flag:" + path, "ui.json has no true/false at '%s'" % path)
	return false

func text(path: String) -> String:
	var v: Variant = lookup(path)
	if v is String:
		return v
	_err_once("text:" + path, "ui.json has no string at '%s'" % path)
	return "?"

func lookup(path: String) -> Variant:
	var cur: Variant = ui
	for part: String in path.split("."):
		if not (cur is Dictionary) or not (cur as Dictionary).has(part):
			return null
		cur = (cur as Dictionary)[part]
	return cur

# The accent of a world side name (ui.json sides.accent -> a palette accent).
func side_color(side: String) -> Color:
	var key: Variant = lookup("sides.accent." + side)
	if key is String and palette.has(key):
		return palette[key]
	_err_once("side:" + side, "ui.json sides.accent has no accent for side '%s'" % side)
	return palette.get("ink", Color(1.0, 0.0, 1.0))

# A render parameter's default as a float (render_defaults.json parameters).
func param(name: String) -> float:
	var v: Variant = params.get(name)
	if v is float or v is int:
		return float(v)
	_err_once("param:" + name, "render_defaults.json parameters has no number '%s'" % name)
	return 0.0

# --- The light (the map's sun, as the prototype computes it) -----------------------

# shadowDir(): the direction shadows fall, unit vector, screen axes (y down).
func shadow_dir() -> Vector2:
	var az := deg_to_rad(param("sun_direction") + 90.0)
	return Vector2(cos(az), sin(az))

# sunL(): shadow length per unit of height.
func sun_len() -> float:
	return 1.0 / tan(deg_to_rad(param("sun_elevation")))

# How far, in world metres, a plane's shadow sits from it when it flies
# `height_m` above the surface under it: cast as if it flew at height x
# aircraft_shadow_altitude_scale (Alex, decision unit-sheet-choices), away from
# the sun, no stretch.
func plane_shadow_offset_m(height_m: float) -> Vector2:
	return shadow_dir() * (maxf(height_m, 0.0) * param("aircraft_shadow_altitude_scale") * sun_len())

# --- Fonts ---------------------------------------------------------------------

func font(italic: bool = false) -> Font:
	var key := "italic" if italic else "regular"
	if _fonts.has(key):
		return _fonts[key]
	var f := SystemFont.new()
	var names := PackedStringArray()
	var list: Variant = lookup("fonts.serif")
	if list is Array:
		for n: Variant in list:
			names.append(str(n))
	else:
		_err_once("fonts", "ui.json fonts.serif must be a list of font names")
	f.font_names = names
	f.font_italic = italic
	_fonts[key] = f
	return f

# --- Loading -------------------------------------------------------------------

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
	else:
		_err("render_defaults.json palette has no accents")
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
	else:
		_err("render_defaults.json has no parameters")
	# The shadow tint the map uses: parameters.shadow_tint.default -> palette.shadow_tints.
	var tint_name := str(params.get("shadow_tint", ""))
	var tints: Variant = p.get("shadow_tints")
	if tints is Dictionary and (tints as Dictionary).has(tint_name):
		_palette_hex("shadow", (tints as Dictionary)[tint_name])
	else:
		_err("shadow tint '%s' is not in palette.shadow_tints" % tint_name)
	var lw: Variant = d.get("linework")
	if lw is Dictionary and (lw as Dictionary).get("detail_light") is Dictionary:
		var dl: Dictionary = (lw as Dictionary)["detail_light"]
		detail_light = Vector2(float(dl.get("x", 0.0)), float(dl.get("y", 0.0)))
	else:
		_err("render_defaults.json has no linework.detail_light")

func _palette_hex(key: String, v: Variant) -> void:
	if v is String and Color.html_is_valid(v):
		palette[key] = Color.html(v)
	else:
		_err("render_defaults.json palette '%s' is not a colour" % key)

func _load_roles() -> void:
	var roles: Variant = ui.get("roles")
	if not (roles is Dictionary):
		_err("ui.json has no roles")
		return
	for name: String in (roles as Dictionary):
		if name.begins_with("_"):
			continue
		var def: Variant = (roles as Dictionary)[name]
		if def is Dictionary:
			_roles[name] = _resolve(name, def)
		else:
			_err("ui.json role '%s' is not an object" % name)

func _resolve(name: String, def: Dictionary) -> Color:
	var base := str(def.get("base", ""))
	if not palette.has(base):
		_err("ui.json role '%s': base '%s' is not a palette colour" % [name, base])
		return Color(1.0, 0.0, 1.0)
	var c: Color = palette[base]
	if def.has("shade"):
		var m := str(def["shade"])
		if mixes.has(m) and palette.has("shadow"):
			# The prototype's mix(shadowCol, fill, 1 - fraction), rounded per channel.
			c = mix8(palette["shadow"], c, 1.0 - float(mixes[m]))
		else:
			_err("ui.json role '%s': shade '%s' is not a palette mix fraction" % [name, m])
	if def.has("toward"):
		var to := str(def["toward"])
		if palette.has(to):
			c = mix8(c, palette[to], float(def.get("t", 0.0)))
		else:
			_err("ui.json role '%s': toward '%s' is not a palette colour" % [name, to])
	if def.has("alpha"):
		var a: Variant = def["alpha"]
		if a is String:
			c.a = param(a)
		elif a is float or a is int:
			c.a = float(a)
		else:
			_err("ui.json role '%s': alpha must be a number or a parameter name" % name)
	return c

# The prototype's mix(a, b, t): per channel a + (b - a) * t, rounded to 8 bits.
static func mix8(a: Color, b: Color, t: float) -> Color:
	return Color8(
		roundi(a.r8 + (b.r8 - a.r8) * t),
		roundi(a.g8 + (b.g8 - a.g8) * t),
		roundi(a.b8 + (b.b8 - a.b8) * t))

func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		_err("file missing: %s" % path)
		return null
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (v is Dictionary):
		_err("does not parse as a JSON object: %s" % path)
		return null
	return v

func _err(message: String) -> void:
	errors.append(message)
	push_error("UiStyle: " + message)

func _err_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	_err(message)
