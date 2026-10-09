extends Node

# THE MOUNT POINT for Track A (and Track V): the whole unit interface wired to
# one World in one call.
#
#   var ui := UnitUI.new()
#   add_child(ui)
#   ui.setup(world, map_view, "local")                 # map_view: Transform2D, or an
#                                                      # object with world_to_screen /
#                                                      # screen_to_world (Track V's MapView)
#   ui.setup(world, map_view, "local", live_layer, hud_layer)   # or into the host's own layers
#
# It builds, and shares one UiSelection between:
#   planner        motion_planner.gd      the fan, the plan curve, ghosts, clamps (map, screen space)
#   marker_layer   unit_marker_layer.gd   every unit's plane, shadow, side mark, selection ring
#   roster         roster.gd              the right-hand sidebar (HUD)
#   orders         motion_planner_panel.gd  the orders card under it: altitude, undo, clear, Ready
#
# map_parent / hud_parent default to two CanvasLayers of its own (1 and 2). The
# map layers must sit in SCREEN space (identity canvas transform): the mapping
# does the zooming, so ink lines stay true pixel widths.
#
# THE TURN: Ready commits the local player (World.commit). When that makes
# everyone ready and auto_resolve is on, it calls World.resolve(); the marker
# layer animates the histories (World.sample); at the end, with
# auto_begin_turn on, World.begin_turn(). A host that wants its own turn
# controller turns both off and listens to ready_pressed / turn_played.
#
# Signals for the host: unit_focus_requested (a roster row was picked: centre
# the camera there if you like -- design doc, Unit roster sidebar), ready_pressed,
# turn_played.

signal unit_focus_requested(unit_id: String, world_pos: Vector2)
signal ready_pressed(all_ready: bool)
signal turn_played(turn: int)

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const MotionPlannerPanel = preload("res://scripts/ui/motion_planner_panel.gd")
const Roster = preload("res://scripts/ui/roster.gd")

var world: World = null
var style: UiStyle = null
var selection: RefCounted = null
var local_player: String = "local"
var auto_resolve: bool = true
var auto_begin_turn: bool = true

var marker_layer: UnitMarkerLayer = null
var planner: MotionPlanner = null
var roster: Roster = null
var orders: MotionPlannerPanel = null
var hud: Control = null

func setup(w: World, host_mapping: Variant, player: String = "local", map_parent: Node = null, hud_parent: Node = null) -> void:
	world = w
	local_player = player
	style = UiStyle.shared() as UiStyle
	selection = UiSelection.new()
	if map_parent == null:
		var cl := CanvasLayer.new()
		cl.name = "UnitMapLayer"
		cl.layer = 1
		add_child(cl)
		map_parent = cl
	if hud_parent == null:
		var cl2 := CanvasLayer.new()
		cl2.name = "UnitHud"
		cl2.layer = 2
		add_child(cl2)
		hud_parent = cl2
	planner = MotionPlanner.new()
	planner.name = "MotionPlanner"
	map_parent.add_child(planner)
	planner.setup(world, host_mapping, selection, local_player, style)
	marker_layer = UnitMarkerLayer.new()
	marker_layer.name = "UnitMarkers"
	map_parent.add_child(marker_layer)
	marker_layer.setup(world, host_mapping, selection, style)
	marker_layer.leader_target = _leader_target
	marker_layer.playback_finished.connect(_on_playback_finished)

	hud = Control.new()
	hud.name = "Hud"
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_parent.add_child(hud)
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	roster = Roster.new()
	roster.name = "Roster"
	hud.add_child(roster)
	roster.setup(world, selection, style)
	roster.unit_selected.connect(_on_roster_pick)
	roster.playback = marker_layer
	orders = MotionPlannerPanel.new()
	orders.name = "Orders"
	hud.add_child(orders)
	orders.setup(world, planner, selection, local_player, style)
	orders.ready_action = press_ready
	orders.playback = marker_layer
	hud.resized.connect(layout)
	roster.resized.connect(layout)
	layout()

func set_mapping(host_mapping: Variant) -> void:
	marker_layer.set_mapping(host_mapping)
	planner.set_mapping(host_mapping)

# The sidebar column: roster at the top right, orders under it.
func layout() -> void:
	if hud == null:
		return
	var m: float = style.num("card.margin_px")
	var w: float = style.num("roster.width_px")
	var x := hud.size.x - m - w
	roster.position = Vector2(x, m)
	orders.position = Vector2(x, m + roster.size.y + style.num("card.gap_px"))

func select(id: String) -> void:
	selection.select(id)

# --- The turn ----------------------------------------------------------------------

func press_ready() -> void:
	if world.phase != World.PHASE_PLANNING:
		return
	if world.is_ready(local_player):
		world.withdraw(local_player)
		ready_pressed.emit(false)
		return
	var all := planner.ready_up()
	ready_pressed.emit(all)
	if all and auto_resolve:
		world.resolve()   # turn_resolved -> the marker layer plays it

func _on_playback_finished(turn_no: int) -> void:
	turn_played.emit(turn_no)
	if auto_begin_turn and world.phase == World.PHASE_RESOLVED:
		world.begin_turn()

# --- Map input (screen points in the map layers' space) ------------------------------

func map_press(p: Vector2) -> bool:
	var hit := marker_layer.unit_at(p)
	if hit != "" and hit != selection.unit_id and planner.handle_at(p) < 0:
		selection.select(hit)
		return true
	if planner.press(p):
		return true
	if hit != "":
		selection.select(hit)
		return true
	return false

func map_drag(p: Vector2) -> bool:
	return planner.drag(p)

func map_release(p: Vector2) -> bool:
	return planner.release(p)

func _to_map(viewport_pt: Vector2) -> Vector2:
	return marker_layer.get_global_transform_with_canvas().affine_inverse() * viewport_pt

func _unhandled_input(event: InputEvent) -> void:
	if world == null:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		var p := _to_map(mb.position)
		var used := map_press(p) if mb.pressed else map_release(p)
		if used:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and planner.is_dragging():
		map_drag(_to_map((event as InputEventMouseMotion).position))
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if _key(event as InputEventKey):
			get_viewport().set_input_as_handled()

func _key(k: InputEventKey) -> bool:
	var name := OS.get_keycode_string(k.keycode)
	if name == style.text("keys.undo"):
		return planner.undo()
	if name == style.text("keys.clear"):
		planner.clear()
		return true
	if name == style.text("keys.ready"):
		press_ready()
		return true
	if name == style.text("keys.climb"):
		return not planner.change_band(1).is_empty()
	if name == style.text("keys.dive"):
		return not planner.change_band(-1).is_empty()
	if name == style.text("keys.next_unit"):
		var ids := roster.ordered_ids()
		if ids.is_empty():
			return false
		var i := (ids.find(selection.unit_id) + 1) % ids.size()
		selection.select(ids[i])
		return true
	return false

# --- Wiring ----------------------------------------------------------------------------

# The selected row's anchor, in the marker layer's space.
func _leader_target(id: String) -> Vector2:
	if roster == null or not roster.is_visible_in_tree():
		return Vector2.INF
	var local := roster.row_anchor(id) - roster.position
	if not local.is_finite():
		return Vector2.INF
	var vp := roster.get_global_transform_with_canvas() * local
	return _to_map(vp)

func _on_roster_pick(id: String) -> void:
	var u = world.units.get(id)
	if u != null:
		unit_focus_requested.emit(id, Vector2(float(u.x), float(u.y)))
