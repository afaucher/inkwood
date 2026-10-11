extends "res://scripts/test_support/test_case.gd"

# MACHINE-GUN TRACERS (Track TR, 2026-10-11; EVERYTHING PROPOSED until Alex picks from variants/tracers/; the scope, machine guns
# only, is Alex's: decision tracers-mg). Headless: the records and the data, and the draw routine run to its end under a canvas.
#
#   1. the data: every value of fx.json tracers is a proposed record (the scope names its decision); the weapon list is the machine guns
#      and none of flak, light flak, the nose cannon or the tank's gun; every id in it is a weapon of some unit; five options, each with
#      the groups its form reads; every colour role they name exists, resolves to a palette base with no new hue
#   2. WHICH FIRE EVENTS DRAW ONE: real fire events from a resolved turn (the light fighter's wing guns, the bomber's tail turret) make
#      a tracer through FxTracer.feed_event; a flak event, a light-flak event, the nose cannon's, the tank's and a shell event do not;
#      through the CombatFeed: a machine gun draws a tracer and no flak burst, a battery's flak is a burst and no tracer, a shell is neither
#   3. HIT AND MISS: a hit ends on the target (inside the hit spread), a miss passes beside it (at least miss_min of the target's size
#      from its centre) and carries on past it; the muzzle is the gun's place in the drawn scale; both scale with the layer's true_scale
#   4. LIFE: a tracer is not there before its event, is there for life_s of the playback clock, and is gone at the end of it; the book caps
#      its records; a shot seen twice makes one
#   5. DETERMINISM: the same events make the same records, in any order, in a fresh book; another world seed makes other offsets
#   6. THE FOG POLICY of the data (shooter seen / either / always)
#   7. THE DRAW ROUTINE of every option runs to its end at several ages, hits and misses, two scales

const World = preload("res://scripts/sim/world.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxTracer = preload("res://scripts/fx/fx_tracer.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const CombatFeed = preload("res://scripts/ui/combat_feed.gd")

const SEED := 20261009
const MG_WEAPONS := ["wing_guns", "nose_gun", "dorsal_turret", "tail_turret", "rear_gunner", "aa_guns"]
const NOT_TRACER := ["flak", "light_flak", "nose_cannon", "turret_gun"]

# The effects layer as the feed sees it: the real tracer list from the data, the calls recorded.
class _FakeFx extends RefCounted:
	const FxT = preload("res://scripts/fx/fx_tracer.gd")
	const FxD = preload("res://scripts/fx/fx_data.gd")
	var book = FxT.Book.new(FxD.shared())
	var calls: Array = []
	func tracer_weapon(weapon: String) -> bool:
		return book.is_weapon(weapon)
	func tracer_flight_s() -> float:
		return book.flight_s()
	func tracer(shot_id: String, weapon: String, muzzle: Vector2, centre: Vector2, aim: Vector2, aim_size_m: float, t: float, hit: bool, accent: String = "", draw_k: float = 1.0, seen_shooter: bool = true, seen_target: bool = true) -> bool:
		calls.append({"call": "tracer", "shot": shot_id, "weapon": weapon, "muzzle": muzzle, "centre": centre, "aim": aim, "size": aim_size_m, "t": t, "hit": hit, "accent": accent, "k": draw_k, "ss": seen_shooter, "st": seen_target})
		return true
	func flak_burst(pos: Vector2, h: float, t: float, hit: bool, shot_id: String = "", _sz: float = 0.0) -> void:
		calls.append({"call": "flak_burst", "pos": pos, "h": h, "t": t, "hit": hit, "shot": shot_id})
	func of(kind: String) -> Array:
		return calls.filter(func(c: Dictionary) -> bool: return c["call"] == kind)

class _Markers extends RefCounted:
	var unit_visible: Callable = Callable()
	func height_above_ground(_s: Dictionary) -> float:
		return 400.0
	func marker(_id: String) -> Object:
		return null

# A canvas that draws the tracers of a book at a time and says whether the draw ran to its end.
class _Canvas extends Node2D:
	const FxT = preload("res://scripts/fx/fx_tracer.gd")
	var book: RefCounted = null
	var mapping: RefCounted = null
	var style: RefCounted = null
	var k: float = 1.0
	var now: float = 0.0
	var drawn: int = -1
	var ended: bool = false
	func _draw() -> void:
		drawn = FxT.draw_all(self, book, mapping, style, k, now, Rect2(-8000.0, -8000.0, 16000.0, 16000.0))
		ended = true

var _data: FxData
var _style: FxStyle
var _ran := {}

func setup(_main) -> void:
	timeout_seconds = 60.0
	_data = FxData.new()
	if not check(_data.ok(), "fx.json loads: %s" % str(_data.errors)):
		finish()
		return
	_style = FxStyle.new(_data)
	if not check(_style.ok(), "the effects' style resolves: %s" % str(_style.errors)):
		finish()
		return
	_check_data()
	var events := _real_events(7)
	_check_which(events)
	_check_feed(events)
	_check_hit_miss(events)
	_check_life()
	_check_determinism(events)
	_check_fog()
	await _check_draw(events)
	var missing: Array = []
	for k: String in ["data", "which", "feed", "hit_miss", "life", "determinism", "fog", "draw"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	check(FxData.shared().ok(), "no data error was raised by any of the above: %s" % str(FxData.shared().errors))
	finish()

# --- helpers ----------------------------------------------------------------------------------------------------------

# The fire events of a fighter chasing a bomber that fires its tail turret back, one turn of the real sim.
func _real_events(seed_value: int) -> Array:
	var w := _world(seed_value)
	w.commit("local")
	var r := w.resolve()
	var out: Array = []
	for ev: Dictionary in r.get("events", []):
		if ev["type"] == "fire":
			out.append(ev)
	return out

func _world(seed_value: int) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 1500.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1280.0, "y": 2480.0, "heading": 0.0, "speed": 100.0, "altitude_band": "medium"})
	return w

func _book() -> FxTracer.Book:
	return FxTracer.Book.new(_data)

# Feeds `events` into a book the way the feed does (centre = the unit's place; sizes from the unit defs); returns the book.
func _fill(book: FxTracer.Book, events: Array, world_seed: int = SEED, order: int = 1) -> void:
	var list := events.duplicate()
	if order < 0:
		list.reverse()
	for ev: Dictionary in list:
		var shot := "%s/%s/%d/%d/%d" % [ev["unit"], ev["weapon"], ev["hardpoint"], ev["turn"], ev["tick"]]
		var size := 20.0 if ev["target"] == "bomber" else 9.0
		book.add(world_seed, shot, str(ev["weapon"]), Vector2(float(ev["x"]), float(ev["y"])), _centre_of(ev), Vector2(float(ev["tx"]), float(ev["ty"])), size, 100.0 + float(ev["t"]), bool(ev["hit"]), "side_a")

# The shooter's centre for an event of the test world (the hardpoint's x/y less its offset: found from the unit's own track).
func _centre_of(ev: Dictionary) -> Vector2:
	# bomber: flies 85 m/s from 1500; fighter: 100 m/s from 1280 (its y is 2480)
	var t := float(ev["t"])
	if ev["unit"] == "bomber":
		return Vector2(1500.0 + 85.0 * t, 2500.0)
	return Vector2(1280.0 + 100.0 * t, 2480.0)

# --- 1. the data ------------------------------------------------------------------------------------------------------------

func _walk_records(node: Variant, path: String, out: Array[String]) -> void:
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	if d.has("value"):
		if not (d.get("_proposed") == true or d.has("decision")):
			out.append("%s is not marked _proposed or backed by a decision" % path)
		if not (d.get("_reason") is String) or str(d.get("_reason")).strip_edges() == "":
			out.append("%s has no _reason" % path)
		return
	for k: String in d:
		if k.begins_with("_"):
			continue
		var v: Variant = d[k]
		if not (v is Dictionary):
			out.append("%s.%s is a bare value, not a value record" % [path, k])
			continue
		_walk_records(v, path + "." + k, out)

func _unit_weapon_ids() -> Array:
	var ids: Array = []
	var dir := DirAccess.open("res://data/units")
	for f in dir.get_files():
		if not f.ends_with(".json") or f.begins_with("_"):
			continue
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/" + f))
		if v is Dictionary:
			for w: Variant in (v as Dictionary).get("weapons", []):
				ids.append(str((w as Dictionary).get("id", "")))
	return ids

func _check_data() -> void:
	var raw: Variant = _data.raw.get("tracers")
	if not check(raw is Dictionary, "fx.json has a tracers section"):
		return
	var bad: Array[String] = []
	_walk_records(raw, "tracers", bad)
	check(bad.is_empty(), "every value of tracers is a proposed record with a reason: %s" % str(bad.slice(0, 5)))
	var scope: Dictionary = (raw as Dictionary).get("scope", {})
	eq(str(scope.get("decision", "")), "tracers-mg", "the scope is Alex's decision tracers-mg")
	check(str(scope.get("_decided", "")).contains("Tracers for mg only for now"), "...with his words")
	var wrec: Dictionary = (raw as Dictionary).get("weapons", {})
	check(str(wrec.get("_reason", "")).contains("Tracers for mg only for now"), "the weapon list's reason quotes Alex's scope")
	check(wrec.get("_proposed") == true, "the weapon list (which ids are machine guns) is a proposal")
	var book := _book()
	check(book.enabled(), "tracers are on in the working data")
	var weapons: Array = book.cfg.get("weapons", [])
	var sorted_w := weapons.duplicate()
	sorted_w.sort()
	var want := MG_WEAPONS.duplicate()
	want.sort()
	eq(sorted_w, want, "the machine guns (and only they) are listed")
	for w: String in NOT_TRACER:
		check(not book.is_weapon(w), "'%s' draws no tracer" % w)
	var have := _unit_weapon_ids()
	for w: String in weapons:
		check(w in have, "listed weapon '%s' exists on some unit (data/units)" % w)
	# nothing in the code keys on a class or kind: adding the tank's gun is one id in the list
	var b2 := _book()
	check(not b2.is_weapon("turret_gun"), "the tank's gun is not a tracer weapon today")
	(b2.cfg["weapons"] as Array).append("turret_gun")
	check(b2.is_weapon("turret_gun"), "...and one id in the data list makes it one (no code change)")
	# options
	eq(book.option_names(), ["T1", "T2", "T3", "T4", "T5"], "five proposed options")
	check(book.cfg["options"].has(_data.working_default("tracers")), "the working default is one of them")
	var wd: Variant = (_data.raw["working_default"] as Dictionary).get("tracers")
	check(wd is Dictionary and (wd as Dictionary).get("_proposed") == true, "the working default is marked proposed")
	var hue_free := ["ink", "paper", "flash", "side_a", "side_b", "dirt"]
	var side_chroma: float = FxStyle.to_oklch(_style.palette["side_a"])[1]
	for name: String in book.option_names():
		book.select(name)
		var o := book.opt
		var form := FxData.s(o, "form")
		check(form in ["dashes", "streak", "dots"], "%s: a known form" % name)
		for g: String in ["timing", "colour", "widths", form]:
			check(o.get(g) is Dictionary, "%s: has the group '%s'" % [name, g])
		var roles: Array = []
		var col := FxData.grp(o, "colour")
		for key: String in ["core_role", "edge_role", "halo_role"]:
			roles.append(FxData.s(col, key))
		if form == "streak":
			roles.append(FxData.s(FxData.grp(o, "streak"), "trace_role"))
		for r: String in roles:
			if r == "":
				continue
			for side: String in ["side_a", "side_b"]:
				var rn := r.replace("@side", side)
				if not check(_style.has_role(rn), "%s: the role '%s' exists" % [name, rn]):
					continue
				var rec: Dictionary = _data.role(rn)
				check(rec.get("_proposed") == true or rec.has("decision"), "%s: role %s is a proposal" % [name, rn])
				check(str(rec.get("base", "")) in hue_free, "%s: role %s is built on a palette base, not a new colour (%s)" % [name, rn, str(rec.get("base", ""))])
				var c := FxStyle.to_oklch(_style.color(rn))
				check(c[1] <= side_chroma + 0.005, "%s: role %s is no more saturated than the side accents (%.3f)" % [name, rn, c[1]])
		# the numbers the draw routine reads are all there: a draw at an age is the proof (section 7); here the keys
		for key: String in ["life_s", "hold_frac", "fade_power", "flight_s"]:
			check(FxData.f(FxData.grp(o, "timing"), key) > 0.0, "%s: timing.%s is positive" % [name, key])
		check(FxData.f(FxData.grp(o, "timing"), "life_s") <= 1.5, "%s: a short life (a tracer is a flash, not a trail)" % name)
	_ran["data"] = true

# --- 2. which events ------------------------------------------------------------------------------------------------------------

func _check_which(events: Array) -> void:
	check(events.size() >= 20, "the resolved turn has fire events (%d)" % events.size())
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	var weapons_seen := {}
	for ev: Dictionary in events:
		weapons_seen[ev["weapon"]] = true
		var made := FxTracer.feed_event(layer, ev, 100.0 + float(ev["t"]), _centre_of(ev), 9.0, "side_a")
		eq(made, true, "a %s fire event is a tracer weapon's" % ev["weapon"])
	check(weapons_seen.has("wing_guns") and weapons_seen.has("tail_turret"), "the turn has the fighter's wing guns and the bomber's tail turret firing (%s)" % str(weapons_seen.keys()))
	eq(layer.field.tracers.records.size(), events.size(), "one tracer per fire event (a twin gun's two hardpoints are two)")
	# the wing guns have two hardpoints, so two tracers at one tick, a few metres apart
	var ticks := {}
	for rec in layer.field.tracers.records:
		if rec["weapon"] == "wing_guns":
			var key := "%.2f" % float(rec["born"])
			if not ticks.has(key):
				ticks[key] = []
			(ticks[key] as Array).append(rec["muzzle"])
	var twin_ok := not ticks.is_empty()
	for key: String in ticks:
		var ms: Array = ticks[key]
		if ms.size() != 2 or absf((ms[0] as Vector2).distance_to(ms[1]) - 6.0) > 0.1:
			twin_ok = false
	check(twin_ok, "the wing guns' two hardpoints (6 m apart) make two tracers at a tick")
	# what is not a machine gun
	var before: int = layer.field.tracers.records.size()
	for w: String in NOT_TRACER:
		var ev := {"type": "fire", "turn": 1, "tick": 99, "unit": "x", "weapon": w, "hardpoint": 0, "target": "y", "t": 1.0, "hit": true, "x": 0.0, "y": 0.0, "tx": 100.0, "ty": 0.0}
		eq(FxTracer.feed_event(layer, ev, 1.0, Vector2.ZERO, 9.0, "side_a"), false, "a '%s' event is no tracer" % w)
	eq(layer.field.tracers.records.size(), before, "...and adds none")
	# a layer without tracers is left alone
	var plain := RefCounted.new()
	eq(FxTracer.feed_event(plain, events[0], 100.0, Vector2.ZERO, 9.0, "side_a"), false, "a layer without tracers is left alone")
	layer.queue_free()
	_ran["which"] = true

func _check_feed(events: Array) -> void:
	var w := _world(7)
	w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3100.0, "y": 2300.0, "heading": 0.4})
	w.commit("local")
	w.resolve()   # the units have a path, so the feed can lead the target
	var fake := _FakeFx.new()
	var feed := CombatFeed.new()
	feed.setup(w, fake, _Markers.new(), null, UiStyle.shared())
	# a machine gun's fire event: a tracer, no flak
	var mg: Dictionary = events[1]
	check(str(mg["weapon"]) == "wing_guns", "the second event is the fighter's (%s)" % str(mg["weapon"]))
	feed.on_event(mg)
	eq(fake.of("tracer").size(), 1, "a wing-gun fire event draws one tracer")
	eq(fake.of("flak_burst").size(), 0, "...and no flak burst")
	if fake.of("tracer").size() == 1:
		var c: Dictionary = fake.of("tracer")[0]
		eq(c["weapon"], "wing_guns", "the tracer is the wing guns'")
		near((c["muzzle"] as Vector2).x, float(mg["x"]), 1e-3, "from the event's muzzle")
		near((c["aim"] as Vector2).y, float(mg["ty"]), 1e-3, "toward the event's target")
		# ...led by what the target flies while the round does (the bomber: 85 m/s east for the option's flight_s)
		var flight := fake.book.flight_s()
		near((c["aim"] as Vector2).x - float(mg["tx"]), 85.0 * flight, 0.05, "aimed %.1f m ahead of the target's place at the roll: where it is when the round arrives" % (85.0 * flight))
		eq(c["hit"], bool(mg["hit"]), "a hit or a miss as the roll was")
		near(float(c["size"]), 20.0, 1e-9, "sized by the target (the bomber's 20 m)")
		eq(c["accent"], "side_a", "in the shooter's side accent (the allies' side A)")
		near(float(c["t"]), (float(mg["turn"]) - 1.0) * float(w.rules.turn_seconds) + float(mg["t"]), 1e-9, "at the event's game time")
	# the bomber's tail turret too
	fake.calls.clear()
	var tail: Dictionary = events[0]
	eq(str(tail["weapon"]), "tail_turret", "the first event is the bomber's tail turret")
	feed.on_event(tail)
	eq(fake.of("tracer").size(), 1, "a turret's fire event draws a tracer")
	eq((fake.of("tracer")[0] as Dictionary)["accent"] if fake.of("tracer").size() == 1 else "", "side_b", "in the enemy's side B")
	# a battery's flak: a burst, no tracer
	fake.calls.clear()
	feed.on_event({"type": "fire", "turn": 1, "tick": 3, "unit": "aa1", "target": "bomber", "t": 1.0, "hit": true, "tx": 2600.0, "ty": 2400.0, "theight_m": 400.0, "weapon": "flak", "hardpoint": 0, "x": 3100.0, "y": 2300.0})
	eq(fake.of("tracer").size(), 0, "a battery's flak event draws no tracer")
	eq(fake.of("flak_burst").size(), 1, "...it is a flak burst still")
	fake.calls.clear()
	feed.on_event({"type": "fire", "turn": 1, "tick": 4, "unit": "aa1", "target": "bomber", "t": 1.0, "hit": false, "tx": 2600.0, "ty": 2400.0, "theight_m": 400.0, "weapon": "light_flak", "hardpoint": 0, "x": 3100.0, "y": 2300.0})
	eq(fake.of("tracer").size(), 0, "light flak draws no tracer")
	eq(fake.of("flak_burst").size(), 1, "...a burst")
	# a cruiser's shell: neither
	fake.calls.clear()
	feed.on_event({"type": "shell_fire", "turn": 1, "unit": "bomber", "step": 1, "t": 1.0})
	eq(fake.calls.size(), 0, "a shell_fire event draws neither a tracer nor a flak burst")
	# the feed leaves a layer without tracers as it was: flak for a ground shooter at a plane, nothing from a plane
	var old := _OldFx.new()
	var feed2 := CombatFeed.new()
	feed2.setup(w, old, _Markers.new(), null, UiStyle.shared())
	feed2.on_event(mg)
	eq(old.flak, 0, "a layer without tracer calls: a plane's shot is not flak (as before)")
	feed2.on_event({"type": "fire", "turn": 1, "tick": 3, "unit": "aa1", "target": "bomber", "t": 1.0, "hit": true, "tx": 2600.0, "ty": 2400.0, "theight_m": 400.0, "weapon": "flak", "hardpoint": 0, "x": 3100.0, "y": 2300.0})
	eq(old.flak, 1, "...and a battery's flak is a burst as before")
	# tracers switched off in the data: the feed falls back to flak for a ground-type machine gun
	var off := _FakeFx.new()
	off.book.cfg["enabled"] = false
	var feed3 := CombatFeed.new()
	feed3.setup(w, off, _Markers.new(), null, UiStyle.shared())
	feed3.on_event(mg)
	eq(off.of("tracer").size(), 0, "tracers off: none drawn")
	_ran["feed"] = true

class _OldFx extends RefCounted:
	var flak: int = 0
	func flak_burst(_p: Vector2, _h: float, _t: float, _hit: bool, _id: String = "", _sz: float = 0.0) -> void:
		flak += 1

# --- 3. hit and miss ------------------------------------------------------------------------------------------------------------

func _check_hit_miss(events: Array) -> void:
	var book := _book()
	var aimg: Dictionary = FxData.grp(book.cfg, "aim")
	var spread := FxData.f(aimg, "hit_spread")
	var miss_min := FxData.f(aimg, "miss_min")
	var hits := 0
	var misses := 0
	var worst_hit := 0.0
	var best_miss := 1e9
	var past := true
	var ends_apart := true
	var size := 20.0
	for i in 400:
		var muzzle := Vector2(1000.0, 1000.0)
		var aim := Vector2(1200.0 + float(i % 7) * 11.0, 1040.0)
		var hit := (i % 3 == 0)
		book.add(SEED, "t/%d" % i, "wing_guns", muzzle, muzzle, aim, size, 10.0, hit)
		var rec: Dictionary = book.records[book.records.size() - 1]
		var ln := book.line_world(rec, 1.0)
		eq(ln["a"], muzzle, "k = 1 and a centre on the muzzle: the line starts at the gun")
		var b: Vector2 = ln["b"]
		if hit:
			hits += 1
			worst_hit = maxf(worst_hit, b.distance_to(aim) / size)
		else:
			misses += 1
			var dir := (aim - muzzle).normalized()
			var rel := aim - muzzle
			var lateral := absf(rel.cross(((b - muzzle).normalized())))   # aim's distance from the line of fire
			best_miss = minf(best_miss, lateral / size)
			if (b - aim).dot(dir) <= 0.0:
				past = false
			if b.distance_to(aim) <= spread * size:
				ends_apart = false
	check(worst_hit <= spread + 1e-9, "a hit ends on the target: at most %.3f of its size from the centre (spread %.2f)" % [worst_hit, spread])
	check(best_miss >= miss_min * 0.98, "a miss passes the target by at least miss_min (%.2f of its size; closest %.3f)" % [miss_min, best_miss])
	check(past, "a miss carries on past the target")
	check(ends_apart, "a miss does not end on the target")
	check(hits > 100 and misses > 200, "the loop made hits and misses (%d, %d)" % [hits, misses])
	# the drawn scale: the gun's offset from its plane and the miss/hit offsets scale with true_scale
	var b2 := _book()
	var centre := Vector2(500.0, 500.0)
	var muz := centre + Vector2(10.5, 0.0)
	b2.add(SEED, "scale/1", "tail_turret", muz, centre, Vector2(900.0, 500.0), 20.0, 5.0, true, "side_a", 1.0)
	b2.add(SEED, "scale/2", "tail_turret", muz, centre, Vector2(900.0, 500.0), 20.0, 5.0, true, "side_a", 1.5)
	var l1 := b2.line_world(b2.records[0], 2.0)
	var l2 := b2.line_world(b2.records[1], 2.0)
	near((l1["a"] as Vector2).x, 500.0 + 21.0, 1e-9, "the gun sits at 2 x its offset from the centre at true_scale 2")
	near((l2["a"] as Vector2).x, 500.0 + 31.5, 1e-9, "...and at 3 x with the unit's draw scale 1.5")
	check((l1["b"] as Vector2).distance_to(Vector2(900.0, 500.0)) <= 2.0 * spread * 20.0 + 1e-9, "a hit still ends on the target at true_scale 2")
	# the event's own numbers: a real hit and a real miss from the sim
	var real_hit := 0
	var real_miss := 0
	var b3 := _book()
	_fill(b3, events)
	for rec in b3.records:
		var ln2 := b3.line_world(rec, 1.0)
		var d_aim: float = (ln2["b"] as Vector2).distance_to(rec["aim"])
		if bool(rec["hit"]):
			real_hit += 1
			check(d_aim <= spread * 20.0 + 1e-6, "a real hit ends on its target (%.1f m off)" % d_aim)
		else:
			real_miss += 1
			check(d_aim > spread * 9.0, "a real miss does not (%.1f m off)" % d_aim)
	check(real_hit > 0 and real_miss > 0, "the real turn has a hit and misses (%d, %d)" % [real_hit, real_miss])
	_ran["hit_miss"] = true

# --- 4. life -----------------------------------------------------------------------------------------------------------------

func _check_life() -> void:
	var book := _book()
	var life := FxData.f(FxData.grp(book.opt, "timing"), "life_s")
	book.add(SEED, "life/1", "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, 50.0, false)
	var rec: Dictionary = book.records[0]
	near(float(rec["life"]), life, 1e-12, "a tracer lives the option's life_s (%.2f s)" % life)
	eq(bool(book.state(rec, 49.99)["alive"]), false, "not there before its event")
	eq(bool(book.state(rec, 50.0)["alive"]), true, "there at its event")
	eq(bool(book.state(rec, 50.0 + life * 0.5)["alive"]), true, "there half way through its life")
	eq(bool(book.state(rec, 50.0 + life - 1e-6)["alive"]), true, "there just before its end")
	eq(bool(book.state(rec, 50.0 + life)["alive"]), false, "gone at the end of its life")
	eq(bool(book.state(rec, 90.0)["alive"]), false, "and long after")
	eq(book.live_count(50.1), 1, "one live at 0.1 s")
	eq(book.live_count(50.0 + life + 0.01), 0, "none after")
	check(float(book.state(rec, 50.0)["alpha"]) >= float(book.state(rec, 50.0 + life * 0.9)["alpha"]), "it fades, never brightens")
	near(float(book.state(rec, 50.0)["head"]), 0.0, 1e-9, "the round starts at the gun")
	near(float(book.state(rec, 50.0 + life * 0.5)["head"]), 1.0, 1e-9, "...and has flown the line well before the tracer is gone")
	# through the layer and a scrub: the same
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	layer.tracer("l/1", "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, 50.0, true)
	layer.set_time(50.1)
	eq(layer.field.tracers.live_count(layer.now), 1, "the layer shows it at 50.1")
	layer.set_time(50.0 + life + 0.5)
	eq(layer.field.tracers.live_count(layer.now), 0, "...not after its life")
	layer.set_time(50.1)
	eq(layer.field.tracers.live_count(layer.now), 1, "...and a scrub back shows it again")
	layer.clear()
	eq(layer.field.tracers.records.size(), 0, "clear() empties the book")
	layer.queue_free()
	# the cap
	var capped := _book()
	var cap := int(FxData.grp(capped.cfg, "limits").get("max_records", 0))
	check(cap > 0, "the data caps the records")
	for i in cap + 20:
		capped.add(SEED, "cap/%d" % i, "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, float(i), false)
	eq(capped.records.size(), cap, "the book keeps at most max_records")
	eq(str(capped.records[capped.records.size() - 1]["shot"]), "cap/%d" % (cap + 19), "...the newest")
	# a shot seen twice makes one
	var twice := _book()
	eq(twice.add(SEED, "same/1", "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, 1.0, true), true, "a shot is added")
	eq(twice.add(SEED, "same/1", "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, 1.0, true), false, "...the same shot again is not")
	eq(twice.records.size(), 1, "one record")
	twice.prune(1.0 + life + 11.0)
	eq(twice.records.size(), 0, "prune forgets what is long dead")
	_ran["life"] = true

# --- 5. determinism ---------------------------------------------------------------------------------------------------------

func _check_determinism(events: Array) -> void:
	var a := _book()
	var b := _book()
	_fill(a, events)
	_fill(b, events)
	eq(a.records, b.records, "the same events make the same tracers in a fresh book")
	var c := _book()
	_fill(c, events, SEED, -1)
	var by_shot := {}
	for rec in a.records:
		by_shot[str(rec["shot"])] = rec
	var same := c.records.size() == a.records.size()
	for rec in c.records:
		var o: Dictionary = by_shot.get(str(rec["shot"]), {})
		if o.is_empty() or o["off"] != rec["off"] or o["over"] != rec["over"] or o["seed"] != rec["seed"]:
			same = false
	check(same, "...and each shot's tracer is the same whatever order the events arrive in")
	var d := _book()
	_fill(d, events, SEED + 1)
	var differ := 0
	for rec in d.records:
		if (by_shot[str(rec["shot"])] as Dictionary)["off"] != rec["off"]:
			differ += 1
	check(differ > events.size() / 2, "another world seed offsets the tracers differently (%d of %d)" % [differ, events.size()])
	# the same events through the layer, twice
	var l1 := FxLayer.new()
	var l2 := FxLayer.new()
	add_child(l1)
	add_child(l2)
	l1.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	l2.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	for ev: Dictionary in events:
		FxTracer.feed_event(l1, ev, 100.0 + float(ev["t"]), _centre_of(ev), 20.0, "side_a")
		FxTracer.feed_event(l2, ev, 100.0 + float(ev["t"]), _centre_of(ev), 20.0, "side_a")
	eq(l1.field.tracers.records, l2.field.tracers.records, "two layers fed the same events hold the same tracers")
	l1.queue_free()
	l2.queue_free()
	_ran["determinism"] = true

# --- 6. the fog ---------------------------------------------------------------------------------------------------------------

func _check_fog() -> void:
	var book := _book()
	var mode := str(FxData.grp(book.cfg, "fog").get("shown_when", ""))
	eq(mode, "shooter_seen", "the working policy: only a shooter the player can see draws one")
	eq(book.shown(true, false), true, "a seen shooter: shown")
	eq(book.shown(false, true), false, "an unseen shooter at a seen target: not shown")
	eq(book.add(SEED, "fog/1", "wing_guns", Vector2.ZERO, Vector2.ZERO, Vector2(200, 0), 9.0, 1.0, true, "", 1.0, false, true), false, "...and add() makes none")
	(book.cfg["fog"] as Dictionary)["shown_when"] = "either_seen"
	eq(book.shown(false, true), true, "either_seen: the seen target is enough")
	eq(book.shown(false, false), false, "...neither seen: no")
	(book.cfg["fog"] as Dictionary)["shown_when"] = "always"
	eq(book.shown(false, false), true, "always: the fog is ignored")
	# through the feed: an unseen shooter draws nothing but is still no flak
	var w := _world(7)
	var fake := _FakeFx.new()
	var mk := _Markers.new()
	mk.unit_visible = func(id: String) -> bool: return id != "fighter"
	var feed := CombatFeed.new()
	feed.setup(w, fake, mk, null, UiStyle.shared())
	var ev := {"type": "fire", "turn": 1, "tick": 2, "unit": "fighter", "target": "bomber", "t": 0.5, "hit": false, "weapon": "wing_guns", "hardpoint": 0, "x": 1329.7, "y": 2477.0, "tx": 1542.5, "ty": 2500.0}
	feed.on_event(ev)
	var calls := fake.of("tracer")
	eq(calls.size(), 1, "the feed passes the sight on to the layer, which applies the data's policy")
	if calls.size() == 1:
		eq([calls[0]["ss"], calls[0]["st"]], [false, true], "...shooter not seen, target seen")
	_ran["fog"] = true

# --- 7. the draw ------------------------------------------------------------------------------------------------------------------

func _check_draw(events: Array) -> void:
	var canvas := _Canvas.new()
	add_child(canvas)
	canvas.mapping = UiMapping.from(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2(-2000.0, -4600.0)))
	canvas.style = _style
	var proper := true
	var any_drawn := 0
	for name: String in _book().option_names():
		var book := _book()
		book.select(name)
		_fill(book, events.slice(0, 12))
		canvas.book = book
		var life := float(book.records[0]["life"])
		for k_scale in [2.0, 0.7]:
			canvas.k = k_scale
			for frac in [0.0, 0.08, 0.3, 0.6, 0.95]:
				canvas.now = 100.0 + 0.5 + life * frac
				canvas.ended = false
				canvas.drawn = -1
				canvas.queue_redraw()
				var guard := 0
				while not canvas.ended and guard < 6:
					await get_tree().process_frame
					guard += 1
				if not canvas.ended:
					proper = false
					fail("%s: the draw did not run (frac %.2f, scale %.1f)" % [name, frac, k_scale])
				elif canvas.drawn < 0 or canvas.drawn != book.live_count(canvas.now):
					proper = false
					fail("%s: drew %d tracers, %d are live (frac %.2f)" % [name, canvas.drawn, book.live_count(canvas.now), frac])
				any_drawn += maxi(canvas.drawn, 0)
	check(proper, "every option's draw ran to its end at every age and scale")
	check(any_drawn > 40, "...and drew tracers (%d)" % any_drawn)
	# a tracer far off the view is left out, an empty book draws nothing
	canvas.book = _book()
	canvas.now = 100.5
	canvas.ended = false
	canvas.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	eq(canvas.drawn, 0, "an empty book draws nothing")
	canvas.queue_free()
	_ran["draw"] = true
