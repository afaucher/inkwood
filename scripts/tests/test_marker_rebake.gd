extends "res://scripts/test_support/test_case.gd"

# A MARKER'S ART IS NOT RE-BAKED IN THE MIDDLE OF A ZOOM (builder CAM, 2026-10-11, decision playtest-3 zoom_judder; PROPOSED, data
# unit_art.rebake_settle_ms, rebake_hard_ratio, rebake_offscreen_margin_px). One wheel notch scales the view by 1.15, which is
# unit_art.rebake_ratio, so every notch re-baked every marker's art in the frame it happened: 10 ms a tank colour, 20 to 50 for
# the bridge, 60 to 250 for the cruiser, a frozen frame of 40 to 180 ms per notch (windowed, tmp/cam/probe_follow.csv). Now:
#
#   1. inside unit_art.rebake_ratio the art is kept, as always
#   2. past it, while the scale is still changing (it changed less than rebake_settle_ms ago) and the art held is within
#      rebake_hard_ratio of the wanted scale, the marker keeps it (drawn scaled) and asks again every frame
#   3. when the scale has been still for rebake_settle_ms it is baked: the question is answered "no wait"
#   4. past rebake_hard_ratio it is baked at once, whatever the clock
#   5. a marker more than rebake_offscreen_margin_px off the screen keeps its art, however far off, and bakes it when it is back
#   6. rebake_settle_ms 0 is the old behaviour: past rebake_ratio it bakes at once
#
# Headless cannot bake (UnitMarkerArt.can_bake), so the held art is a stand-in and "baked" is read as "no longer deferred".

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarker = preload("res://scripts/ui/unit_marker.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const PPM := 4.0

var _st: UiStyle
var _m: UnitMarker
var _held: UnitMarkerArt.Art
var _k := 1.0

func setup(_main) -> void:
	_st = UiStyle.new()
	if not check(_st.ok(), "the UI style loads: %s" % str(_st.errors)):
		finish()
		return
	var settle := _st.num("unit_art.rebake_settle_ms")
	var hard := _st.num("unit_art.rebake_hard_ratio")
	var ratio := _st.num("unit_art.rebake_ratio")
	check(settle > 0.0 and hard > ratio and _st.num("unit_art.rebake_offscreen_margin_px") >= 0.0, "the data is there: settle %.0f ms, hard ratio %.2f over rebake_ratio %.2f" % [settle, hard, ratio])
	var shadows := Node2D.new()
	add_child(shadows)
	_m = UnitMarker.new()
	add_child(_m)
	_m.setup(_st, "t1", "tank", 6.0, Color(0.7, 0.2, 0.2), shadows)
	_k = _st.num("marker.true_scale")
	_held = UnitMarkerArt.Art.new()
	_held.ppm = PPM * _k
	_held.extent_m = 4.0
	var on := Vector2(40.0, 40.0)

	# 1. Inside the ratio: nothing to do.
	_m.art = _held
	_m.set_pose(on, 0.0, PPM, Vector2.ZERO)
	check(not _m.is_art_deferred() and _m.art == _held, "1. at the scale the art was baked for: nothing deferred, art kept")
	_m.set_pose(on, 0.0, PPM * ratio * 0.99, Vector2.ZERO)
	check(not _m.is_art_deferred() and _m.art == _held, "1. inside rebake_ratio: nothing deferred, art kept")

	# 2. A zoom under way: past the ratio, within the hard ratio, the scale just changed: wait.
	_m.set_pose(on, 0.0, PPM * (ratio + hard) * 0.5, Vector2.ZERO)
	check(_m.is_art_deferred(), "2. past rebake_ratio and inside the hard ratio while the zoom moves: the bake waits")
	check(_m.art == _held, "2. and the art held stays (it is drawn scaled meanwhile)")
	_m.set_pose(on, 0.0, PPM * (ratio + hard) * 0.5, Vector2.ZERO)
	check(_m.is_art_deferred(), "2. asked again with the scale unchanged and the clock not run out: still waiting")

	# 3. The zoom settles.
	_m._scale_changed_ms -= int(settle) + 50
	_m.set_pose(on, 0.0, PPM * (ratio + hard) * 0.5, Vector2.ZERO)
	check(not _m.is_art_deferred(), "3. rebake_settle_ms with the scale still: it is baked now (no longer deferred)")

	# 4. Far from the art held: at once.
	_m.art = _held
	_m.set_pose(on, 0.0, PPM, Vector2.ZERO)
	_m.set_pose(on, 0.0, PPM * hard * 1.3, Vector2.ZERO)
	check(not _m.is_art_deferred(), "4. past the hard ratio the art is baked at once, the zoom still moving")
	_m.set_pose(on, 0.0, PPM / (hard * 1.3), Vector2.ZERO)
	check(not _m.is_art_deferred(), "4. and the same shrinking")

	# 5. Off the screen.
	_m.art = _held
	_m.set_pose(on, 0.0, PPM, Vector2.ZERO)
	var vr := _m.get_viewport_rect()
	var off := vr.end + Vector2(5000.0, 5000.0)
	_m.set_pose(off, 0.0, PPM * hard * 3.0, Vector2.ZERO)
	check(_m.is_art_deferred() and _m.art == _held, "5. far off the screen it keeps its art, even 3 x the hard ratio away")
	_m.set_pose(off, 0.0, PPM * hard * 3.0, Vector2.ZERO)
	_m._scale_changed_ms -= int(settle) + 50
	_m.set_pose(off, 0.0, PPM * hard * 3.0, Vector2.ZERO)
	check(_m.is_art_deferred(), "5. and the zoom settling does not bake it: nobody sees it")
	_m.set_pose(on, 0.0, PPM * hard * 3.0, Vector2.ZERO)
	check(not _m.is_art_deferred(), "5. back on the screen it is baked (it is far off the art held)")
	var edge := vr.end + Vector2(_st.num("unit_art.rebake_offscreen_margin_px") * 0.5, 0.0)
	_m.art = _held
	_m.set_pose(on, 0.0, PPM, Vector2.ZERO)
	_m.set_pose(edge, 0.0, PPM * (ratio + hard) * 0.5, Vector2.ZERO)
	check(_m.is_art_deferred(), "5. just past the screen's edge, inside the margin, it is treated as on screen and waits for the zoom like any marker")
	_m._scale_changed_ms -= int(settle) + 50
	_m.set_pose(edge, 0.0, PPM * (ratio + hard) * 0.5, Vector2.ZERO)
	check(not _m.is_art_deferred(), "5. and is baked when the zoom has settled")

	# 6. The switch.
	_st.set_num("unit_art.rebake_settle_ms", 0.0)
	_m.art = _held
	_m.set_pose(on, 0.0, PPM, Vector2.ZERO)
	_m.set_pose(on, 0.0, PPM * ratio * 1.2, Vector2.ZERO)
	check(not _m.is_art_deferred(), "6. rebake_settle_ms 0: past rebake_ratio it is baked at once, as it always was")
	_m.set_pose(off, 0.0, PPM * ratio * 3.0, Vector2.ZERO)
	check(not _m.is_art_deferred(), "6. and off the screen too")
	finish()
