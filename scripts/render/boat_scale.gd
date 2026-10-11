extends RefCounted

# THE SCALE RULES for the boats' board (Track BB, 2026-10-10), computed from the data the game reads, not
# retyped: how many screen pixels a metre is, at a camera zoom, for a thing drawn at the PLANES' rule and
# for a thing drawn at the MAP's scale.
#
#   plane rule  (scripts/app/sandbox.gd _update_plane_scale): marker.true_scale k =
#               max(plane_px / (light fighter size_m x map px/m), plane_min_px / (size_m x map px/m x zoom))
#               and a marker is drawn at map px/m x zoom x k.   plane_px 36, plane_min_px 14, the light
#               fighter 9 m, the map 2 px/m: k = 2 at zoom 1 (4 px per metre), and at the planning zoom
#               0.35 the 14 px floor wins (k = 2.22, 1.556 px per metre).
#   map rule    map px/m x zoom: what a house, a bridge or the road is drawn at.
#
# Data read: data/scenarios/strike.json view.plane_px / plane_min_px, data/units/light_fighter.json size_m,
# data/terrain/terrain.json scale.px_per_m.

const STRIKE_PATH := "res://data/scenarios/strike.json"
const FIGHTER_PATH := "res://data/units/light_fighter.json"
const TERRAIN_PATH := "res://data/terrain/terrain.json"

static var _vals: Dictionary = {}

static func _val(path: String, keys: Array) -> float:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	for k: Variant in keys:
		if v is Dictionary and (v as Dictionary).has(k):
			v = (v as Dictionary)[k]
		else:
			push_error("boat_scale: %s has no %s" % [path, str(keys)])
			return 0.0
	if v is Dictionary and (v as Dictionary).has("value"):
		v = (v as Dictionary)["value"]
	return float(v)

static func values() -> Dictionary:
	if _vals.is_empty():
		_vals = {
			"plane_px": _val(STRIKE_PATH, ["view", "plane_px"]),
			"plane_min_px": _val(STRIKE_PATH, ["view", "plane_min_px"]),
			"fighter_m": _val(FIGHTER_PATH, ["size_m"]),
			"map_ppm": _val(TERRAIN_PATH, ["scale", "px_per_m"]),
		}
	return _vals

static func map_ppm(zoom: float) -> float:
	return float(values()["map_ppm"]) * zoom

# marker.true_scale at this zoom.
static func marker_k(zoom: float) -> float:
	var v := values()
	var base: float = float(v["plane_px"]) / (float(v["fighter_m"]) * float(v["map_ppm"]))
	var floor_k: float = float(v["plane_min_px"]) / (float(v["fighter_m"]) * float(v["map_ppm"]) * maxf(zoom, 1e-6))
	return maxf(base, floor_k)

# Screen pixels per metre of a thing at the planes' rule.
static func plane_ppm(zoom: float) -> float:
	return map_ppm(zoom) * marker_k(zoom)
