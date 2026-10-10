extends Node2D

# THE INK ON A UNIT WHEN IT IS HIT, and the faint tracers of a shot (Track U2, the first
# fight, part 2). Every number is data/ui/ui.json combat.hit_mark / combat.tracers and
# PROPOSED. The design doc's damage rule: "a brief ink mark on the unit when hit, following
# the fast-flash, slow-decay rule; pips drop on the card" (the pips are UnitUI's: it drops
# them as the same event passes the playback clock). No fire: Alex, "just smoke" -- this is
# ink and paper.
#
#   var marks := HitMarks.new()
#   overlay.add_child(marks)                      # screen space, above the markers
#   marks.setup(world, marker_layer, style)
#   marks.add_hit("p1", game_t, damage)           # a "hit" event passed the clock
#   marks.add_shot(fire_event, game_t)            # a "fire" event (tracers, off by default)
#   marks.set_clock(game_t)                       # each playback frame
#   marks.begin_turn()                            # a new playback: what is left is cleared
#   marks.end_turn(game_t)                        # the playback ended at game_t: the clock runs on in real time
#
# FAST FLASH, VERY SLOW DECAY. At the hit, a pool of paper (flash_s) knocks the busy ground
# out under the burst and the ink burst is at full strength and a little large; the paper is
# gone in a blink, the burst settles to its size, and the ink fades over life_s along
# (1 - age / life_s) ^ decay_power. The burst is `rays` short strokes round a dot, their
# lengths and angles picked by the hit, set a little off the plane's centre in the plane's
# own frame so it rides with the plane through a turn.
#
# THE CLOCK is game seconds. While a turn plays it is the playback's (set_clock), so a scrub
# shows the same frame; when the playback has ended it runs on in real time (at the
# playback speed) until the marks are gone, and the next playback clears what is left. A
# mark on a unit that is not drawn (hidden by the fog, or exploded at that moment) is not
# drawn.

const UiStyle = preload("res://scripts/ui/ui_style.gd")

var world: Object = null
var marker_layer: Object = null
var style: UiStyle = null

# {unit, t (game s), damage, seed}
var marks: Array = []
# {t, a (world metres), b (world metres), hit}
var tracers: Array = []
var clock: float = 0.0
var _playing := true     # whether the clock is the playback's (set_clock) or runs on its own
# Counted when a draw ran to its end (a runtime error in a draw function ends it silently).
var draw_count: int = 0
var failed_draws: int = 0

func setup(w: Object, markers: Object, st: RefCounted = null) -> void:
	world = w
	marker_layer = markers
	style = (st if st != null else UiStyle.shared()) as UiStyle
	name = "HitMarks"

# --- Feeding it -----------------------------------------------------------------------------

func add_hit(unit_id: String, game_t: float, damage: int = 1) -> void:
	if not style.flag("combat.hit_mark.enabled"):
		return
	marks.append({"unit": unit_id, "t": game_t, "damage": maxi(damage, 1), "seed": (hash(unit_id) & 0xFFFF) * 131 + int(round(game_t * 1000.0))})
	queue_redraw()

func add_shot(ev: Dictionary, game_t: float) -> void:
	if not style.flag("combat.tracers.enabled"):
		return
	var a := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var b := Vector2(float(ev.get("tx", a.x)), float(ev.get("ty", a.y)))
	if not bool(ev.get("hit", false)):
		# A miss carries on past the target, off the line a little (picked by the roll's time).
		var d := b - a
		var side := Vector2(-d.y, d.x) * (hash_unit(int(round(game_t * 1000.0)), 7) - 0.5) * 0.12
		b = a + d * (1.0 + style.num("combat.tracers.miss_overshoot_k")) + side
	tracers.append({"t": game_t, "a": a, "b": b, "hit": bool(ev.get("hit", false))})
	var cap := int(style.num("combat.tracers.max_live"))
	while tracers.size() > cap:
		tracers.remove_at(0)
	queue_redraw()

func set_clock(game_t: float) -> void:
	clock = game_t
	_playing = true
	if not marks.is_empty() or not tracers.is_empty():
		queue_redraw()

# A new playback begins: marks left over from the turn before are done with.
func begin_turn() -> void:
	marks.clear()
	tracers.clear()
	_playing = true
	queue_redraw()

# The playback ended with the clock at game_t: from here the clock runs on in real time.
func end_turn(game_t: float) -> void:
	clock = game_t
	_playing = false

func clear() -> void:
	marks.clear()
	tracers.clear()
	queue_redraw()

func _process(delta: float) -> void:
	if marks.is_empty() and tracers.is_empty():
		return
	if not _playing and not _held():
		clock += delta * style.num("marker.playback_speed")
	_prune()
	queue_redraw()

# A paused playback holds its marks (screenshots); so does one that is simply on.
func _held() -> bool:
	return marker_layer != null and bool(marker_layer.playback_paused)

func _prune() -> void:
	var life: float = style.num("combat.hit_mark.life_s")
	var keep: Array = []
	for m: Dictionary in marks:
		if clock - float(m["t"]) <= life:
			keep.append(m)
	marks = keep
	var tl: float = style.num("combat.tracers.life_s")
	var keep_t: Array = []
	for s: Dictionary in tracers:
		if clock - float(s["t"]) <= tl:
			keep_t.append(s)
	tracers = keep_t

# --- The curves -------------------------------------------------------------------------------

# The ink's strength at an age (game seconds since the hit): full at 0, gone at life_s,
# along (1 - age / life_s) ^ decay_power. 0 before the hit.
static func ink_alpha(age: float, st: UiStyle) -> float:
	if age < 0.0:
		return 0.0
	var u := age / maxf(st.num("combat.hit_mark.life_s"), 1e-3)
	if u >= 1.0:
		return 0.0
	return pow(1.0 - u, st.num("combat.hit_mark.decay_power"))

# The paper flash behind it: full at 0, gone at flash_s.
static func flash_alpha(age: float, st: UiStyle) -> float:
	if age < 0.0:
		return 0.0
	return clampf(1.0 - age / maxf(st.num("combat.hit_mark.flash_s"), 1e-3), 0.0, 1.0)

# 0..1 from integers: the same hit always draws the same burst.
static func hash_unit(i: int, salt: int) -> float:
	var h := (i * 73856093) ^ (salt * 19349663)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0

# Where a mark is now, in screen px: the unit's marker plus the spot in the plane's frame.
# {} when the unit is not drawn.
func mark_geometry(m: Dictionary) -> Dictionary:
	if marker_layer == null:
		return {}
	var mk: Object = marker_layer.marker(str(m["unit"]))
	if mk == null or not mk.visible:
		return {}
	var plane_r: float = mk.radius_px()
	var seed_v := int(m["seed"])
	var a := hash_unit(seed_v, 1) * TAU
	var d := sqrt(hash_unit(seed_v, 2)) * style.num("combat.hit_mark.spot_k") * plane_r
	var spot := Vector2.from_angle(a) * d
	var heading: float = mk.screen_heading
	var centre: Vector2 = mk.position + spot.rotated(heading)
	var r := clampf(style.num("combat.hit_mark.radius_k") * plane_r * (1.0 + style.num("combat.hit_mark.damage_k") * float(int(m["damage"]) - 1)),
		style.num("combat.hit_mark.min_radius_px"), style.num("combat.hit_mark.max_radius_px"))
	return {"centre": centre, "radius": r}

# --- Drawing ---------------------------------------------------------------------------------------

func _draw() -> void:
	if world == null or style == null:
		return
	var ok := true
	if style.flag("combat.hit_mark.enabled"):
		for m: Dictionary in marks:
			ok = _draw_mark(m) and ok
	if style.flag("combat.tracers.enabled"):
		ok = _draw_tracers() and ok
	failed_draws += 0 if ok else 1
	draw_count += 1

func _draw_mark(m: Dictionary) -> bool:
	var age := clock - float(m["t"])
	var a_ink := ink_alpha(age, style)
	if a_ink <= 0.0:
		return true
	var g := mark_geometry(m)
	if g.is_empty():
		return true
	var c: Vector2 = g["centre"]
	var r: float = g["radius"]
	var seed_v := int(m["seed"])
	# The flash: the paper pool, and the burst a little large in its first blink.
	var f := flash_alpha(age, style)
	if f > 0.0:
		var paper: Color = style.color("hit_flash")
		draw_circle(c, r * style.num("combat.hit_mark.flash_k"), Color(paper.r, paper.g, paper.b, paper.a * f), true, -1.0, true)
	var pop := 1.0 + 0.35 * f
	var ink: Color = style.color("hit_ink")
	var col := Color(ink.r, ink.g, ink.b, ink.a * a_ink)
	var n := int(style.num("combat.hit_mark.rays"))
	var inner: float = style.num("combat.hit_mark.ray_inner_k") * r
	var outer: float = style.num("combat.hit_mark.ray_outer_k") * r
	var w: float = style.num("combat.hit_mark.line_px")
	var base := hash_unit(seed_v, 3) * TAU
	for i in n:
		var ang := base + TAU * float(i) / float(maxi(n, 1)) + (hash_unit(seed_v, 10 + i) - 0.5) * 0.5
		var len_k := 0.55 + 0.45 * hash_unit(seed_v, 40 + i)
		var d := Vector2.from_angle(ang)
		draw_line(c + d * inner, c + d * (inner + (outer - inner) * len_k * pop), col, w, true)
	draw_circle(c, style.num("combat.hit_mark.dot_px"), col, true, -1.0, true)
	return true

func _draw_tracers() -> bool:
	if marker_layer == null or marker_layer.mapping == null:
		return true
	var tl: float = style.num("combat.tracers.life_s")
	var ink: Color = style.color("tracer")
	var w: float = style.num("combat.tracers.line_px")
	for s: Dictionary in tracers:
		var age := clock - float(s["t"])
		if age < 0.0 or age > tl:
			continue
		var a: float = 1.0 - age / maxf(tl, 1e-3)
		var p0: Vector2 = marker_layer.mapping.world_to_screen(s["a"])
		var p1: Vector2 = marker_layer.mapping.world_to_screen(s["b"])
		draw_line(p0, p1, Color(ink.r, ink.g, ink.b, ink.a * a), w, true)
	return true
