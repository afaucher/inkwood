extends RefCounted

# THE GUNFIRE FEED (builder G3, 2026-10-12; decisions gunfire-looks, round-model, impact-by-round-and-target and damage-looks): turns the sim's fire, hit and
# shell_fire events into the muzzle smoke and the impacts the effects layer draws (scripts/fx/fx_layer.gd gunfire_muzzle / gunfire_impact, the looks in
# scripts/fx/fx_gunfire.gd, the numbers in data/fx/fx.json gunfire). CombatFeed owns one and passes it the events. It holds no pixels and no nodes.
#
# ALEX: 'G3 W1 soft puffs' (gunfire-looks); 'Fired shots should have smoke for large rounds (tanks, artillery and ship cannons). Landed shots should have an
# impact even if they don't destroy you.' (third playtest); 'a round hitting water would splash, not explode with smoke' (impact-by-round-and-target);
# a round per weapon with class, calibre, explosive, path, tracer and blast (round-model); everything names a material (damage-looks).
#
# WHAT A WEAPON DOES is decided by the ROUND it fires (data/units/*.json weapons[].round -> data/sim/rounds.json), through two lists in the data:
#   MUZZLE   a "fire" event of a weapon whose round's class is in gunfire.muzzle.round_classes (cannon rounds, flak shells) and a "shell_fire" of the Main Guns
#            (shells): a flash and smoke at the gun, sized by the round's CALIBRE. The place is the fire event's hardpoint (x, y) plus the weapon's barrel
#            (gunfire.muzzle.weapons); the shells of a salvo leave the cruiser's barrels (gunfire.muzzle.shell_barrels) 0.2 s apart.
#   IMPACT   a "fire" event of a weapon whose round's class is in gunfire.impact.round_classes (cannon rounds):
#            a HIT that does not destroy (the "hit" event that follows it has health above 0): at the target, the TARGET's material (its unit file), a moment
#              after the muzzle (the round's flight), inside the target's drawn size; a hit that destroys is the explosion, the ruin or the sinking, not an impact
#            a MISS: at a visual-only point beside the target and along the line of fire (a side picked by the event, as a tracer's miss; seeded from the event,
#              never the combat dice), the material of what is there: WATER where the water is deep enough (fx.json impacts.water, the bombs' own test),
#              else EARTH (PROPOSED: no wall, house, tree or unit footprint is looked up until the lines of fire's stage 2 gives a miss a real landing place)
# Water always splashes and never smokes. Machine-gun bullets keep their tracers (T5) and their hit ink; flak keeps its burst (F2) and makes a muzzle only;
# shells and bombs keep B3 and the water splash (decided) and nothing here touches them.
#
# FOG. A muzzle is drawn when the player sees the shooter; an impact when he sees the shooter or the target (gunfire.*.shown_when, the tracers' rule).
# Everything is visual: nothing here is read by the sim, and every random number comes from Mulberry32 seeded by the event (world seed, the shot's id).

const Rounds = preload("res://scripts/sim/rounds.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

var host: Variant = null             # the CombatFeed: world, fx, marker_layer, _may_show(id), _draw_scale(id)
var rounds: Rounds = null
var _pending: Dictionary = {}        # "shooter|weapon|target|t_ms" -> Array of fire records waiting for their hit event

func _init(combat_feed: Variant) -> void:
	host = combat_feed
	rounds = Rounds.shared() as Rounds

func begin_turn() -> void:
	_pending.clear()

# The unit types of the World tell the round model which weapon fires which round (so a shipped game does not depend on a directory scan alone).
func note_world() -> void:
	if host == null or host.world == null:
		return
	for id: String in host.world.units:
		var def: Object = host.world.units[id].def
		rounds.note_weapons(str(def.id), def.weapon_values)

# --- The layer's side -------------------------------------------------------------------------------------------------------

func _fx() -> Object:
	var fx: Variant = host.fx
	if fx == null or not (fx is Object) or not fx.has_method("gunfire_enabled") or not fx.has_method("gunfire_muzzle") or not fx.has_method("gunfire_impact"):
		return null
	if not bool(fx.call("gunfire_enabled")):
		return null
	return fx as Object

func _shown(mode: String, shooter: String, target: String) -> bool:
	if mode == "always":
		return true
	if mode == "either_seen":
		return bool(host._may_show(shooter)) or (target != "" and bool(host._may_show(target)))
	return bool(host._may_show(shooter))

# The round a weapon of a unit fires (its unit file), "" when the unit or the weapon is unknown.
func round_of_weapon(unit_id: String, weapon_id: String) -> String:
	if not host.world.units.has(unit_id):
		return ""
	for wp in host.world.units[unit_id].def.weapons:
		if wp.id == weapon_id:
			return wp.round_id
	return ""

# --- A roll: the muzzle, and the miss's impact; a hit waits for its hit event --------------------------------------------------------

func on_fire(ev: Dictionary, game_t: float) -> void:
	var fx := _fx()
	if fx == null:
		return
	var sid := str(ev.get("unit", ""))
	var wid := str(ev.get("weapon", ""))
	var rid := round_of_weapon(sid, wid)
	var rnd: Rounds.Round = rounds.round_of(rid)
	if rnd == null:
		return
	var cfg: Dictionary = fx.call("gunfire_cfg")
	var tid := str(ev.get("target", ""))
	var shot := "%s/%s/%d/%d/%d" % [sid, wid, int(ev.get("hardpoint", 0)), int(ev.get("turn", 0)), int(ev.get("tick", 0))]
	var mz: Dictionary = cfg.get("muzzle", {})
	if rnd.round_class in (mz.get("round_classes", []) as Array):
		_muzzle(fx, ev, game_t, sid, wid, rid, shot, mz)
	var im: Dictionary = cfg.get("impact", {})
	if rnd.round_class in (im.get("round_classes", []) as Array) and host.world.units.has(tid):
		var rec := {"ev": ev, "game_t": game_t, "sid": sid, "tid": tid, "rid": rid, "shot": shot, "cfg": im}
		if bool(ev.get("hit", false)):
			var key := _key(sid, wid, tid, float(ev.get("t", 0.0)))
			if not _pending.has(key):
				_pending[key] = []
			(_pending[key] as Array).append(rec)
		else:
			_land(fx, rec, false)

# The hit event that follows a fire event of a hit: a round that did not destroy lands as an impact on the target.
func on_hit(ev: Dictionary, _game_t: float) -> void:
	var fx := _fx()
	if fx == null:
		return
	var key := _key(str(ev.get("by", "")), str(ev.get("weapon", "")), str(ev.get("unit", "")), float(ev.get("t", 0.0)))
	if not _pending.has(key):
		return
	var list: Array = _pending[key]
	var rec: Dictionary = list.pop_front()
	if list.is_empty():
		_pending.erase(key)
	if int(ev.get("health", 0)) <= 0:
		return   # it destroyed the target: the explosion, the ruin or the sinking is its look
	_land(fx, rec, true)

static func _key(shooter: String, weapon: String, target: String, t: float) -> String:
	return "%s|%s|%s|%d" % [shooter, weapon, target, int(round(t * 1000.0))]

# A muzzle: the flash and the smoke at the weapon's barrel, along the way it fires.
func _muzzle(fx: Object, ev: Dictionary, game_t: float, sid: String, wid: String, rid: String, shot: String, mz: Dictionary) -> void:
	if not _shown(str(mz.get("shown_when", "shooter_seen")), sid, ""):
		return
	var w: Object = host.world
	var s: Dictionary = w.sample(sid, float(ev.get("t", 0.0)), "history")
	var hp := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var centre := Vector2(float(s["x"]), float(s["y"])) if not s.is_empty() else hp
	var wcfg: Dictionary = (mz.get("weapons", {}) as Dictionary).get(wid, {})
	var tip := float(wcfg.get("tip_m", 0.0))
	var dir := float(s.get("heading", 0.0))
	if ev.has("bearing") and host.world.units.has(sid) and not (host.world.units[sid].def.turret as Dictionary).is_empty():
		# AN ORDERED SHOT (builder ORD, 2026-10-14; Alex, decision tank-fire-feedback): the smoke starts at the TIP of the barrel, along the turret's bearing -- the
		# direction the event says the gun pointed and the barrel's length from the unit's own data (turret.barrel_tip_m), not the hull's nose and a number in the fx data.
		dir = float(ev["bearing"])
		tip = float((host.world.units[sid].def.turret as Dictionary).get("barrel_tip_m", tip))
	elif str(wcfg.get("aim", "target")) == "target":
		var to_t := Vector2(float(ev.get("tx", hp.x)), float(ev.get("ty", hp.y))) - hp
		dir = to_t.angle() if to_t.length() > 1e-6 else dir
	var dv := Vector2.from_angle(dir)
	var off := hp - centre
	var up := float(ev.get("height_m", 0.0)) - float(s.get("height_m", 0.0))   # the hardpoint above the unit's base
	var h: float = maxf((host.marker_layer.height_above_ground(s) if not s.is_empty() else 0.0) + up, 0.0)
	fx.call("gunfire_muzzle", shot, rounds.muzzle_class(rid), centre, dir, off.dot(dv) + tip, game_t, h, off.dot(Vector2(-dv.y, dv.x)))

# A round lands: a hit on the target (not destroyed) or a miss beside it.
func _land(fx: Object, rec: Dictionary, is_hit: bool) -> void:
	var ev: Dictionary = rec["ev"]
	var cfg: Dictionary = rec["cfg"]
	var sid: String = rec["sid"]
	var tid: String = rec["tid"]
	if not _shown(str(cfg.get("shown_when", "either_seen")), sid, tid):
		return
	var w: Object = host.world
	var tu: Object = w.units[tid]
	var muz := Vector2(float(ev.get("x", 0.0)), float(ev.get("y", 0.0)))
	var aim := Vector2(float(ev.get("tx", muz.x)), float(ev.get("ty", muz.y)))
	var flight := muz.distance_to(aim) / maxf(float(cfg.get("flight_mps", 700.0)), 1.0)
	var t_ev := float(ev.get("t", 0.0))
	var s: Dictionary = w.sample(tid, t_ev + flight, "history")   # the target where it is when the round arrives
	var pos := Vector2(float(s["x"]), float(s["y"])) if not s.is_empty() else aim
	var line := aim - muz
	var dir := line.angle() if line.length() > 1e-6 else 0.0
	var dv := Vector2.from_angle(dir)
	var nrm := Vector2(-dv.y, dv.x)
	var size := float(tu.def.size_m) * float(host._draw_scale(tid))
	var rng := Mulberry32.new(FxBake.seed_of(int(w.rng_seed), str(rec["shot"]), "impact"))
	var airborne := str(tu.def.domain) == "air"
	var off := Vector2.ZERO
	var material := ""
	var h := 0.0
	if is_hit:
		off = Vector2.from_angle(rng.next() * TAU) * sqrt(rng.next()) * float(cfg.get("hit_spread_frac", 0.2)) * size
		material = str(tu.def.material)
		h = host.marker_layer.height_above_ground(s) if (airborne and not s.is_empty()) else 0.0
	else:
		var miss: Dictionary = cfg.get("miss", {})
		if airborne and str(miss.get("air_targets", "ground_below")) == "none":
			return
		var aside_r: Array = miss.get("aside_m", [4.0, 16.0])
		var along_r: Array = miss.get("along_m", [-10.0, 30.0])
		var side := -1.0 if rng.next() < 0.5 else 1.0
		var aside := maxf(lerpf(float(aside_r[0]), float(aside_r[1]), rng.next()), float(miss.get("clear_target_frac", 0.6)) * size)
		off = nrm * side * aside + dv * lerpf(float(along_r[0]), float(along_r[1]), rng.next())
		# what is there: water where the water is deep enough, else earth (PROPOSED; the lines of fire's stage 2 will say what a miss really hits)
		var ts_v: Variant = fx.get("true_scale")
		var at: Vector2 = pos + off * (float(ts_v) if ts_v != null else 1.0)
		material = "water" if _is_water(fx, at) else "earth"
	fx.call("gunfire_impact", "%s/land" % str(rec["shot"]), rounds.impact_class(str(rec["rid"])), material, pos, float(rec["game_t"]) + flight, dir, h, off)

# Whether a round that lands at `at` lands in water: the effects layer's say (fx.json impacts.water) over the World's water, as the bombs' and shells'.
func _is_water(fx: Object, at: Vector2) -> bool:
	var w: Object = host.world
	if w == null or not w.has_water() or not fx.has_method("impact_look"):
		return false
	return str(fx.call("impact_look", w.water_depth_at(at.x, at.y))) == "splash"

# --- The Main Guns -------------------------------------------------------------------------------------------------------------------

# A salvo leaves: one muzzle puff for each shell, from the cruiser's barrels, 0.2 s apart (the shells' own release times).
func on_shell_fire(ev: Dictionary, turn_no: int, game_t: float) -> void:
	var fx := _fx()
	if fx == null:
		return
	var sid := str(ev.get("unit", ""))
	var special := str(ev.get("special", ""))
	var rid := rounds.special_round(special)
	var rnd: Rounds.Round = rounds.round_of(rid)
	if rnd == null or not host.world.units.has(sid):
		return
	var cfg: Dictionary = fx.call("gunfire_cfg")
	var mz: Dictionary = cfg.get("muzzle", {})
	if not (rnd.round_class in (mz.get("round_classes", []) as Array)) or not _shown(str(mz.get("shown_when", "shooter_seen")), sid, ""):
		return
	var w: Object = host.world
	var spec: Object = w.guns.special(special) if w.get("guns") != null else null
	var interval := float(spec.salvo_interval_s) if spec != null else 0.2
	var s: Dictionary = w.sample(sid, float(ev.get("t", 0.0)), "history")
	if s.is_empty():
		return
	var centre := Vector2(float(s["x"]), float(s["y"]))
	var aim_a: Array = ev.get("aim", [centre.x, centre.y])
	var aim := Vector2(float(aim_a[0]), float(aim_a[1]))
	var dir := (aim - centre).angle() if aim.distance_to(centre) > 1e-6 else float(s.get("heading", 0.0))
	var dv := Vector2.from_angle(dir)
	var nrm := Vector2(-dv.y, dv.x)
	var hd := float(s.get("heading", 0.0))
	var hv := Vector2.from_angle(hd)
	var hs := Vector2(-hv.y, hv.x)
	var barrels: Dictionary = mz.get("shell_barrels", {})
	var end: Array = barrels.get("fore" if hv.dot(dv) >= 0.0 else "aft", [])
	# THE TURRETS TURN (builder ORD): with the turrets' bearing in the event, a shell leaves a barrel of the DRAWN turrets as they point at the target (the cruiser's art,
	# UnitMarkerArt.ship_muzzles), every turret fore and aft; without it the fx data's fixed barrels, as before.
	var drawn: Array = []
	if ev.has("turret_rel") and host.style != null:
		drawn = UnitMarkerArt.ship_muzzles(host.style, str(host.world.units[sid].def.silhouette), float(ev["turret_rel"]))
	if end.is_empty() and drawn.is_empty():
		return
	var up := float(barrels.get("up_m", 8.0))
	var h: float = maxf(host.marker_layer.height_above_ground(s), 0.0) + up
	var n := int(ev.get("shells", 1))
	for k in n:
		var off: Vector2
		if not drawn.is_empty():
			var bd: Dictionary = drawn[k % drawn.size()]
			off = hv * float(bd["fwd"]) + hs * float(bd["lat"])
		else:
			var b: Dictionary = end[k % end.size()]
			off = hv * float(b["fwd_m"]) + hs * float(b["lat_m"])
		var shot := "%s/%s/%d/%d/%d" % [sid, special, turn_no, int(ev.get("step", 0)), k]
		fx.call("gunfire_muzzle", shot, rounds.muzzle_class(rid), centre, dir, off.dot(dv), game_t + float(k) * interval, h, off.dot(nrm))
