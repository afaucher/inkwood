extends Control

# The roster sidebar (exit criterion 6; design doc, Unit roster sidebar: "a
# sidebar on the right summarizes every unit the players control"). A floating
# card in the map's ink, one row per player-controlled unit, three lines:
#
#   (side roundel)  NAME                              ▮▮▮▯▯   <- health pips
#                   Type · 100 m/s · medium
#                   —● plan: 3 of 5 steps             o o o . .   <- step pips
#                   - -o no plan (flies on)
#
# NAME is the unit's callsign (Alex 2026-10-09: callsigns show first), else its
# id made readable. The health pips are the unit's def.health, filled for what
# is left (UiHealth: the value shown is the turn's start while a resolve plays
# back, so a hit is never spoiled). The third line is the PLAN STATUS, for
# co-op (Alex: last edit wins, with a full preview so every player sees what
# has plans and what does not): "plan: n of m steps" with a solid path glyph,
# or "no plan (flies on)" with a dashed one -- the same marks the motion
# planner draws on the map -- live on World.plan_changed, whoever made the
# edit (this player, another player over the network). The header counts the
# units still without a plan while the turn is planned.
#
# After the planning phase (the turn resolving, played back) a live unit's third
# line reads "flying the turn": its plan is consumed, not missing.
#
# A DOWN unit's row is greyed: its name struck through, the pips empty, its
# state where the plan status was -- "destroyed" (it exploded), "out of control"
# (nobody can plan it; it flies down over a turn or more) or "crashed" (Alex
# 2026-10-09, Track C's Unit.fate), plain "down" when the unit has no fate --
# and no step pips. A row stays while the unit does. It cannot be selected
# (UiSelection.allow): a click on it emits down_unit_picked instead (the host
# may look at where it fell) and the selection stays as it was.
#
# Click a row to select its unit; the selection is the shared UiSelection, so
# the marker's ring and the motion planner follow, and a marker clicked on the
# map selects its row here.
#
# Units belong to nobody (design doc, Co-op and turns): every player-controlled
# unit is listed for every player.
#
# GROUP BY (Alex 2026-10-09: "we want a group by for needs orders"; Track U2).
# A button in the header ("group by [none]") cycles the grouping. Built: "none"
# (the world's order, no headings) and "needs orders" (small headings "needs
# orders" / "planned" / "down", each with its count; an empty group has none).
# The doc's other groupings (domain, unit type, nest) are not built; a mode is an
# entry of ui.json roster.group.modes and a branch of _group_key. It is a
# per-player VIEW setting: kept here (group_by), never in the World, never sent
# over the network.
#
# KEEPING A ROW STILL (proposed rule; ui.json roster.group._reason): rows must
# not move under a pointer while another player plans. The grouped layout is
# recomputed AT ONCE only when planning starts, when the mode changes and when
# units are added or removed. At any other change -- an edit by this player or
# another, a unit going down -- it is recomputed only while the pointer is NOT
# over the roster, and the row of the SELECTED unit keeps the group it was in
# until another unit is selected (so the plane you are planning does not hop
# headings under your hands). While the pointer is over the roster nothing
# moves; the roster catches up when it leaves. During the playback the layout is
# held. The rows' own text (plan status, health) is always live.
#
# THE SEAM: ordered_ids() is the order the rows are shown in (the layout's);
# rows(), row_rect(i), row_at(), select_row(i) and Tab all follow it.
#
# Mount: a Control anywhere in the HUD (UnitUI anchors it to the right edge);
# setup(world, selection). Thin input: rows(), row_at(point), select_row(i),
# cycle_group().

signal unit_selected(unit_id: String)
signal down_unit_picked(unit_id: String)
signal group_changed(mode: String)

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiHealth = preload("res://scripts/ui/ui_health.gd")

var world: World = null
var selection: RefCounted = null
# The marker layer, when there is one: while it plays a resolve back, rows show
# each unit's speed and band at the playback time, not the turn's end.
var playback: Object = null
var style: UiStyle = null
# The health the rows show (UnitUI shares it with the ring's arc).
var health: UiHealth = null

# The grouping this player chose: an id of ui.json roster.group.modes.
var group_by: String = "none"

var _hover := false                 # the pointer is over the roster
var _pending := false               # a regroup was held back (hover)
var _listed: Array[String] = []     # the units the layout was built for (the world's order)
var _group_of: Dictionary = {}      # unit id -> the group key it is shown under ("" with no headings)
var _layout: Array = []             # [{kind: "heading", group, count, y} | {kind: "row", id, y}], top to bottom
var _order: Array[String] = []      # the row units, in layout order
var _row_rects: Array[Rect2] = []   # parallel to _order
var _row_sep: Array[bool] = []      # parallel: a rule under this row (the next entry is a row too)
var _content_h := 0.0

func setup(w: World, sel: RefCounted, st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	world = w
	selection = sel
	if health == null:
		health = UiHealth.new()
	health.setup(w)
	mouse_filter = Control.MOUSE_FILTER_STOP
	group_by = style.text("roster.group.default")
	if not selection.changed.is_connected(_on_changed_id):
		selection.changed.connect(_on_changed_id)
		world.plan_changed.connect(_on_changed_id)
		world.phase_changed.connect(_on_phase_changed)
		world.ready_changed.connect(func(_p: String, _r: bool) -> void: queue_redraw())
		world.turn_resolved.connect(func(_t: int, _h: Dictionary, _e: Array) -> void: queue_redraw())
		mouse_entered.connect(set_pointer_over.bind(true))
		mouse_exited.connect(set_pointer_over.bind(false))
	_regroup(true)
	custom_minimum_size = Vector2(style.num("roster.width_px"), preferred_height())
	size = custom_minimum_size
	queue_redraw()

# --- Rows ------------------------------------------------------------------------------

# The units the roster lists, in the world's order.
func _listed_ids() -> Array[String]:
	var out: Array[String] = []
	if world == null:
		return out
	for id: String in world.units:
		if world.units[id].controller == World.CONTROLLER_PLAYER:
			out.append(id)
	return out

# The order the rows are shown in -- THE seam for sorting and grouping: the
# world's order with group-by "none", else the layout's (headings aside).
func ordered_ids() -> Array[String]:
	_fresh()
	return _order.duplicate()

# Units added or removed since the layout was built (a host spawning mid-game)
# rebuild it, whatever the pointer does.
func _fresh() -> void:
	if world != null and _listed_ids() != _listed:
		_regroup(true)

# The listed units that can take orders: not down. (Tab walks these, in the order shown.)
func selectable_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in _order:
		if selection == null or selection.can_select(id):
			out.append(id)
	return out

func _playing() -> bool:
	return playback != null and bool(playback.is_playing())

func _planned_steps(u: Object) -> int:
	var n := 0
	for r: Dictionary in u.plan:
		if not r.is_empty():
			n += 1
	return n

# "down" | "plan" | "none" | "flying" (a live unit after the planning phase: its
# plan is consumed, not missing).
func _status_of(id: String, playing: bool) -> String:
	if health.shown_down(id, playing):
		return "down"
	if world.phase != World.PHASE_PLANNING:
		return "flying"
	return "plan" if _planned_steps(world.units[id]) > 0 else "none"

# What each row shows, as data (the test reads this): id, name (the unit's
# callsign, else its id made readable), type, speed (m/s), band, planned,
# steps, side, selected -- and, for the first fight: health (pips shown),
# health_max, down, fate ("" | "exploded" | "out_of_control" | "crashed": Track
# C's Unit.fate, read defensively), status ("plan" | "none" | "down" |
# "flying": a live unit after the planning phase, its plan consumed), has_plan
# (planning, live, at least one planned step), needs_orders (planning, live, no
# plan), group (the group key the row is shown under, "" with no headings: not
# always the status's, see KEEPING A ROW STILL). In the order shown.
func rows() -> Array[Dictionary]:
	_fresh()
	var out: Array[Dictionary] = []
	var playing := _playing()
	for id: String in _order:
		var u = world.units[id]
		var pose: Dictionary = playback.pose_of(id) if playing else u.state()
		var planned := _planned_steps(u)
		var status := _status_of(id, playing)
		out.append({
			"id": id,
			"name": unit_name(u),
			"type": u.def.name,
			"speed": float(pose["speed"]),
			"band": str(pose["altitude_band"]),
			"planned": planned,
			"steps": int(u.def.actions_per_turn),
			"side": str(u.side),
			"selected": selection != null and selection.unit_id == id,
			"health": health.shown(id, playing),
			"health_max": int(u.def.health),
			"down": status == "down",
			"fate": health.shown_fate(id, playing),
			"status": status,
			"has_plan": status == "plan",
			"needs_orders": status == "none",
			"group": str(_group_of.get(id, "")),
		})
	return out

# How many live units still have no plan this turn (they will fly on).
func needs_orders_count() -> int:
	var n := 0
	if world == null or world.phase != World.PHASE_PLANNING:
		return 0
	for id: String in _order:
		if _status_of(id, false) == "none":
			n += 1
	return n

# The header's right-hand text: the turn and, while it is planned, who still
# needs orders; "playing" while a resolve plays back; else the phase.
func header_status() -> String:
	if _playing():
		return "Turn %d · playing" % world.turn
	if world.phase != World.PHASE_PLANNING:
		return "Turn %d · %s" % [world.turn, world.phase]
	var n := needs_orders_count()
	var txt: String
	if n == 0:
		txt = style.text("roster.text.all_planned")
	elif n == 1:
		txt = style.text("roster.text.needs_orders_one")
	else:
		txt = style.text("roster.text.needs_orders_many") % n
	return "Turn %d · %s" % [world.turn, txt]

# The plan status line of a row, as its text.
func status_text(row: Dictionary) -> String:
	match str(row["status"]):
		"down":
			# Why it is down (Alex 2026-10-09: it explodes, or it is out of control and
			# crashes eventually): Track C's Unit.fate when the unit has one.
			var fate := str(row.get("fate", ""))
			if fate != "" and style.lookup("roster.text.fate_" + fate) is String:
				return style.text("roster.text.fate_" + fate)
			return style.text("roster.text.down")
		"plan":
			return style.text("roster.text.has_plan") % [int(row["planned"]), int(row["steps"])]
		"flying":
			return style.text("roster.text.flying")
	return style.text("roster.text.no_plan")

# A unit's name on the roster: its callsign (Alex 2026-10-09, data/names/
# callsigns.json) when it has one, else its id made readable.
static func unit_name(u: Object) -> String:
	var cs := str(u.get("callsign")) if u.get("callsign") != null else ""
	return cs if cs != "" else display_name(str(u.id))

# A unit's id made readable (the fallback name) -- "p1" -> "P1",
# "light_fighter_2" -> "Light fighter 2".
static func display_name(id: String) -> String:
	var s := id.replace("_", " ").strip_edges()
	if s.length() <= 3:
		return s.to_upper()
	return s.substr(0, 1).to_upper() + s.substr(1)

# --- Grouping ---------------------------------------------------------------------------

# The modes ui.json offers: [{id, label, headings}].
func group_modes() -> Array:
	var v: Variant = style.lookup("roster.group.modes")
	return v if v is Array else []

func _mode_record(mode: String) -> Dictionary:
	for m: Variant in group_modes():
		if m is Dictionary and str((m as Dictionary).get("id", "")) == mode:
			return m
	return {}

func group_label(mode: String = "") -> String:
	return str(_mode_record(group_by if mode == "" else mode).get("label", "?"))

# Choose a grouping (a mode id of the data). False for an unknown one. A view
# setting of this player only; the layout is rebuilt at once, pointer or not.
func set_group_by(mode: String) -> bool:
	if _mode_record(mode).is_empty():
		return false
	if mode == group_by:
		return true
	group_by = mode
	_regroup(true)
	group_changed.emit(mode)
	return true

# The next mode in the data's order (the header button).
func cycle_group() -> void:
	var ms := group_modes()
	if ms.is_empty():
		return
	var i := 0
	for k in ms.size():
		if str((ms[k] as Dictionary).get("id", "")) == group_by:
			i = k
	set_group_by(str((ms[(i + 1) % ms.size()] as Dictionary).get("id", "none")))

# The group a unit belongs under in `mode` (its TRUE group now; the layout may
# hold it elsewhere for a moment). "" for a mode with no headings.
func _group_key(id: String, mode: String) -> String:
	match mode:
		"needs_orders":
			match _status_of(id, _playing()):
				"down":
					return "down"
				"none":
					return "needs_orders"
			return "planned"
	return ""

# The pointer is over the roster (Control's mouse signals call this; a test may
# too). Leaving catches up on whatever was held back.
func set_pointer_over(over: bool) -> void:
	_hover = over
	if not over and _pending:
		_regroup(false)

func pointer_over() -> bool:
	return _hover

# Recompute the layout. `force`: planning starting, a mode change, a change of
# the units -- applied whatever the pointer does. Otherwise (see KEEPING A ROW
# STILL) not while the pointer is over the roster (held, applied when it leaves)
# nor outside the planning phase (held through the playback), and the selected
# unit's row stays in the group it is in.
func _regroup(force: bool) -> void:
	if world == null:
		return
	var ids := _listed_ids()
	var structural := ids != _listed
	var hard := force or structural
	if not hard:
		if world.phase != World.PHASE_PLANNING:
			return
		if _hover:
			_pending = true
			return
	var sel: String = selection.unit_id if selection != null else ""
	var groups := {}
	for id: String in ids:
		var g := _group_key(id, group_by)
		if not hard and id == sel and _group_of.has(id):
			g = str(_group_of[id])   # the plane being planned keeps its place
		groups[id] = g
	_group_of = groups
	_listed = ids
	_pending = false
	_build_layout()
	_fit_size()
	queue_redraw()

func _build_layout() -> void:
	var headings: Array = _mode_record(group_by).get("headings", [])
	var y := list_top()
	var rh: float = style.num("roster.row_px")
	var hh: float = style.num("roster.group.heading_px")
	_layout = []
	_order = []
	_row_rects = []
	_row_sep = []
	var pad: float = style.num("card.pad_px") * 0.5
	var width := style.num("roster.width_px")
	if headings.is_empty():
		for id: String in _listed:
			_add_row(id, y, rh, pad, width)
			y += rh
	else:
		var placed := {}
		for key: Variant in headings:
			var members: Array[String] = []
			for id: String in _listed:
				if str(_group_of.get(id, "")) == str(key):
					members.append(id)
			if members.is_empty():
				continue
			_layout.append({"kind": "heading", "group": str(key), "count": members.size(), "y": y})
			y += hh
			for id: String in members:
				_add_row(id, y, rh, pad, width)
				placed[id] = true
				y += rh
		for id: String in _listed:   # (a unit whose group the data does not list: still shown)
			if not placed.has(id):
				_add_row(id, y, rh, pad, width)
				y += rh
	_content_h = y - list_top()

func _add_row(id: String, y: float, rh: float, pad: float, width: float) -> void:
	# A fine rule runs under a row only when the next thing is a row too.
	if not _layout.is_empty() and str((_layout.back() as Dictionary)["kind"]) == "row":
		_row_sep[_row_sep.size() - 1] = true
	_layout.append({"kind": "row", "id": id, "y": y})
	_order.append(id)
	_row_rects.append(Rect2(Vector2(pad, y), Vector2(width - 2.0 * pad, rh)))
	_row_sep.append(false)

# Where the list starts: under the header and the group-by bar.
func list_top() -> float:
	return style.num("roster.header_px") + style.num("roster.group.bar_px")

func preferred_height() -> float:
	return list_top() + maxf(style.num("roster.row_px"), _content_h) + style.num("card.pad_px")

func _fit_size() -> void:
	var h := preferred_height()
	if absf(h - custom_minimum_size.y) > 0.5 or custom_minimum_size.x <= 0.0:
		custom_minimum_size = Vector2(style.num("roster.width_px"), h)
		size = custom_minimum_size

# The group-by button, in this control's space.
func group_button_rect() -> Rect2:
	var pad: float = style.num("card.pad_px")
	var w: float = style.num("roster.group.button_w_px")
	var h: float = style.num("roster.group.button_h_px")
	var bar: float = style.num("roster.group.bar_px")
	return Rect2(Vector2(size.x - pad - w, style.num("roster.header_px") + (bar - h) * 0.5), Vector2(w, h))

# The headings of the layout as data: [{group, text, count, y}].
func headings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in _layout:
		if e["kind"] == "heading":
			out.append({"group": e["group"], "text": style.text("roster.group.heading." + str(e["group"])), "count": e["count"], "y": e["y"]})
	return out

func row_rect(i: int) -> Rect2:
	if i < 0 or i >= _row_rects.size():
		return Rect2()
	return _row_rects[i]

# The row index under a point in this control's space, or -1.
func row_at(point: Vector2) -> int:
	_fresh()
	for i in _row_rects.size():
		if _row_rects[i].has_point(point):
			return i
	return -1

# Pick row i. True when its unit is now selected; false for a row out of range
# or a down unit's (which cannot be selected: down_unit_picked fires instead,
# and the selection stays).
func select_row(i: int) -> bool:
	_fresh()
	if i < 0 or i >= _order.size():
		return false
	var id := _order[i]
	if not selection.can_select(id):
		down_unit_picked.emit(id)
		return false
	selection.select(id)
	unit_selected.emit(id)
	return true

func selected_index() -> int:
	return _order.find(selection.unit_id) if selection != null else -1

# Where the selected row's leader line lands, in this control's parent space
# (the left edge of the row, at its middle).
func row_anchor(id: String) -> Vector2:
	var i := _order.find(id)
	if i < 0:
		return Vector2.INF
	var r := row_rect(i)
	return position + Vector2(r.position.x, r.get_center().y)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if group_button_rect().has_point(mb.position):
				cycle_group()
				accept_event()
				return
			var i := row_at(mb.position)
			if i >= 0:
				select_row(i)
				accept_event()

func _process(_delta: float) -> void:
	if _playing():
		queue_redraw()
	_fresh()

func _on_changed_id(_x: Variant = null) -> void:
	_regroup(false)
	_fit_size()
	queue_redraw()

func _on_phase_changed(phase: String) -> void:
	# Planning starting regroups at once (the turn's plans are new); the rest of the
	# turn the layout is held.
	if phase == World.PHASE_PLANNING:
		_regroup(true)
	_fit_size()
	queue_redraw()

# --- Drawing -----------------------------------------------------------------------

func _draw() -> void:
	if world == null:
		return
	var st := style
	var ink: Color = st.color("ink")
	var soft: Color = st.color("ink_soft")
	var faint: Color = st.color("ink_faint")
	var r := Rect2(Vector2.ZERO, size)
	UiInk.card_shadow(self, r, st.shadow_dir() * st.num("card.lift_px"), st.color("card_shadow"))
	UiInk.card(self, r, st.color("card_fill"), ink, st.num("card.outer_line_px"), st.num("card.inner_line_px"),
		st.num("card.inner_inset_px"), st.num("card.wobble_px"), 7)
	var serif: Font = st.font(false)
	var italic: Font = st.font(true)
	var pad: float = st.num("card.pad_px")
	var title_px: float = st.num("fonts.title_px")
	# Header: the roster's title, the turn and who still needs orders.
	UiInk.text(self, serif, Vector2(pad, 26.0), "R O S T E R", title_px, ink)
	UiInk.text(self, italic, Vector2(0.0, 26.0), header_status(), st.num("fonts.detail_px"), soft,
		HORIZONTAL_ALIGNMENT_RIGHT, size.x - pad)
	UiInk.ink_line(self, PackedVector2Array([Vector2(pad, 34.0), Vector2(size.x - pad, 34.0)]), false, faint, 0.8, 3, 0.4)
	_draw_group_bar(ink, soft, serif, italic)
	for e: Dictionary in _layout:
		if e["kind"] == "heading":
			_draw_heading(e, soft, faint, italic)
	var list := rows()
	for i in list.size():
		_draw_row(i, list[i], ink, soft, faint, serif, italic)

# "group by [needs orders]": the label and the button that cycles the grouping.
func _draw_group_bar(ink: Color, soft: Color, _serif: Font, italic: Font) -> void:
	var st := style
	var b := group_button_rect()
	var detail: float = st.num("fonts.detail_px")
	UiInk.text(self, italic, Vector2(st.num("card.pad_px"), b.position.y + b.size.y * 0.5 + detail * 0.34), st.text("roster.group.label"), detail, soft)
	draw_rect(b, st.color("button_fill"), true)
	UiInk.ink_line(self, UiInk.rect_pts(b), true, ink, 1.0, 11, 0.35)
	UiInk.text(self, italic, Vector2(b.position.x, b.position.y + b.size.y * 0.5 + detail * 0.34), group_label(), detail, ink,
		HORIZONTAL_ALIGNMENT_CENTER, b.size.x - 12.0)
	# Two small chevrons at the right: it cycles.
	var cx := b.end.x - 9.0
	var cy := b.position.y + b.size.y * 0.5
	draw_polyline(PackedVector2Array([Vector2(cx - 3.0, cy - 1.5), Vector2(cx, cy - 4.5), Vector2(cx + 3.0, cy - 1.5)]), ink, 1.0, true)
	draw_polyline(PackedVector2Array([Vector2(cx - 3.0, cy + 1.5), Vector2(cx, cy + 4.5), Vector2(cx + 3.0, cy + 1.5)]), ink, 1.0, true)

func _draw_heading(e: Dictionary, soft: Color, faint: Color, italic: Font) -> void:
	var st := style
	var pad: float = st.num("card.pad_px")
	var y: float = float(e["y"])
	var txt := "%s (%d)" % [st.text("roster.group.heading." + str(e["group"])), int(e["count"])]
	var px: float = st.num("fonts.small_px")
	var base := y + st.num("roster.group.heading_px") - 5.0
	UiInk.text(self, italic, Vector2(pad, base), txt, px, soft)
	var x0 := pad + UiInk.text_width(italic, txt, px) + 8.0
	draw_line(Vector2(x0, base - 3.0), Vector2(size.x - pad, base - 3.0), faint, 0.6, true)

func _draw_row(i: int, row: Dictionary, ink_c: Color, soft_c: Color, faint: Color, serif: Font, italic: Font) -> void:
	var st := style
	var rr := row_rect(i)
	var sel := bool(row["selected"])
	var down := bool(row["down"])
	# A down unit's row: every ink in it is the grey one.
	var ink := st.color("row_down") if down else ink_c
	var soft := st.color("row_down") if down else soft_c
	if sel:
		draw_rect(rr.grow(-2.0), st.color("row_selected"), true)
		UiInk.brackets(self, rr.grow(-2.0), st.num("roster.bracket_px"), ink_c, 1.1)
	var mark_r: float = st.num("roster.mark_r_px")
	var mx := rr.position.x + 10.0 + mark_r
	var my := rr.position.y + rr.size.y * 0.5
	var accent := st.side_color(row["side"])
	if down:
		accent = Color(accent.r, accent.g, accent.b, accent.a * 0.4)
	UiInk.roundel(self, Vector2(mx, my), mark_r, accent, st.color("card_fill"), ink)
	var tx := mx + mark_r + 10.0
	var right := rr.end.x - 10.0
	var y1 := rr.position.y + 20.0
	var y2 := rr.position.y + 37.0
	var y3 := rr.position.y + 54.0
	# Line 1: the name, and the health pips at the right.
	var pips_left := UiHealth.draw_pips(self, st, right, y1 - 5.0, int(row["health_max"]), int(row["health"]),
		st.color("row_down") if down else st.color("health_pip"), st.color("row_down") if down else st.color("health_pip_empty"))
	var name_w := pips_left - st.num("roster.name_clip_gap_px") - tx
	var name_txt := str(row["name"])
	UiInk.text(self, serif, Vector2(tx, y1), name_txt, st.num("fonts.name_px"), ink, HORIZONTAL_ALIGNMENT_LEFT, name_w)
	if down:
		var nw := minf(UiInk.text_width(serif, name_txt, st.num("fonts.name_px")), name_w)
		draw_line(Vector2(tx, y1 - 5.0), Vector2(tx + nw, y1 - 5.0), ink, 1.0, true)
	# Line 2: type, speed, band (a down unit: the type only).
	var detail := "%s · %d %s · %s" % [row["type"], roundi(float(row["speed"])), st.text("roster.speed_unit"), row["band"]]
	if down:
		detail = str(row["type"])
	UiInk.text(self, italic, Vector2(tx, y2), detail, st.num("fonts.detail_px"), soft, HORIZONTAL_ALIGNMENT_LEFT, right - tx)
	# Line 3: the plan status; a down unit has the word instead and no step pips.
	var detail_px: float = st.num("fonts.detail_px")
	if down or str(row["status"]) == "flying":
		UiInk.text(self, italic, Vector2(tx, y3), status_text(row), detail_px, ink if down else soft)
	else:
		var has_plan := bool(row["has_plan"])
		var gl: float = st.num("roster.plan_glyph_px")
		var a := Vector2(tx, y3 - 4.0)
		var b := Vector2(tx + gl, y3 - 4.0)
		var dot: float = st.num("roster.plan_glyph_dot_px")
		if has_plan:
			draw_line(a, b, ink, 1.5, true)
			draw_circle(b, dot, ink, true, -1.0, true)
		else:
			UiInk.dashed(self, PackedVector2Array([a, b - Vector2(dot, 0.0)]), soft, 1.0, 3.0, 3.0)
			draw_circle(b, dot, soft, false, 1.0, true)
		# Step pips: one per step this turn, filled for each planned step.
		var pr: float = st.num("roster.pip_r_px")
		var gap: float = st.num("roster.pip_gap_px")
		var steps := int(row["steps"])
		var planned := int(row["planned"])
		var x0 := right - gap * float(steps - 1) - pr
		for k in steps:
			var c := Vector2(x0 + gap * float(k), y3 - 4.0)
			if k < planned:
				draw_circle(c, pr, ink, true, -1.0, true)
			else:
				draw_circle(c, pr, st.color("pip_empty"), false, 1.0, true)
		UiInk.text(self, italic, Vector2(tx + gl + dot + 6.0, y3), status_text(row), detail_px, ink if has_plan else soft,
			HORIZONTAL_ALIGNMENT_LEFT, x0 - pr - 6.0 - (tx + gl + dot + 6.0))
	if i < _row_sep.size() and _row_sep[i] and not sel:
		var y := rr.end.y
		draw_line(Vector2(tx, y), Vector2(rr.end.x - 8.0, y), faint, 0.6, true)
