extends "res://scripts/test_support/test_case.gd"

# THE FOREST FIRE'S DRAWING (track 'Forest fire', decision forest-fire; scripts/fx/fx_fire.gd, fx_fire_view.gd,
# scripts/render/fire_trunk.gd, chunk_terrain_provider.gd and map_view.gd). Headless: the state and the content, not the pixels
# (headless draws no frames: the windowed proof is scripts/render/fire_shot.gd). Against a FAKE FEED, so it does not depend on the sim.
#
#   1. the data: the forest_fire block is all PROPOSED value records with reasons; its colour roles exist; the fire switch is still off
#   2. the smoke: a column appears AT lit_t (not before), is thick (tone 2, a shadow caster) while the tree burns, dying and then thin
#      after burn-out, is gone life_s after its last puff, fades and rises as the data says, and is the same on every run and after a scrub
#   3. cost: a grove of hundreds is held to draw_budget puffs; sight (visible_at) takes columns out; an empty feed changes nothing
#   4. the layer: set_fire_feed reaches the smoke, an empty feed leaves the layer as it was, clear() empties it
#   5. the map: the chunks selected for a burnt tree include EVERY chunk whose content holds it (canopy and shadow reach), chunk_content
#      with a burnt set has the trunk and not the canopy, nothing else changes, the match is by place within the tolerance, the set can
#      shrink, and the trunk's ink makes no canvas group
#   6. MapView: only the touched chunks that are shown are marked, each is asked for again and keeps its old sprite until its new one
#      lands, and a bake that read the set before the change is baked again
#   7. FxFireView: the feed is handed over once per fire revision, the burnt set to the map when the game time reaches the end of the
#      turn a tree burns out in and not again, and a World without a fire does nothing
#   9. THE WIND (decision coastal-wind; a FAKE Wind, the sim's is scripts/sim/wind.gd): with one set a burning tree's column leans and trails
#      downwind (the centre of its mass is wind x the sim's drift_s from the tree, whichever way it blows and however fast), a puff takes the
#      air as it blew at its birth, a damaged plane's trail and a crash's burst, plume and wreck column drift with it, thick smoke keeps its
#      shadow (the shadows are drawn from the same drifted puffs), the layer hands it to both; with none every run is exactly what it was
#      (the two random numbers a puff's drift draws are drawn either way)
#   8. THE SANDBOX: with the fire knob on (Suppress), the real sandbox makes the view, the layer holds the World's feed and the map's
#      provider the trunks of the trees already out; with the fire off the sandbox makes none and the map and the layer are untouched

const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxFire = preload("res://scripts/fx/fx_fire.gd")
const FxFireView = preload("res://scripts/fx/fx_fire_view.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FireTrunk = preload("res://scripts/render/fire_trunk.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ShadowPass = preload("res://scripts/render/shadow_pass.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")

const FxField = preload("res://scripts/fx/fx_field.gd")
const WindScript = preload("res://scripts/sim/wind.gd")

const SEED := 20261009
const TS := 5.0

# The air: constant, plus `ramp` more m/s for every game second (so a puff born later feels more). Wind.at(game_s) -> Vector2, mean().
class FakeWind extends RefCounted:
	var v := Vector2(3.0, 0.0)
	var ramp := Vector2.ZERO
	var calls := 0
	func _init(velocity: Vector2 = Vector2(3.0, 0.0), per_second: Vector2 = Vector2.ZERO) -> void:
		v = velocity
		ramp = per_second
	func at(t: float) -> Vector2:
		calls += 1
		return v + ramp * t
	func mean() -> Vector2:
		return v

class FakeFire extends RefCounted:
	var revision := 0
	var list: Array = []
	var calls := 0
	func feed() -> Array:
		calls += 1
		return list

class FakeRules extends RefCounted:
	var turn_seconds := 5.0

class FakeWorld extends RefCounted:
	var fire: Variant = null
	var rules := FakeRules.new()

class FakeMap extends RefCounted:
	var sets: Array = []
	func set_burnt_trees(trees: Array) -> int:
		sets.append(trees.size())
		return 0

func setup(main) -> void:
	timeout_seconds = 240.0
	var data := FxData.new()
	if not check(data.ok(), "fx.json loads: %s" % str(data.errors)):
		finish()
		return
	_check_data(data)
	_check_smoke(data)
	_check_cost(data)
	await _check_layer(main)
	_check_provider()
	_check_trunk_ink()
	_check_map_view()
	_check_view()
	check(_check_wind(main, data), "9. the wind section ran to its end (a runtime error aborts a function in silence)")
	check(_check_real_wind(data), "9. the real Wind section ran to its end")
	await _check_sandbox(main)
	check(FxData.shared().ok(), "no data error was raised by any of the above: %s" % str(FxData.shared().errors))
	finish()

# --- helpers ---------------------------------------------------------------------------------------------------

static func _tree(id: String, x: float, y: float, lit_turn: int, lit_t: float, out_turn: int, r: float = 8.0) -> Dictionary:
	return {"id": id, "x_m": x, "y_m": y, "r_m": r, "lit_turn": lit_turn, "lit_t": lit_t, "out_turn": out_turn}

# Every leaf of a group is a value record: proposed (or backed by a decision) and with a reason.
func _walk(node: Variant, path: String, out: Array[String]) -> void:
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
		if not (d[k] is Dictionary):
			out.append("%s.%s is a bare value, not a value record" % [path, k])
			continue
		_walk(d[k], path + "." + k, out)

# --- 1. the data -------------------------------------------------------------------------------------------------

func _check_data(data: FxData) -> void:
	var raw: Variant = data.raw.get("forest_fire")
	if not check(raw is Dictionary, "1. fx.json has a forest_fire block"):
		return
	var bad: Array[String] = []
	for sec: String in ["smoke", "trunk", "map"]:
		check((raw as Dictionary).get(sec) is Dictionary, "1. forest_fire.%s exists" % sec)
		_walk((raw as Dictionary).get(sec), "forest_fire." + sec, bad)
	check(bad.is_empty(), "1. every value of the block is a proposed value record with a reason: %s" % str(bad.slice(0, 5)))
	var st := FxStyle.new(data)
	var trunk: Dictionary = FxData.unwrap((raw as Dictionary)["trunk"])
	for key: String in ["fill_role", "edge_role", "scorch_role", "scorch_dot_role", "tick_role"]:
		check(st.has_role(FxData.s(trunk, key)), "1. trunk.%s names a palette role that exists (%s)" % [key, trunk.get(key)])
	var smoke: Dictionary = FxData.unwrap((raw as Dictionary)["smoke"])
	check(data.smoke_option_names().has(FxData.s(smoke, "smoke_option")) or data.smoke_r2_option_names().has(FxData.s(smoke, "smoke_option")), "1. the smoke option it names exists (W1, decision damage-smoke)")
	eq(FxData.s(smoke, "smoke_option"), "W1", "1. the stand-in is today's W1 smoke (forest-fire option 6)")
	check(not data.fire_enabled(), "1. no fire: the fire switch is still off (decision fire-colour)")
	# no hex or colour literal anywhere in the block: colours are roles
	var text := JSON.stringify(raw)
	var rx := RegEx.new()
	rx.compile("#[0-9a-fA-F]{6}|\"color\"|oklch\\(")
	check(rx.search(text) == null, "1. no colour literal in the block (roles only)")
	check(FxData.b(smoke, "ground_shadow") and FxData.i(smoke, "tone_burning") >= FxData.i(smoke, "shadow_min_tone"), "1. thick smoke casts a shadow (decision smoke-shadow): the burning tone is a shadow caster")

# --- 2. the smoke ---------------------------------------------------------------------------------------------------

func _check_smoke(data: FxData) -> void:
	var fire := FxFire.new(data)
	check(fire.errors.is_empty(), "2. fx_fire.gd reads the block: %s" % str(fire.errors))
	eq(fire.turn_seconds, TS, "2. a turn is 5 s")
	check(not fire.active() and fire.puffs_at(10.0).is_empty(), "2. no feed, no smoke")
	var life: float = FxData.f(fire.cfg, "life_s")
	var tail: float = FxData.f(fire.cfg, "tail_s")
	var dying: float = FxData.f(fire.cfg, "dying_s")
	var iv: float = FxData.f(fire.cfg, "interval_s")
	# lit in turn 2 at 1.5 s, out_turn 4: smoking from game time 6.5 to the end of turn 4 (20 s)
	fire.set_feed([_tree("a", 100.0, 200.0, 2, 1.5, 4)])
	var t_on := TS + 1.5
	var t_end := 4.0 * TS
	eq(fire.puffs_at(t_on - 0.01).size(), 0, "2. no smoke before lit_t")
	eq(fire.columns_at(t_on - 0.01), 0, "2. and no column")
	var born := fire.puffs_at(t_on)
	eq(born.size(), 1, "2. AT lit_t the first puff appears (a fast flash: it appears almost at once)")
	if born.size() == 1:
		near(float(born[0]["u"]), 0.0, 1e-9, "2. born at the start of its life")
		near(float(born[0]["alpha"]), FxData.f(fire.option, "peak_alpha"), 1e-6, "2. at full strength")
		eq(int(born[0]["tone"]), FxData.i(fire.cfg, "tone_burning"), "2. thick (the burning tone)")
		eq(str(born[0]["tree"]), "a", "2. and it is the feed's tree")
	eq(fire.columns_at(10.0), 1, "2. one column for the one burning tree")
	# in the middle of the burn: a stream of thick puffs, each a shadow caster, fading and greying with age
	var mid := fire.puffs_at(12.0)
	check(mid.size() >= int(life / iv) - 1 and mid.size() <= int(ceil(life / iv)) + 1, "2. about life/interval puffs make the column (%d)" % mid.size())
	mid.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["u"]) < float(q["u"]))
	var prev_a := 2.0
	var prev_stage := 0
	var shadow_casters := 0
	for p: Dictionary in mid:
		check(float(p["alpha"]) <= prev_a + 1e-9, "2. a puff fades with age (u %.2f)" % float(p["u"]))
		check(int(p["stage"]) >= prev_stage, "2. and greys with age (stage %d)" % int(p["stage"]))
		prev_a = float(p["alpha"])
		prev_stage = int(p["stage"])
		eq(int(p["tone"]), FxData.i(fire.cfg, "tone_burning"), "2. mid-burn every puff is thick")
		if FxPuff.casts_shadow(fire.option, int(p["tone"])):
			shadow_casters += 1
		near(float(p["h"]), FxData.f(fire.cfg, "base_height_m") + FxData.f(fire.cfg, "rise_mps") * float(p["u"]) * life, 1e-3, "2. it rises")
	eq(shadow_casters, mid.size(), "2. thick smoke casts a shadow (smoke-shadow)")
	# the shadow is visible by the planes' rule at the map's play scale: a puff thick enough (alpha 0.25) and high enough
	var st := FxStyle.shared() as FxStyle
	var min_px: float = FxData.shared().common_num("min_shadow_px")
	var seen := 0
	for p: Dictionary in mid:
		var gap_px := st.plane_shadow_offset_m(float(p["h"])).length() * 2.0
		if float(p["alpha"]) >= 0.25 and gap_px >= min_px:
			seen += 1
	check(seen > 0, "2. at 2 px/m some puff is both thick enough and high enough for its shadow to show (%d)" % seen)
	# the last seconds of the burn: the medium tone; after burn-out: the thin one; none born after the tail
	var late := fire.puffs_at(t_end - 0.05)
	late.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["u"]) < float(q["u"]))
	eq(int(late[0]["tone"]), FxData.i(fire.cfg, "tone_dying"), "2. in the last dying_s the newest puff is the medium tone")
	var after := fire.puffs_at(t_end + tail - 0.3)
	after.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return float(p["u"]) < float(q["u"]))
	eq(int(after[0]["tone"]), FxData.i(fire.cfg, "tone_tail"), "2. after burn-out the newest puff is the thin one")
	check(float(after[0]["u"]) * life <= tail + iv * (1.0 + FxData.f(fire.cfg, "interval_jitter")) + 0.01, "2. and it is a recent one")
	check(fire.puff_count_at(t_end + 1.0) > 0, "2. the column lingers after burn-out")
	var gone := t_end + tail + life
	eq(fire.puffs_at(gone + 0.01).size(), 0, "2. life_s after the last puff the column is gone")
	eq(fire.columns_at(gone + 0.01), 0, "2. no column")
	# the smoke thins away within about a turn or two of the burn-out (PROPOSED: tail + life)
	check(gone - t_end <= 2.0 * TS, "2. it is gone within two turns of the burn-out (%.1f s)" % (gone - t_end))
	# the trunk: from the end of out_turn, never before
	eq(fire.burnt_at(t_end - 0.01).size(), 0, "2. not a trunk while it burns")
	var burnt := fire.burnt_at(t_end)
	eq(burnt.size(), 1, "2. a trunk from the end of out_turn on (out_turn + 1)")
	if burnt.size() == 1:
		eq(str(burnt[0]["id"]), "a", "2. the feed's tree")
		near(float(burnt[0]["x_m"]), 100.0, 1e-9, "2. at its place")
		near(float(burnt[0]["r_m"]), 8.0, 1e-9, "2. with its canopy radius")
	# determinism: the same feed on a fresh object, and a scrub back and forth, give the same smoke
	var other := FxFire.new(data)
	other.set_feed([_tree("a", 100.0, 200.0, 2, 1.5, 4)])
	var first := fire.puffs_at(14.0)
	fire.puffs_at(3.0)
	fire.puffs_at(25.0)
	var again := fire.puffs_at(14.0)
	eq(JSON.stringify(first), JSON.stringify(again), "2. a scrub back and forth draws the same frame")
	eq(JSON.stringify(first), JSON.stringify(other.puffs_at(14.0)), "2. and so does a fresh run of the same feed")
	# the hash is of the PLACE: the same tree under another id draws the same column
	var renamed := FxFire.new(data)
	renamed.set_feed([_tree("another-id", 100.0, 200.0, 2, 1.5, 4)])
	var rp := renamed.puffs_at(14.0)
	var same := rp.size() == first.size()
	for i in mini(rp.size(), first.size()):
		if (rp[i]["pos"] as Vector2) != (first[i]["pos"] as Vector2):
			same = false
	check(same, "2. the column does not depend on the id's format")
	# a tree whose end is not known yet burns on
	var open := FxFire.new(data)
	open.set_feed([_tree("o", 50.0, 60.0, 1, 0.0, -1)])
	check(open.puff_count_at(200.0) > 0, "2. an out_turn that is not known yet: it burns on")
	eq(open.burnt_at(200.0).size(), 0, "2. and is no trunk")
	# several trees: lit later appears later, burns out later
	fire.set_feed([_tree("a", 100.0, 200.0, 1, 0.0, 3), _tree("b", 140.0, 200.0, 2, 3.0, 4), _tree("c", 180.0, 200.0, 3, 0.5, 5)])
	eq(fire.columns_at(1.0), 1, "2. one burning at 1 s")
	eq(fire.columns_at(9.0), 2, "2. two at 9 s")
	eq(fire.columns_at(11.0), 3, "2. three at 11 s")
	eq(fire.burning_count(11.0), 3, "2. burning_count agrees")
	eq(fire.burnt_at(16.0).size(), 1, "2. one trunk after the end of turn 3")
	eq(fire.burnt_at(25.0).size(), 3, "2. three after turn 5")
	var order: Array = []
	for b: Dictionary in fire.burnt_at(25.0):
		order.append(str(b["id"]))
	eq(order, ["a", "b", "c"], "2. in the order they went out")

# --- 3. cost -----------------------------------------------------------------------------------------------------

func _check_cost(data: FxData) -> void:
	var fire := FxFire.new(data)
	var budget: int = FxData.i(fire.cfg, "draw_budget")
	var feed: Array = []
	for i in 600:
		feed.append(_tree("g%d" % i, 100.0 + float(i % 30) * 9.0, 100.0 + float(i / 30) * 9.0, 1, 0.0, 3, 8.0))
	fire.set_feed(feed)
	var n := fire.puff_count_at(8.0)
	var s := fire.stats()
	check(s["thinned"] > 0, "3. 600 burning trees are past the budget, so puffs are thinned (%d thinned)" % int(s["thinned"]))
	check(n <= budget, "3. and no more than draw_budget puffs are made (%d of %d)" % [n, budget])
	check(n >= budget / 2, "3. but the grove is not emptied (%d)" % n)
	eq(fire.columns_at(8.0), 600, "3. every column is still there")
	# sight takes columns out of the frame (smoke over fog would give a fire away)
	var half := FxFire.new(data)
	half.set_feed(feed.slice(0, 20))
	var all := half.puff_count_at(8.0)
	half.visible_at = func(p: Vector2) -> bool: return p.x < 190.0
	half.set_feed(feed.slice(0, 20))
	var some := half.puff_count_at(8.0)
	check(some > 0 and some < all, "3. a column out of sight is not made (%d of %d puffs)" % [some, all])
	half.visible_at = func(_p: Vector2) -> bool: return false
	half.set_feed(feed.slice(0, 20))
	eq(half.puff_count_at(8.0), 0, "3. none in sight, none drawn")
	# an empty feed changes nothing
	var empty := FxFire.new(data)
	empty.set_feed([])
	check(not empty.active() and empty.puff_count_at(5.0) == 0 and empty.burnt_at(5.0).is_empty() and empty.columns_at(5.0) == 0, "3. an empty feed makes nothing")
	empty.set_feed([{"id": "x"}, 7, "junk"])
	check(not empty.active(), "3. entries without a place are skipped")

# --- 4. the layer ---------------------------------------------------------------------------------------------------

func _check_layer(main: Node) -> void:
	var bare := FxLayer.new()
	main.add_child(bare)
	bare.setup(Transform2D.IDENTITY, SEED)
	var before := bare.stats()
	bare.set_fire_feed([])
	bare.set_time(30.0)
	await get_tree().process_frame
	eq(JSON.stringify(bare.stats()), JSON.stringify(before), "4. an empty feed changes nothing in the layer")
	var held := 0
	for k: String in bare.field.counts():
		held += int(bare.field.counts()[k])
	eq(held, 0, "4. and the field holds nothing of it")
	bare.set_fire_feed([_tree("a", 100.0, 200.0, 2, 1.5, 4), _tree("b", 130.0, 200.0, 2, 2.5, 4)], 5.0)
	bare.set_time(10.0)
	eq(int(bare.stats()["fire_trees"]), 2, "4. the layer holds the feed")
	eq(bare.fire.columns_at(bare.now), 2, "4. and a column per burning tree at its game time")
	bare.set_time(2.0)
	eq(bare.fire.columns_at(bare.now), 0, "4. none before they are lit")
	eq(bare.field.puffs.size(), 0, "4. the fire is not in the effects field's puffs (it has no cap to crowd out the planes' smoke)")
	check(bare._anything(), "4. a layer with a feed keeps redrawing with the camera")
	bare.set_fire_feed([_tree("a", 100.0, 200.0, 2, 1.5, 4)], 5.0)
	eq(int(bare.stats()["fire_trees"]), 1, "4. a longer or shorter feed replaces the old")
	bare.clear()
	eq(int(bare.stats()["fire_trees"]), 0, "4. clear() empties it (a new game)")
	check(not bare.fire.active(), "4. and nothing smokes")
	bare.queue_free()

# --- 5. the map ---------------------------------------------------------------------------------------------------------

func _tree_places(trees: Array, ppm: float) -> Dictionary:
	var out := {}
	for t: Dictionary in trees:
		out[Vector2i(roundi(float(t["x"]) * 10.0), roundi(float(t["y"]) * 10.0))] = t
	return out

# The tree of chunk `home` nearest its south-east corner (so the chunks round the corner hold it too).
func _corner_tree(prov: ChunkTerrainProvider, home: Vector2i) -> Dictionary:
	var trees: Array = prov.chunk_content(home)["trees"]
	var cp := float(prov.chunk_px)
	var corner := Vector2(float(home.x + 1) * cp, float(home.y + 1) * cp)
	var pick: Dictionary = trees[0]
	for t: Dictionary in trees:
		if Vector2(t["x"], t["y"]).distance_to(corner) < Vector2(pick["x"], pick["y"]).distance_to(corner):
			pick = t
	return pick

func _check_provider() -> void:
	var P := RenderParams.new()
	var cfg := MapView.load_config(P.source_path)
	var prov := ChunkTerrainProvider.new(SEED, P, cfg, 2.0)
	if not check(prov.ok(), "5. terrain provider loads: %s" % ", ".join(prov.errors)):
		return
	var ppm: float = prov.px_per_m()
	var home := Vector2i(4, 4)
	var base: Dictionary = prov.chunk_content(home)
	eq((base["trunks"] as Array).size(), 0, "5. nothing is a trunk while nothing has burnt")
	var trees: Array = base["trees"]
	if not check(trees.size() > 20, "5. the test chunk has trees (%d)" % trees.size()):
		return
	# the tree nearest a chunk corner, so more than one chunk holds it
	var pick := _corner_tree(prov, home)
	var key := Vector2i(roundi(float(pick["x"]) * 10.0), roundi(float(pick["y"]) * 10.0))
	# the contents of the neighbourhood before the fire
	var before := {}
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var c := home + Vector2i(dx, dy)
			before[c] = prov.chunk_content(c)
	var holders: Array = []
	for c: Vector2i in before:
		if _tree_places((before[c]["trees"] as Array), ppm).has(key):
			holders.append(c)
	check(holders.size() >= 2, "5. the picked tree is held by more than one chunk (its canopy and shadow reach across a border): %d" % holders.size())
	# burn it out
	var place := {"x_m": float(pick["x"]) / ppm, "y_m": float(pick["y"]) / ppm, "r_m": float(pick["r"]) / ppm, "id": "pick"}
	var changed: Array = prov.set_burnt_trees([place])
	for c: Vector2i in holders:
		check(changed.has(c), "5. chunk %s holds the burnt tree and is selected to be baked again" % c)
	var extra := 0
	for c: Vector2i in changed:
		if not holders.has(c):
			extra += 1
	check(extra <= 6, "5. and the selection is not wasteful: %d chunks beyond the holders (the border and tolerance margin)" % extra)
	for c: Vector2i in before:
		var now: Dictionary = prov.chunk_content(c)
		var held: bool = holders.has(c)
		eq(_tree_places(now["trunks"], ppm).has(key), held, "5. chunk %s: the tree is a trunk exactly where it was held" % c)
		eq(_tree_places(now["trees"], ppm).has(key), false, "5. chunk %s: the canopy is gone" % c)
		var was: Array = before[c]["trees"]
		eq((now["trees"] as Array).size() + (now["trunks"] as Array).size(), was.size(), "5. chunk %s: no tree appeared or vanished" % c)
		if not held:
			eq(JSON.stringify(now["trees"]), JSON.stringify(was), "5. chunk %s: a chunk that did not hold it is exactly as it was" % c)
		else:
			# the other trees keep their order
			var rest: Array = []
			for t: Dictionary in was:
				if Vector2i(roundi(float(t["x"]) * 10.0), roundi(float(t["y"]) * 10.0)) != key:
					rest.append(t)
			eq(JSON.stringify(now["trees"]), JSON.stringify(rest), "5. chunk %s: the others keep their order and values" % c)
			var tr: Dictionary = (now["trunks"] as Array)[0]
			for f: String in ["x", "y", "r", "h", "seed", "base", "level"]:
				check(tr.has(f), "5. the trunk record keeps '%s'" % f)
		check(int(now["burn_serial"]) == prov.burnt_serial(), "5. the content says which set it read")
	# the gather stage: no sprite for the canopy, the trunk handed on
	var h0: Vector2i = holders[0]
	var g: Dictionary = prov._gather({"c": h0, "rect": prov.chunk_rect(h0)})
	var so: Array = g["data"]["sprite_objects"]
	var in_sprites := false
	for o: Dictionary in so:
		if o.get("kind", "") == "tree" and Vector2i(roundi(float(o["x"]) * 10.0), roundi(float(o["y"]) * 10.0)) == key:
			in_sprites = true
	check(not in_sprites, "5. the burnt tree asks for no canopy sprite")
	eq((g["data"]["trunks"] as Array).size(), 1, "5. and is handed on as a trunk")
	# the baked serial: a chunk is current only once a bake has read this set
	check(not prov.burn_current(h0), "5. a chunk the change touched is not current until a bake reads the set")
	prov._baked_serial[h0] = int(g["data"]["burn_serial"])
	check(prov.burn_current(h0), "5. and is, once one has")
	prov._baked_serial[h0] = prov.burnt_serial() - 1
	check(not prov.burn_current(h0), "5. a bake that read an older set is not")
	# matching is by PLACE within the tolerance, never by id
	var tol: float = prov.burnt_tolerance_m
	var near_p := {"x_m": place["x_m"] + tol * 0.8, "y_m": place["y_m"], "id": "different"}
	prov.set_burnt_trees([near_p])
	eq(_tree_places(prov.chunk_content(h0)["trunks"], ppm).has(key), true, "5. a place %.2f m off still matches (tolerance %.2f m)" % [tol * 0.8, tol])
	var far_p := {"x_m": place["x_m"] + tol * 3.0, "y_m": place["y_m"], "id": "pick"}
	prov.set_burnt_trees([far_p])
	eq(_tree_places(prov.chunk_content(h0)["trunks"], ppm).has(key), false, "5. a place %.2f m off does not, whatever the id says" % [tol * 3.0])
	# the set can shrink: back to the first state
	var back: Array = prov.set_burnt_trees([])
	check(back.size() > 0, "5. taking the set away selects chunks too")
	for c: Vector2i in before:
		eq(JSON.stringify(prov.chunk_content(c)["trees"]), JSON.stringify(before[c]["trees"]), "5. chunk %s: with no burnt tree it is exactly what it was" % c)
	eq(prov.set_burnt_trees([]).size(), 0, "5. the same (empty) set again selects nothing")
	prov.set_burnt_trees([place])
	eq(prov.set_burnt_trees([place]).size(), 0, "5. the same set again selects nothing")

func _check_trunk_ink() -> void:
	var P := RenderParams.new()
	var look := FireTrunk.look()
	if not check(look.ok, "5. the trunk's look reads"):
		return
	var magenta := Color(1.0, 0.0, 1.0)
	for c: Color in [look.fill, look.edge, look.scorch, look.dot, look.tick]:
		check(c != magenta, "5. every trunk colour resolves to a palette role")
	var rec := {"x": 120.0, "y": 100.0, "r": 22.0, "h": 90.0, "seed": 12345, "base": 0.0, "level": 0}
	check(FireTrunk.trunk_radius(rec, look) >= look.r_min_px, "5. the trunk is at least its minimum")
	check(FireTrunk.trunk_height(rec, look) < float(rec["h"]), "5. and shorter than the tree was")
	var g := InkCanvas.new(Vector2i(256, 256))
	var made := FireTrunk.draw(g, [rec, rec.duplicate()], P, look)
	eq(made, 2, "5. two trunks drawn")
	check(g.op_count() > 0, "5. and they put ink down")
	eq(g.group_count(), 0, "5. with no canvas group (a group is a pass over the whole chunk: a hundred trunks must not make a hundred)")
	g.discard()
	# the trunk's own small shadow
	var prov := ChunkTerrainProvider.new(SEED, P, MapView.load_config(P.source_path), 2.0)
	var sp := ShadowPass.new(Vector2i(256, 256))
	var n := FireTrunk.add_shadows(sp, [rec], 0, Transform2D.IDENTITY, prov.ts, look)
	eq(n, 1, "5. a trunk casts a small shadow of its own")
	sp.canvas.discard()

# --- 6. the map view -----------------------------------------------------------------------------------------------------

func _check_map_view() -> void:
	var view := MapView.new(SEED, Rect2(), 2.0, "terrain", RenderParams.new())
	view.bake_enabled = false
	view.input_enabled = false
	if not check(view.errors().is_empty(), "6. map view loads: %s" % str(view.errors())):
		return
	var prov: ChunkTerrainProvider = view.provider
	var ppm := view.px_per_m
	var home := Vector2i(4, 4)
	var pick := _corner_tree(prov, home)
	var place := {"x_m": float(pick["x"]) / ppm, "y_m": float(pick["y"]) / ppm, "r_m": float(pick["r"]) / ppm, "id": "p"}
	var touched: Array = prov.chunks_touched_by(Vector2(place["x_m"], place["y_m"]))
	check(touched.has(home), "6. the picked tree's own chunk is among the chunks it touches")
	check(touched.size() >= 2, "6. and it touches more than one (%d)" % touched.size())
	# every chunk of the map is "shown" as a fake sprite; the view is where the tree is
	var mr := view.map_rect()
	var side_x := ceili(mr.end.x / float(view.chunk_px))
	var side_y := ceili(mr.end.y / float(view.chunk_px))
	for cy in side_y:
		for cx in side_x:
			var s := Sprite2D.new()
			view.map_layer.add_child(s)
			view._chunks[Vector2i(cx, cy)] = s
	view.cfg["max_cached_chunks"] = 1000
	var old_sprite: Sprite2D = view._chunks[home]
	eq(view.dirty_count(), 0, "6. nothing is dirty at first")
	var n := view.set_burnt_trees([place])
	eq(n, touched.size(), "6. set_burnt_trees says how many chunks changed (%d)" % n)
	eq(view.dirty_count(), touched.size(), "6. and exactly those shown chunks are marked, no others")
	for c: Vector2i in touched:
		check(view.is_dirty(c), "6. chunk %s is marked" % c)
	eq(view.set_burnt_trees([place]), 0, "6. the same set again changes nothing")
	eq(view.dirty_count(), touched.size(), "6. and marks nothing more")
	# the schedule asks for them again, low in the order, and the old sprite stays meanwhile
	view.look_at_m(Vector2(place["x_m"], place["y_m"]))
	view._schedule()
	for c: Vector2i in touched:
		check(view.baker.is_busy(c), "6. chunk %s is asked for again" % c)
		check(view.baker.priority_of(c) >= MapView.DIRTY_OFFSET, "6. behind the view's own missing chunks (%.1f)" % view.baker.priority_of(c))
	check(view._chunks[home] == old_sprite and is_instance_valid(old_sprite), "6. the old sprite of a chunk to be baked again stays on screen until its new one lands")
	eq(view.chunk_count(), side_x * side_y, "6. no chunk went blank")
	# the new picture lands: it replaces the old, the chunk is clean
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	prov._baked_serial[home] = prov.burnt_serial()
	view._show(home, tex)
	check(view._chunks[home] != old_sprite, "6. the new sprite replaces the old")
	check(not view.is_dirty(home), "6. and the chunk is clean")
	eq(view.dirty_count(), touched.size() - 1, "6. the others still wait")
	# a bake that read the set before a change that touched the chunk is shown but baked again
	var c2: Vector2i = touched[touched.size() - 1] if touched[touched.size() - 1] != home else touched[0]
	prov._baked_serial[c2] = prov.burnt_serial() - 1
	view._show(c2, tex)
	check(view.is_dirty(c2), "6. a bake that read an older set leaves the chunk to be baked again")
	# a full rebake bakes everything afresh: nothing is left dirty
	view.rebake()
	eq(view.dirty_count(), 0, "6. rebake() starts over")
	# the scene stand-in has no burnt trees: nothing happens
	var scene := MapView.new(SEED, Rect2(0, 0, 5000, 5000), 2.0, "scene", RenderParams.new())
	scene.bake_enabled = false
	eq(scene.set_burnt_trees([place]), 0, "6. a provider without burnt trees ignores them")
	scene.free()
	view.free()

# --- 7. the view that carries the feed -----------------------------------------------------------------------------------

func _check_view() -> void:
	var world := FakeWorld.new()
	var map := FakeMap.new()
	var fx := FxLayer.new()
	get_tree().root.add_child(fx)
	fx.setup(Transform2D.IDENTITY, SEED)
	var clock := [0.0]
	var view := FxFireView.new()
	view.setup(world, fx, map, func() -> float: return clock[0])
	eq(view.sync(), false, "7. a World without a fire: nothing to do")
	eq(map.sets.size(), 0, "7. and the map is never touched")
	eq(int(fx.stats()["fire_trees"]), 0, "7. nor the layer")
	var fire := FakeFire.new()
	fire.list = [_tree("a", 100.0, 200.0, 1, 0.0, 3), _tree("b", 140.0, 200.0, 2, 1.0, 4)]
	fire.revision = 1
	world.fire = fire
	clock[0] = 2.0
	eq(view.sync(), true, "7. a World with a fire: the view works")
	eq(fire.calls, 1, "7. the feed was taken once")
	eq(int(fx.stats()["fire_trees"]), 2, "7. and handed to the layer")
	eq(map.sets.size(), 1, "7. the map is told once (nothing burnt out yet: an empty set)")
	view.sync()
	view.sync()
	eq(fire.calls, 1, "7. the feed is not asked for again while the fire's revision stands")
	eq(map.sets.size(), 1, "7. and the map is not told again")
	clock[0] = 15.0   # the end of turn 3: tree a is out
	view.sync()
	eq(map.sets.size(), 2, "7. when the game time reaches the end of the turn a tree burns out in the map is told")
	eq(int(map.sets[1]), 1, "7. of one trunk")
	view.sync()
	eq(map.sets.size(), 2, "7. once")
	clock[0] = 14.0   # a scrub back: the set shrinks
	view.sync()
	eq(map.sets.size(), 3, "7. a time before it (a scrub) takes the trunk away again")
	eq(int(map.sets[2]), 0, "7. an empty set")
	fire.list.append(_tree("c", 180.0, 200.0, 3, 0.0, 5))
	fire.revision = 2
	clock[0] = 25.0
	view.sync()
	eq(fire.calls, 2, "7. a new revision takes the feed again")
	eq(int(fx.stats()["fire_trees"]), 3, "7. the layer has all three")
	eq(int(map.sets[map.sets.size() - 1]), 3, "7. and the map is told of three trunks")
	fx.queue_free()

# --- 8. the sandbox ---------------------------------------------------------------------------------------------------------

func _wait_playable(sb: Node, frames: int) -> bool:
	var n := 0
	while not bool(sb.get("is_playable")) and n < frames:
		await get_tree().process_frame
		n += 1
	return bool(sb.get("is_playable"))

func _check_sandbox(main: Node) -> void:
	var saved_scenario: int = DebugSettings.get_choice("scenario")
	var saved_fire: int = DebugSettings.get_choice("fire")
	main.get_window().size = Vector2i(1280, 720)
	# the fire OFF first: nothing is made
	DebugSettings.set_choice("scenario", 3)   # suppress
	DebugSettings.set_choice("fire", 2)       # off
	main.setup_menu()
	if not check(main.start_sandbox(), "8. Suppress with the fire off starts"):
		DebugSettings.set_choice("scenario", saved_scenario)
		DebugSettings.set_choice("fire", saved_fire)
		return
	var sb: Node = main.sandbox
	check(await _wait_playable(sb, 900), "8. the sandbox is playable")
	check(sb.world.get("fire") == null, "8. no fire in the World with the knob off")
	await get_tree().process_frame
	check(sb.get("fire_view") == null, "8. and the sandbox made no fire view")
	eq(int(sb.ui.fx.stats()["fire_trees"]), 0, "8. the layer holds nothing")
	eq(int(sb.map_view.provider.burnt_count()), 0, "8. and the map no burnt tree")
	main.stop_sandbox()
	await get_tree().process_frame
	# the fire ON
	DebugSettings.set_choice("fire", 1)
	main.setup_menu()
	if not check(main.start_sandbox(), "8. Suppress with the fire on starts"):
		DebugSettings.set_choice("scenario", saved_scenario)
		DebugSettings.set_choice("fire", saved_fire)
		return
	sb = main.sandbox
	check(await _wait_playable(sb, 900), "8. the sandbox is playable (fire on)")
	var fire: Object = sb.world.get("fire")
	if check(fire != null, "8. the World has a fire with the knob on"):
		var out_rec := {"id": "t1", "x_m": 2400.0, "y_m": 2400.0, "r_m": 9.0, "kx": 0, "ky": 0, "lit_turn": -1, "lit_t": 1.0, "out_turn": 0, "cause": "bomb", "from": ""}
		var burning_rec := {"id": "t2", "x_m": 2440.0, "y_m": 2400.0, "r_m": 7.0, "kx": 0, "ky": 0, "lit_turn": 1, "lit_t": 0.5, "out_turn": 3, "cause": "bomb", "from": ""}
		fire.apply_net_state({"trees": [out_rec, burning_rec]})
		await get_tree().process_frame
		await get_tree().process_frame
		check(sb.get("fire_view") != null, "8. the sandbox made the fire view on first need")
		eq(sb.ui.fx.wind, sb.world.get("wind"), "8. the effects layer has the World's wind (none while the World has none)")
		eq(int(sb.ui.fx.stats()["fire_trees"]), 2, "8. the layer holds the World's feed")
		eq(int(sb.map_view.provider.burnt_count()), 1, "8. the map holds the one tree that is out at the game time on show (turn 1, planning)")
		eq(sb.ui.fx.fire.columns_at(sb.ui.game_time()), 0, "8. nothing smokes yet: the burning tree is lit later in turn 1 and the other is out")
		# a client-side feed that grows: the new tree is taken at once
		var more := burning_rec.duplicate()
		more["id"] = "t3"
		more["x_m"] = 2480.0
		fire.apply_net_state({"trees": [out_rec, burning_rec, more]})
		await get_tree().process_frame
		eq(int(sb.ui.fx.stats()["fire_trees"]), 3, "8. a new revision of the fire reaches the layer")
	main.stop_sandbox()
	await get_tree().process_frame
	DebugSettings.set_choice("scenario", saved_scenario)
	DebugSettings.set_choice("fire", saved_fire)

# --- 9. the wind ---------------------------------------------------------------------------------------------------------------

# The centre of mass of a column's puffs relative to its tree: positions weighted by what the eye sees (alpha x area).
func _mass_centre(puffs: Array, tree: Vector2) -> Vector2:
	var sum := Vector2.ZERO
	var w := 0.0
	for p: Dictionary in puffs:
		var wt: float = float(p["alpha"]) * float(p["r_m"]) * float(p["r_m"])
		sum += ((p["pos"] as Vector2) - tree) * wt
		w += wt
	return sum / maxf(w, 1e-9)

func _strip_wind(puffs: Array) -> String:
	var copy: Array = []
	for p: Dictionary in puffs:
		var q := p.duplicate()
		q.erase("wind")
		copy.append(q)
	return JSON.stringify(copy)

func _check_wind(main: Node, data: FxData) -> bool:
	var tree := Vector2(100.0, 200.0)
	var feed := [_tree("a", tree.x, tree.y, 2, 1.5, 4)]
	var t := 12.0
	# a burning column in a calm, in the data's own wind (no Wind), and in a Wind
	var fire := FxFire.new(data)
	fire.set_feed(feed)
	check(fire.wind == null, "9. no wind unless one is set")
	var plain := fire.puffs_at(t)
	var plain_json := JSON.stringify(plain)
	check(fire.zone_age_s() > 0.5 and fire.zone_age_s() < FxData.f(fire.cfg, "life_s"), "9. the column's visual mass sits at an age inside a puff's life (%.2f s)" % fire.zone_age_s())
	var calm_wind := FakeWind.new(Vector2.ZERO)
	fire.set_wind(calm_wind)
	var calm_puffs := fire.puffs_at(t)
	var calm := _mass_centre(calm_puffs, tree)
	# the drift_s the sim reads: fix one (the data's is read at start; this makes the test independent of the number)
	fire.set_drift_s(3.0)
	check(fire.drift_gain() > 0.25 and fire.drift_gain() < 4.0, "9. the gain on the wind that follows from drift_s is sane (%.2f)" % fire.drift_gain())
	for v: Vector2 in [Vector2(4.0, 0.0), Vector2(-4.0, 0.0), Vector2(0.0, 4.0), Vector2(2.5, -2.5), Vector2(1.0, 0.0)]:
		fire.set_wind(FakeWind.new(v))
		var wp := fire.puffs_at(t)
		eq(wp.size(), calm_puffs.size(), "9. the same puffs in a wind and in a calm")
		var dir := v.normalized()
		var reach := 0.0
		var across := 0.0
		for k in mini(wp.size(), calm_puffs.size()):
			var d := (wp[k]["pos"] as Vector2) - (calm_puffs[k]["pos"] as Vector2)
			across = maxf(across, absf(d.cross(dir)))
			if float(wp[k]["alpha"]) >= FxFire.THICK_ALPHA:
				reach = maxf(reach, d.dot(dir))
		var far := 3.0 * v.length()
		check(reach <= far + 0.05 and reach >= far * 0.6, "9. wind %s: the farthest puff that still reads as smoke is %.1f m downwind, drift_s (3 s) of wind = %.1f m: it fills the zone and no more" % [v, reach, far])
		check(across < 0.02, "9. and it drifts straight along the wind (%.3f m across)" % across)
		var c := _mass_centre(wp, tree) - calm
		if v.length() >= 2.0:
			check(c.dot(dir) > 0.0, "9. the column's mass is DOWNWIND of its tree (%s)" % v)
	# the column leans further in a stronger wind and trails the other way in the opposite one
	fire.set_wind(FakeWind.new(Vector2(2.0, 0.0)))
	var weak := _mass_centre(fire.puffs_at(t), tree).x
	fire.set_wind(FakeWind.new(Vector2(5.0, 0.0)))
	var strong := _mass_centre(fire.puffs_at(t), tree).x
	check(strong > weak + 2.0, "9. a stronger breeze leans the column further (%.1f m against %.1f m)" % [strong, weak])
	# near calm (dawn): the column stands on its tree
	fire.set_wind(FakeWind.new(Vector2(0.2, 0.1)))
	check(_mass_centre(fire.puffs_at(t), tree).length() < 2.5, "9. in a near calm the smoke stays over its tree")
	# a puff takes the air as it blew when it was BORN: the same column in a steady wind and in one that grows with game time differs, puff
	# by puff, by exactly the extra the air had gained at that puff's birth, over its age (the spread and the rest are the same hashes)
	var gain: float = fire.drift_gain()
	fire.set_wind(FakeWind.new(Vector2(3.0, 0.0)))
	var steady := fire.puffs_at(t)
	fire.set_wind(FakeWind.new(Vector2(3.0, 0.0), Vector2(0.4, 0.0)))
	var growing := fire.puffs_at(t)
	var life: float = FxData.f(fire.cfg, "life_s")
	eq(growing.size(), steady.size(), "9. the same puffs in either wind")
	var worst := 0.0
	var wrong_way := 0.0
	for k in mini(growing.size(), steady.size()):
		var age: float = float(steady[k]["u"]) * life
		var born := t - age
		var extra := ((growing[k]["pos"] as Vector2) - (steady[k]["pos"] as Vector2))
		worst = maxf(worst, absf(extra.x - gain * 0.4 * born * age))
		wrong_way = maxf(wrong_way, absf(extra.y))
	check(worst < 0.4, "9. each puff took the air of its BIRTH time, not of now (worst error %.2f m)" % worst)
	check(wrong_way < 1e-3, "9. and only along the wind (%.4f m across)" % wrong_way)
	var puffs := growing
	# thick smoke keeps its shadow (the shadows are drawn from these same puffs): still tone 2 shadow casters, now drifted
	var casters := 0
	for p: Dictionary in puffs:
		if FxPuff.casts_shadow(fire.option, int(p["tone"])) and float(p["alpha"]) >= 0.25:
			casters += 1
	check(casters > 0, "9. thick smoke still casts a shadow, on the drifted puffs (%d)" % casters)
	# a Wind changed in place is noticed: the column follows
	var live := FakeWind.new(Vector2(4.0, 0.0))
	fire.set_wind(live)
	var east := _mass_centre(fire.puffs_at(t), tree).x
	live.v = Vector2(-4.0, 0.0)
	var west := _mass_centre(fire.puffs_at(t), tree).x
	check(east > 3.0 and west < -3.0, "9. a wind changed in place turns the column (%.1f -> %.1f m)" % [east, west])
	# the wind is sampled on a grid and cached, not asked for every puff of every frame
	var counted := FakeWind.new(Vector2(3.0, 1.0))
	fire.set_wind(counted)
	fire.puffs_at(t)
	var first_calls := counted.calls
	fire.puffs_at(t + 0.05)
	check(counted.calls - first_calls < 20, "9. the wind is cached on a grid (%d calls for a frame's puffs)" % (counted.calls - first_calls))
	# no wind again: exactly what it was (and a fresh run agrees)
	fire.set_wind(null)
	eq(JSON.stringify(fire.puffs_at(t)), plain_json, "9. wind removed: the very same puffs as before any wind was set")
	var fresh := FxFire.new(data)
	fresh.set_feed(feed)
	eq(JSON.stringify(fresh.puffs_at(t)), plain_json, "9. and as a fresh run with none")
	# the drift_s the data holds is what is read (the sim adds smoke.drift_s to data/sim/fire.json; until then none)
	var fd := FxFire.read_drift_s()
	eq(FxFire.new(data).drift_s(), fd, "9. the drift_s used is the one data/sim/fire.json holds (%.2f; -1 while the sim has none)" % fd)
	eq(FxFire.read_drift_s("res://data/no/such/file.json"), -1.0, "9. no file, no drift_s")

	# --- the effects field: a damaged plane's trail and a crash's smoke ---
	var field := FxField.new(data)
	var plain_field := FxField.new(data)
	plain_field.emit_damage_smoke("p1", Vector2(500.0, 500.0), 120.0, 0.4, 10.0, 9.0, 0.0)
	plain_field.emit_damage_smoke("p1", Vector2(560.0, 500.0), 120.0, 0.4, 14.0, 9.0, 0.0)
	var j: float = FxData.f(plain_field.smoke_o, "wind_jitter_mps")
	var dw := FxData.arr(plain_field.smoke_o, "wind_mps")
	check(plain_field.puffs.size() > 3, "9. a damaged plane leaves a trail (%d puffs)" % plain_field.puffs.size())
	for p: Dictionary in plain_field.puffs:
		var d: Vector2 = (p["wind"] as Vector2) - Vector2(float(dw[0]), float(dw[1]))
		check(absf(d.x) <= j + 1e-6 and absf(d.y) <= j + 1e-6, "9. with no wind a puff drifts on the option's own data wind, as before")
	var ramp_air := FakeWind.new(Vector2(1.0, -1.0), Vector2(0.2, 0.0))
	field.wind = ramp_air
	field.emit_damage_smoke("p1", Vector2(500.0, 500.0), 120.0, 0.4, 10.0, 9.0, 0.0)
	field.emit_damage_smoke("p1", Vector2(560.0, 500.0), 120.0, 0.4, 14.0, 9.0, 0.0)
	eq(field.puffs.size(), plain_field.puffs.size(), "9. the same trail, wind or not")
	var off := 0
	for p: Dictionary in field.puffs:
		var air: Vector2 = ramp_air.at(float(p["born"]))
		var d2: Vector2 = (p["wind"] as Vector2) - air
		if absf(d2.x) > j + 1e-6 or absf(d2.y) > j + 1e-6:
			off += 1
	eq(off, 0, "9. with a wind every puff of a plane's trail drifts with the air as it blew at its birth (plus the option's spread)")
	var pf: Dictionary = field.puffs[0]
	var drifted := (field.puff_state(pf, float(pf["born"]) + 4.0)["pos"] as Vector2) - (pf["pos"] as Vector2)
	check((drifted - (pf["wind"] as Vector2) * 4.0).length() < 1e-3, "9. and is drawn where that drift puts it")
	eq(_strip_wind(field.puffs), _strip_wind(plain_field.puffs), "9. nothing else about a puff changes with the wind: the random numbers drawn are the same")
	# a crash: burst, plume and wreck column
	var cf := FxField.new(data)
	cf.wind = FakeWind.new(Vector2(-2.0, 1.5), Vector2(0.05, 0.0))
	cf.impact("u1", Vector2(800.0, 800.0), 20.0, 9.0, 0.0)
	var kinds := {}
	var bad := 0
	for p: Dictionary in cf.puffs:
		var kind := str(p["kind"])
		kinds[kind] = int(kinds.get(kind, 0)) + 1
		var po: Dictionary = cf.set_defs.get(p["set"], cf.smoke_o)
		var jj: float = FxData.f(po, "wind_jitter_mps")
		var dd: Vector2 = (p["wind"] as Vector2) - (cf.wind as FakeWind).at(float(p["born"]))
		if absf(dd.x) > jj + 1e-6 or absf(dd.y) > jj + 1e-6:
			bad += 1
	check(kinds.has("burst") and kinds.has("plume") and kinds.has("smolder"), "9. a crash makes a burst, a plume and a wreck column (%s)" % str(kinds))
	eq(bad, 0, "9. and all of its smoke drifts with the wind at each puff's birth")
	# the layer hands the wind to both
	var layer := FxLayer.new()
	main.add_child(layer)
	layer.setup(Transform2D.IDENTITY, SEED)
	check(layer.wind == null and layer.field.wind == null and layer.fire.wind == null, "9. a layer has no wind unless it is given one")
	var air := FakeWind.new(Vector2(2.0, 2.0))
	layer.set_wind(air)
	check(layer.wind == air and layer.field.wind == air and layer.fire.wind == air, "9. set_wind reaches the effects field and the fire's smoke")
	layer.set_wind(null)
	check(layer.wind == null and layer.field.wind == null and layer.fire.wind == null, "9. set_wind(null) is today's behaviour again")
	layer.queue_free()
	return true

# The sim's own Wind (scripts/sim/wind.gd, from its params as a client builds it) through the same drawing: the day's sea breeze, the night's land breeze
# and the dawn calm lean the smoke the way each blows, by the amounts the regimes give.
func _check_real_wind(data: FxData) -> bool:
	var tree := Vector2(100.0, 200.0)
	var feed := [_tree("a", tree.x, tree.y, 2, 1.5, 4)]
	var t := 12.0
	var leans := {}
	for pair: Array in [["day", 14.0], ["night", 1.5], ["dawn", 7.5]]:
		var w: Object = WindScript.from_params({"hour": pair[1], "toward_sea": [-0.93, 0.37], "seed": SEED, "v": 1}, WindScript.PATH, true)
		if not check(w != null and bool(w.call("ok")), "9. the sim's %s wind builds from its params" % pair[0]):
			return false
		var fire := FxFire.new(data)
		fire.set_feed(feed)
		fire.set_wind(w)
		var plain := FxFire.new(data)
		plain.set_feed(feed)
		plain.set_wind(FakeWind.new(Vector2.ZERO))   # (the same column in dead air: only the wind differs)
		var c := _mass_centre(fire.puffs_at(t), tree) - _mass_centre(plain.puffs_at(t), tree)
		leans[pair[0]] = c
		var mean: Vector2 = w.call("mean")
		if mean.length() > 1.0:
			check(c.dot(mean.normalized()) > 0.0, "9. the %s wind (mean %s): the smoke leans the way the regime blows (%s)" % [pair[0], mean.round(), c.round()])
		var field := FxField.new(data)
		field.wind = w
		field.emit_damage_smoke("p1", Vector2(500.0, 500.0), 120.0, 0.4, 10.0, 9.0, 0.0)
		var j: float = FxData.f(field.smoke_o, "wind_jitter_mps")
		var off := 0
		for p: Dictionary in field.puffs:
			var dd: Vector2 = (p["wind"] as Vector2) - (w.call("at", float(p["born"])) as Vector2)
			if absf(dd.x) > j + 1e-6 or absf(dd.y) > j + 1e-6:
				off += 1
		check(not field.puffs.is_empty() and off == 0, "9. the %s wind: a damaged plane's trail drifts with the sim's Wind at each puff's birth" % pair[0])
	check((leans["day"] as Vector2).length() > (leans["dawn"] as Vector2).length() * 2.0, "9. a day's sea breeze leans the smoke much further than a dawn calm (%.1f m against %.1f m)" % [(leans["day"] as Vector2).length(), (leans["dawn"] as Vector2).length()])
	check((leans["day"] as Vector2).dot((leans["night"] as Vector2)) < 0.0, "9. and the night's land breeze leans it the other way")
	return true
