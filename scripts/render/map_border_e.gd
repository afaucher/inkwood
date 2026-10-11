extends "res://scripts/render/map_border_a.gd"

# OPTION E, THE GAME'S LOOK: "Hatched edge with the distance legend" (builder, map-border board, 2026-10-11). Alex, choosing from
# variants/map-border (decision map-border, 2026-10-11): "I like the hatches, with the distance legend." = option A's hatched edge onto
# blank paper (map_border_a.gd: the heavy edge line, the fine rule, the perpendicular hatching clipped to the band, the paper going
# on) PLUS option B's distance legend (map_border_legend.gd: a tick every 500 m with its number in metres, and at the full zoom-out
# the scale bar); NOT B's double-ruled neatline (A's heavy line and hatch are the edge) and NOT B's north arrow (not asked for).
#
# The numbers sit INSIDE the map, just inside the edge line, on the map's paper halo, so they never lie on the hatching (see
# map_border_legend.gd for why not outside it). The look is chosen; every number in it is still a proposed record in
# data/view/map_border.json (the a.* records for the edge, the e.* records for the legend). A, B, C and D stay switchable.

const Screen = preload("res://scripts/render/map_border_screen.gd")
const Legend = preload("res://scripts/render/map_border_legend.gd")

var legend: Legend
var _screen: Screen
var _xf := Transform2D()
var _vp := Vector2(1280, 720)
var _zoom := 1.0
var _rule_gap := 4.5
var _hatch_depth := 56.0

func build() -> void:
	super.build()
	var d: CameraData = b.data
	d.text("e.name")
	_rule_gap = d.num("a.rule2.gap_px")
	_hatch_depth = d.num("a.hatch.depth_px")
	legend = Legend.new(b)
	_screen = Screen.new()
	_screen.painter = Callable(self, "_paint")
	b.add_child(_screen)

func frame(xf: Transform2D, zoom: float, vp: Vector2) -> void:
	super.frame(xf, zoom, vp)
	_xf = xf
	_vp = vp
	_zoom = zoom
	var view: Node2D = b.view
	_screen.pin(xf * view.get_global_transform().affine_inverse())
	_screen.repaint()

# How far outside the edge the hatching reaches on screen: the hairline's gap plus the hatch depth, never more than the band.
func hatch_clear_px() -> float:
	var band_px: float = band_m * float(b.px_per_m) * _zoom
	return minf(_hatch_depth + _rule_gap, band_px) + 4.0

func _paint(ci: CanvasItem) -> void:
	legend.paint(ci, _xf, _vp, hatch_clear_px())

func stats() -> Dictionary:
	return {"paint_us": legend.paint_us, "paint_us_max": legend.paint_us_max, "paints": legend.paints, "labels": legend.drawn_labels.size(), "ticks": legend.drawn_ticks.size()}
