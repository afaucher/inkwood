extends Node2D

# The motion planning control on the map (exit criterion 3, design doc: "a plan
# is a curve of steps; each step is a point inside the plane's performance
# envelope; inertia applies"). For the selected unit it draws:
#
#   the FAN      the next step's reachable end points (World.reachable's
#                outline), an inked outline with faint ribs, one per sampled turn
#   the CURVE    the whole turn as it will fly (World.sample(id, t, "plan"), the
#                same arcs the resolve flies): planned steps solid, the
#                carry-on steps after them dashed
#   GHOSTS       the unit's own art, faint, at the end of every step
#                (World.planned_states), heading as it will be
#   CLAMPS       where a step was asked for outside the envelope, a fine dashed
#                tie from the point asked for to where the envelope put it --
#                what is drawn is always the CLAMPED result
#
# Other player units' plans show as thin, quiet curves ALL THE TIME while the
# turn is planned (Alex 2026-10-09, co-op: last edit wins, with a full preview
# so every player sees what has plans and what does not): a solid line with a
# dot at each planned step, the carry-on rest dashed, and for a unit with no
# plan only the dashed flight ("flies on"). They follow World.plan_changed, so
# an edit another player makes (applied by the network layer through the World)
# shows at once.
#
# NEVER AN AI UNIT'S PLAN (Alex): plan_shown(id) is the one rule every drawing
# here goes through -- planning phase, a player-controlled unit, not down -- so
# an AI-controlled unit's path, ghosts, fan and clamps are not drawn even when
# it is the selected unit, and path_world / step_labels give nothing for it.
# test_ui_coop fails if any of it is ever drawn.
#
# SPEED PER STEP: the lettering at a planned step's ghost is "n · 120 m/s", the
# speed the step ends at (step_labels, data planner.speed_labels).
#
# INPUT IS THIN. Every action is a public method a test calls directly; the
# mouse handlers (press / drag / release, screen points) only decide which one:
#
#   place_point(world_pt)        the next step steers for that point
#   begin_step / drag_step / end_step   the same, following a drag
#   begin_edit(k, world_pt)      re-drag planned step k (its handle)
#   set_step_band(k, band)       change one step's altitude band
#   change_band(+1 | 0 | -1)     climb / level / dive on the last placed step
#   undo() / clear()             drop the last step / the whole plan
#   ready_up()                   World.commit for the local player
#
# Every change goes through World.plan_step, which validates the step against
# the unit's envelope and returns the clamped state; nothing here moves a unit.
#
# TWO RULES FROM ALEX (2026-10-09), added by Track A:
#   * A step that ends outside the map is REFUSED: the plan stays as it was, the
#     call returns {}, and a small cross and "off the map" show where the point
#     was asked for (refused_world / refused_ms). Uses the out_of_bounds field of
#     the states plan_step returns. A unit already outside the map may plan its
#     way back.
#   * Editing a plan after Ready TAKES THE READY BACK (the player is un-readied
#     and the edit is made), so the last Ready always plays the turn.
#
# THE MAP RULE APPLIES TO THE WHOLE TURN (fix pass, 2026-10-09): carry-on steps
# are steps too, so Ready itself refuses while any step of any player unit's
# turn -- planned or carry-on, World.planned_states -- would end outside the map
# (ready_blocker / ready_up). The refusal marks the first such step with the same
# "off the map" cross, selects the plane and puts "<name> would leave the map:
# plan a turn" on the orders card (ready_notice) until a plan changes. A unit
# that starts the turn already outside is exempt (PROPOSED): it may not be able
# to get back in within one turn, and the rule would then lock Ready for good.

# HOVER (Track U2, Alex 2026-10-10: "we also need a visual indicator for
# selecting path nodes; it is hard to tell when you are close enough"): the
# pointer is fed in with set_pointer(screen_pt) (UnitUI does it on every mouse
# motion; clear_pointer() when it leaves the map) and hover() says what a press
# here would do: "grab" the NEAREST planned step's handle (within planner.
# handle_px; the old last-step-first rule is gone, crowded handles go to the
# closest), "place" the next step (the fan and its capture_px), or nothing. The
# handle shows as the pointer comes within planner.hover.near_factor x
# handle_px (state "near", approach 0..1), unmistakably inside handle_px (state
# "range") and stays lit while that step is dragged (state "drag"), drawn in the
# style planner.hover.mode names (variants/node-hover/); the mouse cursor
# follows (a pointing hand to grab, a grabbing hand dragging, a cross to place;
# reset whenever there is nothing to grab). Nothing hovers when the selected
# unit takes no orders: down, an AI unit's, not the planning phase.
#
# THE BOMB DROP (Track U3, the strike, 2026-10-10; Alex: bombing is "per step, just like
# diving. You set the intent in the cone." Accuracy follows how close the bomber is to the ideal
# release angle, and height; a bomber makes several drops). A step of a unit with bombs may
# carry a DROP: its request gains {"drop": {"aim": [x, y]}} (metres), and the aim must lie
# inside that step's BOMB CONE, World.drop_cone (reached through BombSource, the one place the
# interface asks the simulation about bombs). The calls, all thin like the rest:
#
#   set_step_drop(k, on)        turn step k's drop on (the aim starts at the cone's ideal aim) or off
#   toggle_drop()               the Drop button: the same on the step the card is about
#   place_aim(k, world_pt)      aim step k's drop at a point; REFUSED ({}) outside the cone
#   begin_aim(k, pt) / drag_aim(pt) / end_aim()    the aim handle dragged: the aim follows the
#                               pointer and is held inside the cone (as a step is held in its envelope)
#   drop_options(k)             {available, on, why}: what the Drop control may do for step k
#   drop_info(k)                {cone, aim, spread, quality, release, free, ...} for the card
#   bomb_marks()                the marks the cone node (bomb_aim.gd) draws, in screen px
#
# THE STEP THE CARD IS ABOUT (focus_step): Dive / Level / Climb and Drop act on one step, the
# LAST PLACED STEP until a step's handle (or its aim) is grabbed, then THAT step, until the plan
# changes shape (a step placed, undone, cleared) or another unit is selected. PROPOSED by U3: the
# Drop control needs a way to reach the earlier steps of a bomber that makes more than one
# drop, and the band buttons share it so the card is about one step at a time.
#
# Editing a step keeps its drop; if the new path moves the cone off the aim, the aim is moved to
# the nearest point still inside it (a cone the step no longer has takes the drop off). The aim
# is part of the plan: editing it, undoing, clearing, Ready and last-edit-wins are the plan's.
# EVERYTHING DRAWN FOR A DROP goes through plan_shown, so an AI unit's drop is never shown.

signal plan_edited(unit_id: String)
signal ready_refused(unit_id: String)   # Ready was refused for this unit (or "": the notice was cleared)

const World = preload("res://scripts/sim/world.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")

var world: World = null
var mapping: UiMapping = null
var selection: RefCounted = null
var style: UiStyle = null
var local_player: String = "local"
# The bombs the simulation (or its stand-in) answers with; UnitUI shares one with the roster and the card.
var bombs: BombSource = null
# The unit marker layer, when the planner sits beside one (UnitUI sets it): the
# ghosts use the art the selected unit's own marker already holds, so a zoom
# never makes the planner bake art of its own.
var marker_layer: Object = null

# Why Ready was refused (see the header), "" when it was not: the orders card
# shows it. Cleared when a plan changes or the phase does.
var ready_notice: String = ""

# The last refused point (metres) and when (msec ticks): drawn for a moment.
var refused_world := Vector2.INF
var refused_ms: int = -100000
const REFUSED_SHOW_MS := 1600

var _drag_index: int = -1
var _drag_aim: int = -1             # the step whose aim handle is being dragged (-1: none)
var _focus: int = -1                # the step the card is about; -1: the last placed (see focus_step)
# The last aim refused for lying outside its cone (metres) and when: drawn for a moment, like the
# map rule's cross.
var refused_aim := Vector2.INF
var refused_aim_ms: int = -100000
# The mouse cursor shape this planner last asked the engine for (Input.CURSOR_*): the
# arrow unless a press here would do something; tests read it.
var cursor_shape: int = Input.CURSOR_ARROW
var _pointer := Vector2.INF         # the pointer, in this node's (screen) space; INF: not over the map
var _hover: Dictionary = {}         # see hover()
const _CURSORS := {
	"arrow": Input.CURSOR_ARROW, "pointing_hand": Input.CURSOR_POINTING_HAND, "cross": Input.CURSOR_CROSS,
	"drag": Input.CURSOR_DRAG, "move": Input.CURSOR_MOVE, "can_drop": Input.CURSOR_CAN_DROP,
}
const HOVER_EFFECTS := ["grow", "ring", "halo", "magnet", "label"]
var _paths: Dictionary = {}         # unit id -> Array of [PackedVector2Array world pts, planned: bool]
var _own_art: Dictionary = {}       # unit id -> Art: only used when there is no marker layer to borrow from

func setup(w: World, host_mapping: Variant, sel: RefCounted, player: String = "local", st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	world = w
	local_player = player
	selection = sel
	set_mapping(host_mapping)
	if bombs == null:
		bombs = BombSource.new()
	bombs.setup(world, style)
	if not world.plan_changed.is_connected(_on_plan_changed):
		world.plan_changed.connect(_on_plan_changed)
		world.phase_changed.connect(_on_phase_changed)
	if not selection.changed.is_connected(_on_selection):
		selection.changed.connect(_on_selection)
	_paths.clear()
	queue_redraw()

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	queue_redraw()

# --- Queries ---------------------------------------------------------------------

func unit_id() -> String:
	return selection.unit_id if selection != null else ""

# Whether a unit takes orders from this control: the planning phase and a
# player-controlled unit. A readied player may still edit: the edit takes the
# Ready back (see the header).
func can_plan(id: String = "") -> bool:
	if id == "":
		id = unit_id()
	if world == null or id == "" or not world.units.has(id):
		return false
	if world.phase != World.PHASE_PLANNING:
		return false
	var u = world.units[id]
	return u.controller == World.CONTROLLER_PLAYER and not bool(u.down)

# Whether a unit's plan may be DRAWN at all (path, ghosts, fan, clamps): the
# planning phase and a player-controlled unit that is not down. The one rule
# every drawing here goes through; an AI unit's plan is never shown.
func plan_shown(id: String) -> bool:
	if world == null or not world.units.has(id) or world.phase != World.PHASE_PLANNING:
		return false
	var u = world.units[id]
	return u.controller == World.CONTROLLER_PLAYER and not bool(u.down)

# An edit is being made: a readied local player is un-readied.
func _reopen() -> void:
	if world != null and world.phase == World.PHASE_PLANNING and world.is_ready(local_player):
		world.withdraw(local_player)

# Steps with an explicit request: the last non-empty request + 1.
func planned_count(id: String = "") -> int:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return 0
	var plan: Array = world.units[id].plan
	var n := plan.size()
	while n > 0 and (plan[n - 1] as Dictionary).is_empty():
		n -= 1
	return n

# The step the orders card is about (Dive / Level / Climb, Drop): the last placed step, or the
# step whose handle or aim was grabbed last while that is still a placed step of the selected
# unit's plan. -1 with nothing placed.
func focus_step(id: String = "") -> int:
	if id == "":
		id = unit_id()
	var n := planned_count(id)
	if n <= 0:
		return -1
	if id == unit_id() and _focus >= 0 and _focus < n:
		return _focus
	return n - 1

func set_focus_step(k: int) -> void:
	var n := planned_count()
	_focus = k if k >= 0 and k < n else -1
	queue_redraw()

# The step the next click places, or -1 when the plan is full or closed.
func next_step_index(id: String = "") -> int:
	if id == "":
		id = unit_id()
	if not can_plan(id):
		return -1
	var k := planned_count(id)
	return k if k < world.steps_per_turn(id) else -1

# World.reachable for the next step ({} when there is none).
func reachable_next() -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	return world.reachable(unit_id(), k)

func fan_outline_world() -> PackedVector2Array:
	var r := reachable_next()
	return r.get("outline", PackedVector2Array())

func fan_outline_screen() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in fan_outline_world():
		out.append(mapping.world_to_screen(p))
	return out

# Every step's state for the selected unit, planned and carry-on alike.
func states(id: String = "") -> Array:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return []
	return world.planned_states(id)

# The band a unit is in before step k.
func band_before(k: int, id: String = "") -> String:
	if id == "":
		id = unit_id()
	if k <= 0:
		return world.units[id].altitude_band
	return str((states(id)[k - 1] as Dictionary)["altitude_band"])

# --- Actions -------------------------------------------------------------------------

func place_point(world_pt: Vector2) -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	_focus = -1   # a new step is the last placed: the card is about it
	return _plan_point(k, world_pt)

func begin_step(world_pt: Vector2) -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	_focus = -1
	_set_drag(k)
	return _plan_point(k, world_pt)

func begin_edit(k: int, world_pt: Vector2) -> Dictionary:
	if not can_plan() or k < 0 or k >= planned_count():
		return {}
	_focus = k   # the card is about the step whose handle was grabbed
	_set_drag(k)
	return _plan_point(k, world_pt)

func drag_step(world_pt: Vector2) -> Dictionary:
	if _drag_index < 0 or not can_plan():
		return {}
	return _plan_point(_drag_index, world_pt)

func end_step() -> Dictionary:
	var k := _drag_index
	_set_drag(-1)
	if k < 0 or not can_plan():
		return {}
	return states()[k]

func is_dragging() -> bool:
	return _drag_index >= 0 or _drag_aim >= 0

# Step k steers for `world_pt`, keeping the band it asked for (if any).
func _plan_point(k: int, world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	var req := {"to": world_pt}
	var plan: Array = world.units[id].plan
	if k < plan.size() and (plan[k] as Dictionary).has("altitude_band"):
		req["altitude_band"] = (plan[k] as Dictionary)["altitude_band"]
	if k < plan.size() and (plan[k] as Dictionary).has("drop"):
		req["drop"] = ((plan[k] as Dictionary)["drop"] as Dictionary).duplicate(true)   # a step moved keeps its drop
	return _commit_step(id, k, req, world_pt)

# World.plan_step with the map rule: a plan with a PLANNED step that ends
# outside the map is put back as it was and {} comes back. `asked` is where the
# step was asked for (metres), for the refusal mark.
func _commit_step(id: String, k: int, req: Dictionary, asked: Vector2) -> Dictionary:
	var before: Array = (world.units[id].plan as Array).duplicate(true)
	var s := world.plan_step(id, k, req)
	if s.is_empty():
		return s
	if not bool(world.units[id].out_of_bounds):
		for st: Dictionary in world.planned_states(id):
			if bool(st["planned"]) and bool(st["out_of_bounds"]):
				world.clear_plan(id)
				for i in before.size():
					if not (before[i] as Dictionary).is_empty():
						world.plan_step(id, i, before[i])
				refused_world = asked
				refused_ms = Time.get_ticks_msec()
				return {}
	_fit_drops(id)
	_reopen()
	plan_edited.emit(id)
	return s

func set_step_band(k: int, band: String) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or k < 0 or k >= world.steps_per_turn(id):
		return {}
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true) if k < plan.size() else {}
	req["altitude_band"] = band
	var u = world.units[id]
	var at := Vector2(float(u.x), float(u.y))
	return _commit_step(id, k, req, at)

# Climb (+1), level (0) or dive (-1) on the last placed step, one band, as far
# as the unit's own bands go. {} when no step is placed yet.
func change_band(delta: int) -> Dictionary:
	var k := focus_step()
	if not can_plan() or k < 0:
		return {}
	var bands: Array[String] = world.units[unit_id()].def.envelope.bands
	var from := band_before(k)
	var i := clampi(bands.find(from) + signi(delta), 0, bands.size() - 1)
	return set_step_band(k, bands[i])

# Which band changes the last placed step can take: {-1: bool, 0: bool, 1: bool}.
func band_options() -> Dictionary:
	var out := {-1: false, 0: false, 1: false}
	var k := focus_step()
	if not can_plan() or k < 0:
		return out
	var bands: Array[String] = world.units[unit_id()].def.envelope.bands
	var reach: Array = world.reachable(unit_id(), k).get("bands", [])
	var i := bands.find(band_before(k))
	out[0] = true
	out[1] = i + 1 < bands.size() and reach.has(bands[i + 1])
	out[-1] = i - 1 >= 0 and reach.has(bands[i - 1])
	return out

# Drop the last planned step. World has no remove-one-step call, so the plan
# is cleared and the remaining requests planned again, in order (proposed for
# Track S: a truncate_plan(unit_id, n) would make this one call).
func undo() -> bool:
	var id := unit_id()
	var n := planned_count(id)
	if not can_plan(id) or n == 0:
		return false
	var keep: Array = (world.units[id].plan as Array).slice(0, n - 1).duplicate(true)
	_reopen()
	world.clear_plan(id)
	for i in keep.size():
		world.plan_step(id, i, keep[i])
	_focus = -1
	_set_drag(-1)
	plan_edited.emit(id)
	return true

func clear() -> void:
	var id := unit_id()
	if not can_plan(id):
		return
	_reopen()
	world.clear_plan(id)
	_focus = -1
	_set_drag(-1)
	plan_edited.emit(id)

# --- The bomb drop ----------------------------------------------------------------------------------

# The drop request of step k of a unit ({} when it has none): {"aim": [x, y]}.
func step_drop(k: int, id: String = "") -> Dictionary:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return {}
	var plan: Array = world.units[id].plan
	if k < 0 or k >= plan.size() or not (plan[k] as Dictionary).has("drop"):
		return {}
	var d: Variant = (plan[k] as Dictionary)["drop"]
	return (d as Dictionary).duplicate(true) if d is Dictionary else {}

# Where step k's drop is aimed (metres); Vector2.INF with no drop or no aim.
func step_aim(k: int, id: String = "") -> Vector2:
	var d := step_drop(k, id)
	return BombSource._v2(d.get("aim"))

func step_has_drop(k: int, id: String = "") -> bool:
	return not step_drop(k, id).is_empty()

# What the Drop control may do for step k (-1: the step the card is about): {step, available (it
# may be switched on, or off if it is on), on, why ("" when available, else the reason in words
# from data bombs.text)}.
func drop_options(k: int = -2) -> Dictionary:
	var id := unit_id()
	var out := {"step": -1, "available": false, "on": false, "why": ""}
	if k == -2:
		k = focus_step()
	out["step"] = k
	if not can_plan(id):
		return out
	if not bombs.has_bombs(id):
		out["why"] = style.text("bombs.text.no_bombs")
		return out
	if k < 0:
		out["why"] = style.text("bombs.text.place_first")
		return out
	var on := step_has_drop(k, id)
	out["on"] = on
	if on:
		out["available"] = true   # switching a drop off is always allowed
		return out
	if bombs.drops_free(id, k) <= 0:
		out["why"] = style.text("bombs.text.none_left")
		return out
	if not bool(bombs.cone(id, k)["ok"]):
		out["why"] = style.text("bombs.text.none_left")
		return out
	out["available"] = true
	return out

# The Drop button: the drop of the step the card is about, on or off. {} when it may not.
func toggle_drop() -> Dictionary:
	var k := focus_step()
	if k < 0:
		return {}
	return set_step_drop(k, not step_has_drop(k))

# Turn step k's drop on (aimed at the cone's ideal aim, or its middle) or off. The step must be
# a placed step of the selected unit's plan, the unit must have a drop free (and a cone for the step).
# Returns the step's state, or {} when refused.
func set_step_drop(k: int, on: bool) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or k < 0 or k >= world.steps_per_turn(id):
		return {}
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true) if k < plan.size() else {}
	if not on:
		if not req.has("drop"):
			return {}
		req.erase("drop")
	else:
		if req.has("drop"):
			return world.planned_states(id)[k]   # already on
		if not bombs.has_bombs(id) or bombs.drops_free(id, k) <= 0:
			return {}
		var cone: Dictionary = bombs.cone(id, k)
		if not bool(cone["ok"]):
			return {}
		var aim: Vector2 = cone["ideal_aim"]
		if not BombSource.inside(cone["polygon"], aim):
			aim = BombSource._centroid(cone["polygon"])
			if not BombSource.inside(cone["polygon"], aim):
				aim = BombSource.nearest_inside(cone["polygon"], aim)
		req["drop"] = {"aim": [aim.x, aim.y]}
	_focus = k
	var u = world.units[id]
	var s := _commit_step(id, k, req, Vector2(float(u.x), float(u.y)))
	queue_redraw()
	return s

# Aim step k's drop at `world_pt`. REFUSED -- {} and the plan as it was, the point marked for a
# moment -- when the point lies outside the step's bomb cone, when the step has no drop or none can
# be planned. Returns the step's state when taken.
func place_aim(k: int, world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or not step_has_drop(k, id):
		return {}
	var cone: Dictionary = bombs.cone(id, k)
	if not bool(cone["ok"]) or not BombSource.inside(cone["polygon"], world_pt):
		refused_aim = world_pt
		refused_aim_ms = Time.get_ticks_msec()
		queue_redraw()
		return {}
	return _write_aim(id, k, world_pt)

func _write_aim(id: String, k: int, world_pt: Vector2) -> Dictionary:
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true)
	req["drop"] = {"aim": [world_pt.x, world_pt.y]}
	var u = world.units[id]
	_focus = k
	return _commit_step(id, k, req, Vector2(float(u.x), float(u.y)))

# The aim handle dragged: begin_aim takes hold of step k's aim and moves it to `world_pt` (held
# inside the cone, as a dragged step is held in its envelope), drag_aim follows, end_aim lets go.
func begin_aim(k: int, world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or not step_has_drop(k, id):
		return {}
	_focus = k
	_set_drag_aim(k)
	return drag_aim(world_pt)

func drag_aim(world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	if _drag_aim < 0 or not can_plan(id) or not step_has_drop(_drag_aim, id):
		return {}
	var cone: Dictionary = bombs.cone(id, _drag_aim)
	if not bool(cone["ok"]):
		return {}
	var held := BombSource.nearest_inside(cone["polygon"], world_pt)
	return _write_aim(id, _drag_aim, held)

func end_aim() -> Dictionary:
	var k := _drag_aim
	_set_drag_aim(-1)
	var id := unit_id()
	if k < 0 or not can_plan(id) or not step_has_drop(k, id):
		return {}
	return world.planned_states(id)[k]

func is_aiming() -> bool:
	return _drag_aim >= 0

func _set_drag_aim(k: int) -> void:
	_drag_aim = k
	if k >= 0:
		_drag_index = -1
	_update_hover()

# After a step is edited the cones of the unit's steps are not the same: an aim that lies outside
# its (new) cone moves to the nearest point inside it, a drop whose step has no cone any more comes
# off. (The aim is part of the plan, so this is part of the edit.)
func _fit_drops(id: String) -> void:
	if bombs == null:
		return
	for k in bombs.drop_steps(id):
		var cone: Dictionary = bombs.cone(id, k)
		var plan: Array = world.units[id].plan
		var req: Dictionary = (plan[k] as Dictionary).duplicate(true)
		if not bool(cone["ok"]):
			req.erase("drop")
			world.plan_step(id, k, req)
			continue
		var aim := BombSource._v2((req["drop"] as Dictionary).get("aim"))
		if not aim.is_finite() or not BombSource.inside(cone["polygon"], aim):
			var fixed := BombSource.nearest_inside(cone["polygon"], aim if aim.is_finite() else cone["ideal_aim"])
			req["drop"] = {"aim": [fixed.x, fixed.y]}
			world.plan_step(id, k, req)

# What the card and the map say about step k's drop: {cone (metres), aim, ideal_aim, spread
# {along_m, across_m, heading}, quality 0..1, release (metres), free (drops still free to plan),
# source}. {} when step k has no drop.
func drop_info(k: int = -2) -> Dictionary:
	var id := unit_id()
	if k == -2:
		k = focus_step()
	if not plan_shown(id) or not step_has_drop(k, id):
		return {}
	var cone: Dictionary = bombs.cone(id, k)
	var aim := step_aim(k, id)
	if not bool(cone["ok"]) or not aim.is_finite():
		return {}
	var info: Dictionary = bombs.aim_info(id, k, aim)
	return {"step": k, "cone": cone["polygon"], "aim": aim, "ideal_aim": cone["ideal_aim"], "spread": info["spread"],
		"quality": float(info["quality"]), "release": info["release"], "free": bombs.drops_free(id),
		"path": cone["path"]}

# The marks for the bomb node, in screen px (the record bomb_aim_art.gd documents): the full
# cone and aim of the step the card is about (while its drop is on), a small mark for every
# other drop of the selected unit and of any other player unit. NOTHING for a unit whose plan
# may not be shown (plan_shown): an AI unit's drops are never drawn.
func bomb_marks() -> Array:
	var out: Array = []
	if world == null or bombs == null or world.phase != World.PHASE_PLANNING:
		return out
	var sel := unit_id()
	for id: String in world.units:
		if not plan_shown(id) or not bombs.has_bombs(id):
			continue
		var focus_k := focus_step(id) if id == sel else -1
		for k in bombs.drop_steps(id):
			var rec := _bomb_mark(id, k, k == focus_k)
			if not rec.is_empty():
				out.append(rec)
	return out

func _bomb_mark(id: String, k: int, full: bool) -> Dictionary:
	var cone: Dictionary = bombs.cone(id, k)
	var plan: Array = world.units[id].plan
	var aim := BombSource._v2(((plan[k] as Dictionary)["drop"] as Dictionary).get("aim"))
	if not bool(cone["ok"]) or not aim.is_finite():
		return {}
	var info: Dictionary = bombs.aim_info(id, k, aim)
	var ppm: float = mapping.px_per_m(aim)
	var sp: Dictionary = info["spread"]
	var poly := PackedVector2Array()
	if full:
		for q: Vector2 in cone["polygon"]:
			poly.append(mapping.world_to_screen(q))
	var rel: Vector2 = info["release"]
	var u = world.units[id]
	var quality := float(info["quality"])
	return {
		"unit": id, "step": k, "quiet": not full, "side": str(u.side),
		"cone": poly, "aim": mapping.world_to_screen(aim),
		"ideal": mapping.world_to_screen(cone["ideal_aim"]) if (cone["ideal_aim"] as Vector2).is_finite() else Vector2.INF,
		"release": mapping.world_to_screen(rel) if rel.is_finite() else Vector2.INF,
		"spread": {"a": float(sp["along_m"]) * ppm, "b": float(sp["across_m"]) * ppm, "angle": mapping.screen_angle(aim, float(sp["heading"]))},
		"quality": quality, "ppm": ppm, "seed": (hash(id) & 0xFFFF) * 31 + k,
		"label": ("%d%%" % roundi(quality * 100.0)) if full else "",
	}

# The Ready button: commit for the local player. True when everyone is ready
# (the World does not resolve by itself; the owner -- UnitUI -- decides when).
# False, and nobody readied, when a player unit's turn would leave the map (see
# the header): ready_notice says which plane.
func ready_up() -> bool:
	if world == null or world.phase != World.PHASE_PLANNING:
		return false
	var blocked := ready_blocker()
	if not blocked.is_empty():
		_refuse_ready(blocked)
		return false
	ready_notice = ""
	return world.commit(local_player)

# The first step, of any player-controlled unit, that would end outside the map:
# {unit, step, at (metres)} or {} when every step of every turn stays on it.
# Planned and carry-on steps alike (World.planned_states); a unit that already
# starts the turn outside the map is exempt (see the header).
func ready_blocker() -> Dictionary:
	if world == null:
		return {}
	for id: String in world.units:
		var u = world.units[id]
		if u.controller != World.CONTROLLER_PLAYER or bool(u.out_of_bounds) or bool(u.down):
			continue   # (a down unit takes no orders: it cannot hold the turn up)
		var st := world.planned_states(id)
		for k in st.size():
			var s: Dictionary = st[k]
			if bool(s["out_of_bounds"]):
				return {"unit": id, "step": k, "at": Vector2(float(s["x"]), float(s["y"]))}
	return {}

func _refuse_ready(blocked: Dictionary) -> void:
	var id: String = blocked["unit"]
	refused_world = blocked["at"]
	refused_ms = Time.get_ticks_msec()
	ready_notice = "%s would leave the map: plan a turn" % Roster.unit_name(world.units[id])
	if selection != null and selection.unit_id != id:
		selection.select(id)   # the plane that needs the plan, with its fan up
	ready_refused.emit(id)
	queue_redraw()

# --- Pointer (screen points in this node's space) ------------------------------------

# The planned step whose handle is nearest to `screen_pt` within `max_px`:
# {step, dist (px), screen (its place)}, or {} when none is that close. The
# nearest wins; a tie (two steps ending on one point) goes to the later step.
func nearest_handle(screen_pt: Vector2, max_px: float = INF) -> Dictionary:
	if not can_plan():
		return {}
	var best := _nearest_step_handle(screen_pt, max_px)
	# The AIM handles of the steps that drop (Track U3) compete on the same terms; a tie goes to a step.
	var best_d: float = float(best["dist"]) if not best.is_empty() else max_px
	for k in bombs.drop_steps(unit_id()):
		var a := step_aim(k)
		if not a.is_finite():
			continue
		var p: Vector2 = mapping.world_to_screen(a)
		var d := p.distance_to(screen_pt)
		if d < best_d:
			best_d = d
			best = {"step": k, "kind": "aim", "dist": d, "screen": p}
	return best

# The step handles alone, as this was before aim handles: {step, kind: "step", dist, screen}.
func _nearest_step_handle(screen_pt: Vector2, max_px: float) -> Dictionary:
	var st := states()
	var best := {}
	var best_d := max_px
	for k in planned_count():
		var s: Dictionary = st[k]
		var p: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
		var d := p.distance_to(screen_pt)
		if d <= best_d:
			best_d = d
			best = {"step": k, "kind": "step", "dist": d, "screen": p}
	return best

# Which planned step's handle a press at `screen_pt` would grab: the NEAREST one
# within planner.handle_px, or -1. (It was the last step within the radius, which
# took a crowded neighbour's handle from it.) STEP handles only; grab_at also
# knows the aim handles.
func handle_at(screen_pt: Vector2) -> int:
	return int(_nearest_step_handle(screen_pt, style.num("planner.handle_px")).get("step", -1))

# The handle of any kind a press at `screen_pt` would grab: {step, kind ("step" | "aim"),
# dist, screen}, or {}.
func grab_at(screen_pt: Vector2) -> Dictionary:
	return nearest_handle(screen_pt, style.num("planner.handle_px"))

# Whether a press at `screen_pt` would move the aim of the step the card is about: its drop is on
# and the point is inside its bomb cone.
func in_bomb_cone(screen_pt: Vector2) -> bool:
	var id := unit_id()
	var k := focus_step(id)
	if not can_plan(id) or k < 0 or not step_has_drop(k, id):
		return false
	var cone: Dictionary = bombs.cone(id, k)
	return bool(cone["ok"]) and BombSource.inside(cone["polygon"], mapping.screen_to_world(screen_pt))

# Whether a press at `screen_pt` starts a new step: inside the fan, or within
# capture_px of it.
func in_fan(screen_pt: Vector2) -> bool:
	var poly := fan_outline_screen()
	if poly.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(screen_pt, poly):
		return true
	var cap: float = style.num("planner.capture_px")
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(screen_pt, poly[i], poly[(i + 1) % poly.size()])
		if q.distance_to(screen_pt) <= cap:
			return true
	return false

func press(screen_pt: Vector2) -> bool:
	var g := grab_at(screen_pt)
	var wp: Vector2 = mapping.screen_to_world(screen_pt)
	if not g.is_empty():
		if str(g["kind"]) == "aim":
			begin_aim(int(g["step"]), wp)
		else:
			begin_edit(int(g["step"]), wp)
		return true
	if in_fan(screen_pt):
		begin_step(wp)
		return true
	if in_bomb_cone(screen_pt):
		begin_aim(focus_step(), wp)   # (the cone is far from the fan, so they seldom meet; the fan wins where they do)
		return true
	return false

func drag(screen_pt: Vector2) -> bool:
	if _drag_aim >= 0:
		drag_aim(mapping.screen_to_world(screen_pt))
		return true
	if _drag_index < 0:
		return false
	drag_step(mapping.screen_to_world(screen_pt))
	return true

func release(screen_pt: Vector2) -> bool:
	if _drag_aim >= 0:
		drag_aim(mapping.screen_to_world(screen_pt))
		end_aim()
		return true
	if _drag_index < 0:
		return false
	drag_step(mapping.screen_to_world(screen_pt))
	end_step()
	return true

# --- Hover: what a press here would do ------------------------------------------------------

func _set_drag(k: int) -> void:
	_drag_index = k
	if k >= 0:
		_drag_aim = -1
	_update_hover()

# The pointer is at `screen_pt` (this node's space, the map layer's).
func set_pointer(screen_pt: Vector2) -> void:
	_pointer = screen_pt
	_update_hover()

# The pointer left the map (onto a card, out of the window).
func clear_pointer() -> void:
	_pointer = Vector2.INF
	_update_hover()

func pointer() -> Vector2:
	return _pointer

# What a press at `screen_pt` would do: "grab" (a handle within handle_px:
# begin_edit), "place" (inside the fan or its capture_px: begin_step) or "" --
# the rule press() follows.
func press_action(screen_pt: Vector2) -> String:
	if not grab_at(screen_pt).is_empty():
		return "grab"
	if can_plan() and in_fan(screen_pt):
		return "place"
	if in_bomb_cone(screen_pt):
		return "aim"
	return ""

# The hover state, as data: state ("none" | "near" | "range" | "drag"), step (the
# handle it is about, -1), kind ("step" | "aim": which handle, "" with none), dist_px
# (pointer to that handle), approach (0 at near_factor x handle_px, 1 at handle_px and
# inside), place (a press would place the next step), action ("grab" | "place" | "aim" |
# ""), pointer, handle_screen.
func hover() -> Dictionary:
	if _hover.is_empty():
		_update_hover()
	return _hover.duplicate()

func _update_hover() -> void:
	var h := {"state": "none", "step": -1, "kind": "", "dist_px": INF, "approach": 0.0, "place": false, "action": "",
		"pointer": _pointer, "handle_screen": Vector2.INF}
	if style != null and world != null and mapping != null and _pointer.is_finite() and can_plan():
		var radius: float = style.num("planner.handle_px")
		var near: float = radius * style.num("planner.hover.near_factor")
		if _drag_aim >= 0:
			var a := step_aim(_drag_aim)
			if a.is_finite():
				var pa: Vector2 = mapping.world_to_screen(a)
				h["handle_screen"] = pa
				h["dist_px"] = pa.distance_to(_pointer)
			h["state"] = "drag"
			h["step"] = _drag_aim
			h["kind"] = "aim"
			h["approach"] = 1.0
			h["action"] = "grab"
		elif _drag_index >= 0:
			var st := states()
			if _drag_index < st.size():
				var s: Dictionary = st[_drag_index]
				var p: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
				h["handle_screen"] = p
				h["dist_px"] = p.distance_to(_pointer)
			h["state"] = "drag"
			h["step"] = _drag_index
			h["kind"] = "step"
			h["approach"] = 1.0
			h["action"] = "grab"
		else:
			var n := nearest_handle(_pointer, near)
			if not n.is_empty():
				h["step"] = n["step"]
				h["kind"] = n["kind"]
				h["dist_px"] = n["dist"]
				h["handle_screen"] = n["screen"]
				if float(n["dist"]) <= radius:
					h["state"] = "range"
					h["approach"] = 1.0
				else:
					h["state"] = "near"
					h["approach"] = smoothstep(near, radius, float(n["dist"]))
			if h["state"] != "range" and in_fan(_pointer):
				h["place"] = true
			h["action"] = "grab" if h["state"] == "range" else ("place" if h["place"] else "")
			if h["action"] == "" and in_bomb_cone(_pointer):
				h["action"] = "aim"
	_hover = h
	_apply_cursor()
	queue_redraw()

# The mouse cursor for what a press would do; the arrow when nothing, and always
# put back to the arrow when this planner stops asking for another.
func _apply_cursor() -> void:
	var want: int = Input.CURSOR_ARROW
	if style != null and style.flag("planner.hover.cursor.enabled"):
		var key := ""
		if str(_hover.get("state", "none")) == "drag":
			key = "planner.hover.cursor.drag"
		elif str(_hover.get("action", "")) == "grab":
			key = "planner.hover.cursor.grab"
		elif str(_hover.get("action", "")) == "place":
			key = "planner.hover.cursor.place"
		elif str(_hover.get("action", "")) == "aim":
			key = "planner.hover.cursor.aim"
		if key != "":
			want = int(_CURSORS.get(style.text(key), Input.CURSOR_ARROW))
	if want != cursor_shape:
		cursor_shape = want
		Input.set_default_cursor_shape(want as Input.CursorShape)

func _exit_tree() -> void:
	if cursor_shape != Input.CURSOR_ARROW:
		cursor_shape = Input.CURSOR_ARROW
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)

func _hover_effects() -> PackedStringArray:
	return style.text("planner.hover.mode").split("+", false)

# --- Drawing ---------------------------------------------------------------------------

func _on_plan_changed(id: String) -> void:
	_paths.erase(id)
	_update_hover()
	if ready_notice != "" and world.units.has(id) and world.units[id].controller == World.CONTROLLER_PLAYER:
		ready_notice = ""
		ready_refused.emit("")   # (the card redraws)
	queue_redraw()

func _on_phase_changed(_phase: String) -> void:
	_paths.clear()
	_focus = -1
	_drag_aim = -1
	_set_drag(-1)
	ready_notice = ""
	queue_redraw()

func _on_selection(_id: String) -> void:
	_focus = -1
	_drag_aim = -1
	_set_drag(-1)
	queue_redraw()

func _process(_delta: float) -> void:
	if _pointer.is_finite():
		_update_hover()   # the camera may move under a still pointer
	queue_redraw()  # the host's camera may move; the drawing is a handful of lines

# The turn's curve in world metres, per step: [points, planned]. Nothing for a
# unit whose plan may not be shown (an AI unit's, a down unit's, outside the
# planning phase): see plan_shown.
func path_world(id: String) -> Array:
	if not plan_shown(id):
		return []
	if _paths.has(id):
		return _paths[id]
	var out: Array = []
	var st := world.planned_states(id)
	var n := st.size()
	var dt := world.step_dt(id)
	var m := int(style.num("planner.samples_per_step"))
	var u = world.units[id]
	var prev := Vector2(float(u.x), float(u.y))
	for k in n:
		var pts := PackedVector2Array([prev])
		for j in range(1, m + 1):
			var t := dt * (float(k) + float(j) / float(m))
			var s := world.sample(id, t, "plan")
			pts.append(Vector2(float(s["x"]), float(s["y"])))
		var end := Vector2(float(st[k]["x"]), float(st[k]["y"]))
		pts[pts.size() - 1] = end
		out.append([pts, bool(st[k]["planned"])])
		prev = end
	_paths[id] = out
	return out

func _to_screen(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = mapping.world_to_screen(pts[i])
	return out

func _draw() -> void:
	if world == null or world.phase != World.PHASE_PLANNING:
		return
	var sel := unit_id()
	# Every other unit that takes the players' orders, thin and quiet, all the time.
	for id: String in world.units:
		if id != sel and plan_shown(id):
			_draw_curve(id, style.num("planner.others_alpha"), true)
	if sel == "" or not plan_shown(sel):
		_draw_refused()
		return
	_draw_hover_under()
	_draw_ghosts(sel)
	if can_plan(sel):
		_draw_fan()
	_draw_curve(sel, 1.0)
	_draw_clamps(sel)
	_draw_hover()
	_draw_refused()

func _fade(c: Color, k: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * k)

func _draw_fan() -> void:
	var poly := fan_outline_screen()
	if poly.size() < 3:
		return
	var n := poly.size() / 2
	# The fan's apex: where the step starts (the unit, or the previous step's end).
	var k := next_step_index()
	var apex_w := Vector2(float(world.units[unit_id()].x), float(world.units[unit_id()].y))
	if k > 0:
		var prev: Dictionary = states()[k - 1]
		apex_w = Vector2(float(prev["x"]), float(prev["y"]))
	var apex: Vector2 = mapping.world_to_screen(apex_w)
	# Spokes from the apex out to the far edge: the turn the step can take,
	# drawn as guides (the reachable region itself is only the inked band).
	var rib: Color = style.color("fan_rib")
	var edge: Color = style.color("fan_line")
	var rw: float = style.num("planner.rib_line_px")
	for i in n:
		var far := poly[i]
		var near := poly[poly.size() - 1 - i]
		if i == 0 or i == n - 1:
			UiInk.dashed(self, PackedVector2Array([apex, near]), _fade(edge, 0.7), rw, style.num("planner.dash_px") * 0.5, style.num("planner.gap_px") * 0.6)
		else:
			draw_line(apex.lerp(near, 0.55), near, rib, rw, true)
		draw_line(near, far, rib, rw, true)
	# A unit that cannot turn or change speed this step has a fan with no area
	# (a ship dead in the water): outline only, no fill to fail triangulating.
	if not Geometry2D.triangulate_polygon(poly).is_empty():
		draw_colored_polygon(poly, style.color("fan_fill"))
	UiInk.ink_line(self, poly, true, edge, style.num("planner.fan_line_px"), 31, 0.4)

# `quiet`: another unit's plan (data planner.others_*): thinner line, smaller dots.
func _draw_curve(id: String, alpha: float, quiet: bool = false) -> void:
	var solid := _fade(style.color("path"), alpha)
	var carry := _fade(style.color("path_carry"), alpha)
	var w: float = style.num("planner.others_line_px") if quiet else style.num("planner.path_line_px")
	var wc: float = style.num("planner.others_carry_line_px") if quiet else style.num("planner.carry_line_px")
	var dot: float = style.num("planner.others_dot_px") if quiet else style.num("planner.step_dot_px")
	for seg: Array in path_world(id):
		var pts := _to_screen(seg[0])
		if bool(seg[1]):
			draw_polyline(pts, solid, w, true)
			draw_circle(pts[pts.size() - 1], dot, solid, true, -1.0, true)
		else:
			UiInk.dashed(self, pts, carry, wc, style.num("planner.dash_px"), style.num("planner.gap_px"))
			draw_circle(pts[pts.size() - 1], dot * 0.8, carry, false, 1.0, true)

# The lettering at every step's ghost, as lines (empty for a step with none):
# a planned step's number and the speed it ends at ("2 · 120 m/s", data
# planner.speed_labels), and under it a change of altitude band ("climb to
# high"). Nothing for a unit whose plan may not be shown.
func step_labels(id: String = "") -> Array:
	if id == "":
		id = unit_id()
	var out: Array = []
	if not plan_shown(id):
		return out
	var u = world.units[id]
	var st := states(id)
	var prev_band: String = u.altitude_band
	var unit_txt: String = style.text("roster.speed_unit")
	var with_speed: bool = style.flag("planner.speed_labels")
	for k in st.size():
		var s: Dictionary = st[k]
		var lines := PackedStringArray()
		var with_height: bool = style.flag("labels.enabled")
		if bool(s["planned"]):
			var head := str(k + 1)
			if with_speed:
				head += " · %d %s" % [roundi(float(s["speed"])), unit_txt]
			if with_height:
				head += UiLabels.node_suffix(style, node_height_m(s))   # (Track U3: every node has a height and a speed)
			lines.append(head)
		elif with_height:
			lines.append(UiLabels.carry_text(style, float(s["speed"]), node_height_m(s)))   # a carry-on node: speed and height
		if step_has_drop(k, id):
			lines.append(style.text("bombs.text.step_tag"))   # a drop on this step (Track U3)
		var band := str(s["altitude_band"])
		if band != prev_band:
			var up: bool = u.def.envelope.bands.find(band) > u.def.envelope.bands.find(prev_band)
			lines.append(("climb to " if up else "dive to ") + band)
		out.append(lines)
		prev_band = band
	return out

# The height printed at a plan node (a step state): the simulation's band height, or the ground's by data (ui_labels.gd).
func node_height_m(s: Dictionary) -> float:
	var ground := Callable()
	if marker_layer != null and marker_layer.has_method("height_above_ground"):
		ground = Callable(marker_layer, "height_above_ground")
	return UiLabels.height_of(style, world, {"x": s["x"], "y": s["y"], "altitude_band": s["altitude_band"]}, ground)

# --- Hover drawing: ink, paper and the unit's own side accent only ------------------------------

# The step whose lettering is lit (effect "label"): the grabbed or dragged one.
func _hover_label_step() -> int:
	var state := str(_hover.get("state", "none"))
	if (state == "range" or state == "drag") and str(_hover.get("kind", "step")) != "aim" and _hover_effects().has("label"):
		return int(_hover["step"])
	return -1

# Under the plan line and the ghosts: the halo's paper pool.
func _draw_hover_under() -> void:
	var state := str(_hover.get("state", "none"))
	if state == "none" or str(_hover.get("kind", "step")) == "aim" or not _hover_effects().has("halo"):
		return
	var c: Vector2 = _hover["handle_screen"]
	var amt := float(_hover["approach"]) * (0.6 if state == "near" else 1.0)
	var paper := style.color("hover_paper")
	var r_full: float = style.num("planner.handle_px") * 0.8
	var soft: float = style.num("planner.hover.halo.soft_px")
	for i in 5:
		var r := r_full + soft * (1.0 - float(i) / 4.0)
		draw_circle(c, r, Color(paper.r, paper.g, paper.b, paper.a * amt * 0.34), true, -1.0, true)

func _draw_hover() -> void:
	var state := str(_hover.get("state", "none"))
	if state != "none" and str(_hover.get("kind", "step")) != "aim":   # (an aim handle's hover is the bomb node's: over the planes)
		var c: Vector2 = _hover["handle_screen"]
		var a := float(_hover["approach"])
		for fx: String in _hover_effects():
			match fx:
				"grow":
					_hv_grow(c, a, state)
				"ring":
					_hv_ring(c, a, state)
				"halo":
					_hv_halo(c, a, state)
				"magnet":
					_hv_magnet(c, a, state)
	_draw_place_mark()

# A press here would place the next step: a small plus at the pointer.
func _draw_place_mark() -> void:
	var r: float = style.num("planner.hover.place_mark_px")
	if r <= 0.0 or str(_hover.get("action", "")) != "place" or not _pointer.is_finite():
		return
	var ink: Color = style.color("hover_ink")
	var col := Color(ink.r, ink.g, ink.b, ink.a * 0.75)
	draw_line(_pointer + Vector2(-r, 0.0), _pointer + Vector2(r, 0.0), col, 1.0, true)
	draw_line(_pointer + Vector2(0.0, -r), _pointer + Vector2(0.0, r), col, 1.0, true)

func _hv_accent() -> Color:
	var u = world.units.get(unit_id())
	return style.side_color(str(u.side)) if u != null else style.color("hover_ink")

# The handle's own dot, drawn again over the hover's pools and rules.
func _hv_dot(c: Vector2, r: float) -> void:
	draw_circle(c, r + 1.4, style.color("hover_paper"), true, -1.0, true)
	draw_circle(c, r, style.color("hover_ink"), true, -1.0, true)

# "grow": the dot grows as the pointer comes in and fills when it can grab.
func _hv_grow(c: Vector2, a: float, state: String) -> void:
	var ink: Color = style.color("hover_ink")
	var paper: Color = style.color("hover_paper")
	var dot: float = style.num("planner.step_dot_px")
	var r: float
	match state:
		"near":
			r = lerpf(dot, style.num("planner.hover.grow.near_px"), a)
		"range":
			r = style.num("planner.hover.grow.range_px")
		_:
			r = style.num("planner.hover.grow.drag_px")
	draw_circle(c, r + 1.6, paper, true, -1.0, true)
	draw_circle(c, r, ink, true, -1.0, true)
	if state != "near":
		var lw: float = style.num("planner.hover.grow.line_px")
		draw_arc(c, r * 0.55, 0.0, TAU, 28, paper, 1.0, true)
		draw_arc(c, r + 3.2, 0.0, TAU, 40, ink, lw, true)
		if state == "drag":
			draw_circle(c, r * 0.36, _hv_accent(), true, -1.0, true)

# "ring": a ring round the handle through the pointer's distance, closing in as it
# approaches and locking at the pick radius, where a second rule joins it: the ring
# IS the grab zone.
func _hv_ring(c: Vector2, a: float, state: String) -> void:
	var radius: float = style.num("planner.handle_px")
	var near: float = radius * style.num("planner.hover.near_factor")
	var ink: Color = style.color("hover_ink")
	var cfg: String = "planner.hover.ring."
	if state == "near":
		var d := clampf(float(_hover["dist_px"]), radius, near)
		var col := Color(ink.r, ink.g, ink.b, ink.a * style.num(cfg + "near_alpha") * (0.5 + 0.5 * a))
		var pts := UiInk.circle_pts(c, d, 64)
		pts.append(pts[0])
		# A paper stroke under the dashes keeps them readable over the grove and the cone wash.
		var pp := style.color("hover_paper")
		draw_polyline(pts, Color(pp.r, pp.g, pp.b, pp.a * 0.55 * (0.4 + 0.6 * a)), style.num(cfg + "near_line_px") + 2.2, true)
		UiInk.dashed(self, pts, col, style.num(cfg + "near_line_px"), style.num(cfg + "dash_px"), style.num(cfg + "dash_px"))
		_hv_dot(c, style.num("planner.step_dot_px") + 0.8 * a)
		return
	var w: float = style.num(cfg + "range_line_px")
	draw_arc(c, radius, 0.0, TAU, 64, style.color("hover_paper"), w + 2.0, true)
	draw_arc(c, radius, 0.0, TAU, 64, ink, w, true)
	var gap: float = style.num(cfg + "second_gap_px")
	draw_arc(c, radius + gap, 0.0, TAU, 64, Color(ink.r, ink.g, ink.b, ink.a * 0.55), 0.7, true)
	_hv_dot(c, style.num("planner.step_dot_px") + 1.6)
	if state == "drag":
		var tick: float = style.num(cfg + "tick_px")
		var r2 := radius + gap
		for dir: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
			draw_line(c + dir * (r2 + 1.0), c + dir * (r2 + 1.0 + tick), ink, 1.2, true)
		draw_circle(c, 2.0, _hv_accent(), true, -1.0, true)

# "halo": the pool of paper under the line is _draw_hover_under; here the handle's
# own small ring over it.
func _hv_halo(c: Vector2, a: float, state: String) -> void:
	var ink: Color = style.color("hover_ink")
	_hv_dot(c, style.num("planner.step_dot_px") + (0.8 * a if state == "near" else 1.4))
	if state != "near":
		var rp: float = style.num("planner.hover.halo.ring_px")
		draw_arc(c, rp, 0.0, TAU, 32, ink, 1.3, true)
		if state == "drag":
			draw_arc(c, rp + 2.6, 0.0, TAU, 36, Color(ink.r, ink.g, ink.b, ink.a * 0.6), 0.8, true)

# "magnet": a line from the pointer to the handle -- dotted while approaching,
# solid and snapped to a ring in range.
func _hv_magnet(c: Vector2, a: float, state: String) -> void:
	var ink: Color = style.color("hover_ink")
	var p: Vector2 = _hover["pointer"]
	var w: float = style.num("planner.hover.magnet.line_px")
	var snap: float = style.num("planner.hover.magnet.snap_ring_px")
	if state == "near":
		var col := Color(ink.r, ink.g, ink.b, ink.a * style.num("planner.hover.magnet.near_alpha") * (0.4 + 0.6 * a))
		var dash: float = style.num("planner.hover.magnet.dash_px")
		var pp := style.color("hover_paper")
		draw_line(p, c, Color(pp.r, pp.g, pp.b, pp.a * 0.55 * (0.4 + 0.6 * a)), w * 0.8 + 2.0, true)
		UiInk.dashed(self, PackedVector2Array([p, c]), col, w * 0.8, dash, dash)
		_hv_dot(c, style.num("planner.step_dot_px") + 0.6 * a)
		return
	var d := p.distance_to(c)
	if d > snap + 0.5:
		var to := c + (p - c).normalized() * snap
		draw_line(p, to, style.color("hover_paper"), w + 2.0, true)
		draw_line(p, to, ink, w, true)
	draw_arc(c, snap, 0.0, TAU, 40, style.color("hover_paper"), 3.2, true)
	draw_arc(c, snap, 0.0, TAU, 40, ink, 1.5, true)
	_hv_dot(c, style.num("planner.step_dot_px") + 1.2)
	draw_circle(p, style.num("planner.hover.magnet.dot_px"), ink, true, -1.0, true)
	if state == "drag":
		draw_circle(c, 2.0, _hv_accent(), true, -1.0, true)

func _draw_ghosts(id: String) -> void:
	var u = world.units[id]
	var st := states(id)
	var labels := step_labels(id)
	var font: Font = style.font(true)
	var small: float = style.num("fonts.small_px")
	var ink: Color = style.color("label_ink")
	var carry_ink: Color = style.color("label_carry")
	var hl_k := _hover_label_step()
	for k in st.size():
		var s: Dictionary = st[k]
		var wp := Vector2(float(s["x"]), float(s["y"]))
		var sp: Vector2 = mapping.world_to_screen(wp)
		var ppm: float = mapping.px_per_m(wp)
		var planned := bool(s["planned"])
		var scale_k: float = style.num("marker.true_scale")
		var art: UnitMarkerArt.Art = _ghost_art(id, u, ppm * scale_k)
		if art != null and art.texture != null:
			var a: float = style.num("planner.ghost_alpha") if planned else style.num("planner.carry_ghost_alpha")
			var sc := ppm * scale_k / art.ppm
			draw_set_transform(sp, mapping.screen_angle(wp, float(s["heading"])) + PI / 2.0, Vector2(sc, sc))
			draw_texture(art.texture, -art.origin, Color(1.0, 1.0, 1.0, a))
			draw_set_transform_matrix(Transform2D.IDENTITY)
		var lines: PackedStringArray = labels[k]
		if not lines.is_empty() and UiLabels.shown(style, ppm):   # (the far zoom hides the labels: ui.json labels.hide_below_px_per_m)
			# Lettering on the sun side of the ghost, clear of the curve's own shadow side.
			var off: Vector2 = -style.shadow_dir() * (art.extent_m * ppm * scale_k + 6.0 if art != null else 14.0)
			var base := sp + off + Vector2(-4.0, 0.0)
			if k == hl_k:
				# The grabbed step's lettering on a paper plate, in full ink (hover effect "label").
				var wmax := 0.0
				for ln: String in lines:
					wmax = maxf(wmax, UiInk.text_width(font, ln, small))
				var pad: float = style.num("planner.hover.label.pad_px")
				var plate := Rect2(base + Vector2(-pad, -small * 0.9 - pad * 0.5),
					Vector2(wmax + pad * 2.0, (small + 1.0) * float(lines.size()) + pad))
				draw_rect(plate, style.color("hover_paper"), true)
				UiInk.ink_line(self, UiInk.rect_pts(plate), true, style.color("hover_ink"), 0.9, 41, 0.3)
				for li in lines.size():
					UiInk.text(self, font, base + Vector2(0.0, (small + 1.0) * float(li)), lines[li], small, style.color("hover_ink"))
			else:
				for li in lines.size():
					# the paper under-stroke the hover uses, so the lettering reads over the grove; a carry-on node's is fainter
					UiLabels.draw(self, style, font, base + Vector2(0.0, (small + 1.0) * float(li)), lines[li], small, ink if planned else carry_ink)

# The art a ghost of unit `id` is drawn with, scaled by the caller to the ghost's
# own screen scale. It is the art the unit's MARKER holds (no bake at all, and
# the marker already re-bakes only when the scale drifts past unit_art.rebake_ratio);
# with no marker layer (the planner alone) it keeps one art of its own and
# re-bakes it past the same ratio. Asking UnitMarkerArt.art_for every frame, as
# this once did, baked a new art on almost every zoom step: art_for caches by the
# scale rounded to 0.01 and each miss is a forced engine frame (measured
# 2026-10-09: 128 bakes in 120 frames, 9.7 ms mean and 32 ms worst per frame).
func _ghost_art(id: String, u: Object, want_ppm: float) -> UnitMarkerArt.Art:
	if marker_layer != null:
		var m: Object = marker_layer.marker(id)
		if m != null and m.art != null:
			return m.art
	var held: UnitMarkerArt.Art = _own_art.get(id)
	if held != null:
		var ratio := want_ppm / held.ppm
		var limit: float = style.num("unit_art.rebake_ratio")
		if ratio <= limit and ratio >= 1.0 / limit:
			return held
	var art: UnitMarkerArt.Art = UnitMarkerArt.art_for(style, u.def.silhouette, style.side_color(u.side), want_ppm)
	if art != null:
		_own_art[id] = art
	return art

# The mark for a step refused for leaving the map: a cross where it was asked
# for, with a short caption, for REFUSED_SHOW_MS.
func _draw_refused() -> void:
	var col: Color = style.color("clamp")
	if refused_aim.is_finite() and Time.get_ticks_msec() - refused_aim_ms <= REFUSED_SHOW_MS:
		var pa: Vector2 = mapping.world_to_screen(refused_aim)
		var xa := 5.0
		draw_line(pa + Vector2(-xa, -xa), pa + Vector2(xa, xa), col, 1.6, true)
		draw_line(pa + Vector2(-xa, xa), pa + Vector2(xa, -xa), col, 1.6, true)
		UiInk.text(self, style.font(true), pa + Vector2(9.0, 4.0), "outside the cone", style.num("fonts.small_px"), col)
	if not refused_world.is_finite() or Time.get_ticks_msec() - refused_ms > REFUSED_SHOW_MS:
		return
	var p: Vector2 = mapping.world_to_screen(refused_world)
	var x := 5.0
	draw_line(p + Vector2(-x, -x), p + Vector2(x, x), col, 1.6, true)
	draw_line(p + Vector2(-x, x), p + Vector2(x, -x), col, 1.6, true)
	UiInk.text(self, style.font(true), p + Vector2(9.0, 4.0), "off the map", style.num("fonts.small_px"), col)

func _draw_clamps(id: String) -> void:
	var st := states(id)
	var plan: Array = world.units[id].plan
	var col: Color = style.color("clamp")
	for k in mini(plan.size(), st.size()):
		var req: Dictionary = plan[k]
		var s: Dictionary = st[k]
		if not bool(s["clamped"]) or not req.has("to"):
			continue
		var to_v: Variant = req["to"]
		if not (to_v is Vector2):
			continue
		var a: Vector2 = mapping.world_to_screen(to_v)
		var b: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
		if a.distance_to(b) < 3.0:
			continue
		UiInk.dashed(self, PackedVector2Array([a, b]), col, 0.9, 3.0, 3.0)
		var x := 3.5
		draw_line(a + Vector2(-x, -x), a + Vector2(x, x), col, 1.1, true)
		draw_line(a + Vector2(-x, x), a + Vector2(x, -x), col, 1.1, true)
