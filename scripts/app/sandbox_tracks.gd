extends Node2D

# THE TRACKS (Track A, PROPOSED): the path every plane has flown, kept for the
# whole game and drawn in ink in the plane's side colour, with a dot where each
# turn ended. It is what the zoomed-out map shows after a minute of flight (exit
# criterion 5): where everyone went, and how far round the circles were.
#
# It records each turn from the World's history (World.sample at track_sample_s
# intervals when `turn_resolved` fires) and DRAWS in screen space through the
# host's mapping, like Track U's layers, so the line stays a true pixel width at
# any zoom. While a turn is being played back the track only reaches as far as
# the playback has (the markers' own trail shows the rest), so a line never runs
# ahead of its plane.
#
# FOG: a plane the player does not see is not tracked on screen either. A unit
# of a side with a player-controlled unit is always drawn; any other unit's
# track only where `point_visible` says that ground is in sight right now.
#
# THE WINGTIP TRAIL TAKES THE LAST TURN (decision wingtip-trails, Alex 2026-10-10: "yes, the
# trail is to the current position"; trails on every moving unit): a unit with a wingtip
# trail (scripts/ui/wingtip_trails.gd, drawn by UnitUI) has this whole-flight line stop where
# the trail BEGINS, `trail_start` (UnitUI.trail_start_t: game seconds, NAN when the unit has no
# trail) -- the start of the last resolved turn while planning, a rolling window behind the
# marker while a turn plays back -- so the last turn is drawn once, by the trail, which runs up
# to the plane. The dot where a turn ended is drawn only while it lies on this line. A unit with
# no trail (the mode is none, or it does not apply) keeps its line to the plane.
#
#   var tracks := SandboxTracks.new()
#   mount.add_child(tracks)                     # below Track U's markers
#   tracks.setup(world, map_view, marker_layer, style, 0.25, 1.6)
#   tracks.reveals = func(id): ...              # optional: whose tracks are always drawn
#   tracks.point_visible = func(p_m): ...       # optional: the fog's plain query
#   tracks.trail_start = ui.trail_start_t       # optional: where each unit's wingtip trail begins

const UiStyle = preload("res://scripts/ui/ui_style.gd")

var world: Object = null
var host: Node2D = null             # the MapView: get_global_transform_with_canvas(), px_per_m
var playback: Object = null         # the marker layer: is_playing(), playback_t
var style: UiStyle = null
var sample_s := 0.25
var line_px := 1.6
var reveals: Callable = Callable()
var point_visible: Callable = Callable()
var trail_start: Callable = Callable()      # unit id -> game seconds its wingtip trail begins at (NAN: none)

# unit id -> {pts: PackedVector2Array (metres), t: PackedFloat64Array (game seconds),
#             marks: PackedInt32Array (index of the point that ends each turn), color: Color}
var tracks: Dictionary = {}
var _last_turn_end := 0.0           # game seconds at the end of the last recorded turn

func setup(w: Object, host_view: Node2D, playback_layer: Object, st: RefCounted, sample_seconds: float, width_px: float) -> void:
	world = w
	host = host_view
	playback = playback_layer
	style = st as UiStyle
	sample_s = maxf(sample_seconds, 0.02)
	line_px = width_px
	if not world.turn_resolved.is_connected(_on_turn_resolved):
		world.turn_resolved.connect(_on_turn_resolved)

func clear() -> void:
	tracks.clear()
	_last_turn_end = 0.0
	queue_redraw()

func point_count(unit_id: String) -> int:
	return (tracks[unit_id].pts as PackedVector2Array).size() if tracks.has(unit_id) else 0

# The track's length in metres (for tests and the report).
func length_m(unit_id: String) -> float:
	if not tracks.has(unit_id):
		return 0.0
	var pts: PackedVector2Array = tracks[unit_id].pts
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	return total

func _on_turn_resolved(turn_no: int, _histories: Dictionary, _events: Array) -> void:
	var turn_s: float = world.rules.turn_seconds
	var t0 := float(turn_no - 1) * turn_s
	for id: String in world.units:
		var tr: Dictionary = tracks.get(id, {})
		if tr.is_empty():
			tr = {"pts": PackedVector2Array(), "t": PackedFloat64Array(), "marks": PackedInt32Array(),
				"color": style.side_color(str(world.units[id].side))}
			tracks[id] = tr
		var pts: PackedVector2Array = tr.pts
		var ts: PackedFloat64Array = tr.t
		var first := pts.is_empty()
		var n := int(ceil(turn_s / sample_s))
		for k in range(0 if first else 1, n + 1):
			var t := minf(float(k) * sample_s, turn_s)
			var s: Dictionary = world.sample(id, t, "history")
			pts.append(Vector2(float(s["x"]), float(s["y"])))
			ts.append(t0 + t)
		var marks: PackedInt32Array = tr.marks
		marks.append(pts.size() - 1)
		tr.pts = pts
		tr.t = ts
		tr.marks = marks
	_last_turn_end = t0 + turn_s
	queue_redraw()

func _process(_delta: float) -> void:
	queue_redraw()   # the camera moves; the drawing is a few hundred points

# How far the playback of the last resolved turn has got, in game seconds: INF when none is playing
# (every recorded point may be drawn). The turn being played is the one resolved last: its game time
# starts at _last_turn_end - turn_seconds.
func playback_limit() -> float:
	if playback != null and bool(playback.is_playing()):
		return _last_turn_end - float(world.rules.turn_seconds) + float(playback.playback_t)
	return INF

# The game time the flight line of `unit_id` is drawn up to: the playback's reach (`playback_limit`),
# and never past where the unit's wingtip trail begins (`trail_start`; NAN: it has none).
func line_limit(unit_id: String, playback_reach: float = INF) -> float:
	var lim := playback_reach
	if trail_start.is_valid():
		var from_trail := float(trail_start.call(unit_id))
		if not is_nan(from_trail):
			lim = minf(lim, from_trail)
	return lim

# How many recorded points of the unit's line are drawn right now (fog aside): those up to line_limit.
func drawn_points(unit_id: String) -> int:
	if not tracks.has(unit_id):
		return 0
	var ts: PackedFloat64Array = tracks[unit_id].t
	var lim := line_limit(unit_id, playback_limit())
	var n := 0
	for t: float in ts:
		if t > lim:
			break
		n += 1
	return n

func _draw() -> void:
	if world == null or host == null or tracks.is_empty():
		return
	var xf: Transform2D = host.get_global_transform_with_canvas()
	var ppm: float = host.px_per_m
	var limit := playback_limit()
	var ink: Color = style.color("ink")
	for id: String in tracks:
		var tr: Dictionary = tracks[id]
		var col: Color = tr.color
		col.a = 0.85
		var always := not reveals.is_valid() or bool(reveals.call(id))
		var pts: PackedVector2Array = tr.pts
		var ts: PackedFloat64Array = tr.t
		var run := PackedVector2Array()
		var drawn_to := -1
		var id_limit := line_limit(id, limit)
		for i in pts.size():
			if ts[i] > id_limit:
				break
			drawn_to = i
			var visible := always or not point_visible.is_valid() or bool(point_visible.call(pts[i]))
			if visible:
				run.append(xf * (pts[i] * ppm))
			elif not run.is_empty():
				_flush(run, col)
				run = PackedVector2Array()
		_flush(run, col)
		# A dot where each turn ended (the unit's last point of the turn), if drawn and in sight.
		for m: int in tr.marks:
			if m > drawn_to:
				break
			if always or not point_visible.is_valid() or bool(point_visible.call(pts[m])):
				var c: Vector2 = xf * (pts[m] * ppm)
				draw_circle(c, 2.4, col, true, -1.0, true)
				draw_circle(c, 2.4, Color(ink.r, ink.g, ink.b, 0.55), false, 0.8, true)

func _flush(run: PackedVector2Array, col: Color) -> void:
	if run.size() >= 2:
		draw_polyline(run, col, line_px, true)
