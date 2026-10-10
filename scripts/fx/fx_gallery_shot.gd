extends SceneTree

# A look at the effect generators on plain paper (Track X). WINDOWED ONLY:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/fx/fx_gallery_shot.gd -- [what=puffs|bursts] [out=tmp/fx] [ppm=4]
#
# puffs.png   a row per smoke option (A..D), three tones across, every variant, then at the planning scale
# bursts.png  a row per crash option (A..D): the flipbook frames of the ground burst, then the
#             flame, a piece of debris, the scars and an ember; the same at the planning scale

const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")

var opts: Dictionary = {}
var _vp: SubViewport

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[fx-gallery] needs a windowed run")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _run() -> void:
	var out_dir := str(opts.get("out", "tmp/fx"))
	out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var st: FxStyle = FxStyle.shared()
	if not st.ok():
		printerr("[fx-gallery] style errors: ", st.errors)
		quit(1)
		return
	var ppm := float(opts.get("ppm", "4"))
	var size := Vector2i(int(opts.get("w", "1500")), int(opts.get("h", "760")))
	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)
	var bg := ColorRect.new()
	bg.color = st.palette["paper"]
	bg.size = Vector2(size)
	_vp.add_child(bg)
	var node := Node2D.new()
	_vp.add_child(node)
	var what := str(opts.get("what", "puffs"))
	if what == "puffs":
		_puffs(st, node, ppm)
	else:
		_bursts(st, node, ppm)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var path := out_dir.path_join("%s.png" % what)
	img.save_png(path)
	print("[fx-gallery] saved ", path)
	quit(0)

func _sprite(node: Node2D, tex: Texture2D, pos: Vector2) -> void:
	if tex == null:
		return
	var holder := Sprite2D.new()
	holder.texture = tex
	holder.centered = false
	holder.position = pos
	node.add_child(holder)

func _puffs(st: FxStyle, node: Node2D, ppm: float) -> void:
	var data: FxData = FxData.shared()
	var y := 10.0
	for s_ppm in [ppm, ppm * 0.4]:
		for name: String in data.smoke_option_names():
			var o := data.smoke_option(name)
			var ps := FxPuff.bake_set(st, o, s_ppm, 9.0)
			var x := 10.0
			for tone in FxPuff.TONES:
				for v in ps.variants:
					var tex: Texture2D = (ps.tex[tone] as Array)[v]
					_sprite(node, tex, Vector2(x, y))
					x += tex.get_width() + 6.0
				x += 24.0
			y += float(ps.origin[2].y * 2.0) + 8.0
		y += 20.0

func _bursts(st: FxStyle, node: Node2D, ppm: float) -> void:
	var data: FxData = FxData.shared()
	var y := 10.0
	for s_ppm in [ppm, ppm * 0.4]:
		for name: String in data.crash_option_names():
			var co := data.crash_option(name)
			var b := FxData.grp(co, "burst")
			var R := FxData.f(b, "radius_frac") * 9.0
			var bs := FxBurst.bake_burst(st, b, R, s_ppm, true, 777)
			var x := 6.0
			var row_h := bs.origin.y * 2.0
			for fr in bs.frames:
				_sprite(node, fr["tex"], Vector2(x, y))
				x += bs.origin.x * 1.5
			var parts := FxBurst.bake_parts(st, co, 9.0, s_ppm, null, 99)
			x += 10.0
			for t in parts.flame:
				_sprite(node, t, Vector2(x, y + 20.0) - parts.flame_origin * 0.0)
				x += float((t as Texture2D).get_width()) + 4.0
			for k in parts.shards.size():
				_sprite(node, parts.shards[k], Vector2(x, y + 40.0))
				x += float((parts.shards[k] as Texture2D).get_width()) + 4.0
			_sprite(node, parts.ember, Vector2(x, y + 40.0))
			x += 20.0
			for t in parts.scars:
				_sprite(node, t, Vector2(x, y))
				x += float((t as Texture2D).get_width()) * 0.8
			y += row_h + 6.0
		y += 20.0
