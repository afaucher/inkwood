extends RefCounted

# THE LINE CHECK (builder LOF1, stage 1 of the lines of fire, 2026-10-11; decision line-of-fire, option b). Where does a straight
# line from one 3D point to another stop? Walked across the height grid (scripts/sim/height_grid.gd) in 2.5D: the line's height in
# each cell it crosses against that cell's top. Pure and deterministic: no engine RNG, no combat stream, no nodes. NOT USED BY COMBAT
# YET (data/sim/line_of_fire.json `enabled` is false); stage 2 hooks it to the odds and the misses.
#
#   var lof := LineOfFire.new(grid)                         # grid: HeightGrid; the rules are the grid's
#   var r := lof.trace(from3, to3, roll_key)                # Vector3 in metres: x, y on the map (y down), z above sea level
#   r.clear -> bool                                         # the line reached its end
#   r.t, r.x, r.y, r.z   where it stopped (t: 0 at from, 1 at to)
#   r.kind               "cell" (a wall, a house, the sandbags, a hill, the ground) or "canopy" (a tree)
#   r.material           the material id; r.material_name "stone", "timber", ...; r.cell, r.top (a cell) or r.canopy (a tree's id)
#   var e := lof.exposure(from3, target_boxes, roll_key)   # the share of a target in view, box by box (hull, turret), with the lines
#   e.share, e.visible, e.boxes[i].share / .part / .lines[j].reach / .stop
#
# THE WALK. A line is walked first across COARSE BLOCKS (data grid.block_m, 16 m): a block keeps the highest top in it, and a line
# that passes above that for the whole block skips it. A block the line goes low over is walked cell by cell (Amanatides and Woo:
# the next cell is the one whose boundary the line meets first). A cell stops the line where the line is below its top
# (data trace.clear_eps_m of slack, so a line laid exactly on flat ground, or on a wall's top, is clear): at the cell's top if the
# line comes down onto it, at the cell's side if it runs into it.
#
# CANOPIES ARE THIN. A tree is a disc and a band of height (the grid's canopies). A line that passes through one is stopped with a
# chance from data (canopy.stop_chance, scaled by how much of the crown's diameter the line goes through: canopy.scale_by_chord).
# The roll is a hash of (canopy.roll_salt, the caller's roll_key, the canopy's id): its own stream, never the combat stream (combat
# seeds every roll from a unit's index, CLAUDE.md), the same on every peer, and independent of the order lines are traced in. Pass
# a different roll_key for each independent line (a tick, a shooter, a sample); the same key and line always give the same answer.
#
# HEIGHTS ARE ABSOLUTE (metres above sea level, the grid's own): a plane in a band is at the band's height (data/sim/altitude.json:
# 120 / 400 / 1000), whatever is under it; a unit on the ground stands at HeightGrid.stand_z. A line outside the map sees flat
# ground at 0 m.
#
# COST: counters (`traces`, `blocks_walked`, `cells_walked`) run since the last reset_counters(); the time per check is measured by
# test_line_of_fire and printed.

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Chunk = preload("res://scripts/sim/height_chunk.gd")

const KIND_CELL := 1
const KIND_CANOPY := 2

var grid: Object
var rules: Rules
var traces: int = 0
var blocks_walked: int = 0
var cells_walked: int = 0

var _bs: float
var _nb: int
var _n: int
var _c: float
var _bc: int
var _eps: float
# what the last stop was (set by the walk, read by _result)
var _s_kind: int = 0
var _s_byte: int = 0
var _s_ix: int = 0
var _s_iy: int = 0
var _s_top: float = 0.0
var _s_can: int = -1
var _s_chance: float = 0.0
var _s_roll: float = 0.0

# `rules_v`: other rules than the grid's for the walk, the canopies and the sampling (a test turns the trees off to test the cover alone).
func _init(grid_v: Object, rules_v: Rules = null) -> void:
	grid = grid_v
	rules = rules_v if rules_v != null else grid_v.rules
	_bs = float(grid_v.block_m)
	_nb = int(grid_v.nb)
	_n = int(grid_v.n)
	_c = float(grid_v.cell_m)
	_bc = int(grid_v.block_cells)
	_eps = float(rules.clear_eps_m)

func reset_counters() -> void:
	traces = 0
	blocks_walked = 0
	cells_walked = 0

# --- the trace ------------------------------------------------------------------------------------------------

func trace(from3: Vector3, to3: Vector3, roll_key: int = 0) -> Dictionary:
	return trace_xyz(from3.x, from3.y, from3.z, to3.x, to3.y, to3.z, roll_key)

# Float64 in, for the sim's own positions (a Vector3 is float32).
func trace_xyz(x0: float, y0: float, z0: float, x1: float, y1: float, z1: float, roll_key: int = 0) -> Dictionary:
	traces += 1
	# a point that is not a number would walk forever (every comparison with NaN is false): such a line is refused, as stopped at its start
	if not (is_finite(x0) and is_finite(y0) and is_finite(z0) and is_finite(x1) and is_finite(y1) and is_finite(z1)):
		return {"clear": false, "t": 0.0, "x": x0, "y": y0, "z": z0, "kind": "invalid", "material": -1, "material_name": "", "deck": false}
	var dx := x1 - x0
	var dy := y1 - y0
	var dz := z1 - z0
	var bs := _bs
	var nb := _nb
	var bx := floori(x0 / bs)
	var by := floori(y0 / bs)
	var sx := 0
	var sy := 0
	var tmx := INF
	var tmy := INF
	var tdx := INF
	var tdy := INF
	if dx > 0.0:
		sx = 1
		tmx = (float(bx + 1) * bs - x0) / dx
		tdx = bs / dx
	elif dx < 0.0:
		sx = -1
		tmx = (float(bx) * bs - x0) / dx
		tdx = -bs / dx
	if dy > 0.0:
		sy = 1
		tmy = (float(by + 1) * bs - y0) / dy
		tdy = bs / dy
	elif dy < 0.0:
		sy = -1
		tmy = (float(by) * bs - y0) / dy
		tdy = -bs / dy
	var degenerate := dx == 0.0 and dy == 0.0
	var t_in := 0.0
	var ts := INF
	var ch: Chunk = null
	var last_cx := 1 << 30
	var last_cy := 1 << 30
	# a line crosses at most (blocks along x) + (blocks along y) + 2 blocks; the cap only stops a runaway
	var guard := int(absf(dx) / bs + absf(dy) / bs) + 8
	while guard > 0:
		guard -= 1
		var t_out := minf(minf(tmx, tmy), 1.0)
		if t_out > t_in or degenerate:
			var cxx := floori(float(bx) / float(nb))
			var cyy := floori(float(by) / float(nb))
			if cxx != last_cx or cyy != last_cy:
				ch = grid.chunk_at(cxx, cyy)
				last_cx = cxx
				last_cy = cyy
			ts = _block(ch, bx - cxx * nb, by - cyy * nb, bx, by, x0, y0, z0, dx, dy, dz, t_in, t_out, roll_key)
			if ts < INF:
				break
		if t_out >= 1.0:
			break
		if tmx < tmy:
			bx += sx
			t_in = tmx
			tmx += tdx
		else:
			by += sy
			t_in = tmy
			tmy += tdy
	if ts == INF:
		return {"clear": true, "t": 1.0, "x": x1, "y": y1, "z": z1}
	return _result(x0 + dx * ts, y0 + dy * ts, z0 + dz * ts, ts)

func _result(x: float, y: float, z: float, t: float) -> Dictionary:
	var r := {"clear": false, "t": t, "x": x, "y": y, "z": z}
	if _s_kind == KIND_CANOPY:
		r["kind"] = "canopy"
		r["material"] = Rules.TREES
		r["material_name"] = rules.material_name(Rules.TREES)   # wood (a canopy); r.kind says it is a canopy
		r["canopy"] = _s_can
		r["chance"] = _s_chance
		r["roll"] = _s_roll
	else:
		r["kind"] = "cell"
		r["material"] = _s_byte & Rules.MATERIAL_MASK
		r["material_name"] = rules.material_name(_s_byte & Rules.MATERIAL_MASK)
		r["deck"] = (_s_byte & Rules.FLAG_DECK) != 0
		r["cell"] = Vector2i(_s_ix, _s_iy)
		r["top"] = _s_top
	return r

# One block of the walk: the earliest stop in it over [t_in, t_out], or INF.
func _block(ch: Chunk, lbx: int, lby: int, gbx: int, gby: int, x0: float, y0: float, z0: float, dx: float, dy: float, dz: float,
		t_in: float, t_out: float, roll_key: int) -> float:
	blocks_walked += 1
	var bi := lby * _nb + lbx
	var bmx: float = ch.bmax[bi]
	if ch.has_ov:
		var o: float = ch.obmax[bi]
		if o > bmx:
			bmx = o
	var za := z0 + dz * t_in
	var zb := z0 + dz * t_out
	var zmin := za if za < zb else zb
	var t_cell := INF
	if zmin < bmx - _eps:
		t_cell = _cells(ch, lbx, lby, x0, y0, z0, dx, dy, dz, t_in, t_out)
	var lst: Variant = grid.can_blocks.get(grid.block_key(gbx, gby))
	if lst != null:
		var t_can := _canopies(lst, x0, y0, z0, dx, dy, dz, t_in, t_out, t_cell, roll_key)
		if t_can < t_cell:
			return t_can
	return t_cell

# The fine walk inside one block.
func _cells(ch: Chunk, lbx: int, lby: int, x0: float, y0: float, z0: float, dx: float, dy: float, dz: float, t_in: float, t_out: float) -> float:
	var c := _c
	var n := _n
	var bc := _bc
	var org_x: int = int(ch.cx) * n      # the global index of the chunk's first cell
	var org_y: int = int(ch.cy) * n
	var lo_x := org_x + lbx * bc          # and of the block's
	var lo_y := org_y + lby * bc
	var hi_x := lo_x + bc - 1
	var hi_y := lo_y + bc - 1
	var ps := t_in + (t_out - t_in) * 1e-9
	var ix := clampi(floori((x0 + dx * ps) / c), lo_x, hi_x)
	var iy := clampi(floori((y0 + dy * ps) / c), lo_y, hi_y)
	var sx := 0
	var sy := 0
	var tmx := INF
	var tmy := INF
	var tdx := INF
	var tdy := INF
	if dx > 0.0:
		sx = 1
		tmx = (float(ix + 1) * c - x0) / dx
		tdx = c / dx
	elif dx < 0.0:
		sx = -1
		tmx = (float(ix) * c - x0) / dx
		tdx = -c / dx
	if dy > 0.0:
		sy = 1
		tmy = (float(iy + 1) * c - y0) / dy
		tdy = c / dy
	elif dy < 0.0:
		sy = -1
		tmy = (float(iy) * c - y0) / dy
		tdy = -c / dy
	var guard := 2 * bc + 8   # cells a line can cross inside one block, and a little more: the cap only stops a runaway
	var uni: bool = ch.uniform
	var uh: float = ch.uh
	var h: PackedFloat32Array = ch.h
	var has_ov: bool = ch.has_ov
	var oh: PackedFloat32Array = ch.oh
	var t_cur := t_in
	while guard > 0:
		guard -= 1
		var t_next := minf(minf(tmx, tmy), t_out)
		if t_next > t_cur or (dx == 0.0 and dy == 0.0):
			cells_walked += 1
			var idx := (iy - org_y) * n + (ix - org_x)
			var top := uh if uni else h[idx]
			if has_ov:
				var o := oh[idx]
				if o > top:
					top = o
			var za := z0 + dz * t_cur
			var zb := z0 + dz * t_next
			var zl := za if za < zb else zb
			if zl < top - _eps:
				var ts := t_cur
				if za >= top - _eps and za > zb:
					# the line comes down onto the cell's top inside it
					ts = clampf(t_cur + (za - top) / (za - zb) * (t_next - t_cur), t_cur, t_next)
				_s_kind = KIND_CELL
				_s_byte = ch.material_byte(ix - org_x, iy - org_y)
				_s_ix = ix
				_s_iy = iy
				_s_top = top
				return ts
		if t_next >= t_out:
			break
		if tmx < tmy:
			ix = clampi(ix + sx, lo_x, hi_x)
			tmx += tdx
		else:
			iy = clampi(iy + sy, lo_y, hi_y)
			tmy += tdy
		t_cur = t_next
	return INF

# The canopies of one block that the line goes through: the first one that stops it before t_limit, or INF. A canopy is judged in the
# block where the line first enters its volume, so a crown that overlaps several blocks is judged once.
func _canopies(lst: PackedInt32Array, x0: float, y0: float, z0: float, dx: float, dy: float, dz: float, t_in: float, t_out: float,
		t_limit: float, roll_key: int) -> float:
	var a := dx * dx + dy * dy
	var last_block := t_out >= 1.0
	var cx: PackedFloat64Array = grid.can_x
	var cy: PackedFloat64Array = grid.can_y
	var cr: PackedFloat64Array = grid.can_r
	var czb: PackedFloat64Array = grid.can_zb
	var czt: PackedFloat64Array = grid.can_zt
	var cand_t: Array[float] = []
	var cand_id: Array[int] = []
	var cand_p: Array[float] = []
	for id in lst:
		var rr := cr[id]
		var tin: float
		var tout: float
		if a < 1e-12:
			var ex := x0 - cx[id]
			var ey := y0 - cy[id]
			if ex * ex + ey * ey > rr * rr:
				continue
			tin = 0.0
			tout = 1.0
		else:
			var fx := x0 - cx[id]
			var fy := y0 - cy[id]
			var b := fx * dx + fy * dy
			var disc := b * b - a * (fx * fx + fy * fy - rr * rr)
			if disc < 0.0:
				continue
			var sq := sqrt(disc)
			tin = maxf((-b - sq) / a, 0.0)
			tout = minf((-b + sq) / a, 1.0)
			if tin > tout:
				continue
		var zb := czb[id]
		var zt := czt[id]
		if absf(dz) < 1e-12:
			if z0 < zb or z0 > zt:
				continue
		else:
			var tz1 := (zb - z0) / dz
			var tz2 := (zt - z0) / dz
			if tz1 > tz2:
				var tmp := tz1
				tz1 = tz2
				tz2 = tmp
			tin = maxf(tin, tz1)
			tout = minf(tout, tz2)
			if tin > tout:
				continue
		if tin < t_in or tin >= t_limit or (tin >= t_out and not last_block):
			continue
		var p: float = rules.stop_chance
		if rules.scale_by_chord:
			p *= minf((tout - tin) * sqrt(a) / (2.0 * rr), 1.0) if a >= 1e-12 else 1.0
		# kept in order of entry (a block holds a few)
		var pos := cand_t.size()
		while pos > 0 and cand_t[pos - 1] > tin:
			pos -= 1
		cand_t.insert(pos, tin)
		cand_id.insert(pos, id)
		cand_p.insert(pos, p)
	for k in cand_t.size():
		var roll := canopy_roll(roll_key, cand_id[k])
		if roll < cand_p[k]:
			_s_kind = KIND_CANOPY
			_s_can = cand_id[k]
			_s_chance = cand_p[k]
			_s_roll = roll
			return cand_t[k]
	return INF

# The canopy's roll for a line: a uniform number in [0, 1), a hash of (the salt in data, the caller's key, the canopy's id).
func canopy_roll(roll_key: int, canopy_id: int) -> float:
	var s := (roll_key * 0x9E3779B1 + canopy_id * 0x85EBCA6B + int(rules.roll_salt) * 0xC2B2AE35) & 0xFFFFFFFF
	return Mulberry32.new(s).next()

# --- exposure -----------------------------------------------------------------------------------------------

# How much of a target a shooter at `from3` sees: each of the target's boxes (Shapes.world_boxes) is sampled (Shapes.samples) and a
# line traced to every sample. The boxes that STAMP into the grid (a battery's sandbags, a bridge's deck) are the target's own cover and
# are not targets while the target has any other box; a box that does stamp, as the only one (the bridge), is traced to a metre and a
# half short of its face so its own cells do not stop the line. {visible, share (the silhouette-area weighted share of the target in
# view), boxes: [{part, material, material_name, samples, reached, share, rows, cols, area, lines: [{from, to, reach, stop}]}]}.
# `roll_key` is the caller's: each line gets its own from it. `with_lines` false skips the per-line records.
func exposure(from3: Vector3, target_boxes: Array, roll_key: int = 0, with_lines: bool = true, with_cells: bool = false) -> Dictionary:
	return exposure_xyz(from3.x, from3.y, from3.z, target_boxes, roll_key, with_lines, with_cells)

# STAGE 2 (builder LOF2): the share is WEIGHTED by the band of the box each sample stands for (Shapes.samples: the rows are spread and the
# end rows weigh half a slice), the parts data targets.not_targets names (a level deck) are never sampled, and `with_cells` adds to each box
# record `cells`: [{x, y, z (the sample point on the near face), zlo, zhi (the band of heights it stands for), w (its weight in the box), reach}]
# and `col_w` (the width of a column): the cut of the silhouette the odds (scripts/sim/line_of_fire_odds.gd) sums over.
func exposure_xyz(fx: float, fy: float, fz: float, target_boxes: Array, roll_key: int = 0, with_lines: bool = true, with_cells: bool = false) -> Dictionary:
	var candidates: Array = []
	for i in target_boxes.size():
		if not rules.not_target_parts.has(str((target_boxes[i] as Dictionary).get("part", ""))):
			candidates.append(i)
	if candidates.is_empty():
		for i in target_boxes.size():
			candidates.append(i)
	var picked: Array = []
	for i: int in candidates:
		if not bool((target_boxes[i] as Dictionary).get("stamp", false)):
			picked.append(i)
	if picked.is_empty():
		picked = candidates
	var out_boxes: Array = []
	var area_sum := 0.0
	var seen_sum := 0.0
	var reached_all := 0
	for bi: int in picked:
		var b: Dictionary = target_boxes[bi]
		var s := Shapes.samples(b, fx, fy, rules)
		var pts: PackedFloat64Array = s["pts"]
		var wts: PackedFloat64Array = s["w"]
		var count := pts.size() / 3
		var pull := _c * 1.5 if bool(b.get("stamp", false)) else 0.0
		var reached := 0
		var seen_w := 0.0
		var lines: Array = []
		var cells: Array = []
		for q in count:
			var qx := pts[q * 3]
			var qy := pts[q * 3 + 1]
			var qz := pts[q * 3 + 2]
			var cell_x := qx
			var cell_y := qy
			var cell_z := qz
			if pull > 0.0:
				var hl := sqrt((qx - fx) * (qx - fx) + (qy - fy) * (qy - fy))
				if hl > pull:
					var k := (hl - pull) / hl
					qx = fx + (qx - fx) * k
					qy = fy + (qy - fy) * k
					qz = fz + (qz - fz) * k
			var r := trace_xyz(fx, fy, fz, qx, qy, qz, roll_key * 1000003 + bi * 1009 + q)
			var clear := bool(r["clear"])
			if clear:
				reached += 1
				seen_w += wts[q]
			if with_lines:
				lines.append({"from": Vector3(fx, fy, fz), "to": Vector3(qx, qy, qz), "reach": clear, "stop": {} if clear else r})
			if with_cells:
				cells.append({"x": cell_x, "y": cell_y, "z": cell_z, "zlo": (s["zlo"] as PackedFloat64Array)[q], "zhi": (s["zhi"] as PackedFloat64Array)[q],
					"w": wts[q], "reach": clear})
		var share := seen_w
		var area: float = float(s["area"])
		area_sum += area
		seen_sum += area * share
		reached_all += reached
		var rec := {"part": str(b["part"]), "material": int(b["material"]), "material_name": str(b["material_name"]), "samples": count, "reached": reached,
			"share": share, "rows": int(s["rows"]), "cols": int(s["cols"]), "area": area}
		if with_lines:
			rec["lines"] = lines
		if with_cells:
			rec["cells"] = cells
			rec["col_w"] = float(s["col_w"])
		out_boxes.append(rec)
	return {"visible": reached_all > 0, "share": seen_sum / area_sum if area_sum > 0.0 else 0.0, "boxes": out_boxes}

# --- helpers for the caller ------------------------------------------------------------------------------------

# The absolute height a unit's body stands on: a surface unit (band reference "terrain", height_m 0) at the grid's stand height, a
# unit in an air band (reference "sea_level") at the band's absolute height.
func base_z(x: float, y: float, height_m: float, reference: String) -> float:
	if reference == "terrain":
		return float(grid.stand_z(x, y)) + height_m
	return height_m
