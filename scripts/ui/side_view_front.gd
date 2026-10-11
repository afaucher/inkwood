extends RefCounted

# THE FRONT STRIP of the side view panel (decision side-view-views, 2026-10-11). ALEX: "I want to be able to select between top, front &
# side. I think this solves the 'cone but only upwards' problem." The PROJECTION below is PROPOSED by the builder
# (data/ui/ui.json side_view.front says why).
#
# WHAT IT IS. Looking along the nose of the selected FRIENDLY unit: the vertical plane across its heading through the unit, x the
# lateral offset (right is right), y the height (up is up), one scale for both axes. A weapon's cone is the set of directions it
# reaches -- an ellipse in azimuth and elevation about (mount, elevation), as combat.gd tests it -- out to its effective range and
# then the fade. A point t metres out along the direction (azimuth a, elevation e), the airframe pitched by p, lands at
#
#     t (cos e sin a,  cos e cos a sin p + sin e cos p)
#
# on the plane. Every point of a cone's solid is on a ray from the apex, so the shape is STAR-SHAPED about the unit: for each
# angle round the unit, the strip reaches as far out as the longest such point (the range times the length of the direction's part
# across the heading, the best direction at that angle). The edge of that region is the image of the cone's own edge, plus the unit
# circle of the plane where the cone holds directions square across the heading; it is traced, then kept every
# 360 / side_view.front.theta_bins degrees round the unit. So:
#   a dorsal turret   a fan over the top (its directions are above the plane across the nose and to both sides)
#   waist guns        fans to the left and right
#   a fixed forward gun   a small disc at the centre (the cone is round about the nose axis, seen end-on)
#   a battery's all-round upward cone   a dome
# The wash is the map's: a peaked gun's rings of equal odds each projected (nested, the deeper the ring the darker, as the map's
# wash is darker toward the centre line), a turret's one flat wash, the fade past the effective range in the same steps, an ink rim
# at the effective range and a dashed one at the reach. A cone that faces the TAIL lands on the same plane as one that faces the
# nose, so its rim is dashed (side_view.front.rear_dashed). The target is at its lateral offset and height difference.
#
# model() is the whole strip as numbers (px in the picture's own space, (0, 0) its top-left); paint() draws it. A cone's outline
# depends only on the weapon and the pitch, so it is cached.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const SideViewArt = preload("res://scripts/ui/side_view_art.gd")

static var _cache: Dictionary = {}

# --- The outline of one cone ---------------------------------------------------------------------

# The outline of `w`'s cone on the plane at unit range, one array of radii (0 where nothing is covered) per level of equal odds,
# the deepest (smallest) first: {"levels": [PackedFloat64Array], "fractions": [float], "flat": bool, "bins": int}. Bin i is the
# angle  -PI + (i + 0.5) TAU / bins  (atan2(up, right)).
static func shape(w: Object, pitch_in: float, st: UiStyle) -> Dictionary:
	# The pitch is taken to the data's step (half a degree), so a turn's playback reuses a few dozen outlines, not one a frame.
	var step := deg_to_rad(maxf(st.num("side_view.front.pitch_step_deg"), 0.01))
	var pitch := roundf(pitch_in / step) * step
	var bins := maxi(int(st.num("side_view.front.theta_bins")), 8)
	var flat: bool = float(w.rim_odds_factor) >= 0.999
	var n_levels := 1 if flat else maxi(int(st.num("planner.cones.wash.steps")), 1)
	var nb := maxi(int(st.num("side_view.front.boundary_samples")), 24)
	var dstep := maxf(st.num("side_view.front.densify_step"), 0.002)
	# (keyed by what shapes the outline, not by the weapon object: a freed object's id can be handed to another)
	var key := "%.5f,%.5f,%.5f,%.5f,%.3f:%.4f:%d:%d:%d:%.4f" % [float(w.mount), float(w.elevation), float(w.half_across), float(w.half_height),
		float(w.rim_odds_factor), pitch, bins, n_levels, nb, dstep]
	if _cache.has(key):
		return _cache[key]
	var cp := cos(pitch)
	var sp := sin(pitch)
	var he: float = float(w.half_across)
	var hh: float = maxf(float(w.half_height), 1e-6)
	var mount: float = float(w.mount)
	var elev: float = float(w.elevation)
	var all_around: bool = he >= PI - 1e-9
	var levels: Array = []
	var fractions: Array = []
	for lv in n_levels:
		var s := float(lv + 1) / float(n_levels)
		var rad := PackedFloat64Array()
		rad.resize(bins)
		# The edge of the region is the image of the cone's own edge (the ellipse in azimuth and elevation, for an all-round cone its
		# two edges in elevation) and, where the cone holds them, the unit circle of the plane (the directions square across the
		# heading, the fold of the projection). The image of the edge is traced, every bit of it, so no angle is missed.
		if all_around:
			var lo := PackedVector2Array()
			var hi := PackedVector2Array()
			for i in nb + 1:
				var az := -PI + TAU * float(i) / float(nb)
				lo.append(Vector2(az, elev - s * hh))
				hi.append(Vector2(az, elev + s * hh))
			_trace(rad, bins, lo, cp, sp, dstep)
			_trace(rad, bins, hi, cp, sp, dstep)
		else:
			var ring := PackedVector2Array()
			for i in nb + 1:
				var phi := TAU * float(i) / float(nb)
				ring.append(Vector2(mount + s * he * cos(phi), elev + s * hh * sin(phi)))
			_trace(rad, bins, ring, cp, sp, dstep)
		for i in bins:
			var a := bin_angle(i, bins)
			var d_f := sin(a) * sp                 # the direction square across the heading, in the airframe's axes
			var d_u := sin(a) * cp
			var d_r := cos(a)
			var az_e := atan2(d_r, d_f)
			var el_e := atan2(d_u, sqrt(d_f * d_f + d_r * d_r))
			var ka := 0.0 if all_around else Combat.wrap_angle(az_e - mount) / he
			var kb := (el_e - elev) / hh
			if ka * ka + kb * kb <= s * s:
				rad[i] = 1.0
		levels.append(rad)
		fractions.append(s)
	var out := {"levels": levels, "fractions": fractions, "flat": flat, "bins": bins}
	_cache[key] = out
	return out

# The image on the plane of a polyline of (azimuth, elevation) points, every bit of it put in its angle's bin: the segments between
# the points are walked in steps no longer than `dstep` and no wider than half a bin, so a stretch near the unit (where an angle
# changes fast) is not skipped.
static func _trace(rad: PackedFloat64Array, bins: int, pl: PackedVector2Array, cp: float, sp: float, dstep: float) -> void:
	var half_bin := 0.5 * TAU / float(bins)
	var prev := Vector2.ZERO
	for i in pl.size():
		var q := pl[i]
		var cel := cos(q.y)
		var cur := Vector2(cel * sin(q.x), cel * cos(q.x) * sp + sin(q.y) * cp)   # (lateral, up): a point t out along (a, e) is t x this
		if i == 0:
			_splat(rad, bins, cur)
		else:
			var n := 1
			var len := prev.distance_to(cur)
			if len > 1e-9 and prev.length_squared() > 1e-12 and cur.length_squared() > 1e-12:
				n = clampi(ceili(maxf(len / dstep, absf(angle_difference(prev.angle(), cur.angle())) / half_bin)), 1, 400)
			else:
				n = clampi(ceili(len / dstep), 1, 400)
			for k in range(1, n + 1):
				_splat(rad, bins, prev.lerp(cur, float(k) / float(n)))
		prev = cur

# Keeps the longest reach in the point's angle's bin.
static func _splat(rad: PackedFloat64Array, bins: int, p: Vector2) -> void:
	var rho := p.length()
	if rho < 1e-9:
		return
	var b := int(floor((atan2(p.y, p.x) + PI) / TAU * float(bins))) % bins
	if rho > rad[b]:
		rad[b] = rho

# The bin's centre angle (atan2(up, right)).
static func bin_angle(i: int, bins: int) -> float:
	return -PI + (float(i) + 0.5) * TAU / float(bins)

# The contiguous runs of covered bins of one level, as arrays of bin indices (a full circle is split in two halves so every run is a
# simple fan): [[i0, i1, ...], ...], and whether the whole circle is covered.
static func runs(rad: PackedFloat64Array) -> Dictionary:
	var bins := rad.size()
	var covered := 0
	for i in bins:
		if rad[i] > 0.0:
			covered += 1
	var out: Array = []
	if covered == 0:
		return {"runs": out, "full": false}
	if covered == bins:
		var a: Array = []
		var b: Array = []
		for i in bins / 2 + 1:
			a.append(i)
		for i in range(bins / 2, bins + 1):
			b.append(i % bins)
		return {"runs": [a, b], "full": true}
	# Start at the first uncovered bin so no run wraps past the end.
	var start := 0
	for i in bins:
		if rad[i] <= 0.0:
			start = i
			break
	var cur: Array = []
	for k in range(1, bins + 1):
		var i2 := (start + k) % bins
		if rad[i2] > 0.0:
			cur.append(i2)
		elif not cur.is_empty():
			out.append(cur)
			cur = []
	if not cur.is_empty():
		out.append(cur)
	return {"runs": out, "full": false}

# --- The model -----------------------------------------------------------------------------------------

# The strip's model. `u` the unit, `pose` (side_view.gd's: x, y, heading, pitch, height_m), `tgt` the normalised target ({} for none),
# `size` the picture, `ground_y` the ground line's page y (INF for none: the Side strip's rule).
static func model(u: Object, id: String, pose: Dictionary, tgt: Dictionary, size: Vector2, st: UiStyle, range_factor: Callable, above_ground: float) -> Dictionary:
	var pitch := float(pose["pitch"])
	var cp := cos(pitch)
	var sp := sin(pitch)
	var recs: Array = []
	var pts: Array[Vector2] = [Vector2.ZERO]
	for w in u.def.weapons:
		var shp := shape(w, pitch, st)
		var reach_m: float = ConeOverlay.reach_for(w, 1.0, st, range_factor)
		var bins: int = shp["bins"]
		var outer: PackedFloat64Array = (shp["levels"] as Array)[(shp["levels"] as Array).size() - 1]
		# The hardpoints, in metres from the unit on the plane: lateral, up. One wash per weapon at their mean, a dot at each.
		var offs: Array[Vector2] = []
		var seen := {}
		for hi in w.hardpoints.size():
			var hp: Vector3 = w.hardpoints[hi]
			var o := Vector2(hp.y, hp.x * sp + hp.z * cp)
			var key := "%.2f,%.2f" % [o.x, o.y]
			if seen.has(key):
				continue
			seen[key] = true
			offs.append(o)
		var mean := Vector2.ZERO
		for o: Vector2 in offs:
			mean += o
		mean /= float(maxi(offs.size(), 1))
		for i in bins:
			if outer[i] > 0.0:
				var a := bin_angle(i, bins)
				pts.append(mean + Vector2(cos(a), sin(a)) * reach_m * outer[i])
		var az := Combat.wrap_angle(float(w.mount))
		recs.append({"weapon": w, "shape": shp, "offs": offs, "mean": mean, "reach_m": reach_m, "rear": absf(az) > PI * 0.5 + 1e-6 and float(w.half_across) < PI - 1e-9})
	# The fit: one scale for both axes, centred, with the span margin; the unit keeps room for the ground when it is near (the Side
	# strip's rule: when the ground is within 70% of the page's height at the scale the weapons alone give).
	var fit := _fit(pts, size, st)
	if above_ground > 0.0 and above_ground * float(fit["ppm"]) <= size.y * 0.7:
		var pts2: Array[Vector2] = pts.duplicate()
		pts2.append(Vector2(0.0, -above_ground))
		fit = _fit(pts2, size, st)
	var ppm: float = fit["ppm"]
	var origin: Vector2 = fit["origin"]
	var cones: Array = []
	for r: Dictionary in recs:
		var w: Object = r["weapon"]
		var dots: Array = []
		for o: Vector2 in (r["offs"] as Array):
			dots.append(origin + Vector2(o.x, -o.y) * ppm)
		cones.append({
			"unit": id, "side": str(u.side), "own": true, "weapon": w, "shape": r["shape"], "dots": dots,
			"centre": origin + Vector2((r["mean"] as Vector2).x, -(r["mean"] as Vector2).y) * ppm, "rear": bool(r["rear"]),
			"range_px": float(w.range_m) * ppm, "reach_px": float(r["reach_m"]) * ppm, "ppm": ppm, "rf": range_factor,
		})
	var m := {"size": size, "side": str(u.side), "origin": origin, "ppm": ppm, "tick_dir": Vector2.ZERO, "cones": cones, "pose": pose,
		"target": {}, "ground_marker": "square", "ground_y": INF}
	var gy := origin.y + above_ground * ppm
	m["ground_y"] = gy if above_ground >= 0.0 and gy < size.y - 1.0 else INF
	if not tgt.is_empty() and not tgt.has("hidden"):
		m["target"] = _place_target(tgt, pose, m, st)
	return m

# The scale and the unit's place for the points the page must hold (metres from the unit: lateral, up): one scale for both axes, the
# bounding box with the span margin, centred, with at least span_min_m across.
static func _fit(pts: Array[Vector2], size: Vector2, st: UiStyle) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for p: Vector2 in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var span_min: float = st.num("side_view.frame.span_min_m") * 0.5
	lo = Vector2(minf(lo.x, -span_min), minf(lo.y, -span_min * 0.5))
	hi = Vector2(maxf(hi.x, span_min), maxf(hi.y, span_min * 0.5))
	var pad: float = st.num("side_view.section.pad_px")
	var margin: float = st.num("side_view.frame.span_margin")
	var span_m := hi - lo
	var avail := size - Vector2(pad, pad) * 2.0
	var ppm := minf(avail.x / maxf(span_m.x * margin, 1.0), avail.y / maxf(span_m.y * margin, 1.0))
	# Page x grows with the lateral offset, page y falls with the height.
	var origin := Vector2(pad + (avail.x - span_m.x * ppm) * 0.5 - lo.x * ppm, pad + (avail.y - span_m.y * ppm) * 0.5 + hi.y * ppm)
	return {"ppm": ppm, "origin": origin}

# The target at its lateral offset (right of the heading) and its height difference, on the model's one scale.
static func _place_target(t: Dictionary, pose: Dictionary, m: Dictionary, st: UiStyle) -> Dictionary:
	var d: Vector2 = (t["pos"] as Vector2) - Vector2(float(pose["x"]), float(pose["y"]))
	var h := float(pose["heading"])
	var lateral := d.dot(Vector2.from_angle(h + PI * 0.5))
	var ahead := d.dot(Vector2.from_angle(h))
	var dz: float = float(t["height_m"]) - float(pose["height_m"])
	var origin: Vector2 = m["origin"]
	var ppm: float = m["ppm"]
	var px := origin + Vector2(lateral, -dz) * ppm
	var out := t.duplicate()
	out.merge(SideViewArt.place_edge(px, origin, m["size"], st.num("side_view.frame.edge_inset_px")), true)
	out["px"] = px
	out["rel_lat"] = lateral
	out["rel_z"] = dz
	out["rel_f"] = ahead
	out["dist"] = d.length()
	out["hollow"] = false
	return out

# --- Drawing -------------------------------------------------------------------------------------------------

# Draws the strip and returns how many sub-draws did not reach their end (0: all did).
static func paint(ci: CanvasItem, m: Dictionary, st: UiStyle) -> int:
	var failed := 0
	ci.draw_rect(Rect2(Vector2.ZERO, m["size"]), SideViewArt.role(st, "paper_role"))
	failed += 0 if SideViewArt.ground(ci, m, st) else 1
	for c: Dictionary in m["cones"]:
		failed += 0 if _wash(ci, c, st) else 1
	for c: Dictionary in m["cones"]:
		failed += 0 if _rim(ci, c, st) else 1
	failed += 0 if _dots(ci, m, st) else 1
	failed += 0 if SideViewArt.target(ci, m, st) else 1
	failed += 0 if SideViewArt.mark(ci, m, st) else 1
	failed += 0 if SideViewArt.frame(ci, m, st) else 1
	return failed

# The outline point of bin i at `radius_px`, on the page.
static func _pt(c: Dictionary, rad: PackedFloat64Array, i: int, radius_px: float) -> Vector2:
	var a := bin_angle(i, rad.size())
	return (c["centre"] as Vector2) + Vector2(cos(a), -sin(a)) * radius_px * rad[i]

# The wash: the levels of equal odds nested (the deepest is darkest), each filling the outline at the effective range, then the same
# in rings out to the reach, each ring washed in proportion to the range factor at its middle -- the map's wash (cone_overlay.gd), seen
# end-on. The alphas are the map's too (planner.cones.wash): `totals` is what a point at each depth should show, and each level adds
# only what is missing.
static func _wash(ci: CanvasItem, c: Dictionary, st: UiStyle) -> bool:
	var shp: Dictionary = c["shape"]
	var levels: Array = shp["levels"]
	var n: int = levels.size()
	var w: Object = c["weapon"]
	var accent: Color = st.side_color(str(c["side"]))
	var a_lo: float = st.num("planner.cones.wash.alpha_rim")
	var a_hi: float = st.num("planner.cones.wash.alpha_centre")
	var a_flat: float = st.num("planner.cones.wash.alpha_flat")
	var totals: Array = []     # [level 0 (deepest)] -> the alpha a point inside that level and outside the next deeper one shows
	for k in n:
		if bool(shp["flat"]):
			totals.append(a_flat)
		else:
			var r_mid := (float(k) + 0.5) / float(n)
			var o := Combat.centre_factor(w, r_mid)
			var lo: float = float(w.rim_odds_factor)
			var t := clampf((o - lo) / maxf(1.0 - lo, 1e-6), 0.0, 1.0)
			totals.append(lerpf(a_lo, a_hi, t))
	var range_px: float = c["range_px"]
	for k in range(n - 1, -1, -1):
		var base: float = float(totals[k + 1]) if k + 1 < n else 0.0
		var add := 1.0 - (1.0 - float(totals[k])) / maxf(1.0 - base, 1e-6)
		_fill(ci, c, levels[k], range_px, Color(accent.r, accent.g, accent.b, add))
	var reach: float = c["reach_px"]
	var fall := int(st.num("planner.cones.wash.fall_steps"))
	if reach > range_px + 1.0 and fall > 0:
		for mi in fall:
			var r0 := range_px + (reach - range_px) * float(mi) / float(fall)
			var r1 := range_px + (reach - range_px) * float(mi + 1) / float(fall)
			var rf := ConeOverlay.range_rel({"weapon": w, "range_px": range_px, "reach_px": reach, "rf": c["rf"], "ppm": c["ppm"]}, (r0 + r1) * 0.5)
			if rf <= 0.002:
				continue
			for k in range(n - 1, -1, -1):
				var base2: float = float(totals[k + 1]) * rf if k + 1 < n else 0.0
				var add2 := 1.0 - (1.0 - float(totals[k]) * rf) / maxf(1.0 - base2, 1e-6)
				_ring(ci, c, levels[k], r0, r1, Color(accent.r, accent.g, accent.b, add2))
	return true

# Triangles straight to the canvas (no triangulation: a fan from the unit may have a straight angle at it, which the engine's
# polygon fill does not promise to take).
static func _tris(ci: CanvasItem, points: PackedVector2Array, indices: PackedInt32Array, col: Color) -> void:
	if indices.is_empty():
		return
	var colors := PackedColorArray()
	colors.resize(points.size())
	colors.fill(col)
	RenderingServer.canvas_item_add_triangle_array(ci.get_canvas_item(), indices, points, colors)

# One level's outline filled at `radius_px`: a fan from the unit for each run of covered angles (a full circle in two halves).
static func _fill(ci: CanvasItem, c: Dictionary, rad: PackedFloat64Array, radius_px: float, col: Color) -> void:
	if col.a <= 0.0:
		return
	var rs := runs(rad)
	var points := PackedVector2Array()
	var indices := PackedInt32Array()
	for run: Array in rs["runs"]:
		if run.size() < 2:
			continue
		var base := points.size()
		points.append(c["centre"])
		for i: int in run:
			points.append(_pt(c, rad, i, radius_px))
		for k in run.size() - 1:
			indices.append_array(PackedInt32Array([base, base + 1 + k, base + 2 + k]))
	_tris(ci, points, indices, col)

# One level's ring between two radii: a strip along each run.
static func _ring(ci: CanvasItem, c: Dictionary, rad: PackedFloat64Array, r0: float, r1: float, col: Color) -> void:
	if col.a <= 0.0:
		return
	var rs := runs(rad)
	var points := PackedVector2Array()
	var indices := PackedInt32Array()
	for run: Array in rs["runs"]:
		if run.size() < 2:
			continue
		var base := points.size()
		for i: int in run:
			points.append(_pt(c, rad, i, r0))
			points.append(_pt(c, rad, i, r1))
		for k in run.size() - 1:
			var a := base + 2 * k
			indices.append_array(PackedInt32Array([a, a + 1, a + 3, a, a + 3, a + 2]))
	_tris(ci, points, indices, col)

# The rim: the outermost outline at the effective range (ink; dashed for a cone that faces the tail), and the dashed one at the reach
# the map's falloff sides carry, as the map draws them.
static func _rim(ci: CanvasItem, c: Dictionary, st: UiStyle) -> bool:
	var shp: Dictionary = c["shape"]
	var levels: Array = shp["levels"]
	var rad: PackedFloat64Array = levels[levels.size() - 1]
	var col: Color = SideViewArt.role_of(st, "planner.cones.rim_role")
	var w: float = st.num("planner.cones.rim_px")
	var dashed_rim: bool = bool(c["rear"]) and st.flag("side_view.front.rear_dashed")
	var seed_value := (hash(str((c["weapon"] as Object).id)) & 0xFFFF) + 3
	var dash: float = st.num("planner.cones.falloff_dash_px")
	var rs := runs(rad)
	var range_px: float = c["range_px"]
	var reach: float = c["reach_px"]
	var fcol := Color(col.r, col.g, col.b, col.a * st.num("planner.cones.falloff_side_alpha"))
	if bool(rs["full"]):
		var ring := PackedVector2Array()
		for i in rad.size():
			ring.append(_pt(c, rad, i, range_px))
		if dashed_rim:
			ring.append(ring[0])
			UiInk.dashed(ci, ring, col, w, dash, dash)
		else:
			UiInk.ink_line(ci, ring, true, col, w, seed_value, 0.5)
		if reach > range_px + 1.0:
			var far := PackedVector2Array()
			for i in rad.size():
				far.append(_pt(c, rad, i, reach))
			far.append(far[0])
			UiInk.dashed(ci, far, fcol, w * 0.8, dash, dash)
		return true
	# The full circle was split in two halves by runs(); a partial outline is one polyline per run: out from the unit along the run's
	# first angle, round the outline, and back along its last.
	for run: Array in rs["runs"]:
		if run.size() < 2:
			continue
		var line := PackedVector2Array([c["centre"]])
		for i: int in run:
			line.append(_pt(c, rad, i, range_px))
		if dashed_rim:
			line.append(c["centre"])
			UiInk.dashed(ci, line, col, w, dash, dash)
		else:
			UiInk.ink_line(ci, line, true, col, w, seed_value, 0.5)
		if reach > range_px + 1.0:
			var first: int = run[0]
			var last: int = run[run.size() - 1]
			var far2 := PackedVector2Array()
			for i: int in run:
				far2.append(_pt(c, rad, i, reach))
			UiInk.dashed(ci, far2, fcol, w * 0.8, dash, dash)
			UiInk.dashed(ci, PackedVector2Array([_pt(c, rad, first, range_px), _pt(c, rad, first, reach)]), fcol, w * 0.8, dash, dash)
			UiInk.dashed(ci, PackedVector2Array([_pt(c, rad, last, range_px), _pt(c, rad, last, reach)]), fcol, w * 0.8, dash, dash)
	return true

# The hardpoint dots over every wash, each on a paper knock-out (the map's).
static func _dots(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var halo: Color = SideViewArt.role_of(st, "planner.cones.label_halo_role")
	var col: Color = SideViewArt.role_of(st, "planner.cones.rim_role")
	var hp_r: float = st.num("planner.cones.hardpoint_px")
	for c: Dictionary in m["cones"]:
		for d: Vector2 in c["dots"]:
			ci.draw_circle(d, hp_r + st.num("planner.cones.hardpoint_halo_px"), halo, true, -1.0, true)
	for c: Dictionary in m["cones"]:
		for d: Vector2 in c["dots"]:
			ci.draw_circle(d, hp_r, col, true, -1.0, true)
	return true
