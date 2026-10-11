extends RefCounted

# CONTOURS PAST THE MAP'S EDGE (builder, map-border board, 2026-10-11; PROPOSED). Records the topographic layer's contour lines --
# the fog's own drawing, FogTopo._add_offset, with the same wobble and the same thinning at a coarse level of detail -- for a
# rectangle of map px ANYWHERE, not only over the map's chunks. FogTopo's own _contours asks the terrain for the chunks of the MAP
# a rectangle touches (Terrain.chunks_in_rect_px keeps only those); the terrain itself generates a chunk from (seed, chunk) alone,
# so here every chunk the rectangle touches is asked for, inside the map or out: the height field is continuous past the edge.
#
# The lines are recorded in WHITE at full alpha, so the canvas's alpha is the line's coverage and the baked texture can be
# one channel (R8): the ink colour, its alpha and the fade to blank paper are the shader's (map_border_contour.gdshader).
#
# THREADS: `topo` is a FogTopo twin over a private Terrain (FogTopo.make_twin's way, made on the main thread by the option) and is
# used by one task at a time; nothing here touches the shared terrain, the shared CameraData or the RenderingServer.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

# The canvas of `rect` (map px) at `s` texels per map px: the land's contours and, with `water_lines`, the sea's shore and depth
# steps (FogTopo._water_lines, quieter by the fog's own line alphas). `topo` is the twin.
static func record(topo: RefCounted, rect: Rect2, s: float, water_lines: bool) -> InkCanvas:
	var size := Vector2i(maxi(1, ceili(rect.size.x * s - 1e-6)), maxi(1, ceili(rect.size.y * s - 1e-6)))
	var g := InkCanvas.new(size)
	var view := Transform2D(Vector2(s, 0.0), Vector2(0.0, s), -rect.position * s)
	g.set_transform_matrix(view)
	var terrain: RefCounted = topo.terrain
	var cpx: float = terrain.chunk_m * terrain.px_per_m
	var reach := 0.0
	for o: float in topo.offsets_px:
		reach = maxf(reach, o)
	var near := rect.grow(reach + topo.wobble_px + topo.line_w / s + 2.0)
	var every := maxi(1, floori(1.0 / (s * terrain.resample_m * terrain.px_per_m)))
	var wob: float = topo.wobble_px if topo.wobble_px * s >= 0.2 else 0.0
	g.stroke_color = Color.WHITE
	g.line_width = topo.line_w / s
	g.line_cap = "round"
	g.global_alpha = 1.0
	var c0 := Vector2i(floori(near.position.x / cpx), floori(near.position.y / cpx))
	var c1 := Vector2i(floori(near.end.x / cpx), floori(near.end.y / cpx))
	for k in terrain.thresholds.size():
		var chains: Array = []
		for cy in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				chains.append_array(terrain.chains_px(cx, cy, k))
		if chains.is_empty():
			continue
		for j in topo.offsets_px.size():
			g.begin_path()
			var any := false
			for ch: Dictionary in chains:
				any = topo._add_offset(g, ch.pts, ch.closed, topo.offsets_px[j], k, near, every, wob) or any
			if any:
				g.stroke()
	if water_lines and topo.water != null:
		var wet: Dictionary = topo._water_geo(rect, s)
		if not wet.is_empty():
			var saved: Color = topo.line_color
			topo.line_color = Color.WHITE
			topo._water_lines(g, rect, s, wet)
			topo.line_color = saved
	g.global_alpha = 1.0
	return g
