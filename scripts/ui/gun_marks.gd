extends RefCounted

# THE MAIN GUNS' FIRE MARKS (board guns-mark, backlog D8; builder BP, 2026-10-14).
#
# Alex (decision no-ink-marks, 2026-10-13): "The main guns fire mark is not, we need a better option." and "Generally I don't like the ink
# mark indicators, lets not propose them again". Today (G0, MotionPlanner._draw_fire_marks) a step whose Main Guns fire is on draws a dashed
# line from its node to the target, a ring at the shells' two-sigma scatter, a small shell beside the node and an X at the target. The
# target selection has its own mark (scripts/ui/target_art.gd): nothing here doubles it, and no option draws a symbol (an X, a shell
# icon, a tick). Feedback comes from the thing itself: a line, a wash, a trajectory, the puffs the salvo will raise.
#
# data/ui/ui.json guns.marks.mode picks the look (G0 stays the default until Alex chooses); guns.marks.<mode> holds its numbers. EVERY
# OPTION AND NUMBER IS PROPOSED by builder BP. Colours are roles (fan_wash, fan_rim, path_halo, hover_ink, gun_puff_*): ink and paper at
# alphas, the dust the dirt ink lightened toward the paper (as the gunfire board's G3 dust), no new hue; the weights are the plan-weight
# board's P2 family (a 2 px line, a 1.8 px rim, a paper halo).
#
#   G1  the scatter as a SOFT WASH under one thin rim (the range of motion's grammar), a quiet SOLID line from the node
#   G2  the shells' ARC, tapering from the ship to the target (a light curve, the trajectory), ending in the wash
#   G3  the landing area PREVIEWED as faint soft puffs, dust on land and spray on water, no line
#   G4  proposed best: the arc, the wash, and a few faint puffs in it
#
# A direct shot (the tank's gun: one aimed shell, no scatter) takes a straight line and a small wash.

const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const MODES := ["G0", "G1", "G2", "G3", "G4"]

# The mode in force; anything the data does not list is G0.
static func mode_of(style: UiStyle) -> String:
	var v: Variant = style.lookup("guns.marks.mode")
	var m := str(v) if v is String else "G0"
	return m if MODES.has(m) else "G0"

# Draws the mark of ONE fire step; 1 when it ran to its end (a runtime error part-way leaves the default 0, which a test sees; G0 draws nothing here and gives 0). `ci`: the planner (a CanvasItem with style, mapping and world); `n`: the step's node on screen; `at_m`: the
# target's place in metres; `sigma_m`: the scatter's sigma (0 for a direct shot); `fade`: 1, or less when the fire will not go off.
static func draw_step(ci, k: int, n: Vector2, at_m: Vector2, sigma_m: float, direct: bool, fade: float) -> int:
	var mode := mode_of(ci.style)
	if mode == "G0":
		return 0
	var st: UiStyle = ci.style
	var tp: Vector2 = ci.mapping.world_to_screen(at_m)
	var ppm: float = ci.mapping.px_per_m(at_m)
	var cfg := "guns.marks.%s." % mode
	var r_px := maxf(sigma_m * st.num("guns.marks.sigma_k") * ppm, st.num("guns.marks.ring_min_px"))
	if direct:
		r_px = st.num(cfg + "direct_r_px")
	var seed_v := _seed(k, at_m)
	match mode:
		"G1":
			_line(ci, cfg, n, tp, r_px, fade)
			_wash(ci, cfg, tp, r_px, direct, fade)
		"G2":
			_arc(ci, cfg, n, tp, r_px, direct, fade)
			_wash(ci, cfg, tp, r_px, direct, fade)
		"G3":
			_puffs(ci, cfg, at_m, sigma_m, direct, seed_v, fade)
		"G4":
			_wash(ci, cfg, tp, r_px, direct, fade)
			_arc(ci, cfg, n, tp, r_px, direct, fade)
			_puffs(ci, cfg, at_m, sigma_m, direct, seed_v, fade)
	return 1

static func _seed(k: int, at_m: Vector2) -> int:
	return (k * 7919 + int(roundf(at_m.x)) * 31 + int(roundf(at_m.y)) * 17) & 0x7fffffff

static func _fade(c: Color, k: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * k)

# A quiet solid line from the node to the scatter's edge, with a paper halo so it reads over hatching and forest.
static func _line(ci, cfg: String, n: Vector2, tp: Vector2, r_px: float, fade: float) -> void:
	var st: UiStyle = ci.style
	var d := tp - n
	if d.length() < 1.0:
		return
	var end := tp - d.normalized() * minf(r_px * 0.5, d.length() * 0.5)
	var w: float = st.num(cfg + "line_px")
	var halo: float = st.num(cfg + "halo_px")
	var ink := _fade(st.color("hover_ink"), st.num(cfg + "line_alpha") * fade)
	if halo > 0.0:
		ci.draw_line(n, end, _fade(st.color("path_halo"), fade), w + 2.0 * halo, true)
	ci.draw_line(n, end, ink, w, true)

# The scatter as a wash: the two-sigma disc in the range of motion's wash (role fan_wash) with its thin inked rim (fan_rim), and the
# one-sigma disc inside it in one more layer of wash, so the middle of the salvo is the deepest tone, as the odds are.
static func _wash(ci, cfg: String, tp: Vector2, r_px: float, direct: bool, fade: float) -> void:
	var st: UiStyle = ci.style
	var wash := _fade(st.color(st.text(cfg + "wash_role")), fade)
	var rim := _fade(st.color(st.text(cfg + "rim_role")), fade)
	var disc := UiInk.circle_pts(tp, r_px, 48)
	ci.draw_colored_polygon(disc, wash)
	if not direct:
		ci.draw_colored_polygon(UiInk.circle_pts(tp, r_px * 0.5, 36), wash)
	UiInk.ink_line(ci, disc, true, rim, st.num(cfg + "rim_px"), 37, 0.5)

# The shells' arc: a quadratic curve from the node to the target, bulging to the sun side (a lob seen from above), tapering from a thin
# faint stroke at the ship to a bolder one at the target, over a paper halo. A direct shot is a straight line. It stops inside the wash.
static func _arc(ci, cfg: String, n: Vector2, tp: Vector2, r_px: float, direct: bool, fade: float) -> void:
	var st: UiStyle = ci.style
	var d := tp - n
	var dist := d.length()
	if dist < 2.0:
		return
	var dir := d / dist
	var perp := Vector2(-dir.y, dir.x)
	var sun: Vector2 = -st.shadow_dir()
	if perp.dot(sun) < 0.0:
		perp = -perp
	var bulge: float = 0.0 if direct else st.num(cfg + "bulge") * dist
	var ctrl := (n + tp) * 0.5 + perp * bulge * 2.0
	var stop := clampf(1.0 - r_px * st.num(cfg + "enter") / dist, 0.2, 1.0)
	var steps := clampi(int(dist / 8.0), 8, 64)
	var ink: Color = st.color("hover_ink")
	var halo_c := st.color("path_halo")
	var w0: float = st.num(cfg + "from_px")
	var w1: float = st.num(cfg + "to_px")
	var a0: float = st.num(cfg + "from_alpha")
	var a1: float = st.num(cfg + "to_alpha")
	var halo: float = st.num(cfg + "halo_px")
	var prev := n
	var pts: Array = []
	for i in range(1, steps + 1):
		var t := stop * float(i) / float(steps)
		var p := n.lerp(ctrl, t).lerp(ctrl.lerp(tp, t), t)
		pts.append([prev, p, float(i) / float(steps)])
		prev = p
	if halo > 0.0:
		for s: Array in pts:
			var u: float = s[2]
			ci.draw_line(s[0], s[1], _fade(halo_c, fade), lerpf(w0, w1, u) + 2.0 * halo, true)
	for s: Array in pts:
		var u2: float = s[2]
		ci.draw_line(s[0], s[1], _fade(ink, lerpf(a0, a1, u2) * fade), lerpf(w0, w1, u2), true)

# The landing area previewed as soft puffs (the gunfire board's G3 grammar: scalloped, a soft stack of layers, a thin ink outline): one per
# shell of the salvo, scattered over the two-sigma disc by a sunflower layout seeded by the step and the target (stable from frame to
# frame), dust where the ground is dry and a pale disc with a ripple where it is water. A direct shot is one puff.
static func _puffs(ci, cfg: String, at_m: Vector2, sigma_m: float, direct: bool, seed_v: int, fade: float) -> void:
	var st: UiStyle = ci.style
	var count := 1 if direct else int(st.num(cfg + "count"))
	var reach_m := 2.0 * sigma_m * st.num(cfg + "spread_k")
	var r_m: float = st.num(cfg + "puff_r_m")
	var min_px: float = st.num(cfg + "puff_min_px")
	var dust_c := _fade(st.color("gun_puff_dust"), st.num(cfg + "alpha_k") * fade)
	var water_c := _fade(st.color("gun_puff_water"), st.num(cfg + "alpha_k") * fade)
	var line_c := _fade(st.color("gun_puff_rim"), st.num(cfg + "outline_k") * fade)
	var line_px: float = st.num(cfg + "outline_px")
	var layers: Array = st.lookup(cfg + "layers") if st.lookup(cfg + "layers") is Array else [1.0, 0.72, 0.46]
	var phase := float(seed_v % 628) * 0.01
	var amp: float = st.num(cfg + "lobe_amp")
	for i in count:
		var off := Vector2.ZERO
		if not direct and count > 1:
			var rr := reach_m * sqrt((float(i) + 0.5) / float(count))
			var a := phase + float(i) * 2.39996
			off = Vector2(cos(a), sin(a)) * rr
		var pm := at_m + off
		var c: Vector2 = ci.mapping.world_to_screen(pm)
		var r := maxf(r_m * ci.mapping.px_per_m(pm), min_px)
		var on_water: bool = ci.world != null and ci.world.water_depth_at(pm.x, pm.y) > 0.0
		var rng_seed := seed_v + i * 101
		if on_water:
			for lk: Variant in layers:
				ci.draw_circle(c, r * float(lk), water_c, true, -1.0, true)
			ci.draw_arc(c, r * 1.25, 0.0, TAU, 32, line_c, line_px, true)
			ci.draw_arc(c, r * 1.6, 0.0, TAU, 40, _fade(line_c, 0.5), line_px, true)
		else:
			for lk: Variant in layers:
				ci.draw_colored_polygon(_lobed(c, r * float(lk), rng_seed, amp), dust_c)
			UiInk.ink_line(ci, _lobed(c, r, rng_seed, amp), true, line_c, line_px, 53 + i, 0.3)

# A soft scalloped outline: radius r modulated by round lobes (amp: the lobes' depth as a share of r), star-shaped about its centre. Round,
# not spiky: a puff is a cloud, never a star.
static func _lobed(c: Vector2, r: float, seed_v: int, amp: float) -> PackedVector2Array:
	var lobes := 7 + seed_v % 3
	var p1 := float((seed_v / 7) % 628) * 0.01
	var p2 := float((seed_v / 13) % 628) * 0.01
	var out := PackedVector2Array()
	var m := 44
	for j in m:
		var a := TAU * float(j) / float(m)
		var rr := r * (1.0 + amp * sin(a * float(lobes) + p1) + amp * 0.45 * sin(a * float(lobes + 4) + p2))
		out.append(c + Vector2(cos(a), sin(a)) * rr)
	return out
