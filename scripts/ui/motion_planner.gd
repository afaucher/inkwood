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
#                what is drawn is always the CLAMPED result. OFF (data
#                planner.clamp_marks false): Alex 2026-10-10, "The little X is where
#                I left the mouse when dragging the point. We don't care about that
#                at all." -- clamp_marks() then returns nothing and nothing is drawn
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
# THE STEP LABEL (Track L, 2026-10-10; Alex: "2 lines. Remove the step # as well"): the lettering at a step's ghost is two lines,
# the speed the step ends at over its height ("120 m/s" over "400 m"), no step number; a step with its special on adds the
# special's own words ("Bomb Drop") as a line of its own; a carry-on step has the same two lines, fainter (step_labels, data
# planner.speed_labels and labels.*). The block stands on the sun side of the ghost with its LAST line nearest the node, so a
# longer block grows away from the path (_draw_ghosts).
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
# THE SELECTED STEP (focus_step; Track B, 2026-10-10; Alex, decision step-selection: "I actually want to be able to set my
# motion and come back to step 2/3 and tell it to drop the bomb then." "Selecting the node should select that step in the
# plan."): the orders card is about ONE step -- Dive / Level / Climb and the special (Drop) act on it, its header names it --
# and that step is SELECTED on the map: its node stays filled, ringed and numbered (planner.select, node-hover's grow and fill
# made permanent). A press and release on a step's node, without dragging, selects it (press() grabs with the slop: nothing
# moves until the pointer has left planner.select.slop_px); dragging a node moves it and selects it; placing a step selects the
# new step; a landing point (the aim handle) pressed selects its step too. The selection lasts until another node is clicked,
# the plan changes shape (a step placed, undone, cleared: the last placed step is selected again) or the unit changes
# (PROPOSED: no per-unit memory). It works for every unit. Before this the card followed the LAST PLACED step until a handle was
# grabbed (U3's proposal), which the player could not see.
#
# THE DROP, PINNED TO ITS STEP (Track B, PROPOSED; data bombs.pin): every step of the selected unit with its special on is ONE
# picture -- a line from the step's node to where the bombs land, ending in the area of effect at the target, the target's mark and
# the step's number -- that no other step's placing or moving shifts. The bomb cone is only a thin outline from the selected
# step, while the pointer is over the special's button (set_drop_hover; the card tells us) or a landing point is dragged. The
# step's node carries a small bomb, and its lettering says the special's own words ("Bomb Drop", the unit's data: Alex, "it
# should SAY in the step metadata the name of the special and the action").
#
# Editing a step keeps its drop AND its target (Track T): a step moved or re-banded whose cone no longer holds the
# target is MARKED (drop_blocked, the map's slash, the card's line) and what the sim then does is its switch
# (data/sim/bombs.json outside_cone_mode: "hold" releases nothing, "poor_shot" releases a poor stick); the aim is no
# longer moved into the cone behind the player's back. The aim is part of the plan: editing it, undoing, clearing,
# Ready and last-edit-wins are the plan's.
# EVERYTHING DRAWN FOR A DROP goes through plan_shown, so an AI unit's drop is never shown.
#
# THE TARGET (Track T, 2026-10-10; Alex, decision special-targeting: "when you have a friendly unit selected, you can also
# select either an enemy unit or a point on the map. The only thing it does is show on the side view and it is the target
# that the special will use if activated." "No target set means you can't activate special." "The special is active and
# targeted for the step."): the player's target SELECTION is `target` (ui_target.gd, one object UnitUI shares). Drop (a step's
# special) is on offer only with a target set and inside THAT step's cone; switching it on stores the target ON THE STEP --
# {"drop": {"aim": [x, y], "target": {"unit": id} | {"point": [x, y]}}} -- and puts the aim on it, so one unit can carry
# different targets on different steps and nothing is remembered per unit. A unit target FOLLOWS the unit (Alex: "Targeting a
# moving unit like a tank should follow the unit"): the aim stored is where the unit is SHOWN (no projection of an enemy's
# motion here; the sim resolves the release against where the unit goes). Dragging a step's aim handle moves that step's
# target: it becomes a point, held inside the cone. The calls:
#
#   step_target(k)              {} or {"unit": id or "", "point": Vector2}: the target stored with step k's special (the seam
#                               Track V reads; nothing for a unit whose plan may not be shown)
#   target_in_cone(k)           whether the target selection lies inside step k's bomb cone
#   drop_blocked(k)             step k carries a drop whose aim lies OUTSIDE its cone (it will not release, or is a poor shot)

signal plan_edited(unit_id: String)
signal ready_refused(unit_id: String)   # Ready was refused for this unit (or "": the notice was cleared)

const World = preload("res://scripts/sim/world.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const GunSource = preload("res://scripts/ui/gun_source.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")
const UiTarget = preload("res://scripts/ui/ui_target.gd")

var world: World = null
var mapping: UiMapping = null
var selection: RefCounted = null
var style: UiStyle = null
var local_player: String = "local"
# The bombs the simulation (or its stand-in) answers with; UnitUI shares one with the roster and the card.
var bombs: BombSource = null
# The big guns the simulation answers with (Track SH, gun_source.gd); the planner makes its own.
var guns: GunSource = null
# The target selection (Track T, ui_target.gd): UnitUI shares one with the map marks and the side view; a planner alone
# makes its own.
var target: UiTarget = null
# unit_id -> bool: whether the player can see that unit (the fog's say); UnitUI points it at its own. Unset: all are in sight.
var unit_visible: Callable = Callable()
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
var _aim_grab := Vector2.INF        # where the aim handle was grabbed (metres): the drag moves nothing until it leaves the slop
var _aim_moved: bool = false        # whether the aim drag has left the slop (and so the target has become a point)
const PLACING := -2                 # _focus when the NEXT step, not a placed one, is the selected step (select_next_step)
var _focus: int = -1                # the SELECTED step; -1: the last placed (see focus_step); PLACING: the next one
var _focus_n: int = -1              # the number of planned steps when it was selected: the plan changing shape drops the selection
var _edit_grab := Vector2.INF       # where a node was pressed (metres): the drag moves nothing until the pointer leaves the slop
var _edit_moved: bool = true        # whether the node drag has left the slop (false: a press that may still turn out a click)
var _edit_last_moved: bool = true   # the same for the drag that ended last (a click is false)
var _drop_hover: bool = false       # the pointer is over the special's button on the card (set_drop_hover)
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
	if guns == null:
		guns = GunSource.new()
	guns.setup(world, style)
	if target == null:
		target = UiTarget.new()
	if not target.changed.is_connected(_on_target_changed):
		target.changed.connect(_on_target_changed)
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

# The SELECTED step, the one the orders card is about (Dive / Level / Climb, the special): the step
# clicked or dragged last or the one just placed, while the plan still has the shape it had then,
# else the last placed step. -1 with nothing placed.
func focus_step(id: String = "") -> int:
	if id == "":
		id = unit_id()
	var n := planned_count(id)
	if n <= 0:
		return -1
	if id == unit_id() and _focus == PLACING and _focus_n == n:
		return -1   # the NEXT step is the selected one (the card's step strip): nothing placed is
	if id == unit_id() and _focus >= 0 and _focus < n and _focus_n == n:
		return _focus
	return n - 1

# Selects step k of the selected unit's plan (-1, or a step that is not placed: the last placed one).
func set_focus_step(k: int) -> void:
	var n := planned_count()
	_focus = k if k >= 0 and k < n else -1
	_focus_n = n
	queue_redraw()

# Selects the NEXT step, the one the fan places (Alex, the orders card's step strip: "You can only click an already planned step or
# the next unplanned."): no placed step is selected -- the card says "step 3 of 3 next", Dive / Level / Climb and the special have
# no step to act on -- and the next click in the fan places it, which selects it. False when there is no next step (the plan is
# full, or the unit takes no orders).
func select_next_step() -> bool:
	if next_step_index() < 0:
		return false
	_focus = PLACING
	_focus_n = planned_count()
	queue_redraw()
	return true

# Whether the next step is the selected one (see select_next_step); true too with nothing placed, where it is the only step there is.
func is_placing() -> bool:
	if next_step_index() < 0:
		return false
	return focus_step() < 0

# (the same, under the name the selection now has)
func select_step(k: int) -> void:
	set_focus_step(k)

func selected_step(id: String = "") -> int:
	return focus_step(id)

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
	_focus = -1   # a new step is the last placed: it is the selected one
	return _plan_point(k, world_pt)

func begin_step(world_pt: Vector2) -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	_focus = -1
	_set_drag(k)
	return _plan_point(k, world_pt)

# Takes hold of planned step k's node and SELECTS the step. `grab` (a press on the node itself, press() does it): nothing moves
# until the pointer has left planner.select.slop_px, so a press and release is a CLICK that only selects; without it the step
# steers for `world_pt` at once, as a drag from a point (the calls a test makes) always did.
func begin_edit(k: int, world_pt: Vector2, grab: bool = false) -> Dictionary:
	if not can_plan() or k < 0 or k >= planned_count():
		return {}
	set_focus_step(k)   # the card is about the step whose node was pressed
	_set_drag(k)
	_edit_grab = world_pt
	_edit_moved = not grab
	if grab:
		return states()[k]
	return _plan_point(k, world_pt)

func drag_step(world_pt: Vector2) -> Dictionary:
	if _drag_index < 0 or not can_plan():
		return {}
	if not _edit_moved:
		var slop: float = style.num("planner.select.slop_px") / maxf(mapping.px_per_m(world_pt), 1e-6)
		if world_pt.distance_to(_edit_grab) <= slop:
			return states()[_drag_index]
		_edit_moved = true
	return _plan_point(_drag_index, world_pt)

# Whether the node drag last begun has moved the step (left the slop): false for a plain click on a node.
func edit_was_moved() -> bool:
	return _edit_moved if _drag_index >= 0 else _edit_last_moved

func end_step() -> Dictionary:
	var k := _drag_index
	_edit_last_moved = _edit_moved
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
	if k < plan.size() and (plan[k] as Dictionary).has("fire"):
		req["fire"] = ((plan[k] as Dictionary)["fire"] as Dictionary).duplicate(true)   # ... and its fire (Track SH)
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
# from data bombs.text)}. TRACK T (Alex: "No target set means you can't activate special"; a target outside
# the step's cone: "the special cannot be activated on that step and the card says why"): on offer only with a
# target set that lies inside THAT step's cone.
func drop_options(k: int = -2) -> Dictionary:
	var id := unit_id()
	var out := {"step": -1, "available": false, "on": false, "why": ""}
	if k == -2:
		k = focus_step()
	out["step"] = k
	if not can_plan(id):
		return out
	if special_kind(id) == "gun":
		return _fire_options(k, out)   # the unit's special is a gun salvo (Track SH): the same control, the sim's reasons
	if not bombs.has_bombs(id):
		out["why"] = style.text("bombs.text.no_bombs")
		return out
	var label := special_label(id)
	if k < 0:
		out["why"] = style.text("bombs.text.place_first") % label
		return out
	var on := step_has_drop(k, id)
	out["on"] = on
	if on:
		out["available"] = true   # switching a drop off is always allowed
		return out
	if bombs.drops_free(id, k) <= 0:
		out["why"] = style.text("bombs.text.none_left") % label
		return out
	if not bool(bombs.cone(id, k)["ok"]):
		out["why"] = style.text("bombs.text.none_left") % label
		return out
	if not target.is_set():
		out["why"] = style.text("bombs.text.no_target") % label
		return out
	if not target_in_cone(k):
		out["why"] = style.text("bombs.text.target_outside") % (k + 1)
		return out
	out["available"] = true
	return out

# THE WORDS OF THE SPECIAL (Alex: "it should SAY in the step metadata the name of the special and the action. So Radio On, Bomb
# Drop, Turret Fire."): the bomb drop of a unit as its own data names it, "Bomb Drop" (data/units/<id>.json specials, read through
# UnitDef.special_label). A unit with no special gets the neutral word of bombs.text.label (its button is off).
func special_label(id: String = "") -> String:
	if id == "":
		id = unit_id()
	if world != null and world.units.has(id):
		var words: String = world.units[id].def.special_label(special_id(id))
		if words != "":
			return words
	return style.text("bombs.text.label")

# What kind of special the unit has (Track SH): "bomb" (a bomb drop), "gun" (a gun salvo), or "" for a unit with none.
func special_kind(id: String = "") -> String:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return ""
	if world.units[id].def.special_label("bomb") != "":
		return "bomb"
	if guns != null and guns.has_guns(id):
		return "gun"
	return ""

# The id of the unit's special in its data ("bomb", "main_guns"), "" for none.
func special_id(id: String = "") -> String:
	var kind := special_kind(id)
	if kind == "bomb":
		return "bomb"
	if kind == "gun":
		return guns.special_id(id if id != "" else unit_id())
	return ""

# Whether the unit has a special of its own to name (a bomb drop or a gun salvo).
func has_special(id: String = "") -> bool:
	return special_kind(id) != ""

# THE TARGET IN WORDS, for the orders card; always on offer while the selected unit carries a special ("" for a unit with none, or
# one whose plan may not be shown): "target: radio tower" / "target: a point on the map" -- the SELECTED step's own target when its
# special is on, else the target selection the special would take -- or "no target: click an enemy or right-click the map".
func target_line() -> String:
	var id := unit_id()
	if world == null or not can_plan(id) or not (bombs.has_bombs(id) or special_kind(id) == "gun"):
		return ""
	var k := focus_step(id)
	var tgt := step_target(k, id) if k >= 0 else {}
	if not tgt.is_empty():
		return _target_words(str(tgt.get("unit", "")))
	if target != null and target.is_set():
		return _target_words(target.unit_id if target.is_unit() else "")
	return style.text("bombs.text.target_none")

func _target_words(unit: String) -> String:
	if unit != "" and world.units.has(unit):
		return style.text("bombs.text.target_unit") % str(world.units[unit].def.name).to_lower()
	return style.text("bombs.text.target_point")

# The pointer is over the special's button on the card (the card tells us): the selected step's bomb cone shows as a thin outline.
func set_drop_hover(on: bool) -> void:
	if _drop_hover != on:
		_drop_hover = on
		queue_redraw()

func drop_hover() -> bool:
	return _drop_hover

# Whether the selected step's bomb cone is drawn (data bombs.pin.cone): only as a thin outline, only while the pointer is over the
# special's button or a landing point is being dragged. (With bombs.pin.enabled off the old looks decide, bomb_marks.)
func cone_outline_shown() -> bool:
	if not style.flag("bombs.pin.cone.enabled"):
		return false
	return (_drop_hover and style.flag("bombs.pin.cone.on_button_hover")) or (_drag_aim >= 0 and style.flag("bombs.pin.cone.on_aim_drag"))

# Whether the target selection lies inside step k's bomb cone (false with no target or no cone).
func target_in_cone(k: int) -> bool:
	var id := unit_id()
	if target == null or not target.is_set() or k < 0 or not bombs.has_bombs(id):
		return false
	var cone: Dictionary = bombs.cone(id, k)
	var at := target.position_m(world)
	return bool(cone["ok"]) and at.is_finite() and BombSource.inside(cone["polygon"], at)

# The target stored with step k's special: {} when the step has none (or the plan may not be shown), else
# {"unit": id or "", "point": Vector2}. A unit target's point is the aim stored with it: where the unit was shown
# when the special was activated. This is the seam Track V reads (see ui_target.gd).
func step_target(k: int, id: String = "") -> Dictionary:
	if id == "":
		id = unit_id()
	if not plan_shown(id):
		return {}
	var d := step_drop(k, id)
	if d.is_empty():
		d = step_fire(k, id)   # (Track SH: a gun salvo's step stores its target the same way)
	if d.is_empty():
		return {}
	var aim := BombSource._v2(d.get("aim"))
	var t: Variant = d.get("target")
	if t is Dictionary:
		var td: Dictionary = t
		if td.has("unit"):
			return {"unit": str(td["unit"]), "point": aim}
		if td.has("point"):
			return {"unit": "", "point": BombSource._v2(td["point"])}
	return {"unit": "", "point": aim}   # a drop with no target of its own: its aim is a point

# Whether step k carries a drop whose aim lies OUTSIDE the step's bomb cone: with the sim's outside_cone_mode "hold"
# it will not release, with "poor_shot" it releases a poor stick (bombs.outside_mode()). False for a step with no drop.
func drop_blocked(k: int, id: String = "") -> bool:
	if id == "":
		id = unit_id()
	if not plan_shown(id) or not step_has_drop(k, id):
		return false
	var cone: Dictionary = bombs.cone(id, k)
	var aim := step_aim(k, id)
	if not bool(cone["ok"]) or not aim.is_finite():
		return false
	return not BombSource.inside(cone["polygon"], aim)

# The Drop button: the drop of the step the card is about, on or off. {} when it may not.
func toggle_drop() -> Dictionary:
	var k := focus_step()
	if k < 0:
		return {}
	if special_kind() == "gun":
		return set_step_fire(k, not step_has_fire(k))
	return set_step_drop(k, not step_has_drop(k))

# Turn step k's drop on (aimed at the TARGET, which it stores on the step) or off. The step must be a placed step of
# the selected unit's plan, the unit must have a drop free, a target must be set and lie inside the step's cone.
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
		if not bool(cone["ok"]) or not target.is_set() or not target_in_cone(k):
			return {}
		var aim := target.position_m(world)
		var stored: Dictionary = {"unit": target.unit_id} if target.is_unit() else {"point": [aim.x, aim.y]}
		req["drop"] = {"aim": [aim.x, aim.y], "target": stored}
	set_focus_step(k)
	var u = world.units[id]
	var s := _commit_step(id, k, req, Vector2(float(u.x), float(u.y)))
	queue_redraw()
	return s

# Aim step k's drop at `world_pt`: the step's target becomes that point. REFUSED -- {} and the plan as it was, the
# point marked for a moment -- when the point lies outside the step's bomb cone, when the step has no drop or none can
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

# (Alex: "Dragging a step's aim marker moves that step's target (it becomes a point)".)
func _write_aim(id: String, k: int, world_pt: Vector2) -> Dictionary:
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true)
	req["drop"] = {"aim": [world_pt.x, world_pt.y], "target": {"point": [world_pt.x, world_pt.y]}}
	var u = world.units[id]
	set_focus_step(k)
	return _commit_step(id, k, req, Vector2(float(u.x), float(u.y)))

# The aim handle dragged: begin_aim takes hold of step k's aim (grab: the handle itself was pressed, so nothing moves
# until the pointer has left aim_drag_slop_px; otherwise the aim jumps to world_pt, as a press in the cone does),
# drag_aim follows the pointer, held inside the cone (as a dragged step is held in its envelope), end_aim lets go.
func begin_aim(k: int, world_pt: Vector2, grab: bool = false) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or not step_has_drop(k, id):
		return {}
	set_focus_step(k)
	_set_drag_aim(k)
	_aim_grab = world_pt
	_aim_moved = not grab
	if grab:
		return world.planned_states(id)[k]
	return drag_aim(world_pt)

func drag_aim(world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	if _drag_aim < 0 or not can_plan(id) or not step_has_drop(_drag_aim, id):
		return {}
	if not _aim_moved:
		var slop: float = style.num("target.aim_drag_slop_px") / maxf(mapping.px_per_m(world_pt), 1e-6)
		if world_pt.distance_to(_aim_grab) <= slop:
			return world.planned_states(id)[_drag_aim]
		_aim_moved = true
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

# Whether the aim drag last begun moved the aim (left the slop): false for a plain click on the handle.
func aim_was_moved() -> bool:
	return _aim_moved

func _set_drag_aim(k: int) -> void:
	_drag_aim = k
	if k >= 0:
		_drag_index = -1
	_update_hover()

# (A step edited keeps its drop and its target as they are -- Track T. Where the cone leaves the aim behind, the step is
# MARKED by drop_blocked, and the sim's outside_cone_mode decides what happens; the aim is not moved behind the player's back.)

# What the card and the map say about step k's drop: {cone (metres), aim, ideal_aim, spread
# {along_m, across_m, heading}, quality 0..1, release (metres), free (drops still free to plan),
# path, target (step_target), blocked (the aim is outside the cone), poor_shot (it would be released as one),
# lands (where the stick is centred: the aim, or the cone's nearest point to it)}. {} when step k has no drop.
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
	var outside := drop_blocked(k, id)
	return {"step": k, "cone": cone["polygon"], "aim": aim, "ideal_aim": cone["ideal_aim"], "spread": info["spread"],
		"quality": float(info["quality"]), "release": info["release"], "free": bombs.drops_free(id),
		"path": cone["path"], "target": step_target(k, id), "blocked": outside and not bool(info["releases"]),
		"poor_shot": outside and bool(info["releases"]), "lands": info["lands"]}

# THE EXPECTED-DAMAGE LINE (Track T; "radio tower: about 5 of 8"): for step k's drop, the ground unit IN SIGHT that is expected
# to lose the most pips, from the sim's own rules (World.drop_expected through BombSource; a unit the fog hides is never
# named): {unit, name (lowercase), mean (pips, capped at its health), health, p_destroy}, or {} when there is none (no drop, the
# drop will not release, nothing in reach). Behind plan_shown like every read of a drop.
func expected_damage(k: int = -2) -> Dictionary:
	var id := unit_id()
	if k == -2:
		k = focus_step()
	if not plan_shown(id) or not step_has_drop(k, id):
		return {}
	var aim := step_aim(k, id)
	if not aim.is_finite():
		return {}
	var target_unit := str(step_target(k, id).get("unit", ""))
	for rec: Dictionary in bombs.expected(id, k, aim):
		var uid := str(rec["unit"])
		if unit_visible.is_valid() and not bool(unit_visible.call(uid)):
			continue
		if uid == target_unit or float(rec["mean"]) >= style.num("bombs.aoe.card_min_pips"):
			return {"unit": uid, "name": str(world.units[uid].def.name).to_lower(), "mean": float(rec["mean"]), "health": int(rec["health"]), "p_destroy": float(rec["p_destroy"])}
	# The step's own unit target, on the ground and in sight, that the stick is not expected to hurt at all: the line says so
	# ("radio tower: about 0 of 8"), which is what a player aiming at it needs to be told. A plane in the air takes nothing from bombs.
	if target_unit != "" and world.units.has(target_unit) and (not unit_visible.is_valid() or bool(unit_visible.call(target_unit))):
		var t = world.units[target_unit]
		if not bool(t.down) and world.band_height(str(t.altitude_band)) <= world.bombs.blast_height_m:
			return {"unit": target_unit, "name": str(t.def.name).to_lower(), "mean": 0.0, "health": int(t.health), "p_destroy": 0.0}
	return {}

# The marks for the bomb node, in screen px (the record bomb_aim_art.gd documents). With bombs.pin.enabled (the default):
# ONE PINNED PICTURE for every drop of the selected unit (a line from the step's node to the landing, the area of effect, the
# target, the step's number; `selected` for the step the card is about, whose cone shows as a thin outline while the pointer is
# over the special's button or a landing point is dragged, and then also for that step with no drop, as an outline alone), a
# small mark for any other player unit's drop. With it off, the old looks: the full cone and aim of the step the card is about
# and a small mark for every other drop. NOTHING for a unit whose plan may not be shown (plan_shown): an AI unit's drops are
# never drawn.
func bomb_marks() -> Array:
	var out: Array = []
	if world == null or bombs == null or world.phase != World.PHASE_PLANNING:
		return out
	var sel := unit_id()
	var pin_on := style.flag("bombs.pin.enabled")
	for id: String in world.units:
		if not plan_shown(id) or not bombs.has_bombs(id):
			continue
		var focus_k := focus_step(id) if id == sel else -1
		for k in bombs.drop_steps(id):
			var rec := _bomb_mark(id, k, k == focus_k, pin_on and id == sel)
			if not rec.is_empty():
				out.append(rec)
	# The selected step has no drop yet and the pointer is on the special's button: where its cone is, as an outline alone.
	if pin_on and sel != "" and plan_shown(sel) and bombs.has_bombs(sel) and cone_outline_shown():
		var ck := focus_step(sel)
		if ck >= 0 and not step_has_drop(ck, sel):
			var ccone: Dictionary = bombs.cone(sel, ck)
			if bool(ccone["ok"]):
				var cpoly := PackedVector2Array()
				for q: Vector2 in ccone["polygon"]:
					cpoly.append(mapping.world_to_screen(q))
				out.append({"unit": sel, "step": ck, "quiet": false, "preview": true, "outline": true, "side": str(world.units[sel].side), "cone": cpoly,
					"aim": mapping.world_to_screen(ccone["ideal_aim"]) if (ccone["ideal_aim"] as Vector2).is_finite() else Vector2.INF,
					"spread": {"a": 0.0, "b": 0.0, "angle": 0.0}, "quality": 0.0, "seed": ck, "ppm": 1.0, "label": ""})
	# Track T (PROPOSED, bombs.aim.preview_cone): a target is set and the step the card is about has no drop yet -- its cone, faintly.
	if sel != "" and target != null and target.is_set() and plan_shown(sel) and bombs.has_bombs(sel) and style.flag("bombs.aim.preview_cone"):
		var pk := focus_step(sel)
		if pk >= 0 and not step_has_drop(pk, sel) and bombs.drops_free(sel, pk) > 0:
			var cone: Dictionary = bombs.cone(sel, pk)
			if bool(cone["ok"]):
				var poly := PackedVector2Array()
				for q: Vector2 in cone["polygon"]:
					poly.append(mapping.world_to_screen(q))
				out.append({"unit": sel, "step": pk, "quiet": false, "preview": true, "side": str(world.units[sel].side), "cone": poly,
					"aim": mapping.world_to_screen(target.position_m(world)), "spread": {"a": 0.0, "b": 0.0, "angle": 0.0}, "quality": 0.0,
					"seed": pk, "ppm": mapping.px_per_m(target.position_m(world)), "label": ""})
	return out

func _bomb_mark(id: String, k: int, full: bool, pinned: bool = false) -> Dictionary:
	var cone: Dictionary = bombs.cone(id, k)
	var plan: Array = world.units[id].plan
	var aim := BombSource._v2(((plan[k] as Dictionary)["drop"] as Dictionary).get("aim"))
	if not bool(cone["ok"]) or not aim.is_finite():
		return {}
	var info: Dictionary = bombs.aim_info(id, k, aim)
	var ppm: float = mapping.px_per_m(aim)
	var sp: Dictionary = info["spread"]
	var poly := PackedVector2Array()
	# The cone: the card's step, in the old looks always; pinned, only as the outline the pointer or a drag asks for.
	if full and (not pinned or cone_outline_shown()):
		for q: Vector2 in cone["polygon"]:
			poly.append(mapping.world_to_screen(q))
	# Where the step's node is on the screen: where the line of a pinned drop starts.
	var node := Vector2.INF
	if pinned:
		var sts := states(id)
		if k < sts.size():
			node = mapping.world_to_screen(Vector2(float((sts[k] as Dictionary)["x"]), float((sts[k] as Dictionary)["y"])))
	var rel: Vector2 = info["release"]
	var u = world.units[id]
	var quality := float(info["quality"])
	# TRACK T: a drop whose aim lies outside its cone is MARKED. The outside_cone_mode decides how: "hold" (it releases
	# nothing: `blocked`, no spread or fall line, a slash across the aim) or "poor_shot" (it releases a poor stick at the
	# cone's nearest point to the aim: `poor`, the stick's spread and fall line there, a slash, "poor shot").
	var outside := drop_blocked(k, id)
	var blocked: bool = outside and not bool(info["releases"])
	var poor: bool = outside and bool(info["releases"])
	var lands: Vector2 = info["lands"] if (info["lands"] as Vector2).is_finite() else aim
	if blocked:
		lands = Vector2.INF
	var tgt := step_target(k, id)
	var label := ("%d%%" % roundi(quality * 100.0)) if full else ""
	if full and blocked:
		label = style.text("bombs.text.step_tag_blocked")
	elif full and poor:
		label = style.text("bombs.text.step_tag_poor")
	var per_drop := int(bombs.bombs_left(id)["per_drop"])
	var tiers: Array = []
	for t: Array in bombs.blast_tiers():
		tiers.append([float(t[0]) * ppm, float(t[1])])
	return {
		"unit": id, "step": k, "quiet": not (full or pinned), "side": str(u.side),
		"pin": pinned, "selected": full, "node": node, "num": k + 1, "outline": pinned,
		"cone": poly, "aim": mapping.world_to_screen(aim),
		"lands": mapping.world_to_screen(lands) if lands.is_finite() else Vector2.INF,
		"ideal": mapping.world_to_screen(cone["ideal_aim"]) if (cone["ideal_aim"] as Vector2).is_finite() else Vector2.INF,
		"release": mapping.world_to_screen(rel) if rel.is_finite() else Vector2.INF,
		"spread": {"a": float(sp["along_m"]) * ppm, "b": float(sp["across_m"]) * ppm, "angle": mapping.screen_angle(aim, float(sp["heading"]))},
		"quality": quality, "ppm": ppm, "seed": (hash(id) & 0xFFFF) * 31 + k,
		"label": label, "blocked": blocked, "poor": poor,
		"target": {"kind": "unit" if str(tgt.get("unit", "")) != "" else "point", "unit": str(tgt.get("unit", "")), "radius_px": _marker_radius(str(tgt.get("unit", "")))},
		# the area of effect (bomb_aoe_art.gd): the blast table in px, the stick, the scatter's sigma, all along the bomber's heading
		"aoe": {"tiers": tiers, "count": per_drop, "stick_px": float(sp["stick_m"]) * ppm, "sigma_px": float(sp["sigma_m"]) * ppm,
			"angle": mapping.screen_angle(aim, float(sp["heading"])), "k_sigma": style.num("bombs.aim.spread.sigma_k")},
	}

# The screen radius of a unit's marker (0 for none): the unit-target mark's brackets stand clear of it.
func _marker_radius(unit: String) -> float:
	if unit == "" or marker_layer == null:
		return 0.0
	var m: Object = marker_layer.marker(unit)
	return float(m.radius_px()) if m != null else 0.0

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
	# The cone is not drawn now (it is an outline on the button's hover): a press in it would move the target out of sight.
	if style.flag("bombs.pin.enabled") and not style.flag("bombs.pin.press_in_cone"):
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
			begin_aim(int(g["step"]), wp, true)   # the handle itself: nothing moves until the pointer leaves the slop
		else:
			begin_edit(int(g["step"]), wp, true)   # the node itself: a click selects the step, a drag moves it (past the slop)
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
	_edit_moved = true   # (begin_edit with a grab says otherwise, after this)
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

func _on_target_changed() -> void:
	queue_redraw()

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
	_draw_selected_disc(sel)
	_draw_ghosts(sel)
	if can_plan(sel):
		_draw_fan()
	_draw_curve(sel, 1.0)
	_draw_selected_number(sel)
	_draw_drop_marks(sel)
	_draw_fire_marks(sel)
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

# The lettering at every step's ghost, as lines (empty for a step with none): the speed the step ends at ("120 m/s", data
# planner.speed_labels) over its height ("400 m", labels.enabled) -- the same two lines for a planned step and a carry-on one,
# no step number (Track L, Alex: "2 lines. Remove the step # as well") -- then, for a step with its special on, the special's
# own words ("Bomb Drop") and, when the drop is marked, "will not release" / "poor shot"; and, only while the data's
# labels.band_change_line is on (proposed off), a change of altitude band ("climb to high"). Nothing for a unit whose plan may
# not be shown.
func step_labels(id: String = "") -> Array:
	if id == "":
		id = unit_id()
	var out: Array = []
	if not plan_shown(id):
		return out
	var u = world.units[id]
	var st := states(id)
	var prev_band: String = u.altitude_band
	var with_speed: bool = style.flag("planner.speed_labels")
	var with_height: bool = style.flag("labels.enabled")
	var with_band: bool = style.flag("labels.band_change_line")
	for k in st.size():
		var s: Dictionary = st[k]
		var lines := PackedStringArray()
		if with_speed:
			lines.append(UiLabels.node_speed_text(style, float(s["speed"])))
		if with_height:
			lines.append(UiLabels.node_height_text(style, node_height_m(s)))   # (Track U3: every node has a height and a speed)
		if step_has_special(k, id):
			lines.append(special_label(id))   # the special on this step, in the unit's own words: "Bomb Drop", "Main Guns Fire" (Alex: name and action, from data)
			if drop_blocked(k, id):   # its target outside its cone (Track T): "will not release" / "poor shot", by the sim's switch
				lines.append(style.text("bombs.text.step_tag_blocked" if bombs.outside_mode() == "hold" else "bombs.text.step_tag_poor"))
			elif fire_blocked(k, id):   # a fire that will not go off as things stand (Track SH): the guns reload, the target left the sight ...
				lines.append(style.text("guns.text.step_tag_blocked"))
		var band := str(s["altitude_band"])
		if with_band and band != prev_band:
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

# Where step k's node is on the screen (INF with no such step).
func node_screen(k: int, id: String = "") -> Vector2:
	var st := states(id)
	if k < 0 or k >= st.size():
		return Vector2.INF
	return mapping.world_to_screen(Vector2(float((st[k] as Dictionary)["x"]), float((st[k] as Dictionary)["y"])))

# THE SELECTED NODE (data planner.select): node-hover's grow and fill made permanent -- an ink disc with a paper rim, a ring
# round it, the step's number in paper inside. Drawn for every unit (the selection works for all). While the selected node is
# dragged, or the pointer is on it, the hover look takes over (_draw_hover); the number comes back when it is let go.
func _draw_selected_node(id: String) -> void:
	_draw_selected_disc(id)
	_draw_selected_number(id)

# The disc and the ring, drawn UNDER the ghosts' lettering (so the words "85 m/s", "400 m", "Bomb Drop" stay readable over it) ...
func _draw_selected_disc(id: String) -> void:
	var k := focus_step(id)
	if k < 0 or not can_plan(id):
		return
	if _drag_index == k and _drag_index >= 0:
		return   # dragged: the hover's drag look is the node
	var c := node_screen(k, id)
	if not c.is_finite():
		return
	var ink: Color = style.color("hover_ink")
	var paper: Color = style.color("hover_paper")
	var r: float = style.num("planner.select.node_px")
	draw_circle(c, r + style.num("planner.select.paper_px"), paper, true, -1.0, true)
	draw_circle(c, r, ink, true, -1.0, true)
	draw_arc(c, r + style.num("planner.select.ring_gap_px"), 0.0, TAU, 40, ink, style.num("planner.select.ring_px"), true)

# ... and its number in paper, over the path line that runs through the node.
func _draw_selected_number(id: String) -> void:
	var k := focus_step(id)
	if k < 0 or not can_plan(id) or (_drag_index == k and _drag_index >= 0):
		return
	var c := node_screen(k, id)
	if not c.is_finite():
		return
	var font: Font = UiLabels.font(style)
	var px: float = style.num("planner.select.number_px")
	var txt := str(k + 1)
	var w := UiInk.text_width(font, txt, px)
	UiInk.text(self, font, c + Vector2(-w * 0.5, px * 0.36), txt, px, style.color("hover_paper"), HORIZONTAL_ALIGNMENT_LEFT, -1.0, "mark_number")

# A small bomb beside the node of every step whose special is on, on the shadow side (the lettering is on the sun side).
func _draw_drop_marks(id: String) -> void:
	if not bombs.has_bombs(id):
		return
	var ink: Color = style.color("hover_ink")
	var paper: Color = style.color("hover_paper")
	var s: float = style.num("planner.select.drop_mark.size_px")
	var off: float = style.num("planner.select.node_px") + style.num("planner.select.drop_mark.offset_px")
	var w: float = style.num("planner.select.drop_mark.line_px")
	var halo: float = style.num("planner.select.drop_mark.halo_px")
	for k in bombs.drop_steps(id):
		var n := node_screen(k, id)
		if not n.is_finite():
			continue
		UiInk.bomb_glyph(self, n + style.shadow_dir() * off, s, ink, paper, w, halo)

func _draw_hover() -> void:
	var state := str(_hover.get("state", "none"))
	# (the selected node is already at its strongest: only a drag takes it over; an aim handle's hover is the bomb node's, over the planes)
	var on_selected: bool = state != "drag" and int(_hover.get("step", -1)) == focus_step() and str(_hover.get("kind", "step")) == "step"
	if state != "none" and str(_hover.get("kind", "step")) != "aim" and not on_selected:
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
	var font: Font = UiLabels.font(style)   # readable lettering (Track C, 2026-10-10): labels.px, the semibold face of labels.font
	var small: float = UiLabels.px(style)
	var line_h: float = UiLabels.line_h(style)
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
			# Lettering on the sun side of the ghost, clear of the curve's own shadow side. The LAST line stands nearest the node
			# and the block grows away from it (Track L: two lines, three with the special; the path and the node's own marks
			# are on the node's side, so a longer block never reaches over them).
			var off: Vector2 = -style.shadow_dir() * (art.extent_m * ppm * scale_k + 6.0 if art != null else 14.0)
			var base := sp + off + Vector2(-4.0, 0.0)
			var top := base - Vector2(0.0, line_h * float(lines.size() - 1))
			if k == hl_k:
				# The grabbed step's lettering on a paper plate, in full ink (hover effect "label").
				var wmax := 0.0
				for ln: String in lines:
					wmax = maxf(wmax, UiInk.text_width(font, ln, small))
				var pad: float = style.num("planner.hover.label.pad_px")
				var plate := Rect2(top + Vector2(-pad, -small * 0.9 - pad * 0.5),
					Vector2(wmax + pad * 2.0, line_h * float(lines.size()) + pad))
				draw_rect(plate, style.color("hover_paper"), true)
				UiInk.ink_line(self, UiInk.rect_pts(plate), true, style.color("hover_ink"), 0.9, 41, 0.3)
				for li in lines.size():
					UiInk.text(self, font, top + Vector2(0.0, line_h * float(li)), lines[li], small, style.color("hover_ink"))
			else:
				for li in lines.size():
					# the paper under-stroke the hover uses, so the lettering reads over the grove; a carry-on node's is fainter
					UiLabels.draw(self, style, font, top + Vector2(0.0, line_h * float(li)), lines[li], small, ink if planned else carry_ink)

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
		UiLabels.draw(self, style, UiLabels.font(style), pa + Vector2(9.0, 5.0), "outside the cone", UiLabels.px(style), style.color("label_ink"))
	if not refused_world.is_finite() or Time.get_ticks_msec() - refused_ms > REFUSED_SHOW_MS:
		return
	var p: Vector2 = mapping.world_to_screen(refused_world)
	var x := 5.0
	draw_line(p + Vector2(-x, -x), p + Vector2(x, x), col, 1.6, true)
	draw_line(p + Vector2(-x, x), p + Vector2(x, -x), col, 1.6, true)
	UiLabels.draw(self, style, UiLabels.font(style), p + Vector2(9.0, 5.0), "off the map", UiLabels.px(style), style.color("label_ink"))

# The clamp marks of a unit's plan, in screen px: [{step, asked, put}] -- the point the pointer was left at (`asked`, where the
# little X was) and where the envelope put the step (`put`), for each clamped step more than 3 px apart. EMPTY while the data's
# planner.clamp_marks is false (Alex 2026-10-10: "The little X is where I left the mouse when dragging the point. We don't care
# about that at all."), which is what _draw_clamps draws from, so the off state draws nothing.
func clamp_marks(id: String = "") -> Array:
	var out: Array = []
	if not style.flag("planner.clamp_marks"):
		return out
	if id == "":
		id = unit_id()
	if not plan_shown(id):
		return out
	var st := states(id)
	var plan: Array = world.units[id].plan
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
		out.append({"step": k, "asked": a, "put": b})
	return out

func _draw_clamps(id: String) -> void:
	var col: Color = style.color("clamp")
	for m: Dictionary in clamp_marks(id):
		var a: Vector2 = m["asked"]
		UiInk.dashed(self, PackedVector2Array([a, m["put"]]), col, 0.9, 3.0, 3.0)
		var x := 3.5
		draw_line(a + Vector2(-x, -x), a + Vector2(x, x), col, 1.1, true)
		draw_line(a + Vector2(-x, x), a + Vector2(x, -x), col, 1.1, true)

# --- The gun salvo (Track SH, the warship, proposed 2026-10-10; scripts/sim/guns.gd, gun_source.gd) ------------------------------
#
# A unit's special is the bomb drop OR a gun salvo (special_kind). The control is the same button and the same toggle_drop(); a step
# carries {"fire": {"special": "main_guns", "target": {"unit": id} | {"point": [x, y]}, "aim": [x, y]}} where a bomb step carries "drop".
# Alex (special-targeting, target-follows-unit, step-selection): the special is active and targeted for its step; with no target, or
# one out of reach, it cannot be activated and the card says why; a unit target is followed (the shells are aimed at resolve); the
# step's lettering names the special and its action ("Main Guns Fire"). The reasons are the sim's (World.gun_check): reloading, a
# salvo already set on another step, no target, the target down or a friend, too close, out of range, inland (the guns attack the
# coast), not spotted (a friend must see it: shared spotting). Nothing here decides; it asks the sim and words the answer.

# The fire request of step k of a unit ({} when it has none): {"special", "target", "aim"?}.
func step_fire(k: int, id: String = "") -> Dictionary:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return {}
	var plan: Array = world.units[id].plan
	if k < 0 or k >= plan.size() or not (plan[k] as Dictionary).has("fire"):
		return {}
	var f: Variant = (plan[k] as Dictionary)["fire"]
	return (f as Dictionary).duplicate(true) if f is Dictionary else {}

func step_has_fire(k: int, id: String = "") -> bool:
	return not step_fire(k, id).is_empty()

# Whether step k carries the unit's special, whichever kind it is (a bomb drop or a fire).
func step_has_special(k: int, id: String = "") -> bool:
	return step_has_drop(k, id) or step_has_fire(k, id)

# The target selection as the sim takes it ({"unit": id} | {"point": [x, y]}), or {}.
func _target_request() -> Dictionary:
	if target == null or not target.is_set():
		return {}
	if target.is_unit():
		return {"unit": target.unit_id}
	var p: Vector2 = target.point_m
	return {"point": [p.x, p.y]} if p.is_finite() else {}

# The target stored with step k's fire, as the sim takes it: {"unit": id} | {"point": [x, y]} | {}.
func _fire_target_request(k: int, id: String) -> Dictionary:
	var t: Variant = step_fire(k, id).get("target")
	return (t as Dictionary).duplicate(true) if t is Dictionary else {}

# What the special's control may do for step k when the unit's special is a gun salvo: drop_options' record, filled in.
func _fire_options(k: int, out: Dictionary) -> Dictionary:
	var id := unit_id()
	var label := special_label(id)
	if k < 0:
		out["why"] = style.text("guns.text.place_first") % label
		return out
	var on := step_has_fire(k, id)
	out["on"] = on
	if on:
		out["available"] = true   # switching a fire off is always allowed
		return out
	var left := guns.reload_left(id)
	if left > 0:
		out["why"] = (style.text("guns.text.reloading_one") % label) if left == 1 else (style.text("guns.text.reloading") % [label, left])
		return out
	var req := _target_request()
	if req.is_empty():
		out["why"] = style.text("guns.text.no_target") % label
		return out
	var chk := guns.check(id, k, req)
	if chk.is_empty():
		out["why"] = style.text("guns.text.not_a_gun")
		return out
	if not bool(chk["ok"]):
		out["why"] = gun_reason_text(chk, id, label)
		return out
	out["available"] = true
	return out

# A reason the sim gave (a check's "reason") in the card's words.
func gun_reason_text(chk: Dictionary, id: String, label: String) -> String:
	var why := str(chk.get("reason", ""))
	match why:
		"reloading":
			var left := int(chk.get("reload_left", 1))
			return (style.text("guns.text.reloading_one") % label) if left <= 1 else (style.text("guns.text.reloading") % [label, left])
		"already_planned":
			var other := -1
			for s in guns.fire_steps(id):
				if s != int(chk.get("step", -1)):
					other = s
			return style.text("guns.text.already_planned") % [label, other + 1]
		"too_close":
			return style.text("guns.text.too_close") % roundi(float(chk.get("range_min_m", 0.0)))
		"out_of_range":
			return style.text("guns.text.out_of_range") % [roundi(float(chk.get("range_m", 0.0))), roundi(float(chk.get("range_max_m", 0.0)))]
		"no_target":
			return style.text("guns.text.no_target") % label
		"target_down", "own_side", "inland", "unspotted", "unit_down", "not_a_gun":
			return style.text("guns.text." + why)
	return why

# The sim's check for the fire step k carries (its own stored target); {} when the step has none or its plan may not be shown.
func fire_check(k: int, id: String = "") -> Dictionary:
	if id == "":
		id = unit_id()
	if not plan_shown(id) or not step_has_fire(k, id):
		return {}
	return guns.check(id, k, _fire_target_request(k, id))

# Whether step k carries a fire that will not go off as things stand (the target out of reach or no longer spotted, the guns
# reloading ...): its lettering says so.
func fire_blocked(k: int, id: String = "") -> bool:
	var chk := fire_check(k, id)
	return not chk.is_empty() and not bool(chk["ok"])

# What the card and the map say about step k's fire (-2: the step the card is about): {check (the sim's record), blocked, reason,
# range_m, spread_m (one shell's scatter, sigma), flight_s, spotted_s, salvos}. {} when the step has none.
func fire_info(k: int = -2) -> Dictionary:
	var id := unit_id()
	if k == -2:
		k = focus_step()
	var chk := fire_check(k, id)
	if chk.is_empty():
		return {}
	return {"check": chk, "blocked": not bool(chk["ok"]), "reason": str(chk["reason"]), "range_m": float(chk["range_m"]),
		"spread_m": float(chk["spread_m"]), "flight_s": float(chk["flight_s"]), "spotted_s": float(chk["spotted_s"]), "salvos": int(chk["salvos"])}

# The line under the target's, for a unit with big guns: what the special does at the SELECTED step, or why it cannot be switched on.
func gun_caption() -> String:
	var id := unit_id()
	if not can_plan(id) or special_kind(id) != "gun":
		return ""
	var opt := drop_options()
	var k := int(opt["step"])
	var label := special_label(id)
	if k < 0:
		return str(opt["why"])
	if bool(opt["on"]):
		var info := fire_info(k)
		if info.is_empty():
			return ""
		if bool(info["blocked"]):
			return style.text("guns.text.wont_fire") % gun_reason_text(info["check"], id, label)
		return style.text("guns.text.on") % [k + 1, label, roundi(float(info["spread_m"])), roundi(float(info["range_m"]))]
	if not bool(opt["available"]):
		return str(opt["why"])
	return style.text("guns.text.free") % [k + 1, label]

# Turn step k's fire on (aimed at the TARGET selection, which it stores on the step) or off. The step must be a placed step of the
# selected unit's plan and the sim must allow it (gun_check). Returns the step's state, or {} when refused.
func set_step_fire(k: int, on: bool) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or k < 0 or k >= world.steps_per_turn(id) or special_kind(id) != "gun":
		return {}
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true) if k < plan.size() else {}
	if not on:
		if not req.has("fire"):
			return {}
		req.erase("fire")
	else:
		if req.has("fire"):
			return world.planned_states(id)[k]   # already on
		if not bool(_fire_options(k, {"step": k, "available": false, "on": false, "why": ""})["available"]):
			return {}
		var at: Vector2 = target.position_m(world)
		req["fire"] = {"special": guns.special_id(id), "target": _target_request(), "aim": [at.x, at.y]}
	set_focus_step(k)
	var u = world.units[id]
	var s := _commit_step(id, k, req, Vector2(float(u.x), float(u.y)))
	queue_redraw()
	return s

# What is drawn for the fires of the selected unit (proposed, data guns.marks): a small shell beside the node of every step whose fire
# is on (on the shadow side, as the bomb is), a dashed line from the node to the target, a ring at the scatter's two sigma round the
# target as it was shown, a cross at the target itself; fainter when the fire will not go off. With the pointer on the special's
# button, the guns' reach shows as two thin dashed rings round the selected step.
func _draw_fire_marks(id: String) -> void:
	if special_kind(id) != "gun":
		return
	var ink: Color = style.color("hover_ink")
	var paper: Color = style.color("hover_paper")
	var s: float = style.num("planner.select.drop_mark.size_px")
	var off: float = style.num("planner.select.node_px") + style.num("planner.select.drop_mark.offset_px")
	var w: float = style.num("planner.select.drop_mark.line_px")
	var halo: float = style.num("planner.select.drop_mark.halo_px")
	for k in guns.fire_steps(id):
		var n := node_screen(k, id)
		if not n.is_finite():
			continue
		UiInk.shell_glyph(self, n + style.shadow_dir() * off, s, ink, paper, w, halo)
		var tgt := step_target(k, id)
		if tgt.is_empty() or not (tgt["point"] as Vector2).is_finite():
			continue
		var blocked := fire_blocked(k, id)
		var fade := 0.45 if blocked else 1.0
		var at_m: Vector2 = tgt["point"]
		var tp := mapping.world_to_screen(at_m)
		var line_c := _fade(ink, style.num("guns.marks.line_alpha") * fade)
		UiInk.dashed(self, PackedVector2Array([n, tp]), line_c, w, style.num("planner.dash_px"), style.num("planner.gap_px"))
		var info := fire_info(k)
		var sigma_m := float(info.get("spread_m", 0.0))
		var r := maxf(sigma_m * style.num("guns.marks.sigma_k") * mapping.px_per_m(at_m), style.num("guns.marks.ring_min_px"))
		var ring_c := _fade(ink, style.num("guns.marks.ring_alpha") * fade)
		draw_arc(tp, r + style.num("guns.marks.ring_line_px"), 0.0, TAU, 48, _fade(paper, 0.7 * fade), style.num("guns.marks.ring_line_px") + 1.6, true)
		draw_arc(tp, r, 0.0, TAU, 48, ring_c, style.num("guns.marks.ring_line_px"), true)
		var cx: float = style.num("guns.marks.target_cross_px")
		for d: Vector2 in [Vector2(1.0, 1.0), Vector2(1.0, -1.0)]:
			draw_line(tp - d * cx, tp + d * cx, _fade(paper, 0.8 * fade), w + 1.6, true)
			draw_line(tp - d * cx, tp + d * cx, ring_c, w, true)
	if _drop_hover:
		var k := focus_step(id)
		var st := states(id)
		if k >= 0 and k < st.size():
			var a: Dictionary = st[k - 1] if k > 0 else {"x": world.units[id].x, "y": world.units[id].y}
			var c_m := Vector2((float(a["x"]) + float(st[k]["x"])) * 0.5, (float(a["y"]) + float(st[k]["y"])) * 0.5)
			var c := mapping.world_to_screen(c_m)
			var ppm := mapping.px_per_m(c_m)
			var reach_c := _fade(ink, style.num("guns.marks.reach_alpha"))
			for rm: float in [guns.range_min_m(id), guns.range_max_m(id)]:
				var ring := UiInk.circle_pts(c, rm * ppm, 96)
				ring.append(ring[0])
				UiInk.dashed(self, ring, reach_c, w, style.num("guns.marks.reach_dash_px"), style.num("guns.marks.reach_gap_px"))
