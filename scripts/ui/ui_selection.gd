extends RefCounted

# The selected unit, shared by every UI piece: the roster row, the marker's
# ring, the motion planner and the orders card all read this one object and
# listen to `changed`, so selecting in any of them selects in all of them.
#
#   var sel := UiSelection.new()
#   sel.changed.connect(func(id: String) -> void: ...)
#   sel.select("p1")        # "" selects nothing

signal changed(unit_id: String)

var unit_id: String = ""

func select(id: String) -> void:
	if id == unit_id:
		return
	unit_id = id
	changed.emit(id)

func clear() -> void:
	select("")
