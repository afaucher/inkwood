extends RefCounted

# VISION (Track F): what each revealing unit sees. Pure -- no nodes, no drawing --
# so the UI, Track A and the tests can all ask it. Metres throughout (the sim's
# unit), float64.
#
#   var vision := FogVision.new()                    # reads data/view/fog.json
#   vision.update_from_world(world)                  # circles from the revealing units
#   vision.update_from_world(world, t, "history")    # ... where they are t s into the
#                                                    #     resolve animation (World.sample)
#   vision.is_visible(Vector2(x_m, y_m)) -> bool     # is that GROUND in sight?
#   vision.shows_unit(world, unit_id) -> bool        # hide enemy markers outside vision
#   ui.marker_layer.unit_visible = vision.unit_visible(world)   # Track U's hook: id -> bool
#   vision.circles                                   # [{id, x, y, r, eye_agl, shed?}] metres
#
# WHICH UNITS REVEAL (data vision.reveal, proposed): "player_sides" -- every
# unit on a side that has at least one player-controlled unit; or
# "player_controlled" -- only those units. Radius = the unit type's
# sight_range_m (data/units/<type>.json, Track S's) x vision.sight_range_scale.
#
# LINE OF SIGHT (Alex: "terrain, trees and buildings block sight"; data
# vision.line_of_sight, a switch):
#   "none"           a radius per unit, nothing more (the first option)
#   "terrain"        each unit's circle is cut by its VIEWSHED over the terrain's
#                    height levels: the part of the circle its eye can see
#   "terrain_trees"  the same with every tree canopy an opaque column
# The viewshed (fog_viewshed.gd) needs the terrain: attach_terrain(t) (the fog
# layer does it in setup). Each unit gets an EYE: a ground unit's eye_height_m of
# its domain above the ground, an aircraft's altitude band height (absolute, so
# the terrain is mostly below it). A unit's shed is cached and reused until the
# unit moves recompute_move_m or its eye height changes recompute_height_m.
#   is_visible(p)            GROUND: inside a shed (or a circle, without line of sight)
#   target_visible(x, y, h)  a TARGET h metres above the ground there: visible_from
#                            from each revealing eye in range -- a plane overhead
#                            is seen from a valley though the ground under it is not
#   shows_unit / unit_visible  judge enemy units as targets at their own eye height
# The fog mask (fog_layer.gd) draws the units that have a shed as shapes and the
# rest as circles (mask_circles leaves the shed units out; los_circles lists them).
#
# THE MASK (CPU twin of fog_mask.gdshader). Every frame the fog layer draws a
# CLAMPED SIGNED DISTANCE FIELD of the vision edge into a small texture:
#   m(p) = max over circles of clamp(0.5 + (r - |p - c|) / (2 range), 0, 1)
# in mask pixels, so m >= 0.5 exactly on the union of the circles (the max is
# what makes it exact: an additive or alpha union would bulge where two soft
# edges overlap), m = 1 deeper than `range` inside, 0 farther than `range`
# outside. mask_circles() puts the circles into mask pixels through the
# camera's canvas transform; mask_value() evaluates the shader's formula.
# Shapes (line of sight) go through the same clamped field: fog_los_*.gdshader.

const CameraData = preload("res://scripts/world/camera_data.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")

const REVEAL_PLAYER_SIDES := "player_sides"
const REVEAL_PLAYER_CONTROLLED := "player_controlled"
const LOS_NONE := "none"
const LOS_TERRAIN := "terrain"
const LOS_TREES := "terrain_trees"
const LOS_MODES := [LOS_NONE, LOS_TERRAIN, LOS_TREES]
const CONTROLLER_PLAYER := "player"   # Track S's Unit.CONTROLLER_PLAYER value
const MAX_SHADER_CIRCLES := 64        # fog_mask.gdshader's uniform array size

var data: CameraData
var reveal: String
var sight_scale: float
var line_of_sight: String
var max_circles: int
var eye_heights: Dictionary             # domain -> metres above the surface (not "air")
var cell_m: float
var step_cells: float
var spacing_cells: float
var eye_clear_m: float
var rim_m: float
var canopy_scale: float
var margin_m: float
var exact_below: float
var recompute_move_m: float
var recompute_height_m: float
var budget_ms: float                    # per update_from_world, all units; 0: whole sheds at once
var errors: Array[String] = []

var terrain: Object = null              # the height source, set by attach_terrain
var viewshed: FogViewshed = null        # built the first time line of sight is on

var circles: Array = []   # [{id: String, x: float, y: float, r: float, eye_agl: float, shed: Shed?}] metres
# The time the circles were sampled at (update_from_world): < 0 means the
# units' current state. shows_unit / unit_visible sample enemies at the same t,
# so a marker and the fog edge agree frame by frame during the resolve.
var sample_t := -1.0
var sample_source := "history"
# Counts for the report: sheds computed and reused by update_from_world, and the
# milliseconds the computes took.
var stats := {"computed": 0, "reused": 0, "ms": 0.0, "last_ms": 0.0, "pending": 0}

var _sheds := {}          # circle id -> {shed, r, abs, job: the unfinished next shed or null}
var _budget_left_us := 0

func _init(fog_data: CameraData = null) -> void:
	data = fog_data if fog_data != null else CameraData.new(CameraData.FOG_PATH)
	reveal = data.text("vision.reveal")
	if reveal != REVEAL_PLAYER_SIDES and reveal != REVEAL_PLAYER_CONTROLLED:
		_err("vision.reveal must be '%s' or '%s', not '%s'" % [REVEAL_PLAYER_SIDES, REVEAL_PLAYER_CONTROLLED, reveal])
	sight_scale = data.num("vision.sight_range_scale")
	if not (sight_scale > 0.0):
		_err("vision.sight_range_scale must be positive, got %s" % sight_scale)
	line_of_sight = data.text("vision.line_of_sight")
	if not LOS_MODES.has(line_of_sight):
		_err("vision.line_of_sight must be one of %s, not '%s'" % [LOS_MODES, line_of_sight])
	eye_heights = data.dict("vision.eye_height_m")
	if not eye_heights.has("ground"):
		_err("vision.eye_height_m needs a 'ground' entry (the default for any domain it does not name)")
	max_circles = data.integer("mask.max_circles")
	if max_circles < 1 or max_circles > MAX_SHADER_CIRCLES:
		_err("mask.max_circles must be 1..%d, got %d" % [MAX_SHADER_CIRCLES, max_circles])
	cell_m = data.num("viewshed.cell_m")
	step_cells = data.num("viewshed.step_cells")
	spacing_cells = data.num("viewshed.ray_spacing_cells")
	eye_clear_m = data.num("viewshed.eye_clear_m")
	rim_m = data.num("viewshed.rim_m")
	canopy_scale = data.num("viewshed.canopy_radius_scale")
	margin_m = data.num("viewshed.map_margin_m")
	exact_below = data.num("viewshed.exact_below_factor")
	recompute_move_m = data.num("viewshed.recompute_move_m")
	recompute_height_m = data.num("viewshed.recompute_height_m")
	budget_ms = data.num("viewshed.budget_ms")

func ok() -> bool:
	return errors.is_empty() and data.ok() and (viewshed == null or viewshed.ok())

func _err(message: String) -> void:
	errors.append(message)
	push_error("FogVision: " + message)

# --- line of sight --------------------------------------------------------------------

# The terrain the viewsheds read (heights and trees). The fog layer passes its own.
func attach_terrain(t: Object) -> void:
	if t == terrain:
		return
	terrain = t
	viewshed = null
	_sheds.clear()

# Switch the rule at run time ("none", "terrain" or "terrain_trees"). Returns
# false (and records an error) for any other value.
func set_line_of_sight(mode: String) -> bool:
	if not LOS_MODES.has(mode):
		_err("line of sight must be one of %s, not '%s'" % [LOS_MODES, mode])
		return false
	if mode != line_of_sight:
		line_of_sight = mode
		_sheds.clear()
		if viewshed != null:
			viewshed.canopy = (mode == LOS_TREES)
		for c: Dictionary in circles:
			c.erase("shed")
		_attach_sheds()
	return true

# Is line of sight on and able to work (it needs a terrain)?
func los_on() -> bool:
	return line_of_sight != LOS_NONE and terrain != null

# The viewshed engine, built on first use (the grids are a few MB).
func engine() -> FogViewshed:
	if viewshed == null and terrain != null:
		viewshed = FogViewshed.new(cell_m, step_cells, spacing_cells, eye_clear_m, rim_m, exact_below)
		viewshed.attach_terrain(terrain, canopy_scale, margin_m)
		viewshed.canopy = (line_of_sight == LOS_TREES)
		if not viewshed.ok():
			errors.append_array(viewshed.errors)
	return viewshed

# Ground height above sea level at a point, metres (0 without a terrain).
func ground_at(x: float, y: float) -> float:
	var vs := engine()
	return vs.ground_at(x, y) if vs != null else 0.0

# --- which units reveal ---------------------------------------------------------------

# Sides that reveal under "player_sides": every side with a player-controlled unit.
static func player_sides(world: Object) -> Dictionary:
	var sides := {}
	for u: Object in world.units.values():
		if str(u.controller) == CONTROLLER_PLAYER:
			sides[str(u.side)] = true
	return sides

func reveals(u: Object, sides: Dictionary) -> bool:
	if reveal == REVEAL_PLAYER_CONTROLLED:
		return str(u.controller) == CONTROLLER_PLAYER
	return sides.has(str(u.side))

# A unit's sight radius in metres: its type's sight_range_m x the scale knob.
func sight_radius_m(u: Object) -> float:
	return float(u.def.sight_range_m) * sight_scale

# --- eye heights ----------------------------------------------------------------------------

# A unit's eye (and own top, as a target) in metres ABOVE THE GROUND at (x, y):
# the domain's eye_height_m for a ground or sea unit; for an aircraft its band's
# height -- absolute above sea level for the air bands (the ground is subtracted
# here), above the terrain for a band whose reference is "terrain".
# `height_m` is the sampled height (World.sample), NAN for the band's own.
func unit_agl(world: Object, u: Object, x: float, y: float, band: String = "", height_m: float = NAN) -> float:
	var domain := str(u.def.domain)
	if domain != "air":
		return float(eye_heights.get(domain, eye_heights["ground"]))
	if band == "":
		band = str(u.altitude_band)
	var h := height_m if not is_nan(height_m) else float(world.band_height(band))
	var ref := "sea_level"
	var rules: Variant = world.get("rules")
	if rules != null:
		ref = str(rules.band_reference.get(band, "sea_level"))
	if ref == "terrain":
		return h
	return maxf(h - ground_at(x, y), 0.0)

# The state update_from_world and shows_unit judge a unit by: where it is `t`
# seconds into the resolve (World.sample), or now when t < 0.
func _state(world: Object, u: Object, t: float, source: String) -> Dictionary:
	if t >= 0.0:
		var s: Dictionary = world.sample(u.id, t, source)
		if s.has("x"):
			return {"x": float(s["x"]), "y": float(s["y"]), "band": str(s.get("altitude_band", u.altitude_band)),
				"height_m": float(s.get("height_m", NAN))}
	return {"x": float(u.x), "y": float(u.y), "band": str(u.altitude_band), "height_m": NAN}

# --- circles ---------------------------------------------------------------------------

# Rebuild the circles from the World's revealing units. t < 0: where the units
# are now; t >= 0: World.sample(id, t, source) -- the resolve animation
# ("history") or the plan preview ("plan"). With line of sight on, each circle
# gets its shed (cached while the unit hardly moves).
func update_from_world(world: Object, t: float = -1.0, source: String = "history") -> void:
	circles.clear()
	sample_t = t
	sample_source = source
	var sides := player_sides(world)
	var los := los_on()
	for u: Object in world.units.values():
		if not reveals(u, sides):
			continue
		var st := _state(world, u, t, source)
		var agl := unit_agl(world, u, st.x, st.y, st.band, st.height_m) if los else float(eye_heights.get(str(u.def.domain), eye_heights["ground"]))
		circles.append({"id": str(u.id), "x": st.x, "y": st.y, "r": sight_radius_m(u), "eye_agl": agl})
	if circles.size() > max_circles:
		push_warning("FogVision: %d revealing units, the mask draws the first %d (mask.max_circles)" % [circles.size(), max_circles])
	_attach_sheds()

# Circles given directly: [{x, y, r} (+ id, eye_agl)] in metres. An eye_agl is the
# eye's height above the ground there (default: the ground domain's eye height).
func set_circles(list: Array) -> void:
	circles.clear()
	for c: Dictionary in list:
		circles.append({"id": str(c.get("id", "")), "x": float(c["x"]), "y": float(c["y"]), "r": float(c["r"]),
			"eye_agl": float(c.get("eye_agl", eye_heights["ground"]))})
	_attach_sheds()

# Give every circle its shed when line of sight is on; drop the cache entries of
# circles that are gone.
func _attach_sheds() -> void:
	if not los_on():
		return
	var vs := engine()
	if vs == null or not vs.ok():
		return
	var seen := {}
	var i := 0
	_budget_left_us = int(budget_ms * 1000.0)
	stats.pending = 0
	for c: Dictionary in circles:
		var key: String = c.id if c.id != "" else "#%d" % i
		i += 1
		seen[key] = true
		c["shed"] = _shed_for(key, c, vs)
	for key: String in _sheds.keys():
		if not seen.has(key):
			_sheds.erase(key)

# The shed a circle is drawn with. A shed is reused while its unit stays within
# recompute_move_m and recompute_height_m of where it was made. Otherwise a new one is
# swept: all at once (budget_ms 0, or the unit has none yet), or in slices of the
# frame's budget while the old one keeps being drawn -- a sweep in progress always
# finishes (it was right where it started) and the next starts from the unit's new
# place, so a moving unit's shed trails it by about one sweep.
func _shed_for(key: String, c: Dictionary, vs: FogViewshed) -> FogViewshed.Shed:
	var eye := Vector2(c.x, c.y)
	var abs_eye: float = vs.ground_at(c.x, c.y) + float(c.eye_agl)
	var entry: Dictionary = _sheds.get(key, {})
	var shed: FogViewshed.Shed = entry.get("shed")
	var job: FogViewshed.Shed = entry.get("job")
	if job == null and shed != null and entry.r == c.r and absf(entry.abs - abs_eye) <= recompute_height_m and shed.eye.distance_to(eye) <= recompute_move_m:
		stats.reused += 1
		return shed
	var t0 := Time.get_ticks_usec()
	if job == null:
		job = vs.begin(eye, float(c.eye_agl), float(c.r))
		entry = {"shed": shed, "job": job, "r": c.r, "abs": abs_eye}
		_sheds[key] = entry
	# Sweep: unlimited when the unit has nothing to show yet or slicing is off.
	var unlimited := shed == null or budget_ms <= 0.0
	var done := vs.step(job, 1 << 60 if unlimited else maxi(_budget_left_us, 0))
	var spent := Time.get_ticks_usec() - t0
	stats.ms += spent / 1000.0
	if not unlimited:
		_budget_left_us -= spent
	if done:
		stats.computed += 1
		stats.last_ms = job.compute_ms
		entry["shed"] = job
		entry["job"] = null
		entry["r"] = c.r
		entry["abs"] = abs_eye
		return job
	stats.pending += 1
	return shed

# The circles that have a shed, in order: the shapes the mask draws.
func los_circles() -> Array:
	var out: Array = []
	for c: Dictionary in circles:
		if c.has("shed"):
			out.append(c)
	return out

# --- the query ------------------------------------------------------------------------

# Is the GROUND at the point (metres) in sight? The edge counts as inside.
func is_visible(p: Vector2) -> bool:
	return is_visible_xy(p.x, p.y)

func is_visible_xy(x: float, y: float) -> bool:
	for c: Dictionary in circles:
		var shed: Variant = c.get("shed")
		if shed != null:
			if (shed as FogViewshed.Shed).visible_ground(x, y):
				return true
			continue
		var dx: float = x - c.x
		var dy: float = y - c.y
		var r: float = c.r
		if dx * dx + dy * dy <= r * r and not _sight_blocked(c, x, y):
			return true
	return false

# Is a TARGET `agl` metres above the ground at (x, y) in sight? Without line of
# sight, the radius test; with it, visible_from each revealing eye in range.
func target_visible(x: float, y: float, agl: float) -> bool:
	var los := los_on()
	var vs := engine() if los else null
	for c: Dictionary in circles:
		var dx: float = x - c.x
		var dy: float = y - c.y
		var r: float = c.r
		if dx * dx + dy * dy > r * r:
			continue
		if vs == null or vs.visible_from(Vector2(c.x, c.y), float(c.eye_agl), Vector2(x, y), agl):
			return true
	return false

# Distance (metres) from the point to the vision edge, positive inside:
# max over circles of r - |p - c|. Ignores line of sight (the circle's edge).
func signed_distance_m(x: float, y: float) -> float:
	var best := -INF
	for c: Dictionary in circles:
		best = maxf(best, float(c.r) - sqrt((x - c.x) * (x - c.x) + (y - c.y) * (y - c.y)))
	return best

# Should a unit's marker be drawn? Units of a revealing side always are; any
# other unit only inside vision. Its position is where the last
# update_from_world sampled the world (sample_t), unless `at` (metres) says. With
# line of sight the unit is judged as a TARGET at its own height (a tank's top,
# a plane's altitude), not by the ground under it.
func shows_unit(world: Object, unit_id: String, at: Variant = null) -> bool:
	var u: Object = world.units.get(unit_id)
	if u == null:
		return false
	if reveals(u, player_sides(world)):
		return true
	var st := _state(world, u, sample_t, sample_source)
	var x: float = st.x
	var y: float = st.y
	if at is Vector2:
		x = (at as Vector2).x
		y = (at as Vector2).y
	if not los_on():
		return is_visible_xy(x, y)
	return target_visible(x, y, unit_agl(world, u, x, y, st.band, st.height_m))

# Track U's hook, ready to plug in: `ui.marker_layer.unit_visible =
# vision.unit_visible(world)` -- a Callable taking a unit id. It reads the
# circles live, so keep calling update_from_world as units move.
func unit_visible(world: Object) -> Callable:
	return func(unit_id: String) -> bool: return shows_unit(world, unit_id)

# THE SEAM, for a circle without a shed: does anything block the line from the
# circle's unit to (x, y)? No: a circle with no shed has no line-of-sight rule
# (line_of_sight "none", or no terrain). With a shed, the shed decides.
func _sight_blocked(c: Dictionary, x: float, y: float) -> bool:
	var shed: Variant = c.get("shed")
	if shed == null:
		return false
	return not (shed as FogViewshed.Shed).visible_ground(x, y)

# --- the mask's geometry (CPU twin of fog_mask.gdshader) ------------------------------------

# The circles in MASK pixels: centre through the canvas transform (world px ->
# screen px) times mask_scale, radius times the transform's scale. At most
# max_circles of them; the units that have a shed are drawn as shapes, not here.
# Vector4(x, y, r, 0).
func mask_circles(px_per_m: float, canvas_xf: Transform2D, mask_scale: float) -> PackedVector4Array:
	var out := PackedVector4Array()
	var zoom := canvas_xf.x.length()
	for c: Dictionary in circles:
		if out.size() >= max_circles:
			break
		if c.has("shed"):
			continue
		var sp := canvas_xf * Vector2(float(c.x) * px_per_m, float(c.y) * px_per_m)
		out.append(Vector4(sp.x * mask_scale, sp.y * mask_scale, float(c.r) * px_per_m * zoom * mask_scale, 0.0))
	return out

# The shader's value at mask pixel p: max over circles of the clamped signed
# distance, `range_mask` mask px either side of the edge.
static func mask_value(mcircles: PackedVector4Array, p: Vector2, range_mask: float) -> float:
	var m := 0.0
	for c in mcircles:
		var d := p.distance_to(Vector2(c.x, c.y))
		m = maxf(m, clampf(0.5 + (c.z - d) / (2.0 * range_mask), 0.0, 1.0))
	return m
