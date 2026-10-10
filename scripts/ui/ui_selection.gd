extends RefCounted

# The selected unit, shared by every UI piece: the roster row, the marker's
# ring, the motion planner and the orders card all read this one object and
# listen to `changed`, so selecting in any of them selects in all of them.
#
#   var sel := UiSelection.new()
#   sel.changed.connect(func(id: String) -> void: ...)
#   sel.select("p1")        # "" selects nothing
#
# WHO MAY BE SELECTED (Track U2, the first fight): `allow` is an optional
# Callable (unit_id) -> bool. UnitUI points it at "not down", so a down unit
# cannot be selected for planning -- from the roster, the map or the Tab key --
# and prune() lets go of a unit that went down while it was selected. Without
# it, anything may be selected (a test, a host with no World rules).

signal changed(unit_id: String)

var unit_id: String = ""
var allow: Callable = Callable()

func can_select(id: String) -> bool:
	return id == "" or not allow.is_valid() or bool(allow.call(id))

func select(id: String) -> void:
	if id == unit_id or not can_select(id):
		return
	unit_id = id
	changed.emit(id)

func clear() -> void:
	select("")

# Lets go of a selection that is no longer allowed (a unit that went down).
func prune() -> void:
	if unit_id != "" and not can_select(unit_id):
		select("")
