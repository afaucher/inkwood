extends Control

# The orders card: the motion planner's controls, under the roster. For the
# selected unit -- which step the next click places, the altitude of the step
# just placed (dive / level / climb), undo the last step, clear the plan -- and
# for the turn, Ready (World.commit for the local player; pressed again it
# withdraws) with every participant's ready mark (design doc, UI and HUD: "a
# marker per active player in the persistent HUD showing who has committed").
#
# THE DROP CONTROL (Track U3, the strike): a fourth button beside Dive / Level / Climb. Alex:
# bombing is "per step, just like diving", so it acts on the same step they do (the SELECTED step:
# planner.focus_step(), named in the card's header). On (a toggle: the pressed state is the
# button's ink fill), that step carries a bomb drop and the map shows the drop pinned to the step;
# off, none. Disabled for a unit with no bombs, with no drops left to plan, with no step placed,
# with no target or one outside the step's cone -- and the lines under the first row say so in plain
# words (Track B, 2026-10-10): the TARGET line, always while the unit carries a special ("target:
# radio tower" / "no target: click an enemy or right-click the map"), and under it the STATE of the
# step's special. The button wears the special's own words from the unit's data ("Bomb Drop": Alex,
# "the name of the special and the action") and, with the pointer over it, the map shows the
# selected step's bomb cone as a thin outline (hover_changed -> planner.set_drop_hover): hovering
# the OFF button says where the target has to be. ui.json bombs.text, orders.text.
#
# Buttons are drawn in ink, not Godot Buttons, so they sit in the card's style;
# input is thin: buttons() lays them out, press_button(name) acts, and
# _gui_input only finds the button under the pointer.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")

# The button under the pointer changed ("" none): UnitUI points the special's hover at the planner (set_drop_hover).
signal hover_changed(button: String)

var world: World = null
var planner: MotionPlanner = null
var selection: RefCounted = null
var style: UiStyle = null
var local_player: String = "local"
# The marker layer, when there is one (see roster.gd): the card shows the playback.
var playback: Object = null
# What Ready does. UnitUI points it at its own press_ready (commit, then resolve
# when everyone is in); alone, the panel commits through the planner.
var ready_action: Callable = Callable()
# Player id -> the name to print (UnitUI.player_name, which Track A points at WorldSync.name_of):
# the ready marks print it for every player but this one ("you") and the AI. Empty: the id.
var player_name: Callable = Callable()
# Every button is off (the end-of-mission card is up: planning input is locked).
var locked: bool = false
var _hover_button: String = ""
var _strip_sig: String = ""

func setup(w: World, motion_planner: MotionPlanner, sel: RefCounted, player: String = "local", st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	world = w
	planner = motion_planner
	selection = sel
	local_player = player
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(style.num("roster.width_px"), style.num("orders.height_px"))
	size = custom_minimum_size
	if not world.plan_changed.is_connected(_redraw):
		world.plan_changed.connect(_redraw)
		planner.ready_refused.connect(_redraw)
		world.phase_changed.connect(_redraw)
		world.ready_changed.connect(func(_p: String, _r: bool) -> void: queue_redraw())
		selection.changed.connect(_redraw)
		planner.target.changed.connect(_redraw)   # (Track T: the card's line names the target's state)
	queue_redraw()

func _process(_delta: float) -> void:
	if playback != null and bool(playback.is_playing()):
		queue_redraw()
	# The selected step moves when a node is clicked on the map (the planner's own state): the strip follows it.
	var sig := "%s|%d|%d" % [selection.unit_id if selection != null else "", planner.focus_step() if planner != null else -2, planner.planned_count() if planner != null else -2]
	if sig != _strip_sig:
		_strip_sig = sig
		queue_redraw()

func _redraw(_x: Variant = null) -> void:
	queue_redraw()

# --- Layout and actions --------------------------------------------------------------

# name -> {rect, label, enabled, on}
func buttons() -> Dictionary:
	var st := style
	var pad: float = st.num("card.pad_px")
	var bh: float = st.num("orders.button_h_px")
	var gap: float = st.num("orders.row_gap_px")
	var w := size.x - 2.0 * pad
	var out := {}
	var id: String = selection.unit_id if selection != null else ""
	var can: bool = planner != null and planner.can_plan(id)
	var placed: int = planner.planned_count(id) if planner != null else 0
	var opts: Dictionary = planner.band_options() if can else {-1: false, 0: false, 1: false}
	var y := 104.0
	var dw: float = st.num("orders.drop_w_px")   # the special's button is wider: it wears the special's words ("Bomb Drop")
	var bw := (w - dw - 3.0 * gap) / 3.0
	var cur := _last_step_band_delta()
	var has_sel: bool = can and planner.focus_step(id) >= 0   # (placing the next step: no placed step is selected, no band button is pressed)
	var dopt: Dictionary = planner.drop_options() if can else {"available": false, "on": false}
	var drop_label: String = planner.special_label(id) if planner != null else st.text("bombs.text.label")
	out["dive"] = {"rect": Rect2(pad, y, bw, bh), "label": "Dive", "enabled": bool(opts[-1]), "on": has_sel and cur < 0}
	out["level"] = {"rect": Rect2(pad + bw + gap, y, bw, bh), "label": "Level", "enabled": bool(opts[0]), "on": has_sel and cur == 0}
	out["climb"] = {"rect": Rect2(pad + 2.0 * (bw + gap), y, bw, bh), "label": "Climb", "enabled": bool(opts[1]), "on": has_sel and cur > 0}
	out["drop"] = {"rect": Rect2(pad + 3.0 * (bw + gap), y, dw, bh), "label": drop_label, "enabled": can and bool(dopt["available"]), "on": can and bool(dopt["on"])}
	y += bh + gap + st.num("orders.drop_line_px")
	var hw := (w - gap) / 2.0
	out["undo"] = {"rect": Rect2(pad, y, hw, bh), "label": "Undo step", "enabled": can and placed > 0, "on": false}
	out["clear"] = {"rect": Rect2(pad + hw + gap, y, hw, bh), "label": "Clear plan", "enabled": can and placed > 0, "on": false}
	y += bh + gap + 4.0
	var is_ready: bool = world != null and world.is_ready(local_player)
	var planning: bool = world != null and world.phase == World.PHASE_PLANNING
	out["ready"] = {"rect": Rect2(pad, y, w, st.num("orders.ready_h_px")),
		"label": ("Ready  -  press to withdraw" if planning else "Ready") if is_ready else "Ready",
		"enabled": planning, "on": is_ready and planning}
	if locked:
		for key: String in out:
			out[key]["enabled"] = false
	return out

# The band change the last placed step makes: -1 dive, 0 level, +1 climb.
func _last_step_band_delta() -> int:
	if planner == null or selection == null or selection.unit_id == "":
		return 0
	var k: int = planner.focus_step()
	if k < 0:
		return 0
	var u = world.units[selection.unit_id]
	var bands: Array[String] = u.def.envelope.bands
	var st: Array = planner.states()
	var now := bands.find(str(st[k]["altitude_band"]))
	var before := bands.find(planner.band_before(k))
	return signi(now - before)

func button_at(point: Vector2) -> String:
	var b := buttons()
	for name: String in b:
		if (b[name]["rect"] as Rect2).has_point(point):
			return name
	for m: Dictionary in step_marks():
		if (m["rect"] as Rect2).has_point(point):
			return "step_%d" % int(m["index"])
	return ""

# Act as if `name` were clicked ("step_<i>" is a mark of the step strip, i from 0). Returns whether it did anything.
func press_button(name: String) -> bool:
	if name.begins_with("step_"):
		return press_step(int(name.substr(5)))
	var b := buttons()
	if not b.has(name) or not bool(b[name]["enabled"]):
		return false
	match name:
		"dive":
			planner.change_band(-1)
		"level":
			planner.change_band(0)
		"climb":
			planner.change_band(1)
		"drop":
			planner.toggle_drop()
		"undo":
			planner.undo()
		"clear":
			planner.clear()
		"ready":
			if ready_action.is_valid():
				ready_action.call()
			elif world.is_ready(local_player):
				world.withdraw(local_player)
			else:
				planner.ready_up()
	queue_redraw()
	return true

# The button under the pointer ("" none): the hover that lets the map outline the special's cone.
func hover_button() -> String:
	return _hover_button

func set_hover_button(button: String) -> void:
	if locked:
		button = ""
	if button == _hover_button:
		return
	_hover_button = button
	hover_changed.emit(button)
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		set_hover_button("")

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		set_hover_button(button_at((event as InputEventMouseMotion).position))
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var name := button_at(mb.position)
			if name != "":
				press_button(name)
				accept_event()

# --- The step strip (Track B, 2026-10-10; Alex: "a clickable indicator for the steps that let you select the step from there and
# also see which steps are planned. You can only click an already planned step or the next unplanned.") -----------------------------

# One record per step of the selected unit's turn (World.steps_per_turn), in order: {index, state ("planned" | "next" | "later"),
# selected (the step the card is about; with no placed step selected, the next one), special (a planned step with its special on),
# enabled (a planned step and the next one; not while the card is locked), center, rect (screen px, in this card's space)}.
# NOTHING for a unit whose plan may not be shown (an enemy's, a down unit's, outside the planning phase).
func step_marks() -> Array:
	var out: Array = []
	var id: String = selection.unit_id if selection != null else ""
	if planner == null or id == "" or not world.units.has(id) or not planner.plan_shown(id):
		return out
	var total: int = world.steps_per_turn(id)
	var placed: int = planner.planned_count(id)
	var cur: int = planner.focus_step(id)
	if cur < 0:
		cur = placed if placed < total else -1
	var r: float = style.num("orders.strip.r_px")
	var gap: float = style.num("orders.strip.select_gap_px")
	var pad: float = style.num("card.pad_px")
	var pitch: float = style.num("orders.strip.step_px")
	var cy: float = style.num("orders.strip.cy_px")
	var x0 := size.x - pad - (float(total - 1) * pitch + 2.0 * (r + gap)) + (r + gap)   # right-aligned on the header row
	for i in total:
		var state := "planned" if i < placed else ("next" if i == placed else "later")
		var c := Vector2(x0 + float(i) * pitch, cy)
		out.append({"index": i, "state": state, "selected": i == cur, "special": state == "planned" and planner.step_has_drop(i, id),
			"enabled": state != "later" and not locked, "center": c, "rect": Rect2(c - Vector2(r + gap, r + gap), Vector2(2.0 * (r + gap), 2.0 * (r + gap)))})
	return out

# A click on step mark `index`: a planned step is selected (as its node on the map is), the next one becomes the step to place (the
# fan places it), a later one is refused. Returns whether anything was done.
func press_step(index: int) -> bool:
	for m: Dictionary in step_marks():
		if int(m["index"]) != index:
			continue
		if not bool(m["enabled"]):
			return false
		if str(m["state"]) == "planned":
			planner.select_step(index)
		else:
			if not planner.select_next_step():
				return false
		queue_redraw()
		return true
	return false

func _draw_strip(ink: Color) -> void:
	var marks := step_marks()
	if marks.is_empty():
		return
	var st := style
	var r: float = st.num("orders.strip.r_px")
	var ring_w: float = st.num("orders.strip.ring_px")
	var line_w: float = st.num("orders.strip.line_px")
	var dash: float = st.num("orders.strip.dash_px")
	var gap: float = st.num("orders.strip.select_gap_px")
	var font: Font = st.label_font()
	var px: int = int(st.num("orders.strip.number_px"))
	var paper: Color = st.color("button_fill")
	var paper_text: Color = st.color("button_on_text")
	var off: Color = st.color("button_off_text")
	var quiet: Color = st.color("text_quiet")
	# The path's own language between the marks: solid up to a planned step, dashed to the ones that carry on.
	for i in marks.size() - 1:
		var a: Vector2 = (marks[i] as Dictionary)["center"]
		var b: Vector2 = (marks[i + 1] as Dictionary)["center"]
		var p0 := a + Vector2(r + gap + 1.0, 0.0)
		var p1 := b - Vector2(r + gap + 1.0, 0.0)
		if str((marks[i + 1] as Dictionary)["state"]) == "planned":
			draw_line(p0, p1, ink, line_w, true)
		else:
			UiInk.dashed(self, PackedVector2Array([p0, p1]), off, line_w, dash, dash)
	for m: Dictionary in marks:
		var c: Vector2 = m["center"]
		var state := str(m["state"])
		var selected := bool(m["selected"])
		var enabled := bool(m["enabled"])
		var hovered: bool = _hover_button == "step_%d" % int(m["index"])
		var ring_col := ink if state != "later" else off
		var disc: Color = ink if selected else paper
		draw_circle(c, r, disc, true, -1.0, true)
		if state == "planned" or selected:
			draw_arc(c, r, 0.0, TAU, 36, ink, ring_w, true)
		else:
			var ring := UiInk.circle_pts(c, r, 36)
			ring.append(ring[0])
			UiInk.dashed(self, ring, ring_col, ring_w, dash, dash)
		if selected:
			# the node's grow and fill: a second ring round the filled disc (dashed while the step is not placed yet)
			if state == "planned":
				draw_arc(c, r + gap, 0.0, TAU, 40, ink, ring_w * 0.9, true)
			else:
				var outer := UiInk.circle_pts(c, r + gap, 40)
				outer.append(outer[0])
				UiInk.dashed(self, outer, ink, ring_w * 0.9, dash, dash)
		elif hovered and enabled:
			draw_arc(c, r + st.num("orders.strip.hover_gap_px"), 0.0, TAU, 40, ink, 0.9, true)
		var txt := str(int(m["index"]) + 1)
		var w := UiInk.text_width(font, txt, px)
		UiInk.text(self, font, c + Vector2(-w * 0.5, float(px) * 0.36), txt, px, paper_text if selected else (ink if state != "later" else quiet),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, "mark_number")
		if bool(m["special"]):
			UiInk.bomb_glyph(self, c + Vector2(r + 1.5, r - 2.5), st.num("orders.strip.bomb_px"), ink, paper, 1.1, 1.4)

# --- Drawing -------------------------------------------------------------------------

func _draw() -> void:
	if world == null:
		return
	var st := style
	var ink: Color = st.color("ink")
	var faint: Color = st.color("ink_faint")
	var r := Rect2(Vector2.ZERO, size)
	UiInk.card_shadow(self, r, st.shadow_dir() * st.num("card.lift_px"), st.color("card_shadow"))
	UiInk.card(self, r, st.color("card_fill"), ink, st.num("card.outer_line_px"), st.num("card.inner_line_px"),
		st.num("card.inner_inset_px"), st.num("card.wobble_px"), 13)
	var serif: Font = st.font(false)
	var italic: Font = st.text_font()   # (Track L: the card's small lines are in the label face, upright and semibold, full ink: no thin italic)
	var pad: float = st.num("card.pad_px")
	var detail: float = st.num("fonts.detail_px")
	UiInk.text(self, serif, Vector2(pad, 26.0), "O R D E R S", st.num("fonts.title_px"), ink)
	var id: String = selection.unit_id if selection != null else ""
	var line1 := "no unit selected"
	var line2 := "pick one on the map or in the roster"
	if id != "" and world.units.has(id):
		var u = world.units[id]
		UiInk.text(self, italic, Vector2(0.0, 26.0), "%s · %s" % [Roster.unit_name(u), u.def.name], detail, ink,
			HORIZONTAL_ALIGNMENT_RIGHT, size.x - pad)
		var n := int(u.def.actions_per_turn)
		var placed: int = planner.planned_count(id)
		if playback != null and bool(playback.is_playing()):
			line1 = "turn %d playing" % world.turn
			line2 = "%.1f of %.0f s; orders open when it ends" % [float(playback.playback_t), world.rules.turn_seconds]
		elif world.phase != World.PHASE_PLANNING:
			line1 = "the turn is %s" % world.phase
			line2 = "orders open when it ends"
		elif bool(u.down):
			line1 = style.text("roster.text.down")
			line2 = "a down unit takes no orders"
		elif world.is_ready(local_player):
			line1 = _selected_line(id, placed, n)
			line2 = "ready: change a plan to take it back"
		elif u.controller != World.CONTROLLER_PLAYER:
			line1 = "not under player orders"
			line2 = ""
		elif placed >= n:
			# Alex (step-selection): "3 of 3 steps planned - I can move them but can I replan them?" -- a full plan says a step can be selected.
			line1 = _selected_line(id, placed, n)
			line2 = st.text("orders.text.hint_full")
		else:
			line1 = _selected_line(id, placed, n)
			line2 = "click or drag inside the fan" if (placed == 0 or planner.focus_step(id) < 0) else st.text("orders.text.hint_more") % (placed + 1)
	UiInk.ink_line(self, PackedVector2Array([Vector2(pad, 34.0), Vector2(size.x - pad, 34.0)]), false, faint, 0.8, 5, 0.4)
	UiInk.text(self, serif, Vector2(pad, 56.0), line1, st.num("fonts.name_px"), ink)
	_draw_strip(ink)
	if planner != null and planner.ready_notice != "" and world.phase == World.PHASE_PLANNING:
		# Ready was refused (a turn that would leave the map): said in full ink, in place of the hint.
		_fit_text(italic, Vector2(pad, 74.0), planner.ready_notice, detail, ink)
	else:
		_fit_text(italic, Vector2(pad, 74.0), line2, detail, ink)
	_fit_text(italic, Vector2(pad, 97.0), _altitude_caption(), detail, ink)
	var b := buttons()
	for name: String in b:
		_draw_button(b[name], name == "ready", serif, name == _hover_button)
	# Under the first row of buttons, for a unit with a special: the TARGET in words (always), then what the special does at the
	# selected step, or why it cannot (plain words). Each shrinks to fit the card.
	var drop_rect: Rect2 = b["drop"]["rect"]
	var line_y: float = drop_rect.end.y + st.num("orders.row_gap_px") + detail * 0.95
	var tcap := target_caption()
	if tcap != "":
		_fit_text(italic, Vector2(pad, line_y), tcap, detail, ink)
		line_y += detail + 4.0
	var cap := bomb_caption()
	if cap != "":
		_fit_text(italic, Vector2(pad, line_y), cap, detail, ink)
	# Ready marks: one per participant.
	var y: float = (b["ready"]["rect"] as Rect2).end.y + 20.0
	var x := pad
	for mark: Dictionary in ready_marks():
		var label: String = mark["label"]
		var ready: bool = mark["ready"]
		var c := Vector2(x + 5.0, y - 4.0)
		draw_circle(c, 5.0, ink, false, 1.0, true)
		if ready:
			draw_polyline(PackedVector2Array([c + Vector2(-3.0, 0.0), c + Vector2(-0.8, 2.6), c + Vector2(3.6, -3.2)]), ink, 1.6, true)
		var txt := "%s %s" % [label, "ready" if ready else "planning"]
		UiInk.text(self, italic, Vector2(x + 14.0, y), txt, detail, ink if ready else st.color("text_quiet"))
		x += 14.0 + UiInk.text_width(italic, txt, detail) + 16.0

# One record per participant, as the ready marks print them: {who, label, ready}. The label is
# "you" for this player, "AI" for the AI, else the player's name (player_name).
func ready_marks() -> Array:
	var out: Array = []
	if world == null:
		return out
	for who: String in world.participants():
		out.append({"who": who, "ready": world.is_ready(who),
			"label": "you" if who == local_player else ("AI" if who == World.AI_PLAYER else _player_label(who))})
	return out

func _player_label(who: String) -> String:
	if player_name.is_valid():
		return str(player_name.call(who))
	return who

func _drop_is_on() -> bool:
	var id: String = selection.unit_id if selection != null else ""
	return planner != null and id != "" and planner.can_plan(id) and bool(planner.drop_options()["on"])

# The header line: the SELECTED step named ("step 2 of 3 selected": Alex, step-selection), or, with nothing placed, the step the
# next click places.
func _selected_line(id: String, placed: int, n: int) -> String:
	var k: int = planner.focus_step(id) if planner != null else -1
	if k < 0:
		return "step %d of %d next" % [placed + 1, n] if placed < n else "%d of %d steps planned" % [placed, n]
	return style.text("orders.text.selected") % [k + 1, n]

# Draws a line of the card's lettering, shrunk (never below lettering.fit_floor_px) until it fits the card's width. A line that had
# to shrink under the size the lettering rule asks for says so in the lettering log (kind "fit"), so a test can list them.
func _fit_text(font: Font, pos: Vector2, s: String, size_px: float, color: Color) -> void:
	var max_w := size.x - 2.0 * style.num("card.pad_px")
	var px := UiInk.fit_px(font, s, size_px, max_w, style.fit_floor_px())
	UiInk.text(self, font, pos, s, px, color, HORIZONTAL_ALIGNMENT_LEFT, max_w, "fit" if px < style.min_px() else "")

# The width the text needs at the size it is drawn (after shrinking), for a test: the line fits when this is <= the card's room.
func fitted_width(font: Font, s: String, size_px: float) -> float:
	var max_w := size.x - 2.0 * style.num("card.pad_px")
	return UiInk.text_width(font, s, UiInk.fit_px(font, s, size_px, max_w, style.fit_floor_px()))

# The size a line of the card is drawn at (after shrinking): `size_px` when it fits, else the largest that does, never under the floor.
func fitted_px(font: Font, s: String, size_px: float) -> float:
	return UiInk.fit_px(font, s, size_px, size.x - 2.0 * style.num("card.pad_px"), style.fit_floor_px())

# THE TARGET LINE (Track B; the lead: "always visible on the card while the selected unit carries a special"): "target: radio
# tower" -- with the special on at the selected step, that step's own target and the drop's accuracy -- or "no target: click an
# enemy or right-click the map". "" for a unit with no special (a fighter) and for no unit.
func target_caption() -> String:
	var id: String = selection.unit_id if selection != null else ""
	if planner == null or id == "" or not world.units.has(id) or planner.bombs == null:
		return ""
	var line: String = planner.target_line()
	if line == "":
		return ""
	var k: int = planner.focus_step(id)
	if k >= 0 and planner.step_has_drop(k, id):
		var info: Dictionary = planner.drop_info(k)
		if not info.is_empty() and not bool(info["blocked"]):
			line += style.text("bombs.text.target_accuracy") % roundi(float(info["quality"]) * 100.0)
	return line

# The line under the target's: for a unit with bombs, what the special does at the SELECTED step (the spread, or the expected
# damage, of the drop planned there; the drops still free) or why it cannot be switched on, in plain words. "" for a unit with
# no bombs (and for no unit).
func bomb_caption() -> String:
	var id: String = selection.unit_id if selection != null else ""
	if planner == null or id == "" or not world.units.has(id) or planner.bombs == null:
		return ""
	if not planner.bombs.has_bombs(id) or not planner.can_plan(id):
		return ""
	var opt: Dictionary = planner.drop_options()
	var k := int(opt["step"])
	var label: String = planner.special_label(id)
	if k < 0:
		return str(opt["why"])
	if bool(opt["on"]):
		var info: Dictionary = planner.drop_info(k)
		if info.is_empty():
			return ""
		# Track T: a drop whose target the step's cone no longer holds says so in the sim's own words for the case
		# (data/sim/bombs.json outside_cone_mode: it will not release, or it is a poor shot).
		if bool(info["blocked"]):
			return style.text("bombs.text.wont_release")
		if bool(info["poor_shot"]):
			return style.text("bombs.text.poor_shot")
		var sp: Dictionary = info["spread"]
		var radius := float(sp["across_m"])   # the drawn ellipse's across radius (2 sigma)
		# The expected damage to the most affected unit in sight, from the sim's own rules (data bombs.aoe.card_line).
		var dmg: Dictionary = planner.expected_damage(k) if style.flag("bombs.aoe.card_line") else {}
		if not dmg.is_empty():
			return style.text("bombs.text.expected_on") % [k + 1, label, str(dmg["name"]), str(roundi(float(dmg["mean"]))), int(dmg["health"])]
		return style.text("bombs.text.on") % [k + 1, label, roundi(radius)]
	if not bool(opt["available"]):
		return str(opt["why"])
	var carried: Dictionary = planner.bombs.bombs_left(id)
	return style.text("bombs.text.free") % [k + 1, label, planner.bombs.drops_free(id, k), int(carried["drops_max"])]

# Whether the state line is a reason the special cannot be switched on (said in full ink: it is what the player has to read).
func _drop_reason_is_plain() -> bool:
	var id: String = selection.unit_id if selection != null else ""
	return planner != null and id != "" and planner.can_plan(id) and not bool(planner.drop_options()["available"])

func _altitude_caption() -> String:
	var id: String = selection.unit_id if selection != null else ""
	if planner == null or id == "" or not planner.can_plan(id):
		return "altitude"
	var k: int = planner.focus_step()
	if k < 0:
		return "altitude: place a step first"
	var st: Array = planner.states()
	return "altitude, step %d:  %s  to  %s" % [k + 1, planner.band_before(k), st[k]["altitude_band"]]

func _draw_button(b: Dictionary, big: bool, font: Font, hovered: bool = false) -> void:
	var st := style
	var r: Rect2 = b["rect"]
	var enabled := bool(b["enabled"])
	var on := bool(b["on"])
	var ink: Color = st.color("ink")
	var fill: Color = st.color("button_on_fill") if on else st.color("button_fill")
	var txt: Color = st.color("button_on_text") if on else (ink if enabled else st.color("text_quiet"))
	draw_rect(r, fill, true)
	var edge := ink if enabled else st.color("button_off_text")
	UiInk.ink_line(self, UiInk.rect_pts(r), true, edge, 1.5 if big else 1.0, int(r.position.x + r.position.y), 0.35)
	if on and not big:
		# Pressed in: a paper rule inside the ink fill (a toggle that is ON reads as pressed, not just dark).
		var inner := r.grow(-2.5)
		UiInk.ink_line(self, UiInk.rect_pts(inner), true, st.color("button_on_text"), 0.9, int(r.position.x * 3.0 + r.position.y), 0.2)
	if hovered and not locked:
		# The pointer is on it: a second rule round the button (enabled or not: the special's hover outlines its cone on the map).
		UiInk.ink_line(self, UiInk.rect_pts(r.grow(2.5)), true, ink if enabled else st.color("ink_soft"), 0.9, int(r.position.y * 3.0 + r.position.x), 0.2)
	var size_px: float = st.num("fonts.name_px") if big else st.num("fonts.button_px")
	var base := r.position.y + r.size.y * 0.5 + size_px * 0.34
	UiInk.text(self, font, Vector2(r.position.x, base), str(b["label"]), size_px, txt, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
