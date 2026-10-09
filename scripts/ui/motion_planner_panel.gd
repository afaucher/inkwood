extends Control

# The orders card: the motion planner's controls, under the roster. For the
# selected unit -- which step the next click places, the altitude of the step
# just placed (dive / level / climb), undo the last step, clear the plan -- and
# for the turn, Ready (World.commit for the local player; pressed again it
# withdraws) with every participant's ready mark (design doc, UI and HUD: "a
# marker per active player in the persistent HUD showing who has committed").
#
# Buttons are drawn in ink, not Godot Buttons, so they sit in the card's style;
# input is thin: buttons() lays them out, press_button(name) acts, and
# _gui_input only finds the button under the pointer.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")

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
		world.phase_changed.connect(_redraw)
		world.ready_changed.connect(func(_p: String, _r: bool) -> void: queue_redraw())
		selection.changed.connect(_redraw)
	queue_redraw()

func _process(_delta: float) -> void:
	if playback != null and bool(playback.is_playing()):
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
	var bw := (w - 2.0 * gap) / 3.0
	var cur := _last_step_band_delta()
	out["dive"] = {"rect": Rect2(pad, y, bw, bh), "label": "Dive", "enabled": bool(opts[-1]), "on": can and placed > 0 and cur < 0}
	out["level"] = {"rect": Rect2(pad + bw + gap, y, bw, bh), "label": "Level", "enabled": bool(opts[0]), "on": can and placed > 0 and cur == 0}
	out["climb"] = {"rect": Rect2(pad + 2.0 * (bw + gap), y, bw, bh), "label": "Climb", "enabled": bool(opts[1]), "on": can and placed > 0 and cur > 0}
	y += bh + gap
	var hw := (w - gap) / 2.0
	out["undo"] = {"rect": Rect2(pad, y, hw, bh), "label": "Undo step", "enabled": can and placed > 0, "on": false}
	out["clear"] = {"rect": Rect2(pad + hw + gap, y, hw, bh), "label": "Clear plan", "enabled": can and placed > 0, "on": false}
	y += bh + gap + 4.0
	var is_ready: bool = world != null and world.is_ready(local_player)
	var planning: bool = world != null and world.phase == World.PHASE_PLANNING
	out["ready"] = {"rect": Rect2(pad, y, w, st.num("orders.ready_h_px")),
		"label": ("Ready  -  press to withdraw" if planning else "Ready") if is_ready else "Ready",
		"enabled": planning, "on": is_ready and planning}
	return out

# The band change the last placed step makes: -1 dive, 0 level, +1 climb.
func _last_step_band_delta() -> int:
	if planner == null or selection == null or selection.unit_id == "":
		return 0
	var k: int = planner.planned_count() - 1
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
	return ""

# Act as if `name` were clicked. Returns whether it did anything.
func press_button(name: String) -> bool:
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

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var name := button_at(mb.position)
			if name != "":
				press_button(name)
				accept_event()

# --- Drawing -------------------------------------------------------------------------

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
		st.num("card.inner_inset_px"), st.num("card.wobble_px"), 13)
	var serif: Font = st.font(false)
	var italic: Font = st.font(true)
	var pad: float = st.num("card.pad_px")
	var detail: float = st.num("fonts.detail_px")
	UiInk.text(self, serif, Vector2(pad, 26.0), "O R D E R S", st.num("fonts.title_px"), ink)
	var id: String = selection.unit_id if selection != null else ""
	var line1 := "no unit selected"
	var line2 := "pick one on the map or in the roster"
	if id != "" and world.units.has(id):
		var u = world.units[id]
		UiInk.text(self, italic, Vector2(0.0, 26.0), "%s · %s" % [Roster.unit_name(u), u.def.name], detail, soft,
			HORIZONTAL_ALIGNMENT_RIGHT, size.x - pad)
		var n := int(u.def.actions_per_turn)
		var placed: int = planner.planned_count(id)
		if playback != null and bool(playback.is_playing()):
			line1 = "turn %d playing" % world.turn
			line2 = "%.1f of %.0f s; orders open when it ends" % [float(playback.playback_t), world.rules.turn_seconds]
		elif world.phase != World.PHASE_PLANNING:
			line1 = "the turn is %s" % world.phase
			line2 = "orders open when it ends"
		elif world.is_ready(local_player):
			line1 = "%d of %d steps planned" % [placed, n]
			line2 = "ready: change a plan to take it back"
		elif u.controller != World.CONTROLLER_PLAYER:
			line1 = "not under player orders"
			line2 = ""
		elif placed >= n:
			line1 = "%d of %d steps planned" % [placed, n]
			line2 = "plan full: drag a step's end to change it"
		else:
			line1 = "step %d of %d next" % [placed + 1, n]
			line2 = "click or drag inside the fan" if placed == 0 else "%d planned; the rest carry on" % placed
	UiInk.ink_line(self, PackedVector2Array([Vector2(pad, 34.0), Vector2(size.x - pad, 34.0)]), false, faint, 0.8, 5, 0.4)
	UiInk.text(self, serif, Vector2(pad, 56.0), line1, st.num("fonts.name_px"), ink)
	UiInk.text(self, italic, Vector2(pad, 74.0), line2, detail, soft)
	UiInk.text(self, italic, Vector2(pad, 97.0), _altitude_caption(), detail, soft)
	var b := buttons()
	for name: String in b:
		_draw_button(b[name], name == "ready", serif)
	# Ready marks: one per participant.
	var y: float = (b["ready"]["rect"] as Rect2).end.y + 20.0
	var x := pad
	for who: String in world.participants():
		var label := "you" if who == local_player else ("AI" if who == World.AI_PLAYER else who)
		var ready := world.is_ready(who)
		var c := Vector2(x + 5.0, y - 4.0)
		draw_circle(c, 5.0, ink, false, 1.0, true)
		if ready:
			draw_polyline(PackedVector2Array([c + Vector2(-3.0, 0.0), c + Vector2(-0.8, 2.6), c + Vector2(3.6, -3.2)]), ink, 1.6, true)
		var txt := "%s %s" % [label, "ready" if ready else "planning"]
		UiInk.text(self, italic, Vector2(x + 14.0, y), txt, detail, ink if ready else soft)
		x += 14.0 + UiInk.text_width(italic, txt, detail) + 16.0

func _altitude_caption() -> String:
	var id: String = selection.unit_id if selection != null else ""
	if planner == null or id == "" or not planner.can_plan(id):
		return "altitude"
	var k: int = planner.planned_count() - 1
	if k < 0:
		return "altitude: place a step first"
	var st: Array = planner.states()
	return "altitude, step %d:  %s  to  %s" % [k + 1, planner.band_before(k), st[k]["altitude_band"]]

func _draw_button(b: Dictionary, big: bool, font: Font) -> void:
	var st := style
	var r: Rect2 = b["rect"]
	var enabled := bool(b["enabled"])
	var on := bool(b["on"])
	var ink: Color = st.color("ink")
	var fill: Color = st.color("button_on_fill") if on else st.color("button_fill")
	var txt: Color = st.color("button_on_text") if on else (ink if enabled else st.color("button_off_text"))
	draw_rect(r, fill, true)
	var edge := ink if enabled else st.color("button_off_text")
	UiInk.ink_line(self, UiInk.rect_pts(r), true, edge, 1.5 if big else 1.0, int(r.position.x + r.position.y), 0.35)
	var size_px: float = st.num("fonts.name_px") if big else st.num("fonts.button_px")
	var base := r.position.y + r.size.y * 0.5 + size_px * 0.34
	UiInk.text(self, font, Vector2(r.position.x, base), str(b["label"]), size_px, txt, HORIZONTAL_ALIGNMENT_CENTER, r.size.x)
