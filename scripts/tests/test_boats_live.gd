extends "res://scripts/test_support/test_case.gd"

# THE BOATS AND THE BRIDGE IN THE GAME (Track BB, 2026-10-11): everything below the picture, headless, on the real Strike with the water
# on (the pixels are a windowed run: scripts/app/boats_live_shot.gd, tmp/boats_live/).
#
#   1. THE CHOICES   the art reads Alex's decisions from the data: the patrol boat is P1, the supply boat S2 (boat-looks), the wake the ink V
#                    (boat-wake), the bridge the stone arch with a flat deck (bridge-look), the river 26 m at the road (water-layer), computed
#                    from the water's own data; and no hex in the new code
#   2. THE DISPATCH  unit_marker_art.gd's one line reaches unit_marker_art_boats.gd for the three silhouettes (and for nothing else), the
#                    boats are drawn at the planes' scale and the bridge at the MAP's; a destroyed bridge has a ruin art, a boat has none (it
#                    sinks: the wreck of the first proposal is gone, with its data keys)
#   3. THE MARKERS   on the Strike with water, a marker for the patrol boat, the supply boat and the bridge; the bridge's is drawn at the
#                    map's scale at every zoom (its drawn scale times the planes' rule is 1), the boats' is not; the drawing order is boats,
#                    then the bridge, then everything else; a boat's wake shows only while it is under way; a boat's shadow is its hull
#                    plus a stepped copy of each taller part, lifted by its height (a marker given an art that has them), and goes with it
#   4. THE RUIN      a destroyed bridge goes through the effects layer as the tower does: the ruin() call at the event (a blast sized by the
#                    data's share of its size_m), add_ruin() for the bare ruin, and a LATE JOINER's ruin comes back from the world
#                    (restore_wrecks); the standing marker is gone with its fate
#   5. THE SINKING   (Alex, decision ship-sinks) a destroyed boat stays on the map BELOW the water: drawn intact under the water layer's own
#                    depth wash for the metres above it (none at the surface, the map's step colour by the metres, deeper washes more), with
#                    no shadow and no wake once it is under; it gets the standard down flash and no ruin, no smoke, no scar; the splash event
#                    puts rings on the water; a crash on the floor draws nothing on the ground; a late joiner finds the bridge's ruin and the
#                    boats lying where they went down
#
# Headless draws nothing, so the arts themselves are null here; what is proved is everything the arts rest on.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarker = preload("res://scripts/ui/unit_marker.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const BridgeArt = preload("res://scripts/render/bridge_art.gd")
const UnitSunk = preload("res://scripts/ui/unit_sunk.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")
const WaterPlaceholder = preload("res://scripts/render/water_placeholder.gd")

const BOATS_ART := "res://scripts/ui/unit_marker_art_boats.gd"
const PATROL := "patrol_boat_1"
const SUPPLY := "supply_boat_1"
const BRIDGE := "bridge_1"

var _boats: GDScript = null
var _st: UiStyle = null
var _ran := 0

func setup(_main) -> void:
	timeout_seconds = 180.0
	_st = UiStyle.shared() as UiStyle
	_boats = load(BOATS_ART)
	if not check(_boats != null and _boats.can_instantiate(), "unit_marker_art_boats.gd compiles -- see the Parse Error in the .err.log"):
		finish()
		return
	_choices()
	_dispatch()
	var w := _strike()
	if check(w != null, "the Strike with water builds"):
		_markers(w)
		_ruin(w)
		_sinking(w)
	eq(_ran, 5, "all five parts ran to their end")
	finish()

func _json(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _decision(id: String) -> Dictionary:
	for r: Dictionary in (_json("res://data/decisions/decisions.json") as Dictionary)["decisions"]:
		if str(r["id"]) == id:
			return r
	return {}

# --- 1. the choices ------------------------------------------------------------------------------------------------

func _choices() -> void:
	var looks: Dictionary = _decision("boat-looks").get("parameters", {})
	eq(_boats.look_of("patrol"), str(looks.get("patrol", "?")), "1. the patrol boat's look is Alex's (boat-looks: %s)" % [str(looks)])
	eq(_boats.look_of("supply"), str(looks.get("supply", "?")), "1. the supply boat's look is Alex's")
	eq(str(_boats.val(BoatArt.data()["game"]["wake"])), str((_decision("boat-wake").get("parameters", {}) as Dictionary).get("wake", "?")), "1. the wake is Alex's (boat-wake)")
	var bl: Dictionary = _decision("bridge-look").get("parameters", {})
	eq(str(_boats.val(BridgeArt.data()["game"]["kind"])), str(bl.get("kind", "?")), "1. the bridge's kind is Alex's (bridge-look)")
	var m: BridgeArt.Model = _boats.bridge_model(_st, false)
	eq(bool(m.p.get("humped_deck", true)), bool(bl.get("humped_deck", true)), "1. the deck is flat as Alex chose (humped_deck %s)" % str(bl.get("humped_deck")))
	var water: Dictionary = _json("res://data/world/water.json")
	var half: float = float(BoatArt.val(water["river"]["shape"]["crossing_half_width_m"]))
	near(_boats.river_width_m(), 2.0 * half, 1e-9, "1. the bridge spans the river the water makes at the road (2 x crossing_half_width_m %.1f)" % half)
	near(float(m.p.river_w), _boats.river_width_m(), 1e-9, "1. and the model is built over it")
	var hex := RegEx.create_from_string("#[0-9A-Fa-f]{6}\\b|Color\\.html|Color\\(\\s*\"|Color8\\(|Color\\(0x")
	for f: String in [BOATS_ART, "res://scripts/ui/unit_sunk.gd"]:
		var text := FileAccess.get_file_as_string(f)
		check(text != "" and hex.search(text) == null, "1. %s has no hex literal and no colour made from a literal" % f)
	_ran += 1

# --- 2. the dispatch ----------------------------------------------------------------------------------------------------

func _dispatch() -> void:
	check(_boats.has_ruin("bridge"), "2. the bridge has a destroyed art")
	for s: String in ["patrol_boat", "supply_boat"]:
		check(not _boats.has_ruin(s), "2. %s has none: a boat that is destroyed sinks" % s)
	check(not (BoatArt.data()["game"] as Dictionary).has("wreck"), "2. and the data has no wreck left in it (the first proposal's keys are gone)")
	for s: String in ["patrol_boat", "supply_boat", "bridge"]:
		check(UnitMarkerArt.art_for(_st, s, Color.WHITE, 4.0, 0.0) == null, "2. headless: the art of %s resolves through the dispatch to nothing to bake, not to an error" % s)
	for s: String in ["radio_tower", "small_cruiser", "light_fighter", "tank", "military_complex"]:
		check(not _boats.has_ruin(s), "2. %s is not one of the boats' kinds" % s)
	check(UnitMarkerArt.is_map_scale("bridge"), "2. the bridge is drawn at the map's scale")
	for s: String in ["patrol_boat", "supply_boat", "radio_tower", "small_cruiser", "tank"]:
		check(not UnitMarkerArt.is_map_scale(s), "2. %s is drawn at the units' scale" % s)
	check(_boats.is_map_scale("bridge") and not _boats.is_map_scale("patrol_boat"), "2. the boats file says the same")
	# the ruin's blast: a share of the size, from the data
	near(_boats.effects_frac("bridge"), float(_boats.val(BridgeArt.data()["game"]["effects_size_frac"])), 1e-9, "2. a bridge's blast is the data's share of its size")
	near(_boats.effects_frac("patrol_boat"), float(_boats.val(BoatArt.data()["game"]["sunk"]["effects_size_frac"])), 1e-9, "2. a sinking boat's down flash likewise")
	near(_boats.effects_frac("tank"), 1.0, 1e-9, "2. any other kind keeps its whole size")
	# the models the ruins are made of
	var ruin: BridgeArt.Model = _boats.bridge_model(_st, true)
	var whole: BridgeArt.Model = _boats.bridge_model(_st, false)
	check((ruin.G.rubble as Array).size() > 0 and (whole.G.rubble as Array).size() == 0, "2. the destroyed bridge has stone in the river and the whole one none")
	eq((ruin.G.deck as Array).size(), 2, "2. the destroyed bridge's deck is two stubs, one from each bank")
	for kind: String in ["patrol", "supply"]:
		var bm: BoatArt.Model = BoatArt.model(_st, kind, _boats.look_of(kind))
		check(bm.G.has("house") and (bm.G.hull as PackedVector2Array).size() > 40, "2. the %s has a hull and a house" % kind)
		check(float(bm.p.wake_len) > 0.0, "2. the %s has a wake" % kind)
	_ran += 1

# --- the Strike -------------------------------------------------------------------------------------------------------------

func _strike() -> World:
	var sc := SandboxScenario.new("strike", true, {"water": true})
	if not sc.ok():
		fail("the scenario does not read: %s" % [sc.errors])
		return null
	var w := World.new()
	w.quiet = true
	var ids := sc.populate(w)
	if ids.has(""):
		fail("a unit of the Strike did not load: %s" % w.last_error)
		return null
	return w

# --- 3. the markers --------------------------------------------------------------------------------------------------------------

var _ui: UnitUI = null

func _new_ui(w: World) -> UnitUI:
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, Transform2D(0.0, Vector2(0.5, 0.5), 0.0, Vector2.ZERO), "local")
	return ui

func _markers(w: World) -> void:
	_ui = _new_ui(w)
	var layer = _ui.marker_layer
	for id: String in [PATROL, SUPPLY, BRIDGE]:
		check(layer.marker(id) != null, "3. %s has a marker" % id)
	var mb: UnitMarker = layer.marker(BRIDGE)
	var mp: UnitMarker = layer.marker(PATROL)
	var ms: UnitMarker = layer.marker(SUPPLY)
	eq([mp.silhouette, ms.silhouette, mb.silhouette], ["patrol_boat", "supply_boat", "bridge"], "3. the silhouettes the arts are looked up by")
	eq([mb.map_scale, mp.map_scale, ms.map_scale], [true, false, false], "3. only the bridge is drawn at the map's scale")
	# the map scale holds at every zoom: the planes' rule k changes with the zoom (2 at zoom 1, 2.22 at the planning zoom), the bridge's drawn scale does not
	var saved: float = _st.num("marker.true_scale")
	for k: float in [2.0, 2.2222, 1.0, 3.0]:
		_st.set_num("marker.true_scale", k)
		layer.update_poses()
		near(mb.draw_scale * k, 1.0, 1e-6, "3. true_scale %.4f: the bridge's drawn scale is the map's (draw_scale x true_scale = 1)" % k)
		near(mp.draw_scale, 1.0, 1e-9, "3. ...and the patrol boat keeps the planes' rule")
	_st.set_num("marker.true_scale", saved)
	layer.update_poses()
	# the drawing order: boats, then the bridge, then the rest (a boat sails under the bridge, a tank drives over it)
	var planes: Node = layer.get_node("Planes")
	var order: Array = []
	for c: Node in planes.get_children():
		order.append((c as UnitMarker).unit_id)
	var rank := func(id: String) -> int:
		var u: Unit = w.units[id]
		return 0 if str(u.def.domain) == "sea" else (1 if id == BRIDGE else 2)
	var last := -1
	var sorted := true
	for id: Variant in order:
		var r: int = rank.call(str(id))
		if r < last:
			sorted = false
		last = r
	check(sorted, "3. the markers are drawn boats, then the bridge, then the rest: %s" % [order])
	# a wake only while under way (ui.json unit_art.ship.underway_mps)
	var limit: float = _st.num("unit_art.ship.underway_mps")
	w.units[PATROL].speed = limit + 5.0
	layer.update_poses()
	eq(mp.underway, true, "3. the patrol boat making way is under way")
	w.units[PATROL].speed = 0.0
	layer.update_poses()
	eq(mp.underway, false, "3. at anchor it is not")
	eq(mb.underway, false, "3. a bridge never is")
	# a boat's art with the wake and the shadow's parts: the marker shows the wake only under way, and draws a copy of each taller part
	var img := Image.create(24, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var art := UnitMarkerArt.Art.new()
	art.texture = tex
	art.mask = tex
	art.wake = tex
	art.origin = Vector2(12.0, 20.0)
	art.ppm = 4.0
	art.extent_m = 6.0
	art.cast_height_m = 3.0
	art.shadow_parts = [{"tex": tex, "heights": [3.0, 4.5, 6.0]}, {"tex": tex, "heights": [9.0]}]
	mp.art = art
	mp.underway = true
	mp.set_pose(Vector2(100.0, 100.0), 0.0, 4.0, Vector2(6.0, 6.0))
	check(mp.wake != null and mp.wake.visible, "3. under way: the wake is shown")
	mp.underway = false
	mp.set_pose(Vector2(100.0, 100.0), 0.0, 4.0, Vector2(6.0, 6.0))
	check(mp.wake != null and not mp.wake.visible, "3. at anchor: the wake is hidden")
	eq(mp._part_sprites.size(), 4, "3. a shadow copy for every height of every taller part (3 + 1)")
	var want := [3.0, 4.5, 6.0, 9.0]
	for i in 4:
		var spr: Sprite2D = mp._part_sprites[i]
		check(spr.visible, "3. copy %d is shown" % i)
		check(spr.position.is_equal_approx(Vector2(100.0, 100.0) + Vector2(6.0, 6.0) * (float(want[i]) / 3.0)), "3. copy %d is lifted by its own height (%.1f m: %s)" % [i, float(want[i]), str(spr.position)])
	check(mp.shadow.position.is_equal_approx(Vector2(106.0, 106.0)), "3. the marker's own shadow is the hull's, lifted by cast_height_m")
	mp.visible = false
	mp.refresh_shapes()
	var any_shown := false
	for s: Variant in mp._part_sprites:
		any_shown = any_shown or (s as Sprite2D).visible
	check(not any_shown, "3. a marker the layer hides takes its shadow copies with it")
	mp.visible = true
	mp.art = null
	mp.set_pose(Vector2(100.0, 100.0), 0.0, 4.0, Vector2(6.0, 6.0))
	any_shown = false
	for s: Variant in mp._part_sprites:
		any_shown = any_shown or (s as Sprite2D).visible
	check(not any_shown, "3. a marker with no art has no copies")
	_ran += 1

# --- 4. the ruin -------------------------------------------------------------------------------------------------------------------

func _ruin(w: World) -> void:
	var fx = _ui.fx
	# the ruin call at the event, as combat_feed makes it: the blast is the data's share of the unit's size, the ruin stays
	var b: Unit = w.units[BRIDGE]
	var pos := Vector2(float(b.x), float(b.y))
	var before: int = fx.field.ruins.size()
	fx.ruin(BRIDGE, pos, 10.0, "bridge", float(b.def.size_m), float(b.heading))
	eq(fx.field.ruins.size(), before + 1, "4. the bridge's ruin is on the ground")
	var rec: Dictionary = fx.field.ruins[fx.field.ruins.size() - 1]
	eq([str(rec["kind"]), rec["pos"], float(rec["heading"])], ["bridge", pos, float(b.heading)], "4. of kind bridge, where it stood, along its road")
	var blast_m := -1.0
	for burst: Dictionary in fx.field.bursts:
		if str(burst.get("unit", "")) == BRIDGE and str(burst.get("grp", "")) == "ruin":
			blast_m = float(burst["size_m"])
	near(blast_m, float(b.def.size_m) * _boats.effects_frac("bridge"), 1e-6, "4. its blast is the data's share of its size_m (%.1f m)" % blast_m)
	# the bare ruin, for a client out of sight
	fx.add_ruin("elsewhere", Vector2(10.0, 10.0), 3.0, "bridge", 27.0, 0.5, 12345)
	eq(str(fx.field.ruins[fx.field.ruins.size() - 1]["kind"]), "bridge", "4. add_ruin() puts a bridge's ruin down without the blast")
	# the world's ruin: a destroyed bridge is gone from the map, and a LATE JOINER finds its ruin again
	for id: String in [BRIDGE]:
		var u: Unit = w.units[id]
		u.health = 0
		u.down = true
		u.fate = Unit.FATE_DESTROYED
		u.down_at = NAN
	_ui.marker_layer.update_poses()
	check(not _ui.marker_layer.marker(BRIDGE).visible, "4. the bridge's marker is gone with its fate")
	check(_ui.marker_layer.marker(PATROL).visible and _ui.marker_layer.marker(SUPPLY).visible, "4. the boats afloat are still there")
	var late := _new_ui(w)   # a client that joined after it fell
	var kinds: Dictionary = {}
	for r: Dictionary in late.fx.field.ruins:
		kinds[str(r["unit"])] = str(r["kind"])
	eq(kinds, {BRIDGE: "bridge"}, "4. a late joiner's effects layer has the bridge's ruin")
	for r: Dictionary in late.fx.field.ruins:
		var u: Unit = w.units[str(r["unit"])]
		check(r["pos"] == Vector2(float(u.x), float(u.y)) and absf(float(r["heading"]) - float(u.heading)) < 1e-9, "4. %s's ruin is where it fell and as it lay" % str(r["unit"]))
	check(late.restore_wrecks(true) >= 1, "4. and the layer can be rebuilt from the world again (restore_wrecks with clear)")
	_ran += 1

# --- 5. the sinking -------------------------------------------------------------------------------------------------------------------

func _fake_art() -> UnitMarkerArt.Art:
	var img := Image.create(24, 40, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 1.0, 1.0))
	var tex := ImageTexture.create_from_image(img)
	var art := UnitMarkerArt.Art.new()
	art.texture = tex
	art.mask = tex
	art.wake = tex
	art.origin = Vector2(12.0, 20.0)
	art.ppm = 4.0
	art.extent_m = 6.0
	art.cast_height_m = 3.0
	art.shadow_parts = [{"tex": tex, "heights": [3.0, 4.5]}]
	return art

func _sink(u: Unit, fate: String, height: float) -> void:
	u.health = 0
	u.down = true
	u.fate = fate
	u.fall_height_m = height
	u.down_at = NAN

func _sinking(w: World) -> void:
	var layer = _ui.marker_layer
	var mp: UnitMarker = layer.marker(PATROL)
	var up: Unit = w.units[PATROL]
	var depth: float = w.water_depth_at(float(up.x), float(up.y))
	check(depth > 1.0, "5. the patrol boat floats over water (%.1f m)" % depth)
	# the wash itself: none at the surface, deeper washes more, to the water layer's own colours (the map bake's steps, no new tint)
	near(UnitSunk.amount(0.0), 0.0, 1e-12, "5. no wash at the surface")
	check(UnitSunk.amount(3.0) < UnitSunk.amount(10.0) and UnitSunk.amount(10.0) < UnitSunk.amount(30.0), "5. the wash grows with the metres above")
	check(UnitSunk.amount(30.0) > 0.9 and UnitSunk.amount(3.0) < 0.5, "5. deep water all but hides a hull on the floor and the shallows do not (30 m: %.2f, 3 m: %.2f)" % [UnitSunk.amount(30.0), UnitSunk.amount(3.0)])
	var steps: Array = WaterPlaceholder.wb_steps(_st)
	eq(steps.size(), 3, "5. the water layer's steps are three: shallows, shelf, deep")
	var cols: Array = [UnitSunk.step_color(w, _st, 3.0), UnitSunk.step_color(w, _st, 10.0), UnitSunk.step_color(w, _st, 30.0)]
	for k in 3:
		check((cols[k] as Color).is_equal_approx(steps[k]), "5. the wash at step %d is the map bake's colour" % k)
	# a boat afloat: no wash
	layer.update_poses()
	near(mp.sunk_amount, 0.0, 1e-12, "5. afloat: no wash")
	mp.art = _fake_art()
	var limit: float = _st.num("unit_art.ship.underway_mps")
	up.speed = limit + 5.0
	layer.update_poses()
	check(mp.wake.visible and mp.shadow.visible, "5. afloat and under way: the wake and the shadow are shown")
	# half sunk
	_sink(up, Unit.FATE_OUT_OF_CONTROL, -0.5 * depth)
	layer.update_poses()
	check(mp.visible, "5. a sinking boat is on the map")
	near(mp.sunk_amount, UnitSunk.amount(0.5 * depth), 1e-9, "5. half sunk: the wash for half its depth of water")
	check(mp.sunk_color.is_equal_approx(UnitSunk.step_color(w, _st, depth)), "5. in the colour of the step the floor is in")
	check(not mp.wake.visible and not mp.shadow.visible, "5. below the surface it has no wake (it is still moving) and no shadow")
	var any_part := false
	for sp: Variant in mp._part_sprites:
		any_part = any_part or (sp as Sprite2D).visible
	check(not any_part, "5. and none of the stepped shadow copies of its tall parts")
	check(mp.plane.material != null, "5. its sprite wears the wash")
	near(layer.unit_height_m(PATROL), -0.5 * depth, 1e-9, "5. the height label reads the depth it is at")
	# on the floor
	_sink(up, Unit.FATE_CRASHED, -depth)
	layer.update_poses()
	check(mp.visible, "5. on the floor it stays on the map")
	near(mp.sunk_amount, UnitSunk.amount(depth), 1e-9, "5. the full wash for its depth of water")
	check(UiFate.under_water(up) and UiFate.alive_until(up) == INF, "5. UiFate: under the water, and there for good")
	# the supply boat likewise, in its own water
	var us: Unit = w.units[SUPPLY]
	var ds: float = w.water_depth_at(float(us.x), float(us.y))
	_sink(us, Unit.FATE_CRASHED, -ds)
	layer.update_poses()
	near(layer.marker(SUPPLY).sunk_amount, UnitSunk.amount(ds), 1e-9, "5. the supply boat likewise (%.1f m)" % ds)
	# the effects: the standard flash, rings on the water, nothing on the ground
	_sink(up, Unit.FATE_OUT_OF_CONTROL, 0.0)
	_sink(us, Unit.FATE_OUT_OF_CONTROL, 0.0)
	var fx = _ui.fx
	var feed = _ui.feed
	var ruins0: int = fx.field.ruins.size()
	var counts0: Dictionary = fx.field.counts()
	var bursts0: int = fx.field.bursts.size()
	var pos := Vector2(float(up.x), float(up.y))
	feed.on_event({"type": "down", "unit": PATROL, "fate": Unit.FATE_OUT_OF_CONTROL, "t": 1.0, "turn": 1, "x": pos.x, "y": pos.y})
	eq(fx.field.bursts.size(), bursts0 + 1, "5. the down event gives the one standard flash")
	var flash: Dictionary = fx.field.bursts[fx.field.bursts.size() - 1]
	eq([str(flash["unit"]), str(flash["grp"])], [PATROL, "ruin"], "5. the ruin's flash group, for the boat")
	near(float(flash["size_m"]), float(up.def.size_m) * _boats.effects_frac("patrol_boat"), 1e-6, "5. sized by the data's share of the boat's size_m")
	eq(fx.field.ruins.size(), ruins0, "5. no ruin on the water")
	check(not bool(feed._falling.get(PATROL, false)), "5. and it does not ride as a falling plane (no smoke trail)")
	var t_game: float = feed.turn_t0(1) + 1.0
	feed.on_event({"type": "splash", "unit": PATROL, "turn": 1, "t": 1.0, "x": pos.x, "y": pos.y})
	eq(fx.field.splashes.size(), 1, "5. the splash event puts rings on the water")
	check(fx.field.splashes[0]["pos"] == pos, "5. where it went under")
	var life: float = fx._splash_life_s()
	check(life > 0.0, "5. the rings last %.1f s" % life)
	eq(fx.field.splashes_live(t_game + 0.5 * life, life), 1, "5. they are drawn while they last")
	eq(fx.field.splashes_live(t_game + life + 1.0, life), 0, "5. and the layer lets go of them after")
	var after_splash: Dictionary = fx.field.counts()
	eq(after_splash["scars"], counts0["scars"], "5. no scar from the down or the splash")
	# the crash on the floor: nothing on the ground
	_sink(up, Unit.FATE_CRASHED, -depth)
	feed.on_event({"type": "crash", "unit": PATROL, "turn": 1, "t": 4.0, "x": pos.x, "y": pos.y})
	var after_crash: Dictionary = fx.field.counts()
	eq(after_crash, after_splash, "5. a crash on the water's floor draws nothing: no impact, no scar, no smoke")
	# a plane that came down over water is under the same wash; over land it is crashed at 0 m as before (nothing below the surface)
	# a late joiner: the bridge's ruin, no wreck of a boat, and both boats lying there
	_sink(us, Unit.FATE_CRASHED, -ds)
	var late := _new_ui(w)
	late.marker_layer.update_poses()
	var kinds: Dictionary = {}
	for r: Dictionary in late.fx.field.ruins:
		kinds[str(r["unit"])] = str(r["kind"])
	eq(kinds, {BRIDGE: "bridge"}, "5. a late joiner finds the bridge's ruin and no boat's")
	for sc: Dictionary in late.fx.field.scars:
		check(str(sc["unit"]) != PATROL and str(sc["unit"]) != SUPPLY, "5. and no scar of a boat on the water")
	check(late.marker_layer.marker(PATROL).visible and late.marker_layer.marker(SUPPLY).visible, "5. the boats lie on the map where they went down")
	near(late.marker_layer.marker(PATROL).sunk_amount, UnitSunk.amount(depth), 1e-9, "5. under the same wash on the late joiner's screen")
	_ran += 1
