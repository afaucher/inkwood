extends RefCounted

# THE FOREST FIRE'S NUMBERS (decision forest-fire, 2026-10-11): data/sim/fire.json read under the sim's data rules (records.gd: a missing
# field is an error, every tunable says where it came from, an unknown field is an error). The state and the turn step that use them are
# scripts/sim/fire.gd; this file only holds values and the small pure functions of them (the chances).
#
#   var rules := FireRules.new()                  # data/sim/fire.json (a Dictionary also works: a test's variant)
#   rules.ok()  rules.errors
#   rules.spread_p(gap_m)                         # the chance one burning tree lights one unlit tree `gap_m` away
#   rules.damage_p(edge_m)                        # the chance (one tree) a unit `edge_m` beyond a burning canopy loses a pip
#   rules.out_turn(lit_turn)                      # the last turn a tree lit in `lit_turn` burns

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/fire.json"

const DOMAINS := ["air", "ground", "sea"]
const MOBILITY := ["mobile", "static"]
const GAP_MEASURES := ["canopy_edge", "centre"]
const STARTS := ["next_turn", "same_turn"]
const LIT_T := ["seeded_in_turn", "turn_start"]
const SHAPES := ["linear"]
const COMBINES := ["independent"]
const KNOWN := ["ignite", "spread", "burn", "damage", "smoke", "burnt_cover"]
# The fields of each section (an unknown one is an error, like a misspelt top-level one).
const SECTION_KEYS := {
	"ignite": ["chance", "events", "radius_field", "crash_radius_m"],
	"spread": ["chance_touching", "reach_m", "fall", "gap_measure", "starts", "lit_t"],
	"burn": ["turns", "counts_lit_turn"],
	"damage": ["domains", "pips", "chance_near", "reach_m", "fade", "combine", "max_pips_per_unit_turn", "sample_s"],
	"smoke": ["denies_tracking", "reach_m", "domains", "mobility", "entry_step_s"],
	"burnt_cover": ["share_radius_m"],
}

var errors: Array[String] = []

# ignite
var ignite_chance: float = NAN
var ignite_events: Array[String] = []
var ignite_radius_field: String = ""
var crash_radius_m: float = NAN
# spread
var spread_chance: float = NAN
var spread_reach_m: float = NAN
var gap_measure: String = ""
var spread_starts: String = ""
var lit_t_mode: String = ""
# burn
var burn_turns: int = 0
var burn_counts_lit_turn: bool = false
# damage
var damage_domains: Array[String] = []
var damage_pips: int = 0
var damage_chance: float = NAN
var damage_reach_m: float = NAN
var damage_sample_s: float = NAN
var max_pips_per_unit_turn: int = 0
# smoke
var denies_tracking: bool = false
var smoke_reach_m: float = NAN
var smoke_domains: Array[String] = []
var smoke_mobility: Array[String] = []
var entry_step_s: float = NAN
# burnt cover
var burnt_share_radius_m: float = NAN

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<fire dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a fire source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		var ig := r.section(d, "ignite", "ignite")
		ignite_chance = r.number(ig, "chance", "ignite.chance", 0.0, 1.0)
		ignite_events = _strings(r, ig, "events", "ignite.events")
		ignite_radius_field = _text(r, ig, "radius_field", "ignite.radius_field")
		crash_radius_m = r.number(ig, "crash_radius_m", "ignite.crash_radius_m", 0.0)
		var sp := r.section(d, "spread", "spread")
		spread_chance = r.number(sp, "chance_touching", "spread.chance_touching", 0.0, 1.0)
		spread_reach_m = r.number(sp, "reach_m", "spread.reach_m", 0.001)
		r.id_value(sp, "fall", "spread.fall", SHAPES)
		gap_measure = r.id_value(sp, "gap_measure", "spread.gap_measure", GAP_MEASURES)
		spread_starts = r.id_value(sp, "starts", "spread.starts", STARTS)
		lit_t_mode = r.id_value(sp, "lit_t", "spread.lit_t", LIT_T)
		var bu := r.section(d, "burn", "burn")
		burn_turns = r.integer(bu, "turns", "burn.turns", 1)
		burn_counts_lit_turn = r.boolean(bu, "counts_lit_turn", "burn.counts_lit_turn")
		var dm := r.section(d, "damage", "damage")
		damage_domains = r.id_list(dm, "domains", "damage.domains", DOMAINS)
		damage_pips = r.integer(dm, "pips", "damage.pips", 1)
		damage_chance = r.number(dm, "chance_near", "damage.chance_near", 0.0, 1.0)
		damage_reach_m = r.number(dm, "reach_m", "damage.reach_m", 0.001)
		r.id_value(dm, "fade", "damage.fade", SHAPES)
		r.id_value(dm, "combine", "damage.combine", COMBINES)
		max_pips_per_unit_turn = r.integer(dm, "max_pips_per_unit_turn", "damage.max_pips_per_unit_turn", 1)
		damage_sample_s = r.number(dm, "sample_s", "damage.sample_s", 0.01)
		var sm := r.section(d, "smoke", "smoke")
		denies_tracking = r.boolean(sm, "denies_tracking", "smoke.denies_tracking")
		smoke_reach_m = r.number(sm, "reach_m", "smoke.reach_m", 0.0)
		smoke_domains = r.id_list(sm, "domains", "smoke.domains", DOMAINS)
		smoke_mobility = r.id_list(sm, "mobility", "smoke.mobility", MOBILITY)
		entry_step_s = r.number(sm, "entry_step_s", "smoke.entry_step_s", 0.01)
		var bc := r.section(d, "burnt_cover", "burnt_cover")
		burnt_share_radius_m = r.number(bc, "share_radius_m", "burnt_cover.share_radius_m", 0.0)
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not KNOWN.has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
		for sec: String in SECTION_KEYS:
			if d.get(sec) is Dictionary:
				for key: Variant in (d[sec] as Dictionary):
					var k2 := str(key)
					if not k2.begins_with("_") and not (SECTION_KEYS[sec] as Array).has(k2):
						r.err("unknown field '%s.%s' (misspelt?)" % [sec, k2])
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

static func _text(r: Records, d: Dictionary, key: String, label: String) -> String:
	var v: Variant = r.record(d, key, label)
	if v is String and str(v) != "":
		return str(v)
	if typeof(v) != TYPE_NIL:
		r.err("'%s' must be text" % label)
	return ""

static func _strings(r: Records, d: Dictionary, key: String, label: String) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = r.record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of text" % label)
		return out
	for item: Variant in v:
		if item is String and str(item) != "":
			out.append(str(item))
		else:
			r.err("'%s' has an entry that is not text: %s" % [label, str(item)])
	return out

# --- The chances ---------------------------------------------------------------------------------------------------------

# The chance one burning tree lights one unlit tree whose gap is `gap_m` (negative: overlapping canopies; the same as touching): the
# touching chance, falling linearly to 0 at spread.reach_m.
func spread_p(gap_m: float) -> float:
	var g := maxf(gap_m, 0.0)
	if g >= spread_reach_m:
		return 0.0
	return spread_chance * (1.0 - g / spread_reach_m)

# The chance (one burning tree) that a unit `edge_m` beyond its canopy edge (0 or less: under the canopy) loses a pip: damage.chance_near at the
# edge, falling linearly to 0 at damage.reach_m beyond it.
func damage_p(edge_m: float) -> float:
	var e := maxf(edge_m, 0.0)
	if e >= damage_reach_m:
		return 0.0
	return damage_chance * (1.0 - e / damage_reach_m)

# The last turn a tree lit in `lit_turn` burns.
func out_turn(lit_turn: int) -> int:
	return lit_turn + burn_turns - (1 if burn_counts_lit_turn else 0)

# Do units of this definition (domain, mobility) lose pips to a fire?
func hurts(def: Object) -> bool:
	return damage_domains.has(str(def.domain))

# Does smoke deny tracking of units of this definition?
func smoke_applies(def: Object) -> bool:
	return denies_tracking and smoke_domains.has(str(def.domain)) and smoke_mobility.has(str(def.mobility))
