extends Node2D

# The selection ring's health arc (design doc, UI table, proposed: "segmented
# pips on the card, echoed as a short arc on the selection ring"). Drawn here,
# on UnitUI's overlay layer above the markers, so the marker layer's own ring
# stays as Track U1 has it: this reads the ring's radius and the marker's
# screen position from the layer (public) and puts a short arc of segments
# just outside the ring's fine rule and ticks.
#
# WHERE ON THE RING (proposed): one of the four diagonals, the one furthest
# from the side badge (it sits toward the sun) and from the leader line to the
# roster row, so the arc never lies on either. Only the selected unit, and only
# a player-controlled one (a player sees its own units' health; what the enemy
# shows is combat's and the fog's to say). The pips are UiHealth's, the same
# ones as the roster row.
#
# arc_angle(), arc_radius() and shown() are public for tests; the frame is
# drawn from _draw.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiHealth = preload("res://scripts/ui/ui_health.gd")

const DIAGONALS := [PI * 0.25, PI * 0.75, -PI * 0.75, -PI * 0.25]   # down-right, down-left, up-left, up-right (screen, y down)

var world: World = null
var marker_layer: Object = null
var selection: RefCounted = null
var style: UiStyle = null
var health: UiHealth = null

func setup(w: World, markers: Object, sel: RefCounted, st: UiStyle, h: UiHealth) -> void:
	world = w
	marker_layer = markers
	selection = sel
	style = st
	health = h
	name = "HealthArc"

func _process(_delta: float) -> void:
	queue_redraw()   # the marker moves with the camera and the playback

# The unit the arc is drawn for, or "".
func target_id() -> String:
	if world == null or selection == null or selection.unit_id == "":
		return ""
	var u = world.units.get(selection.unit_id)
	if u == null or u.controller != World.CONTROLLER_PLAYER:
		return ""
	return selection.unit_id

# The arc's centre angle for a unit's marker: the diagonal furthest from the badge and the leader.
func arc_angle(id: String) -> float:
	var m = marker_layer.marker(id)
	if m == null:
		return DIAGONALS[0]
	var avoid: Array[float] = [(-style.shadow_dir()).angle()]
	if marker_layer.leader_target.is_valid():
		var t: Vector2 = marker_layer.leader_target.call(id)
		if t.is_finite() and t.distance_to(m.position) > 1.0:
			avoid.append((t - m.position).angle())
	var best: float = DIAGONALS[0]
	var best_d := -1.0
	for a: float in DIAGONALS:
		var d := INF
		for b: float in avoid:
			d = minf(d, absf(angle_difference(a, b)))
		if d > best_d + 1e-6:
			best_d = d
			best = a
	return best

func arc_radius(id: String) -> float:
	var m = marker_layer.marker(id)
	return marker_layer.ring_radius(m) + style.num("marker.ring_gap_px") + style.num("health.ring_arc.outside_px")

func _draw() -> void:
	if world == null or not style.flag("health.ring_arc.enabled"):
		return
	var id := target_id()
	if id == "":
		return
	var m = marker_layer.marker(id)
	if m == null or not m.visible:
		return
	var playing: bool = marker_layer.is_playing()
	UiHealth.draw_arc_pips(self, style, m.position, arc_radius(id), arc_angle(id), health.max_of(id),
		health.shown(id, playing), style.color("ring_health"), style.color("ring_health_empty"))
