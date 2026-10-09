extends RefCounted

# Height-respecting shadows on terrain levels (Track T; exit criterion 4).
# Functions that ADD SILHOUETTES TO A ShadowPass (scripts/render/shadow_pass.gd),
# so the renderer composes them in its own pass order; plus cast_terrain /
# cast_trees, which run a whole class for callers that just want it done.
#
# THE MODEL: levels are flat tops with vertical scarps, so a shadow is exact
# per RECEIVER LEVEL. On receiver level r (height z_r) everything taller casts
# its silhouette displaced by (top - z_r) / tan(elevation) away from the sun:
#   - the scarp of threshold k (between levels k and k+1, k >= r) as a PRISM:
#     each boundary segment and the same segment shifted by
#     (height_{k+1} - z_r) / tan(elev), filled as one path -- castShadows'
#     wall prisms, one merged mask, tinted once;
#   - a tree with base b and height h: its trunk line from where its foot
#     lands, (max(b, z_r) - z_r) * L, to its canopy, (b + h - z_r) * L, and the
#     canopy silhouette stretched along the sun as the prototype does.
# Then the mask is CUT TO THE RECEIVER: multiplied by "level == r" from the
# level masks (terrain_draw.gd), so the upland's own top never darkens under
# its own prism, a low tree's shadow stops at the foot of the scarp it runs
# into, and a tree standing on the upland near the edge throws its shadow off
# the edge and down onto the low ground, further out, where it really lands.
#
# ONE TINT PER CLASS. The receiver masks are rendered one by one, summed into
# a single mask (they cover disjoint pixels, so the sum is their union with no
# seam at a boundary) and composited ONCE: never double-darkened within the
# class, exactly like castShadows.
#
# SHADE (proposed, beyond the prototype): the prototype composites each class
# separately, so a tree shadow inside a wall's shadow darkens twice. A scarp's
# shadow is broad, and trees stand in it, so cast_terrain returns its class
# mask -- the TERRAIN SHADE -- and every later class can be cut by it
# (cut_to_receiver's `shade`, or cut_shade): ground already out of the sun
# does not darken again. Proposed for Track R's prop and structure classes too.
#
# PASS ORDER (proposed; Track R's renderer, Track V's chunk bake):
#   ground, level fill, linework (terrain_draw.gd)
#   -> TERRAIN class: shade := cast_terrain(frame, sp, masks, view, rect)
#      (or by hand: per receiver r in 0 .. levels-2: add_terrain_silhouettes(sp, r, view, rect);
#       cut_to_receiver(sp, masks, r); parts.append(sp.canvas.finish_texture()); sp.clear()
#       -- then composite_parts(frame, sp, parts))
#   -> prop shadows -> props -> structure shadows -> structures   (each cut_shade(sp, shade))
#   -> TREE class: cast_trees(frame, sp, masks, trees, view, shade)
#   -> trees (sorted by base + h, then y) -> grain
#
# Trees need `sprite` (a Texture2D, premultiplied) and `half`, as the
# prototype's castShadows does; terrain.gd's records carry `base` and `level`.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Terrain = preload("res://scripts/world/terrain.gd")

const MAX_RECEIVERS := 4

# out = mask * keep, alpha included (blend_mul multiplies both): keep is the
# receiver's share of the pixel -- level >= r minus level >= r+1 -- outside
# the shade.
const _CUT_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_mul;
uniform sampler2D lo_mask : filter_linear;
uniform sampler2D hi_mask : filter_linear;
uniform sampler2D shade_mask : filter_nearest;
uniform bool use_lo = false;
uniform bool use_hi = false;
uniform bool use_shade = false;
void fragment() {
	float lo = use_lo ? texture(lo_mask, UV).r : 1.0;
	float hi = use_hi ? texture(hi_mask, UV).r : 0.0;
	float keep = clamp(lo - hi, 0.0, 1.0);
	if (use_shade) {
		keep *= 1.0 - texture(shade_mask, UV).a;
	}
	COLOR = vec4(keep);
}
"""

# The receiver masks summed into one (disjoint supports: the sum is the union).
const _MERGE_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
uniform sampler2D p0 : filter_nearest;
uniform sampler2D p1 : filter_nearest;
uniform sampler2D p2 : filter_nearest;
uniform sampler2D p3 : filter_nearest;
uniform int count = 1;
void fragment() {
	float a = texture(p0, UV).a;
	if (count > 1) { a += texture(p1, UV).a; }
	if (count > 2) { a += texture(p2, UV).a; }
	if (count > 3) { a += texture(p3, UV).a; }
	COLOR = vec4(0.0, 0.0, 0.0, min(a, 1.0));
}
"""

var terrain: Terrain
var P: RenderParams
var az: float          # the prototype's az: (sunAz + 90) degrees, the shadow's direction
var dir: Vector2       # unit, away from the sun
var L: float           # 1 / tan(elevation): shadow length per unit of height
var stretch: float     # canopy stretch along the sun
var lee_dot_min: float
var last_count := 0    # silhouettes added by the last cast_terrain / cast_trees

var _cut_shader: Shader
var _merge_shader: Shader

func _init(t: Terrain, params: RenderParams = null) -> void:
	terrain = t
	P = params if params != null else RenderParams.new()
	az = (P.sunAz + 90.0) * PI / 180.0
	dir = Vector2(cos(az), sin(az))
	L = 1.0 / tan(P.elev * PI / 180.0)
	stretch = minf(P.canopy_shadow_stretch_max, 1.0 + L * 0.3)
	lee_dot_min = terrain.data.num("shadow.lee_dot_min")
	if terrain.level_count() > MAX_RECEIVERS:
		push_error("TerrainShadows: %d levels; the merge handles %d" % [terrain.level_count(), MAX_RECEIVERS])

# How far (world px) a shadow can reach from its caster: the top level's
# drop plus the tallest tree, plus a stretched canopy. Gather casters from a
# rect grown by this much.
func reach_px() -> float:
	var top := terrain.heights_m[terrain.heights_m.size() - 1] * terrain.px_per_m
	var tallest := P.treeSize * (1.0 + P.sizeVar) * P.big_tree_scale * P.height * 1.15
	return (top + tallest) * L + tallest * stretch * 1.3 + 8.0

# --- terrain class -------------------------------------------------------------------

# The scarp prisms that fall on receiver level r, into `sp`, under `view`
# (world px -> frame). `rect` is the world-pixel area being drawn; casters
# are gathered from it grown by reach_px(). Returns the number of prisms.
func add_terrain_silhouettes(sp: ShadowPass, receiver: int, view: Transform2D, rect: Rect2) -> int:
	var m := sp.canvas
	var chunks := terrain.chunks_in_rect_px(rect.grow(reach_px()))
	var count := 0
	m.save()
	m.set_transform_matrix(view)
	m.fill_color = Color.BLACK
	m.begin_path()
	for k in range(receiver, terrain.thresholds.size()):
		var drop := (terrain.heights_m[k + 1] - terrain.heights_m[receiver]) * terrain.px_per_m * L
		var off := dir * drop
		for c in chunks:
			for ch: Dictionary in terrain.chains_px(c.x, c.y, k):
				var pts: PackedVector2Array = ch.pts
				var n := pts.size()
				var lim := n if ch.closed else n - 1
				for i in lim:
					var a := pts[i]
					var b := pts[(i + 1) % n]
					var d := b - a
					var l := d.length()
					if l == 0.0:
						continue
					# down-slope normal (the lower level is on the chain's left)
					if (d.y * dir.x - d.x * dir.y) / l < lee_dot_min:
						continue
					m.move_to(a.x, a.y)
					m.line_to(b.x, b.y)
					m.line_to(b.x + off.x, b.y + off.y)
					m.line_to(a.x + off.x, a.y + off.y)
					m.close_path()
					count += 1
	if count > 0:
		m.fill()
	m.restore()
	return count

# --- tree class ------------------------------------------------------------------------

# The trees whose shadows land on receiver level r: trunk lines and stretched
# canopy silhouettes, each displaced by its height above that level. A tree
# standing ABOVE the receiver is skipped unless its shadow there comes near
# ground of that level (a cheap filter; the cut is what makes it exact).
func add_tree_silhouettes(sp: ShadowPass, trees: Array, receiver: int, view: Transform2D) -> int:
	var m := sp.canvas
	var zr := terrain.heights_m[receiver] * terrain.px_per_m
	var count := 0
	m.stroke_color = Color.BLACK
	m.line_cap = "round"
	for t: Dictionary in trees:
		var base: float = t.get("base", 0.0)
		var h: float = t.h
		var top := base + h
		if top <= zr:
			continue
		var pos := Vector2(t.x, t.y)
		var foot := pos + dir * ((maxf(base, zr) - zr) * L)
		var s := pos + dir * ((top - zr) * L)
		var half: float = t.half
		var lvl: int = t.get("level", 0)
		if lvl > receiver and not _reaches_level(s, foot, half * stretch, receiver):
			continue
		m.save()
		m.set_transform_matrix(view)
		m.line_width = maxf(1.5, t.r * 0.12)
		m.begin_path()
		m.move_to(foot.x, foot.y)
		m.line_to(s.x, s.y)
		m.stroke()
		m.restore()
		var xf := view * Transform2D(0.0, s) * Transform2D(az, Vector2.ZERO) \
			* Transform2D(Vector2(stretch, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) * Transform2D(-az, Vector2.ZERO)
		sp.draw_silhouette_texture(t.sprite, xf, Rect2(-half, -half, half * 2.0, half * 2.0))
		count += 1
	return count

# Whether a shadow centred at `s` (radius `rad`, trunk back to `foot`) touches
# ground of level <= receiver.
func _reaches_level(s: Vector2, foot: Vector2, rad: float, receiver: int) -> bool:
	var ppm := terrain.px_per_m
	if terrain.level_at_px(s.x, s.y) <= receiver or terrain.level_at_px(foot.x, foot.y) <= receiver:
		return true
	var reach := (rad + s.distance_to(foot)) / ppm
	return terrain.boundary_distance(s.x / ppm, s.y / ppm, receiver, reach) < reach

# --- cuts ---------------------------------------------------------------------------------

# Keeps only the part of the mask in `sp` that lands on receiver level r:
# mask *= (level >= r) - (level >= r + 1), from terrain_draw.gd's level masks
# rendered for the same frame -- and, given a `shade` (a class mask returned
# by cast_terrain), only outside it. Call after the silhouettes, before the
# mask is rendered or composited.
func cut_to_receiver(sp: ShadowPass, masks: Array, receiver: int, shade: Texture2D = null) -> void:
	if masks.is_empty() and shade == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = _shader("cut")
	if receiver >= 1 and receiver - 1 < masks.size():
		mat.set_shader_parameter("use_lo", true)
		mat.set_shader_parameter("lo_mask", masks[receiver - 1])
	if receiver < masks.size():
		mat.set_shader_parameter("use_hi", true)
		mat.set_shader_parameter("hi_mask", masks[receiver])
	if shade != null:
		mat.set_shader_parameter("use_shade", true)
		mat.set_shader_parameter("shade_mask", shade)
	_full_rect(sp, masks[0] if not masks.is_empty() else shade, mat)

# Only the shade cut, for a class with no receiver logic (props, structures).
func cut_shade(sp: ShadowPass, shade: Texture2D) -> void:
	if shade != null:
		cut_to_receiver(sp, [], 0, shade)

# The rendered receiver masks of one class, summed into `sp`'s mask and
# composited once onto `frame`. Returns the class mask (premultiplied black,
# alpha = coverage), or null when there was nothing to cast.
func composite_parts(frame: InkCanvas, sp: ShadowPass, parts: Array) -> ImageTexture:
	if parts.is_empty():
		sp.clear()
		return null
	var mat := ShaderMaterial.new()
	mat.shader = _shader("merge")
	for i in parts.size():
		mat.set_shader_parameter("p%d" % i, parts[i])
	mat.set_shader_parameter("count", parts.size())
	_full_rect(sp, parts[0], mat)
	return sp.composite(frame, P.shadowCol, P.shadowStr)

func _full_rect(sp: ShadowPass, tex: Texture2D, mat: ShaderMaterial) -> void:
	var m := sp.canvas
	m.save()
	m.reset_transform()
	m.global_alpha = 1.0
	m.draw_image_with_material(tex, 0.0, 0.0, float(sp.size.x), float(sp.size.y), mat)
	m.restore()

func _shader(which: String) -> Shader:
	if which == "cut":
		if _cut_shader == null:
			_cut_shader = Shader.new()
			_cut_shader.code = _CUT_SHADER
		return _cut_shader
	if _merge_shader == null:
		_merge_shader = Shader.new()
		_merge_shader.code = _MERGE_SHADER
	return _merge_shader

# --- whole classes ---------------------------------------------------------------------

# The terrain class onto `frame`: a receiver mask per level below the top,
# summed and composited once. Returns the class mask: the TERRAIN SHADE.
func cast_terrain(frame: InkCanvas, sp: ShadowPass, masks: Array, view: Transform2D, rect: Rect2) -> ImageTexture:
	var parts: Array = []
	last_count = 0
	for r in terrain.level_count() - 1:
		var n := add_terrain_silhouettes(sp, r, view, rect)
		last_count += n
		if n > 0:
			cut_to_receiver(sp, masks, r)
			parts.append(sp.canvas.finish_texture())
		sp.clear()
	return composite_parts(frame, sp, parts)

# The tree class onto `frame`: a receiver mask per level, each outside the
# `shade` when given, summed and composited once. Returns the class mask.
func cast_trees(frame: InkCanvas, sp: ShadowPass, masks: Array, trees: Array, view: Transform2D,
		shade: Texture2D = null) -> ImageTexture:
	var parts: Array = []
	last_count = 0
	for r in terrain.level_count():
		var n := add_tree_silhouettes(sp, trees, r, view)
		last_count += n
		if n > 0:
			cut_to_receiver(sp, masks, r, shade)
			parts.append(sp.canvas.finish_texture())
		sp.clear()
	return composite_parts(frame, sp, parts)
