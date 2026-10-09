extends RefCounted

# The --render-shot demo frame (scripts/app/main.gd): a 1280x720 picture that
# drives the drawing layer the way the port of the prototype's render() will,
# so a PNG of it shows whether the substrate draws like Canvas before any scene
# is ported onto it. NOT the scene: no generation, no placement rules.
#
# What it exercises, in the prototype's own draw order (paper, shadows, objects,
# grain), each piece a line-for-line port of the prototype routine it names
# (reference/inkwood-renderer.html):
#   - paper:     one fillRect in the paper colour.
#   - lobes:     scallop() + drawLobe() straight onto the frame, at canopy size
#                and enlarged -- the acid test for thin, wobbly, broken, 88%
#                ink rings, cusp ticks, and stipple dots (arc + fill at .55).
#   - trees:     buildTreeSprite() into offscreen canvases (one engine frame for
#                all of them), drawn with drawImage at fractional positions; one
#                of them again stretched 2x along a 45-degree axis by the
#                canopy-shadow transform (translate, rotate, scale, rotate back).
#   - walls:     wallGeom() for an open capped wall and a closed ring
#                (rrectLocal), filled with fill_band, the butt-capped slope tone
#                at .6 and the 1.15 x line-weight edge strokes (part of drawWall).
#   - a crate:   save / translate / rotate / fillRect / rect + stroke / restore.
#   - shadows:   castShadows: prism hulls for the walls and the crate, trunk
#                strokes and stretched canopy silhouettes for the trees, merged
#                in one mask and composited in the steel tint at .92 -- the
#                tree shadows overlap each other and the crate's.
#   - grain:     the seeded grain multiplied over everything at .55.
# Every colour and parameter comes from data/params/render_defaults.json.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const Grain = preload("res://scripts/render/grain.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const PARAMS_PATH := "res://data/params/render_defaults.json"

# The prototype's P and palette constants, read from the data file.
class Style:
	var paper: Color
	var ink: Color
	var cream: Color
	var wall: Color
	var shadow: Color
	var lw: float
	var wob: float
	var rings: int
	var tree_size: float
	var size_var: float
	var height: float
	var wall_w: float
	var wall_h: float
	var sun_az: float
	var elev: float
	var shadow_str: float
	var grain: float
	var lx: float
	var ly: float
	var k: Dictionary  # linework multipliers
	var slope_mix: float
	var scene_seed: int

static func render(size: Vector2i) -> Image:
	var t_all := Time.get_ticks_usec()
	var st := _load_style()
	var rng := Mulberry32.new(st.scene_seed)

	# --- objects: trees (model + sprites), walls, the crate ----------------------
	var trees: Array[Dictionary] = []
	var spots := [Vector2(578.3, 236.6), Vector2(611.7, 268.2), Vector2(552.9, 281.4),
		Vector2(640.5, 222.9), Vector2(596.1, 309.8), Vector2(1095.4, 205.7)]
	for p: Vector2 in spots:
		trees.append(_make_tree(rng, p.x, p.y, st))
	var t0 := Time.get_ticks_usec()
	var canvases: Array = []
	for t in trees:
		canvases.append(_tree_sprite_canvas(t, st))
	var sprites := InkCanvas.render_all(canvases)
	for i in trees.size():
		trees[i]["sprite"] = ImageTexture.create_from_image(sprites[i])
	print("[render-shot] %d tree sprites (one engine frame): %.0f ms" % [trees.size(), (Time.get_ticks_usec() - t0) / 1000.0])

	var wall_pts := PackedVector2Array()
	for i in 57:
		var a := deg_to_rad(200.0 + i * 2.5)
		wall_pts.push_back(Vector2(330.0 + cos(a) * 170.0, 640.0 + sin(a) * 120.0))
	var walls: Array[Dictionary] = [
		_wall_geom(wall_pts, false, true, 1.0, rng.next_seed(), st),
		_wall_geom(_rrect_ring(905.0, 520.0, 300.0, 170.0, 30.0, -0.18), true, false, 1.0, rng.next_seed(), st),
	]
	var crate := {"x": 700.0, "y": 360.0, "a": 26.0, "rot": 0.6, "h": 22.0}

	# --- the frame ----------------------------------------------------------------
	t0 = Time.get_ticks_usec()
	var g := InkCanvas.new(size)
	g.fill_color = st.paper
	g.fill_rect(0, 0, size.x, size.y)

	# Shadows first, as in render(): one mask for everything, tinted once.
	var t1 := Time.get_ticks_usec()
	var shadow := ShadowPass.new(size)
	_cast_shadows(shadow, trees, walls, crate, st)
	shadow.composite(g, st.shadow, st.shadow_str)
	print("[render-shot] shadow mask: %.0f ms" % [(Time.get_ticks_usec() - t1) / 1000.0])

	for w in walls:
		_draw_wall(g, w, st)
	_draw_crate(g, crate, st)
	var by_height := trees.duplicate()
	by_height.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["h"] < b["h"] or (a["h"] == b["h"] and a["y"] < b["y"]))
	for t: Dictionary in by_height:
		var s: float = t["half"] * 2.0
		g.draw_image(t["sprite"], t["x"] - t["half"], t["y"] - t["half"], s, s)

	# The canopy-shadow transform on a visible sprite: 2x along 45 degrees.
	var demo: Dictionary = trees[trees.size() - 1]
	var half: float = demo["half"]
	var az := PI / 4.0
	g.save()
	g.translate(1095.4, 330.0)
	g.rotate(az)
	g.scale(2.0, 1.0)
	g.rotate(-az)
	g.draw_image(demo["sprite"], -half, -half, half * 2.0, half * 2.0)
	g.restore()

	# Lobes straight onto the frame: canopy size, then enlarged.
	var lobe_rng := Mulberry32.new(st.scene_seed + 7)
	draw_lobe(g, 120.0, 150.0, 10.5, lobe_rng, st)
	draw_lobe(g, 160.0, 150.0, 7.0, lobe_rng, st)
	draw_lobe(g, 300.0, 170.0, 48.0, lobe_rng, st)

	var t2 := Time.get_ticks_usec()
	var grain := Grain.build_texture(size, st.scene_seed)
	print("[render-shot] grain texture: %.0f ms" % [(Time.get_ticks_usec() - t2) / 1000.0])
	Grain.apply(g, grain, st.grain)

	var img := g.finish_image()
	print("[render-shot] frame (incl. shadows, grain): %.0f ms; total %.0f ms" % [
		(Time.get_ticks_usec() - t0) / 1000.0, (Time.get_ticks_usec() - t_all) / 1000.0])
	return img

# --- Ported prototype routines -------------------------------------------------------

# scallop(cx,cy,R,n,ph,amps,wob,ns): |sin| bumps give rounded lobes with inward
# cusps. Returns [points, segment index per point].
static func scallop(cx: float, cy: float, r: float, n: int, ph: float, amps: PackedFloat64Array,
		wob: float, ns: int) -> Array:
	var pts := PackedVector2Array()
	var seg := PackedInt32Array()
	var steps := n * 9
	for i in steps + 1:
		var th := float(i) / float(steps) * PI * 2.0
		var u := float(n) * th / 2.0 + ph
		var idx := int(floorf(u / PI)) % n
		var a := amps[idx]
		var rr := r * (1.0 - a + a * pow(absf(sin(u)), 0.55))
		rr *= 1.0 + wob * 0.08 * (ValueNoise.vnoise(cos(th) * 1.6 + 7.0, sin(th) * 1.6 + 7.0, ns) * 2.0 - 1.0)
		pts.push_back(Vector2(cx + cos(th) * rr, cy + sin(th) * rr))
		seg.push_back(idx)
	return [pts, seg]

static func trace_path(g: InkCanvas, pts: PackedVector2Array) -> void:
	g.begin_path()
	for i in pts.size():
		if i:
			g.line_to(pts[i].x, pts[i].y)
		else:
			g.move_to(pts[i].x, pts[i].y)
	g.close_path()

static func draw_lobe(g: InkCanvas, x: float, y: float, r: float, rng: Mulberry32, st: Style) -> void:
	var n := maxi(5, roundi(4.5 + r / 3.0))
	var ph := rng.next() * PI
	var ns := int(rng.next() * 1e6)
	var amps := PackedFloat64Array()
	for i in n:
		amps.push_back(0.13 + rng.next() * 0.12)
	var outline: PackedVector2Array = scallop(x, y, r, n, ph, amps, st.wob, ns)[0]
	trace_path(g, outline)
	g.fill_color = st.cream
	g.fill()
	g.stroke_color = st.ink
	g.line_width = float(st.k.get("tree_outline", 1.25)) * st.lw
	g.stroke()
	# nested, broken contour rings shifted toward the light
	for k in range(1, st.rings + 1):
		var s := 1.0 - k * (0.68 / (st.rings + 0.4))
		var nk := maxi(3, n - k)
		var am := PackedFloat64Array()
		for i in nk:
			am.push_back(0.15 + rng.next() * 0.12)
		var ring: Array = scallop(x + st.lx * r * 0.1 * k, y + st.ly * r * 0.1 * k, r * s, nk, ph + k * 0.7, am, st.wob, ns + k * 31)
		var rp: PackedVector2Array = ring[0]
		var ri: PackedInt32Array = ring[1]
		g.line_width = float(st.k.get("tree_inner_rings", 0.85)) * st.lw
		g.global_alpha = 0.88
		g.begin_path()
		var seg := -1
		var draw := false
		for j in rp.size():
			if ri[j] != seg:
				seg = ri[j]
				draw = rng.next() < 0.8
				if draw:
					g.move_to(rp[j].x, rp[j].y)
				continue
			if draw:
				g.line_to(rp[j].x, rp[j].y)
		g.stroke()
		g.global_alpha = 1.0
	# short ticks from cusps toward the centre
	g.line_width = float(st.k.get("cusp_ticks", 0.75)) * st.lw
	g.begin_path()
	for m in range(1, n + 1):
		if rng.next() > 0.55:
			continue
		var th := 2.0 * (m * PI - ph) / n
		var rr := r * (1.0 - amps[m % n])
		var cx := x + cos(th) * rr
		var cy := y + sin(th) * rr
		g.move_to(cx, cy)
		g.line_to(cx - cos(th) * r * 0.15, cy - sin(th) * r * 0.15)
	g.stroke()
	# stipple on the side away from the light
	g.fill_color = st.ink
	g.global_alpha = 0.55
	var dots := roundi(r * 0.6)
	for i in dots:
		var a := rng.next() * PI * 2.0
		var d := sqrt(rng.next()) * r * 0.78
		var dx := cos(a)
		var dy := sin(a)
		if dx * st.lx + dy * st.ly > -0.15:
			continue
		g.begin_path()
		g.arc(x + dx * d, y + dy * d, 0.45, 0.0, PI * 2.0)
		g.fill()
	g.global_alpha = 1.0

# makeTree + syncTree: the model fields the sprite and the shadow read.
static func _make_tree(rng: Mulberry32, x: float, y: float, st: Style) -> Dictionary:
	var t := {"x": x, "y": y, "seed": rng.next_seed(), "sr": rng.next() * 2.0 - 1.0, "hr": rng.next(), "big": rng.next() < 0.1}
	var r: float = st.tree_size * (1.0 + st.size_var * t["sr"]) * (1.45 if t["big"] else 1.0)
	t["r"] = r
	t["h"] = r * st.height * (0.85 + 0.3 * t["hr"])
	t["half"] = float(ceili(r * 1.3 + 4.0))
	return t

# buildTreeSprite, onto a canvas that the caller renders (in a batch).
static func _tree_sprite_canvas(t: Dictionary, st: Style) -> InkCanvas:
	var r: float = t["r"]
	var half := ceili(r * 1.3 + 4.0)
	var g := InkCanvas.new(Vector2i(half * 2, half * 2))
	g.set_transform(1, 0, 0, 1, half, half)
	g.line_cap = "round"
	var rng := Mulberry32.new(t["seed"])
	var n_outer := mini(7, 3 + floori(r / 11.0) + (1 if rng.next() < 0.5 else 0))
	var a0 := rng.next() * PI * 2.0
	var lobes: Array = []
	for i in n_outer:
		var a := a0 + float(i) / n_outer * PI * 2.0 + (rng.next() - 0.5) * 0.5
		var d := r * (0.36 + rng.next() * 0.14)
		lobes.append([cos(a) * d, sin(a) * d, r * (0.34 + rng.next() * 0.16)])
	var lx := st.lx
	var ly := st.ly
	lobes.sort_custom(func(p: Array, q: Array) -> bool:
		return p[0] * lx + p[1] * ly < q[0] * lx + q[1] * ly)  # far-from-light lobes first
	var cx := (rng.next() - 0.5) * r * 0.12
	var cy := (rng.next() - 0.5) * r * 0.12
	lobes.append([cx, cy, r * (0.48 + rng.next() * 0.1)])  # crown on top
	for l: Array in lobes:
		draw_lobe(g, l[0], l[1], l[2], rng, st)
	return g

# rrectLocal(w, d, r, 3) transformed like wallCenterline's rrect.
static func _rrect_ring(cx: float, cy: float, w: float, d: float, r: float, rot: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var hx := w / 2.0
	var hy := d / 2.0
	var step := 3.0
	var segs := [[-hx + r, -hy, hx - r, -hy], [hx, -hy + r, hx, hy - r], [hx - r, hy, -hx + r, hy], [-hx, hy - r, -hx, -hy + r]]
	var arcs := [[hx - r, -hy + r, -PI / 2.0], [hx - r, hy - r, 0.0], [-hx + r, hy - r, PI / 2.0], [-hx + r, -hy + r, PI]]
	for e in 4:
		var s: Array = segs[e]
		var n := maxi(1, ceili(Vector2(s[2] - s[0], s[3] - s[1]).length() / step))
		for i in n:
			var t := float(i) / n
			pts.push_back(Vector2(s[0] + (s[2] - s[0]) * t, s[1] + (s[3] - s[1]) * t))
		var c: Array = arcs[e]
		var m := maxi(2, ceili(r * PI / 2.0 / step))
		for i in m:
			var a: float = c[2] + float(i) / m * PI / 2.0
			pts.push_back(Vector2(c[0] + cos(a) * r, c[1] + sin(a) * r))
	var xf := Transform2D(rot, Vector2(cx, cy))
	for i in pts.size():
		pts[i] = xf * pts[i]
	return pts

# wallGeom: edge polylines with hand wobble, normals, caps.
static func _wall_geom(pts: PackedVector2Array, closed: bool, caps: bool, ws: float, seed_value: int, st: Style) -> Dictionary:
	var n := pts.size()
	var hw := st.wall_w * ws / 2.0
	var nrm := PackedVector2Array()
	var lp := PackedVector2Array()
	var rp := PackedVector2Array()
	for i in n:
		var a := pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b := pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var tng := b - a
		var l := tng.length()
		if l == 0.0:
			l = 1.0
		var nn := Vector2(-tng.y / l, tng.x / l)
		var el := (ValueNoise.vnoise(i * 0.18, 1.3, seed_value) * 2.0 - 1.0) * st.wob * 1.3
		var er := (ValueNoise.vnoise(i * 0.18, 5.1, seed_value) * 2.0 - 1.0) * st.wob * 1.3
		nrm.push_back(nn)
		lp.push_back(pts[i] + nn * (hw + el))
		rp.push_back(pts[i] - nn * (hw + er))
	var w := {"pts": pts, "nrm": nrm, "L": lp, "R": rp, "hw": hw, "closed": closed, "h": st.wall_h,
		"ce": PackedVector2Array(), "cs": PackedVector2Array(), "caps": []}
	if not closed and caps:
		var ce := _cap(pts[n - 1], atan2(nrm[n - 1].y, nrm[n - 1].x), hw)
		var cs := _cap(pts[0], atan2(nrm[0].y, nrm[0].x) + PI, hw)
		w["ce"] = ce
		w["cs"] = cs
		var c0 := ce.duplicate()
		c0.append_array(PackedVector2Array([lp[n - 1], rp[n - 1]]))
		var c1 := cs.duplicate()
		c1.append_array(PackedVector2Array([lp[0], rp[0]]))
		w["caps"] = [c0, c1]
	return w

static func _cap(c: Vector2, start_ang: float, hw: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in range(1, 8):
		var a := start_ang - k * PI / 8.0
		out.push_back(Vector2(c.x + cos(a) * hw, c.y + sin(a) * hw))
	return out

static func _add_poly(g: InkCanvas, p: PackedVector2Array, closed: bool) -> void:
	g.move_to(p[0].x, p[0].y)
	for i in range(1, p.size()):
		g.line_to(p[i].x, p[i].y)
	if closed:
		g.close_path()

# drawWall: the band, the slope tone, the edges (the stipple, hatching, crest
# and pebbles are left to the real port).
static func _draw_wall(g: InkCanvas, w: Dictionary, st: Style) -> void:
	var pts: PackedVector2Array = w["pts"]
	var nrm: PackedVector2Array = w["nrm"]
	var lp: PackedVector2Array = w["L"]
	var rp: PackedVector2Array = w["R"]
	var hw: float = w["hw"]
	var closed: bool = w["closed"]
	var n := pts.size()
	var lim := n if closed else n - 1
	var sd := _shadow_dir(st)
	g.line_cap = "round"
	g.fill_color = st.wall
	g.fill_band(lp, rp, closed, w["ce"], w["cs"])
	# tonal slope on the side facing away from the sun
	g.stroke_color = _mix(st.shadow, st.wall, 1.0 - st.slope_mix)
	g.line_width = hw * 0.7
	g.line_cap = "butt"
	g.global_alpha = 0.6
	for side in [1.0, -1.0]:
		g.begin_path()
		var pen := false
		for k in lim + 1:
			var i := k % n
			var f: Vector2 = nrm[i] * side
			if f.x * sd.x + f.y * sd.y < 0.2:
				pen = false
				continue
			var q := pts[i] + f * hw * 0.55
			if not pen:
				g.move_to(q.x, q.y)
				pen = true
			else:
				g.line_to(q.x, q.y)
		g.stroke()
	g.global_alpha = 1.0
	g.line_cap = "round"
	# outer edges
	g.stroke_color = st.ink
	g.line_width = float(st.k.get("wall_edges", 1.15)) * st.lw
	g.begin_path()
	if closed:
		_add_poly(g, lp, true)
		_add_poly(g, rp, true)
	else:
		var loop := lp.duplicate()
		loop.append_array(w["ce"])
		var rr := rp.duplicate()
		rr.reverse()
		loop.append_array(rr)
		loop.append_array(w["cs"])
		_add_poly(g, loop, true)
	g.stroke()

static func _draw_crate(g: InkCanvas, c: Dictionary, st: Style) -> void:
	var a: float = c["a"]
	g.save()
	g.translate(c["x"], c["y"])
	g.rotate(c["rot"])
	g.fill_color = st.cream
	g.fill_rect(-a, -a, a * 2.0, a * 2.0)
	g.stroke_color = st.ink
	g.line_width = 0.95 * st.lw
	g.begin_path()
	g.rect(-a, -a, a * 2.0, a * 2.0)
	g.stroke()
	g.line_width = 0.7 * st.lw
	g.begin_path()
	g.rect(-a * 0.6, -a * 0.6, a * 1.2, a * 1.2)
	g.move_to(-a * 0.6, -a * 0.6)
	g.line_to(a * 0.6, a * 0.6)
	g.stroke()
	g.restore()

static func _crate_corners(c: Dictionary) -> PackedVector2Array:
	var a: float = c["a"]
	var xf := Transform2D(c["rot"], Vector2(c["x"], c["y"]))
	return PackedVector2Array([xf * Vector2(-a, -a), xf * Vector2(a, -a), xf * Vector2(a, a), xf * Vector2(-a, a)])

# castShadows for these objects: prism hulls, trunks, stretched canopies.
static func _cast_shadows(sp: ShadowPass, trees: Array[Dictionary], walls: Array[Dictionary], crate: Dictionary, st: Style) -> void:
	var az := (st.sun_az + 90.0) * PI / 180.0
	var dx := cos(az)
	var dy := sin(az)
	var L := 1.0 / tan(st.elev * PI / 180.0)
	var stretch := minf(2.4, 1.0 + L * 0.3)
	var prism := func(q: PackedVector2Array, h: float) -> void:
		var all := q.duplicate()
		for p in q:
			all.push_back(p + Vector2(dx * h * L, dy * h * L))
		sp.draw_polygon(Geometry2D.convex_hull(all))
	for w in walls:
		var lp: PackedVector2Array = w["L"]
		var rp: PackedVector2Array = w["R"]
		var n := lp.size()
		var lim := n if w["closed"] else n - 1
		for i in lim:
			var j := (i + 1) % n
			prism.call(PackedVector2Array([lp[i], lp[j], rp[j], rp[i]]), w["h"])
		for c: PackedVector2Array in w["caps"]:
			prism.call(c, w["h"])
	prism.call(_crate_corners(crate), crate["h"])
	for t in trees:
		var off: float = t["h"] * L
		var sx: float = t["x"] + dx * off
		var sy: float = t["y"] + dy * off
		var half: float = t["half"]
		sp.draw_line(Vector2(t["x"], t["y"]), Vector2(sx, sy), maxf(1.5, t["r"] * 0.12))
		var xf := Transform2D(0.0, Vector2(sx, sy)) * Transform2D(az, Vector2.ZERO) \
			* Transform2D(Vector2(stretch, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) * Transform2D(-az, Vector2.ZERO)
		sp.draw_silhouette_texture(t["sprite"], xf, Rect2(-half, -half, half * 2.0, half * 2.0))

static func _shadow_dir(st: Style) -> Vector2:
	var az := (st.sun_az + 90.0) * PI / 180.0
	return Vector2(cos(az), sin(az))

# mix(a, b, t): the prototype rounds each channel to an integer.
static func _mix(a: Color, b: Color, t: float) -> Color:
	return Color8(roundi(a.r8 + (b.r8 - a.r8) * t), roundi(a.g8 + (b.g8 - a.g8) * t), roundi(a.b8 + (b.b8 - a.b8) * t))

# --- Data ---------------------------------------------------------------------

static func _load_style() -> Style:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	var params: Dictionary = raw if raw is Dictionary else {}
	var pal: Dictionary = params.get("palette", {})
	var par: Dictionary = params.get("parameters", {})
	var lines: Dictionary = params.get("linework", {})
	var light: Dictionary = lines.get("detail_light", {})
	var tints: Dictionary = pal.get("shadow_tints", {})
	var st := Style.new()
	st.paper = Color.html(pal.get("paper", "#D9CCAA"))
	st.ink = Color.html(pal.get("ink", "#3D3226"))
	st.cream = Color.html(pal.get("object_fill", "#EFE6CD"))
	st.wall = Color.html(pal.get("wall_fill", "#E2D7BA"))
	var tint_name: String = par.get("shadow_tint", {}).get("default", "steel")
	st.shadow = Color.html(tints.get(tint_name, "#3D6C8F"))
	st.lw = _def(par, "line_weight", 0.8)
	st.wob = _def(par, "hand_wobble", 0.6)
	st.rings = int(_def(par, "inner_contour_rings", 3))
	st.tree_size = _def(par, "canopy_size", 19)
	st.size_var = _def(par, "size_variation", 0.4)
	st.height = _def(par, "tree_height", 1.3)
	st.wall_w = _def(par, "wall_width", 16)
	st.wall_h = _def(par, "wall_height", 12)
	st.sun_az = _def(par, "sun_direction", 315)
	st.elev = _def(par, "sun_elevation", 46)
	st.shadow_str = _def(par, "shadow_strength", 0.92)
	st.grain = _def(par, "paper_grain", 0.55)
	st.lx = float(light.get("x", -sqrt(0.5)))
	st.ly = float(light.get("y", -sqrt(0.5)))
	st.k = lines
	st.slope_mix = float(pal.get("wall_slope_shadow_mix", 0.30))
	st.scene_seed = int(params.get("scene_seed", 20261009))
	return st

static func _def(par: Dictionary, key: String, fallback: float) -> float:
	var entry: Variant = par.get(key, {})
	if entry is Dictionary:
		return float((entry as Dictionary).get("default", fallback))
	return fallback
