extends Node2D

# THE ENGAGEMENT CONES ON THE MAP while planning (Track U1, the first fight):
# the variant switch of variants/cone-overlay/. EVERY VALUE AND RULE HERE IS
# PROPOSED; Alex chooses the style from the board. Data: data/ui/ui.json
# planner.cones.
#
#   var cones := ConeOverlay.new()
#   map_parent.add_child(cones)                    # screen space, the markers' space
#   cones.setup(world, host_mapping, selection)    # mapping: as UnitMarkerLayer takes it
#   cones.unit_visible = fog.vision.unit_visible(world)    # optional: enemy cones need sight
#   cones.marker_layer = marker_layer              # optional: the stand-out scale of own planes
#
# WHAT IT DRAWS (the rules are proposed):
#   - the SELECTED player unit's cones, every weapon, every hardpoint (planner.cones.own
#     "selected"; "all_own" draws every player unit's), and every enemy unit's cones
#     while that unit is in sight (planner.cones.enemy "in_sight"; "none" draws no
#     enemy's). Only while PLANNING: a turn that is playing back shows none.
#   - one wedge per hardpoint, its apex ON the hardpoint. A hardpoint is [forward,
#     right, up] metres on the airframe (data/units/*.json weapons); the plane is drawn
#     at its own scale, so the apex sits where the gun is DRAWN (metres x the map scale
#     x marker.true_scale), while the range is the true range on the map.
#   - the wedge is the weapon's cone cut at the plane's OWN LEVEL (Alex: "the same cone
#     in height"): the cone is an ellipse in azimuth and elevation (combat.gd), so a
#     weapon pitched up (the dorsal turret, +35 +- 35 degrees) has a narrower slice at
#     level and none at all when its elevation reaches the plane's own level. A cone with
#     no slice is drawn as a dashed rim only, labelled "overhead". The odds shading is
#     combat.gd's own centre_factor(r) at each azimuth, so what is drawn is the model:
#     peaked for fixed guns, even for turrets and flexible guns.
#   - the styles (planner.cones.mode): the rim and the hardpoint dots are common to all;
#     the interior differs. outline: nothing inside, range ticks along the centre line.
#     hatch: 45 degree ink-hatching in the side colour, the strokes more broken where the
#     odds are lower. stipple: dots in the side colour, thinner where the odds are lower.
#     wash: a light wash in the side colour in odds-steps, darker near the centre.
#
# EFFECTIVE RANGE (Alex 2026-10-09: "slightly over effective range"). A weapon's range_m is its
# EFFECTIVE range: full odds inside it, and past it the odds fall smoothly to nothing over a
# short overshoot (Track C builds that as a second odds factor, "range"). Every style shows
# both: a solid rim at the effective range, and beyond it a falloff zone that fades out in
# that style's own way (outline: dashed sides and three fainter arcs; hatch: the strokes fray;
# stipple: the dots thin out; wash: the steps lighten). The zone's size and shape come from
# `range_factor` -- a Callable (CombatWeapon, distance_m) -> 0..1 that the host points at Track
# C's function when it lands -- and, until it is set, from planner.cones.overshoot_fraction
# of the effective range with a smooth (smoothstep) ramp: PROPOSED stand-ins, so the picture is
# right the day the real numbers arrive.
#
# TWO LAYERS. The interior (hatch, stipple, wash) must lie UNDER the planes, or an enemy's
# wash would tint your own plane; the rim, the ticks, the hardpoint dots and the lettering
# must lie OVER them, because a hardpoint is ON the airframe. This node is the first and
# sits where the host mounts it (just under the markers); its child "Marks" has z_index 1,
# so it draws over every sibling of this node at z 0, the markers included.
#
# COLOUR: roles only. The interior is the unit's side accent (side_a for the players'
# planes, side_b for the enemy's): hue is reserved for paper, ink, shadow and the
# accents. The rim, ticks and labels are ink; the lettering has a paper halo.
#
# It redraws only when something it shows changes (a selection, a pose, the camera,
# the mode), not every frame: a wedge of stipple is a thousand dots.

const World = preload("res://scripts/sim/world.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const Combat = preload("res://scripts/sim/combat.gd")

var world: World = null
var mapping: UiMapping = null
var selection: RefCounted = null
var style: UiStyle = null
# Optional seams, as the marker layer has them.
var unit_visible: Callable = Callable()     # unit_id -> bool: in sight (enemy cones need it)
var marker_layer: Object = null             # for marker(id).draw_scale (the stand-out "larger" mode)
var range_factor: Callable = Callable()     # (CombatWeapon, distance_m) -> 0..1: the odds' fall past the effective range
# Which units show cones; read from data each redraw so a host can switch them.
var _sig := ""
var _cones: Array = []
var _marks: Node2D = null
# Counted when a draw ran to its end (a runtime error in a draw function aborts it
# silently): a test or a board can tell a drawn frame from a failed one.
var draw_count: int = 0
var marks_draw_count: int = 0
var failed_draws: int = 0       # sub-draws that did not reach their end (draw_cones' tally)

func setup(w: World, host_mapping: Variant, sel: RefCounted, st: RefCounted = null) -> void:
	world = w
	selection = sel
	style = (st if st != null else UiStyle.shared()) as UiStyle
	set_mapping(host_mapping)
	name = "ConeOverlay"
	if _marks == null:
		_marks = Node2D.new()
		_marks.name = "Marks"
		_marks.z_index = 1
		add_child(_marks)
		_marks.draw.connect(_draw_marks)

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	_sig = ""

func _process(_delta: float) -> void:
	if world == null or mapping == null:
		return
	var cones := collect()
	var sig := _signature(cones)
	if sig != _sig:
		_sig = sig
		_cones = cones
		queue_redraw()
		if _marks != null:
			_marks.queue_redraw()

# --- What is drawn ---------------------------------------------------------------------

# One record per hardpoint of every weapon of every unit that shows cones:
#   {unit, side, own, weapon (CombatWeapon), hp (index), apex (screen px), phi (screen
#    angle of the cone's centre line), half (azimuth half-width at the unit's level, rad;
#    0 when the cone has no slice at that level), range_px, b0 (the level's height offset
#    as a fraction of the cone's half height), sp (the unit's screen position), ppm, reach_px
#    (where the odds reach zero: the effective range plus the overshoot), rf (the range_factor
#    seam, maybe invalid)}
func collect() -> Array:
	var out: Array = []
	if world == null or mapping == null or world.phase != World.PHASE_PLANNING:
		return out
	var own_rule := style.text("planner.cones.own")
	var enemy_rule := style.text("planner.cones.enemy")
	var k: float = style.num("marker.true_scale")
	for id: String in world.units:
		var u = world.units[id]
		if u.down or u.def == null or u.def.weapons.is_empty():
			continue
		var is_own: bool = u.controller == World.CONTROLLER_PLAYER
		if is_own:
			if own_rule == "selected" and (selection == null or selection.unit_id != id):
				continue
			if own_rule != "selected" and own_rule != "all_own":
				continue
		else:
			if enemy_rule != "in_sight":
				continue
			if unit_visible.is_valid() and not bool(unit_visible.call(id)):
				continue
		var wp := Vector2(float(u.x), float(u.y))
		var sp: Vector2 = mapping.world_to_screen(wp)
		var ppm: float = mapping.px_per_m(wp)
		var ang: float = mapping.screen_angle(wp, float(u.heading))
		var scale_k := k
		if marker_layer != null:
			var m: Object = marker_layer.marker(id)
			if m != null:
				scale_k *= float(m.draw_scale)
		var fwd := Vector2.from_angle(ang)
		var right := Vector2.from_angle(ang + PI / 2.0)
		for w in u.def.weapons:
			var b0: float = -float(w.elevation) / maxf(float(w.half_height), 1e-6)
			var half := 0.0
			if absf(b0) < 1.0 - 1e-6:
				half = float(w.half_across) * sqrt(1.0 - b0 * b0)
			for hi in w.hardpoints.size():
				var hp: Vector3 = w.hardpoints[hi]
				out.append({
					"unit": id, "side": str(u.side), "own": is_own, "weapon": w, "hp": hi,
					"apex": sp + fwd * hp.x * ppm * scale_k + right * hp.y * ppm * scale_k,
					"phi": ang + float(w.mount), "half": half, "range_px": float(w.range_m) * ppm,
					"b0": b0, "sp": sp, "ppm": ppm,
						"reach_px": reach_for(w, ppm, style, range_factor), "rf": range_factor,
				})
	return out

func _signature(cones: Array) -> String:
	var parts := PackedStringArray([style.text("planner.cones.mode")])
	for c: Dictionary in cones:
		var a: Vector2 = c["apex"]
		parts.append("%s.%s.%d:%.1f,%.1f,%.3f,%.1f,%.1f" % [c["unit"], (c["weapon"] as Object).id, c["hp"], a.x, a.y, c["phi"], c["range_px"], c["reach_px"]])
	return "|".join(parts)

# --- Drawing ---------------------------------------------------------------------------

func _draw() -> void:
	if world == null or mapping == null:
		return
	failed_draws += draw_cones(self, _cones, style, "", "fill")
	draw_count += 1

func _draw_marks() -> void:
	if world == null or mapping == null:
		return
	failed_draws += draw_cones(_marks, _cones, style, "", "marks")
	marks_draw_count += 1

# Draws a list of cone records (collect()) on any CanvasItem, in the style the data
# names. Static so a board can draw cones where there is no World (the side view).
# Returns how many sub-draws did not reach their end (0 when all did): a runtime error ends
# a GDScript function early and silently, so each returns true as its last act and the
# tally says whether a frame was drawn whole.
static func draw_cones(ci: CanvasItem, cones: Array, st: UiStyle, mode_override: String = "", layer: String = "all") -> int:
	var failed := 0
	var mode := mode_override if mode_override != "" else st.text("planner.cones.mode")
	var rim_col: Color = UiRoles.resolve(st, st.lookup("planner.cones.rim_role"), "planner.cones.rim_role")
	var rim_w: float = st.num("planner.cones.rim_px")
	var hp_r: float = st.num("planner.cones.hardpoint_px")
	var labelled := {}
	if layer == "all" or layer == "fill":
		for c: Dictionary in cones:
			var accent: Color = st.side_color(str(c["side"]))
			match mode:
				"wash":
					failed += 0 if _draw_wash(ci, c, accent, st) else 1
				"hatch":
					failed += 0 if _draw_hatch(ci, c, accent, st) else 1
				"stipple":
					failed += 0 if _draw_stipple(ci, c, accent, st) else 1
	if layer == "fill":
		return failed
	for c: Dictionary in cones:
		if mode == "outline":
			failed += 0 if _draw_ticks(ci, c, rim_col, st) else 1
		failed += 0 if _draw_rim(ci, c, rim_col, rim_w, st) else 1
	# Hardpoints on top of every wedge, so two a few px apart both show; each has a paper
	# knock-out under it so it reads on the busiest ground.
	var halo: Color = UiRoles.resolve(st, st.lookup("planner.cones.label_halo_role"), "planner.cones.label_halo_role")
	for c: Dictionary in cones:
		ci.draw_circle(c["apex"], hp_r + st.num("planner.cones.hardpoint_halo_px"), halo, true, -1.0, true)
	for c: Dictionary in cones:
		ci.draw_circle(c["apex"], hp_r, rim_col, true, -1.0, true)
	var placed: Array[Rect2] = []
	for c: Dictionary in cones:
		var key := "%s.%s" % [c["unit"], (c["weapon"] as Object).id]
		if labelled.has(key):
			continue
		labelled[key] = true
		failed += 0 if _draw_label(ci, c, cones, st, placed) else 1
	return failed

# Where a weapon's odds reach zero, in px: its effective range plus the overshoot. From the
# host's range_factor when it has one (scanned out to twice the effective range for the
# first distance where the factor is gone), else the data's overshoot_fraction.
static func reach_for(w: Object, ppm: float, st: UiStyle, rf: Callable = Callable()) -> float:
	var eff := float(w.range_m)
	if rf.is_valid():
		var d := eff
		var step := maxf(eff / 60.0, 0.5)
		while d < eff * 2.0:
			if float(rf.call(w, d)) <= 0.001:
				return d * ppm
			d += step
		return eff * 2.0 * ppm
	return eff * (1.0 + st.num("planner.cones.overshoot_fraction")) * ppm

# The range factor at a distance (px) from the apex: 1 inside the effective range, then
# falling smoothly to 0 at the reach.
static func range_rel(c: Dictionary, d_px: float) -> float:
	var r: float = c["range_px"]
	if d_px <= r:
		return 1.0
	var rf: Callable = c.get("rf", Callable())
	if rf.is_valid():
		return clampf(float(rf.call(c["weapon"], d_px / maxf(float(c.get("ppm", 1.0)), 1e-6))), 0.0, 1.0)
	var over := float(c.get("reach_px", r)) - r
	if over <= 0.0:
		return 0.0
	var t := (d_px - r) / over
	if t >= 1.0:
		return 0.0
	return 1.0 - t * t * (3.0 - 2.0 * t)

# The wedge's polygon: the apex, then the arc from phi - half to phi + half, at `radius`
# (px; the effective range when not given).
static func wedge_points(c: Dictionary, half: float, steps_per_rad: float = 14.0, radius: float = -1.0) -> PackedVector2Array:
	var pts := PackedVector2Array([c["apex"]])
	var n := maxi(3, ceili(half * 2.0 * steps_per_rad))
	var rad := radius if radius > 0.0 else float(c["range_px"])
	for i in n + 1:
		var a: float = float(c["phi"]) - half + 2.0 * half * float(i) / float(n)
		pts.append((c["apex"] as Vector2) + Vector2.from_angle(a) * rad)
	return pts

# A band of the falloff zone: between two azimuth offsets and two radii (px).
static func annulus(c: Dictionary, a0: float, a1: float, r0: float, r1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(2, ceili(absf(a1 - a0) * 14.0))
	for i in n + 1:
		var a: float = float(c["phi"]) + a0 + (a1 - a0) * float(i) / float(n)
		pts.append((c["apex"] as Vector2) + Vector2.from_angle(a) * r0)
	for i in range(n, -1, -1):
		var a2: float = float(c["phi"]) + a0 + (a1 - a0) * float(i) / float(n)
		pts.append((c["apex"] as Vector2) + Vector2.from_angle(a2) * r1)
	return pts

# The odds at an azimuth offset from the cone's centre line, as a fraction of the weapon's
# centre odds, at the unit's own level (combat.gd's centre_factor along the level's slice).
static func odds_rel(c: Dictionary, across: float) -> float:
	var w = c["weapon"]
	if c.get("side_view", false):
		# Seen side-on, the angle is an ELEVATION offset about the cone's centre line, at the
		# centre azimuth.
		return Combat.centre_factor(w, absf(across) / maxf(float(w.half_height), 1e-6))
	var a := across / maxf(float(w.half_across), 1e-6)
	var r := sqrt(a * a + float(c["b0"]) * float(c["b0"]))
	return Combat.centre_factor(w, r)

# True when the point is inside the wedge (distance and azimuth about phi).
static func inside(c: Dictionary, p: Vector2, half: float) -> bool:
	var d: Vector2 = p - (c["apex"] as Vector2)
	var dist := d.length()
	if dist > float(c.get("reach_px", c["range_px"])) or dist < 0.5:
		return false
	return absf(angle_difference(float(c["phi"]), d.angle())) <= half

# 0..1 from integers: the same cell always draws the same mark.
static func hash01(i: int, j: int, salt: int) -> float:
	var h := (i * 73856093) ^ (j * 19349663) ^ (salt * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0

static func _unit_salt(c: Dictionary) -> int:
	return (hash(str(c["unit"]) + (c["weapon"] as Object).id) & 0xFFFF) + int(c["hp"]) * 7

# --- the rim: the same in every style ------------------------------------------------------

static func _draw_rim(ci: CanvasItem, c: Dictionary, col: Color, w: float, st: UiStyle) -> bool:
	var half: float = c["half"]
	var seed_value := _unit_salt(c)
	if half <= 0.0:
		# No slice at this level: the cone's whole footprint, dashed, "overhead".
		var wide: float = (c["weapon"] as Object).half_across
		var pts := wedge_points(c, wide)
		pts.append(pts[0])
		UiInk.dashed(ci, pts, Color(col.r, col.g, col.b, col.a * st.num("planner.cones.overhead_alpha")), w * 0.8, st.num("planner.cones.overhead_dash_px"), st.num("planner.cones.overhead_dash_px"))
		return true
	UiInk.ink_line(ci, wedge_points(c, half), true, col, w, seed_value, 0.5)
	# The falloff zone: the wedge's sides carry on, dashed and fainter, to where the odds are gone.
	var reach: float = c.get("reach_px", c["range_px"])
	if reach > float(c["range_px"]) + 1.0:
		var fcol := Color(col.r, col.g, col.b, col.a * st.num("planner.cones.falloff_side_alpha"))
		var dash: float = st.num("planner.cones.falloff_dash_px")
		var apex: Vector2 = c["apex"]
		for sgn in [-1.0, 1.0]:
			var dir := Vector2.from_angle(float(c["phi"]) + sgn * half)
			UiInk.dashed(ci, PackedVector2Array([apex + dir * float(c["range_px"]), apex + dir * reach]), fcol, w * 0.8, dash, dash)
	return true

# --- outline: range ticks along the centre line ---------------------------------------------

static func _draw_ticks(ci: CanvasItem, c: Dictionary, col: Color, st: UiStyle) -> bool:
	if float(c["half"]) <= 0.0:
		return true
	var w = c["weapon"]
	var every: float = st.num("planner.cones.outline.tick_every_m")
	var range_m: float = float(w.range_m)
	var px_per_m: float = float(c["range_px"]) / maxf(range_m, 1.0)
	var dir := Vector2.from_angle(float(c["phi"]))
	var nrm := Vector2(-dir.y, dir.x)
	var tick: float = st.num("planner.cones.outline.tick_px")
	var apex: Vector2 = c["apex"]
	var faint := Color(col.r, col.g, col.b, col.a * st.num("planner.cones.outline.centre_alpha"))
	ci.draw_line(apex, apex + dir * float(c["range_px"]), faint, 0.8, true)
	var d := every
	while d < range_m - 0.5:
		var p := apex + dir * d * px_per_m
		ci.draw_line(p - nrm * tick, p + nrm * tick, col, 1.0, true)
		d += every
	# The falloff zone, in linework only: arcs at equal steps out to the reach, each fainter by
	# the odds left there, so the line fades the way the odds do.
	var reach: float = c.get("reach_px", c["range_px"])
	var arcs := int(st.num("planner.cones.outline.fade_arcs"))
	if reach > float(c["range_px"]) + 1.0 and arcs > 0:
		var half: float = c["half"]
		for i in range(1, arcs + 1):
			var rr: float = float(c["range_px"]) + (reach - float(c["range_px"])) * float(i) / float(arcs + 1)
			var a := range_rel(c, rr)
			ci.draw_arc(apex, rr, float(c["phi"]) - half, float(c["phi"]) + half, maxi(8, ceili(half * 2.0 * 14.0)), Color(col.r, col.g, col.b, col.a * a * st.num("planner.cones.outline.fade_arc_alpha")), 0.9, true)
	return true

# --- wash: the side colour in odds steps ----------------------------------------------------

static func _draw_wash(ci: CanvasItem, c: Dictionary, accent: Color, st: UiStyle) -> bool:
	var half: float = c["half"]
	if half <= 0.0:
		return true
	var w = c["weapon"]
	var steps: int = int(st.num("planner.cones.wash.steps")) if float(w.rim_odds_factor) < 0.999 else 1
	var a_lo: float = st.num("planner.cones.wash.alpha_rim")
	var a_hi: float = st.num("planner.cones.wash.alpha_centre")
	var a_flat: float = st.num("planner.cones.wash.alpha_flat")
	var bands: Array = []     # [h0, h1, alpha] in azimuth, from the centre line out
	for j in steps:
		# Band j covers azimuth fractions [f0, f1] of the half-width, both sides.
		var f0 := float(j) / float(steps)
		var f1 := float(j + 1) / float(steps)
		var mid := (f0 + f1) * 0.5 * half
		var o := odds_rel(c, mid)
		var lo: float = float(w.rim_odds_factor)
		var t := 1.0 if lo >= 0.999 else clampf((o - lo) / maxf(1.0 - lo, 1e-6), 0.0, 1.0)
		var alpha := lerpf(a_lo, a_hi, t) if lo < 0.999 else a_flat
		var col := Color(accent.r, accent.g, accent.b, alpha)
		bands.append([f0 * half, f1 * half, alpha])
		if steps == 1:
			ci.draw_colored_polygon(wedge_points(c, half), col)
			continue
		var h0 := f0 * half
		var h1 := f1 * half
		if j == 0:
			ci.draw_colored_polygon(wedge_points(c, h1), col)
		else:
			for sgn in [-1.0, 1.0]:
				ci.draw_colored_polygon(_strip(c, sgn * h0, sgn * h1), col)
	# The falloff zone: the same azimuth steps in rings out to the reach, each ring washed in
	# proportion to the range factor at its middle, so the wash fades to nothing.
	var reach: float = c.get("reach_px", c["range_px"])
	var rim_r: float = c["range_px"]
	var fall := int(st.num("planner.cones.wash.fall_steps"))
	if reach > rim_r + 1.0 and fall > 0:
		for m in fall:
			var r0 := rim_r + (reach - rim_r) * float(m) / float(fall)
			var r1 := rim_r + (reach - rim_r) * float(m + 1) / float(fall)
			var rf := range_rel(c, (r0 + r1) * 0.5)
			if rf <= 0.002:
				continue
			for b: Array in bands:
				var col2 := Color(accent.r, accent.g, accent.b, float(b[2]) * rf)
				if float(b[0]) <= 0.0:
					ci.draw_colored_polygon(annulus(c, -float(b[1]), float(b[1]), r0, r1), col2)
				else:
					for sgn in [-1.0, 1.0]:
						var lo_a: float = minf(sgn * float(b[0]), sgn * float(b[1]))
						var hi_a: float = maxf(sgn * float(b[0]), sgn * float(b[1]))
						ci.draw_colored_polygon(annulus(c, lo_a, hi_a, r0, r1), col2)
	return true

# The thin wedge between two azimuth offsets (signed) from the centre line.
static func _strip(c: Dictionary, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array([c["apex"]])
	var n := maxi(2, ceili(absf(a1 - a0) * 14.0))
	for i in n + 1:
		var a: float = float(c["phi"]) + a0 + (a1 - a0) * float(i) / float(n)
		pts.append((c["apex"] as Vector2) + Vector2.from_angle(a) * float(c["range_px"]))
	return pts

# The wedge's bounding box in screen px (apex and arc samples).
static func wedge_bounds(c: Dictionary, half: float) -> Rect2:
	var pts := wedge_points(c, half, 6.0, float(c.get("reach_px", c["range_px"])))
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r

# --- hatch: 45 degree strokes, more broken where the odds are lower --------------------------

static func _draw_hatch(ci: CanvasItem, c: Dictionary, accent: Color, st: UiStyle) -> bool:
	var half: float = c["half"]
	if half <= 0.0:
		return true
	var spacing: float = st.num("planner.cones.hatch.spacing_px")
	var cell: float = st.num("planner.cones.hatch.cell_px")
	var line_w: float = st.num("planner.cones.hatch.line_px")
	var col := Color(accent.r, accent.g, accent.b, st.num("planner.cones.hatch.alpha"))
	var ang := deg_to_rad(st.num("planner.cones.hatch.angle_deg"))
	var t := Vector2.from_angle(ang)
	var n := Vector2(-t.y, t.x)
	var apex: Vector2 = c["apex"]
	var R: float = c.get("reach_px", c["range_px"])
	var salt := _unit_salt(c)
	var step := 1.5
	# The lines and cells that can meet the wedge: its bounding box in the hatch's own
	# axes (u across the lines, v along them), about the apex.
	var bb := wedge_bounds(c, half)
	var u_lo := INF
	var u_hi := -INF
	var v_lo := INF
	var v_hi := -INF
	for corner: Vector2 in [bb.position, Vector2(bb.end.x, bb.position.y), bb.end, Vector2(bb.position.x, bb.end.y)]:
		var q := corner - apex
		u_lo = minf(u_lo, q.dot(n))
		u_hi = maxf(u_hi, q.dot(n))
		v_lo = minf(v_lo, q.dot(t))
		v_hi = maxf(v_hi, q.dot(t))
	for i in range(floori(u_lo / spacing), ceili(u_hi / spacing) + 1):
		var base := apex + n * float(i) * spacing
		for j in range(floori(v_lo / cell), ceili(v_hi / cell) + 1):
			var v0 := float(j) * cell
			var mid := base + t * (v0 + cell * 0.5)
			if mid.distance_to(apex) > R + cell:
				continue
			# Is this cell kept? Its odds decide how often.
			var d := mid - apex
			var o := odds_rel(c, absf(angle_difference(float(c["phi"]), d.angle()))) * range_rel(c, d.length())
			if hash01(i, j, salt) > o:
				continue
			# Draw the part of the cell that lies inside the wedge.
			var run_start := -1.0
			var s := 0.0
			while s <= cell + 0.001:
				var p := base + t * (v0 + s)
				var ins := inside(c, p, half)
				if ins and run_start < 0.0:
					run_start = s
				if (not ins or s + step > cell) and run_start >= 0.0:
					var end_s := s if not ins else minf(s, cell)
					if end_s - run_start > 0.4:
						ci.draw_line(base + t * (v0 + run_start), base + t * (v0 + end_s), col, line_w, true)
					run_start = -1.0
				s += step
	return true

# --- stipple: dots, thinner where the odds are lower ------------------------------------------

static func _draw_stipple(ci: CanvasItem, c: Dictionary, accent: Color, st: UiStyle) -> bool:
	var half: float = c["half"]
	if half <= 0.0:
		return true
	var cell: float = st.num("planner.cones.stipple.cell_px")
	var r: float = st.num("planner.cones.stipple.dot_px")
	var gamma: float = st.num("planner.cones.stipple.gamma")
	var col := Color(accent.r, accent.g, accent.b, st.num("planner.cones.stipple.alpha"))
	var apex: Vector2 = c["apex"]
	var salt := _unit_salt(c)
	# The grid is anchored to the SCREEN, not the apex, so a dot does not swim when the
	# unit moves a pixel (the cone redraws on a change).
	var bb := wedge_bounds(c, half)
	var x0 := floori(bb.position.x / cell)
	var x1 := ceili(bb.end.x / cell)
	var y0 := floori(bb.position.y / cell)
	var y1 := ceili(bb.end.y / cell)
	for gx in range(x0, x1 + 1):
		for gy in range(y0, y1 + 1):
			var p := Vector2((float(gx) + hash01(gx, gy, salt + 1)) * cell, (float(gy) + hash01(gx, gy, salt + 2)) * cell)
			if not inside(c, p, half):
				continue
			var d := p - apex
			var o := odds_rel(c, absf(angle_difference(float(c["phi"]), d.angle()))) * range_rel(c, d.length())
			if hash01(gx, gy, salt + 3) > pow(o, gamma):
				continue
			ci.draw_circle(p, r, col, true, -1.0, true)
	return true

# --- label: name, range and centre odds, with a paper halo --------------------------------------

static func _draw_label(ci: CanvasItem, c: Dictionary, all: Array, st: UiStyle, placed: Array[Rect2]) -> bool:
	if not st.flag("planner.cones.label") or c.get("side_view", false):
		return true
	var w = c["weapon"]
	# One label per weapon, at the mean apex of its hardpoints, past the arc's far end.
	var apex := Vector2.ZERO
	var n := 0
	for o: Dictionary in all:
		if o["unit"] == c["unit"] and (o["weapon"] as Object).id == w.id:
			apex += o["apex"]
			n += 1
	apex /= float(maxi(n, 1))
	var dir := Vector2.from_angle(float(c["phi"]))
	if float(c["half"]) <= 0.0:
		# An overhead cone has no reach at this level: its label sits on the dashed footprint,
		# turned off the weapon's axis so it does not land on a neighbour's.
		dir = Vector2.from_angle(float(c["phi"]) + 0.45 * float((c["weapon"] as Object).half_across))
	var px := st.num("planner.cones.label_px")
	var font: Font = st.font(true)
	var text := "%s · %d m" % [str(w.name), int(round(float(w.range_m)))]    # the EFFECTIVE range
	if float(c["half"]) <= 0.0:
		text = "%s · overhead" % str(w.name)
	var reach := float(c.get("reach_px", c["range_px"])) if float(c["half"]) > 0.0 else float(c["range_px"])
	var at := apex + dir * reach
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(px))).x
	# The lettering lies INSIDE the cone at its far end, on the faded zone, ending where the
	# odds end (so a label never leaves the picture the cone itself is in), with its paper halo.
	var x: float
	if dir.x > 0.3:
		x = at.x - width - 3.0
	elif dir.x < -0.3:
		x = at.x + 3.0
	else:
		x = at.x - width * 0.5
	var y0 := at.y + px * 0.35
	if absf(dir.y) >= 0.6:
		y0 = at.y - 4.0 if dir.y > 0.0 else at.y + px + 2.0
	# The first spot that no earlier label has taken: along the line, then stepped up and down.
	var pos := Vector2(x, y0)
	for step in [0.0, -1.0, 1.0, -2.0, 2.0, -3.0, 3.0]:
		var trial := Vector2(x, y0 + float(step) * (px + 3.0))
		var box := Rect2(trial.x - 2.0, trial.y - px, width + 4.0, px + 4.0)
		var clash := false
		for r: Rect2 in placed:
			if r.intersects(box):
				clash = true
				break
		if not clash:
			pos = trial
			break
	placed.append(Rect2(pos.x - 2.0, pos.y - px, width + 4.0, px + 4.0))
	var halo: Color = UiRoles.resolve(st, st.lookup("planner.cones.label_halo_role"), "planner.cones.label_halo_role")
	var ink: Color = UiRoles.resolve(st, st.lookup("planner.cones.label_role"), "planner.cones.label_role")
	ci.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(px)), int(st.num("planner.cones.label_halo_px")), halo)
	ci.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(px)), ink)
	return true
