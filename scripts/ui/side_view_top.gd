extends RefCounted

# THE TOP STRIP of the side view panel (decision side-view-views, 2026-10-11). ALEX: "I want to be able to select between top, front &
# side. I think this solves the 'cone but only upwards' problem. Maybe they fold instead of you selecting only one - so you could have
# all three. It would also make it easier to disable the cones on the main map." The PROJECTION below is PROPOSED by the builder
# (data/ui/ui.json side_view.top says why).
#
# WHAT IT IS. The horizontal plane through the selected FRIENDLY unit, seen from above, in the unit's own frame: the map's own cone
# wash made small. Each weapon is cone_overlay.gd's own record (collect()'s: an apex on the hardpoint, a centre line at the weapon's
# mount, the wedge's half width at the plane's own level, b0 the plane's height over the cone's centre line as a fraction of its half
# height), so it draws through ConeOverlay.draw_cones with the map's wash, odds shading, fade past the effective range, rim and
# hardpoint dots: nothing here invents a look. Two differences from the map, both because this is a plane through the unit and not a
# picture of the ground:
#   - the plane is the HORIZONTAL one, so a climb or a dive changes each cone's slice (side_view.top.pitch_shift; the Side strip tilts
#     its cones by the same pitch): slice() puts the plane's directions through the airframe's pitch as combat.gd does and keeps the
#     azimuths inside the cone. Level, the records are the map's own.
#   - a weapon whose cone misses the plane (the bomber's dorsal turret covers what is ABOVE it) is drawn as its FOOTPRINT, dashed,
#     as cone_overlay.gd draws the overhead footprint (planner.cones.overhead_*; the map itself draws none by default).
# The nose points where side_view.top.nose_deg says (0: to the right, the Side strip's way); the scale is one for both axes, from the
# weapons' reach, with the span_margin; the target is at its bearing and distance in the same frame, an arrow on the edge when the
# page does not hold it.
#
# model() is the whole strip as numbers (px in the picture's own space, (0, 0) its top-left); paint() draws it.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const SideViewArt = preload("res://scripts/ui/side_view_art.gd")
const Combat = preload("res://scripts/sim/combat.gd")

# Where the horizontal plane through the unit cuts a weapon's cone, the airframe pitched by `pitch`: {"half": the slice's half width as
# a wedge (0: the plane misses the cone), "mid": its centre line (azimuth off the nose; the weapon's mount when the cone is cut
# symmetrically), "b0": the plane's height over the cone's centre line there as a fraction of the cone's half height}.
# Level (pitch 0) it is the map's own (cone_overlay.gd's collect): b0 = -elevation / half_height, half = half_across sqrt(1 - b0^2).
# Pitched, each horizontal direction (world azimuth a off the heading) is put in the airframe's axes exactly as combat.gd's
# evaluate_pose does (the forward axis lifted by the pitch, the up axis tipped back) and tested against the cone's ellipse: the
# wedge spans the azimuths that are inside. A wide cone (a turret's) is cut at a different height at each end, so this is
# not the level formula tilted by one number.
static func slice(w: Object, pitch: float) -> Dictionary:
	var hh := maxf(float(w.half_height), 1e-6)
	var mount := float(w.mount)
	var elev := float(w.elevation)
	var he := float(w.half_across)
	if absf(pitch) < 1e-9:
		var b0 := -elev / hh
		return {"half": he * sqrt(1.0 - b0 * b0) if absf(b0) < 1.0 - 1e-6 else 0.0, "mid": mount, "b0": b0}
	var all_around := he >= PI - 1e-9
	var cp := cos(pitch)
	var sp := sin(pitch)
	var n := 360
	var span := PI if all_around else he
	var lo := INF
	var hi := -INF
	var lo_b := 0.0
	var hi_b := 0.0
	for i in n + 1:
		var a := (mount if not all_around else 0.0) - span + 2.0 * span * float(i) / float(n)   # world azimuth off the nose
		var d_f := cos(a) * cp
		var d_r := sin(a)
		var d_u := -cos(a) * sp
		var az := atan2(d_r, d_f)
		var el := atan2(d_u, sqrt(d_f * d_f + d_r * d_r))
		var across := Combat.wrap_angle(az - mount)
		var ka := 0.0 if all_around else across / he
		var kb := (el - elev) / hh
		if ka * ka + kb * kb <= 1.0:
			if a < lo:
				lo = a
				lo_b = kb
			if a > hi:
				hi = a
				hi_b = kb
	if lo > hi:
		return {"half": 0.0, "mid": mount, "b0": -elev / hh}
	return {"half": (hi - lo) * 0.5, "mid": (hi + lo) * 0.5, "b0": 0.5 * (lo_b + hi_b)}

# The strip's model. `u` the unit, `pose` {x, y, heading, pitch, ...} (side_view.gd's), `tgt` the normalised target ({} for none),
# `size` the picture. {} keys: size, side, origin, ppm, nose (screen angle), tick_dir, cones (draw_cones records), footprints,
# target (the placed one or {}), pose, ground_marker.
static func model(u: Object, id: String, pose: Dictionary, tgt: Dictionary, size: Vector2, st: UiStyle, range_factor: Callable) -> Dictionary:
	var pitch: float = float(pose["pitch"]) if st.flag("side_view.top.pitch_shift") else 0.0
	var cp := cos(pitch)
	var sp := sin(pitch)
	var nose := deg_to_rad(st.num("side_view.top.nose_deg"))
	var fwd := Vector2.from_angle(nose)
	var rgt := Vector2.from_angle(nose + PI * 0.5)
	# The records in metres from the unit (screen axes), and the points the page must hold.
	var recs: Array = []
	var pts: Array[Vector2] = [Vector2.ZERO, fwd * st.num("side_view.frame.span_min_m")]
	for w in u.def.weapons:
		var sl := slice(w, pitch)
		var half: float = sl["half"]
		var mid: float = float(sl["mid"])
		var reach_m: float = ConeOverlay.reach_for(w, 1.0, st, range_factor)
		var fit_m: float = reach_m if half > 0.0 else float(w.range_m)   # (a footprint is drawn to the effective range, a wedge to where its fade ends)
		var seen := {}
		for hi in w.hardpoints.size():
			var hp: Vector3 = w.hardpoints[hi]
			var f_off: float = hp.x * cp - hp.z * sp
			var key := "%.2f,%.2f" % [f_off, hp.y]
			if seen.has(key):
				continue
			seen[key] = true
			var apex_m: Vector2 = fwd * f_off + rgt * hp.y
			recs.append({"weapon": w, "hp": hi, "apex_m": apex_m, "half": half, "mid": mid, "b0": float(sl["b0"]), "reach_m": reach_m})
			var span := minf(half if half > 0.0 else float(w.half_across), PI)
			var n := maxi(8, ceili(span * 12.0))
			for i in n + 1:
				var a := nose + mid - span + 2.0 * span * float(i) / float(n)
				pts.append(apex_m + Vector2.from_angle(a) * fit_m)
			pts.append(apex_m)
	# The fit: one scale for both axes, the bounding box of what the page holds (with the margin), centred.
	var lo := Vector2(INF, INF)
	var hi_p := Vector2(-INF, -INF)
	for p: Vector2 in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi_p = Vector2(maxf(hi_p.x, p.x), maxf(hi_p.y, p.y))
	var pad: float = st.num("side_view.section.pad_px")
	var margin: float = st.num("side_view.frame.span_margin")
	var span_m := hi_p - lo
	var avail := size - Vector2(pad, pad) * 2.0
	var ppm := minf(avail.x / maxf(span_m.x * margin, 1.0), avail.y / maxf(span_m.y * margin, 1.0))
	var origin := Vector2(pad, pad) + (avail - span_m * ppm) * 0.5 - lo * ppm
	var cones: Array = []
	var foots: Array = []
	var accent_side := str(u.side)
	for r: Dictionary in recs:
		var w: Object = r["weapon"]
		var c := {
			"unit": id, "side": accent_side, "own": true, "weapon": w, "hp": int(r["hp"]),
			"apex": origin + (r["apex_m"] as Vector2) * ppm, "phi": nose + float(r["mid"]), "half": float(r["half"]),
			"range_px": float(w.range_m) * ppm, "b0": float(r["b0"]), "sp": origin, "ppm": ppm,
			"reach_px": float(r["reach_m"]) * ppm, "rf": range_factor,
		}
		if float(r["half"]) > 0.0:
			cones.append(c)
		elif st.flag("side_view.top.footprint"):
			foots.append(c)
	var m := {"size": size, "side": accent_side, "origin": origin, "ppm": ppm, "nose": nose, "tick_dir": fwd, "cones": cones,
		"footprints": foots, "pose": pose, "target": {}, "ground_marker": "square", "ground_y": INF}
	if not tgt.is_empty() and not tgt.has("hidden"):
		m["target"] = _place_target(tgt, pose, m, st)
	return m

# The target at its bearing and distance in the unit's frame (forward and right of the heading), on the model's one scale.
static func _place_target(t: Dictionary, pose: Dictionary, m: Dictionary, st: UiStyle) -> Dictionary:
	var d: Vector2 = (t["pos"] as Vector2) - Vector2(float(pose["x"]), float(pose["y"]))
	var h := float(pose["heading"])
	var f := d.dot(Vector2.from_angle(h))
	var r := d.dot(Vector2.from_angle(h + PI * 0.5))
	var fwd := Vector2.from_angle(float(m["nose"]))
	var rgt := Vector2.from_angle(float(m["nose"]) + PI * 0.5)
	var origin: Vector2 = m["origin"]
	var ppm: float = m["ppm"]
	var px := origin + (fwd * f + rgt * r) * ppm
	var out := t.duplicate()
	out.merge(SideViewArt.place_edge(px, origin, m["size"], st.num("side_view.frame.edge_inset_px")), true)
	out["px"] = px
	out["rel_f"] = f
	out["rel_r"] = r
	out["dist"] = d.length()
	out["hollow"] = false
	return out

# Draws the strip and returns how many sub-draws did not reach their end (0: all did).
static func paint(ci: CanvasItem, m: Dictionary, st: UiStyle) -> int:
	var failed := 0
	ci.draw_rect(Rect2(Vector2.ZERO, m["size"]), SideViewArt.role(st, "paper_role"))
	failed += ConeOverlay.draw_cones(ci, m["cones"], st, st.text("side_view.cone_mode"), "all")
	failed += 0 if _footprints(ci, m, st) else 1
	failed += 0 if SideViewArt.target(ci, m, st) else 1
	failed += 0 if SideViewArt.mark(ci, m, st) else 1
	failed += 0 if SideViewArt.frame(ci, m, st) else 1
	return failed

# The cones that miss the plane: the weapon's whole footprint, dashed, one per weapon at the mean of its hardpoints (the map's
# overhead footprint), and the hardpoint dots the wedges carry.
static func _footprints(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var foots: Array = m["footprints"]
	if foots.is_empty():
		return true
	var ink: Color = SideViewArt.role_of(st, "planner.cones.rim_role")
	var rim_w: float = st.num("planner.cones.rim_px")
	var alpha: float = st.num("planner.cones.overhead_alpha")
	var dash: float = st.num("planner.cones.overhead_dash_px")
	var by_weapon := {}
	for c: Dictionary in foots:
		var key := str((c["weapon"] as Object).id)
		if not by_weapon.has(key):
			by_weapon[key] = []
		(by_weapon[key] as Array).append(c)
	for key: String in by_weapon:
		var group: Array = by_weapon[key]
		var mean := Vector2.ZERO
		for c: Dictionary in group:
			mean += c["apex"] as Vector2
		mean /= float(group.size())
		var rep: Dictionary = (group[0] as Dictionary).duplicate()
		rep["apex"] = mean
		var wide: float = (rep["weapon"] as Object).half_across
		var pts := ConeOverlay.wedge_points(rep, wide)
		pts.append(pts[0])
		UiInk.dashed(ci, pts, Color(ink.r, ink.g, ink.b, ink.a * alpha), rim_w * 0.8, dash, dash)
	var halo: Color = SideViewArt.role_of(st, "planner.cones.label_halo_role")
	var hp_r: float = st.num("planner.cones.hardpoint_px")
	for c: Dictionary in foots:
		ci.draw_circle(c["apex"], hp_r + st.num("planner.cones.hardpoint_halo_px"), halo, true, -1.0, true)
	for c: Dictionary in foots:
		ci.draw_circle(c["apex"], hp_r, ink, true, -1.0, true)
	return true
