extends RefCounted

# THE CONTRACT between the chunk baker (chunk_baker.gd) and whatever decides
# what the static map holds. The baker owns scheduling, sprites, rendering,
# caching and display; a provider owns the CONTENT of the world and how one
# chunk of it is COMPOSED, as a list of stages. Two exist:
#   chunk_terrain_provider.gd  Track T's terrain (scripts/world/terrain.gd):
#                              levels, hachures, groves, height-respecting shadows
#   chunk_scene_provider.gd    the stand-in: the prototype's scene generator per
#                              chunk (forts, houses, props, trees; no terrain)
# Another source is another subclass; the baker and the MapView do not change.
#
# Units: world PIXELS (map px) throughout; metres are the MapView's business.
# A chunk is chunk_px square, chunk (cx, cy) covering [cx, cx + 1) x [cy, cy +
# 1) times chunk_px. Chunk tiles are the BAKER's tiling and need not match the
# provider's own generation cells (Track T generates per 256 m).
#
# A provider implements:
#   prepare()            main thread, once: anything that touches the
#                        RenderingServer (materials, textures). The base
#                        class makes the shared ones here.
#   stages() -> Array    the bake, in order (chunk_baker.gd's header has the
#                        protocol): [{name, thread, fn, final?, parallel?,
#                        join?} | {builtin: "sprites"}]. An early stage must put
#                        the objects to draw from sprites into
#                        data.sprite_objects (COPIES the stage owns: the
#                        "sprites" stage sets `sprite` and `half` on them).
#   reach_px() -> float  how far any sprite or shadow reaches from its anchor.
#                        Every object of the neighbourhood that comes within
#                        this of a chunk is drawn by that chunk too, so a
#                        canopy or shadow crossing a border is identical on
#                        both sides and the border never shows.
#   chunk_content(c) -> Dictionary
#                        what chunk c holds, for tests and tools: a pure
#                        function of (seed, c), never of bake order. May run on
#                        a worker thread.
#   clear_cache()        drop generated content (a scale or style change).
#
# GROUND, MASKS, GRAIN shared by both providers (below): the paper tint per
# pixel at WORLD coordinates (shaders/map_paper.gdshader), buildGround's
# specks, fibres and dirt from a stream seeded by (seed, chunk) with the dirt
# field at world coordinates, the shadow composite, and the grain tile (one
# seeded texture per chunk size, multiplied at P.grain). All anchored to the
# world, so a chunk border never shows in them -- except that a speck or fibre
# is clipped at its own chunk's edge rather than continuing into the
# neighbour (at most a 4.5 px fibre at alpha .09).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/render/fast_noise.gd")  # core/noise.gd, bit for bit, faster
const InkGround = preload("res://scripts/render/ink_ground.gd")
const Grain = preload("res://scripts/render/grain.gd")
const PAPER_SHADER = preload("res://scripts/render/shaders/map_paper.gdshader")
const COMPOSITE_SHADER = preload("res://scripts/render/shaders/shadow_composite.gdshader")
const GRAIN_SHADER = preload("res://scripts/render/shaders/grain.gdshader")

const SALT_GROUND := 0x6A42

var chunk_px: int = 1024
var seed_value: int = 0
var P: RenderParams

# Made on the main thread by prepare(), shared by every chunk.
var _white: ImageTexture
var _grain: ImageTexture
var _paper_mat: ShaderMaterial
var _shadow_mat: ShaderMaterial
var _grain_mat: ShaderMaterial

func prepare() -> void:
	var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	_white = ImageTexture.create_from_image(white)
	_grain = Grain.build_texture(Vector2i(chunk_px, chunk_px), seed_value)
	_paper_mat = ShaderMaterial.new()
	_paper_mat.shader = PAPER_SHADER
	_paper_mat.set_shader_parameter("paper", Vector3(P.PAPER.r8, P.PAPER.g8, P.PAPER.b8))
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = COMPOSITE_SHADER
	_shadow_mat.set_shader_parameter("tint", Vector3(P.shadowCol.r, P.shadowCol.g, P.shadowCol.b))
	_shadow_mat.set_shader_parameter("strength", P.shadowStr)
	_grain_mat = ShaderMaterial.new()
	_grain_mat.shader = GRAIN_SHADER
	_grain_mat.set_shader_parameter("strength", P.grain)
	ShadowPass._silhouette_material()  # made here, never first on a worker

func stages() -> Array:
	return []

func reach_px() -> float:
	return 0.0

func chunk_content(_c: Vector2i) -> Dictionary:
	return {}

func clear_cache() -> void:
	pass

# --- shared helpers (thread-safe once prepare() has run) ------------------------------

func chunk_rect(c: Vector2i) -> Rect2:
	return Rect2(float(c.x * chunk_px), float(c.y * chunk_px), float(chunk_px), float(chunk_px))

# A stable 31-bit seed for (seed, chunk, salt), from the prototype's hash2 so
# it is the same on every platform.
static func chunk_seed(seed_value_: int, c: Vector2i, salt: int) -> int:
	return int(ValueNoise.hash2(c.x, c.y, (seed_value_ ^ salt) & 0x7FFFFFFF) * 2147483647.0)

# A fresh chunk canvas with the ground on it: the paper tint at world
# coordinates, then specks, fibres and dirt from the chunk's own stream (no
# road: P.L.road is the caller's).
func record_ground(view: Transform2D, rect: Rect2, size: Vector2i, c: Vector2i) -> InkCanvas:
	var g := InkCanvas.new(size)
	g.set_transform_matrix(view)
	if P.L.paper:
		# UV carries the world position (map_paper.gdshader): the source rect of
		# a 1x1 texture is the world rect itself.
		g.draw_image_region_with_material(_white, rect, rect, _paper_mat)
	else:
		g.fill_color = P.PAPER
		g.fill_rect(rect.position.x, rect.position.y, rect.size.x, rect.size.y)
	var k := view.get_scale().x
	InkGround.draw_ground(g, rect.size.x, rect.size.y, [], P, null,
		Mulberry32.new(chunk_seed(seed_value, c, SALT_GROUND)), null,
		Transform2D(Vector2(k, 0.0), Vector2(0.0, k), Vector2.ZERO), rect.position)
	g.set_transform_matrix(view)
	return g

# ctx.globalAlpha=P.shadowStr; ctx.drawImage(tinted mask, 0, 0)
func composite_mask(g: InkCanvas, mask: Texture2D) -> void:
	if mask == null or not P.L.shadows:
		return
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(mask, 0.0, 0.0, float(g.size.x), float(g.size.y), _shadow_mat)
	g.restore()

# The grain tile multiplied over the whole chunk (Grain.apply's draw, with the
# material made on the main thread).
func apply_grain(g: InkCanvas) -> void:
	if not (P.L.grain and P.grain > 0.0):
		return
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(_grain, 0.0, 0.0, float(g.size.x), float(g.size.y), _grain_mat)
	g.restore()

# A ShadowPass-like mask canvas for `size` (black fill and stroke, round caps)
# under `view`. Unrendered: the baker renders it.
static func new_mask(size: Vector2i, view: Transform2D) -> InkCanvas:
	var m := InkCanvas.new(size)
	m.fill_color = Color.BLACK
	m.stroke_color = Color.BLACK
	m.line_cap = "round"
	m.set_transform_matrix(view)
	return m

# Points as [x, y] Arrays -> PackedVector2Array.
static func to_v2(pts: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = Vector2(pts[i][0], pts[i][1])
	return out
