extends Node2D

# WINGTIP TRAILS (Track U1; Alex 2026-10-10: "For locating the players planes, what
# about wingtip trails in the players color? That cover the past turn."). The variant
# switch of variants/wingtip-trails/. EVERY VALUE AND RULE HERE IS PROPOSED; nothing is
# chosen. Data: data/ui/ui.json marker.trails, mode "none" by default (nothing is drawn,
# today's look).
#
#   var trails := WingtipTrails.new()
#   map_parent.add_child(trails)                         # screen space, the markers' space
#   map_parent.move_child(trails, marker_layer.get_index())   # just UNDER the markers
#   trails.setup(world, host_mapping, marker_layer)      # records every resolved turn itself
#   trails.unit_visible = fog.vision.unit_visible(world) # optional: a unit out of sight has none
#
# WHAT IT DRAWS. Each wingtip of a plane leaves a line behind it, in the unit's side accent
# (side_a for the players, side_b for the enemy), over the last `window_turns` of play:
#   - while PLANNING: the whole last resolved turn, ending at the plane, fading to nothing at
#     the far end;
#   - while a turn PLAYS BACK: a rolling window of the same length behind the plane's
#     position now, so the trail grows from the plane and its tail is the end of the turn
#     before (that is why it keeps the turns it has seen resolve, not only the last).
# A unit that has not flown (no history yet) has no trail; neither does a down unit.
#
# WHERE THE LINES START. At the drawn wingtips: the wing outline's half-span (UnitMarkerArt.
# half_span_m, in the art's own metres) times the plane's drawn scale (marker.true_scale, and
# the stand-out "larger" factor), offset square to the heading at that moment. So the two
# lines sit on the plane's drawn wingtips at every zoom, whatever the map scale, and a
# plane drawn small at the far zoom has lines a few px apart.
#
# THE RECORD. At every `turn_resolved` it samples each unit's history (World.sample(id, t,
# "history") every sample_s, plus a sample exactly at each step end, which C and E use) and
# keeps the last window plus one turn. Game time = (turn - 1) x turn_seconds + t, as
# SandboxTracks counts it. A client that joined late has only the turns it saw resolve.
#
# STYLES (marker.trails.mode): lines, steps, ribbon, rungs, wake -- see data.
#
# It redraws only when something it shows changes (a pose, the camera, the playback clock,
# the mode), so a planning view costs nothing per frame.

const World = preload("res://scripts/sim/world.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

var world: World = null
var mapping: UiMapping = null
var style: UiStyle = null
var marker_layer: Object = null              # is_playing(), playback_t, playback_turn, marker(id).draw_scale
var unit_visible: Callable = Callable()      # unit_id -> bool: in sight
# Counted when a draw ran to its end; failed_draws counts sub-draws that did not (a runtime
# error ends a GDScript function silently, so each returns true as its last act).
var draw_count: int = 0
var failed_draws: int = 0

# unit id -> {t: PackedFloat64Array (game seconds), x, y, h: PackedFloat64Array, steps: PackedFloat64Array}
var _buf: Dictionary = {}
var _recorded_end := 0.0     # game seconds at the end of the latest turn recorded
var _sig := ""
var _items: Array = []
var _span: Dictionary = {}   # silhouette -> the drawn wing's half-span, art metres

func setup(w: World, host_mapping: Variant, markers: Object = null, st: RefCounted = null) -> void:
	world = w
	marker_layer = markers
	style = (st if st != null else UiStyle.shared()) as UiStyle
	set_mapping(host_mapping)
	name = "WingtipTrails"
	if not world.turn_resolved.is_connected(_on_turn_resolved):
		world.turn_resolved.connect(_on_turn_resolved)

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	_sig = ""

# Forgets every recorded turn (a new game, a host change).
func clear() -> void:
	_buf.clear()
	_recorded_end = 0.0
	_sig = ""
	queue_redraw()

func _on_turn_resolved(turn_no: int, _histories: Dictionary, _events: Array) -> void:
	record_turn(turn_no)

# --- The record ----------------------------------------------------------------------------

# Samples every unit's history of turn `turn_no` (call it when that turn's histories are on the
# units: World.turn_resolved does). Public so a board or a test can feed it.
func record_turn(turn_no: int) -> void:
	var turn_s: float = world.rules.turn_seconds
	var t0 := float(turn_no - 1) * turn_s
	var dt := maxf(style.num("marker.trails.sample_s"), 0.02)
	var keep_s := (style.num("marker.trails.window_turns") + 1.0) * turn_s
	for id: String in world.units:
		var u = world.units[id]
		if u.history.size() < 2:
			continue
		var times: Array = []
		var n := ceili(turn_s / dt)
		for k in n + 1:
			times.append(minf(float(k) * dt, turn_s))
		var steps_here: Array = []
		for hs: Dictionary in u.history:
			var ht := float(hs.get("t", 0.0))
			times.append(ht)
			if int(hs.get("step", -1)) >= 0:
				steps_here.append(t0 + ht)
		times.sort()
		var b: Dictionary = _buf.get(id, {})
		if b.is_empty():
			b = {"t": PackedFloat64Array(), "x": PackedFloat64Array(), "y": PackedFloat64Array(), "h": PackedFloat64Array(), "steps": PackedFloat64Array()}
			_buf[id] = b
		_drop_from(b, t0 - 1e-9)
		# Packed arrays read out of a Dictionary are copies: take them, append, put them back.
		var ts: PackedFloat64Array = b["t"]
		var xs: PackedFloat64Array = b["x"]
		var ys: PackedFloat64Array = b["y"]
		var hd: PackedFloat64Array = b["h"]
		var steps: PackedFloat64Array = b["steps"]
		var last_t := -INF
		for tt: float in times:
			if tt - last_t < 1e-6:
				continue
			last_t = tt
			var s: Dictionary = world.sample(id, tt, "history")
			if s.is_empty():
				continue
			ts.append(t0 + tt)
			xs.append(float(s["x"]))
			ys.append(float(s["y"]))
			hd.append(float(s["heading"]))
		for st_t: float in steps_here:
			steps.append(st_t)
		# Older than the window plus a turn is never drawn again.
		var cutoff := t0 + turn_s - keep_s
		var drop := 0
		while ts.size() - drop > 2 and ts[drop + 1] < cutoff:
			drop += 1
		if drop > 0:
			ts = ts.slice(drop)
			xs = xs.slice(drop)
			ys = ys.slice(drop)
			hd = hd.slice(drop)
		var keep_steps := PackedFloat64Array()
		for st_t: float in steps:
			if st_t >= cutoff:
				keep_steps.append(st_t)
		b["t"] = ts
		b["x"] = xs
		b["y"] = ys
		b["h"] = hd
		b["steps"] = keep_steps
	_recorded_end = maxf(_recorded_end, t0 + turn_s)
	_sig = ""

static func _drop_from(b: Dictionary, t_from: float) -> void:
	var ts: PackedFloat64Array = b["t"]
	var keep := ts.size()
	while keep > 0 and ts[keep - 1] >= t_from:
		keep -= 1
	for key: String in ["t", "x", "y", "h"]:
		var arr: PackedFloat64Array = b[key]
		arr.resize(keep)
		b[key] = arr
	var steps: PackedFloat64Array = b["steps"]
	var ks := steps.size()
	while ks > 0 and steps[ks - 1] >= t_from:
		ks -= 1
	steps.resize(ks)
	b["steps"] = steps

# Game seconds the trail ends at: the playback clock while a turn plays back, else the end of
# the last turn recorded.
func now() -> float:
	if marker_layer != null and bool(marker_layer.is_playing()):
		return float(int(marker_layer.playback_turn) - 1) * float(world.rules.turn_seconds) + float(marker_layer.playback_t)
	return _recorded_end

# The recorded pose at game time t: {x, y, h}, interpolated; {} outside the record.
static func pose_at(b: Dictionary, t: float) -> Dictionary:
	var ts: PackedFloat64Array = b["t"]
	var n := ts.size()
	if n == 0 or t < ts[0] - 1e-9 or t > ts[n - 1] + 1e-9:
		return {}
	var i := 0
	while i < n - 2 and ts[i + 1] < t:
		i += 1
	if n == 1:
		return {"x": (b["x"] as PackedFloat64Array)[0], "y": (b["y"] as PackedFloat64Array)[0], "h": (b["h"] as PackedFloat64Array)[0]}
	var span := ts[i + 1] - ts[i]
	var f := clampf((t - ts[i]) / span, 0.0, 1.0) if span > 1e-9 else 1.0
	var xs: PackedFloat64Array = b["x"]
	var ys: PackedFloat64Array = b["y"]
	var hs: PackedFloat64Array = b["h"]
	return {
		"x": lerpf(xs[i], xs[i + 1], f),
		"y": lerpf(ys[i], ys[i + 1], f),
		"h": hs[i] + angle_difference(hs[i], hs[i + 1]) * f,
	}

# --- What is drawn ---------------------------------------------------------------------------

# One record per unit that shows a trail, newest point first (index 0 is at the plane):
#   {unit, side, own, accent, left (screen px, the port wingtip's path), right, centre,
#    age (0 at the plane to 1 at the far end of the window), step (1 where a step ended),
#    half_span_px (the drawn half-span at the plane)}
# Empty in mode "none".
func collect() -> Array:
	var out: Array = []
	if world == null or mapping == null or style.text("marker.trails.mode") == "none":
		return out
	var applies := style.text("marker.trails.applies_to")
	var turn_s: float = world.rules.turn_seconds
	var win := maxf(style.num("marker.trails.window_turns") * turn_s, 0.05)
	var t1 := now()
	var t0 := t1 - win
	var k0: float = style.num("marker.true_scale")
	var power: float = style.num("marker.trails.fade_power")
	var min_alpha: float = style.num("marker.trails.min_alpha")
	for id: String in _buf:
		var u = world.units.get(id)
		if u == null or u.down or u.def == null:
			continue
		var is_own: bool = u.controller == World.CONTROLLER_PLAYER
		if applies == "own" and not is_own:
			continue
		if unit_visible.is_valid() and not bool(unit_visible.call(id)):
			continue
		var half_sheet := _half_span(str(u.def.silhouette))
		if half_sheet <= 0.0:
			continue
		var k := k0
		if marker_layer != null:
			var m: Object = marker_layer.marker(id)
			if m != null:
				k *= float(m.draw_scale)
		var half_m := half_sheet * k
		var b: Dictionary = _buf[id]
		var ts: PackedFloat64Array = b["t"]
		if ts.size() < 2:
			continue
		var from_t := maxf(t0, ts[0])
		var to_t := minf(t1, ts[ts.size() - 1])
		if to_t - from_t < 0.05:
			continue
		# Sample times in the window, newest first: the end, every recorded sample inside it, the start.
		var times: Array = [to_t]
		for i in range(ts.size() - 1, -1, -1):
			if ts[i] < to_t - 1e-6 and ts[i] > from_t + 1e-6:
				times.append(ts[i])
		times.append(from_t)
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		var centre := PackedVector2Array()
		var age := PackedFloat64Array()
		var step := PackedInt32Array()
		var steps: PackedFloat64Array = b["steps"]
		for tt: float in times:
			var a := clampf((t1 - tt) / win, 0.0, 1.0)
			if pow(1.0 - a, power) < min_alpha:
				break
			var p := pose_at(b, tt)
			if p.is_empty():
				continue
			var wp := Vector2(float(p["x"]), float(p["y"]))
			var side_v := Vector2.from_angle(float(p["h"]) + PI / 2.0) * half_m
			left.append(mapping.world_to_screen(wp - side_v))
			right.append(mapping.world_to_screen(wp + side_v))
			centre.append(mapping.world_to_screen(wp))
			age.append(a)
			var is_step := 0
			for s_t: float in steps:
				if absf(s_t - tt) < 1e-6:
					is_step = 1
					break
			step.append(is_step)
		if left.size() < 2:
			continue
		out.append({
			"unit": id, "side": str(u.side), "own": is_own, "accent": style.side_color(str(u.side)),
			"left": left, "right": right, "centre": centre, "age": age, "step": step,
			"half_span_px": (left[0] as Vector2).distance_to(right[0]) * 0.5,
		})
	return out

func _half_span(silhouette: String) -> float:
	if not _span.has(silhouette):
		_span[silhouette] = UnitMarkerArt.half_span_m(style, silhouette)
	return float(_span[silhouette])

func _signature(items: Array) -> String:
	var parts := PackedStringArray([style.text("marker.trails.mode"), "%.3f" % now()])
	for it: Dictionary in items:
		var l: PackedVector2Array = it["left"]
		var r: PackedVector2Array = it["right"]
		parts.append("%s:%d:%.1f,%.1f:%.1f,%.1f:%.1f,%.1f" % [it["unit"], l.size(), l[0].x, l[0].y, l[l.size() - 1].x, l[l.size() - 1].y, r[0].x, r[0].y])
	return "|".join(parts)

func _process(_delta: float) -> void:
	if world == null or mapping == null:
		return
	var items := collect()
	var sig := _signature(items)
	if sig != _sig:
		_sig = sig
		_items = items
		queue_redraw()

func _draw() -> void:
	if world == null or mapping == null:
		return
	failed_draws += draw_items(self, _items, style, "")
	draw_count += 1

# --- Drawing (static: a board can draw items anywhere) --------------------------------------------

# The alpha at an age (0 at the plane, 1 at the far end), before a style's own alpha.
static func fade(age: float, st: UiStyle) -> float:
	return pow(clampf(1.0 - age, 0.0, 1.0), st.num("marker.trails.fade_power"))

# Draws trail records in the data's mode (or `mode_override`). Returns how many sub-draws did
# not reach their end (0 when all did).
static func draw_items(ci: CanvasItem, items: Array, st: UiStyle, mode_override: String = "") -> int:
	var mode := mode_override if mode_override != "" else st.text("marker.trails.mode")
	var failed := 0
	for it: Dictionary in items:
		var ok := true
		match mode:
			"lines":
				ok = _draw_lines(ci, it, st, false)
			"steps":
				ok = _draw_lines(ci, it, st, true)
			"ribbon":
				ok = _draw_ribbon(ci, it, st)
			"rungs":
				ok = _draw_rungs(ci, it, st)
			"wake":
				ok = _draw_wake(ci, it, st)
		failed += 0 if ok else 1
	return failed

static func _colors(it: Dictionary, base_alpha: float, st: UiStyle) -> PackedColorArray:
	var accent: Color = it["accent"]
	var cols := PackedColorArray()
	for a: float in (it["age"] as PackedFloat64Array):
		cols.append(Color(accent.r, accent.g, accent.b, base_alpha * fade(a, st)))
	return cols

# lines / steps: a polyline per wingtip, alpha falling with age; steps cut it at every step end.
static func _draw_lines(ci: CanvasItem, it: Dictionary, st: UiStyle, broken: bool) -> bool:
	var block := "steps" if broken else "lines"
	var w: float = st.num("marker.trails.%s.line_px" % block)
	var cols := _colors(it, st.num("marker.trails.%s.alpha" % block), st)
	for side: String in ["left", "right"]:
		var pts: PackedVector2Array = it[side]
		if not broken:
			ci.draw_polyline_colors(pts, cols, w, true)
			continue
		var gap: float = st.num("marker.trails.steps.gap_px")
		var steps: PackedInt32Array = it["step"]
		# Runs between step ends (index 0 is at the plane, the run reaching it keeps its head).
		var start := 0
		for i in range(1, pts.size()):
			if steps[i] == 1 or i == pts.size() - 1:
				var run_pts := pts.slice(start, i + 1)
				var run_cols := cols.slice(start, i + 1)
				var head := 0.0 if start == 0 else gap * 0.5
				var tail := 0.0 if i == pts.size() - 1 else gap * 0.5
				_draw_trimmed(ci, run_pts, run_cols, w, head, tail)
				start = i
	return true

# A coloured polyline with `head` px taken off its first end and `tail` px off its last.
static func _draw_trimmed(ci: CanvasItem, pts: PackedVector2Array, cols: PackedColorArray, w: float, head: float, tail: float) -> void:
	if pts.size() < 2:
		return
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i - 1].distance_to(pts[i])
	if total <= head + tail + 0.5:
		return
	var out_p := PackedVector2Array()
	var out_c := PackedColorArray()
	var walked := 0.0
	for i in range(0, pts.size()):
		if i > 0:
			walked += pts[i - 1].distance_to(pts[i])
		if walked >= head and walked <= total - tail:
			if out_p.is_empty() and i > 0 and walked > head:
				var seg := pts[i - 1].distance_to(pts[i])
				var f := (head - (walked - seg)) / maxf(seg, 1e-6)
				out_p.append(pts[i - 1].lerp(pts[i], f))
				out_c.append(cols[i - 1].lerp(cols[i], f))
			out_p.append(pts[i])
			out_c.append(cols[i])
		elif walked > total - tail and not out_p.is_empty():
			var seg2 := pts[i - 1].distance_to(pts[i])
			var f2 := ((total - tail) - (walked - seg2)) / maxf(seg2, 1e-6)
			out_p.append(pts[i - 1].lerp(pts[i], f2))
			out_c.append(cols[i - 1].lerp(cols[i], f2))
			break
	if out_p.size() >= 2:
		ci.draw_polyline_colors(out_p, out_c, w, true)

# ribbon: quads between the two wingtip paths, alpha falling with age, a hairline on each edge.
static func _draw_ribbon(ci: CanvasItem, it: Dictionary, st: UiStyle) -> bool:
	var l: PackedVector2Array = it["left"]
	var r: PackedVector2Array = it["right"]
	var fill := _colors(it, st.num("marker.trails.ribbon.fill_alpha"), st)
	for i in range(0, l.size() - 1):
		ci.draw_polygon(PackedVector2Array([l[i], l[i + 1], r[i + 1], r[i]]), PackedColorArray([fill[i], fill[i + 1], fill[i + 1], fill[i]]))
	var edge := _colors(it, st.num("marker.trails.ribbon.edge_alpha"), st)
	var w: float = st.num("marker.trails.ribbon.edge_px")
	ci.draw_polyline_colors(l, edge, w, true)
	ci.draw_polyline_colors(r, edge, w, true)
	return true

# rungs: the twin lines and a short bar across the wingtips at every step end.
static func _draw_rungs(ci: CanvasItem, it: Dictionary, st: UiStyle) -> bool:
	var w: float = st.num("marker.trails.rungs.line_px")
	var cols := _colors(it, st.num("marker.trails.rungs.alpha"), st)
	ci.draw_polyline_colors(it["left"], cols, w, true)
	ci.draw_polyline_colors(it["right"], cols, w, true)
	var rung_cols := _colors(it, st.num("marker.trails.rungs.rung_alpha"), st)
	var rw: float = st.num("marker.trails.rungs.rung_px")
	var l: PackedVector2Array = it["left"]
	var r: PackedVector2Array = it["right"]
	var steps: PackedInt32Array = it["step"]
	for i in range(1, l.size()):
		if steps[i] == 1:
			ci.draw_line(l[i], r[i], rung_cols[i], rw, true)
	return true

# wake: segments that narrow with age and draw toward the centre line.
static func _draw_wake(ci: CanvasItem, it: Dictionary, st: UiStyle) -> bool:
	var w0: float = st.num("marker.trails.wake.line_px_start")
	var w1: float = st.num("marker.trails.wake.line_px_end")
	var conv: float = st.num("marker.trails.wake.converge")
	var base: float = st.num("marker.trails.wake.alpha")
	var accent: Color = it["accent"]
	var ages: PackedFloat64Array = it["age"]
	var c: PackedVector2Array = it["centre"]
	for side: String in ["left", "right"]:
		var pts: PackedVector2Array = it[side]
		var prev := pts[0].lerp(c[0], conv * ages[0])
		for i in range(1, pts.size()):
			var cur := pts[i].lerp(c[i], conv * ages[i])
			var a := (ages[i - 1] + ages[i]) * 0.5
			var col := Color(accent.r, accent.g, accent.b, base * fade(a, st))
			ci.draw_line(prev, cur, col, lerpf(w0, w1, a), true)
			prev = cur
	return true
