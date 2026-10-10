extends Node2D

# The motion planning control on the map (exit criterion 3, design doc: "a plan
# is a curve of steps; each step is a point inside the plane's performance
# envelope; inertia applies"). For the selected unit it draws:
#
#   the FAN      the next step's reachable end points (World.reachable's
#                outline), an inked outline with faint ribs, one per sampled turn
#   the CURVE    the whole turn as it will fly (World.sample(id, t, "plan"), the
#                same arcs the resolve flies): planned steps solid, the
#                carry-on steps after them dashed
#   GHOSTS       the unit's own art, faint, at the end of every step
#                (World.planned_states), heading as it will be
#   CLAMPS       where a step was asked for outside the envelope, a fine dashed
#                tie from the point asked for to where the envelope put it --
#                what is drawn is always the CLAMPED result
#
# Other player units' plans show as thin, quiet curves ALL THE TIME while the
# turn is planned (Alex 2026-10-09, co-op: last edit wins, with a full preview
# so every player sees what has plans and what does not): a solid line with a
# dot at each planned step, the carry-on rest dashed, and for a unit with no
# plan only the dashed flight ("flies on"). They follow World.plan_changed, so
# an edit another player makes (applied by the network layer through the World)
# shows at once.
#
# NEVER AN AI UNIT'S PLAN (Alex): plan_shown(id) is the one rule every drawing
# here goes through -- planning phase, a player-controlled unit, not down -- so
# an AI-controlled unit's path, ghosts, fan and clamps are not drawn even when
# it is the selected unit, and path_world / step_labels give nothing for it.
# test_ui_coop fails if any of it is ever drawn.
#
# SPEED PER STEP: the lettering at a planned step's ghost is "n · 120 m/s", the
# speed the step ends at (step_labels, data planner.speed_labels).
#
# INPUT IS THIN. Every action is a public method a test calls directly; the
# mouse handlers (press / drag / release, screen points) only decide which one:
#
#   place_point(world_pt)        the next step steers for that point
#   begin_step / drag_step / end_step   the same, following a drag
#   begin_edit(k, world_pt)      re-drag planned step k (its handle)
#   set_step_band(k, band)       change one step's altitude band
#   change_band(+1 | 0 | -1)     climb / level / dive on the last placed step
#   undo() / clear()             drop the last step / the whole plan
#   ready_up()                   World.commit for the local player
#
# Every change goes through World.plan_step, which validates the step against
# the unit's envelope and returns the clamped state; nothing here moves a unit.
#
# TWO RULES FROM ALEX (2026-10-09), added by Track A:
#   * A step that ends outside the map is REFUSED: the plan stays as it was, the
#     call returns {}, and a small cross and "off the map" show where the point
#     was asked for (refused_world / refused_ms). Uses the out_of_bounds field of
#     the states plan_step returns. A unit already outside the map may plan its
#     way back.
#   * Editing a plan after Ready TAKES THE READY BACK (the player is un-readied
#     and the edit is made), so the last Ready always plays the turn.
#
# THE MAP RULE APPLIES TO THE WHOLE TURN (fix pass, 2026-10-09): carry-on steps
# are steps too, so Ready itself refuses while any step of any player unit's
# turn -- planned or carry-on, World.planned_states -- would end outside the map
# (ready_blocker / ready_up). The refusal marks the first such step with the same
# "off the map" cross, selects the plane and puts "<name> would leave the map:
# plan a turn" on the orders card (ready_notice) until a plan changes. A unit
# that starts the turn already outside is exempt (PROPOSED): it may not be able
# to get back in within one turn, and the rule would then lock Ready for good.

signal plan_edited(unit_id: String)
signal ready_refused(unit_id: String)   # Ready was refused for this unit (or "": the notice was cleared)

const World = preload("res://scripts/sim/world.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const Roster = preload("res://scripts/ui/roster.gd")

var world: World = null
var mapping: UiMapping = null
var selection: RefCounted = null
var style: UiStyle = null
var local_player: String = "local"
# The unit marker layer, when the planner sits beside one (UnitUI sets it): the
# ghosts use the art the selected unit's own marker already holds, so a zoom
# never makes the planner bake art of its own.
var marker_layer: Object = null

# Why Ready was refused (see the header), "" when it was not: the orders card
# shows it. Cleared when a plan changes or the phase does.
var ready_notice: String = ""

# The last refused point (metres) and when (msec ticks): drawn for a moment.
var refused_world := Vector2.INF
var refused_ms: int = -100000
const REFUSED_SHOW_MS := 1600

var _drag_index: int = -1
var _paths: Dictionary = {}         # unit id -> Array of [PackedVector2Array world pts, planned: bool]
var _own_art: Dictionary = {}       # unit id -> Art: only used when there is no marker layer to borrow from

func setup(w: World, host_mapping: Variant, sel: RefCounted, player: String = "local", st: RefCounted = null) -> void:
	style = (st if st != null else UiStyle.shared()) as UiStyle
	world = w
	local_player = player
	selection = sel
	set_mapping(host_mapping)
	if not world.plan_changed.is_connected(_on_plan_changed):
		world.plan_changed.connect(_on_plan_changed)
		world.phase_changed.connect(_on_phase_changed)
	if not selection.changed.is_connected(_on_selection):
		selection.changed.connect(_on_selection)
	_paths.clear()
	queue_redraw()

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping
	queue_redraw()

# --- Queries ---------------------------------------------------------------------

func unit_id() -> String:
	return selection.unit_id if selection != null else ""

# Whether a unit takes orders from this control: the planning phase and a
# player-controlled unit. A readied player may still edit: the edit takes the
# Ready back (see the header).
func can_plan(id: String = "") -> bool:
	if id == "":
		id = unit_id()
	if world == null or id == "" or not world.units.has(id):
		return false
	if world.phase != World.PHASE_PLANNING:
		return false
	var u = world.units[id]
	return u.controller == World.CONTROLLER_PLAYER and not bool(u.down)

# Whether a unit's plan may be DRAWN at all (path, ghosts, fan, clamps): the
# planning phase and a player-controlled unit that is not down. The one rule
# every drawing here goes through; an AI unit's plan is never shown.
func plan_shown(id: String) -> bool:
	if world == null or not world.units.has(id) or world.phase != World.PHASE_PLANNING:
		return false
	var u = world.units[id]
	return u.controller == World.CONTROLLER_PLAYER and not bool(u.down)

# An edit is being made: a readied local player is un-readied.
func _reopen() -> void:
	if world != null and world.phase == World.PHASE_PLANNING and world.is_ready(local_player):
		world.withdraw(local_player)

# Steps with an explicit request: the last non-empty request + 1.
func planned_count(id: String = "") -> int:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return 0
	var plan: Array = world.units[id].plan
	var n := plan.size()
	while n > 0 and (plan[n - 1] as Dictionary).is_empty():
		n -= 1
	return n

# The step the next click places, or -1 when the plan is full or closed.
func next_step_index(id: String = "") -> int:
	if id == "":
		id = unit_id()
	if not can_plan(id):
		return -1
	var k := planned_count(id)
	return k if k < world.steps_per_turn(id) else -1

# World.reachable for the next step ({} when there is none).
func reachable_next() -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	return world.reachable(unit_id(), k)

func fan_outline_world() -> PackedVector2Array:
	var r := reachable_next()
	return r.get("outline", PackedVector2Array())

func fan_outline_screen() -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in fan_outline_world():
		out.append(mapping.world_to_screen(p))
	return out

# Every step's state for the selected unit, planned and carry-on alike.
func states(id: String = "") -> Array:
	if id == "":
		id = unit_id()
	if world == null or not world.units.has(id):
		return []
	return world.planned_states(id)

# The band a unit is in before step k.
func band_before(k: int, id: String = "") -> String:
	if id == "":
		id = unit_id()
	if k <= 0:
		return world.units[id].altitude_band
	return str((states(id)[k - 1] as Dictionary)["altitude_band"])

# --- Actions -------------------------------------------------------------------------

func place_point(world_pt: Vector2) -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	return _plan_point(k, world_pt)

func begin_step(world_pt: Vector2) -> Dictionary:
	var k := next_step_index()
	if k < 0:
		return {}
	_drag_index = k
	return _plan_point(k, world_pt)

func begin_edit(k: int, world_pt: Vector2) -> Dictionary:
	if not can_plan() or k < 0 or k >= planned_count():
		return {}
	_drag_index = k
	return _plan_point(k, world_pt)

func drag_step(world_pt: Vector2) -> Dictionary:
	if _drag_index < 0 or not can_plan():
		return {}
	return _plan_point(_drag_index, world_pt)

func end_step() -> Dictionary:
	var k := _drag_index
	_drag_index = -1
	if k < 0 or not can_plan():
		return {}
	return states()[k]

func is_dragging() -> bool:
	return _drag_index >= 0

# Step k steers for `world_pt`, keeping the band it asked for (if any).
func _plan_point(k: int, world_pt: Vector2) -> Dictionary:
	var id := unit_id()
	var req := {"to": world_pt}
	var plan: Array = world.units[id].plan
	if k < plan.size() and (plan[k] as Dictionary).has("altitude_band"):
		req["altitude_band"] = (plan[k] as Dictionary)["altitude_band"]
	return _commit_step(id, k, req, world_pt)

# World.plan_step with the map rule: a plan with a PLANNED step that ends
# outside the map is put back as it was and {} comes back. `asked` is where the
# step was asked for (metres), for the refusal mark.
func _commit_step(id: String, k: int, req: Dictionary, asked: Vector2) -> Dictionary:
	var before: Array = (world.units[id].plan as Array).duplicate(true)
	var s := world.plan_step(id, k, req)
	if s.is_empty():
		return s
	if not bool(world.units[id].out_of_bounds):
		for st: Dictionary in world.planned_states(id):
			if bool(st["planned"]) and bool(st["out_of_bounds"]):
				world.clear_plan(id)
				for i in before.size():
					if not (before[i] as Dictionary).is_empty():
						world.plan_step(id, i, before[i])
				refused_world = asked
				refused_ms = Time.get_ticks_msec()
				return {}
	_reopen()
	plan_edited.emit(id)
	return s

func set_step_band(k: int, band: String) -> Dictionary:
	var id := unit_id()
	if not can_plan(id) or k < 0 or k >= world.steps_per_turn(id):
		return {}
	var plan: Array = world.units[id].plan
	var req: Dictionary = (plan[k] as Dictionary).duplicate(true) if k < plan.size() else {}
	req["altitude_band"] = band
	var u = world.units[id]
	var at := Vector2(float(u.x), float(u.y))
	return _commit_step(id, k, req, at)

# Climb (+1), level (0) or dive (-1) on the last placed step, one band, as far
# as the unit's own bands go. {} when no step is placed yet.
func change_band(delta: int) -> Dictionary:
	var k := planned_count() - 1
	if not can_plan() or k < 0:
		return {}
	var bands: Array[String] = world.units[unit_id()].def.envelope.bands
	var from := band_before(k)
	var i := clampi(bands.find(from) + signi(delta), 0, bands.size() - 1)
	return set_step_band(k, bands[i])

# Which band changes the last placed step can take: {-1: bool, 0: bool, 1: bool}.
func band_options() -> Dictionary:
	var out := {-1: false, 0: false, 1: false}
	var k := planned_count() - 1
	if not can_plan() or k < 0:
		return out
	var bands: Array[String] = world.units[unit_id()].def.envelope.bands
	var reach: Array = world.reachable(unit_id(), k).get("bands", [])
	var i := bands.find(band_before(k))
	out[0] = true
	out[1] = i + 1 < bands.size() and reach.has(bands[i + 1])
	out[-1] = i - 1 >= 0 and reach.has(bands[i - 1])
	return out

# Drop the last planned step. World has no remove-one-step call, so the plan
# is cleared and the remaining requests planned again, in order (proposed for
# Track S: a truncate_plan(unit_id, n) would make this one call).
func undo() -> bool:
	var id := unit_id()
	var n := planned_count(id)
	if not can_plan(id) or n == 0:
		return false
	var keep: Array = (world.units[id].plan as Array).slice(0, n - 1).duplicate(true)
	_reopen()
	world.clear_plan(id)
	for i in keep.size():
		world.plan_step(id, i, keep[i])
	_drag_index = -1
	plan_edited.emit(id)
	return true

func clear() -> void:
	var id := unit_id()
	if not can_plan(id):
		return
	_reopen()
	world.clear_plan(id)
	_drag_index = -1
	plan_edited.emit(id)

# The Ready button: commit for the local player. True when everyone is ready
# (the World does not resolve by itself; the owner -- UnitUI -- decides when).
# False, and nobody readied, when a player unit's turn would leave the map (see
# the header): ready_notice says which plane.
func ready_up() -> bool:
	if world == null or world.phase != World.PHASE_PLANNING:
		return false
	var blocked := ready_blocker()
	if not blocked.is_empty():
		_refuse_ready(blocked)
		return false
	ready_notice = ""
	return world.commit(local_player)

# The first step, of any player-controlled unit, that would end outside the map:
# {unit, step, at (metres)} or {} when every step of every turn stays on it.
# Planned and carry-on steps alike (World.planned_states); a unit that already
# starts the turn outside the map is exempt (see the header).
func ready_blocker() -> Dictionary:
	if world == null:
		return {}
	for id: String in world.units:
		var u = world.units[id]
		if u.controller != World.CONTROLLER_PLAYER or bool(u.out_of_bounds) or bool(u.down):
			continue   # (a down unit takes no orders: it cannot hold the turn up)
		var st := world.planned_states(id)
		for k in st.size():
			var s: Dictionary = st[k]
			if bool(s["out_of_bounds"]):
				return {"unit": id, "step": k, "at": Vector2(float(s["x"]), float(s["y"]))}
	return {}

func _refuse_ready(blocked: Dictionary) -> void:
	var id: String = blocked["unit"]
	refused_world = blocked["at"]
	refused_ms = Time.get_ticks_msec()
	ready_notice = "%s would leave the map: plan a turn" % Roster.unit_name(world.units[id])
	if selection != null and selection.unit_id != id:
		selection.select(id)   # the plane that needs the plan, with its fan up
	ready_refused.emit(id)
	queue_redraw()

# --- Pointer (screen points in this node's space) ------------------------------------

# Which planned step's handle is under `screen_pt` (the last one first), or -1.
func handle_at(screen_pt: Vector2) -> int:
	if not can_plan():
		return -1
	var st := states()
	for k in range(planned_count() - 1, -1, -1):
		var s: Dictionary = st[k]
		var p: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
		if p.distance_to(screen_pt) <= style.num("planner.handle_px"):
			return k
	return -1

# Whether a press at `screen_pt` starts a new step: inside the fan, or within
# capture_px of it.
func in_fan(screen_pt: Vector2) -> bool:
	var poly := fan_outline_screen()
	if poly.size() < 3:
		return false
	if Geometry2D.is_point_in_polygon(screen_pt, poly):
		return true
	var cap: float = style.num("planner.capture_px")
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(screen_pt, poly[i], poly[(i + 1) % poly.size()])
		if q.distance_to(screen_pt) <= cap:
			return true
	return false

func press(screen_pt: Vector2) -> bool:
	var k := handle_at(screen_pt)
	var wp: Vector2 = mapping.screen_to_world(screen_pt)
	if k >= 0:
		begin_edit(k, wp)
		return true
	if in_fan(screen_pt):
		begin_step(wp)
		return true
	return false

func drag(screen_pt: Vector2) -> bool:
	if not is_dragging():
		return false
	drag_step(mapping.screen_to_world(screen_pt))
	return true

func release(screen_pt: Vector2) -> bool:
	if not is_dragging():
		return false
	drag_step(mapping.screen_to_world(screen_pt))
	end_step()
	return true

# --- Drawing ---------------------------------------------------------------------------

func _on_plan_changed(id: String) -> void:
	_paths.erase(id)
	if ready_notice != "" and world.units.has(id) and world.units[id].controller == World.CONTROLLER_PLAYER:
		ready_notice = ""
		ready_refused.emit("")   # (the card redraws)
	queue_redraw()

func _on_phase_changed(_phase: String) -> void:
	_paths.clear()
	_drag_index = -1
	ready_notice = ""
	queue_redraw()

func _on_selection(_id: String) -> void:
	_drag_index = -1
	queue_redraw()

func _process(_delta: float) -> void:
	queue_redraw()  # the host's camera may move; the drawing is a handful of lines

# The turn's curve in world metres, per step: [points, planned]. Nothing for a
# unit whose plan may not be shown (an AI unit's, a down unit's, outside the
# planning phase): see plan_shown.
func path_world(id: String) -> Array:
	if not plan_shown(id):
		return []
	if _paths.has(id):
		return _paths[id]
	var out: Array = []
	var st := world.planned_states(id)
	var n := st.size()
	var dt := world.step_dt(id)
	var m := int(style.num("planner.samples_per_step"))
	var u = world.units[id]
	var prev := Vector2(float(u.x), float(u.y))
	for k in n:
		var pts := PackedVector2Array([prev])
		for j in range(1, m + 1):
			var t := dt * (float(k) + float(j) / float(m))
			var s := world.sample(id, t, "plan")
			pts.append(Vector2(float(s["x"]), float(s["y"])))
		var end := Vector2(float(st[k]["x"]), float(st[k]["y"]))
		pts[pts.size() - 1] = end
		out.append([pts, bool(st[k]["planned"])])
		prev = end
	_paths[id] = out
	return out

func _to_screen(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = mapping.world_to_screen(pts[i])
	return out

func _draw() -> void:
	if world == null or world.phase != World.PHASE_PLANNING:
		return
	var sel := unit_id()
	# Every other unit that takes the players' orders, thin and quiet, all the time.
	for id: String in world.units:
		if id != sel and plan_shown(id):
			_draw_curve(id, style.num("planner.others_alpha"), true)
	if sel == "" or not plan_shown(sel):
		_draw_refused()
		return
	_draw_ghosts(sel)
	if can_plan(sel):
		_draw_fan()
	_draw_curve(sel, 1.0)
	_draw_clamps(sel)
	_draw_refused()

func _fade(c: Color, k: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * k)

func _draw_fan() -> void:
	var poly := fan_outline_screen()
	if poly.size() < 3:
		return
	var n := poly.size() / 2
	# The fan's apex: where the step starts (the unit, or the previous step's end).
	var k := next_step_index()
	var apex_w := Vector2(float(world.units[unit_id()].x), float(world.units[unit_id()].y))
	if k > 0:
		var prev: Dictionary = states()[k - 1]
		apex_w = Vector2(float(prev["x"]), float(prev["y"]))
	var apex: Vector2 = mapping.world_to_screen(apex_w)
	# Spokes from the apex out to the far edge: the turn the step can take,
	# drawn as guides (the reachable region itself is only the inked band).
	var rib: Color = style.color("fan_rib")
	var edge: Color = style.color("fan_line")
	var rw: float = style.num("planner.rib_line_px")
	for i in n:
		var far := poly[i]
		var near := poly[poly.size() - 1 - i]
		if i == 0 or i == n - 1:
			UiInk.dashed(self, PackedVector2Array([apex, near]), _fade(edge, 0.7), rw, style.num("planner.dash_px") * 0.5, style.num("planner.gap_px") * 0.6)
		else:
			draw_line(apex.lerp(near, 0.55), near, rib, rw, true)
		draw_line(near, far, rib, rw, true)
	# A unit that cannot turn or change speed this step has a fan with no area
	# (a ship dead in the water): outline only, no fill to fail triangulating.
	if not Geometry2D.triangulate_polygon(poly).is_empty():
		draw_colored_polygon(poly, style.color("fan_fill"))
	UiInk.ink_line(self, poly, true, edge, style.num("planner.fan_line_px"), 31, 0.4)

# `quiet`: another unit's plan (data planner.others_*): thinner line, smaller dots.
func _draw_curve(id: String, alpha: float, quiet: bool = false) -> void:
	var solid := _fade(style.color("path"), alpha)
	var carry := _fade(style.color("path_carry"), alpha)
	var w: float = style.num("planner.others_line_px") if quiet else style.num("planner.path_line_px")
	var wc: float = style.num("planner.others_carry_line_px") if quiet else style.num("planner.carry_line_px")
	var dot: float = style.num("planner.others_dot_px") if quiet else style.num("planner.step_dot_px")
	for seg: Array in path_world(id):
		var pts := _to_screen(seg[0])
		if bool(seg[1]):
			draw_polyline(pts, solid, w, true)
			draw_circle(pts[pts.size() - 1], dot, solid, true, -1.0, true)
		else:
			UiInk.dashed(self, pts, carry, wc, style.num("planner.dash_px"), style.num("planner.gap_px"))
			draw_circle(pts[pts.size() - 1], dot * 0.8, carry, false, 1.0, true)

# The lettering at every step's ghost, as lines (empty for a step with none):
# a planned step's number and the speed it ends at ("2 · 120 m/s", data
# planner.speed_labels), and under it a change of altitude band ("climb to
# high"). Nothing for a unit whose plan may not be shown.
func step_labels(id: String = "") -> Array:
	if id == "":
		id = unit_id()
	var out: Array = []
	if not plan_shown(id):
		return out
	var u = world.units[id]
	var st := states(id)
	var prev_band: String = u.altitude_band
	var unit_txt: String = style.text("roster.speed_unit")
	var with_speed: bool = style.flag("planner.speed_labels")
	for k in st.size():
		var s: Dictionary = st[k]
		var lines := PackedStringArray()
		if bool(s["planned"]):
			var head := str(k + 1)
			if with_speed:
				head += " · %d %s" % [roundi(float(s["speed"])), unit_txt]
			lines.append(head)
		var band := str(s["altitude_band"])
		if band != prev_band:
			var up: bool = u.def.envelope.bands.find(band) > u.def.envelope.bands.find(prev_band)
			lines.append(("climb to " if up else "dive to ") + band)
		out.append(lines)
		prev_band = band
	return out

func _draw_ghosts(id: String) -> void:
	var u = world.units[id]
	var st := states(id)
	var labels := step_labels(id)
	var font: Font = style.font(true)
	var small: float = style.num("fonts.small_px")
	var ink: Color = style.color("ink_soft")
	for k in st.size():
		var s: Dictionary = st[k]
		var wp := Vector2(float(s["x"]), float(s["y"]))
		var sp: Vector2 = mapping.world_to_screen(wp)
		var ppm: float = mapping.px_per_m(wp)
		var planned := bool(s["planned"])
		var scale_k: float = style.num("marker.true_scale")
		var art: UnitMarkerArt.Art = _ghost_art(id, u, ppm * scale_k)
		if art != null and art.texture != null:
			var a: float = style.num("planner.ghost_alpha") if planned else style.num("planner.carry_ghost_alpha")
			var sc := ppm * scale_k / art.ppm
			draw_set_transform(sp, mapping.screen_angle(wp, float(s["heading"])) + PI / 2.0, Vector2(sc, sc))
			draw_texture(art.texture, -art.origin, Color(1.0, 1.0, 1.0, a))
			draw_set_transform_matrix(Transform2D.IDENTITY)
		var lines: PackedStringArray = labels[k]
		if not lines.is_empty():
			# Lettering on the sun side of the ghost, clear of the curve's own shadow side.
			var off: Vector2 = -style.shadow_dir() * (art.extent_m * ppm * scale_k + 6.0 if art != null else 14.0)
			for li in lines.size():
				UiInk.text(self, font, sp + off + Vector2(-4.0, (small + 1.0) * float(li)), lines[li], small, ink)

# The art a ghost of unit `id` is drawn with, scaled by the caller to the ghost's
# own screen scale. It is the art the unit's MARKER holds (no bake at all, and
# the marker already re-bakes only when the scale drifts past unit_art.rebake_ratio);
# with no marker layer (the planner alone) it keeps one art of its own and
# re-bakes it past the same ratio. Asking UnitMarkerArt.art_for every frame, as
# this once did, baked a new art on almost every zoom step: art_for caches by the
# scale rounded to 0.01 and each miss is a forced engine frame (measured
# 2026-10-09: 128 bakes in 120 frames, 9.7 ms mean and 32 ms worst per frame).
func _ghost_art(id: String, u: Object, want_ppm: float) -> UnitMarkerArt.Art:
	if marker_layer != null:
		var m: Object = marker_layer.marker(id)
		if m != null and m.art != null:
			return m.art
	var held: UnitMarkerArt.Art = _own_art.get(id)
	if held != null:
		var ratio := want_ppm / held.ppm
		var limit: float = style.num("unit_art.rebake_ratio")
		if ratio <= limit and ratio >= 1.0 / limit:
			return held
	var art: UnitMarkerArt.Art = UnitMarkerArt.art_for(style, u.def.silhouette, style.side_color(u.side), want_ppm)
	if art != null:
		_own_art[id] = art
	return art

# The mark for a step refused for leaving the map: a cross where it was asked
# for, with a short caption, for REFUSED_SHOW_MS.
func _draw_refused() -> void:
	if not refused_world.is_finite() or Time.get_ticks_msec() - refused_ms > REFUSED_SHOW_MS:
		return
	var col: Color = style.color("clamp")
	var p: Vector2 = mapping.world_to_screen(refused_world)
	var x := 5.0
	draw_line(p + Vector2(-x, -x), p + Vector2(x, x), col, 1.6, true)
	draw_line(p + Vector2(-x, x), p + Vector2(x, -x), col, 1.6, true)
	UiInk.text(self, style.font(true), p + Vector2(9.0, 4.0), "off the map", style.num("fonts.small_px"), col)

func _draw_clamps(id: String) -> void:
	var st := states(id)
	var plan: Array = world.units[id].plan
	var col: Color = style.color("clamp")
	for k in mini(plan.size(), st.size()):
		var req: Dictionary = plan[k]
		var s: Dictionary = st[k]
		if not bool(s["clamped"]) or not req.has("to"):
			continue
		var to_v: Variant = req["to"]
		if not (to_v is Vector2):
			continue
		var a: Vector2 = mapping.world_to_screen(to_v)
		var b: Vector2 = mapping.world_to_screen(Vector2(float(s["x"]), float(s["y"])))
		if a.distance_to(b) < 3.0:
			continue
		UiInk.dashed(self, PackedVector2Array([a, b]), col, 0.9, 3.0, 3.0)
		var x := 3.5
		draw_line(a + Vector2(-x, -x), a + Vector2(x, x), col, 1.1, true)
		draw_line(a + Vector2(-x, x), a + Vector2(x, -x), col, 1.1, true)
