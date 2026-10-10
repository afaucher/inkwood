extends RefCounted

# THE EFFECTS FEED (Track U2, the first fight, part 2): turns a turn's playback into the
# calls the effects layer (scripts/fx/fx_layer.gd, Track X) takes, and the ink marks
# (hit_marks.gd). UnitUI owns one, drives it from its playback signals and mounts the
# FxLayer it feeds. It holds no pixels and no nodes of its own, and the layer it feeds is
# whatever has the FxLayer calls (a test hands it a recording fake).
#
#   var feed := CombatFeed.new()
#   feed.setup(world, fx, marker_layer, health, style)
#   feed.marks = hit_marks                     # optional: a hit leaves its ink, a shot its tracer
#   feed.begin_turn(turn)                      # the playback of `turn` starts
#   feed.on_event(ev)                          # each event as the clock passes it (UnitUI.playback_event)
#   feed.on_frame(t, turn)                     # each frame of the playback (UnitUI.playback_frame)
#   feed.end_turn(turn)                        # it ended
#   feed.restore_wrecks()                      # a wreck already on the ground: add_scar
#
# GAME TIME. The effects layer lives on game time t = (turn - 1) x turn_seconds + the
# second of the turn (fx_layer.gd), the same for every call here.
#
# WHAT IT CALLS, and when (scripts/sim/combat.gd's events; the shapes are its header's):
#   hit            the unit's health fraction changes AT the event's time: damage smoke
#                  (emit_path, with the fraction as shown at that moment) is left along the
#                  path up to it with the fraction before, and from it with the fraction after.
#                  Every frame of the playback, a unit with 0 < health < full leaves smoke
#                  along the stretch it flew since the last frame (emit_path over [last, now]),
#                  sampled from World.sample on the exact grid of the layer, so how often the
#                  host calls changes nothing. A full-health plane makes none.
#   down, exploded explode_midair(unit, position, height above the ground, t, size_m, heading);
#                  its smoke stops (the blast has taken over) and its marker goes (the marker layer).
#   down, out_of_control
#                  falling() EVERY FRAME from then until the crash (and from the first frame of
#                  a later turn it is still falling in), with the pose and the height above the
#                  ground at the playback time, from World.sample: the marker layer flies the
#                  same plane, so the smoke is on the plane.
#   crash          impact(unit, position, t, size_m, heading): the blast, the plume, the scar
#                  and the smoke column from the wreck. Out of sight, the scar alone goes down
#                  (add_scar): the wreck is a fact of the map, the blast is not.
# A unit outside the player's sight (marker_layer.unit_visible) leaves no smoke and no blast
# (data combat.fx.smoke_when_hidden): a trail of puffs would give away where it flew.
#
# THE STRIKE (Track U3, 2026-10-10; the layer's calls are scripts/fx/fx_layer.gd's header, Track X2). Each is made
# only when the layer has the call (a fake without it is fine), at the event's game time:
#   fire, a GROUND shooter at an aircraft      flak_burst(target_pos, the target's height above the ground, t, hit,
#                                              "<shooter>/<tick>"): a burst beside the plane, in the plane's sight
#   bomb_release                               bomb_drop() once for each bomb of the stick: from the bomber's place at the
#                                              bomb's release to where it lands (this turn's, found among the turn's later
#                                              bomb_impact events, `lookahead`; one that lands in a later turn, in
#                                              World.bombs_in_flight), the bomb's id = drop_index x 1000 + its index
#   bomb_impact                                bomb_impact(pos, t, blast_m, bomber, bomb id): the blast, the crater that stays;
#                                              out of sight (the bomber's), add_crater alone
#   down, fate "destroyed" (the tower, a battery)   ruin(unit, pos, t, silhouette, size_m, heading); out of sight add_ruin; the
#                                              marker goes at the event (ui_fate.gd), and a ruin on the ground comes back with
#                                              restore_wrecks
# A bomb's fog rule is its BOMBER's: what your bomber drops you see land, what an unseen enemy drops you do not.

const UiFate = preload("res://scripts/ui/ui_fate.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const World = preload("res://scripts/sim/world.gd")

var world: Object = null
var fx: Variant = null              # the FxLayer (or a fake with its calls)
var marker_layer: Object = null     # pose_of / height_above_ground / fall_height_above_ground / unit_visible
var health: RefCounted = null       # UiHealth: the health shown when the turn began
var style: RefCounted = null
var marks: Variant = null           # HitMarks, optional
# The turn being played, as events (Array of Dictionary): the feed reads ahead in it for where this turn's bombs land
# (UnitUI sets it). An empty Callable: no lookahead, a bomb is then dropped only from World.bombs_in_flight.
var lookahead: Callable = Callable()

var _turn: int = 0
var _frac: Dictionary = {}          # unit id -> health fraction as shown now (0 for a unit that is down)
var _smoke_to: Dictionary = {}      # unit id -> game seconds the damage smoke has been left up to
var _falling: Dictionary = {}       # unit id -> true while the unit falls out of control
var _scarred: Dictionary = {}       # unit id -> true once a wreck of it is on the ground

func setup(w: Object, effects: Variant, markers: Object, ui_health: RefCounted, st: RefCounted) -> void:
	world = w
	fx = effects
	marker_layer = markers
	health = ui_health
	style = st

# --- The clock -----------------------------------------------------------------------------

func turn_t0(turn: int) -> float:
	return float(turn - 1) * float(world.rules.turn_seconds)

# The game time to show now: the playback's while one runs; the start of the turn being
# planned; the end of a turn that was resolved and has played.
func game_time(playing: bool, playback_turn: int, playback_t: float) -> float:
	if playing:
		return turn_t0(playback_turn) + playback_t
	var turn_no: int = int(world.turn)
	if str(world.phase) == World.PHASE_RESOLVED:
		return turn_t0(turn_no) + float(world.rules.turn_seconds)
	return turn_t0(turn_no)

# --- A turn's playback ------------------------------------------------------------------------

func begin_turn(turn: int) -> void:
	_turn = turn
	_frac.clear()
	_smoke_to.clear()
	_falling.clear()
	var t0 := turn_t0(turn)
	for id: String in world.units:
		var u = world.units[id]
		var full: int = maxi(int(u.def.health), 1)
		_frac[id] = clampf(float(health.shown(id, true)) / float(full), 0.0, 1.0)
		_smoke_to[id] = t0
		_falling[id] = UiFate.falls_from(u) <= 0.0 and UiFate.alive_until(u) > 0.0
	if marks != null:
		marks.begin_turn()

func end_turn(turn: int) -> void:
	_frac.clear()
	_falling.clear()
	if marks != null:
		marks.end_turn(turn_t0(turn) + float(world.rules.turn_seconds))

func on_frame(t: float, turn: int) -> void:
	var game_t := turn_t0(turn) + t
	if marks != null:
		marks.set_clock(game_t)
	for id: String in world.units:
		var u = world.units[id]
		var f: float = float(_frac.get(id, 0.0))
		if f > 0.0 and f < 1.0 and t < UiFate.alive_until(u):
			_leave_smoke(id, game_t)
		if bool(_falling.get(id, false)) and t < UiFate.alive_until(u):
			_ride(id, t, game_t)

func on_event(ev: Dictionary) -> void:
	var id := str(ev.get("unit", ""))
	var kind := str(ev.get("type", ""))
	var turn_no := int(ev.get("turn", _turn))
	var game_t := turn_t0(turn_no) + float(ev.get("t", 0.0))
	match kind:
		"hit":
			if world.units.has(id):
				_leave_smoke(id, game_t)
				var full: int = maxi(int(world.units[id].def.health), 1)
				_frac[id] = clampf(float(ev.get("health", 0)) / float(full), 0.0, 1.0)
			if marks != null:
				marks.add_hit(id, game_t, int(ev.get("damage", 1)))
		"fire":
			if marks != null:
				marks.add_shot(ev, game_t)
			_flak(ev, game_t)
		"bomb_release":
			_bomb_drops(ev, turn_no)
		"bomb_impact":
			_bomb_impact(ev, game_t)
		"down":
			if not world.units.has(id):
				return
			_leave_smoke(id, game_t)
			_frac[id] = 0.0
			var u = world.units[id]
			var fate := str(ev.get("fate", ""))
			if fate == Unit.FATE_EXPLODED:
				if _may_show(id):
					var s: Dictionary = world.sample(id, float(ev.get("t", 0.0)), "history")
					fx.explode_midair(id, Vector2(float(ev.get("x", s.get("x", 0.0))), float(ev.get("y", s.get("y", 0.0)))),
						marker_layer.height_above_ground(s), game_t, float(u.def.size_m), float(s.get("heading", NAN)))
			elif fate == Unit.FATE_OUT_OF_CONTROL:
				_falling[id] = true
				_ride(id, float(ev.get("t", 0.0)), game_t)
			elif fate == Unit.FATE_DESTROYED:
				_destroyed(id, u, ev, game_t)
		"crash":
			if not world.units.has(id):
				return
			_falling.erase(id)
			var u2 = world.units[id]
			var s2: Dictionary = world.sample(id, float(ev.get("t", 0.0)), "history")
			var pos := Vector2(float(ev.get("x", s2.get("x", 0.0))), float(ev.get("y", s2.get("y", 0.0))))
			var hd := float(s2.get("heading", NAN))
			if _may_show(id):
				fx.impact(id, pos, game_t, float(u2.def.size_m), hd)
			else:
				fx.add_scar(id, pos, game_t, float(u2.def.size_m), hd, _scar_seed(id))
			_scarred[id] = true

# --- The strike: flak, bombs, a ruin -----------------------------------------------------------

# A ground unit's shot at an aircraft: a burst of flak beside it (or on it, when the roll hit).
func _flak(ev: Dictionary, game_t: float) -> void:
	var sid := str(ev.get("unit", ""))
	var tid := str(ev.get("target", ""))
	if not fx.has_method("flak_burst") or not world.units.has(sid) or not world.units.has(tid):
		return
	if str(world.units[sid].def.domain) == "air" or str(world.units[tid].def.domain) != "air" or not _may_show(tid):
		return
	var s: Dictionary = world.sample(tid, float(ev.get("t", 0.0)), "history")
	var h: float = marker_layer.height_above_ground(s) if not s.is_empty() else float(ev.get("theight_m", 0.0))
	fx.flak_burst(Vector2(float(ev.get("tx", 0.0)), float(ev.get("ty", 0.0))), h, game_t, bool(ev.get("hit", false)),
		"%s/%s/%d" % [sid, str(ev.get("weapon", "")), int(ev.get("tick", 0))], 0.0)   # the weapon too: a battery's two guns roll on one tick

static func _bomb_key(drop_index: int, bomb: int) -> int:
	return drop_index * 1000 + bomb

# The bombs of a stick that just left, one by one: the layer draws each one falling.
func _bomb_drops(ev: Dictionary, turn_no: int) -> void:
	var bomber := str(ev.get("unit", ""))
	if not fx.has_method("bomb_drop") or not world.units.has(bomber) or not _may_show(bomber):
		return
	var drop_index := int(ev.get("drop_index", 0))
	var t0 := turn_t0(turn_no)
	# A bomb that lands in a later turn is a record of the World's bombs_in_flight.
	for rec: Variant in world.bombs_in_flight:
		var r: Dictionary = rec
		if str(r.get("unit", "")) == bomber and int(r.get("release_turn", -1)) == turn_no and int(r.get("drop_index", -1)) == drop_index:
			# (h0 is the sim's height above its 0 m; the layer wants it above the ground under the bomb)
			var h0 := float(r["h0"])
			if marker_layer.ground_height.is_valid():
				h0 = maxf(h0 - float(marker_layer.ground_height.call(float(r["x0"]), float(r["y0"]))), 0.0)
			fx.bomb_drop(bomber, _bomb_key(drop_index, int(r.get("bomb", 0))), Vector2(float(r["x0"]), float(r["y0"])), h0,
				t0 + float(r["release_t"]), Vector2(float(r["x"]), float(r["y"])), turn_t0(int(r["impact_turn"])) + float(r["impact_t"]))
	# One that lands this turn is among the turn's bomb_impact events.
	if not lookahead.is_valid():
		return
	for e: Variant in lookahead.call():
		var im: Dictionary = e
		if str(im.get("type", "")) != "bomb_impact" or str(im.get("unit", "")) != bomber or int(im.get("drop_index", -1)) != drop_index \
				or int(im.get("released_turn", turn_no)) != turn_no or int(im.get("turn", turn_no)) != turn_no:
			continue
		var rt := float(im.get("released_t", ev.get("t", 0.0)))
		var s: Dictionary = world.sample(bomber, rt, "history")
		if s.is_empty():
			continue
		fx.bomb_drop(bomber, _bomb_key(drop_index, int(im.get("bomb", 0))), Vector2(float(s["x"]), float(s["y"])), marker_layer.height_above_ground(s),
			t0 + rt, Vector2(float(im["x"]), float(im["y"])), t0 + float(im.get("t", rt)))

# A bomb lands: the blast and the crater; out of sight only the crater, quietly.
func _bomb_impact(ev: Dictionary, game_t: float) -> void:
	var bomber := str(ev.get("unit", ""))
	var pos := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var blast := float(ev.get("blast_m", 45.0))
	var key := _bomb_key(int(ev.get("drop_index", 0)), int(ev.get("bomb", 0)))
	if _may_show(bomber):
		if fx.has_method("bomb_impact"):
			fx.bomb_impact(pos, game_t, blast, bomber, key)
	elif fx.has_method("add_crater"):
		fx.add_crater(bomber, pos, game_t, blast, _scar_seed("%s/%d" % [bomber, key]))

# A static unit at 0 health: its ruin where it stood.
func _destroyed(id: String, u: Object, ev: Dictionary, game_t: float) -> void:
	var pos := Vector2(float(ev.get("x", u.x)), float(ev.get("y", u.y)))
	var kind := str(u.def.silhouette)
	if _may_show(id):
		if fx.has_method("ruin"):
			fx.ruin(id, pos, game_t, kind, float(u.def.size_m), float(u.heading))
	elif fx.has_method("add_ruin"):
		fx.add_ruin(id, pos, game_t, kind, float(u.def.size_m), float(u.heading), _scar_seed(id))
	_scarred[id] = true

# --- Smoke and the fall -----------------------------------------------------------------------

# Damage smoke along the stretch flown from the last call to `to_game_t`, at the unit's
# current health fraction.
func _leave_smoke(id: String, to_game_t: float) -> void:
	var from_t: float = float(_smoke_to.get(id, to_game_t))
	if to_game_t - from_t <= 1e-6:
		return   # nothing flown since the last call (an event on a frame's boundary)
	_smoke_to[id] = to_game_t
	var f: float = float(_frac.get(id, 0.0))
	if f <= 0.0 or f >= 1.0 or not _may_show(id):
		return
	var u = world.units[id]
	var t0 := turn_t0(_turn)
	var sampler := func(tg: float) -> Dictionary:
		var s: Dictionary = world.sample(id, tg - t0, "history")
		return {"x": s["x"], "y": s["y"], "height_m": marker_layer.height_above_ground(s), "heading": s["heading"]}
	fx.emit_path(id, sampler, from_t, to_game_t, f, float(u.def.size_m))

# One frame of a plane falling out of control: its pose at `t` seconds into the turn.
func _ride(id: String, t: float, game_t: float) -> void:
	if not _may_show(id):
		return
	var u = world.units[id]
	var s: Dictionary = world.sample(id, t, "history")
	if s.is_empty():
		return
	fx.falling(id, Vector2(float(s["x"]), float(s["y"])), marker_layer.fall_height_above_ground(s), game_t,
		float(u.def.size_m), float(s["heading"]))

# Whether this unit's effects may be shown: in the player's sight, or the data allows it.
func _may_show(id: String) -> bool:
	if style.flag("combat.fx.smoke_when_hidden"):
		return true
	var seen: Callable = marker_layer.unit_visible
	return not seen.is_valid() or bool(seen.call(id))

# --- Wrecks that are already on the ground --------------------------------------------------------

# A client that joins late (or whose layer was rebuilt) finds crashed units whose crash it never
# saw: each gets its scar back, as old as combat.fx.restore_age_s, so it is settled and
# its embers are out. During a playback only the wrecks of earlier turns are put back (this
# turn's crash is still to come, as an event). Returns how many were put back. `clear` empties
# the layer first (a rebuild).
func restore_wrecks(playing: bool, now_game_t: float, clear: bool = false) -> int:
	if clear:
		fx.clear()
		_scarred.clear()
	var n := 0
	for id: String in world.units:
		var u = world.units[id]
		if UiFate.fate(u) == Unit.FATE_DESTROYED and not bool(_scarred.get(id, false)) and fx.has_method("add_ruin"):
			if playing and is_finite(float(u.down_at)):
				continue   # destroyed in the turn being played: its event is still to come
			fx.add_ruin(id, Vector2(float(u.x), float(u.y)), now_game_t - float(style.num("combat.fx.restore_age_s")), str(u.def.silhouette),
				float(u.def.size_m), float(u.heading), _scar_seed(id))
			_scarred[id] = true
			n += 1
			continue
		if UiFate.fate(u) != Unit.FATE_CRASHED or bool(_scarred.get(id, false)):
			continue
		if playing and UiFate.crash_t(u) > 0.0:
			continue
		fx.add_scar(id, Vector2(float(u.x), float(u.y)), now_game_t - float(style.num("combat.fx.restore_age_s")),
			float(u.def.size_m), float(u.heading), _scar_seed(id))
		_scarred[id] = true
		n += 1
	return n

# A scar's own seed from the unit's id: the same wreck looks the same on every peer.
static func _scar_seed(id: String) -> int:
	return (hash(id) & 0x3FFFFFFF)
