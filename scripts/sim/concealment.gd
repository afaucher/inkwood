extends RefCounted

# CONCEALMENT (Track M2L, PROPOSED 2026-10-11, the coordinator's brief after the first Suppress report; numbers data/sim/concealment.json).
# A mobile ground unit standing in WOODS (the tree density at its place at or above cover_density_min) is seen by an observer only within
# radius_m of it -- or within the observer's own sight, if that is shorter -- unless it has just fired (scripts/sim/reveal.gd). ONE RULE, ASKED
# WHERE SIGHT IS JUDGED, by three callers that must agree:
#
#   the player's fog      scripts/render/fog_vision.gd shows_unit: a unit in cover is shown inside a reveal patch, or inside radius_m of a sight
#                         circle; the ground itself stays in sight (the fog is still the fog)
#   the enemy AI          scripts/sim/ai_sense.gd: a player's unit in cover is known inside radius_m of an AI unit's sight, or where it fired from
#   shared spotting       scripts/sim/spotting.gd _sees: a spotter sees a target unit in cover inside radius_m, or at any distance of its sight
#                         when the target is revealed to the spotter's side at that moment
#
#   var cover := Concealment.shared()                          # data/sim/concealment.json, read once
#   cover.covered(world, unit, x, y[, t])                      # is this unit hidden by cover where it stands (x, y) [at moment t]?
#   cover.sight_limit_m(world, unit, x, y, sight_m[, t])       # how far an observer of sight `sight_m` sees it: min(sight_m, radius_m) in cover
#
# The tree density is the World's own query (World.set_ground's woods function: scripts/world/ground_map.gd woods_at), so the sim never learns
# the terrain, and a World that was never given the ground (the Strike, the Intercept: no mobile ground unit) conceals nothing. Alex's rule that
# trees do not block sight for now stands: this is a spotting radius for small ground units, not a line of sight.
#
# THE FOREST FIRE (decision forest-fire, 2026-10-11): a BURNT-OUT tree takes its woods cover with it (Alex, "5 - yes"). When the World has a fire
# (world.fire, scripts/sim/fire.gd) the woods density at a point is scaled by the share of the trees within data/sim/fire.json burnt_cover.share_radius_m
# (PROPOSED 20 m) that are NOT burnt out at the moment asked about. SMOKE IS NOT COVER (Alex: "visible but untrackable"): a unit in smoke is seen exactly
# as it would be without it; what smoke denies is tracking (scripts/sim/spotting.gd, World._resolve_followed_drops, UiTarget). The moment is `t`, as
# everywhere in the sim: seconds into the last resolve, < 0 (the default) as the world stands. The ground movement rule (ground_rules.gd) is NOT
# scaled: trunks still slow a tank (PROPOSED).

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/concealment.json"

static var _shared: RefCounted = null

var on: bool = false
var radius_m: float = NAN
var cover_density_min: float = NAN
var domains: Array[String] = []
var mobility: Array[String] = []
var errors: Array[String] = []

# The one rule (data read on first use). A test that changes a value makes its own with Concealment.new(dictionary).
static func shared() -> RefCounted:
	if _shared == null:
		_shared = (load("res://scripts/sim/concealment.gd") as GDScript).new()
	return _shared

# Forget the shared rule (a test that rewrote the data file; the next shared() reads it again).
static func reset_shared() -> void:
	_shared = null

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<concealment dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a concealment source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		on = r.boolean(d, "on", "on")
		radius_m = r.number(d, "radius_m", "radius_m", 0.0)
		cover_density_min = r.number(d, "cover_density_min", "cover_density_min", 0.0, 1.0)
		domains = _strings(r, d, "domains")
		mobility = _strings(r, d, "mobility")
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not ["on", "radius_m", "cover_density_min", "domains", "mobility"].has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

static func _strings(r: Records, d: Dictionary, key: String) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = r.record(d, key, key)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of text" % key)
		return out
	for item: Variant in v:
		if item is String and str(item) != "":
			out.append(str(item))
		else:
			r.err("'%s' has an entry that is not text: %s" % [key, str(item)])
	return out

# Can a unit of this type hide in cover (its domain and mobility are listed)?
func applies(def: Object) -> bool:
	return ok() and on and domains.has(str(def.domain)) and mobility.has(str(def.mobility))

# Is the point in cover: the World has a tree-density query (World.set_ground) and the density there -- scaled by the share of the trees near it that
# have not burnt out at moment `t`, when the World has a fire -- is at least cover_density_min?
func in_cover(world: Object, x: float, y: float, t: float = -1.0) -> bool:
	if not (ok() and on) or world == null:
		return false
	var ground: Variant = world.get("ground")
	if ground == null or not (ground.woods_fn as Callable).is_valid():
		return false
	var density := float((ground.woods_fn as Callable).call(x, y))
	if density < cover_density_min:
		return false   # (burning down can only lower it)
	var fire: Variant = world.get("fire")
	if fire != null:
		density *= float(fire.burnt_scale(x, y, float(fire.moment(world, t))))
	return density >= cover_density_min

# Is this unit hidden by cover where it stands (x, y metres) at moment `t`?
func covered(world: Object, unit: Object, x: float, y: float, t: float = -1.0) -> bool:
	return unit != null and applies(unit.def) and in_cover(world, x, y, t)

# How far an observer whose sight is `sight_m` sees this unit at (x, y): its sight, or radius_m when the unit is in cover and that is shorter.
func sight_limit_m(world: Object, unit: Object, x: float, y: float, sight_m: float, t: float = -1.0) -> float:
	return minf(sight_m, radius_m) if covered(world, unit, x, y, t) else sight_m
