extends Node2D

# Something on screen for every unit (exit criterion 6): one UnitMarker per
# unit in the World, posed every frame through the HOST's world-to-screen
# mapping, and -- during a resolve -- animated along the turn's histories with
# World.sample(). Mount it in a screen-space parent above the map (Track V's
# live layer slot, or a CanvasLayer) and hand it the host's mapping:
#
#   var layer := UnitMarkerLayer.new()
#   parent.add_child(layer)
#   layer.setup(world, host_mapping, selection)     # mapping: Transform2D or an
#                                                   # object with world_to_screen
#
# Draw order, bottom to top: the stand-out shapes and rings of the players' own
# units (Track U1, data marker.standout; nothing at all in the default mode
# "none"), every unit's shadow (one CanvasGroup, composited
# once at the map's shadow strength, so overlapping shadows merge and never
# darken twice -- the map's own shadow rule), every plane, then the marks: side
# roundels, the selected unit's inked ring, and its leader line up to its
# roster row (the design doc's proposed selection treatment).
#
# A DOWN UNIT (Track U2, part 2; the rules are scripts/ui/ui_fate.gd's): an exploded unit's
# marker is gone from down_at (the effects layer takes over); an out-of-control unit's marker
# keeps flying its sampled path with its shadow gap closing as the sim's fall height drops
# (fall_height_above_ground) and a slight wobble (data combat.fall, PROPOSED); a crashed
# unit's marker is gone at the crash (the wreck is the effects layer's scar). After the
# turn an exploded or crashed unit has no marker at all. A down unit's plan is never drawn
# (the planner does not draw one for it).
#
# SEAMS for other tracks (all optional Callables, all proposed):
#   ground_height(x, y) -> metres   Track T's height_at: a plane's shadow sits
#                                   by its height above the ground under it;
#                                   without it the ground is at 0
#   unit_visible(unit_id) -> bool   Track F's vision: a unit outside it is not drawn
#   leader_target(unit_id) -> Vector2  the roster row's screen point (UnitUI sets it)

signal playback_started(turn: int)
signal playback_finished(turn: int)

const World = preload("res://scripts/sim/world.gd")
const UnitMarker = preload("res://scripts/ui/unit_marker.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UnitStandout = preload("res://scripts/ui/unit_standout.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")

var world: World = null
var mapping: UiMapping = null
var selection: RefCounted = null
var style: UiStyle = null
var markers: Dictionary = {}        # unit id -> UnitMarker

var ground_height: Callable = Callable()
var unit_visible: Callable = Callable()
var leader_target: Callable = Callable()

# Playback of the last resolve: seconds into the turn, < 0 when not playing.
var playback_t: float = -1.0
var playback_turn: int = 0
# Held: playback stays where it is (scrubbing, screenshots).
var playback_paused: bool = false

var _under: Node2D            # the stand-out shapes and rings, below the shadows
var _shadows: CanvasGroup
var _planes: Node2D
var _marks: Node2D
var _standout: Dictionary = {}     # UnitStandout.parse() of the data's mode
var _standout_mode := ""
var _lowest_air_m := -1.0          # the lowest sea-level band's height, for the fall's ground blend

func setup(w: World, host_mapping: Variant, sel: RefCounted, st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	if _shadows == null:
		_build()
	set_mapping(host_mapping)
	selection = sel
	if not selection.changed.is_connected(_on_selection):
		selection.changed.connect(_on_selection)
	world = w
	if not world.turn_resolved.is_connected(_on_turn_resolved):
		world.turn_resolved.connect(_on_turn_resolved)
	sync_units()
	update_poses()

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping

func _build() -> void:
	_under = Node2D.new()
	_under.name = "Under"
	add_child(_under)
	_under.draw.connect(_draw_under)
	_shadows = CanvasGroup.new()
	_shadows.name = "Shadows"
	var tint: Color = style.color("unit_shadow")
	_shadows.self_modulate = Color(1.0, 1.0, 1.0, tint.a)
	add_child(_shadows)
	_planes = Node2D.new()
	_planes.name = "Planes"
	add_child(_planes)
	_marks = Node2D.new()
	_marks.name = "Marks"
	add_child(_marks)
	_marks.draw.connect(_draw_marks)

# --- Units ---------------------------------------------------------------------------

# One marker per unit in the world, in the world's order; gone units dropped.
func sync_units() -> void:
	for id: String in markers.keys():
		if not world.units.has(id):
			(markers[id] as Node).queue_free()
			markers.erase(id)
	for id: String in world.units:
		if markers.has(id):
			continue
		var u = world.units[id]
		var m := UnitMarker.new()
		m.own = u.controller == World.CONTROLLER_PLAYER
		m.setup(style, id, u.def.silhouette, u.def.size_m, style.side_color(u.side), _shadows, _under)
		_planes.add_child(m)
		markers[id] = m
		m.selected = selection != null and selection.unit_id == id
		if not _standout.is_empty():
			m.set_standout(_standout)

func marker(id: String) -> UnitMarker:
	return markers.get(id)

# Every marker bakes its art again (after UnitMarkerArt.clear_cache(): the pen
# changed, say).
func refresh_art() -> void:
	for id: String in markers:
		(markers[id] as UnitMarker).refresh_art()

# The pose a unit is drawn at now: {x, y, heading, speed, altitude_band, height_m}.
# During playback, where the last resolve had it at playback_t; otherwise where it is.
func pose_of(id: String) -> Dictionary:
	if is_playing():
		return world.sample(id, playback_t, "history")
	var u = world.units[id]
	var s: Dictionary = u.state()
	# A unit falling out of control has a continuous height of its own, not its nearest band's.
	s["height_m"] = float(u.fall_height_m) if is_finite(float(u.fall_height_m)) else world.band_height(u.altitude_band)
	return s

# Whether the unit is on the map as a plane right now (UiFate: an exploded unit goes at
# down_at, a crashed one at the crash, and neither is a plane once the turn has played).
func unit_on_map(id: String) -> bool:
	var u = world.units.get(id)
	return u != null and UiFate.on_map(u, playback_t, is_playing())

# Whether the unit is falling out of control right now (the sim's fall height applies).
func unit_falling(id: String) -> bool:
	var u = world.units.get(id)
	return u != null and UiFate.falling_at(u, playback_t, is_playing())

# Height above the surface under the unit, for its shadow.
func height_above_ground(pose: Dictionary) -> float:
	var h := float(pose.get("height_m", 0.0))
	var band := str(pose.get("altitude_band", ""))
	if world.rules.band_reference.get(band, "sea_level") == "terrain":
		return h
	if ground_height.is_valid():
		h -= float(ground_height.call(float(pose["x"]), float(pose["y"])))
	return h

# The height of a FALLING unit above the ground under it. The sim's fall height is already
# above the ground (it has no terrain: the plane falls to 0 m); the band the plane left was
# measured from sea level, so the ground under it is taken off that, and the offset is
# blended away as the plane nears the ground (full above the lowest air band, nothing at
# 0 m) so the shadow gap closes smoothly at down_at and again at the crash (PROPOSED).
func fall_height_above_ground(pose: Dictionary) -> float:
	var h := maxf(float(pose.get("height_m", 0.0)), 0.0)
	if not ground_height.is_valid():
		return h
	if _lowest_air_m < 0.0:
		_lowest_air_m = INF
		for band: String in world.rules.band_height_m:
			if str(world.rules.band_reference.get(band, "sea_level")) == "sea_level" and float(world.rules.band_height_m[band]) > 0.0:
				_lowest_air_m = minf(_lowest_air_m, float(world.rules.band_height_m[band]))
	var g := float(ground_height.call(float(pose["x"]), float(pose["y"])))
	var blend := 1.0 if not is_finite(_lowest_air_m) else clampf(h / _lowest_air_m, 0.0, 1.0)
	return maxf(h - g * blend, 0.0)

# The extra rotation of a falling unit's plane (radians; data combat.fall): a wobble that
# rocks it either side of its heading, eased in over ramp_s after it goes down, and a slow
# spin (0 by default). On the playback's own clock, so a scrub shows the same angle; the
# phase is the game clock, so it carries on across turns, and the unit's id offsets it so two
# falling planes do not rock together.
func fall_wobble(id: String) -> float:
	if not is_playing() or not unit_falling(id):
		return 0.0
	var u = world.units[id]
	var turn_s: float = world.rules.turn_seconds
	var game_t := float(playback_turn - 1) * turn_s + playback_t
	var phase := float(hash(id) & 0xFF) / 255.0 * TAU
	var amp := deg_to_rad(style.num("combat.fall.wobble_deg"))
	if UiFate.went_down_this_turn(u):
		var ramp := maxf(style.num("combat.fall.ramp_s"), 1e-3)
		var f := clampf((playback_t - float(u.down_at)) / ramp, 0.0, 1.0)
		amp *= f * f * (3.0 - 2.0 * f)
	var w := amp * sin(TAU * style.num("combat.fall.wobble_hz") * game_t + phase)
	return w + deg_to_rad(style.num("combat.fall.spin_dps")) * maxf(playback_t - UiFate.falls_from(u), 0.0)

func update_poses() -> void:
	if world == null:
		return
	if world.units.size() != markers.size():
		sync_units()
	apply_standout()
	var playing := is_playing()
	for id: String in markers:
		var m: UnitMarker = markers[id]
		var u = world.units[id]
		var vis := UiFate.on_map(u, playback_t, playing) and (not unit_visible.is_valid() or bool(unit_visible.call(id)))
		m.visible = vis
		if not vis:
			m.shadow.visible = false
			m.refresh_shapes()
			continue
		var pose := pose_of(id)
		var wp := Vector2(float(pose["x"]), float(pose["y"]))
		var sp: Vector2 = mapping.world_to_screen(wp)
		var falling := UiFate.falling_at(u, playback_t, playing)
		var h := fall_height_above_ground(pose) if falling else height_above_ground(pose)
		var off: Vector2 = shadow_offset_px(wp, h, m.draw_scale)
		m.set_pose(sp, mapping.screen_angle(wp, float(pose["heading"])), mapping.px_per_m(wp), off, fall_wobble(id))
	_marks.queue_redraw()
	if not (_standout["ring"] as Dictionary).is_empty() or _ring_drawn:
		_under.queue_redraw()
	queue_redraw()

# The stand-out mode (data marker.standout.mode), read again when it changes
# (the data, or a host that sets it at run time: style.ui["marker"]["standout"]
# ["mode"]); `force` re-reads the parameters too. Cheap when nothing changed.
func apply_standout(force: bool = false) -> void:
	var mode := style.text("marker.standout.mode")
	if not force and mode == _standout_mode and not _standout.is_empty():
		return
	_standout_mode = mode
	_standout = UnitStandout.parse(style, mode)
	for id: String in markers:
		(markers[id] as UnitMarker).set_standout(_standout)
	_under.queue_redraw()

# The shadow's screen offset for a plane `height_m` above the ground at `wp`:
# the world offset (UiStyle.plane_shadow_offset_m) scaled by marker.true_scale,
# so the gap follows the plane's DRAWN size, not the map's (Alex, 2026-10-09,
# variants/plane-shadow-gap/). A plane drawn the same size at any map scale
# keeps the same gap at the same altitude; before, the gap shrank 4x from
# 4 px/m to 1 px/m while the plane stayed the same size.
func shadow_offset_px(wp: Vector2, height_m: float, unit_scale: float = 1.0) -> Vector2:
	return mapping.screen_delta(wp, style.plane_shadow_offset_m(height_m) * style.num("marker.true_scale") * unit_scale)

# The unit under a screen point (the nearest within its hit radius), or "".
func unit_at(screen_pt: Vector2) -> String:
	var best := ""
	var best_d := INF
	for id: String in markers:
		var m: UnitMarker = markers[id]
		if not m.visible:
			continue
		var d := m.position.distance_to(screen_pt)
		if d <= maxf(style.num("marker.hit_min_px"), m.radius_px()) and d < best_d:
			best = id
			best_d = d
	return best

func _on_selection(id: String) -> void:
	for mid: String in markers:
		(markers[mid] as UnitMarker).selected = mid == id
	_marks.queue_redraw()

# --- Playback ------------------------------------------------------------------------

func is_playing() -> bool:
	return playback_t >= 0.0

func start_playback(turn_no: int) -> void:
	playback_turn = turn_no
	playback_t = 0.0
	playback_started.emit(turn_no)
	update_poses()

# Advance the animation by `dt` seconds of real time (data: marker.playback_speed
# turn-seconds per second). Ends at the turn's length.
func advance_playback(dt: float) -> void:
	if not is_playing():
		return
	playback_t += dt * style.num("marker.playback_speed")
	if playback_t >= world.rules.turn_seconds:
		playback_t = -1.0
		update_poses()
		playback_finished.emit(playback_turn)
		return
	update_poses()

# Hold the animation at `t` seconds into the turn (screenshots, scrubbing).
func set_playback_time(t: float) -> void:
	playback_t = clampf(t, 0.0, world.rules.turn_seconds)
	update_poses()

func stop_playback() -> void:
	playback_t = -1.0
	update_poses()

func _on_turn_resolved(turn_no: int, _histories: Dictionary, _events: Array) -> void:
	start_playback(turn_no)

func _process(delta: float) -> void:
	if world == null:
		return
	if is_playing():
		if not playback_paused:
			advance_playback(delta)
		else:
			update_poses()
	else:
		update_poses()

# --- Trails: during playback, the track flown so far and the rest of the turn ----------

# Drawn by the layer itself, so below every shadow and plane.
func _draw() -> void:
	if world == null or not is_playing():
		return
	var flown: Color = style.color("trail")
	var ahead: Color = style.color("trail_ahead")
	for id: String in markers:
		if not (markers[id] as UnitMarker).visible:
			continue
		var tr := track_points(id)
		var past: PackedVector2Array = tr["past"]
		var rest: PackedVector2Array = tr["rest"]
		if past.size() > 1 and not _flown_line_replaced(markers[id] as UnitMarker):
			draw_polyline(past, flown, 1.2, true)
		if rest.size() > 1:
			UiInk.dashed(self, rest, ahead, 1.0, 4.0, 4.0)

# The track of a unit through the turn being played, in screen px: {past: where it has flown (the plane's
# place last), rest: the rest of the turn (the plane's place first)}. The rest is the dashed line ahead,
# and what it shows is PROPOSED (data marker.ahead_line): a player's own planes only -- the enemy's
# plan is never shown, and the rest of its turn is its plan -- and a unit that goes down this turn
# has a line only up to the moment it goes down (a fall, a blast or an end beyond it is not shown
# ahead of time: a resolve does not spoil a death any more than a hit).
func track_points(id: String) -> Dictionary:
	var step: float = maxf(0.02, style.num("marker.trail_dt_s"))  # never 0: the loop below steps by it
	var turn_s: float = world.rules.turn_seconds
	var u = world.units[id]
	var m: UnitMarker = markers[id]
	var limit := minf(UiFate.alive_until(u), UiFate.falls_from(u))
	var ahead_shown := m.own or style.text("marker.ahead_line.applies_to") == "all"
	var now := pose_of(id)
	var here: Vector2 = mapping.world_to_screen(Vector2(float(now["x"]), float(now["y"])))
	var past := PackedVector2Array()
	var rest := PackedVector2Array()
	var k := 0
	while true:
		var t := minf(float(k) * step, turn_s)
		var s := world.sample(id, t, "history")
		var p: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
		if t < playback_t:
			past.append(p)
		elif ahead_shown and t < limit:
			rest.append(p)
		if t >= turn_s:
			break
		k += 1
	past.append(here)
	if ahead_shown and playback_t < limit:
		rest.insert(0, here)
	else:
		rest.clear()
	return {"past": past, "rest": rest}

# --- Under: the side rings (the shapes are nodes of their own) -----------------------------

var _ring_drawn := false

func _draw_under() -> void:
	_ring_drawn = false
	if world == null:
		return
	for id: String in markers:
		var m: UnitMarker = markers[id]
		if not m.visible or m.ring.is_empty():
			continue
		_ring_drawn = true
		var spec: Dictionary = m.ring
		var r := m.radius_px() + float(spec["pad_px"]) + float(spec["width_px"]) * 0.5
		var col := Color(m.accent.r, m.accent.g, m.accent.b, float(spec["alpha"]))
		var seed_value := (hash(id) & 0xFFFF) + 31
		# The accent band, then a fine ink line on its outer edge (inked like the rest).
		UiInk.ink_line(_under, UiInk.circle_pts(m.position, r, 48), true, col, float(spec["width_px"]), seed_value, 0.5)
		UiInk.ink_line(_under, UiInk.circle_pts(m.position, r + float(spec["width_px"]) * 0.5 + float(spec["rim_px"]) * 0.4, 52),
			true, spec["rim_color"], float(spec["rim_px"]), seed_value + 7, 0.5)

# Wingtip trails (data marker.trails, scripts/ui/wingtip_trails.gd) carry the track flown so
# far at the wingtips; with them on, the solid ink line down the middle of it is not drawn.
func _flown_line_replaced(m: UnitMarker) -> bool:
	if style.text("marker.trails.mode") == "none" or not style.flag("marker.trails.replaces_flown_line"):
		return false
	return m.own or style.text("marker.trails.applies_to") == "all"

# --- Marks: side roundels, the selection ring, the leader line ------------------------

func ring_radius(m: UnitMarker) -> float:
	return maxf(style.num("marker.ring_min_px"), m.radius_px() + style.num("marker.ring_pad_px"))

func _draw_marks() -> void:
	if world == null:
		return
	var ink: Color = style.color("ring")
	var eye: Color = style.color("card_fill")
	var leader: Color = style.color("leader")
	var badge_r: float = style.num("marker.badge_r_px")
	var badge_off: float = style.num("marker.badge_offset_px")
	# The side mark sits toward the sun, so the plane's shadow never covers it.
	var toward_sun: Vector2 = -style.shadow_dir()
	for id: String in markers:
		var m: UnitMarker = markers[id]
		if not m.visible:
			continue
		var r := ring_radius(m)
		var bc := m.position + toward_sun * (r + badge_off)
		var tie_a := m.position + toward_sun * (m.radius_px() * 0.55 + 2.0)
		var tie_b := bc - toward_sun * badge_r
		_marks.draw_line(tie_a, tie_b, leader, 1.0, true)
		UiInk.roundel(_marks, bc, badge_r, m.accent, eye, ink)
		if m.selected:
			_draw_ring(m, r, ink, leader)

func _draw_ring(m: UnitMarker, r: float, ink: Color, leader: Color) -> void:
	var c := m.position
	var seed_value := hash(m.unit_id) & 0xFFFF
	var w: float = style.num("marker.ring_line_px")
	UiInk.ink_line(_marks, UiInk.circle_pts(c, r, 48), true, ink, w, seed_value, 0.5)
	var faint := Color(ink.r, ink.g, ink.b, ink.a * 0.7)
	UiInk.ink_line(_marks, UiInk.circle_pts(c, r + style.num("marker.ring_gap_px"), 52), true, faint, 0.6, seed_value + 5, 0.5)
	# Four ticks outside the ring, square to the map (a reticle, not a compass).
	var tick: float = style.num("marker.ring_tick_px")
	var r2 := r + style.num("marker.ring_gap_px")
	for d: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		_marks.draw_line(c + d * (r2 + 1.0), c + d * (r2 + 1.0 + tick), ink, 1.0, true)
	if style.flag("marker.leader_to_roster") and leader_target.is_valid():
		var t: Vector2 = leader_target.call(m.unit_id)
		if t.is_finite():
			var dir := (t - c).normalized()
			var a := c + dir * (r2 + 1.0)
			if a.distance_to(t) > 4.0:
				_marks.draw_line(a, t, leader, style.num("marker.leader_line_px"), true)
				_marks.draw_circle(t, 2.2, ink, true, -1.0, true)
