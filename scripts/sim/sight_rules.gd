extends RefCounted

# WHAT A DOWNED UNIT STILL SEES (Track S-sight, 2026-10-10; values proposed in
# data/sim/sight.json, the rule is Alex's: "A destroyed plane keeps the fog away.
# Ideally we have this track the pilot. So a destroyed plane should loose the fog.
# One disabled and falling should keep it but with reduced distance until it hits.
# (take height into account too).")
#
# SIGHT FOLLOWS THE PILOT:
#   a live unit            its full sight, untouched
#   exploded, destroyed    full sight until the moment it went down (down_at), then none; a
#                          unit that went down in an earlier turn sees nothing at all. A tower
#                          or a battery at 0 pips is "destroyed" and sees nothing
#   out of control         (disabled and falling) a REDUCED radius that depends on its height
#                          above the ground, from the moment it went down until it hits:
#                              sight x falling_factor x min(height / falling_reference_height_m, 1)
#                          never below falling_floor_m while it is in the air
#   crashed                none from the instant its height reached 0
#   down, no fate          none (a unit marked down by hand, or by the placeholder rule)
#
# ONE FUNCTION, TWO READERS: the player's fog (fog_vision.gd, the playback time t) and the
# enemy AI's knowledge (ai_sense.gd, the state as it stands) both call radius_m, so a plane
# that stops seeing for one side stops seeing for the other.
#
#   var rules := SightRules.new()            # data/sim/sight.json
#   rules.radius_m(unit, base_m)             # the unit as it stands now
#   rules.radius_m(unit, base_m, t, h)       # t s into the last resolved turn (World.sample's
#                                            # clock), h the sampled height_m at that moment
#
# `base_m` is the unit's full radius in metres (its type's sight_range_m, times the fog's scale
# knob where the caller has one). Returns metres; 0 means it sees nothing and the caller leaves it
# out. Pure: reads the unit's down, fate, down_at and fall_height_m, writes nothing.

const Records = preload("res://scripts/sim/records.gd")
const Unit = preload("res://scripts/sim/unit.gd")

const PATH := "res://data/sim/sight.json"

var falling_factor: float = NAN          # the share of its sight a falling plane keeps, at the reference height or above
var falling_reference_m: float = NAN     # the height (m above the ground) at which that share applies in full
var falling_floor_m: float = NAN         # the least radius a plane still in the air keeps
var errors: Array[String] = []

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<sight dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a sight source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		falling_factor = r.number(d, "falling_factor", "falling_factor", 0.0, 1.0)
		falling_reference_m = r.number(d, "falling_reference_height_m", "falling_reference_height_m", 1.0)
		falling_floor_m = r.number(d, "falling_floor_m", "falling_floor_m", 0.0)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

# The radius, in metres, that `u` sees to at time `t` (seconds into the last resolved turn, the
# clock of World.sample; negative: the unit as it stands now), given its full radius `base_m`.
# `height_m` is the unit's height above the ground at that moment (World.sample's height_m);
# NAN takes the unit's own fall_height_m. Only a falling plane reads it.
func radius_m(u: Object, base_m: float, t: float = -1.0, height_m: float = NAN) -> float:
	if not bool(u.down):
		return base_m
	# The turn it went down in, before the moment it did: it was still flying, and saw as it did.
	var down_at := float(u.down_at)
	if t >= 0.0 and is_finite(down_at) and t < down_at:
		return base_m
	# Gone (exploded, destroyed) or marked down with no fate: the pilot sees nothing.
	var fate := str(u.fate)
	if fate != Unit.FATE_OUT_OF_CONTROL and fate != Unit.FATE_CRASHED:
		return 0.0
	if not ok():
		return 0.0
	# Falling, or crashed this turn and still falling at t. Height 0 (or unknown) is the ground.
	var h := height_m if is_finite(height_m) else float(u.fall_height_m)
	if not (h > 0.0):
		return 0.0
	var cap := base_m * falling_factor
	return clampf(cap * minf(h / falling_reference_m, 1.0), minf(falling_floor_m, cap), cap)
