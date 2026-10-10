extends Control

# THE SIDE VIEW (Track V, 2026-10-10). ALEX (decisions height-speed-labels and side-view-look): "a side view
# indicator that only shows the firing cone and the relative straight line position of the targeted enemy";
# "for the side view I like the color wash. Keep the style identical to the top down. Reduce the icons (plane,
# tower, etc) to just indicators. I don't want side view assets"; "let's remove the weapon labels on the graph".
# And (special-targeting): with a friendly unit selected the player can also select an enemy unit or a point;
# "the only thing it does is show on the side view and it is the target that the special will use if activated",
# a special being "active and targeted for the step". And (2026-10-10): "targeting a moving unit like a tank
# should follow the unit. We need to pick the release point for bombs and things dynamically."
# EVERYTHING ELSE HERE IS PROPOSED, and data/ui/ui.json side_view holds every value.
#
# WHAT IT IS. A picture of the selected FRIENDLY unit's weapons in elevation, on one scale for both axes (so
# every angle is true), with the target at its straight-line position. It sits at the bottom of the orders card
# (the mock-up's place, tmp/sideview/make.py), and the card grows by its section while it shows:
#
#   var sv := SideView.new()
#   orders.add_child(sv)
#   sv.setup(world, planner, selection, style)
#   sv.attach(orders)                  # the card it grows; call it after the card's own setup
#   sv.target_source = func() -> Object: return ui.get("target")     # Track T's UnitUI.target, when it exists
#   sv.unit_visible = ...; sv.shown_pose = marker_layer.pose_of; sv.range_factor = ...; sv.playback = marker_layer
#
# WHAT IT SHOWS (model() is the whole picture as numbers; side_view_art.gd draws it):
#   the cones   every weapon of the unit, every distinct hardpoint, cut by the vertical plane along the nose
#               (forward weapons point right, rearward ones left), tilted by the pitch the step gives the
#               airframe (combat.json max_pitch_deg: a dive tilts every cone down), as cone_overlay.gd's own
#               wash records -- the same odds shading toward the centre of a fixed gun, the same fade past the
#               effective range, the same rim and hardpoint dots. Their elevation extent is the weapon's own:
#               elevation +- half height, narrowed by the slice's azimuth (combat.gd: the cone is an ellipse in
#               azimuth and elevation). No lettering.
#   the step    the step the orders card is about (planner.focus_step(): the last placed step, or the one whose
#               handle was grabbed last), the unit as that step leaves it (its position, heading, band and
#               pitch from the planned state); with no step placed, the unit as it is now.
#   the ground  one line at the unit's height below it (the sim's ground is 0 m everywhere; ground_height is a
#               seam for the day it has terrain, unwired).
#   the target  at its STRAIGHT-LINE position: the horizontal distance (negative if it is behind) and the height
#               difference, the bearing not drawn (the map shows it). A plane target a dot in its side's colour
#               (a ring when its bearing is off every gun's arc that faces its way: PROPOSED), a ground unit a
#               tick on the ground line, a map point a cross; beyond the picture an arrow on the edge. Which
#               target: the step's own if that step carries a special (MotionPlanner.step_target(k), Track T's;
#               until it exists the drop's aim stands in for it), otherwise the target selection (UnitUI.target).
#               A unit target is drawn at its SHOWN position (shown_pose = the marker layer's pose_of: where the
#               unit is drawn, moving with it through a playback) and only while it is in sight and on the map
#               (unit_visible); a point always. NEVER anything from an enemy's plan: only its shown pose.
#   a drop      a step with a drop shows the bombs' fall instead of the cones: the bomber at its release, the
#               arc the stick falls, where it lands (the aim as World.drop_spread clamps it into the cone) with
#               the expected spread, and the target on the ground. The aim is the target's SHOWN position, so a
#               moving target is followed and the release point is the one drop_spread gives for it (the sim
#               picks the release moment itself at resolve). The arc is Bombs.bomb_position's own.
#   the words   at most one quiet line under the picture (distance and height difference); data side_view.text.
#
# WHEN. Planning, for a friendly mobile unit that takes orders; and, while a turn plays back
# (side_view.live_during_playback), for the same unit at its SHOWN pose, so the picture follows the playback.
# Hidden for an enemy or nothing selected, and when the window is too short to hold it.
#
# THE PLAN-READ RULE (test_ui_coop's tripwire, and test_side_view's): every plan-derived question goes through
# the planner and only after planner.plan_shown(id) -- the planning phase, a player-controlled unit, not down --
# so an AI unit's plan, drop or step can never reach this picture. The playback view reads the shown pose and
# the sim's own history samples of the selected FRIENDLY unit only.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const SideViewArt = preload("res://scripts/ui/side_view_art.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")

var world: World = null
var planner: Object = null            # MotionPlanner (duck-typed: so Track T's edits cannot break this file's compile)
var selection: RefCounted = null
var style: UiStyle = null
var host: Control = null              # the card this section grows (attach())

# Seams (all optional Callables, all proposed):
var target_source: Callable = Callable()   # () -> Object: the target selection (Track T's UnitUI.target), or null
var unit_visible: Callable = Callable()    # unit_id -> bool: in sight and on the map (a target unit needs it)
var shown_pose: Callable = Callable()      # unit_id -> {x, y, heading, speed, altitude_band, height_m}: where it is drawn
var range_factor: Callable = Callable()    # (CombatWeapon, distance_m) -> 0..1: the odds' fall past the effective range
var ground_height: Callable = Callable()   # (x, y) -> metres: the terrain; the sim has none, so it is not wired
var playback: Object = null                # the marker layer: is_playing() / playback_t

# Counted when a draw ran to its end (a runtime error ends one early and silently).
var draw_count: int = 0
var picture_draws: int = 0
var failed_draws: int = 0

var _pic: Control = null
var _model: Dictionary = {"active": false}
var _sig: String = ""
var _rev: int = 0
var _base_h: float = 0.0
var _tg_id: int = 0

# The picture's own canvas: it clips to its rect (a wide cone may leave the page).
class _Pic extends Control:
	var panel: Object = null
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true
	func _draw() -> void:
		if panel != null:
			panel.paint_picture(self)

func setup(w: World, motion_planner: Object, sel: RefCounted, st: RefCounted = null) -> void:
	world = w
	planner = motion_planner
	selection = sel
	style = (st if st != null else UiStyle.shared()) as UiStyle
	name = "SideView"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	if _pic == null:
		_pic = _Pic.new()
		_pic.name = "Picture"
		_pic.panel = self
		add_child(_pic)
	if not world.plan_changed.is_connected(_on_change):
		world.plan_changed.connect(_on_change)
		world.phase_changed.connect(_on_change)
		selection.changed.connect(_on_change)
	_sig = ""

# The card the section is added to; it grows by the section while the panel shows. Call it after the card
# has its own size (the base height is read now).
func attach(card: Control) -> void:
	host = card
	_base_h = card.size.y
	var pc := card.get_parent_control()
	if pc != null and not pc.resized.is_connected(_on_change):
		pc.resized.connect(_on_change)
	_sig = ""

func _on_change(_x: Variant = null) -> void:
	_rev += 1

func _process(_delta: float) -> void:
	if world == null or style == null:
		return
	_watch_target()
	var sig := _signature()
	if sig == _sig:
		return
	_sig = sig
	refresh()

# Recompute the model and the card's room now (what _process does when something changed).
func refresh() -> void:
	_model = _compute()
	_apply_layout()
	visible = bool(_model.get("active", false))
	queue_redraw()
	if _pic != null:
		_pic.queue_redraw()

# The whole picture as numbers (see the header). {"active": false} when nothing is shown.
func model() -> Dictionary:
	return _model

func is_active() -> bool:
	return bool(_model.get("active", false))

# --- Change detection -----------------------------------------------------------------------

func _selection_target() -> Object:
	if not target_source.is_valid():
		return null
	var o: Variant = target_source.call()
	return o as Object if o is Object else null

# Follows the target selection's own change signal (Track T's), whichever object the source hands over.
func _watch_target() -> void:
	var tg := _selection_target()
	var gid := tg.get_instance_id() if tg != null else 0
	if gid == _tg_id:
		return
	_tg_id = gid
	if tg != null and tg.has_signal("changed") and not tg.is_connected("changed", _on_change):
		tg.connect("changed", _on_change)
	_rev += 1

func _signature() -> String:
	var id: String = selection.unit_id if selection != null else ""
	var parts := PackedStringArray([id, world.phase, str(world.turn), str(_rev)])
	var playing := playback != null and playback.has_method("is_playing") and bool(playback.is_playing())
	if playing:
		parts.append("%.3f" % float(playback.playback_t))
	var u: Variant = world.units.get(id)
	if u != null and u.controller == World.CONTROLLER_PLAYER and not u.def.is_static():
		if not playing and world.phase == World.PHASE_PLANNING and planner != null:
			parts.append(str(planner.focus_step(id)))
		# The target unit's shown position: a moving target is followed.
		var raw := _raw_target(id, int(planner.focus_step(id)) if (not playing and planner != null) else -1, playing)
		if not raw.is_empty() and str(raw["unit"]) != "" and world.units.has(str(raw["unit"])):
			var tid := str(raw["unit"])
			var sp := _shown_pose_of(tid, world.units[tid])
			parts.append("%s:%.1f,%.1f,%s,%s" % [tid, float(sp["x"]), float(sp["y"]), str(sp.get("height_m", 0.0)), str(_is_shown(tid, world.units[tid]))])
		elif not raw.is_empty():
			parts.append("p%s" % str(raw["point"]))
	if host != null:
		var pc := host.get_parent_control()
		parts.append("%.0f,%.0f,%.0f" % [host.position.y, host.size.x, pc.size.y if pc != null else 0.0])
	return "|".join(parts)

# --- The card's room ------------------------------------------------------------------------

func _chrome() -> float:
	return style.num("side_view.section.gap_px") + style.num("side_view.section.head_px") + _caption_h() + style.num("side_view.section.bottom_px")

func _caption_h() -> float:
	return style.num("side_view.section.caption_h_px") if style.flag("side_view.text.enabled") else 0.0

# The picture's size, or a height of 0 when the window cannot hold the section.
func _picture_size() -> Vector2:
	var pad: float = style.num("card.pad_px")
	var w: float = (host.size.x if host != null else style.num("roster.width_px")) - 2.0 * pad
	var h: float = style.num("side_view.section.picture_h_px")
	if host != null:
		var pc := host.get_parent_control()
		if pc != null and pc.size.y > 1.0:
			h = minf(h, pc.size.y - style.num("card.margin_px") - (host.position.y + _base_h) - _chrome())
	if h < style.num("side_view.section.min_picture_h_px"):
		return Vector2(w, 0.0)
	return Vector2(w, h)

# Sizes the section and grows (or restores) the card.
func _apply_layout() -> void:
	var on := bool(_model.get("active", false))
	if host == null:
		if on and _pic != null:
			var sz: Vector2 = _model["size"]
			size = Vector2(sz.x, _chrome() + sz.y)
			_pic.position = Vector2(0.0, style.num("side_view.section.gap_px") + style.num("side_view.section.head_px"))
			_pic.size = sz
		return
	var want := _base_h
	if on:
		var sz2: Vector2 = _model["size"]
		var section := _chrome() + sz2.y
		want = _base_h + section
		position = Vector2(style.num("card.pad_px"), _base_h)
		size = Vector2(sz2.x, section)
		_pic.position = Vector2(0.0, style.num("side_view.section.gap_px") + style.num("side_view.section.head_px"))
		_pic.size = sz2
	if not is_equal_approx(host.custom_minimum_size.y, want):
		host.custom_minimum_size = Vector2(host.custom_minimum_size.x, want)
		host.size = Vector2(host.size.x, want)
		host.queue_redraw()

# --- Drawing -----------------------------------------------------------------------------------

func _draw() -> void:
	if not bool(_model.get("active", false)):
		return
	var st := style
	var soft: Color = st.color("ink_soft")
	var faint: Color = st.color("ink_faint")
	var italic: Font = st.font(true)
	var detail: float = st.num("fonts.detail_px")
	var gap: float = st.num("side_view.section.gap_px")
	var head: float = st.num("side_view.section.head_px")
	UiInk.ink_line(self, PackedVector2Array([Vector2(0.0, 1.0), Vector2(size.x, 1.0)]), false, faint, 0.8, 9, 0.4)
	UiInk.text(self, italic, Vector2(0.0, gap + head - 5.0), str(_model["head"]), detail, soft)
	var line := str(_model["line"])
	if line != "":
		var sz: Vector2 = _model["size"]
		UiInk.text(self, italic, Vector2(0.0, gap + head + sz.y + _caption_h() - 5.0), line, detail, soft, HORIZONTAL_ALIGNMENT_LEFT, size.x)
	draw_count += 1

# Called by the picture canvas.
func paint_picture(ci: CanvasItem) -> void:
	if not bool(_model.get("active", false)):
		return
	failed_draws += SideViewArt.paint(ci, _model, style)
	picture_draws += 1

# --- The model ------------------------------------------------------------------------------------

func _compute() -> Dictionary:
	var off := {"active": false}
	if style == null or world == null or selection == null or planner == null or not style.flag("side_view.enabled"):
		return off
	var id: String = selection.unit_id
	if id == "" or not world.units.has(id):
		return off
	var u = world.units[id]
	if u.controller != World.CONTROLLER_PLAYER or u.def.is_static():
		return off
	var live := false
	if playback != null and playback.has_method("is_playing") and bool(playback.is_playing()):
		# A turn plays: the unit as it is DRAWN, unless the data keeps the panel down or the unit is shown down.
		if not style.flag("side_view.live_during_playback") or not shown_pose.is_valid() or not selection.can_select(id):
			return off
		live = true
	elif not planner.plan_shown(id):
		return off   # the planning phase, a player unit, not down: the one rule every plan-derived read goes through
	var pic := _picture_size()
	if pic.y <= 0.0:
		return off
	var pose := _pose(id, u, live)
	var k: int = int(pose["step"])
	var tgt := _normalise_target(_raw_target(id, k, live))
	var m := {"active": true, "unit": id, "side": str(u.side), "live": live, "size": pic, "step": k, "pose": pose,
		"mode": "guns", "cones": [], "drop": {}, "target": {}, "target_hidden": bool(tgt.get("hidden", false)),
		"ref": pose, "ppm": 1.0, "origin": Vector2.ZERO, "ground_y": INF, "arcs": {}}
	var drop := {}
	if not live and k >= 0 and planner.step_has_drop(k, id):
		drop = _drop_frame(id, k, tgt, pose, pic, m)
	if drop.is_empty():
		_guns_frame(id, u, pose, pic, m, tgt)
	else:
		m["mode"] = "drop"
		m["drop"] = drop
	if not tgt.is_empty() and not tgt.has("hidden"):
		m["target"] = _place_target(tgt, m, pic)
	m["head"] = style.text("side_view.text.head_live") if live else (style.text("side_view.text.head_step") % (k + 1) if k >= 0 else style.text("side_view.text.head_now"))
	m["line"] = _line(m, tgt)
	return m

# The unit as the step the card is about leaves it ({x, y, heading, speed, band, pitch, step, height_m}).
func _pose(id: String, u: Object, live: bool) -> Dictionary:
	var pose := {"x": float(u.x), "y": float(u.y), "heading": float(u.heading), "speed": float(u.speed),
		"band": str(u.altitude_band), "pitch": 0.0, "step": -1, "height_m": 0.0}
	if live:
		var s: Dictionary = shown_pose.call(id)
		pose["x"] = float(s["x"])
		pose["y"] = float(s["y"])
		pose["heading"] = float(s["heading"])
		pose["speed"] = float(s["speed"])
		pose["band"] = str(s.get("altitude_band", pose["band"]))
		pose["height_m"] = float(s["height_m"]) if s.has("height_m") else _band_m(str(pose["band"]), float(pose["x"]), float(pose["y"]))
		pose["pitch"] = _live_pitch(id, float(pose["speed"]))
		return pose
	var k: int = int(planner.focus_step(id))
	pose["step"] = k
	if k >= 0:
		var states: Array = planner.states(id)
		if k < states.size():
			var s2: Dictionary = states[k]
			pose["x"] = float(s2["x"])
			pose["y"] = float(s2["y"])
			pose["heading"] = float(s2["heading"])
			pose["speed"] = float(s2["speed"])
			pose["band"] = str(s2["altitude_band"])
			pose["pitch"] = _step_pitch(id, k, s2)
	pose["height_m"] = _band_m(str(pose["band"]), float(pose["x"]), float(pose["y"]))
	return pose

# The pitch the airframe takes in step k, as combat_resolver.gd's _state_at does: the path's angle in the
# step (the change of band height over the step's length, at the speed), limited to +- combat.json max_pitch_deg.
func _step_pitch(id: String, k: int, s: Dictionary) -> float:
	var mp: float = world.combat.max_pitch
	if not (mp > 0.0):
		return 0.0
	var dh: float = world.band_height(str(s["altitude_band"])) - world.band_height(str(planner.band_before(k, id)))
	var dt: float = world.step_dt(id)
	if dh == 0.0 or not (dt > 0.0) or is_nan(dh):
		return 0.0
	return clampf(atan2(dh / dt, maxf(float(s["speed"]), 1e-9)), -mp, mp)

# The same tilt while a turn plays back: the climb or dive rate over a moment either side of the clock.
func _live_pitch(id: String, speed: float) -> float:
	var mp: float = world.combat.max_pitch
	if not (mp > 0.0):
		return 0.0
	var t := float(playback.playback_t)
	var t0 := maxf(t - 0.1, 0.0)
	var t1 := minf(t + 0.1, world.rules.turn_seconds)
	if t1 - t0 < 1e-6:
		return 0.0
	var a: Dictionary = world.sample(id, t0, "history")
	var b: Dictionary = world.sample(id, t1, "history")
	if a.is_empty() or b.is_empty():
		return 0.0
	var dh := float(b["height_m"]) - float(a["height_m"])
	if absf(dh) < 1e-6:
		return 0.0
	return clampf(atan2(dh / (t1 - t0), maxf(speed, 1e-9)), -mp, mp)

func _band_m(band: String, x: float, y: float) -> float:
	var h: float = world.band_height(band)
	if is_nan(h):
		h = 0.0
	if str(world.rules.band_reference.get(band, "sea_level")) == "terrain":
		h += _ground_at(x, y)
	return h

func _ground_at(x: float, y: float) -> float:
	return float(ground_height.call(x, y)) if ground_height.is_valid() else 0.0

# --- The cones ----------------------------------------------------------------------------------------

# Every weapon cut by the vertical plane along the nose: a forward slice (azimuth 0) and a rearward one
# (azimuth 180), each only if the cone reaches that azimuth. One entry per distinct hardpoint (the wing guns'
# two sit on the same spot side-on, and a wash twice over would read as twice the odds):
#   {weapon, hp, facing (+1 right, -1 left), elevation, half (rad: the slice's half height), arc (rad: the
#    weapon's azimuth half width, PI all around), reach_m, apex_m (Vector2: forward, up, tilted by the pitch)}
func _slices(u: Object, pitch: float) -> Array:
	var out: Array = []
	var cp := cos(pitch)
	var sp := sin(pitch)
	for w in u.def.weapons:
		var all_around: bool = float(w.half_across) >= PI - 1e-9
		var reach_m: float = ConeOverlay.reach_for(w, 1.0, style, range_factor)
		for facing in [1, -1]:
			var az := 0.0 if facing == 1 else PI
			var across: float = Combat.wrap_angle(az - float(w.mount))
			var half := 0.0
			if all_around:
				half = float(w.half_height)
			elif absf(across) <= float(w.half_across):
				var a: float = across / float(w.half_across)
				half = float(w.half_height) * sqrt(maxf(1.0 - a * a, 0.0))
			if half <= 1e-6:
				continue
			var seen := {}
			for hi in w.hardpoints.size():
				var hp: Vector3 = w.hardpoints[hi]
				var ax: float = hp.x * cp - hp.z * sp
				var az_up: float = hp.x * sp + hp.z * cp
				var key := "%.2f,%.2f" % [ax, az_up]
				if seen.has(key):
					continue
				seen[key] = true
				out.append({"weapon": w, "hp": hi, "facing": facing, "elevation": float(w.elevation), "half": half,
					"arc": PI if all_around else float(w.half_across), "reach_m": reach_m, "apex_m": Vector2(ax, az_up)})
	return out

# The scale, the unit's place and the cone records for the guns view; fills the model's frame keys.
# THE SCALE comes from the weapons alone (so it does not change as the target moves): the longest reach forward on the
# right, rearward on the left. THE UNIT'S HEIGHT ON THE PAGE is the room each side needs: by default the cones' own
# extents above and below the unit (a dive hangs its cones below it) and the ground when it is near; and when there
# is a target on the page, the room it needs above or below as far as the page can give it.
func _guns_frame(id: String, u: Object, pose: Dictionary, pic: Vector2, m: Dictionary, tgt: Dictionary) -> void:
	var pitch: float = float(pose["pitch"])
	var slices := _slices(u, pitch)
	var fwd := 0.0
	var rear := 0.0
	var arcs := {1: 0.0, -1: 0.0}
	var up_m := 0.0
	var dn_m := 0.0
	for s: Dictionary in slices:
		if int(s["facing"]) == 1:
			fwd = maxf(fwd, float(s["reach_m"]))
		else:
			rear = maxf(rear, float(s["reach_m"]))
		arcs[int(s["facing"])] = maxf(float(arcs[int(s["facing"])]), float(s["arc"]))
		# The wedge's vertical extent: the reach times the sine of its steepest edge, up and down.
		var mid: float = (pitch + float(s["elevation"])) if int(s["facing"]) == 1 else (PI + pitch - float(s["elevation"]))
		for i in 9:
			var a: float = mid - float(s["half"]) + 2.0 * float(s["half"]) * float(i) / 8.0
			up_m = maxf(up_m, float(s["reach_m"]) * sin(a))
			dn_m = maxf(dn_m, -float(s["reach_m"]) * sin(a))
	var margin: float = style.num("side_view.frame.span_margin")
	var right_m := maxf(style.num("side_view.frame.span_min_m"), fwd * margin)
	var left_m := rear * margin if rear > 0.0 else right_m * style.num("side_view.frame.rear_room_fraction")
	var pad: float = style.num("side_view.section.pad_px")
	var ppm := (pic.x - 2.0 * pad) / (right_m + left_m)
	# The unit's place down the page.
	var above_ground: float = float(pose["height_m"]) - _ground_at(float(pose["x"]), float(pose["y"]))
	if above_ground * ppm <= pic.y * 0.7:
		dn_m = maxf(dn_m, above_ground)   # the ground is near: leave it room
	var fmin: float = style.num("side_view.frame.unit_y_min_frac")
	var fmax: float = style.num("side_view.frame.unit_y_max_frac")
	var f: float = clampf(up_m / (up_m + dn_m), fmin, fmax) if up_m + dn_m > 1.0 else style.num("side_view.frame.unit_y_frac")
	var unit_y := pic.y * f
	if not tgt.is_empty() and not tgt.has("hidden"):
		var rel := _rel(tgt, pose)
		if float(rel["x"]) <= right_m and float(rel["x"]) >= -left_m:
			var inset: float = style.num("side_view.frame.edge_inset_px")
			var lo := maxf(float(rel["z"]), 0.0) * ppm + inset + 1.0
			var hi := pic.y - maxf(-float(rel["z"]), 0.0) * ppm - inset - 1.0
			if lo <= hi:
				unit_y = clampf(unit_y, lo, hi)
			else:
				unit_y = pic.y * (fmax if float(rel["z"]) > 0.0 else fmin)
	var origin := Vector2(pad + left_m * ppm, unit_y)
	var cones: Array = []
	for s: Dictionary in slices:
		var facing := int(s["facing"])
		var e: float = float(s["elevation"])
		var w: Object = s["weapon"]
		var phi := -(pitch + e) if facing == 1 else -PI - pitch + e
		var apex_m: Vector2 = s["apex_m"]
		cones.append({
			"unit": id, "side": str(u.side), "own": true, "weapon": w, "hp": int(s["hp"]),
			"apex": origin + Vector2(apex_m.x, -apex_m.y) * ppm, "phi": phi, "half": float(s["half"]),
			"range_px": float(w.range_m) * ppm, "b0": 0.0, "sp": origin, "side_view": true, "ppm": ppm,
			"reach_px": float(s["reach_m"]) * ppm, "rf": range_factor, "facing": facing, "reach_m": float(s["reach_m"]),
		})
	m["cones"] = cones
	m["ppm"] = ppm
	m["origin"] = origin
	m["arcs"] = arcs
	m["ref"] = pose
	var gy := origin.y + above_ground * ppm
	m["ground_y"] = gy if gy < pic.y - 1.0 else INF

# --- The fall ---------------------------------------------------------------------------------------------

# The bombs' fall view for step k's drop, or {} when the sim gives none. Aimed at the target's SHOWN position
# when it has one (a moving target is followed: the sim picks the release moment itself at resolve and
# drop_spread gives the release point for this aim), else at the drop's own aim. Fills the frame keys.
func _drop_frame(id: String, k: int, tgt: Dictionary, pose: Dictionary, pic: Vector2, m: Dictionary) -> Dictionary:
	var aim: Vector2 = planner.step_aim(k, id)
	if not tgt.is_empty() and not tgt.has("hidden"):
		aim = tgt["pos"]
	if not aim.is_finite():
		return {}
	var info: Variant = world.drop_spread(id, k, aim)
	if not (info is Dictionary) or (info as Dictionary).is_empty() or not bool((info as Dictionary).get("ok", false)):
		return {}
	var d: Dictionary = info
	var release: Vector2 = d["release"]
	var landing: Vector2 = d["aim"]
	var h0: float = float(d["release_height_m"])
	var fall_s: float = float(d["fall_s"])
	var heading: float = float((d["spread"] as Dictionary)["heading"])
	var land_m := release.distance_to(landing)
	# The expected spread the map draws (BombSource's ellipse), along the line of the fall.
	var a_m := 0.0
	var b_m := 0.0
	var bs: Variant = planner.get("bombs")
	if bs != null:
		var sp: Dictionary = (bs.aim_info(id, k, aim) as Dictionary)["spread"]
		a_m = float(sp["along_m"])
		b_m = float(sp["across_m"])
	var dir := (landing - release).normalized() if land_m > 1e-6 else Vector2.from_angle(heading)
	var psi := dir.angle_to(Vector2.from_angle(heading))
	var extent := sqrt(pow(a_m * cos(psi), 2.0) + pow(b_m * sin(psi), 2.0))
	var ref := {"x": release.x, "y": release.y, "heading": heading, "height_m": h0, "pitch": float(pose["pitch"])}
	var need := land_m + extent
	if not tgt.is_empty() and not tgt.has("hidden"):
		# The page makes room for the target, but only so far: a target far beyond the fall is an arrow.
		need = maxf(need, minf(((tgt["pos"] as Vector2) - release).length(), need * style.num("side_view.drop.fit_target_max_factor")))
	need = maxf(need * style.num("side_view.frame.span_margin"), 1.0)
	var top: float = style.num("side_view.drop.top_px")
	var left: float = style.num("side_view.drop.left_px")
	var ppm := minf((pic.x - left - style.num("side_view.drop.right_px")) / need,
		(pic.y - top - style.num("side_view.drop.bottom_px")) / maxf(h0, 1.0))
	var origin := Vector2(left, top)
	# The arc: Bombs.bomb_position's own (level across, height h0 (1 - f^2)), sampled over the fall.
	var bomb := {"x0": release.x, "y0": release.y, "h0": h0, "x": landing.x, "y": landing.y, "fall_s": fall_s,
		"release_turn": 0, "release_t": 0.0}
	var n := maxi(int(style.num("side_view.drop.samples")), 4)
	var arc := PackedVector2Array()
	for i in n + 1:
		var p: Dictionary = Bombs.bomb_position(bomb, 0, fall_s * float(i) / float(n), world.rules.turn_seconds)
		var across_m := Vector2(float(p["x"]), float(p["y"])).distance_to(release)
		arc.append(origin + Vector2(across_m, -(float(p["height_m"]) - h0)) * ppm)
	m["ppm"] = ppm
	m["origin"] = origin
	m["ref"] = ref
	m["ground_y"] = origin.y + h0 * ppm
	return {
		"arc": arc, "land": origin + Vector2(land_m, h0) * ppm, "land_m": land_m, "fall_s": fall_s,
		"spread_px": Vector2(origin.x + (land_m - extent) * ppm, origin.x + (land_m + extent) * ppm),
		"release": release, "aim": landing, "release_height_m": h0, "extent_m": extent,
		"clamped": bool(d.get("clamped", false)), "outside": bool(d.get("outside", false)),
		"releases": bool(d.get("releases", true)), "poor_shot": bool(d.get("poor_shot", false)),
	}

# --- The target --------------------------------------------------------------------------------------------

# Which target the picture is about: {"unit": id or "", "point": Vector2, "source": "step"|"aim"|"selection"} or {}.
#   a step that carries a special: its own target (MotionPlanner.step_target(k), Track T's; {} before it exists),
#   until then the drop's aim; never the selection
#   any other step, and the playback: the target selection (UnitUI.target)
func _raw_target(id: String, k: int, live: bool) -> Dictionary:
	if not live and k >= 0 and planner != null:
		var carries: bool = planner.step_has_drop(k, id)
		if planner.has_method("step_target"):
			var d: Variant = planner.step_target(k)
			if d is Dictionary and not (d as Dictionary).is_empty():
				var own := _raw_from(d, "step")
				if not own.is_empty():
					return own
		if carries:
			var aim: Vector2 = planner.step_aim(k, id)
			return {"unit": "", "point": aim, "source": "aim"} if aim.is_finite() else {}
	var tg := _selection_target()
	if tg != null and tg.has_method("is_set") and bool(tg.is_set()):
		var kind := str(tg.get("kind"))
		if kind == "unit":
			return _raw_from({"unit": str(tg.get("unit_id"))}, "selection")
		if kind == "point":
			return _raw_from({"point": tg.get("point_m")}, "selection")
	return {}

func _raw_from(d: Dictionary, source: String) -> Dictionary:
	var uid := str(d.get("unit", ""))
	if uid != "" and world.units.has(uid):
		return {"unit": uid, "point": Vector2.INF, "source": source}
	var p: Variant = d.get("point")
	if p is Vector2 and (p as Vector2).is_finite():
		return {"unit": "", "point": p, "source": source}
	return {}

# Whether a unit target may be drawn: in sight and on the map (the seam), else simply not down.
func _is_shown(id: String, u: Object) -> bool:
	if unit_visible.is_valid():
		return bool(unit_visible.call(id))
	return not bool(u.down)

# Where a unit is DRAWN: the marker layer's pose (a playback's pose while one plays), else where it is.
func _shown_pose_of(id: String, u: Object) -> Dictionary:
	if shown_pose.is_valid():
		return shown_pose.call(id)
	var s: Dictionary = u.state()
	s["height_m"] = _band_m(str(u.altitude_band), float(u.x), float(u.y))
	return s

# The target as the picture knows it, before it is placed: {} for none, {"hidden": true} for a unit out of sight.
func _normalise_target(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	var src := str(raw["source"])
	var tid := str(raw["unit"])
	if tid != "":
		var tu = world.units.get(tid)
		if tu == null:
			return {}
		if not _is_shown(tid, tu):
			return {"hidden": true, "source": src}
		var s := _shown_pose_of(tid, tu)
		var h := float(s["height_m"]) if s.has("height_m") else _band_m(str(tu.altitude_band), float(s["x"]), float(s["y"]))
		return {"kind": "unit", "source": src, "unit": tid, "name": str(tu.def.name).to_lower(), "side": str(tu.side),
			"ground": str(tu.def.domain) != "air", "pos": Vector2(float(s["x"]), float(s["y"])), "height_m": h}
	var p: Vector2 = raw["point"]
	return {"kind": "point", "source": src, "unit": "", "name": style.text("side_view.text.point"), "side": "", "ground": true,
		"pos": p, "height_m": _ground_at(p.x, p.y)}

# A target's straight-line position from the picture's unit: the horizontal distance (negative behind the nose), the
# height difference, the bearing's size off the nose or the tail. `ref` is {x, y, heading, height_m}.
func _rel(t: Dictionary, ref: Dictionary) -> Dictionary:
	var d: Vector2 = (t["pos"] as Vector2) - Vector2(float(ref["x"]), float(ref["y"]))
	var dist := d.length()
	var az := Combat.wrap_angle(d.angle() - float(ref["heading"])) if dist > 1e-9 else 0.0
	var forward := absf(az) <= PI * 0.5
	return {"x": dist if forward else -dist, "z": float(t["height_m"]) - float(ref["height_m"]), "dist": dist, "forward": forward,
		"off_axis": absf(az) if forward else PI - absf(az)}

# Puts the target on the page: its straight-line position relative to the picture's unit (the horizontal
# distance, negative behind the nose, and the height difference), in px on the model's one scale, and the
# arrow on the edge when the page does not hold it.
func _place_target(t: Dictionary, m: Dictionary, pic: Vector2) -> Dictionary:
	var ref: Dictionary = m["ref"]
	var ppm: float = m["ppm"]
	var origin: Vector2 = m["origin"]
	var r := _rel(t, ref)
	var dist: float = r["dist"]
	var dz: float = r["z"]
	var rel_x: float = r["x"]
	var forward: bool = r["forward"]
	var off_axis: float = r["off_axis"]
	var px := origin + Vector2(rel_x, -dz) * ppm
	var inner := Rect2(Vector2.ZERO, pic).grow(-style.num("side_view.frame.edge_inset_px"))
	var inside := inner.has_point(px)
	var v := px - origin
	var edge := px
	if not inside:
		var tt := 1.0
		if v.x > 1e-9:
			tt = minf(tt, (inner.end.x - origin.x) / v.x)
		elif v.x < -1e-9:
			tt = minf(tt, (inner.position.x - origin.x) / v.x)
		if v.y > 1e-9:
			tt = minf(tt, (inner.end.y - origin.y) / v.y)
		elif v.y < -1e-9:
			tt = minf(tt, (inner.position.y - origin.y) / v.y)
		edge = origin + v * maxf(tt, 0.0)
	var out := t.duplicate()
	out["rel_x"] = rel_x
	out["rel_z"] = dz
	out["dist"] = dist
	out["slant"] = sqrt(dist * dist + dz * dz)
	out["forward"] = forward
	out["off_axis"] = off_axis
	out["px"] = px
	out["inside"] = inside
	out["edge"] = edge
	out["dir"] = v.normalized() if v.length() > 1e-9 else Vector2.RIGHT
	var arcs: Dictionary = m["arcs"]
	out["hollow"] = style.flag("side_view.target.off_axis_hollow") and str(t["kind"]) == "unit" and not bool(t["ground"]) \
		and str(m["mode"]) == "guns" and off_axis > float(arcs.get(1 if forward else -1, 0.0)) + 1e-6
	return out

# The one quiet line under the picture.
func _line(m: Dictionary, tgt_raw: Dictionary) -> String:
	if not style.flag("side_view.text.enabled"):
		return ""
	if tgt_raw.has("hidden"):
		return style.text("side_view.text.unseen")
	var t: Dictionary = m["target"]
	var drop: Dictionary = m["drop"]
	if not drop.is_empty():
		if t.is_empty():
			return style.text("side_view.text.drop_line_free") % [roundi(float(drop["land_m"])), roundi(float(drop["fall_s"]))]
		return style.text("side_view.text.drop_line") % [str(t["name"]), roundi(float(t["dist"])), roundi(float(drop["fall_s"]))]
	if t.is_empty():
		return ""
	var dz: float = t["rel_z"]
	var h := style.text("side_view.text.level")
	if absf(dz) > style.num("side_view.text.level_within_m"):
		h = (style.text("side_view.text.above") if dz > 0.0 else style.text("side_view.text.below")) % roundi(absf(dz))
	return style.text("side_view.text.unit_line") % [str(t["name"]), roundi(float(t["slant"])), h]
