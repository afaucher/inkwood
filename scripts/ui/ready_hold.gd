extends Control

# HOLD SPACE TO READY (decision playtest-4, Alex: "Controls - Lets have holding space for 1s ready you up if all units have actions or 2s otherwise."
# Alex earlier banned keyboard mapping ("No keyboard mapping"); this is his explicit exception).
#
# THE STATE OF A HOLD AND ITS PICTURE. UnitUI owns one, as a child of the orders card (so it draws over the card's Ready button), feeds it the
# Space bar's press and release (begin / release) and the frame time (tick). Nothing here reads a key or a clock: a test drives begin, tick and
# release by hand with a fake clock.
#
#   begin()      the Space bar went down: starts a hold, unless one cannot start (not the planning phase, the local player is already ready, the end-of-mission
#                card is up, or the hold already readied the player and the key has not been let go)
#   tick(dt)     `dt` seconds of the key held. When the hold reaches required_s() it readies the player ONCE (the `completed` signal; UnitUI answers with its
#                own press_ready, the Ready button's action) and the picture clears. True the frame it completes
#   release()    the Space bar came up: an early release CANCELS (no ready, the picture clears); after a completed hold it only lets the next one start
#   required_s() the seconds a hold takes NOW: data orders.ready_hold.all_planned_s (Alex's 1 s) when every one of the local player's units that is up has
#                a step planned, else orders.ready_hold.otherwise_s (Alex's 2 s). Asked every tick, so the plan is the one at the moment of the hold
#   progress()   0..1 of the hold, for the picture
#
# THE PICTURE (no new symbol): a wash of the pressed-button ink (role orders.ready_hold.fill_role, the strength fill_alpha) grows along the Ready button
# from its left edge to its right as the hold goes on and goes the moment the hold ends. The button's own rectangle is the orders card's
# (MotionPlannerPanel.buttons()["ready"]["rect"]).

signal completed

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var style: UiStyle = null
var orders: Control = null                        # the orders card: where the Ready button's rectangle is
var world: World = null
var local_player: String = "local"
# () -> bool: whether every unit of the local player's that is up has actions planned (UnitUI.all_units_planned).
var all_planned: Callable = Callable()
# () -> bool: whether a hold may start or go on at all (the end-of-mission card is not up). UnitUI points it at its own input lock.
var allowed: Callable = Callable()

var held_s: float = 0.0
var holding: bool = false
var _spent: bool = false                          # this hold already readied the player: wait for the key to come up
var _last_progress: float = -1.0
var draw_count: int = 0
var failed_draws: int = 0

func setup(st: UiStyle, orders_card: Control, w: World, player: String) -> void:
	style = st
	orders = orders_card
	world = w
	local_player = player
	name = "ReadyHold"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

# The seconds a hold takes now (see the header).
func required_s() -> float:
	var every_unit_has_actions: bool = all_planned.is_valid() and bool(all_planned.call())
	return style.num("orders.ready_hold.all_planned_s" if every_unit_has_actions else "orders.ready_hold.otherwise_s")

# Whether a hold can run at all now: the planning phase, this player not ready yet, no end-of-mission card.
func can_hold() -> bool:
	if world == null or world.phase != World.PHASE_PLANNING:
		return false
	if world.is_ready(local_player):
		return false
	return not allowed.is_valid() or bool(allowed.call())

func begin() -> bool:
	if holding or _spent:
		return holding   # (a key held on after a completed hold does not start another)
	if not can_hold():
		return false
	holding = true
	held_s = 0.0
	_changed()
	return true

func release() -> void:
	var was := holding or _spent
	holding = false
	_spent = false
	held_s = 0.0
	if was:
		_changed()

# True the frame the hold completes.
func tick(dt: float) -> bool:
	if not holding:
		return false
	if not can_hold():
		cancel()   # the turn moved on, the player was readied some other way, or the card came up
		return false
	held_s += maxf(dt, 0.0)
	var need := required_s()
	if held_s + 1e-9 >= need:
		holding = false
		_spent = true
		held_s = 0.0
		_changed()
		completed.emit()
		return true
	_changed()
	return false

# The hold stops with no ready (the key is still down, if it is: the next begin() waits for release()).
func cancel() -> void:
	holding = false
	held_s = 0.0
	_changed()

# Whether the key is still down after a hold that readied the player (the next hold waits for the key to come up).
func is_spent() -> bool:
	return _spent

func progress() -> float:
	if not holding:
		return 0.0
	return clampf(held_s / maxf(required_s(), 1e-6), 0.0, 1.0)

# The wash on the Ready button at this moment, in the orders card's own space: its left part, `progress` of its width. Empty when no hold runs.
func fill_rect() -> Rect2:
	var p := progress()
	if p <= 0.0 or orders == null:
		return Rect2()
	var b: Dictionary = orders.call("buttons")
	if not b.has("ready"):
		return Rect2()
	var r: Rect2 = (b["ready"] as Dictionary)["rect"]
	return Rect2(r.position, Vector2(r.size.x * p, r.size.y))

func _changed() -> void:
	var p := progress()
	if p != _last_progress:
		_last_progress = p
		queue_redraw()

func _draw() -> void:
	draw_count += 1
	var r := fill_rect()
	if r.size.x <= 0.0 or style == null:
		return
	var c: Color = style.color(style.text("orders.ready_hold.fill_role"))
	var a: float = style.num("orders.ready_hold.fill_alpha")
	draw_rect(r, Color(c.r, c.g, c.b, c.a * a), true)
