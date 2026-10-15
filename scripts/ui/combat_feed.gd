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
#
# SMOKE'S SHARED RULES (builder SMOKE, 2026-10-11; decisions smoke-consistency and impact-by-round-and-target; docs/proposals/smoke-audit.md):
#   a damaged unit's smoke is sized by its SOURCE (data/units damage_smoke.source_m, placed source_back_m behind its centre, climbing rise_mps), never
#   by its length; a unit with damage_smoke.enabled false (the stone bridge) leaves none, with no special case here;
#   a bomb or a shell that lands in WATER (the layer's impact_look, data fx.json impacts.water) is a splash of rings, with no flash, smoke, clods or
#   crater -- and none to put back for a late joiner.
#
# GUNFIRE (builder G3, 2026-10-12; decisions gunfire-looks (G3, the W1 soft puffs), round-model, impact-by-round-and-target, damage-looks): the fire, hit and
# shell_fire events also go to scripts/ui/gunfire_feed.gd, which looks up the ROUND the weapon fires (data/units weapons[].round -> data/sim/rounds.json) and
# draws, by what the data lists (data/fx/fx.json gunfire): a muzzle's flash and smoke for cannon rounds, flak shells and the Main Guns' shells, sized by the
# round's calibre; an impact for a cannon round that lands without destroying (a hit: the target's material; a miss: beside it, water or earth). The bombs'
# and shells' own impacts are above (B3, the water splash) and are not touched; tracers (T5) and the flak burst (F2) are as they were.

const UiFate = preload("res://scripts/ui/ui_fate.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const World = preload("res://scripts/sim/world.gd")
const FxTracer = preload("res://scripts/fx/fx_tracer.gd")   # (Track TR) FxTracer.feed_event: a fire event becomes the layer's tracer() call
const GunfireFeed = preload("res://scripts/ui/gunfire_feed.gd")   # (builder G3) a cannon's or a flak gun's muzzle smoke, a cannon round's impact, the Main Guns' salvo

var world: Object = null
var fx: Variant = null              # the FxLayer (or a fake with its calls)
var marker_layer: Object = null     # pose_of / height_above_ground / fall_height_above_ground / unit_visible
var health: RefCounted = null       # UiHealth: the health shown when the turn began
var style: RefCounted = null
var marks: Variant = null           # HitMarks, optional
# The turn being played, as events (Array of Dictionary): the feed reads ahead in it for where this turn's bombs land
# (UnitUI sets it). An empty Callable: no lookahead, a bomb is then dropped only from World.bombs_in_flight.
var lookahead: Callable = Callable()

var gunfire: GunfireFeed = null     # (builder G3, decision gunfire-looks) muzzles and impacts, from the rounds the weapons fire

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
	gunfire = GunfireFeed.new(self)
	gunfire.note_world()

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
	if gunfire != null:
		gunfire.begin_turn()
		gunfire.note_world()   # (reinforcements and a late joiner's units: every unit type of the World is in the round model's weapon index)
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
			if gunfire != null:
				gunfire.on_hit(ev, game_t)   # a cannon round that did not destroy lands as an impact on its target
		"fire":
			if marks != null:
				marks.add_shot(ev, game_t)
			if not _tracer(ev, game_t):   # a machine gun draws a tracer (Track TR), anything else from the ground at a plane is flak
				_flak(ev, game_t)
			if gunfire != null:
				gunfire.on_fire(ev, game_t)   # a cannon's or a flak gun's muzzle smoke, a missed cannon round's impact
		"bomb_release":
			_bomb_drops(ev, turn_no)
		"bomb_impact":
			_bomb_impact(ev, game_t)
		"shell_fire":
			_shell_flights(ev, turn_no)
			if gunfire != null:
				gunfire.on_shell_fire(ev, turn_no, game_t)   # the Main Guns' muzzle smoke, shell by shell
		"shell_impact":
			_shell_impact(ev, game_t)
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
			elif fate == Unit.FATE_OUT_OF_CONTROL and str(u.def.domain) == "sea":
				_sinks(id, u, ev, game_t)   # a ship goes down: the standard flash, then it sinks (no smoke, no damage drawn)
			elif fate == Unit.FATE_OUT_OF_CONTROL:
				_falling[id] = true
				_ride(id, float(ev.get("t", 0.0)), game_t)
			elif fate == Unit.FATE_DESTROYED:
				_destroyed(id, u, ev, game_t)
		"splash":
			# a ship at the moment it goes down, a plane at the surface: rings in the ink where it goes under (Track BB, decision ship-sinks)
			if world.units.has(id) and _may_show(id) and fx.has_method("splash"):
				fx.splash(id, Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0))), game_t, float(world.units[id].def.size_m))
		"crash":
			if not world.units.has(id):
				return
			_falling.erase(id)
			var u2 = world.units[id]
			if UiFate.under_water(u2):
				_scarred[id] = true   # on the water's floor: no ground crash, no smoke, no scar -- the unit lies there under the wash
				return
			var s2: Dictionary = world.sample(id, float(ev.get("t", 0.0)), "history")
			var pos := Vector2(float(ev.get("x", s2.get("x", 0.0))), float(ev.get("y", s2.get("y", 0.0))))
			var hd := float(s2.get("heading", NAN))
			if _may_show(id):
				fx.impact(id, pos, game_t, float(u2.def.size_m), hd)
			else:
				fx.add_scar(id, pos, game_t, float(u2.def.size_m), hd, _scar_seed(id))
			_scarred[id] = true

# --- The strike: flak, bombs, a ruin -----------------------------------------------------------

# MACHINE-GUN TRACERS (Track TR, 2026-10-11, PROPOSED; decision tracers-mg; scripts/fx/fx_tracer.gd, data/fx/fx.json tracers). A "fire" event of a
# weapon in the effects data's tracer list draws a tracer from the gun toward the target: tracer(shot id, weapon, muzzle, centre, aim, aim size,
# t, hit, accent, draw_k, seen_shooter, seen_target) on the layer, at the event's game time. centre = the shooter's centre at the event
# (World.sample), the aim size = the target's size_m x its marker's draw scale, the accent = the shooter's side accent (a palette name),
# seen_* = whether the player can see each unit (the data's fog policy decides). Returns true when the weapon is a tracer weapon, whether or
# not one was drawn (out of sight it is still no flak); false when it is not, or the layer has no tracers (a fake without them is fine).
func _tracer(ev: Dictionary, game_t: float) -> bool:
	if fx == null or not fx.has_method("tracer_weapon") or not bool(fx.tracer_weapon(str(ev.get("weapon", "")))):
		return false
	var sid := str(ev.get("unit", ""))
	var tid := str(ev.get("target", ""))
	if not world.units.has(sid) or not world.units.has(tid):
		return true
	var su = world.units[sid]
	var tu = world.units[tid]
	var s: Dictionary = world.sample(sid, float(ev.get("t", 0.0)), "history")
	var centre := Vector2(float(s["x"]), float(s["y"])) if not s.is_empty() else Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var accent_v: Variant = style.lookup("sides.accent." + str(su.side))
	var seen: Callable = marker_layer.unit_visible
	var seen_shooter: bool = not seen.is_valid() or bool(seen.call(sid))
	var seen_target: bool = not seen.is_valid() or bool(seen.call(tid))
	if style.flag("combat.fx.smoke_when_hidden"):
		seen_shooter = true
		seen_target = true
	var lead := Vector2.ZERO   # the target flies on while the round does: aim where it will be when the round arrives
	if fx.has_method("tracer_flight_s"):
		var t_ev := float(ev.get("t", 0.0))
		var p0: Dictionary = world.sample(tid, t_ev, "history")
		var p1: Dictionary = world.sample(tid, t_ev + float(fx.tracer_flight_s()), "history")
		if not p0.is_empty() and not p1.is_empty():
			lead = Vector2(float(p1["x"]) - float(p0["x"]), float(p1["y"]) - float(p0["y"]))
	FxTracer.feed_event(fx, ev, game_t, centre, float(tu.def.size_m) * _draw_scale(tid), str(accent_v) if accent_v is String else "", _draw_scale(sid), seen_shooter, seen_target, lead)
	return true

# A unit's marker draw scale (1 for a plane, more for what is drawn larger), 1 without a marker.
func _draw_scale(id: String) -> float:
	if marker_layer != null and marker_layer.has_method("marker"):
		var m: Object = marker_layer.marker(id)
		if m != null:
			return float(m.draw_scale)
	return 1.0

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

# THE BIG GUNS (Track SH, the warship, proposed 2026-10-10; scripts/sim/guns.gd): a salvo's shells, one by one, are drawn as the bombs
# are -- the layer's falling-bomb picture from the guns to where each lands (the shell's own height is the arc's apex) -- and a landing
# shell is a blast and a crater like a bomb's, the blast's size the shell's. The keys are apart from the bombs' (500000 + step x 1000 + shell).
static func _shell_key(step: int, shell: int) -> int:
	return 500000 + step * 1000 + shell

func _shell_flights(ev: Dictionary, turn_no: int) -> void:
	var shooter := str(ev.get("unit", ""))
	if not fx.has_method("bomb_drop") or not world.units.has(shooter) or not _may_show(shooter):
		return
	var step := int(ev.get("step", 0))
	var t0 := turn_t0(turn_no)
	# Shells still in the air at the turn's end are records of the World's shells_in_flight, the rest are among the turn's shell_impact events.
	for rec: Variant in world.shells_in_flight:
		var r: Dictionary = rec
		if str(r.get("unit", "")) == shooter and int(r.get("release_turn", -1)) == turn_no and int(r.get("step", -1)) == step:
			fx.bomb_drop(shooter, _shell_key(step, int(r.get("shell", 0))), Vector2(float(r["x0"]), float(r["y0"])), float(r.get("apex_m", 0.0)),
				t0 + float(r["release_t"]), Vector2(float(r["x"]), float(r["y"])), turn_t0(int(r["impact_turn"])) + float(r["impact_t"]))
	if not lookahead.is_valid():
		return
	for e: Variant in lookahead.call():
		var im: Dictionary = e
		if str(im.get("type", "")) != "shell_impact" or str(im.get("unit", "")) != shooter or int(im.get("step", -1)) != step 				or int(im.get("released_turn", turn_no)) != turn_no or int(im.get("turn", turn_no)) != turn_no:
			continue
		var rt := float(im.get("released_t", ev.get("t", 0.0)))
		var s: Dictionary = world.sample(shooter, rt, "history")
		if s.is_empty():
			continue
		fx.bomb_drop(shooter, _shell_key(step, int(im.get("shell", 0))), Vector2(float(s["x"]), float(s["y"])), 0.12 * Vector2(float(s["x"]) - float(im["x"]), float(s["y"]) - float(im["y"])).length(),
			t0 + rt, Vector2(float(im["x"]), float(im["y"])), t0 + float(im.get("t", rt)))

func _shell_impact(ev: Dictionary, game_t: float) -> void:
	var shooter := str(ev.get("unit", ""))
	var pos := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var blast := float(ev.get("blast_m", 20.0))
	var key := _shell_key(int(ev.get("step", 0)), int(ev.get("shell", 0)))
	if _lands_in_water(pos):
		if _may_show(shooter) and fx.has_method("water_impact"):
			fx.water_impact(pos, game_t, blast, shooter, "shell_large")   # a splash: no smoke, no crater, nothing to put back for a late joiner
		return
	if _may_show(shooter):
		if fx.has_method("bomb_impact"):
			fx.bomb_impact(pos, game_t, blast, shooter, key)
	elif fx.has_method("add_crater"):
		fx.add_crater(shooter, pos, game_t, blast, _scar_seed("%s/%d" % [shooter, key]))

# A bomb lands: the blast and the crater; out of sight only the crater, quietly.
func _bomb_impact(ev: Dictionary, game_t: float) -> void:
	var bomber := str(ev.get("unit", ""))
	var pos := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var blast := float(ev.get("blast_m", 45.0))
	var key := _bomb_key(int(ev.get("drop_index", 0)), int(ev.get("bomb", 0)))
	if _lands_in_water(pos):
		if _may_show(bomber) and fx.has_method("water_impact"):
			fx.water_impact(pos, game_t, blast, bomber, "bomb")   # a splash: no smoke, no crater, nothing to put back for a late joiner
		return
	if _may_show(bomber):
		if fx.has_method("bomb_impact"):
			fx.bomb_impact(pos, game_t, blast, bomber, key)
	elif fx.has_method("add_crater"):
		fx.add_crater(bomber, pos, game_t, blast, _scar_seed("%s/%d" % [bomber, key]))

# Whether a round that lands at `pos` lands in water (decision impact-by-round-and-target: "a round hitting water would splash, not explode with
# smoke"): the effects layer's say (impact_look, data fx.json impacts.water) over the World's water. A layer without the question (a fake) says land.
func _lands_in_water(pos: Vector2) -> bool:
	if world == null or not world.has_water() or fx == null or not fx.has_method("impact_look"):
		return false
	return str(fx.impact_look(world.water_depth_at(pos.x, pos.y))) == "splash"

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

# A SEA UNIT GOING DOWN (Track BB, decision ship-sinks): the flash every destroyed unit gets, sized by data game.sunk.effects_size_frac, and
# nothing else of the unit's own: no smoke column, no ruin, no scar. The sim lowers it through the water and the marker draws it under the
# water layer's wash (unit_sunk.gd).
func _sinks(id: String, u: Object, ev: Dictionary, game_t: float) -> void:
	if not _may_show(id) or not fx.has_method("down_flash"):
		return
	var boats = load("res://scripts/ui/unit_marker_art_boats.gd")
	var pos := Vector2(float(ev.get("x", u.x)), float(ev.get("y", u.y)))
	fx.down_flash(id, pos, game_t, float(u.def.size_m) * float(boats.effects_frac("patrol_boat")))

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
	# WHAT SMOKES (builder SMOKE, decisions smoke-consistency and impact-by-round-and-target): the unit's own data (damage_smoke): a unit that does not
	# smoke (the stone bridge) leaves none, and the puffs are sized by the SOURCE on the unit (an engine deck, a funnel), never by its length.
	var ds: Dictionary = u.def.damage_smoke
	if not bool(ds.get("enabled", false)):
		return
	var t0 := turn_t0(_turn)
	var sampler := func(tg: float) -> Dictionary:
		var s: Dictionary = world.sample(id, tg - t0, "history")
		return {"x": s["x"], "y": s["y"], "height_m": marker_layer.height_above_ground(s), "heading": s["heading"]}
	fx.emit_path(id, sampler, from_t, to_game_t, f, float(ds["source_m"]), float(ds["source_back_m"]), float(ds["rise_mps"]))

# One frame of a plane falling out of control: its pose at `t` seconds into the turn.
func _ride(id: String, t: float, game_t: float) -> void:
	if not _may_show(id):
		return
	var u = world.units[id]
	var s: Dictionary = world.sample(id, t, "history")
	if s.is_empty() or float(s.get("height_m", 0.0)) < 0.0:
		return   # (under the water the fall has no smoke)
	var ds: Dictionary = u.def.damage_smoke   # (the same engine that smoked before the fall smokes in it: its source, not the airframe's length)
	fx.falling(id, Vector2(float(s["x"]), float(s["y"])), marker_layer.fall_height_above_ground(s), game_t,
		float(u.def.size_m), float(s["heading"]), float(ds.get("source_m", -1.0)), float(ds.get("source_back_m", NAN)), float(ds.get("rise_mps", 0.0)))

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
		if UiFate.fate(u) != Unit.FATE_CRASHED or bool(_scarred.get(id, false)) or UiFate.under_water(u):
			continue   # (a unit on the water's floor leaves no scar: it lies there under the wash)
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
