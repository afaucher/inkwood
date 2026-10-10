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
# THE STRIKE (Track U3, 2026-10-10; Alex: bombing is "per step, just like diving. You set the intent in the
# cone"; accuracy follows the release angle and the height; several drops; the enemy's plans never shown).
# setup() mounts and feeds all of it:
#   bombs      BombSource (bomb_source.gd): the one place the interface asks the World about bombs
#              (bombs_left, drop_cone, drop_spread), shared by the planner, the card and the roster
#   bomb_aim   BombAim (bomb_aim.gd), just under the planner: the selected bomber's BOMB CONE, aim, expected
#              spread and release for the step the card is about (planner.bomb_marks()), in the look data
#              bombs.aim.mode names (variants/bomb-aim/); its "Marks" child draws the crosshair and the aim
#              handle's hover over the planes
#   the orders card has a Drop control beside Dive / Level / Climb (key B): a drop on the step the card is
#   about (planner.focus_step(): the last placed step, or the step whose handle was grabbed last); the aim is
#   a handle like a step's (planner.grab_at / begin_aim), held inside the cone, refused outside it
#   the roster row of a unit with bombs shows its drops left and the bombs in each; during a playback the
#   marks are the turn's start and one empties as its bomb_release event passes
#   ground units: the radio tower and the anti-aircraft batteries are markers like the planes (unit_marker_art
#   _static.gd: baked already turned, with a cast shadow that is as long as the tower is tall), drawn
#   marker.static_scale times the plane rule; a destroyed one's marker goes at its down event (ui_fate.gd) and
#   the effects layer's ruin takes its place (combat_feed.gd asks for it, and for the bombs falling and landing
#   and the flak, when the layer has the calls)
#   NEVER THE ENEMY'S DROP: every bomb mark goes through planner.plan_shown (see motion_planner.gd).
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
# ---------------------------------------------------------------------------
# COMBAT ON SCREEN (Track U2, the first fight, part 2): setup() mounts and feeds all of it, so a
# host only builds UnitUI as before.
#
#   MOUNTED, bottom to top, in the map parent (map_parent's children):
#     trails                      WingtipTrails: one ribbon between the wingtips, to the plane's
#                                 position now, for every unit in sight, falling ones included --
#                                 HERE, under the smoke, while marker.trails.under_smoke is true
#                                 (PROPOSED: a ribbon over white smoke on the same centre line nearly
#                                 hides it); with it false the ribbon sits just under the planes,
#                                 after the cones (apply_trail_order() moves it)
#     fx (ground, shadows, air)   the effects layer, Track X's FxLayer: damage smoke, the blast, the
#                                 wreck; below the planner and the planes
#     planner                     (as before)
#     cones                       ConeOverlay: the SELECTED unit's cones as a colour wash (its
#                                 interior here, under the planes; its "Marks" child, the rim and
#                                 the hardpoints, above them); range_factor is combat.gd's own
#     marker_layer                (as before; an exploded plane is gone from down_at, a falling one
#                                 flies on and rocks, a crashed one is gone at the crash)
#     fx_above                    the effects layer's bursts, over the planes
#     overlay                     the health arc, then the hit marks (ink on a unit when it is hit)
#   FED from the playback: damage smoke along a damaged plane's path, explode_midair on a down event
#   of fate exploded, falling() every frame for an out-of-control plane, impact() on a crash; a
#   late joiner's wrecks come back with add_scar (restore_wrecks). The calls, their times and the
#   fog rule are scripts/ui/combat_feed.gd's header. Nothing in it is fire: Alex, "just smoke".
#
#   THE END OF A MISSION: show_result(Mission.evaluate()'s dictionary) draws the card (VICTORY /
#   DEFEAT, the reason in words, two buttons) and locks planning input; the buttons emit
#   result_play_again and result_menu for the host to wire. A result handed over while a turn
#   plays waits for its playback to end. hide_result() takes the card down and unlocks.
#   PLAYER NAMES: player_name is a Callable (player id -> display String; the default returns the
#   id); the orders card's ready marks print it for the other players. A host that has names
#   (Track A: WorldSync.name_of) sets it: ui.player_name = world_sync.name_of.
#   TRAILS AND THE WHOLE-FLIGHT LINE: trail_start_t(id) is the game time the ribbon begins at; a
#   track drawn for the whole flight (Track A's sandbox_tracks.gd) stops there.
# ---------------------------------------------------------------------------
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
signal result_play_again
signal result_menu

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
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const WingtipTrails = preload("res://scripts/ui/wingtip_trails.gd")
const HitMarks = preload("res://scripts/ui/hit_marks.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const BombAim = preload("res://scripts/ui/bomb_aim.gd")
const CombatFeed = preload("res://scripts/ui/combat_feed.gd")
const ResultCard = preload("res://scripts/ui/result_card.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const Combat = preload("res://scripts/sim/combat.gd")

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
var cones: ConeOverlay = null
var trails: WingtipTrails = null
var fx: FxLayer = null
var fx_above: Node2D = null
var hit_marks: HitMarks = null
# THE STRIKE (Track U3): the bombs the simulation answers with (shared by the planner, the orders card
# and the roster) and the node that draws the selected bomber's cone and aim, just under the planner.
var bombs: BombSource = null
var bomb_aim: BombAim = null
var feed: CombatFeed = null
var result_card: ResultCard = null
# Player id -> display name (Track A: WorldSync.name_of). The default returns the id.
var player_name: Callable = func(id: String) -> String: return id

var _pending_result: Dictionary = {}
var _fx_k: float = -1.0
var _fx_t: float = -1.0

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
	bombs = BombSource.new()
	planner = MotionPlanner.new()
	planner.name = "MotionPlanner"
	planner.bombs = bombs
	map_parent.add_child(planner)
	planner.setup(world, host_mapping, selection, local_player, style)
	bomb_aim = BombAim.new()   # the bomb cone and the aim: just under the planner, so its hover draws over it
	map_parent.add_child(bomb_aim)
	map_parent.move_child(bomb_aim, planner.get_index())
	bomb_aim.setup(planner, style)
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
	_mount_combat(map_parent, host_mapping)

	hud = Control.new()
	hud.name = "Hud"
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_parent.add_child(hud)
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	roster = Roster.new()
	roster.name = "Roster"
	roster.bombs = bombs
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
	hit_marks = HitMarks.new()
	overlay.add_child(hit_marks)
	hit_marks.setup(world, marker_layer, style)
	feed = CombatFeed.new()
	feed.setup(world, fx, marker_layer, health, style)
	feed.marks = hit_marks
	feed.lookahead = _turn_events   # where this turn's bombs land: read ahead from a bomb_release
	playback_event.connect(feed.on_event)
	playback_frame.connect(feed.on_frame)
	orders = MotionPlannerPanel.new()
	orders.name = "Orders"
	hud.add_child(orders)
	orders.setup(world, planner, selection, local_player, style)
	orders.ready_action = press_ready
	orders.playback = marker_layer
	orders.player_name = func(id: String) -> String: return str(player_name.call(id))
	result_card = ResultCard.new()
	hud.add_child(result_card)   # last: over the roster and the orders card
	result_card.setup(style, world)
	result_card.play_again.connect(func() -> void: result_play_again.emit())
	result_card.menu.connect(func() -> void: result_menu.emit())
	hud.resized.connect(layout)
	roster.resized.connect(layout)
	layout()
	restore_wrecks()
	_sync_fx()

# Mounts the combat pieces round the markers (see COMBAT ON SCREEN above); called by setup()
# once the planner and the marker layer are in `map_parent`.
func _mount_combat(map_parent: Node, host_mapping: Variant) -> void:
	# The effects layer: its ground, shadow and air passes under the planner, its bursts over the planes.
	fx_above = Node2D.new()
	fx_above.name = "FxAbove"
	map_parent.add_child(fx_above)
	fx = FxLayer.new()
	fx.setup(host_mapping, int(world.rng_seed))
	var smoke := style.text("combat.fx.select_smoke")
	var crash := style.text("combat.fx.select_crash")
	var smoke_opt := smoke if smoke != "" else fx.data.working_default("smoke")
	# The crash's own smoke (a falling plane's trail, the burst's cloud, the wreck's column) follows the
	# damage smoke unless the data names another: one smoke for the whole game (proposed).
	var crash_smoke := style.text("combat.fx.select_crash_smoke")
	fx.select(smoke_opt, crash if crash != "" else fx.data.working_default("crash"), crash_smoke if crash_smoke != "" else smoke_opt)
	fx.mount(map_parent, fx_above)
	map_parent.move_child(fx, planner.get_index())
	# The cones, then the trails, just under the markers.
	cones = ConeOverlay.new()
	map_parent.add_child(cones)
	map_parent.move_child(cones, marker_layer.get_index())
	cones.setup(world, host_mapping, selection, style)
	cones.marker_layer = marker_layer
	cones.unit_visible = _unit_in_sight
	cones.range_factor = _range_factor
	trails = WingtipTrails.new()
	map_parent.add_child(trails)
	map_parent.move_child(trails, marker_layer.get_index())
	trails.setup(world, host_mapping, marker_layer, style)
	trails.unit_visible = _unit_in_sight
	apply_trail_order()

# Puts the wingtip ribbon under the smoke (data marker.trails.under_smoke true: before the effects
# layer) or just under the planes (false: after the cones). Idempotent; setup() calls it, and a host
# that changes the data at run time calls it again.
func apply_trail_order() -> void:
	var parent := trails.get_parent()
	if parent == null:
		return
	if style.flag("marker.trails.under_smoke"):
		if trails.get_index() > fx.get_index():
			parent.move_child(trails, fx.get_index())
	else:
		var target := marker_layer.get_index()
		if trails.get_index() < target:
			target -= 1
		parent.move_child(trails, target)

# The fog's say, read from the marker layer when asked (the host sets marker_layer.unit_visible
# after setup()).
func _unit_in_sight(id: String) -> bool:
	return not marker_layer.unit_visible.is_valid() or bool(marker_layer.unit_visible.call(id))

# The odds' fall past a weapon's effective range: combat.gd's own range factor with the
# rules' own overshoot while the "range" factor is in use; a hard edge at the effective range
# when it is not (as Combat.reach reads it).
func _range_factor(weapon: Object, distance_m: float) -> float:
	if world.combat.odds_factors.has("range"):
		return Combat.range_factor(weapon, distance_m, float(world.combat.factor_params().get("range_overshoot", 0.0)))
	return 1.0 if distance_m <= float(weapon.effective_range_m) else 0.0

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	marker_layer.set_mapping(host_mapping)
	planner.set_mapping(host_mapping)
	cones.set_mapping(host_mapping)
	trails.set_mapping(host_mapping)
	fx.set_mapping(host_mapping)

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
	if world.phase != World.PHASE_PLANNING or input_locked():
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
	feed.end_turn(turn_no)
	_last_t = -1.0
	health.clear_shown()
	bombs.clear_shown()
	_sync_fx()
	turn_played.emit(turn_no)
	if not _pending_result.is_empty():
		_present_result(_pending_result)   # handed over while the turn played: now it is over
	if auto_begin_turn and world.phase == World.PHASE_RESOLVED:
		world.begin_turn()

func _on_playback_started(turn_no: int) -> void:
	_next = 0
	_last_t = -1.0
	if feed != null:
		feed.begin_turn(turn_no)

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

# The events of the turn being played, in order (for the feed's lookahead).
func _turn_events() -> Array:
	var out: Array = []
	for e: Variant in _events:
		out.append((e as Array)[2])
	return out

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
		_sync_fx()

# The effects layer's two per-frame inputs: the drawn scale (marker.true_scale) and the game time
# (the playback's while one runs, else the start of the turn being planned). The layer is only
# told when one changes.
func _sync_fx() -> void:
	if fx == null or feed == null:
		return
	if fx.field.world_seed != int(world.rng_seed):
		fx.field.world_seed = int(world.rng_seed)   # a seed a host sets after setup() (the network's) is followed
	var k: float = style.num("marker.true_scale")
	var t := game_time()
	if k != _fx_k or t != _fx_t:
		_fx_k = k
		_fx_t = t
		fx.true_scale = k
		fx.set_time(t)

# Game seconds, the effects' clock: (turn - 1) x turn_seconds + the second of the turn playing.
func game_time() -> float:
	return feed.game_time(is_playing(), marker_layer.playback_turn, marker_layer.playback_t)

# Wrecks already on the ground (a client that joined late finds crashed units whose crash it
# never saw): each gets its scar back. Called by setup(); a host that rebuilt the effects layer
# calls it with clear = true. Returns how many it put back. Scars sit at world positions, so a
# change of scale (set_mapping) needs none of this.
func restore_wrecks(clear: bool = false) -> int:
	return feed.restore_wrecks(is_playing(), game_time(), clear)

# Game seconds at which the wingtip ribbon of a unit begins (NAN: it has none). The whole-flight
# line of a plane stops there so the two never draw the same stretch twice.
func trail_start_t(id: String) -> float:
	return trails.start_t(id)

# --- The end of a mission ---------------------------------------------------------------------

# Shows the end-of-mission card for Mission.evaluate()'s result ({state, reason, turn, t}); a
# state other than "won" or "lost" shows nothing. Planning input is locked while it shows. Called
# while a turn is still playing, it waits for the playback to end.
func show_result(result: Dictionary) -> void:
	var state := str(result.get("state", ""))
	if state != "won" and state != "lost":
		return
	if is_playing():
		_pending_result = result.duplicate(true)
		return
	_present_result(result)

func _present_result(result: Dictionary) -> void:
	_pending_result = {}
	result_card.show_result(result)
	orders.locked = true
	orders.queue_redraw()
	planner.clear_pointer()

# Takes the card down and gives planning back.
func hide_result() -> void:
	_pending_result = {}
	result_card.hide_result()
	orders.locked = false
	orders.queue_redraw()

func input_locked() -> bool:
	return result_card != null and result_card.is_showing()

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
	if str(ev.get("type", "")) == "bomb_release":
		bombs.release_seen(id)   # the roster's bomb marks empty as the release is seen (BombSource)
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
	if input_locked():
		return false
	var hit := marker_layer.unit_at(p)
	if hit != "" and not selection.can_select(hit):
		hit = ""   # a down unit's marker is not a way to plan it
	# (The strike: inside the selected bomber's bomb cone a press moves the aim, even over an ENEMY's marker
	# -- aiming at the tower is clicking the tower -- so it must not select that unit instead.)
	var aiming_at_enemy: bool = hit != "" and world.units.has(hit) and world.units[hit].controller != World.CONTROLLER_PLAYER and planner.in_bomb_cone(p)
	if hit != "" and hit != selection.unit_id and planner.grab_at(p).is_empty() and not aiming_at_enemy:
		selection.select(hit)
		return true
	if planner.press(p):
		return true
	if hit != "":
		selection.select(hit)
		return true
	return false

func map_drag(p: Vector2) -> bool:
	return not input_locked() and planner.drag(p)

func map_release(p: Vector2) -> bool:
	return not input_locked() and planner.release(p)

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
	if input_locked():
		planner.clear_pointer()
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
	if input_locked():
		return false
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
	if name == style.text("keys.drop"):
		return not planner.toggle_drop().is_empty()
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
