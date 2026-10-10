extends Node2D

# A stand-in for the unit markers, for the boards and shots only (the game's planes are
# scripts/ui/unit_marker_layer.gd's): draws planes and their ground shadows as the markers
# do, from the same art (UnitMarkerArt, read-only) and the same shadow rule, so an effect is
# judged beside the plane it will really sit with. Two passes, like the FxLayer's:
# `shadow_node` (a CanvasGroup at the map's shadow strength) and `plane_node`.
#
#   var proxy := FxPlaneProxy.new()
#   canvas_layer.add_child(proxy)
#   proxy.setup(mapping, style, fx_style)
#   proxy.planes = [{"pos": Vector2 (world m), "heading": rad, "h": metres above ground, "type": "light_fighter", "side": "side_a"}]
#   proxy.refresh()

const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const WingtipTrails = preload("res://scripts/ui/wingtip_trails.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPass = preload("res://scripts/fx/fx_pass.gd")
const FxShadowPass = preload("res://scripts/fx/fx_shadow_pass.gd")

var mapping: UiMapping = null
var ui_style: UiStyle = null
var fx_style: FxStyle = null
var true_scale: float = 1.0
var planes: Array[Dictionary] = []
# Wingtip-trail records (WingtipTrails.collect()'s shape: left, right, centre, age, step, accent, half_span_px),
# drawn in the ribbon mode under the planes, as the marker layer's trail node does. The board builds them.
var ribbons: Array = []
# false: the ribbons are drawn with the planes, over the smoke (the marker layer's order today); true: in a node of their
# own the board puts BELOW the smoke, the alternative order the board shows beside it.
var ribbons_below: bool = false
var below_node: Node2D = null
var shadow_node: CanvasGroup = null
var plane_node: Node2D = null

var _tint := Color.WHITE
var _size_m := {"light_fighter": 9.0, "heavy_fighter": 12.0, "bomber": 20.0}

func setup(host_mapping: Variant, ui_st: UiStyle, fx_st: FxStyle) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	ui_style = ui_st
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
	pn.name = "Planes"
	pn.layer = self
	pn.kind = "planes"
	add_child(pn)
	plane_node = pn

func refresh() -> void:
	if shadow_node != null:
		shadow_node.queue_redraw()
		plane_node.queue_redraw()
	if below_node != null:
		below_node.queue_redraw()

func size_of(type: String) -> float:
	return float(_size_m.get(type, 9.0))

func draw_pass(item: CanvasItem, kind: String) -> void:
	if mapping == null or not FxBake.can_bake():
		return
	if kind == "ribbons":
		if ribbons_below and not ribbons.is_empty():
			WingtipTrails.draw_items(item, ribbons, ui_style, "ribbon")
		return
	if kind == "planes" and not ribbons_below and not ribbons.is_empty():
		WingtipTrails.draw_items(item, ribbons, ui_style, "ribbon")
	for p in planes:
		var wp: Vector2 = p["pos"]
		var ppm := mapping.px_per_m(wp) * true_scale
		var rot := mapping.screen_angle(wp, float(p["heading"])) + PI / 2.0
		var art: UnitMarkerArt.Art = UnitMarkerArt.art_for(ui_style, str(p["type"]), fx_style.palette[str(p["side"])], snappedf(ppm, 0.01), rot)
		if art == null or art.texture == null:
			continue
		var sp := mapping.world_to_screen(wp)
		var sc := ppm / art.ppm
		# a static unit's art (the battery) is baked already turned, its mask its cast shadow: not rotated here
		var turn := 0.0 if ("screen_aligned" in art and art.screen_aligned) else rot
		if kind == "shadows":
			var off := mapping.screen_delta(wp, fx_style.plane_shadow_offset_m(float(p["h"])) * true_scale)
			item.draw_set_transform(sp + off, turn, Vector2(sc, sc))
			item.draw_texture(art.mask, -art.origin, _tint)
		else:
			item.draw_set_transform(sp, turn, Vector2(sc, sc))
			item.draw_texture(art.texture, -art.origin, Color.WHITE)
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
