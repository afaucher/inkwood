extends RefCounted

# The AI's view of a weapon cone (Track E, proposed): which cone is a unit's
# FORWARD weapon, and whether a target is inside it. Alex's rule (design doc,
# 2026-10-09): a cone per weapon on hardpoints, the same cone in height, hits
# random-ish and likelier near the centre. The AI does not roll anything; it
# steers so the target is inside the cone and lets the shared firing rules
# (Track C) do the rest. Hardpoint offsets (a few metres) are ignored here.
#
# A cone is a Dictionary of the names Track C's def.weapons uses:
#   mount_deg         bearing of the cone's centre from the nose (0 = straight ahead)
#   half_across_deg   half angle across (horizontal)
#   elevation_deg     centre of the cone above the horizon
#   half_height_deg   half angle in height
#   range_m           reach (slant range)
# plus "source": "def" (the unit type's own weapons), "fallback" (the
# placeholders in data/sim/ai.json, for a type whose UnitDef has no weapons, or
# no weapons data yet)
# or "none" (the type has weapons but none points forward).
#
# def.weapons is read defensively: an Array (or a Dictionary of them) of
# Dictionaries or objects, any field possibly wrapped in a value record. Track C
# owns that shape; if it differs, this is the one place to adapt.

const JsMath = preload("res://scripts/core/js_math.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")

const SOURCE_DEF := "def"
const SOURCE_FALLBACK := "fallback"
const SOURCE_NONE := "none"

# The forward cone of a unit type: from def.weapons if the UnitDef has that
# property, else from the fallback table; {} if neither knows the type.
static func forward_cone(def: Object, type_id: String, params: AiParams) -> Dictionary:
	var tol := params.num("escort", "forward_mount_tolerance_deg")
	var weapons: Variant = null
	if def != null:
		weapons = def.get("weapons")
	# An EMPTY list is "no weapons data yet" (Track C's UnitDef has the property
	# before the unit files carry any weapons), so it falls through to the
	# placeholders; a non-empty list is trusted even if none of it points forward.
	if (weapons is Array and not (weapons as Array).is_empty()) or (weapons is Dictionary and not (weapons as Dictionary).is_empty()):
		var list: Array = weapons if weapons is Array else (weapons as Dictionary).values()
		var best: Dictionary = {}
		for w: Variant in list:
			var c := _cone_of(w)
			if c.is_empty():
				continue
			if absf(wrap_deg(float(c["mount_deg"]))) <= tol and (best.is_empty() or float(c["range_m"]) > float(best["range_m"])):
				best = c
		if best.is_empty():
			return {"source": SOURCE_NONE}
		best["source"] = SOURCE_DEF
		return best
	var fb := params.fallback_cone(type_id)
	if fb.is_empty():
		return {}
	fb["source"] = SOURCE_FALLBACK
	return fb

# True when the cone can be used to aim (it has a reach).
static func usable(cone: Dictionary) -> bool:
	return cone.has("range_m") and float(cone["range_m"]) > 0.0

# Is the target inside the cone? The shooter is (sx, sy) at `heading` (rad) and
# height sz; the target (tx, ty) at height tz (metres, from the altitude bands).
static func contains(cone: Dictionary, sx: float, sy: float, heading: float, sz: float, tx: float, ty: float, tz: float) -> bool:
	if not usable(cone):
		return false
	var dx := tx - sx
	var dy := ty - sy
	var dz := tz - sz
	if not (is_finite(dx) and is_finite(dy) and is_finite(dz)):
		return false
	var flat := sqrt(dx * dx + dy * dy)
	if sqrt(flat * flat + dz * dz) > float(cone["range_m"]):
		return false
	var across := wrap_deg(rad_to_deg(JsMath.atan2(dy, dx) - heading) - float(cone["mount_deg"]))
	if flat > 1e-9 and absf(across) > float(cone["half_across_deg"]):
		return false
	var elev := rad_to_deg(JsMath.atan2(dz, flat))
	return absf(elev - float(cone["elevation_deg"])) <= float(cone["half_height_deg"])

# An angle in degrees in [-180, 180).
static func wrap_deg(a: float) -> float:
	return a - 360.0 * floorf((a + 180.0) / 360.0)

# --- Reading def.weapons -------------------------------------------------------

static func _cone_of(w: Variant) -> Dictionary:
	var out := {}
	for k: String in AiParams.CONE_KEYS:
		var v := _field(w, k)
		if is_nan(v):
			return {}
		out[k] = v
	return out

static func _field(w: Variant, key: String) -> float:
	var v: Variant = null
	if w is Dictionary:
		v = (w as Dictionary).get(key)
	elif w is Object:
		v = (w as Object).get(key)
	if v is Dictionary and (v as Dictionary).has("value"):
		v = (v as Dictionary)["value"]
	if v is float or v is int:
		return float(v)
	return NAN
