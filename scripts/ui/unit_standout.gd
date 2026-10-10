extends RefCounted

# How the players' own units stand out on busy ground: the variant switch of
# variants/own-units-stand-out/ (Track U1, the first fight; EVERY VALUE PROPOSED,
# nothing chosen). Data: data/ui/ui.json marker.standout. The default mode,
# "none", is today's marker and builds nothing at all.
#
#   mode            what it adds, under the plane (own units only)
#   none            nothing (today)
#   halo            a paper knock-out round the silhouette, feathered
#   lift            a soft pool of paper centred on the unit
#   rim             the silhouette grown in ink: a heavier outline
#   ring            a ring in the unit's side accent under the plane
#   larger          the plane drawn `scale` times bigger
#
# A mode may join effects with "+": "halo+ring". An unknown name is an error
# (reported once, the rest still applied), never a silent no-op.
#
# THE SPEC. parse() resolves the data once into a plain Dictionary the markers
# and the layer read every frame:
#   {"mode": "halo+ring", "scale": 1.0,
#    "shapes": [{"kind": 0, "radius_px", "soft_px", "color": Color} | {"kind": 1, "inner_k", "outer_k", "color"}],
#    "ring": {} | {"pad_px", "width_px", "color_alpha", "rim_px", "rim_color"}}
# Shapes are drawn by Shape (a Node2D with unit_standout.gdshader) in the
# layer's "Under" node, below the shadows: a halo never covers the plane's own
# shadow, so the altitude cue stays. The ring is drawn by the layer in the
# same node.

const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const SHADER := preload("res://scripts/ui/unit_standout.gdshader")

const KIND_DILATE := 0   # a grown copy of the silhouette (halo, rim)
const KIND_POOL := 1     # a soft disc centred on the unit (lift)

# The data's mode names, from marker.standout.modes.
static func known_modes(style: RefCounted) -> Array:
	var v: Variant = style.lookup("marker.standout.modes")
	return v if v is Array else []

# Resolves a mode string to the spec above.
static func parse(style: RefCounted, mode: String) -> Dictionary:
	var spec := {"mode": mode, "scale": 1.0, "shapes": [], "ring": {}}
	var known := known_modes(style)
	for token: String in mode.split("+", false):
		token = token.strip_edges()
		if token == "none":
			continue
		if not known.has(token):
			style._err_once("standout:" + token, "ui.json marker.standout.mode '%s' is not one of %s" % [token, str(known)])
			continue
		var p := "marker.standout." + token
		match token:
			"halo", "rim":
				(spec["shapes"] as Array).append({
					"kind": KIND_DILATE, "name": token,
					"radius_px": style.num(p + ".radius_px"),
					"soft_px": style.num(p + ".soft_px"),
					"color": UiRoles.resolve(style, style.lookup(p + ".role"), p + ".role"),
				})
			"lift":
				(spec["shapes"] as Array).append({
					"kind": KIND_POOL, "name": token,
					"inner_k": style.num(p + ".inner_k"),
					"outer_k": style.num(p + ".outer_k"),
					"color": UiRoles.resolve(style, style.lookup(p + ".role"), p + ".role"),
				})
			"ring":
				spec["ring"] = {
					"pad_px": style.num(p + ".pad_px"),
					"width_px": style.num(p + ".width_px"),
					"alpha": style.num(p + ".alpha"),
					"rim_px": style.num(p + ".rim_px"),
					"rim_color": UiRoles.resolve(style, style.lookup(p + ".rim_role"), p + ".rim_role"),
				}
			"larger":
				spec["scale"] = style.num(p + ".scale")
	return spec

static func is_none(spec: Dictionary) -> bool:
	return (spec["shapes"] as Array).is_empty() and (spec["ring"] as Dictionary).is_empty() and is_equal_approx(float(spec["scale"]), 1.0)

# One shape under one plane: posed with the plane's own transform, so the
# shader reads the mask in the mask's own px.
class Shape extends Node2D:
	const _SHADER := preload("res://scripts/ui/unit_standout.gdshader")
	const _DILATE := 0
	var spec: Dictionary = {}
	var _tex: Texture2D = null
	var _origin := Vector2.ZERO
	var _extent_px := 0.0       # the plane's radius in node-local px (the lift's unit)
	var _pad := -1.0
	var _mat: ShaderMaterial

	func setup(shape_spec: Dictionary) -> void:
		spec = shape_spec
		_mat = ShaderMaterial.new()
		_mat.shader = _SHADER
		_mat.set_shader_parameter("kind", int(spec["kind"]))
		material = _mat
		name = "Standout_%s" % str(spec.get("name", "shape"))

	# `art_mask` is the baked silhouette; `origin` the unit's centre in it; `extent_px` the
	# plane's radius in the mask's px; `scale_px` the node's scale (screen px per mask px).
	func pose(screen_pos: Vector2, rot: float, scale_px: float, art_mask: Texture2D, origin: Vector2, extent_px: float) -> void:
		position = screen_pos
		rotation = rot
		scale = Vector2.ONE * scale_px
		var s := maxf(scale_px, 1e-4)
		var pad: float
		if int(spec["kind"]) == _DILATE:
			pad = ceilf((float(spec["radius_px"]) + float(spec["soft_px"])) / s) + 2.0
			_mat.set_shader_parameter("radius", float(spec["radius_px"]) / s)
			_mat.set_shader_parameter("soft", float(spec["soft_px"]) / s)
		else:
			var outer := float(spec["outer_k"]) * extent_px
			pad = outer + 2.0
			_mat.set_shader_parameter("inner", float(spec["inner_k"]) * extent_px)
			_mat.set_shader_parameter("outer", outer)
		if art_mask != _tex or origin != _origin or absf(pad - _pad) > 0.5:
			_tex = art_mask
			_origin = origin
			_pad = pad
			_mat.set_shader_parameter("mask", art_mask)
			_mat.set_shader_parameter("origin_px", origin)
			_mat.set_shader_parameter("tex_px", Vector2(art_mask.get_size()))
			queue_redraw()

	func _draw() -> void:
		if _tex == null:
			return
		var r: Rect2
		if int(spec["kind"]) == _DILATE:
			r = Rect2(-_origin - Vector2(_pad, _pad), _tex.get_size() + Vector2(_pad, _pad) * 2.0)
		else:
			r = Rect2(Vector2(-_pad, -_pad), Vector2(_pad, _pad) * 2.0)
		_mat.set_shader_parameter("rect_min", r.position)
		_mat.set_shader_parameter("rect_size", r.size)
		draw_rect(r, spec["color"])
