extends "res://scripts/render/map_border_base.gd"

# OPTION A, "Hatched edge onto blank paper" (builder, map-border board, 2026-10-11; PROPOSED). Alex's idea (2026-10-11): "The hatch
# edging onto a continued blank paper pattern. Clipped so you just see it as the border but not beyond."
#
# The paper continues past the edge (the map's own tint at world coordinates, its grain, no ink and no specks). Along the edge: a
# heavy ink line, a fine rule outside it, and a band of ink hatch lines pointing OUTWARD (perpendicular to the edge, a fan at each
# corner), their ends ragged and tapering, clipped to the band (reach.band_m, and never deeper than hatch.depth_px on screen).
# It is all one shader (map_border_edge.gdshader), in screen px like the fog's inked edge, so a line keeps its width at every zoom.
#
# READING AS THE WORLD'S EDGE, NOT THE FOG'S: the fog's sight edge is a 1.5 px line with 4 px-spaced 0.9 px hatching at 45 degrees,
# 26 px deep, at alpha 0.55. This is HEAVIER (2.6 px line, 1.1 px hatch at alpha 0.8), DENSER (3 px spacing) and DEEPER (56 px),
# DOUBLED (a fine rule 4.5 px outside the heavy line), and PERPENDICULAR to the edge. The board's notes say the same.

func build() -> void:
	var d: CameraData = b.data
	d.text("a.name")
	var f := make_fill(true, b.role("paper.role"))
	var edge_color: Color = b.role("a.edge.line_role")
	f.set_param("line_color", vec4(edge_color))
	f.set_param("line_px", d.num("a.edge.line_px"))
	f.set_param("wobble_px", d.num("a.edge.wobble_px"))
	f.set_param("wobble_freq", d.num("a.edge.wobble_per_px"))
	var r2: Color = b.role("a.rule2.role")
	f.set_param("rule2_color", vec4(r2))
	f.set_param("rule2_px", d.num("a.rule2.px"))
	var gap := d.num("a.rule2.gap_px")
	f.set_param("rule2_gap", gap)
	var h: Color = b.role("a.hatch.role")
	f.set_param("hatch_on", true)
	f.set_param("hatch_color", vec4(h))
	f.set_param("hatch_spacing", d.num("a.hatch.spacing_px"))
	f.set_param("hatch_width", d.num("a.hatch.width_px"))
	f.set_param("hatch_depth", d.num("a.hatch.depth_px"))
	f.set_param("hatch_min", d.num("a.hatch.ragged_min"))
	f.set_param("hatch_jitter", d.num("a.hatch.jitter"))
	f.set_param("hatch_taper", d.num("a.hatch.taper"))
	f.set_param("hatch_start", gap)   # the hatching begins at the fine rule

func frame(_xf: Transform2D, zoom: float, _vp: Vector2) -> void:
	fill.set_zoom(zoom)
	# the band is reach.band_m deep on screen (px per metre x zoom); the hatching is clipped to it
	fill.set_param("band_px", band_m * b.px_per_m * zoom)
