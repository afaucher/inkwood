extends "res://scripts/test_support/test_case.gd"

# HATCHING STAYS INSIDE ITS OUTLINE (fix, 2026-10-11). UnitMarkerArt.hatch_lines (the tank's track links and grilles, the
# mobile AA's, the radio tower's platform, the military complex's roofs and ruins) and FxRuin._hatch_in (the tower's
# platform and hut, standing, lying and in its remains) clip parallel lines to an outline. Both once clipped with
# Geometry2D.clip_polyline_with_polygon, which is a DIFFERENCE: every line was drawn OUTSIDE its shape and none inside
# (the tank's links stuck out past its tracks; the tracks and grilles were bare). intersect_polyline_with_polygon is
# the inside.
#
#   1. hatch_lines on a square and on a U (concave: a line crosses both arms), across and on a diagonal
#   2. hatch_lines on the tank's own track and grille outlines, built as the bake builds them, at three scales
#   3. FxRuin._hatch_in on the U and on the tower's platform as draw_standing places it
#
# Every recorded line is sampled along its length: no sample may lie outside the outline (EPS px of slack on the
# outline itself, where every part ends), and the hatch must COVER the shape -- its length near area / spacing -- so
# an empty hatch cannot pass. Headless: a RecordingCanvas keeps the polylines, nothing is rendered.
#
# A sentinel counts what ran: a dependency that does not compile, or a runtime error, stops a test coroutine in silence.

const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const RecordingCanvas = preload("res://scripts/test_support/recording_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxRuin = preload("res://scripts/fx/fx_ruin.gd")

const SAMPLES := 16    # samples per recorded segment
const EPS := 0.05      # px: a sample this close to the outline counts as on it

func setup(_main) -> void:
	for path: String in ["res://scripts/ui/unit_marker_art.gd", "res://scripts/fx/fx_ruin.gd", "res://scripts/test_support/recording_canvas.gd"]:
		check((load(path) as GDScript).can_instantiate(), "%s compiles" % path)
	var ran := 0
	if _shapes() == true:
		ran += 1
	if _tank() == true:
		ran += 1
	if _ruin() == true:
		ran += 1
	eq(ran, 3, "every part ran to its end")
	finish()

# 1. hatch_lines on a square and a U, across and diagonally; no jitter, so the length is area / spacing within a line or two.
func _shapes() -> bool:
	var ink := UnitMarkerArt.ink_consts(UiStyle.shared())
	var square := PackedVector2Array([Vector2(10, 10), Vector2(70, 10), Vector2(70, 50), Vector2(10, 50)])
	var u := PackedVector2Array([Vector2(10, 10), Vector2(25, 10), Vector2(25, 60), Vector2(55, 60), Vector2(55, 10), Vector2(70, 10),
		Vector2(70, 80), Vector2(10, 80)])
	for shape: Array in [["square", square], ["U", u]]:
		var o: PackedVector2Array = shape[1]
		for dir: Vector2 in [Vector2(1, 0), Vector2(1, 1).normalized()]:
			var rec := RecordingCanvas.new(Vector2i(96, 96))
			UnitMarkerArt.hatch_lines(rec, ink, o, dir, 2.0, {"rng": Mulberry32.new(7)})
			var m := _measure(rec.lines, o)
			var want := absf(_area(o)) / 2.0
			var what := "hatch_lines on the %s along (%.2f, %.2f)" % [shape[0], dir.x, dir.y]
			check(m.y < 0.01, "%s: nothing outside it (%.2f px of line outside)" % [what, m.y])
			check(absf(m.x - want) < 0.1 * want, "%s: covers it (%.0f px of line inside, area / spacing %.0f)" % [what, m.x, want])
			rec.discard()
	return true

# 2. The tank's track links and grilles: the outlines the bake draws (wobbled, in px), the spacing and options it passes.
func _tank() -> bool:
	var st: UiStyle = UiStyle.shared() as UiStyle
	var M := UnitMarkerArt.model_for(st, "tank")
	var ink := UnitMarkerArt.ink_consts(st)
	var margin: float = st.num("unit_art.bake_margin_px")
	var box := UnitMarkerArt.extent_box(M)
	var n_shapes := 0
	var inside := 0.0
	var want := 0.0
	var worst := 0.0
	for ppm: float in [3.8, 8.0, 14.0]:
		var size := Vector2i(ceili(box.size.x * ppm + 2.0 * margin), ceili(box.size.y * ppm + 2.0 * margin))
		var V := UnitMarkerArt.View.new(-box.position.x * ppm + margin, -box.position.y * ppm + margin, ppm, 0.0)
		var g := InkCanvas.new(size)
		var pn := UnitMarkerArt.Pen.new(g, V, ink, M.seed + 5)
		var along := V.tv(Vector2(1.0, 0.0))
		var shapes: Array = []
		for t: PackedVector2Array in M.G.tracks:
			shapes.append([UnitMarkerArt._path(pn, t, {"fill": ink.rock, "weight": 0.0}), maxf(1.5, 0.12 * ppm), {"rng": UnitMarkerArt._rng(pn), "jit": 0.25}])
		for gr: PackedVector2Array in M.G.grilles:
			shapes.append([UnitMarkerArt._path(pn, gr, {"weight": 0.6, "alpha": 0.8}), maxf(1.5, 0.13 * ppm), {"rng": UnitMarkerArt._rng(pn)}])
		for s: Array in shapes:
			var o: PackedVector2Array = s[0]
			var rec := RecordingCanvas.new(size)
			UnitMarkerArt.hatch_lines(rec, ink, o, along, float(s[1]), s[2])
			var m := _measure(rec.lines, o)
			inside += m.x
			want += absf(_area(o)) / float(s[1])
			worst = maxf(worst, m.y)
			n_shapes += 1
			rec.discard()
		g.discard()
	eq(n_shapes, 12, "two tracks and two grilles at three scales")
	check(worst < 0.01, "the tank's link and grille hatching stays inside each outline (worst: %.2f px of line outside)" % worst)
	check(inside > 0.7 * want, "and covers them (%.0f px of line inside, area / spacing %.0f)" % [inside, want])
	return true

# 3. The ruin's hatch: the U, and the tower's platform as draw_standing places it.
func _ruin() -> bool:
	var k := FxRuin.make_ink(FxStyle.new(FxData.new()))
	var u := PackedVector2Array([Vector2(10, 10), Vector2(25, 10), Vector2(25, 60), Vector2(55, 60), Vector2(55, 10), Vector2(70, 10),
		Vector2(70, 80), Vector2(10, 80)])
	var M := FxRuin.tower_model(UiStyle.shared().scene_seed, 0)
	var plat := FxRuin._tpp(M.G["platform"], Vector2(48, 48), 6.0, PI / 2.0)
	for shape: Array in [["U", u], ["tower's platform", plat]]:
		var o: PackedVector2Array = shape[1]
		var rec := RecordingCanvas.new(Vector2i(96, 96))
		FxRuin._hatch_in(rec, k, o, 2.0, 0.45, 0.45)
		var m := _measure(rec.lines, o)
		var want := absf(_area(o)) / 2.0
		check(m.y < 0.01, "FxRuin's hatch on the %s: nothing outside it (%.2f px of line outside)" % [shape[0], m.y])
		check(absf(m.x - want) < 0.15 * want, "FxRuin's hatch on the %s: covers it (%.0f px of line inside, area / spacing %.0f)" % [shape[0], m.x, want])
		rec.discard()
	return true

# Vector2(length inside, length outside) of the recorded lines against outline o, from SAMPLES points per segment.
func _measure(lines: Array[PackedVector2Array], o: PackedVector2Array) -> Vector2:
	var out := Vector2.ZERO
	for part: PackedVector2Array in lines:
		for i in range(1, part.size()):
			var a := part[i - 1]
			var b := part[i]
			var step := a.distance_to(b) / SAMPLES
			for s in SAMPLES:
				var q := a.lerp(b, (s + 0.5) / SAMPLES)
				if Geometry2D.is_point_in_polygon(q, o) or _to_outline(q, o) < EPS:
					out.x += step
				else:
					out.y += step
	return out

func _to_outline(q: Vector2, o: PackedVector2Array) -> float:
	var best := INF
	for i in o.size():
		best = minf(best, q.distance_to(Geometry2D.get_closest_point_to_segment(q, o[i], o[(i + 1) % o.size()])))
	return best

func _area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		s += p[i].cross(p[(i + 1) % p.size()])
	return s * 0.5
