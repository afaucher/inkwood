extends "res://scripts/test_support/test_case.gd"

# THE FOG-EDGE BOARD'S DATA SWITCH (builder BF, 2026-10-14; backlog B15; every look is PROPOSED, Alex has not picked), headless:
#
#   DEFAULT   data/view/fog.json edge.inked.look is "e0" and e0 overrides nothing: the compositor's uniforms are exactly
#             today's (value noise, a hard cut, one octave of 2.5 px at 0.018, random tick lengths) and the line-of-sight
#             shape pass takes the nearest ray (viewshed.interp false); the shader files' own defaults say the same.
#   LOOKS     every row of edge.inked.looks is applied by FogLayer.set_look without an error: its keys are known, its
#             values reach the compositor's uniforms, an unknown row is refused and "" returns to the data's look; the
#             range the mask holds still covers the widest effect of every look.
#   INTERP    FogLayer.set_los_interp / viewshed.interp reach the shape shader's materials (the draw is the windowed
#             board's: scripts/render/boards/fog_edge_board_shot.gd).

const Terrain = preload("res://scripts/world/terrain.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")

const SEED := 20261009

func setup(_main) -> void:
	var terrain := Terrain.new(SEED)
	if not check(terrain.ok(), "terrain loads: %s" % [terrain.errors]):
		finish()
		return
	var d := CameraData.new(CameraData.FOG_PATH)
	var layer := FogLayer.new()
	layer.setup(terrain, null, d)
	check(layer.ok(), "the fog layer loads cleanly: %s %s" % [layer.errors, d.errors])
	var mat: ShaderMaterial = layer._mat

	# DEFAULT
	eq(layer.edge_look, "e0", "the working look is e0 (today)")
	var looks: Dictionary = d.dict("edge.inked.looks")
	check(looks.has("e0") and (looks["e0"] as Dictionary).is_empty(), "e0 overrides nothing")
	_expect_today(mat, "after setup")
	check(not layer.los_interp, "viewshed.interp is false (the nearest ray)")
	check(float(d.num("viewshed.interp_spread")) > 0.0, "viewshed.interp_spread is positive")
	var src := FileAccess.get_file_as_string("res://scripts/render/fog_composite.gdshader")
	for line: String in ["uniform int wobble_noise = 0;", "uniform float cut_soft = 0.0;", "uniform float wobble2_px = 0.0;", "uniform int hatch_len_mode = 0;"]:
		check(src.contains(line), "fog_composite.gdshader defaults to today: %s" % line)
	var los_src := FileAccess.get_file_as_string("res://scripts/render/fog_los_shape.gdshader")
	check(los_src.contains("uniform bool interp = false;"), "fog_los_shape.gdshader defaults to the nearest ray")

	# LOOKS
	check(not layer.set_look("nonsense"), "an unknown look is refused")
	var expect := {
		"e0": {"wobble_noise": 0, "cut_soft": 0.0, "wobble2_px": 0.0, "hatch_len_mode": 0, "wobble_px": 2.5, "wobble_freq": 0.018},
		"e1": {"wobble_noise": 1, "cut_soft": 0.0, "wobble2_px": 0.0, "hatch_len_mode": 0, "wobble_px": 2.5, "wobble_freq": 0.018},
		"e2": {"wobble_noise": 1, "cut_soft": 2.5, "wobble2_px": 0.0, "hatch_len_mode": 0, "wobble_px": 2.5, "wobble_freq": 0.018},
		"e3": {"wobble_noise": 1, "cut_soft": 2.5, "wobble2_px": 0.8, "hatch_len_mode": 0, "wobble_px": 2.5, "wobble_freq": 0.009},
		"e4": {"wobble_noise": 1, "cut_soft": 2.5, "wobble2_px": 0.0, "hatch_len_mode": 1, "wobble_px": 2.5, "wobble_freq": 0.018},
		"e5": {"wobble_noise": 1, "cut_soft": 2.5, "wobble2_px": 0.8, "hatch_len_mode": 1, "wobble_px": 2.5, "wobble_freq": 0.009},
	}
	for id: String in looks:
		check(expect.has(id), "look %s is one the test knows (add its row to the test's table)" % id)
	for id: String in expect:
		var errs_before := layer.errors.size()
		check(layer.set_look(id), "set_look(%s) is accepted" % id)
		eq(layer.edge_look, id, "the look in force is %s" % id)
		check(layer.errors.size() == errs_before, "look %s adds no error: %s" % [id, layer.errors.slice(errs_before)])
		var row: Dictionary = expect[id]
		for k: String in row:
			var got: Variant = mat.get_shader_parameter(k)
			check(is_equal_approx(float(got), float(row[k])), "look %s: %s is %s (got %s)" % [id, k, row[k], got])
	check(layer.set_look(""), "an empty id returns to the data's look")
	eq(layer.edge_look, "e0", "the data's look is e0 again")
	_expect_today(mat, "after the looks")

	# INTERP
	layer.set_los_interp(true)
	check(layer.los_interp, "set_los_interp(true) is kept")
	layer.set_los_interp(false)
	check(not layer.los_interp, "set_los_interp(false) is kept")
	check(d.unused().is_empty(), "every field of fog.json is read; unused: %s" % [d.unused()])
	layer.free()
	finish()

func _expect_today(mat: ShaderMaterial, when: String) -> void:
	eq(int(mat.get_shader_parameter("wobble_noise")), 0, "%s: value noise" % when)
	check(is_zero_approx(float(mat.get_shader_parameter("cut_soft"))), "%s: the hard cut" % when)
	check(is_zero_approx(float(mat.get_shader_parameter("wobble2_px"))), "%s: one octave" % when)
	eq(int(mat.get_shader_parameter("hatch_len_mode")), 0, "%s: random tick lengths" % when)
	check(is_equal_approx(float(mat.get_shader_parameter("wobble_px")), 2.5), "%s: wobble 2.5 px" % when)
	check(is_equal_approx(float(mat.get_shader_parameter("wobble_freq")), 0.018), "%s: wobble 0.018 per px" % when)
