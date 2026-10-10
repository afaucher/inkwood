extends Node2D

# A stand-in for the standing radio tower, for the variant boards and shots only (the game's tower is the unit marker's:
# Track U3's scripts/ui/unit_marker_art_static.gd). It draws the tower from the unit sheet's own model (the same seed as
# the marker's) through scripts/fx/fx_ruin.gd, with its cast shadow, so a destroyed tower is judged beside the standing
# one it was. Two passes, like FxPlaneProxy's: `shadow_node` (a CanvasGroup at the map's shadow strength) and `plane_node`.
#
#   var sp := FxStructProxy.new()
#   canvas_layer.add_child(sp)
#   sp.setup(mapping, fx_style)
#   sp.towers = [{"pos": Vector2 (world m), "heading": rad, "side": "side_a"}]
#   sp.refresh()

const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPass = preload("res://scripts/fx/fx_pass.gd")
const FxShadowPass = preload("res://scripts/fx/fx_shadow_pass.gd")
const FxRuin = preload("res://scripts/fx/fx_ruin.gd")

var mapping: UiMapping = null
var fx_style: FxStyle = null
var true_scale: float = 1.0
var towers: Array[Dictionary] = []
var variant: int = 0
var shadow_node: CanvasGroup = null
var plane_node: Node2D = null
var roles := {"rock": "ruin.rock", "roof": "ruin.roof", "cream": "ruin.cream"}

var _tint := Color.WHITE
var _art: Dictionary = {}

func setup(host_mapping: Variant, fx_st: FxStyle) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	fx_style = fx_st
	var tint: Color = fx_st.palette["shadow"]
	_tint = Color(tint.r, tint.g, tint.b, 1.0)
	var sg := FxShadowPass.new()
	sg.name = "Shadows"
	sg.layer = self
	sg.self_modulate = Color(1.0, 1.0, 1.0, fx_st.param("shadow_strength"))
	add_child(sg)
	shadow_node = sg
	var pn := FxPass.new()
	pn.name = "Towers"
	pn.layer = self
	pn.kind = "planes"
	add_child(pn)
	plane_node = pn

func refresh() -> void:
	if shadow_node != null:
		shadow_node.queue_redraw()
		plane_node.queue_redraw()

# The tower's sprite and shadow mask at `ppm`, turned by `rot`, baked once.
func _art_for(ppm: float, rot: float, accent: Color) -> Dictionary:
	var q := snappedf(ppm, 0.05)
	var key := "%.2f|%.3f|%s" % [q, rot, accent.to_html()]
	if _art.has(key):
		return _art[key]
	var M := FxRuin.tower_model(fx_style.scene_seed, variant)
	var half := int(ceil(34.0 * q))
	var g := InkCanvas.new(Vector2i(half * 2, half * 2))
	g.line_cap = "round"
	FxRuin.draw_standing(g, fx_style, M, q, Vector2(half, half), accent, roles, rot)
	var gm := InkCanvas.new(Vector2i(half * 2, half * 2))
	FxRuin.draw_standing_mask(gm, fx_style, M, q, Vector2(half, half), rot)
	var imgs := FxBake.render([g, gm])
	var art := {"tex": FxBake.texture(imgs[0], false), "mask": FxBake.texture(imgs[1], true), "origin": Vector2(half, half), "ppm": q}
	_art[key] = art
	return art

func draw_pass(item: CanvasItem, kind: String) -> void:
	if mapping == null or not FxBake.can_bake():
		return
	for t in towers:
		var wp: Vector2 = t["pos"]
		var ppm := mapping.px_per_m(wp) * true_scale
		var rot := mapping.screen_angle(wp, float(t["heading"])) + PI / 2.0
		var art := _art_for(ppm, snappedf(rot, 0.001), fx_style.palette[str(t.get("side", "side_a"))])
		if art["tex"] == null:
			continue
		var sp := mapping.world_to_screen(wp)
		var sc := ppm / float(art["ppm"])
		item.draw_set_transform(sp, 0.0, Vector2(sc, sc))
		if kind == "shadows":
			item.draw_texture(art["mask"], -(art["origin"] as Vector2), _tint)
		else:
			item.draw_texture(art["tex"], -(art["origin"] as Vector2), Color.WHITE)
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
