extends RefCounted

# The prototype's `P` object and its constants, read from
# data/params/render_defaults.json (working rule 4: values live in data, code
# reads them). Exposed UNDER THE PROTOTYPE'S NAMES so a ported line reads like
# the original -- `P.treeSize*(1+P.sizeVar*t.sr)` becomes
# `P.treeSize * (1.0 + P.sizeVar * t.sr)` with `P` an instance of this script.
#
#   prototype                                   data/params/render_defaults.json
#   P.brush, P.density, P.collide               parameters.brush_size / density / collision_check
#   P.treeSize, P.sizeVar, P.rings, P.height    parameters.canopy_size / size_variation /
#                                                 inner_contour_rings / tree_height
#   P.wallW, P.wallH, P.houseSize               parameters.wall_width / wall_height / house_size
#   P.houseHeightRatio                          parameters.house_height_ratio (decision scenery-heights, S1): a house's height
#                                                 is houseSize * this (the prototype's literal 0.9) times its own factor
#   P.treeHeightScale, P.treeHeightMin/Max      parameters.tree_height_scale / tree_height_min_px / tree_height_max_px
#                                                 (decision scenery-heights, S1): a tree's height times the scale, held to
#                                                 [min, max] px (0 = no bound). The prototype's values (1, 0, 0) are each
#                                                 entry's prototype_default; use_prototype_defaults() sets them back
#   P.sunAz, P.elev, P.shadowStr, P.shadowCol   data/params/sun.json via scripts/world/sun.gd (Sun.current():
#                                                 the compass bearing and the height of THE sun, one source for
#                                                 every reader; 'fixed' is the prototype's 315 / 46) /
#                                                 parameters.shadow_strength / shadow_tint (+ palette.shadow_tints)
#   P.treeSunAz, P.treeElev                      the sun the trees' CAST SHADOWS follow: P.sunAz, P.elev unless
#                                                 Sun's scope is "trees" (the board's two-suns frame, PROPOSED)
#   P.lw, P.wob, P.grain                        parameters.line_weight / hand_wobble / paper_grain
#   P.L.{paper,road,shadows,objects,grain,grid} render_passes.enabled (grid = debug_grid)
#   CELL, ROAD_HALF                             constants.collision_cell_px / road_half_width_px
#   LX, LY                                      linework.detail_light.x / .y
#   PAPER CREAM ROCK INK DIRT WALL ROOF         palette.paper / object_fill / rock_fill / ink /
#                                                 dirt / wall_fill / roof_lit
#   the literals .1 / 1.45 (makeTree, syncTree), .72 / 1.25 (cr), the prop mix
#   .5 / .8 (makeProp)                          constants.big_tree_chance / big_tree_scale /
#                                                 tree_collision_radius / prop_collision_radius / prop_mix
#
# Numbers stay float64 as parsed. Short decimals (0.4, 1.3, 0.92) parse to the
# same double in Godot as in JavaScript -- the bit check against the prototype's
# own `P` is in scripts/tests/test_scene_gen.gd -- but keep data values at 15
# significant digits or fewer: past that Godot's parser is not exact
# (CLAUDE.md, engine traps). P.shadowCol and the palette are Colors (float32
# channels), which is fine: they only ever reach the drawing layer.
#
# A missing or mistyped key is recorded in `errors` (and pushed) rather than
# defaulted, so a broken data file cannot quietly fall back to a value that
# lives in code. Construct, then check `ok()`.

const Sun = preload("res://scripts/world/sun.gd")

const DEFAULT_PATH := "res://data/params/render_defaults.json"

# --- P.* -----------------------------------------------------------------------
var brush: float
var density: float
var collide: bool
var treeSize: float
var sizeVar: float
var rings: int
var height: float
var sunAz: float
var elev: float
var treeSunAz: float   # the trees' cast shadows (terrain_shadows.gd): sunAz unless Sun's scope is "trees"
var treeElev: float
var shadowStr: float
var shadowCol: Color
var shadow_tint: String  # the tint's NAME ("steel"); P.shadowCol is its colour
var lw: float
var wob: float
var grain: float
var wallW: float
var wallH: float
var houseSize: float
var houseHeightRatio: float   # a house's height = houseSize * this * hs (structures.gd sync_struct); the prototype's literal was 0.9
var treeHeightScale: float    # a tree's height (scene_gen.gd sync_tree) is multiplied by this ...
var treeHeightMin: float      # ... then held to [min, max] px; 0 = unbounded on that side (the prototype's)
var treeHeightMax: float
var L: Dictionary = {}  # paper, road, shadows, objects, grain, grid -> bool

# --- prototype constants -------------------------------------------------------
var CELL: float
var ROAD_HALF: float
var LX: float
var LY: float
var PAPER: Color
var CREAM: Color
var ROCK: Color
var INK: Color
var DIRT: Color
var WALL: Color
var ROOF: Color
var shadow_tints: Dictionary = {}  # name -> Color
var linework: Dictionary = {}      # element -> line-weight multiplier (float)
var big_tree_chance: float
var big_tree_scale: float
var tree_collision_radius: float
var prop_collision_radius: float
var prop_mix: Dictionary = {}      # rock / barrel / crate -> share (float)
var wall_close_distance: float
var canopy_shadow_stretch_max: float

var source_path: String
var errors: Array[String] = []

func _init(path: String = DEFAULT_PATH) -> void:
	source_path = path
	if not FileAccess.file_exists(path):
		_err("render params file missing: %s" % path)
		return
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (root is Dictionary):
		_err("render params do not parse as a JSON object: %s" % path)
		return
	var d: Dictionary = root
	var prm: Dictionary = _section(d, "parameters")
	brush = _default(prm, "brush_size")
	density = _default(prm, "density")
	collide = _default_bool(prm, "collision_check")
	treeSize = _default(prm, "canopy_size")
	sizeVar = _default(prm, "size_variation")
	rings = int(_default(prm, "inner_contour_rings"))
	height = _default(prm, "tree_height")
	wallW = _default(prm, "wall_width")
	wallH = _default(prm, "wall_height")
	houseSize = _default(prm, "house_size")
	houseHeightRatio = _default(prm, "house_height_ratio")
	treeHeightScale = _default(prm, "tree_height_scale")
	treeHeightMin = _default(prm, "tree_height_min_px")
	treeHeightMax = _default(prm, "tree_height_max_px")
	# THE SUN is data/params/sun.json's (Sun.current(): fixed = the prototype's 315 and 46 unless a switch says clock)
	var sun = Sun.current()
	if not sun.ok():
		for e: String in sun.errors:
			_err(e)
	sunAz = sun.azimuth_deg
	elev = sun.elevation_deg
	treeSunAz = sun.tree_azimuth_deg
	treeElev = sun.tree_elevation_deg
	shadowStr = _default(prm, "shadow_strength")
	lw = _default(prm, "line_weight")
	wob = _default(prm, "hand_wobble")
	grain = _default(prm, "paper_grain")

	var pal: Dictionary = _section(d, "palette")
	PAPER = _color(pal, "paper")
	INK = _color(pal, "ink")
	CREAM = _color(pal, "object_fill")
	WALL = _color(pal, "wall_fill")
	ROCK = _color(pal, "rock_fill")
	ROOF = _color(pal, "roof_lit")
	DIRT = _color(pal, "dirt")
	var tints: Dictionary = _section(pal, "shadow_tints")
	for k: String in tints:
		shadow_tints[k] = _color(tints, k)
	var tint_entry: Dictionary = _section(prm, "shadow_tint")
	shadow_tint = str(tint_entry.get("default", ""))
	if shadow_tints.has(shadow_tint):
		shadowCol = shadow_tints[shadow_tint]
	else:
		_err("parameters.shadow_tint.default '%s' is not in palette.shadow_tints" % shadow_tint)

	var passes: Dictionary = _section(_section(d, "render_passes"), "enabled")
	for k: String in ["paper", "road", "shadows", "objects", "grain"]:
		L[k] = _bool(passes, k)
	L["grid"] = _bool(passes, "debug_grid")

	var lwk: Dictionary = _section(d, "linework")
	for k: String in lwk:
		if lwk[k] is float:
			linework[k] = lwk[k]
	var light: Dictionary = _section(lwk, "detail_light")
	LX = _num(light, "x")
	LY = _num(light, "y")

	var c: Dictionary = _section(d, "constants")
	CELL = _num(c, "collision_cell_px")
	ROAD_HALF = _num(c, "road_half_width_px")
	wall_close_distance = _num(c, "wall_close_distance_px")
	big_tree_chance = _num(c, "big_tree_chance")
	big_tree_scale = _num(c, "big_tree_scale")
	tree_collision_radius = _num(c, "tree_collision_radius")
	prop_collision_radius = _num(c, "prop_collision_radius")
	canopy_shadow_stretch_max = _num(c, "canopy_shadow_stretch_max")
	var mix: Dictionary = _section(c, "prop_mix")
	for k: String in ["rock", "barrel", "crate"]:
		prop_mix[k] = _num(mix, k)

func ok() -> bool:
	return errors.is_empty()

# The prototype's name for each parameter that has a data key (data key -> P field). PARITY (render's -Parity, the port check) sets
# each one whose entry carries a "prototype_default" back to it: render_defaults.json keeps the prototype's value beside a decided
# one, so the game runs the decided value and the check against the prototype runs the prototype's.
const PARITY_NAMES := {"brush_size": "brush", "density": "density", "canopy_size": "treeSize",
	"size_variation": "sizeVar", "inner_contour_rings": "rings", "tree_height": "height",
	"wall_width": "wallW", "wall_height": "wallH", "house_size": "houseSize",
	"house_height_ratio": "houseHeightRatio", "tree_height_scale": "treeHeightScale",
	"tree_height_min_px": "treeHeightMin", "tree_height_max_px": "treeHeightMax", "sun_direction": "sunAz",
	"sun_elevation": "elev", "shadow_strength": "shadowStr", "line_weight": "lw", "hand_wobble": "wob",
	"paper_grain": "grain"}

# The tallest a tree can be, px: the biggest crown at the tallest height factor, scaled and held to the window. What a shadow's
# reach is measured from (terrain_shadows.gd, chunk_scene_provider.gd): with the prototype's values it is exactly what they
# computed before (treeSize x (1 + sizeVar) x big x height x 1.15).
func tallest_tree_px() -> float:
	var h := treeSize * (1.0 + sizeVar) * big_tree_scale * height * 1.15 * treeHeightScale
	if treeHeightMax > 0.0:
		h = minf(h, treeHeightMax)
	return h

# Sets every mapped P field whose data entry has a "prototype_default" to that value. Returns a line per change. (InkRenderer's
# apply_prototype_defaults calls this, then does the pen.) Tree height and structure height are read by scene_gen.gd and
# structures.gd from P, so a scene generated after this call is the prototype's own.
func use_prototype_defaults() -> Array[String]:
	var out: Array[String] = []
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(source_path))
	var prm: Dictionary = (raw as Dictionary).get("parameters", {}) if raw is Dictionary else {}
	for key: String in prm:
		var entry: Variant = prm[key]
		if not (entry is Dictionary and (entry as Dictionary).has("prototype_default") and PARITY_NAMES.has(key)):
			continue
		var v: Variant = entry["prototype_default"]
		var field: String = PARITY_NAMES[key]
		var was: Variant = get(field)
		set(field, int(v) if field == "rings" else float(v))
		out.append("P.%s %s -> %s (parameters.%s.prototype_default)" % [field, str(was), str(get(field)), key])
	return out

func _err(message: String) -> void:
	errors.append(message)
	push_error("RenderParams: " + message)

func _section(d: Dictionary, key: String) -> Dictionary:
	var v: Variant = d.get(key)
	if v is Dictionary:
		return v
	_err("missing section '%s' in %s" % [key, source_path])
	return {}

func _num(d: Dictionary, key: String) -> float:
	var v: Variant = d.get(key)
	if v is float or v is int:
		return float(v)
	_err("missing number '%s' in %s" % [key, source_path])
	return NAN

func _bool(d: Dictionary, key: String) -> bool:
	var v: Variant = d.get(key)
	if v is bool:
		return v
	_err("missing boolean '%s' in %s" % [key, source_path])
	return false

func _default(prm: Dictionary, key: String) -> float:
	return _num(_section(prm, key), "default")

func _default_bool(prm: Dictionary, key: String) -> bool:
	return _bool(_section(prm, key), "default")

func _color(d: Dictionary, key: String) -> Color:
	var v: Variant = d.get(key)
	if v is String and Color.html_is_valid(v):
		return Color.html(v)
	_err("missing colour '%s' in %s" % [key, source_path])
	return Color.MAGENTA
