extends Node2D

# THE BOMB CONE AND THE AIM ON THE MAP while planning (Track U3, the strike, 2026-10-10): the
# node UnitUI mounts just UNDER the motion planner, so the planner's hover (the aim handle's
# grow-and-fill) is drawn over it. It draws what MotionPlanner.bomb_marks() hands it -- the
# selected bomber's cone, aim, expected spread and release for the step the card is about, and
# a small mark for every other drop of the selected unit and of the other player units -- in the
# look data/ui/ui.json bombs.aim.mode names (scripts/ui/bomb_aim_art.gd; variants/bomb-aim/).
#
#   var aim := BombAim.new()
#   map_parent.add_child(aim)                 # screen space, the planner's space
#   aim.setup(planner, style)
#
# TWO LAYERS (as the cone overlay has): this node draws the interior, the rim, the fall line and the spread
# UNDER the planes; its child "Marks" (z_index 1) draws the crosshair, its lettering and the aim handle's
# hover (the grow-and-fill, from the planner's hover state) OVER them, so an aim on the tower is not hidden by it.
#
# It asks the PLANNER, never the World: the planner is the one place that decides whose plan may
# be shown (plan_shown: the planning phase, a player-controlled unit, not down), so this node
# cannot draw an enemy's drop, and test_ui_coop's plan-reading tripwire does not have to look at
# it. It redraws only when something it shows changes (a pose, the camera, a plan, the look), not
# every frame: the stipple look is a thousand dots.

const BombAimArt = preload("res://scripts/ui/bomb_aim_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var planner: Object = null
var style: UiStyle = null
# What was last drawn, for a test or a board: the marks, and how often a draw ran to its end.
var marks: Array = []
var draw_count: int = 0
var marks_draw_count: int = 0
var failed_draws: int = 0
var _marks: Node2D = null
var mode_override: String = ""      # a board forces a look here; "" is the data's

var _sig := ""

func setup(motion_planner: Object, st: RefCounted = null) -> void:
	planner = motion_planner
	style = (st if st != null else UiStyle.shared()) as UiStyle
	name = "BombAim"
	if _marks == null:
		_marks = Node2D.new()
		_marks.name = "Marks"
		_marks.z_index = 1
		add_child(_marks)
		_marks.draw.connect(_draw_marks)

func _process(_delta: float) -> void:
	if planner == null:
		return
	refresh()

# Reads the marks and redraws if they changed.
func refresh() -> void:
	var now: Array = planner.bomb_marks()
	var sig := _signature(now)
	if sig != _sig:
		_sig = sig
		marks = now
		queue_redraw()
		if _marks != null:
			_marks.queue_redraw()

func _signature(list: Array) -> String:
	var parts := PackedStringArray([mode_override if mode_override != "" else style.text("bombs.aim.mode"), style.text("bombs.aoe.mode")])
	var h: Dictionary = planner.hover()
	parts.append("%s.%s.%d.%d" % [h["state"], h.get("kind", ""), int(h["step"]), roundi(float(h["approach"]) * 20.0)])
	for m: Dictionary in list:
		var a: Vector2 = m["aim"]
		var sp: Dictionary = m["spread"]
		parts.append("%s.%d:%s:%.1f,%.1f:%.1f,%.1f:%.2f:%d" % [m["unit"], m["step"], str(m["quiet"]), a.x, a.y,
			float(sp["a"]), float(sp["b"]), float(m["quality"]), (m["cone"] as PackedVector2Array).size()])
		# (Track T) the target, whether the drop is blocked or a poor shot, where the stick lands, the area of effect's size
		var lands: Vector2 = m.get("lands", a)
		var tg: Dictionary = m.get("target", {})
		parts.append("%s.%s.%s.%s.%s:%.1f,%.1f:%.1f" % [str(m.get("preview", false)), str(m.get("blocked", false)), str(m.get("poor", false)), str(tg.get("kind", "")), str(tg.get("unit", "")),
			lands.x if lands.is_finite() else -1.0, lands.y if lands.is_finite() else -1.0, float((m.get("aoe", {}) as Dictionary).get("sigma_px", 0.0))])
		var cone: PackedVector2Array = m["cone"]
		if cone.size() > 0:
			parts.append("%.1f,%.1f,%.1f,%.1f" % [cone[0].x, cone[0].y, cone[cone.size() / 2].x, cone[cone.size() / 2].y])
	return "|".join(parts)

func _draw() -> void:
	if planner == null or style == null:
		return
	var mode := mode_override if mode_override != "" else style.text("bombs.aim.mode")
	for m: Dictionary in marks:
		failed_draws += BombAimArt.draw(self, m, style, mode, "under")
	draw_count += 1

func _draw_marks() -> void:
	if planner == null or style == null:
		return
	var mode := mode_override if mode_override != "" else style.text("bombs.aim.mode")
	for m: Dictionary in marks:
		failed_draws += BombAimArt.draw(_marks, m, style, mode, "marks")
	# The aim handle's hover, over the aim it is about.
	var h: Dictionary = planner.hover()
	if str(h.get("kind", "")) == "aim" and str(h["state"]) != "none":
		for m: Dictionary in marks:
			if str(m["unit"]) == planner.unit_id() and int(m["step"]) == int(h["step"]):
				failed_draws += 0 if BombAimArt.draw_hover(_marks, m["aim"], str(h["state"]), float(h["approach"]), str(m["side"]), style) else 1
	marks_draw_count += 1
