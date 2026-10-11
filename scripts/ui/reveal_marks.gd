extends Node2D

# THE "LAST SEEN" MARKS (Track M2L, PROPOSED 2026-10-11; scripts/sim/reveal.gd, data/sim/reveal.json "ghost"): where a hidden gun gave itself
# away by firing at the player's side. The lead's proposal was "a quiet 'last seen' marker that fades": a dashed ring in the gun's side
# colour with a cross in it and the words LAST SEEN under it, at the place of the shot, drawn in screen space (a true pixel width at any
# zoom) above the fog, at full strength while the gun is REVEALED (the fog is open there) and fading away over fade_s after that.
#
# It draws only what the fog has not got already: when the gun's own marker is shown (it is still where it fired from, in the open patch)
# the marker is the thing to see and the ring is not drawn. A gun that has driven away (its marker is hidden again) leaves the ring.
# The list is the fog's (FogVision.reveal_list, made by update_from_world with the playback time), so a ring appears the moment the
# playback reaches the shot and not before.
#
#   var marks := RevealMarks.new()
#   mount.add_child(marks)
#   marks.setup(map_view, style, fog.vision, world)

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")
const RevealRules = preload("res://scripts/sim/reveal.gd")

var host: Node2D = null
var style: UiStyle = null
var vision: RefCounted = null          # the FogVision whose reveal_list is drawn
var world: Object = null
var enabled := true                     # false: nothing drawn (the fog is off)

var _drawn := 0                         # rings drawn last frame (so the frame they all go is redrawn empty)

func setup(host_view: Node2D, st: RefCounted, fog_vision: RefCounted, w: Object) -> void:
	host = host_view
	style = st as UiStyle
	vision = fog_vision
	world = w
	name = "RevealMarks"
	queue_redraw()

func _process(_delta: float) -> void:
	if vision != null and (_drawn > 0 or not (vision.reveal_list as Array).is_empty()):
		queue_redraw()

# The rings to draw now, on screen: [{unit, centre: Vector2 (px), alpha, revealed, side}]. The ghost data of Reveal.marks, minus the
# guns whose own marker is shown, plus the screen position. Public so a test can see what is drawn without a pixel.
func rings() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not enabled or host == null or vision == null or world == null:
		return out
	var rv: Variant = RevealRules.of(world)
	if rv == null or not rv.ok():
		return out
	var xf: Transform2D = host.get_global_transform_with_canvas()
	var ppm: float = host.px_per_m
	for m: Dictionary in vision.reveal_list:
		if vision.shows_unit(world, str(m["unit"])):
			continue
		out.append({
			"unit": str(m["unit"]), "side": str(m["side"]), "revealed": bool(m["revealed"]),
			"centre": xf * (Vector2(float(m["x"]), float(m["y"])) * ppm),
			"alpha": float(m["alpha"]) * float(rv.ghost_alpha),
		})
	return out

func _draw() -> void:
	var list := rings()
	_drawn = list.size()
	if list.is_empty() or style == null:
		return
	var rv: Variant = RevealRules.of(world)
	var r: float = float(rv.ghost_ring_px)
	var line: float = float(rv.ghost_line_px)
	var word: String = str(rv.ghost_label)
	var font: Font = UiLabels.font(style)
	var px: float = UiLabels.px(style)
	for ring: Dictionary in list:
		var c: Vector2 = ring["centre"]
		var a: float = float(ring["alpha"])
		var accent: Color = style.side_color(str(ring["side"]))
		var ink: Color = style.color("ink")
		var col := Color(accent.r, accent.g, accent.b, a)
		UiInk.dashed(self, UiInk.circle_pts(c, r, 40) + PackedVector2Array([c + Vector2(r, 0.0)]), col, line, 5.0, 3.5)
		var k := r * 0.45
		UiInk.ink_line(self, PackedVector2Array([c + Vector2(-k, 0.0), c + Vector2(k, 0.0)]), false, Color(ink.r, ink.g, ink.b, a), line, 3, 0.3)
		UiInk.ink_line(self, PackedVector2Array([c + Vector2(0.0, -k), c + Vector2(0.0, k)]), false, Color(ink.r, ink.g, ink.b, a), line, 5, 0.3)
		if word != "":
			var w := UiInk.text_width(font, word, px)
			var lc: Color = style.color("label_ink")
			UiLabels.draw(self, style, font, Vector2(c.x - w * 0.5, c.y + r + px + 3.0), word, px, Color(lc.r, lc.g, lc.b, a), w, HORIZONTAL_ALIGNMENT_CENTER)
