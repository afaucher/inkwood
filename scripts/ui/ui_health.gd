extends RefCounted

# What the interface shows of a unit's health (Track U2, the first fight): the
# pips on the roster row and the short arc on the selection ring read the SAME
# number from here, and draw it with the helpers below.
#
# WHY NOT JUST Unit.health: a resolve writes the turn's end state onto the
# units at once, and the markers then play the turn back over five seconds. A
# row that showed the new health the moment Ready resolved the turn would
# spoil a hit the player has not seen yet. So WHILE A RESOLVE PLAYS BACK the
# number shown is the health the unit had when the turn began (a snapshot
# taken whenever planning starts), and it changes only when the effects layer
# says so: show(id, pips), called as a hit's event time passes (UnitUI.
# show_health; the playback_event signal tells it when). When the playback
# ends the overrides are dropped and Unit.health is what shows. Outside a
# playback (planning, a headless run, a host that skips the playback) the
# unit's own health is shown, always.
#
#   var h := UiHealth.new()
#   h.setup(world)
#   h.shown("p1", playing)        # pips to show for p1 (0 = down)
#   h.shown_down("p1", playing)   # whether to show p1 as down
#   h.show("p1", 2)               # the effects layer: p1 shows 2 pips now (playback only)
#   h.clear_shown()               # the playback ended
#
# DRAWING: draw_pips (a row of segments, for the roster) and draw_arc_pips
# (the same segments along an arc, for the ring). Filled = pips left, outline =
# pips lost; ink only, never a hue (palette rule 6).

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var world: World = null
var _start: Dictionary = {}     # unit id -> {"health": int, "down": bool} at the start of this turn's planning
var _shown: Dictionary = {}     # unit id -> pips the effects layer wants shown during the playback

func setup(w: World) -> void:
	world = w
	snapshot()
	if not world.phase_changed.is_connected(_on_phase):
		world.phase_changed.connect(_on_phase)

# The health of every unit as the turn about to be planned finds it.
func snapshot() -> void:
	_start.clear()
	if world == null:
		return
	for id: String in world.units:
		var u = world.units[id]
		_start[id] = {"health": int(u.health), "down": bool(u.down), "fate": fate_of(u)}

func shown_fate(id: String, playing: bool) -> String:
	if not shown_down(id, playing):
		return ""
	var u = world.units.get(id)
	if playing and _start.has(id) and bool((_start[id] as Dictionary)["down"]):
		return str((_start[id] as Dictionary)["fate"])   # already down when the turn began: its fate then
	return fate_of(u)

# A downed unit's fate (Alex 2026-10-09, Track C's Unit.fate): "exploded" (gone
# at once), "out_of_control" (nobody can plan it; the sim flies it down), then
# "crashed"; "" for a unit that is not down, or when Unit has no fate (yet).
static func fate_of(u: Object) -> String:
	if u == null:
		return ""
	var f: Variant = u.get("fate")
	return str(f) if f != null else ""

func _on_phase(phase: String) -> void:
	if phase == World.PHASE_PLANNING:
		_shown.clear()
		snapshot()

# The effects layer: show `pips` for the unit from now until the playback ends.
func show(id: String, pips: int) -> void:
	_shown[id] = maxi(pips, 0)

func clear_shown() -> void:
	_shown.clear()

func max_of(id: String) -> int:
	var u = world.units.get(id) if world != null else null
	return int(u.def.health) if u != null else 0

func shown(id: String, playing: bool) -> int:
	var u = world.units.get(id) if world != null else null
	if u == null:
		return 0
	if playing:
		if _shown.has(id):
			return int(_shown[id])
		if _start.has(id):
			return int((_start[id] as Dictionary)["health"])
	return int(u.health)

func shown_down(id: String, playing: bool) -> bool:
	var u = world.units.get(id) if world != null else null
	if u == null:
		return false
	if playing:
		if _shown.has(id):
			return int(_shown[id]) <= 0
		if _start.has(id):
			return bool((_start[id] as Dictionary)["down"])
	return bool(u.down)

# --- Drawing ----------------------------------------------------------------------------

# A row of `total` segments right-aligned at right_x, centred on cy: the first
# `now` filled, the rest outlines. Segments narrow to fit health.max_w_px.
# Returns the row's left edge.
static func draw_pips(ci: CanvasItem, st: UiStyle, right_x: float, cy: float, total: int, now: int, full: Color, empty: Color) -> float:
	var n := maxi(total, 0)
	if n == 0:
		return right_x
	var h: float = st.num("health.pip_h_px")
	var gap: float = st.num("health.pip_gap_px")
	var w: float = minf(st.num("health.pip_w_px"), (st.num("health.max_w_px") - gap * float(n - 1)) / float(n))
	var x0 := right_x - (w * float(n) + gap * float(n - 1))
	for i in n:
		var r := Rect2(x0 + (w + gap) * float(i), cy - h * 0.5, w, h)
		if i < now:
			ci.draw_rect(r, full, true)
		else:
			ci.draw_rect(r.grow(-0.5), empty, false, 1.0)
	return x0

# The same segments along an arc about `c` at radius `r`, centred on screen
# angle `centre` (radians), total span health.ring_arc.span_deg.
static func draw_arc_pips(ci: CanvasItem, st: UiStyle, c: Vector2, r: float, centre: float, total: int, now: int, full: Color, empty: Color) -> void:
	var n := maxi(total, 0)
	if n == 0:
		return
	var span := deg_to_rad(st.num("health.ring_arc.span_deg"))
	var gap := minf(deg_to_rad(st.num("health.ring_arc.gap_deg")), span / float(n) * 0.4)
	var seg := (span - gap * float(n - 1)) / float(n)
	var a0 := centre - span * 0.5
	var lw: float = st.num("health.ring_arc.line_px")
	var ew: float = st.num("health.ring_arc.empty_line_px")
	for i in n:
		var a := a0 + (seg + gap) * float(i)
		var pts := maxi(3, ceili(seg / 0.1))
		if i < now:
			ci.draw_arc(c, r, a, a + seg, pts, full, lw, true)
		else:
			ci.draw_arc(c, r, a, a + seg, pts, empty, ew, true)
