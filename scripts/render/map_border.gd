extends Node2D

# THE MAP'S BORDER (builder, map-border board, 2026-10-11). What the map shows past its edge, as options on a switch, read from
# data/view/map_border.json. ALEX CHOSE E (2026-10-11, decision map-border, from variants/map-border/board.json: "I like the
# hatches, with the distance legend"); the numbers in it stay proposed records. The others are kept switchable for comparison:
#
#   none  the old look (the engine's clear colour; the map's own hard edge at its last 256 m / 512 m chunk)
#   A     hatched edge onto blank paper    map_border_a.gd   Alex's idea: ink hachures pointing outward, clipped to a band
#   B     printed map sheet                map_border_b.gd   a ruled neatline, graticule ticks and numbers, scale bar, north arrow
#   C     contours continue                map_border_c.gd   the topographic layer's contours go on, fainter, fading to paper
#   D     sheet on a table                 map_border_d.gd   a deckle-edged sheet with a lifted shadow on a darker surface
#   E     hatched edge + distance legend   map_border_e.gd   THE GAME'S LOOK (the data's default): A's edge, B's ticks, numbers and scale
#                                          bar (map_border_legend.gd), without B's neatline or north arrow; the numbers INSIDE the map
#
#   map_view.border.set_option("B")     switch at run time ("none" removes it); the first call builds the option
#   map_view.border.option()            the letter now on
#   map_view.border.is_ready()          false while an option still has pieces to bake (only C bakes); never a blank or grey square
#                                       meanwhile: the paper is there at once and the ink arrives as it is baked
#   INKWOOD_MAP_BORDER=<letter>         sets the option for a run without touching the data
#
# MapView creates this node (one commented line in map_view.gd) and owns it. It adds NOTHING while the option is "none"; the data's default is E.
#
# WHERE IT SITS IN THE LAYER ORDER. Everything an option draws is a child of this node with z_index >= 1, so it draws ABOVE the
# map's chunks and the fog's topographic quads (z 0) wherever it is, and below the screen-space layers (the markers, the
# tracks, the roster, which are separate canvas layers). It is above rather than below the map because the map's chunks and
# the fog's quads reach 120 m past the 5,000 m bounds on the right and the bottom (they are whole squares), and the border
# must hide that sliver: the map ends at its bounds. Everything outside the map's rectangle is covered by the fill (paper,
# or the table), so the engine's clear colour never shows, at any zoom including the full zoom-out, where the strips beside
# the map are as wide as the window is.
#
# COST. Nothing here redraws ink per frame. The fill is four quads and a shader (A, B, C, D); A's hatch is that shader, in
# screen px, like the fog's inked edge; B's rules, ticks and lettering are a few dozen draw calls re-recorded when the
# camera moves; D's ragged edge and shadow are static geometry recorded once; C's contours are baked tiles (a bake, once
# per option and scale, on worker threads and read back without a stall), drawn as textured quads.

const CameraData = preload("res://scripts/world/camera_data.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Grain = preload("res://scripts/render/grain.gd")
const OptionA = preload("res://scripts/render/map_border_a.gd")
const OptionB = preload("res://scripts/render/map_border_b.gd")
const OptionC = preload("res://scripts/render/map_border_c.gd")
const OptionD = preload("res://scripts/render/map_border_d.gd")
const OptionE = preload("res://scripts/render/map_border_e.gd")

const DATA_PATH := "res://data/view/map_border.json"
const OPTIONS: Array[String] = ["none", "A", "B", "C", "D", "E"]

# The option's scripts, by letter (a RefCounted with build / frame / tick / is_ready / dispose).
const _IMPLS := {"A": OptionA, "B": OptionB, "C": OptionC, "D": OptionD, "E": OptionE}

var view: Node2D                 # the MapView that owns this node
var data: CameraData
var P: RenderParams
var errors: Array[String] = []

var px_per_m := 2.0
var map_rect_px := Rect2()       # the map's bounds, MAP px
var chunk_px := 1024

var _option := "none"
var _impl: RefCounted = null
var _xf := Transform2D()
var _zoom := -1.0
var _vp := Vector2.ZERO
var _grain: ImageTexture = null
var _stats := {"frames": 0, "frame_us": 0, "frame_us_max": 0, "builds": 0, "build_ms": 0.0}

func _init(map_view: Node2D) -> void:
	view = map_view
	name = "Border"
	process_priority = 100         # after the camera has moved this frame, as the fog layer's
	P = map_view.P
	data = CameraData.new(DATA_PATH)
	errors.append_array(data.errors)
	_sync_scale()

func _ready() -> void:
	var wanted := data.text("option")
	var env := OS.get_environment("INKWOOD_MAP_BORDER")
	if env != "":
		wanted = env
	if wanted != "none":
		set_option(wanted)

# --- the switch ------------------------------------------------------------------------------

# Turns an option on ("A".."D", any case) or off ("none"). Returns false for a name that is not one (and changes nothing).
func set_option(opt: String) -> bool:
	var key := opt.strip_edges()
	key = key.to_upper() if key.to_upper().length() == 1 else key.to_lower()
	if not OPTIONS.has(key):
		errors.append("map border: '%s' is not one of %s" % [opt, OPTIONS])
		push_error("MapBorder: " + errors[errors.size() - 1])
		return false
	if key == _option and (_impl != null or key == "none"):
		return true
	_dispose()
	_option = key
	if key == "none":
		return true
	_sync_scale()
	var t0 := Time.get_ticks_usec()
	_impl = (_IMPLS[key] as GDScript).new(self)
	_impl.build()
	_stats.builds = int(_stats.builds) + 1
	_stats.build_ms = (Time.get_ticks_usec() - t0) / 1000.0
	_zoom = -1.0                   # the next frame hands the option the camera
	return true

func option() -> String:
	return _option

func options() -> Array[String]:
	return OPTIONS

# The option's name as the data gives it ("Hatched edge onto blank paper"); "None: the map's own edge" for none.
func option_name(key: String) -> String:
	if key == "none":
		return "None: the map's own edge"
	return data.text("%s.name" % key.to_lower())

# Has every piece of the option been made? True with no option on.
func is_ready() -> bool:
	return _impl == null or bool(_impl.is_ready())

# Pieces of the option still to be baked (0 when ready).
func pending() -> int:
	return 0 if _impl == null else int(_impl.pending())

func stats() -> Dictionary:
	var out := _stats.duplicate()
	if _impl != null and _impl.has_method("stats"):
		out.merge(_impl.stats(), true)
	return out

# The option's own object (tests and the board read what it drew).
func impl() -> RefCounted:
	return _impl

func _dispose() -> void:
	if _impl != null:
		_impl.dispose()
		_impl = null
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_option = "none"

# --- the frame -------------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _impl == null or not is_inside_tree():
		return
	var t0 := Time.get_ticks_usec()
	if not is_equal_approx(float(view.px_per_m), px_per_m):
		# a new scale (MapView.set_px_per_m, a live knob): the option is made again for it
		var key := _option
		_dispose()
		set_option(key)
		if _impl == null:
			return
	var xf: Transform2D = view.get_global_transform_with_canvas()
	var vs := get_viewport().get_visible_rect().size
	var z := xf.get_scale().x
	if xf != _xf or not is_equal_approx(z, _zoom) or vs != _vp:
		_xf = xf
		_zoom = z
		_vp = vs
		_impl.frame(xf, z, vs)
	_impl.tick()
	var us := Time.get_ticks_usec() - t0
	_stats.frames = int(_stats.frames) + 1
	_stats.frame_us = us
	_stats.frame_us_max = maxi(int(_stats.frame_us_max), us)

func _exit_tree() -> void:
	if _impl != null:
		_impl.shutdown()

# --- what the options share --------------------------------------------------------------------

func _sync_scale() -> void:
	px_per_m = float(view.px_per_m)
	map_rect_px = view.map_rect()
	chunk_px = int(view.chunk_px)

# A colour role of the data file (a record whose value is {base, toward?, t?, lift?, chroma?, alpha?}), resolved against the
# map's palette: FogStyle's resolver, the one the fog's roles use. A bad role is an error in `errors`, never a default.
func role(path: String) -> Color:
	return FogStyle.resolve(data.value(path), P, errors)

# Every role record of the data file's options, as {path: Color}; the test resolves them all.
func all_role_paths() -> Array[String]:
	var out: Array[String] = []
	_collect_roles(data.root, "", out)
	return out

func _collect_roles(node: Dictionary, prefix: String, out: Array[String]) -> void:
	for k: String in node:
		if k.begins_with("_"):
			continue
		var path := k if prefix == "" else prefix + "." + k
		var child: Variant = node[k]
		if child is Dictionary:
			var d: Dictionary = child
			if d.has("value"):
				var v: Variant = d["value"]
				if v is Dictionary and (v as Dictionary).has("base"):
					out.append(path)
			else:
				_collect_roles(d, path, out)

# The grain tile the outside paper multiplies: the map's own (the provider's, chunk_px square, in phase with the chunks) with
# mipmaps, so a zoomed-out view averages it as the chunks' own mipmaps do; or, with no baked provider, one built from the seed.
func grain_texture() -> Texture2D:
	if _grain != null:
		return _grain
	var src: Variant = null
	if view.get("provider") != null:
		src = (view.get("provider") as Object).get("_grain")
	var img: Image = null
	if src is ImageTexture:
		img = (src as ImageTexture).get_image()
	if img == null or img.is_empty():
		var tile := int(data.num("paper.grain_tile_px"))
		img = Grain.build_image(Vector2i(tile, tile), int(view.seed_value))
	else:
		data.num("paper.grain_tile_px")   # (read, so the data holds nothing dead: it is the fallback's size)
	img.generate_mipmaps()
	_grain = ImageTexture.create_from_image(img)
	return _grain

# The size of the grain tile in px (what the shader divides the world position by).
func grain_tile_px() -> float:
	var t := grain_texture()
	return float(t.get_width())

# Seconds-free helpers for the options: screen px per map px at the last frame.
func zoom() -> float:
	return _zoom

# metres -> map px
func m_to_px(m: float) -> float:
	return m * px_per_m
