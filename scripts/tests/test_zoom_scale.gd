extends "res://scripts/test_support/test_case.gd"

# THE PLANES' SCALE FOLLOWS THE ZOOM IN THE SAME CALL (builder CAM, 2026-10-11, decision playtest-3 zoom_judder; the fix is
# PROPOSED). The sandbox keeps every unit's drawn size by setting marker.true_scale from the zoom
# (Sandbox._update_plane_scale). It did that in its own _process (priority 50), AFTER the marker layer (priority 0) had posed
# every marker for the frame, so below the zoom where the minimum-size floor binds (view.plane_min_px) each wheel notch drew every
# unit 15% too big for one frame and then snapped it back: a tank 21.1 px for one frame and 18.3 px after
# (tmp/cam/probe_low.csv, windowed). Now the camera's view_changed signal calls it, so the scale is the zoom's at the moment the zoom
# changes and no frame sees one without the other.
#
# Headless: the sandbox built through the menu's own Local path (the old flight toy scenario, whose 36 px planes and 14 px floor make
# the floor bind below zoom 0.39), the camera set in code, and marker.true_scale read back with no frame in between.

const UiStyle = preload("res://scripts/ui/ui_style.gd")

func setup(main) -> void:
	timeout_seconds = 90.0
	var saved := DebugSettings.get_choice("scenario")
	DebugSettings.set_choice("scenario", 1)   # "sandbox": the flight toy (planes, so the plane rule has its reference size)
	main.get_window().size = Vector2i(1280, 720)
	main.setup_menu()
	var built: bool = main.start_sandbox()
	if not check(built and main.sandbox != null, "Local builds the sandbox"):
		DebugSettings.set_choice("scenario", saved)
		finish()
		return
	var sb: Node = main.sandbox
	var st: UiStyle = UiStyle.shared() as UiStyle
	var ctl = sb.ctl
	var ppm: float = sb.map_view.px_per_m
	var floor_px: float = sb.plane_min_px
	var plane_px: float = sb.plane_px
	var ref: float = sb._ref_size
	check(plane_px > 0.0 and floor_px > 0.0 and ref > 0.0, "the plane rule's numbers are there (plane_px %.1f, floor %.1f, reference %.1f m)" % [plane_px, floor_px, ref])
	var floor_zoom := floor_px / plane_px   # below this the floor binds: k = floor_px / (ref x ppm x zoom), a size that does not change with the zoom
	var worst := 0.0
	var checked := 0
	# Zooms that move the scale by more than its 0.4% update threshold each, in and out, the floor binding all the way.
	for z: float in [0.3, 0.26, 0.22, 0.19, 0.16, 0.13, 0.1, 0.13, 0.19, 0.26, 0.33]:
		ctl.set_view(ctl.center(), z)
		var zz: float = ctl.zoom_level()
		if zz >= floor_zoom:
			continue
		var want: float = floor_px / (ref * ppm * zz)
		var got: float = st.num("marker.true_scale")
		worst = maxf(worst, absf(got - want) / want)
		checked += 1
	check(checked >= 8, "most of the zooms tried were under the floor's zoom %.3f (%d)" % [floor_zoom, checked])
	check(worst < 1e-6, "the planes' scale (marker.true_scale) is the floor rule's at the zoom the instant it is set, no frame between (worst relative error %s over %d zooms; float32 transforms, so 1e-6 is the bar: a frame of lag is 15%%)" % [String.num(worst, 12), checked])
	# And through the wheel, the way the player does it.
	ctl.input_enabled = true
	ctl.set_view(ctl.center(), 0.15)
	var before: float = st.num("marker.true_scale")
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.position = Vector2(700.0, 300.0)
	ev.factor = 1.0
	ctl._unhandled_input(ev)
	var z2: float = ctl.zoom_level()
	var want2: float = floor_px / (ref * ppm * z2)
	check(absf(st.num("marker.true_scale") - want2) < want2 * 1e-6 and absf(before - want2) > want2 * 0.05, "a wheel notch changes the scale with the zoom in the same call (%.4f before, %.4f after)" % [before, st.num("marker.true_scale")])
	main.stop_sandbox()
	DebugSettings.set_choice("scenario", saved)
	finish()
