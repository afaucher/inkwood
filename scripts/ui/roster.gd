extends Control

# The roster sidebar (exit criterion 6; design doc, Unit roster sidebar: "a
# sidebar on the right summarizes every unit the players control"). A floating
# card in the map's ink, one row per player-controlled unit:
#
#   (side roundel)  NAME                         o o o . .   <- plan pips:
#                   Type · 100 m/s · medium                     steps planned
#                                                               of steps per turn
#
# Click a row to select its unit; the selection is the shared UiSelection, so
# the marker's ring and the motion planner follow, and a marker clicked on the
# map selects its row here.
#
# Units belong to nobody (design doc, Co-op and turns): every player-controlled
# unit is listed for every player. SORTING AND GROUPING come later (Alex): the
# rows come from ordered_ids(), the one place a sort or a grouping goes in.
#
# Mount: a Control anywhere in the HUD (UnitUI anchors it to the right edge);
# setup(world, selection). Thin input: rows(), row_at(point), select_row(i).

signal unit_selected(unit_id: String)

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

var world: World = null
var selection: RefCounted = null
# The marker layer, when there is one: while it plays a resolve back, rows show
# each unit's speed and band at the playback time, not the turn's end.
var playback: Object = null
var style: UiStyle = null

func setup(w: World, sel: RefCounted, st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	world = w
	selection = sel
	mouse_filter = Control.MOUSE_FILTER_STOP
	if not selection.changed.is_connected(_on_changed_id):
		selection.changed.connect(_on_changed_id)
		world.plan_changed.connect(_on_changed_id)
		world.phase_changed.connect(_on_changed_id)
		world.turn_resolved.connect(func(_t: int, _h: Dictionary, _e: Array) -> void: queue_redraw())
	custom_minimum_size = Vector2(style.num("roster.width_px"), preferred_height())
	size = custom_minimum_size
	queue_redraw()

# --- Rows ------------------------------------------------------------------------------

# The units the roster lists, in order. THE seam for sorting and grouping.
func ordered_ids() -> Array[String]:
	var out: Array[String] = []
	if world == null:
		return out
	for id: String in world.units:
		if world.units[id].controller == World.CONTROLLER_PLAYER:
			out.append(id)
	return out

# What each row shows, as data (the test reads this): id, name, type, speed
# (m/s), band, planned, steps, side, selected.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var playing := playback != null and bool(playback.is_playing())
	for id: String in ordered_ids():
		var u = world.units[id]
		var pose: Dictionary = playback.pose_of(id) if playing else u.state()
		var plan: Array = u.plan
		var planned := 0
		for r: Dictionary in plan:
			if not r.is_empty():
				planned += 1
		out.append({
			"id": id,
			"name": display_name(id),
			"type": u.def.name,
			"speed": float(pose["speed"]),
			"band": str(pose["altitude_band"]),
			"planned": planned,
			"steps": int(u.def.actions_per_turn),
			"side": str(u.side),
			"selected": selection != null and selection.unit_id == id,
		})
	return out

# A unit's name on the roster (proposed): its id, made readable -- "p1" -> "P1",
# "light_fighter_2" -> "Light fighter 2". Callsigns are a later decision.
static func display_name(id: String) -> String:
	var s := id.replace("_", " ").strip_edges()
	if s.length() <= 3:
		return s.to_upper()
	return s.substr(0, 1).to_upper() + s.substr(1)

func preferred_height() -> float:
	return style.num("roster.header_px") + style.num("roster.row_px") * maxf(1.0, float(ordered_ids().size())) \
		+ style.num("card.pad_px")

func row_rect(i: int) -> Rect2:
	var pad: float = style.num("card.pad_px") * 0.5
	var top: float = style.num("roster.header_px")
	var h: float = style.num("roster.row_px")
	return Rect2(Vector2(pad, top + h * float(i)), Vector2(size.x - 2.0 * pad, h))

# The row index under a point in this control's space, or -1.
func row_at(point: Vector2) -> int:
	var n := ordered_ids().size()
	for i in n:
		if row_rect(i).has_point(point):
			return i
	return -1

func select_row(i: int) -> void:
	var ids := ordered_ids()
	if i < 0 or i >= ids.size():
		return
	selection.select(ids[i])
	unit_selected.emit(ids[i])

func selected_index() -> int:
	return ordered_ids().find(selection.unit_id) if selection != null else -1

# Where the selected row's leader line lands, in this control's parent space
# (the left edge of the row, at its middle).
func row_anchor(id: String) -> Vector2:
	var i := ordered_ids().find(id)
	if i < 0:
		return Vector2.INF
	var r := row_rect(i)
	return position + Vector2(r.position.x, r.get_center().y)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var i := row_at(mb.position)
			if i >= 0:
				select_row(i)
				accept_event()

func _process(_delta: float) -> void:
	if playback != null and bool(playback.is_playing()):
		queue_redraw()
	# Units added after setup (a host spawning mid-game) grow the card.
	if world != null and absf(preferred_height() - custom_minimum_size.y) > 0.5:
		_on_changed_id()

func _on_changed_id(_x: Variant = null) -> void:
	var h := preferred_height()
	if absf(h - custom_minimum_size.y) > 0.5:
		custom_minimum_size = Vector2(custom_minimum_size.x, h)
		size = custom_minimum_size
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
	# Header: the roster's title and the turn.
	UiInk.text(self, serif, Vector2(pad, 26.0), "R O S T E R", title_px, ink)
	var phase_txt := "Turn %d · %s" % [world.turn, world.phase]
	if playback != null and bool(playback.is_playing()):
		phase_txt = "Turn %d · playing" % world.turn
	UiInk.text(self, italic, Vector2(0.0, 26.0), phase_txt, st.num("fonts.detail_px"), soft,
		HORIZONTAL_ALIGNMENT_RIGHT, size.x - pad)
	UiInk.ink_line(self, PackedVector2Array([Vector2(pad, 34.0), Vector2(size.x - pad, 34.0)]), false, faint, 0.8, 3, 0.4)
	var list := rows()
	for i in list.size():
		_draw_row(i, list[i], ink, soft, faint, serif, italic)

func _draw_row(i: int, row: Dictionary, ink: Color, soft: Color, faint: Color, serif: Font, italic: Font) -> void:
	var st := style
	var rr := row_rect(i)
	var sel := bool(row["selected"])
	if sel:
		draw_rect(rr.grow(-2.0), st.color("row_selected"), true)
		UiInk.brackets(self, rr.grow(-2.0), st.num("roster.bracket_px"), ink, 1.1)
	var mark_r: float = st.num("roster.mark_r_px")
	var mx := rr.position.x + 10.0 + mark_r
	var my := rr.position.y + rr.size.y * 0.5
	UiInk.roundel(self, Vector2(mx, my), mark_r, st.side_color(row["side"]), st.color("card_fill"), ink)
	var tx := mx + mark_r + 10.0
	UiInk.text(self, serif, Vector2(tx, rr.position.y + 21.0), str(row["name"]), st.num("fonts.name_px"), ink)
	var detail := "%s · %d %s · %s" % [row["type"], roundi(float(row["speed"])), st.text("roster.speed_unit"), row["band"]]
	UiInk.text(self, italic, Vector2(tx, rr.position.y + 38.0), detail, st.num("fonts.detail_px"), soft)
	# Plan status: one pip per step this turn, filled for each planned step.
	var pr: float = st.num("roster.pip_r_px")
	var gap: float = st.num("roster.pip_gap_px")
	var steps := int(row["steps"])
	var planned := int(row["planned"])
	var x0 := rr.end.x - 10.0 - gap * float(steps - 1) - pr
	for k in steps:
		var c := Vector2(x0 + gap * float(k), rr.position.y + 16.0)
		if k < planned:
			draw_circle(c, pr, ink, true, -1.0, true)
		else:
			draw_circle(c, pr, st.color("pip_empty"), false, 1.0, true)
	UiInk.text(self, italic, Vector2(0.0, rr.position.y + 38.0), "%d/%d" % [planned, steps], st.num("fonts.small_px"),
		soft, HORIZONTAL_ALIGNMENT_RIGHT, rr.end.x - 10.0)
	if i < ordered_ids().size() - 1 and not sel:
		var y := rr.end.y
		draw_line(Vector2(tx, y), Vector2(rr.end.x - 8.0, y), faint, 0.6, true)
