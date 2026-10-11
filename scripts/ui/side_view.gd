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
#   a fire      (Track SH, the warship) a step with Main Guns Fire shows the shell's flight instead of the cones, in the drop's own
#               frame: the ship on the ground line, the arc the shell flies (guns.gd's own model: level across, a parabola up to
#               apex_per_range x the range), where it lands (the target as it is shown) with the expected scatter (two sigma, the
#               card's number) on the ground, and the target indicator as ever; faint when the sim says the salvo would not go
#               off (planner.fire_check: reloading, the target down ...). A salvo whose target is unspotted or out of reach goes off as
#               a POOR SHOT (Alex, outside-cone-release; data/sim/guns.json gun_unspotted_mode) and is drawn in full with a wider
#               scatter; with the mode on "hold" it is faint. Indicators only: the same wash and ink.
#   the words   at most one quiet line under the picture (distance and height difference); data side_view.text.
#
# WHEN. Planning, for a friendly mobile unit that takes orders; and, while a turn plays back
# (side_view.live_during_playback), for the same unit at its SHOWN pose, so the picture follows the playback.
# Hidden for an enemy or nothing selected, and when the window is too short to hold it.
#
# THE THREE STRIPS (decision side-view-views, 2026-10-11). ALEX: "I want to be able to select between top, front & side. I think this
# solves the 'cone but only upwards' problem. Maybe they fold instead of you selecting only one - so you could have all three. It would
# also make it easier to disable the cones on the main map which visually make it much harder to read." And: "1 B - but no limit on which
# are open at a time. I am testing on 4k  2 Yes, lets actually add a button to the panel to turn arcs on/off  3 self only". So the panel
# is a heading row (which step, and the ARCS button: the same switch as the roster's) and three folding STRIPS under it, each a row with
# a fold box and its name (Top, Front, Side) and, unfolded, a picture of the selected unit's OWN cones:
#   Top    the horizontal plane through the unit: the map's cone wash made small (side_view_top.gd)
#   Front  looking along the nose: each weapon's coverage on the plane across it (side_view_front.gd)
#   Side   the vertical plane along the nose: what the panel has always shown, the drop and the fire frames included (this file)
# Each strip folds on its own and any number are open at once; what the player folds is kept for the session (static, like
# ConeOverlay's arcs switch), not per unit. The three projections, the sizes and everything but the quoted words are PROPOSED
# (data/ui/ui.json side_view.strips, .top, .front, .arcs).
# THE ROOM. The card must stay on the screen, so the open strips share the room the window leaves (down to strips.min_picture_h_px each);
# the ones that do not fit are held folded by the room (the player's choice is kept; the strip the player opened last keeps its place
# first, then strips.priority). A window too short even for the three rows and one picture shows the panel as it was before the
# strips ("compact": heading row, the Side picture, the quiet line), and one too short for that shows nothing. A model is
# {"layout": {"mode": "strips" | "compact", ...}}; model()["size"] is always the Side picture's size, model()["top"] and ["front"] the
# other two strips' models (the same keys, the cones as each strip draws them).
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
const SideViewTop = preload("res://scripts/ui/side_view_top.gd")
const SideViewFront = preload("res://scripts/ui/side_view_front.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const Guns = preload("res://scripts/sim/guns.gd")

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
var arcs_state: Callable = Callable()      # () -> bool: whether the map shows the weapon cones (UnitUI.arcs_shown); with none there is no Arcs button

# The Arcs button was pressed: UnitUI points it at the cone overlay's own switch (UnitUI.toggle_arcs), the roster's button's.
signal arcs_pressed

# What the player has folded or unfolded this session: strip id -> open (a strip never touched takes the data's), and the order the
# strips were opened in, the latest first (it decides which strip keeps its picture when the room is short). Forgotten by
# reset_view_setting(); never per unit.
static var _session_open: Dictionary = {}
static var _session_recent: Array = []

# Counted when a draw ran to its end (a runtime error ends one early and silently).
var draw_count: int = 0
var picture_draws: int = 0
var failed_draws: int = 0

var _pic: Control = null                  # the Side strip's picture
var _pics: Dictionary = {}                # strip id -> its picture canvas
var _model: Dictionary = {"active": false}
var _sig: String = ""
var _rev: int = 0
var _base_h: float = 0.0
var _tg_id: int = 0

# The picture's own canvas: it clips to its rect (a wide cone may leave the page).
class _Pic extends Control:
	var panel: Object = null
	var kind: String = "side"
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true
	func _draw() -> void:
		if panel != null:
			panel.paint_strip(kind, self)

func setup(w: World, motion_planner: Object, sel: RefCounted, st: RefCounted = null) -> void:
	world = w
	planner = motion_planner
	selection = sel
	style = (st if st != null else UiStyle.shared()) as UiStyle
	name = "SideView"
	mouse_filter = Control.MOUSE_FILTER_STOP   # the Arcs button and the strips' headers are clicked here
	visible = false
	if _pic == null:
		for id: String in ["side", "top", "front"]:
			var pic := _Pic.new()
			pic.name = "Picture" if id == "side" else "%sPicture" % id.capitalize()
			pic.panel = self
			pic.kind = id
			pic.visible = false
			add_child(pic)
			_pics[id] = pic
		_pic = _pics["side"]
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
	for id: String in _pics:
		(_pics[id] as Control).queue_redraw()

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
	# What is unfolded and what the Arcs button says: a click on either is a change.
	var open_ids := PackedStringArray()
	for sid: String in strip_ids():
		if strip_chosen(sid):
			open_ids.append(sid)
	parts.append("o:" + ",".join(open_ids))
	parts.append("a:" + str(arcs_on()))
	if host != null:
		var pc := host.get_parent_control()
		parts.append("%.0f,%.0f,%.0f" % [host.position.y, host.size.x, pc.size.y if pc != null else 0.0])
	return "|".join(parts)

# --- The strips: what is folded, and in what order they keep their room ----------------------------------

# The strips' ids, top to bottom (data side_view.strips.order).
func strip_ids() -> Array:
	var out: Array = []
	var v: Variant = style.lookup("side_view.strips.order")
	if v is Array:
		for e: Variant in v:
			out.append(str(e))
	return out

func strip_name(id: String) -> String:
	return style.text("side_view.strips.name." + id)

# Whether the player (or, until they touch it, the data) has the strip unfolded: the CHOICE, kept for the session. Whether the room
# lets it show is strip_shown().
func strip_chosen(id: String) -> bool:
	if _session_open.has(id):
		return bool(_session_open[id])
	return style.flag("side_view.strips.open." + id)

# Whether the strip is unfolded on the screen now: chosen, and held by the room (see the header: "THE ROOM"). Read from the model.
func strip_shown(id: String) -> bool:
	var lay: Dictionary = _model.get("layout", {})
	for e: Dictionary in lay.get("strips", []):
		if str(e["id"]) == id:
			return bool(e["shown"])
	return false

# Folds or unfolds one strip, on its own. An unfolded strip comes first when the room is short.
func set_strip_open(id: String, on: bool) -> void:
	if not strip_ids().has(id):
		return
	_session_open[id] = on
	if on:
		_session_recent.erase(id)
		_session_recent.push_front(id)
	_rev += 1
	if world != null and style != null:
		refresh()

func toggle_strip(id: String) -> void:
	set_strip_open(id, not strip_shown(id) if layout_mode() == "strips" else not strip_chosen(id))

# A click on a strip's header: folds a strip that is showing, unfolds one that is not (one the room is holding folded comes forward and
# another gives up its place). False when the panel has no strips on the screen (compact, or nothing shown).
func press_strip(id: String) -> bool:
	if layout_mode() != "strips" or not strip_ids().has(id):
		return false
	toggle_strip(id)
	return true

# Forgets what the player folded and unfolded (tests, a fresh session): the data's starting state rules again.
static func reset_view_setting() -> void:
	_session_open = {}
	_session_recent = []

# The strips in the order they keep their room: the one opened last first, then the data's priority, then the order on the screen.
func _priority_ids() -> Array:
	var ids := strip_ids()
	var out: Array = []
	for id: Variant in _session_recent:
		if ids.has(id) and not out.has(id):
			out.append(id)
	var v: Variant = style.lookup("side_view.strips.priority")
	if v is Array:
		for e: Variant in v:
			if ids.has(str(e)) and not out.has(str(e)):
				out.append(str(e))
	for id: String in ids:
		if not out.has(id):
			out.append(id)
	return out

func layout_mode() -> String:
	return str((_model.get("layout", {}) as Dictionary).get("mode", "off"))

# --- The arcs button -------------------------------------------------------------------------------------------

func has_arcs_button() -> bool:
	return arcs_state.is_valid()

# Whether the map shows the arcs (the button reads pressed); false with no button.
func arcs_on() -> bool:
	return arcs_state.is_valid() and bool(arcs_state.call())

func arcs_label() -> String:
	return style.text("side_view.arcs.label_on" if arcs_on() else "side_view.arcs.label_off")

# The button, in this section's space: in the heading row, at the right.
func arcs_button_rect() -> Rect2:
	var gap: float = style.num("side_view.section.gap_px")
	var head: float = style.num("side_view.section.head_px")
	var w: float = style.num("side_view.arcs.w_px")
	var h: float = style.num("side_view.arcs.h_px")
	return Rect2(Vector2(maxf(size.x - w, 0.0), gap + (head - h) * 0.5), Vector2(w, h))

# The button, as a click does it. False when there is none (or no panel on the screen).
func press_arcs() -> bool:
	if not has_arcs_button() or not is_active():
		return false
	arcs_pressed.emit()
	queue_redraw()
	return true

func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT or not is_active():
		return
	if has_arcs_button() and arcs_button_rect().has_point(mb.position):
		press_arcs()
		accept_event()
		return
	for e: Dictionary in (_model.get("layout", {}) as Dictionary).get("strips", []):
		if (e["head"] as Rect2).size.y > 0.0 and (e["head"] as Rect2).has_point(mb.position):
			press_strip(str(e["id"]))
			accept_event()
			return
	accept_event()   # (the rest of the section is not the orders card's)

func _get_tooltip(at_position: Vector2) -> String:
	if has_arcs_button() and is_active() and arcs_button_rect().has_point(at_position):
		return style.text("side_view.arcs.tooltip")
	return ""

# --- The card's room ------------------------------------------------------------------------

func _caption_h() -> float:
	return style.num("side_view.section.caption_h_px") if style.flag("side_view.text.enabled") else 0.0

# The section's chrome without any strip: the gap, the heading row, the quiet line, the bottom.
func _chrome() -> float:
	return style.num("side_view.section.gap_px") + style.num("side_view.section.head_px") + _caption_h() + style.num("side_view.section.bottom_px")

# How the section is laid out in the room there is (see the header, "THE ROOM"): {"mode": "strips" | "compact" | "off", "w", "shown":
# {id: bool}, "h": {id: picture height}, "section_h"}. With no card to grow (a panel alone) there is no room limit: the strips the
# player has unfolded, at the data's heights.
func _plan_layout() -> Dictionary:
	var ids := strip_ids()
	var pad: float = style.num("card.pad_px")
	var w: float = (host.size.x if host != null else style.num("roster.width_px")) - 2.0 * pad
	var sh: float = style.num("side_view.strips.head_px")
	var sgap: float = style.num("side_view.strips.gap_px")
	var min_h: float = style.num("side_view.strips.min_picture_h_px")
	var pref := {}
	for id: String in ids:
		pref[id] = style.num("side_view.strips.picture_h_px." + id)
	var chosen: Array = []
	for id: String in ids:
		if strip_chosen(id):
			chosen.append(id)
	var room := INF
	if host != null:
		var pc := host.get_parent_control()
		if pc != null and pc.size.y > 1.0:
			room = pc.size.y - style.num("card.margin_px") - (host.position.y + _base_h)
	var shown := {}
	var heights := pref.duplicate()
	var mode := "strips"
	var base := _chrome() + float(ids.size()) * sh
	if room == INF:
		for id: String in chosen:
			shown[id] = true
	elif room >= base + (0.0 if chosen.is_empty() else min_h + sgap):
		var by_priority: Array = []
		for id: Variant in _priority_ids():
			if chosen.has(id):
				by_priority.append(id)
		var n := chosen.size()
		var each := 0.0
		while n > 0:
			each = (room - base - float(n) * sgap) / float(n)
			if each >= min_h:
				break
			n -= 1
		for i in n:
			var id2: String = by_priority[i]
			shown[id2] = true
			heights[id2] = minf(float(pref[id2]), each)
	else:
		# Too short for the strips: the panel as it was, the Side picture alone, if even that fits.
		mode = "compact"
		var side_h := minf(float(style.num("side_view.section.picture_h_px")), room - _chrome())
		if side_h < style.num("side_view.section.min_picture_h_px"):
			return {"mode": "off", "w": w, "shown": {}, "h": heights, "section_h": 0.0}
		shown["side"] = true
		heights["side"] = side_h
	var section_h := _chrome()
	if mode == "strips":
		for id: String in ids:
			section_h += sh
			if shown.has(id):
				section_h += float(heights[id]) + sgap
	else:
		section_h += float(heights["side"])
	return {"mode": mode, "w": w, "shown": shown, "h": heights, "section_h": section_h}

# Where everything is, in the section's own space: the plan as rectangles.
func _rects(plan: Dictionary) -> Dictionary:
	var w: float = plan["w"]
	var gap: float = style.num("side_view.section.gap_px")
	var head: float = style.num("side_view.section.head_px")
	var sh: float = style.num("side_view.strips.head_px")
	var sgap: float = style.num("side_view.strips.gap_px")
	var y := gap + head
	var strips: Array = []
	if str(plan["mode"]) == "strips":
		for id: String in strip_ids():
			var row := Rect2(0.0, y, w, sh)
			y += sh
			var shown: bool = (plan["shown"] as Dictionary).has(id)
			var pic := Rect2()
			if shown:
				pic = Rect2(0.0, y, w, float((plan["h"] as Dictionary)[id]))
				y += pic.size.y + sgap
			strips.append({"id": id, "name": strip_name(id), "chosen": strip_chosen(id), "shown": shown, "head": row, "pic": pic})
	else:
		var side := Rect2(0.0, y, w, float((plan["h"] as Dictionary)["side"]))
		y += side.size.y
		strips.append({"id": "side", "name": strip_name("side"), "chosen": true, "shown": true, "head": Rect2(), "pic": side})
	return {"mode": plan["mode"], "w": w, "section_h": plan["section_h"], "strips": strips,
		"head": Rect2(0.0, gap, w, head), "caption": Rect2(0.0, y, w, _caption_h())}

# Sizes the section and grows (or restores) the card.
func _apply_layout() -> void:
	var on := bool(_model.get("active", false))
	if on:
		var lay: Dictionary = _model["layout"]
		for id: String in _pics:
			(_pics[id] as Control).visible = false
		for e: Dictionary in lay["strips"]:
			if bool(e["shown"]):
				var pic: Control = _pics[str(e["id"])]
				pic.visible = true
				pic.position = (e["pic"] as Rect2).position
				pic.size = (e["pic"] as Rect2).size
		size = Vector2(float(lay["w"]), float(lay["section_h"]))
		if host == null:
			return
		position = Vector2(style.num("card.pad_px"), _base_h)
	else:
		for id: String in _pics:
			(_pics[id] as Control).visible = false
		if host == null:
			return
	var want := _base_h + (size.y if on else 0.0)
	if not is_equal_approx(host.custom_minimum_size.y, want):
		host.custom_minimum_size = Vector2(host.custom_minimum_size.x, want)
		host.size = Vector2(host.size.x, want)
		host.queue_redraw()

# --- Drawing -----------------------------------------------------------------------------------

func _draw() -> void:
	if not bool(_model.get("active", false)):
		return
	var st := style
	var ink: Color = st.color("ink")
	var soft: Color = st.color("ink")   # (Track L, readable lettering: the heading and the caption are full ink in the label face, 14 px)
	var faint: Color = st.color("ink_faint")
	var label_face: Font = st.text_font()
	var detail: float = st.num("fonts.detail_px")
	var lay: Dictionary = _model["layout"]
	var head_r: Rect2 = lay["head"]
	UiInk.ink_line(self, PackedVector2Array([Vector2(0.0, 1.0), Vector2(size.x, 1.0)]), false, faint, 0.8, 9, 0.4)
	var head_w := size.x - (st.num("side_view.arcs.w_px") + 8.0 if has_arcs_button() else 0.0)
	UiInk.text(self, label_face, Vector2(0.0, head_r.end.y - 5.0), str(_model["head"]), detail, soft, HORIZONTAL_ALIGNMENT_LEFT, head_w)
	if has_arcs_button():
		_draw_arcs_button(ink)
	for e: Dictionary in lay["strips"]:
		if (e["head"] as Rect2).size.y > 0.0:
			_draw_strip_head(e, ink)
	var line := str(_model["line"])
	if line != "":
		var cap: Rect2 = lay["caption"]
		UiInk.text(self, label_face, Vector2(0.0, cap.end.y - 5.0), line, detail, soft, HORIZONTAL_ALIGNMENT_LEFT, size.x)
	draw_count += 1

# "Arcs: on" filled with ink and lettered in paper (a toggle that is on), or "Arcs: off" raised: the roster button's pair of roles.
func _draw_arcs_button(ink: Color) -> void:
	var st := style
	var r := arcs_button_rect()
	var on := arcs_on()
	draw_rect(r, st.color("button_on_fill") if on else st.color("button_fill"), true)
	UiInk.ink_line(self, UiInk.rect_pts(r), true, ink, 1.0, 17, 0.35)
	var px: float = st.num("fonts.button_px")
	UiInk.text(self, st.font(false), Vector2(r.position.x, r.position.y + r.size.y * 0.5 + px * 0.34), arcs_label(), px,
		st.color("button_on_text") if on else ink, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)

# A strip's header row: the fold box (filled with ink and a paper chevron down when the strip is unfolded, paper with an ink chevron
# right when it is folded) and the strip's name in the card face.
func _draw_strip_head(e: Dictionary, ink: Color) -> void:
	var st := style
	var row: Rect2 = e["head"]
	var q: float = st.num("side_view.strips.box_px")
	var box := Rect2(Vector2(0.0, row.position.y + (row.size.y - q) * 0.5), Vector2(q, q))
	var on: bool = bool(e["shown"])
	draw_rect(box, st.color("button_on_fill") if on else st.color("button_fill"), true)
	UiInk.ink_line(self, UiInk.rect_pts(box), true, ink, st.num("side_view.strips.box_line_px"), 21, 0.3)
	var c := box.get_center()
	var k: float = st.num("side_view.strips.chevron_px")
	var chev: PackedVector2Array
	if on:
		chev = PackedVector2Array([Vector2(c.x - k, c.y - k * 0.5), Vector2(c.x, c.y + k * 0.5), Vector2(c.x + k, c.y - k * 0.5)])
	else:
		chev = PackedVector2Array([Vector2(c.x - k * 0.5, c.y - k), Vector2(c.x + k * 0.5, c.y), Vector2(c.x - k * 0.5, c.y + k)])
	draw_polyline(chev, st.color("button_on_text") if on else ink, st.num("side_view.strips.chevron_line_px"), true)
	var px: float = st.num("side_view.strips.name_px")
	UiInk.text(self, st.font(false), Vector2(q + st.num("side_view.strips.box_gap_px"), row.end.y - 6.0), str(e["name"]), px, ink)

# Called by a picture canvas: the strip of that kind.
func paint_strip(kind: String, ci: CanvasItem) -> void:
	if not bool(_model.get("active", false)):
		return
	match kind:
		"top":
			failed_draws += SideViewTop.paint(ci, _model["top"], style)
		"front":
			failed_draws += SideViewFront.paint(ci, _model["front"], style)
		_:
			failed_draws += SideViewArt.paint(ci, _model, style)
	picture_draws += 1

# (the Side strip's canvas, as before)
func paint_picture(ci: CanvasItem) -> void:
	paint_strip("side", ci)

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
	var plan := _plan_layout()
	if str(plan["mode"]) == "off":
		return off
	var pic := Vector2(float(plan["w"]), float((plan["h"] as Dictionary)["side"]))
	var pose := _pose(id, u, live)
	var k: int = int(pose["step"])
	var tgt := _normalise_target(_raw_target(id, k, live))
	var m := {"active": true, "unit": id, "side": str(u.side), "live": live, "size": pic, "step": k, "pose": pose,
		"mode": "guns", "cones": [], "drop": {}, "target": {}, "target_hidden": bool(tgt.get("hidden", false)),
		"ref": pose, "ppm": 1.0, "origin": Vector2.ZERO, "ground_y": INF, "arcs": {}}
	var drop := {}
	var mode := "drop"
	if not live and k >= 0 and planner.step_has_drop(k, id):
		drop = _drop_frame(id, k, tgt, pose, pic, m)
	elif not live and k >= 0 and planner.has_method("step_has_fire") and planner.step_has_fire(k, id):
		drop = _fire_frame(id, k, tgt, pic, m)
		mode = "fire"
	if drop.is_empty():
		_guns_frame(id, u, pose, pic, m, tgt)
	else:
		m["mode"] = mode
		m["drop"] = drop
	if not tgt.is_empty() and not tgt.has("hidden"):
		m["target"] = _place_target(tgt, m, pic)
	m["head"] = style.text("side_view.text.head_live") if live else (style.text("side_view.text.head_step") % (k + 1) if k >= 0 else style.text("side_view.text.head_now"))
	m["line"] = _line(m, tgt)
	# The other two strips, the unit as the same step leaves it and the same target (their projections: side_view_top.gd, side_view_front.gd).
	m["top"] = SideViewTop.model(u, id, pose, tgt, Vector2(float(plan["w"]), float((plan["h"] as Dictionary)["top"])), style, range_factor)
	m["front"] = SideViewFront.model(u, id, pose, tgt, Vector2(float(plan["w"]), float((plan["h"] as Dictionary)["front"])), style, range_factor,
		float(pose["height_m"]) - _ground_at(float(pose["x"]), float(pose["y"])))
	m["layout"] = _rects(plan)
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

# THE SHELL'S FLIGHT (Track SH): the salvo planned at step k as the drop's frame: the ship at the origin on the ground line, the arc the
# shells fly to where they land (the target as it is shown; the sim leads a moving one only at resolve, as it does a bomb's aim), the
# expected scatter on the ground. The arc is guns.gd's own: Guns.shell_position's level line across and parabola in height, apex
# apex_per_range x the range. Returns the same record the fall does (arc, land, land_m, fall_s, spread_px, ...) plus "releases": whether the
# sim would fire it as things stand, or {} when there is none. Fills the frame keys. One scale for both axes, so the angles are true.
func _fire_frame(id: String, k: int, tgt: Dictionary, pic: Vector2, m: Dictionary) -> Dictionary:
	var chk: Dictionary = planner.fire_check(k, id) if planner.has_method("fire_check") else {}
	if chk.is_empty() or not world.guns.has_special(str(chk.get("special", ""))):
		return {}
	var spec: Object = world.guns.special(str(chk["special"]))
	var from: Vector2 = chk["from"]
	var aim: Vector2 = chk["target_pos"]
	if not tgt.is_empty() and not tgt.has("hidden"):
		aim = tgt["pos"]
	var land_m := from.distance_to(aim)
	var flight := Guns.flight_time(land_m, spec)
	var apex: float = float(spec.apex_per_range) * land_m
	var extent: float = style.num("guns.marks.sigma_k") * float(chk["spread_m"])
	var need := land_m + extent
	if not tgt.is_empty() and not tgt.has("hidden"):
		need = maxf(need, minf(((tgt["pos"] as Vector2) - from).length(), need * style.num("side_view.drop.fit_target_max_factor")))
	need = maxf(need * style.num("side_view.frame.span_margin"), 1.0)
	var top: float = style.num("side_view.drop.top_px")
	var left: float = style.num("side_view.drop.left_px")
	var bottom: float = style.num("side_view.drop.bottom_px")
	var ppm := minf((pic.x - left - style.num("side_view.drop.right_px")) / need, (pic.y - top - bottom) / maxf(apex, 1.0))
	var origin := Vector2(left, pic.y - bottom)
	var heading := (aim - from).angle() if land_m > 1e-6 else 0.0
	var shell := {"x0": from.x, "y0": from.y, "x": aim.x, "y": aim.y, "fall_s": flight, "apex_m": apex, "release_turn": 0, "release_t": 0.0}
	var n := maxi(int(style.num("side_view.drop.samples")), 4)
	var arc := PackedVector2Array()
	for i in n + 1:
		var p: Dictionary = Guns.shell_position(shell, 0, flight * float(i) / float(n), world.rules.turn_seconds)
		var across_m := Vector2(float(p["x"]), float(p["y"])).distance_to(from)
		arc.append(origin + Vector2(across_m, -float(p["height_m"])) * ppm)
	m["ppm"] = ppm
	m["origin"] = origin
	m["ref"] = {"x": from.x, "y": from.y, "heading": heading, "height_m": 0.0, "pitch": 0.0}
	m["ground_y"] = origin.y
	return {
		"arc": arc, "land": origin + Vector2(land_m, 0.0) * ppm, "land_m": land_m, "fall_s": flight,
		"spread_px": Vector2(origin.x + (land_m - extent) * ppm, origin.x + (land_m + extent) * ppm),
		"release": from, "aim": aim, "release_height_m": 0.0, "extent_m": extent, "apex_m": apex,
		"clamped": false, "outside": false, "releases": bool(chk["ok"]) or bool(chk.get("poor_shot", false)), "poor_shot": bool(chk.get("poor_shot", false)), "fire": true,
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
	if not drop.is_empty() and str(m["mode"]) == "fire":
		if t.is_empty():
			return style.text("side_view.text.fire_line_free") % [roundi(float(drop["land_m"])), roundi(float(drop["fall_s"]))]
		return style.text("side_view.text.fire_line") % [str(t["name"]), roundi(float(t["dist"])), roundi(float(drop["fall_s"]))]
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
