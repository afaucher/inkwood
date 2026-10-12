extends RefCounted

# THE ROUND MODEL, read from data/sim/rounds.json (decision round-model; builder G3, 2026-10-12). Alex (round-model): "a round per weapon with class,
# calibre, explosive, path, tracer and blast; a round x material table for impacts; armour and penetration later". Every weapon in data/units/*.json
# names its round (weapons[].round); the cruiser's Main Guns and the bomb drop name theirs in the file's `specials`. Same rules as the other sim data
# (records.gd): a missing field is an error, never a default; a tunable without a provenance is an error.
#
#   var rounds := Rounds.shared()                 # the one the game reads (tests build their own: Rounds.new(path_or_dictionary))
#   rounds.ok(), rounds.errors
#   rounds.materials                              # the ONE vocabulary of what a round hits: metal, stone, wood, earth, water
#   rounds.has_round("cannon_medium"), rounds.round_ids()
#   var r: Rounds.Round = rounds.round_of("cannon_medium")      # .round_class .calibre .explosive .path .tracer .blast
#   rounds.impact_class("bullet")                 # "bullet" for a bullet, else the calibre: the size class of an impact
#   rounds.special_round("main_guns")             # the round a special fires
#   rounds.blast_table("shell_large")             # the blast table a round points at: Array of [distance_m, pips]; [] when it has none
#   rounds.weapon_round("turret_gun")             # the round a weapon id fires (the unit files' weapons[].round), "" when unknown
#   rounds.weapon_tracer("wing_guns")             # whether that round draws a tracer (data/fx/fx.json tracers.enabled is the other half)
#
# THE WEAPON INDEX (weapon id -> round id) is built from the unit files the first time a weapon id is asked about (a directory scan of
# data/units/), and fed by `note_weapons` whenever a unit definition is at hand (the effects feed notes every unit of its World, so a shipped
# game does not depend on the directory scan alone). A weapon id that two unit types give different rounds is an error the tests catch: the
# effects layer asks by weapon id alone.

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/rounds.json"
const UNITS_DIR := "res://data/units"

# One round's record. `blast` is {} when the round has no blast table, else the pointer {file, path} as the data gives it.
class Round:
	var id: String = ""
	var round_class: String = ""
	var calibre: String = ""
	var explosive: bool = false
	var path: String = ""
	var tracer: bool = false
	var blast: Dictionary = {}

var classes: Array[String] = []
var calibres: Array[String] = []
var paths: Array[String] = []
var materials: Array[String] = []
var rounds: Dictionary = {}         # id -> Round
var specials: Dictionary = {}       # special id -> round id
var errors: Array[String] = []

var _weapon_index: Dictionary = {}  # weapon id -> round id ("" noted as conflicting is kept in _conflicts)
var _conflicts: Array[String] = []
var _scanned: bool = false

static var _shared: RefCounted = null

static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/sim/rounds.gd").new()
	return _shared

# `source`: a path or an already-parsed Dictionary (tests build variants that way without writing files).
func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<rounds dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a rounds source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		var v: Dictionary = r.section(d, "vocabulary", "vocabulary")
		classes = _names(r, v, "classes")
		calibres = _names(r, v, "calibres")
		paths = _names(r, v, "paths")
		materials = _names(r, v, "materials")
		var rs: Dictionary = r.section(d, "rounds", "rounds")
		if rs.is_empty():
			r.err("'rounds' has no rounds")
		for id: String in rs:
			if id.begins_with("_"):
				continue
			if not (rs[id] is Dictionary):
				r.err("round '%s' is not an object" % id)
				continue
			rounds[id] = _read_round(r, id, rs[id])
		var sp: Dictionary = r.section(d, "specials", "specials")
		for sid: String in sp:
			if sid.begins_with("_"):
				continue
			var rid := r.id_value(sp, sid, "specials.%s" % sid, rounds.keys())
			if rid != "":
				specials[sid] = rid
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

func _names(r: Records, d: Dictionary, key: String) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = r.record(d, key, "vocabulary.%s" % key)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'vocabulary.%s' must be a non-empty list of names" % key)
		return out
	for item: Variant in v:
		if not (item is String) or (item as String) == "" or out.has(item):
			r.err("'vocabulary.%s' has a name that is not a unique, non-empty string: %s" % [key, str(item)])
		else:
			out.append(item)
	return out

func _read_round(r: Records, id: String, d: Dictionary) -> Round:
	var o := Round.new()
	o.id = id
	var p := "rounds.%s." % id
	o.round_class = r.id_value(d, "class", p + "class", classes)
	o.calibre = r.id_value(d, "calibre", p + "calibre", calibres)
	o.explosive = r.boolean(d, "explosive", p + "explosive")
	o.path = r.id_value(d, "path", p + "path", paths)
	o.tracer = r.boolean(d, "tracer", p + "tracer")
	var b: Variant = r.record(d, "blast", p + "blast")
	if b is Dictionary:
		var bd: Dictionary = b
		if not (bd.get("file") is String) or not (bd.get("path") is Array) or (bd["path"] as Array).is_empty():
			r.err("'%sblast' is \"none\" or a pointer {file, path: [keys...]}, got %s" % [p, str(b)])
		else:
			o.blast = bd
	elif typeof(b) != TYPE_NIL and not (b is String and b == "none"):
		r.err("'%sblast' is \"none\" or a pointer {file, path: [keys...]}, got %s" % [p, str(b)])
	if o.blast.is_empty() == false and not o.explosive:
		r.err("round '%s' is not explosive and so has no blast table" % id)
	return o

# --- Questions ----------------------------------------------------------------------------------------------

func has_round(id: String) -> bool:
	return rounds.has(id)

func round_ids() -> Array[String]:
	var out: Array[String] = []
	for k: String in rounds:
		out.append(k)
	return out

func round_of(id: String) -> Round:
	return rounds.get(id, null)

# The size class of an impact: "bullet" for a bullet (its own small mark), else the round's calibre.
func impact_class(id: String) -> String:
	var o: Round = round_of(id)
	if o == null:
		return ""
	return "bullet" if o.round_class == "bullet" else o.calibre

# The size class of a muzzle: the round's calibre.
func muzzle_class(id: String) -> String:
	var o: Round = round_of(id)
	return o.calibre if o != null else ""

func special_round(special_id: String) -> String:
	return str(specials.get(special_id, ""))

# The blast table a round points at, as [[distance_m, pips], ...] (smallest distance first), [] when it has none or the pointer does not resolve.
func blast_table(id: String) -> Array:
	var o: Round = round_of(id)
	if o == null or o.blast.is_empty():
		return []
	var file := "res://" + str(o.blast["file"])
	if not FileAccess.file_exists(file):
		return []
	var node: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	for k: Variant in (o.blast["path"] as Array):
		if node is Dictionary and (node as Dictionary).has(str(k)):
			node = (node as Dictionary)[str(k)]
		else:
			return []
	if node is Dictionary and (node as Dictionary).has("value"):
		node = (node as Dictionary)["value"]
	return node if node is Array else []

# --- The weapon index -----------------------------------------------------------------------------------------

# Records the rounds of one unit type's weapons (`weapon_values`: the validated weapons section, an Array of Dictionaries with `id` and `round`).
func note_weapons(unit_id: String, weapon_values: Array) -> void:
	for w: Variant in weapon_values:
		if not (w is Dictionary):
			continue
		var wid := str((w as Dictionary).get("id", ""))
		var rid := str((w as Dictionary).get("round", ""))
		if wid == "" or rid == "":
			continue
		if _weapon_index.has(wid) and str(_weapon_index[wid]) != rid:
			_conflicts.append("%s (%s): %s is %s, was %s" % [wid, unit_id, wid, rid, str(_weapon_index[wid])])
			continue
		_weapon_index[wid] = rid

# Weapon ids that two unit types gave different rounds (an error the unit test reports).
func conflicts() -> Array[String]:
	_scan()
	return _conflicts

func weapon_round(weapon_id: String) -> String:
	if not _weapon_index.has(weapon_id):
		_scan()
	return str(_weapon_index.get(weapon_id, ""))

func weapon_tracer(weapon_id: String) -> bool:
	var o: Round = round_of(weapon_round(weapon_id))
	return o != null and o.tracer

# Every weapon id the unit files give a round that draws a tracer (the old data/fx/fx.json tracers.weapons list, now derived).
func tracer_weapons() -> Array[String]:
	_scan()
	var out: Array[String] = []
	for wid: String in _weapon_index:
		if weapon_tracer(wid):
			out.append(wid)
	out.sort()
	return out

func weapon_ids() -> Array[String]:
	_scan()
	var out: Array[String] = []
	for wid: String in _weapon_index:
		out.append(wid)
	out.sort()
	return out

# The unit files, read once for the index. Only what the index needs (weapons[].id and weapons[].round.value): validation is unit_def.gd's.
func _scan() -> void:
	if _scanned:
		return
	_scanned = true
	var files := DirAccess.get_files_at(UNITS_DIR)
	var n := 0
	for file: String in files:
		if not file.ends_with(".json") or file.begins_with("_"):
			continue
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [UNITS_DIR, file]))
		if not (v is Dictionary):
			continue
		n += 1
		var plain: Array = []
		for w: Variant in (v as Dictionary).get("weapons", []):
			if w is Dictionary:
				var rv: Variant = (w as Dictionary).get("round")
				plain.append({"id": (w as Dictionary).get("id", ""), "round": (rv as Dictionary).get("value", "") if rv is Dictionary else ""})
		note_weapons(file.get_basename(), plain)
	if n == 0:
		push_error("Rounds: no unit file was found in %s, so no weapon has a round (a shipped build needs data/* in the export filter)" % UNITS_DIR)
