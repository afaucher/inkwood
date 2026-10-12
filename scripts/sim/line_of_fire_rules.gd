extends RefCounted

# The line-of-fire model's constants, read from data/sim/line_of_fire.json (builder LOF1, stage 1, 2026-10-11; every value there is
# PROPOSED and carries its reason). Same rules as the other sim data (records.gd): a missing field is an error, never a default; a
# tunable without a provenance is an error. The model is documented at the top of scripts/sim/line_of_fire.gd and height_grid.gd.
#
#   var rules := LineOfFireRules.new()
#   if not rules.ok(): ...                   # rules.errors says what is wrong
#   rules.cell_m, rules.block_m, rules.material_id("stone"), rules.stop_chance, ...
#
# `source` may also be an already-parsed Dictionary (tests build variants that way without writing files).

const Records = preload("res://scripts/sim/records.gd")
const Rounds = preload("res://scripts/sim/rounds.gd")

const PATH := "res://data/sim/line_of_fire.json"

# The CELL KINDS the code builds with: the first six ids of data `materials`, checked on load. Their NAMES are the round model's one vocabulary for what a
# round hits (data/sim/rounds.json vocabulary.materials; builder G3, 2026-10-12): GROUND is open ground (earth), TIMBER a house (wood), EARTHWORKS the
# sandbags (raised earth), TREES a canopy (wood). Two kinds can share a name; the ids stay apart because a vehicle stands ON open ground and UNDER a sandbag.
const GROUND := 0
const WATER := 1
const STONE := 2
const TIMBER := 3
const EARTHWORKS := 4
const TREES := 5
const FIXED_MATERIALS := ["earth", "water", "stone", "wood", "earth", "wood"]

# The flag bit of a cell's material byte: a surface a unit stands on (the bridge's deck), not an obstacle to stand beside.
const FLAG_DECK := 0x10
const MATERIAL_MASK := 0x0F

var enabled: bool = false
var cell_m: float = NAN
var block_m: float = NAN
var materials: Array[String] = []
var wall_material: int = STONE
var house_material: int = TIMBER
var water_margin_m: float = NAN
var canopy_base_frac: float = NAN
var stop_chance: float = NAN
var scale_by_chord: bool = true
var roll_salt: int = 0
var row_spacing_m: float = NAN
var col_spacing_m: float = NAN
var max_rows: int = 0
var max_cols: int = 0
var row_edge_inset_m: float = NAN
var clear_eps_m: float = NAN
# STAGE 2 (builder LOF2, decision line-of-fire, PROPOSED numbers): which parts of a unit are no target (a level deck), and the odds model.
var not_target_parts: Array[String] = []
var odds_aim: String = ""                 # "visible_centroid" | "silhouette_centre": where the gunner aims on the target
var odds_landing_attempts: int = 0        # draws a miss may take to land outside the visible parts before it is placed by hand
var odds_miss_run_m: float = NAN          # how far past the target a round that missed flies, looking for the first thing it meets
var odds_landing_salt: int = 0            # mixed into the seed of the round's own stream (where it lands), never the combat stream
var odds_roll_key_salt: int = 0           # mixed into the key the trees' rolls on a shot's lines are made from
var spreads: Dictionary = {}              # weapon id -> {spread_mrad, target, range_m, elevation_deg, odds} (the straight rounds' angular spread, and the reference case it was calibrated on)
var errors: Array[String] = []

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<line of fire dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a line-of-fire source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		enabled = r.boolean(d, "enabled", "enabled")
		var g: Dictionary = r.section(d, "grid", "grid")
		cell_m = r.number(g, "cell_m", "grid.cell_m", 0.25, 8.0)
		block_m = r.number(g, "block_m", "grid.block_m", 1.0, 256.0)
		_read_materials(r, d)
		var s: Dictionary = r.section(d, "scenery", "scenery")
		wall_material = _material_named(r, r.record(s, "wall_material", "scenery.wall_material"), "scenery.wall_material")
		house_material = _material_named(r, r.record(s, "house_material", "scenery.house_material"), "scenery.house_material")
		var w: Dictionary = r.section(d, "water", "water")
		water_margin_m = r.number(w, "margin_m", "water.margin_m", 0.0)
		var c: Dictionary = r.section(d, "canopy", "canopy")
		canopy_base_frac = r.number(c, "base_frac", "canopy.base_frac", 0.0, 0.95)
		stop_chance = r.number(c, "stop_chance", "canopy.stop_chance", 0.0, 1.0)
		scale_by_chord = r.boolean(c, "scale_by_chord", "canopy.scale_by_chord")
		roll_salt = r.integer(c, "roll_salt", "canopy.roll_salt", 0)
		var sm: Dictionary = r.section(d, "sampling", "sampling")
		row_spacing_m = r.number(sm, "row_spacing_m", "sampling.row_spacing_m", 0.05)
		col_spacing_m = r.number(sm, "col_spacing_m", "sampling.col_spacing_m", 0.05)
		max_rows = r.integer(sm, "max_rows", "sampling.max_rows", 1)
		max_cols = r.integer(sm, "max_cols", "sampling.max_cols", 1)
		row_edge_inset_m = r.number(sm, "row_edge_inset_m", "sampling.row_edge_inset_m", 0.0, 0.5)
		var t: Dictionary = r.section(d, "trace", "trace")
		clear_eps_m = r.number(t, "clear_eps_m", "trace.clear_eps_m", 0.0, 0.1)
		var tg: Dictionary = r.section(d, "targets", "targets")
		var nt: Variant = r.record(tg, "not_targets", "targets.not_targets")
		if nt is Array:
			for part: Variant in nt:
				not_target_parts.append(str(part))
		elif typeof(nt) != TYPE_NIL:
			r.err("'targets.not_targets' must be a list of part names")
		_read_odds(r, d)
		_check(r)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

# The odds section: how a straight round's chance comes from the visible share, and where a miss lands (scripts/sim/line_of_fire_odds.gd).
func _read_odds(r: Records, d: Dictionary) -> void:
	var o: Dictionary = r.section(d, "odds", "odds")
	var aim: Variant = r.record(o, "aim", "odds.aim")
	if typeof(aim) != TYPE_NIL:
		odds_aim = str(aim)
		if not ["visible_centroid", "silhouette_centre"].has(odds_aim):
			r.err("'odds.aim' must be visible_centroid or silhouette_centre, got %s" % odds_aim)
	odds_landing_attempts = r.integer(o, "landing_attempts", "odds.landing_attempts", 1)
	odds_miss_run_m = r.number(o, "miss_run_m", "odds.miss_run_m", 1.0, 20000.0)
	odds_landing_salt = r.integer(o, "landing_salt", "odds.landing_salt", 0)
	odds_roll_key_salt = r.integer(o, "roll_key_salt", "odds.roll_key_salt", 0)
	var ws: Dictionary = r.section(o, "weapons", "odds.weapons")
	for wid: Variant in ws:
		var id := str(wid)
		if id.begins_with("_"):
			continue
		var e: Variant = ws[wid]
		if not (e is Dictionary):
			r.err("'odds.weapons.%s' is not an object" % id)
			continue
		var ed: Dictionary = e
		var ref: Dictionary = r.section(ed, "reference", "odds.weapons.%s.reference" % id)
		var tv: Variant = r.record(ref, "target", "odds.weapons.%s.reference.target" % id)
		spreads[id] = {
			"spread_mrad": r.number(ed, "spread_mrad", "odds.weapons.%s.spread_mrad" % id, 0.01, 1000.0),
			"target": str(tv) if typeof(tv) != TYPE_NIL else "",
			"range_m": r.number(ref, "range_m", "odds.weapons.%s.reference.range_m" % id, 1.0),
			"elevation_deg": r.number(ref, "elevation_deg", "odds.weapons.%s.reference.elevation_deg" % id, -89.0, 89.0),
			"odds": r.number(ref, "odds", "odds.weapons.%s.reference.odds" % id, 0.0, 1.0),
		}

# Does the weapon's round take the line-of-fire odds (it is in the table of straight rounds)?
func has_spread(weapon_id: String) -> bool:
	return spreads.has(weapon_id)

func _read_materials(r: Records, d: Dictionary) -> void:
	var v: Variant = r.record(d, "materials", "materials")
	if typeof(v) == TYPE_NIL:
		return
	if not (v is Array) or (v as Array).is_empty():
		r.err("'materials' must be a non-empty list of names")
		return
	var vocabulary: Array[String] = (Rounds.shared() as Rounds).materials
	for m: Variant in v:
		if not (m is String) or (m as String) == "" or not vocabulary.has(m):
			r.err("'materials' has a name that is not one of the round model's vocabulary %s (data/sim/rounds.json): %s" % [str(vocabulary), str(m)])
		else:
			materials.append(m)
	for i in FIXED_MATERIALS.size():
		if i >= materials.size() or materials[i] != FIXED_MATERIALS[i]:
			r.err("'materials' must begin %s (the code builds with those ids), got %s" % [str(FIXED_MATERIALS), str(materials)])
			return

func _material_named(r: Records, name: Variant, label: String) -> int:
	if typeof(name) == TYPE_NIL:
		return GROUND
	var i := materials.find(str(name))
	if i < 0:
		r.err("'%s' = '%s' is not one of the materials %s" % [label, str(name), str(materials)])
		return GROUND
	return i

func _check(r: Records) -> void:
	if not is_nan(cell_m) and not is_nan(block_m):
		var cells := block_m / cell_m
		if absf(cells - roundf(cells)) > 1e-9:
			r.err("grid.block_m (%s) must be a whole number of grid.cell_m (%s)" % [str(block_m), str(cell_m)])
		var chunk := 256.0
		if absf(chunk / block_m - roundf(chunk / block_m)) > 1e-9 or absf(chunk / cell_m - roundf(chunk / cell_m)) > 1e-9:
			r.err("grid.cell_m (%s) and grid.block_m (%s) must each divide the terrain chunk (256 m)" % [str(cell_m), str(block_m)])

# The first id of a material by name, -1 when the name is not in the data (earth is 0, wood is 3: a name can serve two kinds).
func material_id(name: String) -> int:
	return materials.find(name)

# The id a STAMPED box of this material puts in the grid: the sandbags' raised earth for earth (a ring of sandbags is not open ground), else the
# material's own first id.
func stamp_id(name: String) -> int:
	var i := materials.find(name)
	return EARTHWORKS if i == GROUND else i

# The name of a cell kind in the one vocabulary ("" when out of range): earth for open ground and for the sandbags.
func material_name(id: int) -> String:
	return materials[id] if id >= 0 and id < materials.size() else ""
