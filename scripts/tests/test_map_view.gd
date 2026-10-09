extends "res://scripts/test_support/test_case.gd"

# THE MAP VIEW'S HEADLESS CHECKS (Track V: scripts/render/map_view.gd,
# chunk_baker.gd, chunk_*_provider.gd). Baking itself renders and needs a
# windowed run (scripts/render/map_view_shot.gd); what decides WHAT a chunk
# holds and WHERE things land on screen is checked here:
#
#   1. CHUNK DETERMINISM. A chunk's content is the same whatever was asked
#      for before it -- the border rules included. For both providers, a
#      fresh provider asked for chunk X first, and another asked for X's
#      neighbours (and their neighbours) first, give X the same objects:
#      same kinds, seeds, positions, radii.
#   2. METRES <-> SCREEN. A MapView in the tree, its camera current (baking
#      off: headless draws nothing): world_to_screen and screen_to_world
#      invert each other to 1e-3 m at several zooms and positions; the point
#      the camera looks at is the viewport centre; and after a change of
#      scale (set_px_per_m, the demo knob) the camera still looks at the same
#      metres.

const RenderParams = preload("res://scripts/world/render_params.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const ChunkSceneProvider = preload("res://scripts/render/chunk_scene_provider.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")

const SEED := 20261009

var _view: Node2D
var _frames := 0
var _phase := 0

func setup(main) -> void:
	timeout_seconds = 180.0
	var P := RenderParams.new()
	if not check(P.ok(), "render params load: %s" % ", ".join(P.errors)):
		finish()
		return
	var cfg := MapView.load_config(P.source_path)
	check(not cfg.is_empty(), "render_defaults.json has a map_view section")
	var t0 := Time.get_ticks_usec()
	_check_scene_determinism(cfg)
	_check_terrain_determinism(cfg)
	print("determinism checks: %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	_view = MapView.new(SEED, Rect2(0, 0, 5000, 5000), 2.0, "scene", RenderParams.new())
	_view.bake_enabled = false
	_view.input_enabled = false
	main.add_child(_view)

func _physics_process(_delta: float) -> void:
	if _view == null or _finished:
		return
	_frames += 1
	if _frames < 3:
		return
	match _phase:
		0:
			_view.set_zoom(1.0)
			_view.look_at_m(Vector2(1234.5, 2345.25))
			_phase = 1
			_frames = 0
		1:
			_check_round_trip("zoom 1")
			_view.set_zoom(0.3)
			_view.look_at_m(Vector2(4000.0, 900.0))
			_phase = 2
			_frames = 0
		2:
			_check_round_trip("zoom 0.3")
			_view.set_px_per_m(4.0)
			_phase = 3
			_frames = 0
		3:
			eq(_view.px_per_m, 4.0, "set_px_per_m changes the scale")
			_check_round_trip("zoom 0.3 at 4 px/m")
			_check_centre(Vector2(4000.0, 900.0), "the camera stays on the same metres across a scale change")
			_view.queue_free()
			_view = null
			finish()

func _check_round_trip(label: String) -> void:
	var worst := 0.0
	for p: Vector2 in [Vector2(0, 0), Vector2(1234.5, 2345.25), Vector2(4999.0, 17.0), Vector2(2500.0, 2500.0), Vector2(-50.0, 6000.0)]:
		var s: Vector2 = _view.world_to_screen(p)
		var back: Vector2 = _view.screen_to_world(s)
		worst = maxf(worst, back.distance_to(p))
	check(worst < 1e-3, "%s: screen_to_world(world_to_screen(p)) == p (worst %s m)" % [label, String.num_scientific(worst)])
	var z: float = _view.get_zoom()
	var a: Vector2 = _view.world_to_screen(Vector2(100.0, 100.0))
	var b: Vector2 = _view.world_to_screen(Vector2(110.0, 100.0))
	near(b.x - a.x, 10.0 * _view.px_per_m * z, 1e-3, "%s: 10 m is px_per_m x zoom x 10 screen px" % label)

func _check_centre(p_m: Vector2, label: String) -> void:
	var vs: Vector2 = _view.get_viewport_rect().size
	var s: Vector2 = _view.world_to_screen(p_m)
	check(s.distance_to(vs * 0.5) < 0.01, "%s (%s vs viewport centre %s)" % [label, s, vs * 0.5])

# --- determinism -------------------------------------------------------------------------

static func _sig(list: Array) -> Array:
	var out: Array = []
	for o: Dictionary in list:
		out.append("%s|%d|%.6f|%.6f|%.6f" % [o.kind, int(o.seed), float(o.x), float(o.y), float(o.get("r", o.get("s", 0.0)))])
	out.sort()
	return out

func _check_scene_determinism(cfg: Dictionary) -> void:
	var X := Vector2i(4, 5)
	var a := ChunkSceneProvider.new(SEED, RenderParams.new(), cfg)
	var first: Dictionary = a.objects(X)
	var b := ChunkSceneProvider.new(SEED, RenderParams.new(), cfg)
	for c: Vector2i in [Vector2i(5, 6), Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4), Vector2i(3, 5), Vector2i(4, 6)]:
		b.objects(c)
	var later: Dictionary = b.objects(X)
	for k: String in ["trees", "props", "structs"]:
		check(_sig(first[k]) == _sig(later[k]), "scene provider: chunk %s's %s are the same whatever was generated first (%d vs %d)" % [X, k, first[k].size(), later[k].size()])
	check((first.trees as Array).size() > 0, "scene provider: the test chunk has trees")
	# Neighbours never overlap each other (the border rule): X against its W neighbour.
	var w: Dictionary = b.objects(X + Vector2i(-1, 0))
	var clash := 0
	for o: Dictionary in first.trees:
		for p: Dictionary in w.trees:
			var rr: float = float(o.r) * 0.72 + float(p.r) * 0.72
			if Vector2(o.x, o.y).distance_squared_to(Vector2(p.x, p.y)) < rr * rr:
				clash += 1
	eq(clash, 0, "scene provider: no tree of chunk %s overlaps one of its west neighbour" % X)

func _check_terrain_determinism(cfg: Dictionary) -> void:
	var X := Vector2i(4, 4)
	var a := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	if not check(a.ok(), "terrain provider loads: %s" % ", ".join(a.errors)):
		return
	var first: Array = a.chunk_content(X).trees
	var b := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	b.chunk_content(Vector2i(5, 5))
	b.chunk_content(Vector2i(3, 4))
	var later: Array = b.chunk_content(X).trees
	check(first.size() > 0, "terrain provider: the test chunk has trees")
	check(_sig(first) == _sig(later), "terrain provider: chunk %s's trees are the same whatever was generated first (%d vs %d)" % [X, first.size(), later.size()])
