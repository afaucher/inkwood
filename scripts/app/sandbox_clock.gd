extends Control

# THE TURN CLOCK (Track A2, PROPOSED): "turn 7 of 20", a small inked card at the top of the map, for a scenario whose
# mission has a TURN LIMIT (the strike: Alex, "lose ... at a turn limit"). Without it a player cannot tell how long
# the bomber has: the roster header says the turn, never the limit. It counts the turn being planned; the limit's
# own turn is the last one played ("turn 20 of 20" is the last turn to plan). The last three turns say how many
# are left, in heavier ink. Never takes a click.
#
#   var clock := SandboxClock.new()
#   hud_layer.add_child(clock)
#   clock.setup(style, world, 20)           # the scenario's turn limit (SandboxScenario.turn_limit(); 0: no clock)
#   clock.line()                            # "turn 7 of 20"

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

const WARN_TURNS := 3          # this many turns from the end the card says "n turns left"

var style: UiStyle = null
var world: Object = null
var limit := 0
var insets_right := 0.0        # the sidebar's width: the card centres on the map to its left

func setup(st: RefCounted, w: Object, turn_limit: int, right_inset: float = 0.0) -> void:
	style = st as UiStyle
	world = w
	limit = turn_limit
	insets_right = right_inset
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = limit > 0
	queue_redraw()

# The turn being planned, never past the limit (the roster counts on after a result).
func turn_now() -> int:
	return mini(int(world.turn), limit) if world != null else 0

func turns_left() -> int:
	return limit - turn_now()

func line() -> String:
	return "turn %d of %d" % [turn_now(), limit]

func warning() -> String:
	var left := turns_left()
	if left > WARN_TURNS - 1:
		return ""
	return "last turn" if left == 0 else "%d turn%s left" % [left, "" if left == 1 else "s"]

func _process(_delta: float) -> void:
	if visible:
		queue_redraw()

func _draw() -> void:
	if style == null or limit <= 0 or world == null:
		return
	var ink: Color = style.color("ink")
	var soft: Color = style.color("ink_soft")
	var serif: Font = style.font(false)
	var italic: Font = style.font(true)
	var px: float = style.num("fonts.detail_px") + 3.0
	var small: float = style.num("fonts.detail_px")
	var warn := warning()
	var w := maxf(UiInk.text_width(serif, line(), px), UiInk.text_width(italic, warn, small) if warn != "" else 0.0) + 28.0
	var h := 30.0 if warn == "" else 46.0
	var x := (size.x - insets_right - w) * 0.5
	var r := Rect2(Vector2(x, 12.0), Vector2(w, h))
	UiInk.card_shadow(self, r, style.shadow_dir() * style.num("card.lift_px"), style.color("card_shadow"))
	UiInk.card(self, r, style.color("card_fill"), ink, style.num("card.outer_line_px"), style.num("card.inner_line_px"),
		style.num("card.inner_inset_px"), style.num("card.wobble_px"), 17)
	UiInk.text(self, serif, Vector2(r.position.x + 14.0, r.position.y + px + 6.0), line(), px, ink if warn != "" else soft)
	if warn != "":
		UiInk.text(self, italic, Vector2(r.position.x + 14.0, r.position.y + px + small + 12.0), warn, small, ink)
