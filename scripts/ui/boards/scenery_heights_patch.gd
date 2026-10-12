extends RefCounted

# THE SCENERY-HEIGHTS BOARD'S OVERRIDE (builder SH, 2026-10-11). BOARD ONLY: nothing in the game or its data files changes.
#
# RETIRED 2026-10-12: Alex chose S1 (decision scenery-heights) and it is live as DATA (render_defaults.json: wall_height,
# house_height_ratio, tree_height_scale, tree_height_min_px, tree_height_max_px, each with its prototype_default; read by
# scene_gen.gd sync_tree and structures.gd sync_struct). apply() now refuses, so the board cannot be re-run under a wrong label
# (an "S0" frame would be S1). The text below describes how the board worked.
#
# Scenery heights come out of three lines of the port, and none of them has a data key that can say "7 m":
#
#   trees   scripts/world/scene_gen.gd   sync_tree     t.h = t.r * P.height * (0.85 + 0.3 * t.hr)        (tree_height is a multiple of the crown's radius)
#   walls   scripts/world/structures.gd  sync_struct   s.h = P.wallH * s.hs                              (wall_height, px, a data key)
#   houses  scripts/world/structures.gd  sync_struct   s.h = P.houseSize * 0.9 * s.hs                    (the 0.9 is a literal; houseSize is the footprint's scale too)
#   hedges  scripts/render/village_draw.gd             t.h = hedge tree's r * P.height * (..) * 0.5      (terrain.json draw.fields.hedge.height_frac; already about 2 m, left as is)
#
# A height drives the SHADOW only: the sprites, the footprints, the crowns and the placement (the collision radii, the
# random stream) do not read it. So to look at other heights this file rewrites those two lines in MEMORY, before anything
# loads them (Script.source_code + reload(): the files on disk are never touched), and puts the option's numbers where the
# patched lines read them (Engine meta "scenery_heights"). With no meta, or an empty one, the lines compute exactly what
# they computed before. Everything is in METRES here and turned into map px by the board (px_per_m 2 today).
#
# The patched lines are not the follow-up. If Alex picks an option, the permanent change is data plus two small code
# edits (see board.json "to_make_it_live"): a house_height key next to wall_height, and a tree height window
# (tree_height_min_m / tree_height_max_m) read by sync_tree. The 0.9 literal and the clamp are the only places that
# need code; walls and the tree multiple are data edits today.
#
# Use, BEFORE the first load of scene_gen.gd or structures.gd in the process:
#   var Patch = load("res://scripts/ui/boards/scenery_heights_patch.gd")
#   var err: String = Patch.apply(option_dict, px_per_m)      # "" when both lines were patched
#
# `option`: {"tree_mult": 1.0, "tree_min_m": 8.0, "tree_max_m": 20.0, "house_mult": 0.5555, "wall_mult": 0.3333}. A key left out is
# "no change": tree_min_m / tree_max_m 0 mean no clamp on that side.

const META := "scenery_heights"

const SCENE_GEN := "res://scripts/world/scene_gen.gd"
const STRUCTURES := "res://scripts/world/structures.gd"

const TREE_FIND := "\tt.h = t.r * P.height * (0.85 + 0.3 * t.hr)\n"
const TREE_REPLACE := "\tt.h = t.r * P.height * (0.85 + 0.3 * t.hr)\n" \
	+ "\tvar sh_board: Dictionary = Engine.get_meta(\"scenery_heights\", {})   # BOARD OVERRIDE (scenery_heights_patch.gd)\n" \
	+ "\tif not sh_board.is_empty():\n" \
	+ "\t\tt.h = t.h * float(sh_board[\"tree_mult\"])\n" \
	+ "\t\tif float(sh_board[\"tree_min_px\"]) > 0.0:\n" \
	+ "\t\t\tt.h = maxf(t.h, float(sh_board[\"tree_min_px\"]))\n" \
	+ "\t\tif float(sh_board[\"tree_max_px\"]) > 0.0:\n" \
	+ "\t\t\tt.h = minf(t.h, float(sh_board[\"tree_max_px\"]))\n"

const STRUCT_FIND := "\ts.h = (P.wallH if s.kind == \"wall\" else P.houseSize * 0.9) * s.hs\n"
const STRUCT_REPLACE := "\ts.h = (P.wallH if s.kind == \"wall\" else P.houseSize * 0.9) * s.hs\n" \
	+ "\tvar sh_board: Dictionary = Engine.get_meta(\"scenery_heights\", {})   # BOARD OVERRIDE (scenery_heights_patch.gd)\n" \
	+ "\tif not sh_board.is_empty():\n" \
	+ "\t\ts.h = s.h * float(sh_board[\"wall_mult\"] if s.kind == \"wall\" else sh_board[\"house_mult\"])\n"

# Patches the two scripts and sets the numbers. Returns "" on success, else what went wrong (nothing is then left half done:
# the meta is set only after both patches compiled).
static func apply(option: Dictionary, px_per_m: float) -> String:
	var sg: GDScript = load(SCENE_GEN) as GDScript
	if sg != null and sg.source_code.contains("treeHeightScale"):
		return "RETIRED: the scenery heights are data now (decision scenery-heights, S1 is live in render_defaults.json); this override no longer applies"
	if option.is_empty():
		clear()
		return ""
	var err := _patch(SCENE_GEN, TREE_FIND, TREE_REPLACE)
	if err != "":
		return err
	err = _patch(STRUCTURES, STRUCT_FIND, STRUCT_REPLACE)
	if err != "":
		return err
	Engine.set_meta(META, {
		"tree_mult": float(option.get("tree_mult", 1.0)),
		"tree_min_px": float(option.get("tree_min_m", 0.0)) * px_per_m,
		"tree_max_px": float(option.get("tree_max_m", 0.0)) * px_per_m,
		"house_mult": float(option.get("house_mult", 1.0)),
		"wall_mult": float(option.get("wall_mult", 1.0)),
	})
	return ""

static func clear() -> void:
	if Engine.has_meta(META):
		Engine.remove_meta(META)

static func _patch(path: String, find: String, replace: String) -> String:
	var script: GDScript = load(path) as GDScript
	if script == null or not script.can_instantiate():
		return "%s did not load" % path
	var src: String = script.source_code
	if src.contains("BOARD OVERRIDE (scenery_heights_patch.gd)"):
		return ""    # already patched in this process
	if src.count(find) != 1:
		return "%s: the line to patch was found %d times (it was edited since this board was written?):\n%s" % [path, src.count(find), find]
	script.source_code = src.replace(find, replace)
	var e := script.reload()
	if e != OK:
		return "%s: reload failed (%s)" % [path, error_string(e)]
	if not script.can_instantiate():
		return "%s: the patched source does not compile" % path
	return ""
