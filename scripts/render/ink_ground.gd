extends RefCounted

# The paper ground and the road, ported line for line from the prototype
# (reference/inkwood-renderer.html) onto the drawing layer:
#
#   prototype                     here
#   buildGround()                 build_ground(size, roadPts, P, paper_shader) -> ImageTexture
#     the 1/3-res paper tint        paper_pixel(P) through Paper.build (GDScript, exact) or
#                                   Paper.build_shader (shaders/paper_tint.gdshader)
#     specks, fibres, dirt          draw_ground(g, W, H, roadPts, P, paper, rng, road_rng)
#   drawRoad(g)                   draw_road(g, roadPts, P, rng = null)
#   buildGrain()                  build_grain(size, seed) -> ImageTexture   (Grain, seeded)
#
# The ground is its own W x H canvas, as in the prototype (it is built once
# per stage size and drawn with one drawImage at the start of every render).
#
# THE PAPER TINT has two implementations (scripts/render/paper.gd): the
# GDScript path evaluates the prototype's two fbm per 1/3-res pixel exactly
# (scripts/core/noise.gd; ~2.2 s at 1280x720) and is the default; the shader
# twin (fp32 noise, exact lattice) agrees on all but a handful of pixels by
# one 8-bit step and takes ~15 ms. `paper_shader` picks; both are seeded by
# nothing but position, as in the prototype.
#
# THE RNG STREAMS: specks and dirt come from mulberry32(4242) and the road
# from mulberry32(77), both in the prototype's order. The dirt-patch test
# `f<.58||rng()>(f-.58)*4` decides from fbm whether a draw happens at all, so
# fbm here is scripts/core/noise.gd's (exact), never the shader's.
#
# Colours and weights: P.PAPER / INK / DIRT / CREAM, road ruts P.linework.road_ruts.
# One colour the data file does not carry yet: the light paper fibre
# "#f4ecd6" (FIBRE_LIGHT below; a palette role for it is PROPOSED).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Paper = preload("res://scripts/render/paper.gd")
const Grain = preload("res://scripts/render/grain.gd")

# The prototype's light paper fibre: g.strokeStyle=rng()<.5?INK:"#f4ecd6".
# PROPOSED: a palette role in data/params/render_defaults.json (e.g.
# palette.paper_fibre_light); until then the prototype's literal, here only.
const FIBRE_LIGHT := Color8(0xf4, 0xec, 0xd6)
# Downscale of the paper tint: const S=3.
const PAPER_SCALE := 3
const PAPER_SHADER_PATH := "res://scripts/render/shaders/paper_tint.gdshader"

# One 1/3-res paper pixel at world (wx, wy), channels 0..255 as ImageData holds them:
#   n=fbm(wx*.008,wy*.008,11,4), m=fbm(wx*.0025,wy*.0025,23,3), k=.93+.11*n;
#   d[i]=PAPER[0]*k+(m-.5)*14; d[i+1]=PAPER[1]*k+(m-.5)*8; d[i+2]=PAPER[2]*k-(m-.5)*8;
static func paper_pixel(P: RenderParams) -> Callable:
	var pr := float(P.PAPER.r8)  # PAPER=[217,204,170]
	var pg := float(P.PAPER.g8)
	var pb := float(P.PAPER.b8)
	return func(wx: float, wy: float) -> Vector3:
		var n := ValueNoise.fbm(wx * 0.008, wy * 0.008, 11, 4)
		var m := ValueNoise.fbm(wx * 0.0025, wy * 0.0025, 23, 3)
		var k := 0.93 + 0.11 * n
		return Vector3(pr * k + (m - 0.5) * 14.0, pg * k + (m - 0.5) * 8.0, pb * k - (m - 0.5) * 8.0)

# The paper tint at frame size: sg.putImageData(img,0,0); g.drawImage(small,0,0,lw*S,lh*S).
static func build_paper(size: Vector2i, P: RenderParams, paper_shader: bool = false) -> ImageTexture:
	if paper_shader:
		var mat := ShaderMaterial.new()
		mat.shader = load(PAPER_SHADER_PATH)
		mat.set_shader_parameter("paper", Vector3(P.PAPER.r8, P.PAPER.g8, P.PAPER.b8))
		return Paper.build_shader(size, PAPER_SCALE, mat)
	return Paper.build(size, PAPER_SCALE, paper_pixel(P))

# function buildGround(): the paper, then the road, on one W x H canvas,
# rendered to a texture. `paper` is build_paper()'s result (made here when null).
static func build_ground(size: Vector2i, roadPts: Array, P: RenderParams, paper_shader: bool = false,
		paper: Texture2D = null) -> ImageTexture:
	if paper == null and P.L.paper:
		paper = build_paper(size, P, paper_shader)
	var g := InkCanvas.new(size)  # ground.width=Math.round(W*DPR); ground.height=Math.round(H*DPR);
	draw_ground(g, float(size.x), float(size.y), roadPts, P, paper)
	return g.finish_texture()

# buildGround's drawing, onto `g`: the paper tint, specks and fibres, dirt
# stipple patches, then drawRoad. rng / road_rng are mulberry32(4242) and
# mulberry32(77) unless a test hands its own in.
static func draw_ground(g: InkCanvas, W: float, H: float, roadPts: Array, P: RenderParams, paper: Texture2D,
		rng: Mulberry32 = null, road_rng: Mulberry32 = null) -> void:
	g.set_transform(1, 0, 0, 1, 0, 0)  # g.setTransform(DPR,0,0,DPR,0,0) -- DPR is 1
	g.global_alpha = 1.0
	if P.L.paper:
		# The 1/3-res tint, upscaled and cropped to W x H by Paper.build already.
		g.draw_image(paper, 0.0, 0.0, W, H)
		if rng == null:
			rng = Mulberry32.new(4242)  # const rng=mulberry32(4242)
		# specks and fibres
		var specks := roundi(W * H / 90.0)  # Math.round(W*H/90) -- positive, so roundi agrees
		for _i in specks:
			var x := rng.next() * W
			var y := rng.next() * H
			if rng.next() < 0.85:
				g.global_alpha = 0.12 + rng.next() * 0.28
				g.fill_color = P.INK
				var s := 0.5 + rng.next() * 0.9
				g.fill_rect(x, y, s, s)
			else:
				g.global_alpha = 0.18
				g.stroke_color = P.INK if rng.next() < 0.5 else FIBRE_LIGHT
				g.line_width = 0.5
				g.begin_path()
				g.move_to(x, y)
				var a := rng.next() * 6.28
				var l := 1.5 + rng.next() * 3.0
				g.line_to(x + cos(a) * l, y + sin(a) * l)
				g.stroke()
		# dirt stipple patches driven by a noise field
		g.fill_color = P.DIRT
		var darts := roundi(W * H / 12.0)  # Math.round(W*H/12)
		for _i in darts:
			var x := rng.next() * W
			var y := rng.next() * H
			var f := ValueNoise.fbm(x * 0.011, y * 0.011, 91, 3)
			if f < 0.58 or rng.next() > (f - 0.58) * 4.0:  # || short-circuits: no draw when f < .58
				continue
			g.global_alpha = 0.15 + rng.next() * 0.25
			var s := 0.6 + rng.next() * 0.8
			g.fill_rect(x, y, s, s)
		g.global_alpha = 1.0
	else:
		g.fill_color = P.PAPER  # g.fillStyle=`rgb(${PAPER})`
		g.fill_rect(0.0, 0.0, W, H)
	if P.L.road:
		draw_road(g, roadPts, P, road_rng)

# --- road: offset rut lines, dirt, pebbles --------------------------------------------

# function drawRoad(g): dirt specks across the road, eight wobbly broken rut
# and edge lines offset along the normals, and pebbles along both verges.
# roadPts are scene_gen's {x, y, nx, ny} (buildRoad's sampling).
static func draw_road(g: InkCanvas, roadPts: Array, P: RenderParams, rng: Mulberry32 = null) -> void:
	if rng == null:
		rng = Mulberry32.new(77)  # const rng=mulberry32(77)
	var ROAD_HALF := P.ROAD_HALF
	g.fill_color = P.DIRT
	for p: Dictionary in roadPts:
		for _k in 6:
			var t := rng.next() * 2.0 - 1.0
			if rng.next() > 1.0 - absf(t) * 0.65:
				continue
			var off := t * ROAD_HALF * 1.5
			g.global_alpha = 0.14 + rng.next() * 0.2
			# fillRect's x argument is evaluated (and draws) before its y argument
			var x: float = p.x + p.nx * off + (rng.next() - 0.5) * 3.0
			var y: float = p.y + p.ny * off + (rng.next() - 0.5) * 3.0
			g.fill_rect(x, y, 0.9, 0.9)
	g.stroke_color = P.INK
	g.line_cap = "round"  # g.lineCap="round"; g.lineJoin="round";
	var lines := [{"o": -9.0, "a": 0.6}, {"o": -7.2, "a": 0.35}, {"o": -10.9, "a": 0.3}, {"o": 9.0, "a": 0.6},
		{"o": 7.2, "a": 0.35}, {"o": 10.9, "a": 0.3}, {"o": -ROAD_HALF, "a": 0.3}, {"o": ROAD_HALF, "a": 0.3}]
	for li in lines.size():  # lines.forEach((L,li)=>{
		var L: Dictionary = lines[li]
		var ns := 1000 + li * 13
		g.global_alpha = L.a
		g.line_width = P.linework["road_ruts"] * P.lw  # JS: .8*P.lw
		g.begin_path()
		var pen := false
		var o: float = L.o
		for i in roadPts.size():  # roadPts.forEach((p,i)=>{
			var p: Dictionary = roadPts[i]
			if ValueNoise.vnoise(i * 0.045, 3.3, ns) < 0.3:
				pen = false
				continue  # JS: return (from the forEach callback)
			var j := (ValueNoise.vnoise(i * 0.09, 1.7, ns + 5) - 0.5) * 2.6 * (0.35 + P.wob)
			var x: float = p.x + p.nx * (o + j)
			var y: float = p.y + p.ny * (o + j)
			if not pen:
				g.move_to(x, y)
				pen = true
			else:
				g.line_to(x, y)
		g.stroke()
	for i in range(0, roadPts.size(), 5):  # for(let i=0;i<roadPts.length;i+=5)
		if rng.next() < 0.45:
			continue
		var p: Dictionary = roadPts[i]
		var off := (-1.0 if rng.next() < 0.5 else 1.0) * (ROAD_HALF + 1.0 + rng.next() * 8.0)
		var rr := 0.6 + rng.next() * 1.4
		g.begin_path()
		g.arc(p.x + p.nx * off, p.y + p.ny * off, rr, 0.0, PI * 2.0)
		g.global_alpha = 0.9
		g.fill_color = P.CREAM
		g.fill()
		g.global_alpha = 0.55
		g.line_width = 0.6 * P.lw
		g.stroke()
	g.global_alpha = 1.0

# --- grain ---------------------------------------------------------------------------

# function buildGrain(): SEEDED here (Grain), where the prototype uses
# Math.random -- so the browser's grain can never match pixel for pixel.
static func build_grain(size: Vector2i, seed_value: int) -> ImageTexture:
	return Grain.build_texture(size, seed_value)
