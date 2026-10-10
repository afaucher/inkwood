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
#   planner        motion_planner.gd      the fan, the plan curves, ghosts, clamps (map, screen space)
#   marker_layer   unit_marker_layer.gd   every unit's plane, shadow, side mark, selection ring
#   overlay        a Node2D above the markers for overlays (see HOOKS below); the selection
#                  ring's health arc (health_arc.gd) is its first child
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
# SIGNALS for the host: unit_focus_requested (a roster row was picked: centre
# the camera there if you like -- design doc, Unit roster sidebar; a DOWN unit's
# row emits it too, without selecting), ready_pressed, turn_played.
#
# CO-OP (Alex 2026-10-09: last edit wins, a full preview, no unit belongs to a
# player; Track U2): every player unit's plan is drawn thin on the map and the
# roster marks each unit "plan: n of m steps" or "no plan (flies on)", both
# live on World.plan_changed whoever edited (this player, or another over the
# network). An AI unit's plan is NEVER drawn (motion_planner.gd plan_shown).
# A down unit's roster row is greyed and the unit cannot be selected
# (UiSelection.allow); a selection that goes down is let go when planning
# starts again.
#
# NODE HOVER (Alex 2026-10-10: "a visual indicator for selecting path nodes"): every
# mouse motion is fed to the planner (set_pointer), unless a card is under the pointer
# (over_card) or the pointer leaves the window, and the planner shows and says what a
# press would do (planner.hover(), planner.cursor_shape): grab the NEAREST step's
# handle, place the next step, or nothing. Style: ui.json planner.hover.mode.
#
# GROUP BY (Alex: "a group by for needs orders"): the roster header's button
# cycles ui.json roster.group.modes (roster.set_group_by(id) from code). It is
# this player's VIEW setting, held in the Roster only -- never in the World,
# never sent. Rows move by the rule in roster.gd (KEEPING A ROW STILL): not
# under the pointer, not the selected unit's, regrouped when planning starts.
#
# ---------------------------------------------------------------------------
# HOOKS FOR PART 2 (the combat overlay and the effects layer mount on these
# without editing this file). All PROPOSED by Track U2, 2026-10-09.
#
#   LAYER      overlay: Node2D          Add children to it. Same screen space as the
#                                       markers (mapping.world_to_screen is its
#                                       space), drawn ABOVE the markers and the
#                                       health arc, BELOW the HUD (roster, orders).
#              hud: Control             The HUD root (full rect, ignores the mouse);
#                                       add cards above the roster here.
#   SPACE      mapping: UiMapping       world_to_screen / screen_to_world /
#                                       px_per_m(at) / screen_angle(at, heading) /
#                                       screen_delta(at, d). Live with a live host.
#              world_pos_at(id, t) -> Vector2             metres, where the unit is t seconds
#                                                         into the last resolve (INF: no such unit)
#              screen_pos_at(id, t) -> Vector2            the same, in the overlay's screen space
#              screen_pose_at(id, t) -> Dictionary        the World.sample pose
#                  ({x, y, heading, speed, altitude_band, height_m}) plus screen (Vector2),
#                  screen_heading (rad) and px_per_m
#              screen_pos_now(id) -> Vector2              where the marker is drawn this frame
#                                                         (playback-aware; INF if hidden)
#   CLOCK      playback_time() -> float                   seconds into the turn being played back,
#                                                         -1.0 when none is
#              is_playing() -> bool
#              signal playback_frame(t, turn)             once per frame a playback advances
#                                                         (and once with t = turn length when it
#                                                         ends)
#              signal playback_event(event)               each event of the turn's resolve (the
#                                                         `events` World.turn_resolved carries --
#                                                         fire, hit, down, left_bounds ...) the
#                                                         moment the playback clock passes its
#                                                         "t" (seconds; an event with no "t" fires
#                                                         at 0). In "t" order, ties in the order
#                                                         World gave them; every one fires exactly
#                                                         once per playback, a jump forward
#                                                         fires all it skipped, and the rest
#                                                         fire when the playback ends.
#              poll_playback()                            what _process runs each frame (public so
#                                                         a test that drives the marker layer by
#                                                         hand can run it)
#   HEALTH     show_health(id, pips)                      during a playback the roster rows and
#                                                         the ring arc show the health the unit
#                                                         had when the turn began (a resolve does
#                                                         not spoil a hit). UnitUI itself drops
#                                                         the pips as a "hit" event ("unit",
#                                                         "health") or a "down" event ("unit")
#                                                         passes the clock; show_health is for
#                                                         anything else (0 shows the unit down).
#                                                         Dropped when the playback ends;
#                                                         Unit.health shows then.
#   LAYOUT     sidebar_width_px() -> float                the screen width the roster and orders
#                                                         column takes at the right (margins
#                                                         included); hud_insets() -> {left, top,
#                                                         right, bottom} the same as a camera
#                                                         inset; sidebar_rect() -> Rect2 in HUD
#                                                         space. See the camera note below.
#
# CAMERA NOTE (the roster must not cover the map at full zoom-out): UnitUI
# cannot fix this alone -- at the camera's zoom-out limit ("fit_map") the map
# fills the whole view, and the sidebar is a card on top of it. CameraController
# already takes insets (set_insets) for framing; its zoom_limit_min() and the
# centring at that limit must take them too (scripts/world, Track F's). A host
# reads the column's width here: ctl.set_insets(...hud_insets...).
# ---------------------------------------------------------------------------

signal unit_focus_requested(unit_id: String, world_pos: Vector2)
signal ready_pressed(all_ready: bool)
signal turn_played(turn: int)
signal playback_frame(t: float, turn: int)
signal playback_event(event: Dictionary)

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiHealth = preload("res://scripts/ui/ui_health.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const MotionPlannerPanel = preload("res://scripts/ui/motion_planner_panel.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const HealthArc = preload("res://scripts/ui/health_arc.gd")

var world: World = null
var style: UiStyle = null
var selection: RefCounted = null
var mapping: UiMapping = null
var local_player: String = "local"
var auto_resolve: bool = true
var auto_begin_turn: bool = true

var marker_layer: UnitMarkerLayer = null
var planner: MotionPlanner = null
var roster: Roster = null
var orders: MotionPlannerPanel = null
var hud: Control = null
var overlay: Node2D = null
var health: UiHealth = null
var health_arc: HealthArc = null

# This turn's events, [t, order, event] sorted by t; _next is the first one not yet fired.
var _events: Array = []
var _next: int = 0
var _last_t: float = -1.0

func _init() -> void:
	process_priority = 10   # after the marker layer (0) has advanced the playback this frame

func setup(w: World, host_mapping: Variant, player: String = "local", map_parent: Node = null, hud_parent: Node = null) -> void:
	world = w
	local_player = player
	style = UiStyle.shared() as UiStyle
	mapping = UiMapping.from(host_mapping) as UiMapping
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
	planner.marker_layer = marker_layer   # the ghosts borrow the selected marker's art
	marker_layer.playback_finished.connect(_on_playback_finished)
	marker_layer.playback_started.connect(_on_playback_started)
	world.turn_resolved.connect(_on_turn_resolved)
	world.phase_changed.connect(_on_phase_changed)

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
	roster.down_unit_picked.connect(_on_roster_pick)
	roster.playback = marker_layer
	health = roster.health
	selection.allow = _may_select
	# The overlay layer, above the markers: the health arc first, then whatever part 2 adds.
	overlay = Node2D.new()
	overlay.name = "Overlay"
	map_parent.add_child(overlay)
	health_arc = HealthArc.new()
	overlay.add_child(health_arc)
	health_arc.setup(world, marker_layer, selection, style, health)
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
	mapping = UiMapping.from(host_mapping) as UiMapping
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

# --- Layout for the host (the camera) --------------------------------------------

# The screen width the sidebar column takes at the right edge: the card and a
# margin on each side.
func sidebar_width_px() -> float:
	return style.num("roster.width_px") + 2.0 * style.num("card.margin_px")

# The same as a camera inset (CameraController.set_insets(left, top, right, bottom)).
func hud_insets() -> Dictionary:
	return {"left": 0.0, "top": 0.0, "right": sidebar_width_px(), "bottom": 0.0}

# The column the roster and the orders card occupy, in HUD space (margins included).
func sidebar_rect() -> Rect2:
	var m: float = style.num("card.margin_px")
	var bottom := orders.position.y + orders.size.y + m
	return Rect2(roster.position.x - m, 0.0, sidebar_width_px(), bottom)

# --- The turn ----------------------------------------------------------------------

func press_ready() -> void:
	if world.phase != World.PHASE_PLANNING:
		return
	if world.is_ready(local_player):
		world.withdraw(local_player)
		ready_pressed.emit(false)
		return
	var all := planner.ready_up()
	if not world.is_ready(local_player):
		return   # refused: the planner says why on the orders card (a turn that would leave the map)
	ready_pressed.emit(all)
	if all and auto_resolve:
		world.resolve()   # turn_resolved -> the marker layer plays it

func _on_playback_finished(turn_no: int) -> void:
	# Whatever the clock never reached (an event at the turn's very end) fires now,
	# the clock reads the turn's length once, and the shown health is the unit's own again.
	_fire_events_until(INF)
	playback_frame.emit(world.rules.turn_seconds, turn_no)
	_last_t = -1.0
	health.clear_shown()
	turn_played.emit(turn_no)
	if auto_begin_turn and world.phase == World.PHASE_RESOLVED:
		world.begin_turn()

func _on_playback_started(_turn_no: int) -> void:
	_next = 0
	_last_t = -1.0

func _on_turn_resolved(_turn_no: int, _histories: Dictionary, events: Array) -> void:
	_events.clear()
	var i := 0
	for ev: Variant in events:
		if ev is Dictionary:
			_events.append([float((ev as Dictionary).get("t", 0.0)), i, ev])
			i += 1
	_events.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	_next = 0
	_last_t = -1.0

func _on_phase_changed(phase: String) -> void:
	if phase == World.PHASE_PLANNING:
		selection.prune()   # a unit that went down while selected

# Whom the selection may take: not a unit shown as down (the shown state, so a
# unit about to fall is still selectable until the playback says it has).
func _may_select(id: String) -> bool:
	if not world.units.has(id):
		return true
	return not health.shown_down(id, marker_layer != null and marker_layer.is_playing())

# --- Hooks for part 2 -------------------------------------------------------------------

func is_playing() -> bool:
	return marker_layer != null and marker_layer.is_playing()

func playback_time() -> float:
	return marker_layer.playback_t if is_playing() else -1.0

# Run each frame (after the marker layer has advanced the playback): emits
# playback_frame and fires the events the clock has passed.
func poll_playback() -> void:
	if not is_playing():
		return
	var t: float = marker_layer.playback_t
	if t == _last_t:
		return
	_last_t = t
	_fire_events_until(t)
	playback_frame.emit(t, marker_layer.playback_turn)

func _process(_delta: float) -> void:
	if world != null:
		poll_playback()

func _fire_events_until(t: float) -> void:
	while _next < _events.size() and float((_events[_next] as Array)[0]) <= t:
		var ev: Dictionary = (_events[_next] as Array)[2]
		_next += 1
		_show_event_health(ev)
		playback_event.emit(ev)

# The pips follow combat's own events (scripts/sim/combat.gd): a "hit" carries
# the target's pips left ("unit", "health"), a "down" takes the unit to 0. They
# drop as the playback clock passes the event, with nothing for the effects
# layer to wire (it may still call show_health for anything else).
func _show_event_health(ev: Dictionary) -> void:
	var id := str(ev.get("unit", ""))
	if id == "" or not world.units.has(id):
		return
	match str(ev.get("type", "")):
		"hit":
			if ev.has("health"):
				health.show(id, int(ev["health"]))
		"down":
			health.show(id, 0)

func show_health(id: String, pips: int) -> void:
	health.show(id, pips)

# Where a unit is `t` seconds into the last resolve, in metres.
func world_pos_at(id: String, t: float) -> Vector2:
	if not world.units.has(id):
		return Vector2.INF
	var s := world.sample(id, t, "history")
	if s.is_empty():
		return Vector2.INF
	return Vector2(float(s["x"]), float(s["y"]))

func screen_pos_at(id: String, t: float) -> Vector2:
	var p := world_pos_at(id, t)
	return mapping.world_to_screen(p) if p.is_finite() else Vector2.INF

func screen_pose_at(id: String, t: float) -> Dictionary:
	if not world.units.has(id):
		return {}
	var s := world.sample(id, t, "history")
	if s.is_empty():
		return {}
	var p := Vector2(float(s["x"]), float(s["y"]))
	s["screen"] = mapping.world_to_screen(p)
	s["screen_heading"] = mapping.screen_angle(p, float(s["heading"]))
	s["px_per_m"] = mapping.px_per_m(p)
	return s

# Where the unit's marker is drawn this frame (the playback's pose while one plays).
func screen_pos_now(id: String) -> Vector2:
	var m = marker_layer.marker(id)
	if m == null or not m.visible:
		return Vector2.INF
	return m.position

# --- Map input (screen points in the map layers' space) ------------------------------

func map_press(p: Vector2) -> bool:
	var hit := marker_layer.unit_at(p)
	if hit != "" and not selection.can_select(hit):
		hit = ""   # a down unit's marker is not a way to plan it
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

# A step being dragged follows the pointer and ends on release WHEREVER the
# pointer is, so those two events are taken here, before the GUI: a card (the
# roster, the orders card) under the pointer stops mouse motion, which stalled
# the drag, and swallowed the release, which left the step under the card. The
# press that starts a drag stays in _unhandled_input: a card on top is clicked,
# not planned through.
func _input(event: InputEvent) -> void:
	if world == null or planner == null:
		return
	if not planner.is_dragging():
		# The planner's hover: where the pointer is, unless a card is under it (a card is
		# clicked, not planned through) -- every motion is seen here, GUI or not.
		if event is InputEventMouseMotion:
			var pos := (event as InputEventMouseMotion).position
			if over_card(pos):
				planner.clear_pointer()
			else:
				planner.set_pointer(_to_map(pos))
		return
	if event is InputEventMouseMotion:
		planner.set_pointer(_to_map((event as InputEventMouseMotion).position))
		map_drag(_to_map((event as InputEventMouseMotion).position))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and not (event as InputEventMouseButton).pressed:
		map_release(_to_map((event as InputEventMouseButton).position))
		planner.set_pointer(_to_map((event as InputEventMouseButton).position))
		get_viewport().set_input_as_handled()

# Whether a viewport point is on the roster or the orders card.
func over_card(viewport_pt: Vector2) -> bool:
	for c: Control in [roster, orders]:
		if c != null and c.is_visible_in_tree() and c.get_global_rect().has_point(viewport_pt):
			return true
	return false

func _notification(what: int) -> void:
	# The pointer left the window: nothing is hovered.
	if what == NOTIFICATION_WM_MOUSE_EXIT and planner != null:
		planner.clear_pointer()

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
		var ids := roster.selectable_ids()   # (a down unit takes no orders)
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
