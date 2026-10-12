extends RefCounted

# THE ODDS TABLE OF PROOF 4 (builder LOF2, stage 2 of the lines of fire, 2026-10-12; test support -- the gate does not run scripts/test_support).
# A tank's gun (data/units/tank.json turret_gun) against a still tank at 100, 200 and 350 m, under the new model: in the open (head on and
# broadside), hull-down behind the low bridge's parapet, hull-down behind sandbags, and behind a house. The old model gave 0.12 in every cell
# (flat to 350 m; cover did not count). Each cell is {situation, range_m, odds, share (the target's visible share), hull, turret (each box's),
# visible (false: the gun holds)}. The chance is the odds module's own (Odds.assess) with the weapon's spread from data; the cone's other factors
# are 1 for a still target inside the effective range at the cone's centre.
#
#   var rows := LofOddsTable.new().compute()

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Odds = preload("res://scripts/sim/line_of_fire_odds.gd")
const LofCalibration = preload("res://scripts/test_support/lof_calibration.gd")
const LofCases = preload("res://scripts/test_support/lof_cases.gd")

const RANGES: Array[float] = [100.0, 200.0, 350.0]
const OLD_ODDS := 0.12

var cal: LofCalibration
var rules: Rules

func _init() -> void:
	cal = LofCalibration.new()
	rules = cal.rules

func _wall(cx: float, cy: float, half_l: float, half_w: float, h: float, material_name: String) -> Dictionary:
	return {"part": "test", "material": rules.material_id(material_name), "material_name": material_name, "kind": "box", "stamp": true, "standable": false,
		"cx": cx, "cy": cy, "cs": 1.0, "sn": 0.0, "hl": half_l, "hw": half_w, "ro": 0.0, "ri": 0.0, "z0": 0.0, "z1": h}

func _cell(situation: String, d: float, lof: LineOfFire, mx: float, my: float, mz: float, tx: float, ty: float, tz: float, heading: float, key: int = 1) -> Dictionary:
	var tdef: Variant = cal.world.unit_def("tank")
	var spread := float(rules.spreads["turret_gun"]["spread_mrad"])
	var boxes := Shapes.world_boxes(tdef, rules, tx, ty, heading, tz)
	var ex := lof.exposure_xyz(mx, my, mz, boxes, key, false, true)
	var ev := Odds.assess(ex, mx, my, mz, spread, rules.odds_aim)
	var visible := bool(ex["visible"]) and bool(ev["visible"])
	return {"situation": situation, "range_m": d, "odds": float(ev["p"]) if visible else 0.0, "share": float(ex["share"]), "hull": float(ex["boxes"][0]["share"]),
		"turret": float(ex["boxes"][1]["share"]), "visible": visible, "old": OLD_ODDS}

func compute() -> Array:
	var rows: Array = []
	var hp: Vector3 = cal.world.unit_def("tank").weapons[0].hardpoints[0]
	var mz := hp.z
	var bay := LofCalibration.BAY
	var g := cal.grid
	var lof := cal.lof
	# 1 and 2: the open bay, the target head on to the gun and broadside to it
	for d in RANGES:
		rows.append(_cell("in the open, head on", d, lof, bay.x, bay.y, mz, bay.x + d, bay.y, 0.0, PI))
	for d in RANGES:
		rows.append(_cell("in the open, broadside", d, lof, bay.x, bay.y, mz, bay.x + d, bay.y, 0.0, PI * 0.5))
	# 3: sandbags (1.15 m of earth, 3 m in front of the target)
	for d in RANGES:
		g.stamp("test_bags", [_wall(bay.x + d - 3.0, bay.y, 0.5, 8.0, 1.15, "earth")])
		rows.append(_cell("behind sandbags (1.15 m, 3 m ahead)", d, lof, bay.x, bay.y, mz, bay.x + d, bay.y, 0.0, PI))
		g.unstamp("test_bags")
	# 4: a house (a wooden block 8 m wide and 7 m high, 3 m in front of the target)
	for d in RANGES:
		g.stamp("test_house", [_wall(bay.x + d - 7.0, bay.y, 4.0, 5.0, 7.0, "wood")])
		rows.append(_cell("behind a house (7 m)", d, lof, bay.x, bay.y, mz, bay.x + d, bay.y, 0.0, PI))
		g.unstamp("test_house")
	# 5: behind the low bridge's parapet: on Hold the bridge's map, the target on the deck, its front 1 m behind the near parapet, the gun across it
	var bs := LofCases.ProbeScene.new(LofCases.BRIDGE)
	var site: Dictionary = bs.water.sites()["bridge"]
	bs.add("bridge_1", "bridge", site["pos"], float(site["heading"]))
	var bp: Vector2 = site["pos"]
	var hd: float = site["heading"]
	var across := Vector2(-sin(hd), cos(hd))
	var tgt := bp + across * 3.0
	bs.grid.build_rect(Rect2(bp.x - 400.0, bp.y - 400.0, 800.0, 800.0))
	for d in RANGES:
		var gun := tgt + across * d
		var heading := (gun - tgt).angle()
		var c := _cell("behind the bridge parapet (1 m, 1 m ahead)", d, bs.lof, gun.x, gun.y, bs.grid.stand_z(gun.x, gun.y) + mz, tgt.x, tgt.y, bs.grid.stand_z(tgt.x, tgt.y), heading)
		rows.append(c)
	return rows

# The rows as lines of text, grouped by situation: the report's table.
static func to_text(rows: Array) -> String:
	var out := "situation                                      100 m   200 m   350 m      (old model: 0.120 in every cell)\n"
	var seen: Array[String] = []
	for r: Dictionary in rows:
		if not seen.has(str(r["situation"])):
			seen.append(str(r["situation"]))
	for s in seen:
		var line := "%-44s" % s
		for r: Dictionary in rows:
			if str(r["situation"]) == s:
				line += "  %6s" % (("%.3f" % float(r["odds"])) if bool(r["visible"]) else "held")
		out += line + "\n"
	return out
