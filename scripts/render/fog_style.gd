extends RefCounted

# Colour ROLES for the fog and the topographic layer (working rule 6: no hex
# in draw code; docs/proposals/palette-architecture.md: hue is reserved for
# paper, ink, shadow and accents, lightness is a ramp off paper). A role in
# data/view/fog.json is
#
#   { "base": <name>, "toward"?: <name>, "t"?: 0..1, "lift"?: dL, "chroma"?: k, "alpha"?: a }
#
# base / toward name a colour of data/params/render_defaults.json: paper, ink,
# object_fill, wall_fill, rock_fill, roof_lit, dirt, shadow (the chosen shadow
# tint), side_a, side_b (palette.accents). toward + t mixes in sRGB, as the
# prototype's mix() does; lift moves OK lightness by dL and chroma scales OK
# chroma (Track T's fill-ramp helper, TerrainDraw.lift); alpha sets the alpha.
# An unknown name or key is an error, never a default.
#
#   var c := FogStyle.resolve({"base": "ink", "toward": "paper", "t": 0.3}, P)

const RenderParams = preload("res://scripts/world/render_params.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")

const KEYS := ["base", "toward", "t", "lift", "chroma", "alpha"]

static var _accents: Dictionary = {}  # source path -> {side_a: Color, side_b: Color}

# The named palette colour, or null when the name is unknown.
static func base(name: String, P: RenderParams) -> Variant:
	match name:
		"paper": return P.PAPER
		"ink": return P.INK
		"object_fill": return P.CREAM
		"wall_fill": return P.WALL
		"rock_fill": return P.ROCK
		"roof_lit": return P.ROOF
		"dirt": return P.DIRT
		"shadow": return P.shadowCol
		"side_a", "side_b":
			var acc := _accents_of(P)
			return acc.get(name, null)
	return null

# The role's colour; problems are appended to `errors` (when given) and pushed.
static func resolve(spec: Variant, P: RenderParams, errors: Array = []) -> Color:
	if not (spec is Dictionary):
		_err(errors, "a colour role is an object {base, ...}, got %s" % str(spec))
		return Color.TRANSPARENT
	var d: Dictionary = spec
	for k: String in d:
		if not KEYS.has(k):
			_err(errors, "colour role key '%s' is not one of %s" % [k, KEYS])
	var c: Variant = base(str(d.get("base", "")), P)
	if c == null:
		_err(errors, "colour role base '%s' is not a palette colour" % str(d.get("base", "")))
		return Color.TRANSPARENT
	var col: Color = c
	if d.has("toward"):
		var to: Variant = base(str(d["toward"]), P)
		if to == null:
			_err(errors, "colour role toward '%s' is not a palette colour" % str(d["toward"]))
		else:
			col = col.lerp(to, float(d.get("t", 0.5)))
	if d.has("lift") or d.has("chroma"):
		col = TerrainDraw.lift(col, float(d.get("lift", 0.0)), float(d.get("chroma", 1.0)))
	col.a = float(d.get("alpha", 1.0))
	return col

static func _accents_of(P: RenderParams) -> Dictionary:
	if _accents.has(P.source_path):
		return _accents[P.source_path]
	var out := {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(P.source_path))
	if parsed is Dictionary:
		var acc: Variant = (parsed as Dictionary).get("palette", {}).get("accents", {})
		if acc is Dictionary:
			for k: String in ["side_a", "side_b"]:
				if (acc as Dictionary).has(k):
					out[k] = Color.html(str(acc[k]))
	_accents[P.source_path] = out
	return out

static func _err(errors: Array, message: String) -> void:
	errors.append(message)
	push_error("FogStyle: " + message)
