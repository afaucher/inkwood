extends RefCounted

# THE TARGET SELECTION (Track T, 2026-10-10). Alex, decision special-targeting: "when you have a friendly
# unit selected, you can also select either an enemy unit or a point on the map. The only thing it does is
# show on the side view and it is the target that the special will use if activated. Non-specials don't need
# targets because they autofire." "No target set means you can't activate special." This is that selection:
# one object shared by every UI piece (UnitUI holds it as `target`, the planner and the map marks read it, and
# Track V's side view listens to it), like UiSelection is for the selected unit.
#
# THE SEAM FOR TRACK V (names are fixed): UnitUI.target is a UiTarget with the signal changed(), the fields
# kind ("" none | "unit" | "point"), unit_id (the enemy unit when kind is "unit", else ""), point_m (a point
# target's place in metres; for a unit target the place it was last seen, Vector2.INF when kind is ""), and
# is_set(), clear() and position_m(world) -- where the target is SHOWN: the point, or the unit's position as the
# player sees it (the animated pose while a turn plays back; a unit out of sight is held at the place it was last
# seen; a unit that is gone or down, the place it was). A UNIT TARGET FOLLOWS THE UNIT (Alex: "Targeting a moving
# unit like a tank should follow the unit"): the selection only names it, and the sim resolves the release against
# where it goes; nothing here projects an enemy's motion. It is set only while a friendly unit is selected and it is cleared when that selection
# changes (PROPOSED: Alex, "not sure [a target] is meaningful across multiple steps" -- per-unit memory is not
# wanted). The target the special of a STEP carries is another thing, stored on that step when the special is
# activated there: MotionPlanner.step_target(k) -> {} or {"unit": id or "", "point": Vector2} for step k of the
# selected unit's plan (the wire form is {"drop": {"aim": [x, y], "target": {"unit": id} | {"point": [x, y]}}}).
#
#   var t := UiTarget.new()
#   t.changed.connect(func() -> void: ...)
#   t.set_unit("radio_tower_1", Vector2(3300, 2400))     # left-click on an enemy marker
#   t.set_point(Vector2(3320, 2410))                     # right-click on the map
#   t.position_m(world)                                  # -> Vector2 (metres)
#   t.clear()                                            # Esc, or the friendly selection changed

signal changed

var kind: String = ""                 # "" | "unit" | "point"
var unit_id: String = ""
var point_m: Vector2 = Vector2.INF
# unit_id -> bool: whether the player can see that unit now (the fog's say). UnitUI points it at the marker
# layer's. Unset: every unit is in sight.
var sight: Callable = Callable()
# unit_id -> Vector2 (metres): where that unit is SHOWN now (UnitUI points it at the playback's pose while a turn
# plays, else the unit's place). Unset: the unit's own x, y.
var shown: Callable = Callable()

func is_set() -> bool:
	return kind != ""

func is_unit() -> bool:
	return kind == "unit"

func is_point() -> bool:
	return kind == "point"

func clear() -> void:
	if kind == "" and unit_id == "" and not point_m.is_finite():
		return
	kind = ""
	unit_id = ""
	point_m = Vector2.INF
	changed.emit()

# An enemy unit as the target; `at_m` is where the player sees it now (kept as the last place it was seen).
func set_unit(id: String, at_m: Vector2) -> void:
	if id == "":
		clear()
		return
	if kind == "unit" and unit_id == id and point_m == at_m:
		return
	kind = "unit"
	unit_id = id
	point_m = at_m
	changed.emit()

# A point on the map as the target.
func set_point(p: Vector2) -> void:
	if not p.is_finite():
		clear()
		return
	if kind == "point" and point_m == p:
		return
	kind = "point"
	unit_id = ""
	point_m = p
	changed.emit()

# Where the target is, in metres: the point; or the unit's position as the planning player sees it. A unit
# that is in sight is read live (and remembered as the last place it was seen); one that is not is held where it
# was last seen, so the fog never gives its place away. Vector2.INF when there is no target.
func position_m(world: Object) -> Vector2:
	if kind == "point":
		return point_m
	if kind != "unit":
		return Vector2.INF
	if world != null and world.units.has(unit_id) and (not sight.is_valid() or bool(sight.call(unit_id))):
		var u: Object = world.units[unit_id]
		var at := Vector2(float(u.x), float(u.y))
		if shown.is_valid():
			var s: Variant = shown.call(unit_id)
			if s is Vector2 and (s as Vector2).is_finite():
				at = s
		point_m = at
	return point_m

# Whether the unit target is in sight now (a point is always shown).
func in_sight() -> bool:
	if kind != "unit":
		return kind == "point"
	return not sight.is_valid() or bool(sight.call(unit_id))

# A unit target whose unit is gone or down has nothing to aim at: cleared. Returns whether it was.
func prune(world: Object) -> bool:
	if kind != "unit":
		return false
	if world == null or not world.units.has(unit_id) or bool(world.units[unit_id].down):
		clear()
		return true
	return false
