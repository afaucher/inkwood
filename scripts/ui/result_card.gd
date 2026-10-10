extends Control

# THE END-OF-MISSION CARD (Track U2, the first fight, part 2). A veil over the map and
# the sidebar and, on it, a card in the UI's style: the verdict ("V I C T O R Y" /
# "D E F E A T"), the reason in plain words, the turn it was settled on, and two buttons:
# Play again and Back to the menu. UnitUI.show_result(result) shows it with
# Mission.evaluate()'s shape, {state: "won" | "lost", reason, turn, t}; its buttons emit
# play_again and menu, which UnitUI re-emits as result_play_again / result_menu for the
# host (Track A) to wire. While it shows, planning input is locked (UnitUI.input_locked()).
#
# THE WORDS are data (ui.json combat.result): the verdict, and `reasons`, patterns that turn
# the mission's own reason string ("bomber is down", "bomber came within 150 m of the
# target", "all player units are down") into the card's words ("bomber down", "the bomber
# reached its target", "both fighters down"). Nothing matching shows the mission's own words.
#
# Buttons are drawn in ink like the orders card's; input is thin: buttons() lays them
# out, press_button(name) acts, _gui_input finds the button under the pointer.

signal play_again
signal menu

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

var style: UiStyle = null
var world: Object = null
var result: Dictionary = {}

func setup(st: RefCounted, w: Object = null) -> void:
	style = st as UiStyle
	world = w
	name = "ResultCard"
	mouse_filter = Control.MOUSE_FILTER_STOP   # a veil: nothing under it is clicked
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false

func show_result(r: Dictionary) -> void:
	result = r.duplicate(true)
	visible = true
	queue_redraw()

func hide_result() -> void:
	visible = false
	result = {}

func is_showing() -> bool:
	return visible and not result.is_empty()

# --- The words ---------------------------------------------------------------------------------

func won() -> bool:
	return str(result.get("state", "")) == "won"

func title_text() -> String:
	return style.text("combat.result.text.won_title" if won() else "combat.result.text.lost_title")

func sub_text() -> String:
	return style.text("combat.result.text.won_sub" if won() else "combat.result.text.lost_sub")

func turn_text() -> String:
	var turn_no := int(result.get("turn", 0))
	return style.text("combat.result.text.turn") % turn_no if turn_no > 0 else ""

func reason_text() -> String:
	return reason_words(style, world, str(result.get("reason", "")))

# The mission's reason string in the card's words: the first pattern of combat.result.reasons that
# matches; %s in its text is the display name of the unit the pattern captured, lower case.
static func reason_words(st: UiStyle, w: Object, reason: String) -> String:
	var list: Variant = st.lookup("combat.result.reasons")
	if list is Array:
		for entry: Variant in (list as Array):
			if not (entry is Dictionary):
				continue
			var re := RegEx.new()
			if re.compile(str((entry as Dictionary).get("pattern", ""))) != OK:
				continue
			var m := re.search(reason)
			if m == null:
				continue
			var text := str((entry as Dictionary).get("text", ""))
			if text.contains("%s"):
				var cap := m.get_string(1) if re.get_group_count() >= 1 else ""
				text = text % _display_name(w, cap)
			return text
	return reason

static func _display_name(w: Object, id: String) -> String:
	if w != null and w.units.has(id):
		return str(w.units[id].def.name).to_lower()
	return id

# --- Layout and actions --------------------------------------------------------------------------

func card_rect() -> Rect2:
	var cw: float = style.num("combat.result.width_px")
	var ch: float = style.num("combat.result.height_px")
	return Rect2((size - Vector2(cw, ch)) * 0.5, Vector2(cw, ch)).abs()

# name -> {rect (in this control's space), label, enabled, on}
func buttons() -> Dictionary:
	var r := card_rect()
	var pad: float = style.num("card.pad_px") + 8.0
	var gap: float = style.num("orders.row_gap_px")
	var bh: float = style.num("combat.result.button_h_px")
	var w := (r.size.x - 2.0 * pad - gap) * 0.5
	var y := r.end.y - pad - bh
	return {
		"again": {"rect": Rect2(r.position.x + pad, y, w, bh), "label": style.text("combat.result.text.again"), "enabled": true, "on": true},
		"menu": {"rect": Rect2(r.position.x + pad + w + gap, y, w, bh), "label": style.text("combat.result.text.menu"), "enabled": true, "on": false},
	}

func button_at(point: Vector2) -> String:
	var b := buttons()
	for key: String in b:
		if (b[key]["rect"] as Rect2).has_point(point):
			return key
	return ""

# Act as if `key` ("again" / "menu") were clicked. Returns whether it did anything.
func press_button(key: String) -> bool:
	if not is_showing():
		return false
	match key:
		"again":
			play_again.emit()
			return true
		"menu":
			menu.emit()
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var key := button_at(mb.position)
			if key != "":
				press_button(key)
		accept_event()
	elif event is InputEventMouseMotion:
		accept_event()

# --- Drawing -----------------------------------------------------------------------------------------

func _draw() -> void:
	if style == null or not is_showing():
		return
	var st := style
	var ink: Color = st.color("ink")
	var soft: Color = st.color("ink_soft")
	var faint: Color = st.color("ink_faint")
	draw_rect(Rect2(Vector2.ZERO, size), st.color("result_veil"), true)
	var r := card_rect()
	UiInk.card_shadow(self, r, st.shadow_dir() * st.num("card.lift_px"), st.color("card_shadow"))
	UiInk.card(self, r, st.color("card_fill"), ink, st.num("card.outer_line_px"), st.num("card.inner_line_px"),
		st.num("card.inner_inset_px"), st.num("card.wobble_px"), 29)
	var serif: Font = st.font(false)
	var italic: Font = st.font(true)
	var pad: float = st.num("card.pad_px") + 8.0
	var cx := r.position.x
	var wide := r.size.x
	UiInk.text(self, serif, Vector2(cx, r.position.y + 54.0), title_text(), st.num("combat.result.title_px"), ink, HORIZONTAL_ALIGNMENT_CENTER, wide)
	UiInk.ink_line(self, PackedVector2Array([Vector2(cx + pad, r.position.y + 68.0), Vector2(r.end.x - pad, r.position.y + 68.0)]), false, faint, 0.8, 7, 0.4)
	UiInk.text(self, italic, Vector2(cx, r.position.y + 90.0), sub_text(), st.num("fonts.detail_px"), soft, HORIZONTAL_ALIGNMENT_CENTER, wide)
	UiInk.text(self, serif, Vector2(cx, r.position.y + 126.0), reason_text(), st.num("combat.result.reason_px"), ink, HORIZONTAL_ALIGNMENT_CENTER, wide)
	var turn_line := turn_text()
	if turn_line != "":
		UiInk.text(self, italic, Vector2(cx, r.position.y + 148.0), turn_line, st.num("fonts.detail_px"), soft, HORIZONTAL_ALIGNMENT_CENTER, wide)
	var b := buttons()
	for key: String in b:
		_draw_button(b[key], key == "again", serif)

func _draw_button(b: Dictionary, big: bool, font: Font) -> void:
	var st := style
	var rect: Rect2 = b["rect"]
	var on := bool(b["on"])
	var ink: Color = st.color("ink")
	var fill: Color = st.color("button_on_fill") if on else st.color("button_fill")
	var txt: Color = st.color("button_on_text") if on else ink
	draw_rect(rect, fill, true)
	UiInk.ink_line(self, UiInk.rect_pts(rect), true, ink, 1.5 if big else 1.0, int(rect.position.x + rect.position.y), 0.35)
	var size_px: float = st.num("fonts.name_px") if big else st.num("fonts.button_px")
	var base := rect.position.y + rect.size.y * 0.5 + size_px * 0.34
	UiInk.text(self, font, Vector2(rect.position.x, base), str(b["label"]), size_px, txt, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x)
