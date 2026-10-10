extends Node2D

# THE TARGET SELECTION ON THE MAP (Track T, 2026-10-10). UnitUI mounts this node in its overlay layer, above the
# planes and below the HUD, in screen space like the planner: it draws the player's target (UnitUI.target, ui_target.gd)
# with target_art.gd -- brackets round an enemy unit, a diamond for a point -- in ink on a paper pool. The map layers sit
# above the map and its fog, so a point target set in the unexplored dark is drawn over the fog (Alex: right-click "a point
# on the map"); a unit target whose unit has gone out of sight is held at the place it was last seen and drawn fainter
# (target.unseen_alpha), never at the place it really is.
#
# It draws the SELECTION only. The target of a planned drop is part of that step's plan: the planner's bomb marks draw it
# (bomb_aim_art.gd), behind plan_shown, so an enemy's targets are never drawn. This node reads no plan.

const TargetArt = preload("res://scripts/ui/target_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var world: Object = null
var planner: Object = null
var target: RefCounted = null
var marker_layer: Object = null
var style: UiStyle = null
# What was last drawn, for a test or a board: the target's screen place and kind ("" nothing), and how often a draw ran.
var drawn_kind: String = ""
var drawn_at := Vector2.INF
var draw_count: int = 0
var failed_draws: int = 0

func setup(w: Object, motion_planner: Object, selection_target: RefCounted, markers: Object, st: RefCounted) -> void:
	world = w
	planner = motion_planner
	target = selection_target
	marker_layer = markers
	style = st as UiStyle
	name = "TargetMarks"
	if not target.changed.is_connected(queue_redraw):
		target.changed.connect(queue_redraw)

func _process(_delta: float) -> void:
	if target != null and (target.is_set() or drawn_kind != ""):
		queue_redraw()   # the camera and the unit move under a still target

# The target's place on the screen and kind ("unit" | "point"), or {} when there is none to draw.
func shown() -> Dictionary:
	if target == null or not target.is_set() or planner == null or planner.mapping == null:
		return {}
	var at_m: Vector2 = target.position_m(world)
	if not at_m.is_finite():
		return {}
	var radius := 0.0
	if target.is_unit() and marker_layer != null:
		var m: Object = marker_layer.marker(target.unit_id)
		if m != null:
			radius = float(m.radius_px())
	return {"kind": target.kind, "at": planner.mapping.world_to_screen(at_m), "radius_px": radius, "in_sight": target.in_sight()}

func _draw() -> void:
	drawn_kind = ""
	drawn_at = Vector2.INF
	var s := shown()
	if s.is_empty() or style == null:
		return
	var alpha := 1.0 if bool(s["in_sight"]) else style.num("target.unseen_alpha")
	if not TargetArt.draw(self, str(s["kind"]), s["at"], style, float(s["radius_px"]), 1.0, alpha):
		failed_draws += 1
	drawn_kind = str(s["kind"])
	drawn_at = s["at"]
	draw_count += 1
