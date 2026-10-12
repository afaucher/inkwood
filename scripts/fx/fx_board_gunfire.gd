extends "res://scripts/fx/fx_board_strike.gd"

# THE GUNFIRE BOARD (builder GF, 2026-10-11): variants/gunfire/. WINDOWED ONLY -- under --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/fx/fx_board_gunfire.gd -- [what=board|spec] [out=variants] [options=G0,G1] [only=<row key>] [scene=duel|salvo|strike]
#
# Decisions gunfire-looks and impact-by-round-and-target (both OPEN). Alex, third playtest: "Fired shots should have smoke for large rounds (tanks,
# artillery and ship cannons). Landed shots should have an impact even if they don't destroy you." Then, asked for options: "8 yes, give options". And:
# "this should probably be a property of either the round or the thing being hit or both. Ex a round hitting water would splash, not explode with smoke. Right?"
# A BOARD ONLY: nothing in the live game changes until Alex picks. EVERY FAMILY, SIZE AND NUMBER IS PROPOSED (variants/gunfire/families.json, drawn by
# scripts/fx/fx_gunfire.gd); the muzzle and impact marks are drawn by that file, the rest (tracers T5, flak F2, the bomb B3, the smoke W1, the units, the
# map) by the game's own code.
#
# THE SCENES ARE THE REAL SIM (as the tracers board's). HOLD THE BRIDGE (seed 55, data/scenarios/bridge.json) is played by the real World: a DUEL of tanks
# across the river (two turns) and the cruiser's Main Guns SALVO (three turns: the shells are 10.8 s in the air); THE STRIKE (seed 20261009) is one turn of
# a heavy fighter chasing a bomber over the village battery. Every "fire", "shell_fire" and "shell_impact" event of those turns is turned into muzzle and
# impact records by the adapters below, as the game's CombatFeed would. WHAT THE SIM DOES NOT SAY IS PROPOSED HERE AND MARKED SO: where a MISSED tank round
# lands (a seeded offset from the target, visual only; a real miss point is the line-of-fire proposal), the round's flight time, and the material under a
# landing (looked up from the map: a unit's footprint, the bridge, the water, a tree's canopy, else the ground).

const FxGunfire = preload("res://scripts/fx/fx_gunfire.gd")
const BridgePlay = preload("res://scripts/test_support/bridge_play.gd")
const World = preload("res://scripts/sim/world.gd")
const Wind = preload("res://scripts/sim/wind.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const FxTracer = preload("res://scripts/fx/fx_tracer.gd")
const FxPass = preload("res://scripts/fx/fx_pass.gd")
const FxShadowPass = preload("res://scripts/fx/fx_shadow_pass.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const BR_SEED := 55
const ST_SEED := 20261009
const DUEL_COMBAT_SEED := 242      # two turns that mix hits and misses on a tank and on the bridge (tmp/gunfire/scan_duel.gd)
const SALVO_COMBAT_SEED := 252     # a salvo whose six shells land on five materials: ground x2, stone, water, wood, metal (scan_salvo.gd)
const STRIKE_COMBAT_SEED := 84     # three nose-cannon hits at 1, 3 and 5 s, two misses, ten flak rolls (scan_strike.gd)
const TURN_S := 5.0
const SHELL_FLIGHT_MPS := 700.0    # PROPOSED: a tank round's speed, only for where the impact comes after the muzzle
const FAMILY_ORDER := ["G0", "G1", "G2", "G3", "G4"]
const BR_CROP_P := Vector2i(440, 620)      # portrait: the road runs north-south
const BR_CROP := Vector2i(600, 440)
const BR_WIDE := Vector2i(900, 520)

var cfg: Dictionary = {}
var gbook: FxGunfire.Book = null
var gpainter: FxGunfire.Painter = null
var wind: Object = null
var grig: GfRig = null

# --- Entry ----------------------------------------------------------------------------------------------------------------------

func _run() -> void:
	cfg = FxGunfire.load_cfg()
	if cfg.is_empty():
		quit(1)
		return
	var what := str(opts.get("what", "board"))
	if what == "spec":
		await _spec_only()
		quit(0)
		return
	await _board()
	quit(1 if (grig != null and grig.failures > 0) else 0)

# The light set-up for a run that draws on plain paper: no map, no rig view.
func _light_rig() -> void:
	rig = FxRig.new(self)
	rig.fxs = FxStyle.shared() as FxStyle
	rig.fxd = FxData.shared() as FxData
	rig.ui_style = UiStyle.shared() as UiStyle
	fxs = rig.fxs
	fxd = rig.fxd
	FxGunfire.install_roles(fxs, cfg)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

# --- The rig for the gunfire scenes ---------------------------------------------------------------------------------------------------------

# What the gunfire nodes ask for: draw_pass(item, kind), the shape FxPass and FxShadowPass call.
class GfLayer extends RefCounted:
	var painter: FxGunfire.Painter = null
	var book: FxGunfire.Book = null
	var mapping: RefCounted = null
	var ts: float = 1.0
	var now: float = 0.0
	var view_size := Vector2(1280, 720)
	func draw_pass(item: CanvasItem, kind: String) -> void:
		if painter == null or book == null or mapping == null:
			return
		painter.draw(item, book, mapping, ts, now, Rect2(Vector2.ZERO, view_size), kind)

# The rig of the strike's boards with this board's differences: a seed and a water of its own, the bridge's own proxy at the MAP's scale (a bridge is scenery),
# the planes' drawn size from the scenario (a tank 24 px at zoom 1 in Hold the bridge), a closest zoom of 3.0, and the gunfire's three passes.
class GfRig extends "res://scripts/fx/fx_board_rig.gd":
	var plane_px := 36.0
	var plane_min := 14.0
	var bridge_proxy: FxPlaneProxy = null
	var gf: GfLayer = null
	var g_ground: Node2D = null
	var g_shadow: Node2D = null
	var g_air: Node2D = null
	var seed_value := 20261009

	func setup_for(seed_v: int, water: RefCounted, px: float, pmin: float, painter: FxGunfire.Painter, book: FxGunfire.Book) -> void:
		seed_value = seed_v
		plane_px = px
		plane_min = pmin
		fxs = FxStyle.shared() as FxStyle
		fxd = FxData.shared() as FxData
		ui_style = UiStyle.shared() as UiStyle
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		vp = SubViewport.new()
		vp.size = SIZE
		vp.disable_3d = true
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		tree.root.add_child(vp)
		var P := RenderParams.new()
		view = MapView.new(seed_v, Rect2(), 0.0, "terrain", P, water)
		view.zoom_max = 3.0
		view.zoom_min = 0.12
		view.input_enabled = false
		vp.add_child(view)
		layer = CanvasLayer.new()
		vp.add_child(layer)
		fx = FxLayer.new()
		layer.add_child(fx)
		fx.setup(view, seed_v)
		towers = FxStructProxy.new()
		layer.add_child(towers)
		towers.setup(view, fxs)
		bridge_proxy = FxPlaneProxy.new()
		layer.add_child(bridge_proxy)
		bridge_proxy.setup(view, ui_style, fxs)
		proxy = FxPlaneProxy.new()
		layer.add_child(proxy)
		proxy.setup(view, ui_style, fxs)
		var above := Node2D.new()
		above.name = "AbovePlanes"
		layer.add_child(above)
		fx.mount(layer, above)
		# the gunfire: marks on the ground and the puffs' shadows under the units, the flashes, ticks and puffs over them
		gf = GfLayer.new()
		gf.painter = painter
		gf.book = book
		gf.mapping = UiMapping.from(view)
		var gg := FxPass.new()
		gg.name = "GunfireGround"
		gg.layer = gf
		gg.kind = "ground"
		layer.add_child(gg)
		layer.move_child(gg, fx.get_index() + 1)
		g_ground = gg
		var gs := FxShadowPass.new()
		gs.name = "GunfireShadows"
		gs.layer = gf
		gs.self_modulate = Color(1.0, 1.0, 1.0, fxs.param("shadow_strength"))
		layer.add_child(gs)
		layer.move_child(gs, gg.get_index() + 1)
		g_shadow = gs
		var ga := FxPass.new()
		ga.name = "GunfireAir"
		ga.layer = gf
		ga.kind = "air"
		above.add_child(ga)
		g_air = ga
		if not view.errors().is_empty():
			printerr("[gunfire] map errors: ", view.errors())

	func true_scale_at(zoom: float) -> float:
		var ppm_drawn := maxf(plane_px * zoom, plane_min) / 9.0
		return ppm_drawn / (view.px_per_m * zoom)

	func refresh_gf(t: float, zoom: float) -> void:
		gf.ts = true_scale_at(zoom)
		gf.now = t
		g_ground.queue_redraw()
		g_shadow.queue_redraw()
		g_air.queue_redraw()
		bridge_proxy.true_scale = 1.0
		bridge_proxy.refresh()

	# One frame centred on `center` at `zoom`, cropped to `crop` round the middle of the viewport (the base's, with the bridge and the gunfire refreshed too).
	func grab_frame(center: Vector2, zoom: float, crop: Vector2i, game_t: float) -> Image:
		camera(center, zoom)
		await wait_map()
		for k in 2:
			fx.queue_redraws()
			proxy.refresh()
			towers.refresh()
			refresh_gf(game_t, zoom)
			await frames(2)
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		var c := Vector2i(SIZE.x / 2, SIZE.y / 2)
		return img.get_region(Rect2i(c - crop / 2, crop))

	func free_all() -> void:
		view.baker.clear()
		view.queue_free()
		vp.queue_free()

# --- The scene: a resolved scenario, its poses and its events ---------------------------------------------------------------------------

class Scene extends RefCounted:
	var id := ""
	var world: World = null
	var water: RefCounted = null
	var terrain: Variant = null
	var units: Dictionary = {}        # id -> {type, side ("side_a" | "side_b"), size_m}
	var events: Array = []            # every event, with "tau" (seconds from the scenario's start)
	var poses: Dictionary = {}        # id -> Array of {tau, x, y, h (heading), z (height m)}
	var turns := 0
	var bridge_id := ""
	var seed_value := 0
	var combat_seed := 0

	func pose(uid: String, tau: float) -> Dictionary:
		var arr: Array = poses.get(uid, [])
		if arr.is_empty():
			return {}
		var t := clampf(tau, float((arr[0] as Dictionary)["tau"]), float((arr[arr.size() - 1] as Dictionary)["tau"]))
		var i := clampi(int(floor(t / 0.1 + 1e-6)), 0, arr.size() - 2)
		var a: Dictionary = arr[i]
		var b: Dictionary = arr[i + 1]
		var f := clampf((t - float(a["tau"])) / maxf(float(b["tau"]) - float(a["tau"]), 1e-6), 0.0, 1.0)
		return {"pos": Vector2(float(a["x"]), float(a["y"])).lerp(Vector2(float(b["x"]), float(b["y"])), f), "h": lerp_angle(float(a["h"]), float(b["h"]), f), "z": lerpf(float(a["z"]), float(b["z"]), f)}

	func pos_of(uid: String, tau: float) -> Vector2:
		return pose(uid, tau).get("pos", Vector2.ZERO)

	func record_turn(k: int, res: Dictionary) -> void:
		var w := world
		for uid: String in w.units:
			if not poses.has(uid):
				poses[uid] = []
			for i in 51:
				var t := 0.1 * float(i)
				var s: Dictionary = w.sample(uid, t, "history")
				if s.is_empty():
					continue
				(poses[uid] as Array).append({"tau": float(k) * TURN_S + t, "x": float(s["x"]), "y": float(s["y"]), "h": float(s.get("heading", 0.0)), "z": float(s.get("height_m", 0.0))})
		for ev: Dictionary in res.get("events", []):
			var e := ev.duplicate()
			e["tau"] = float(k) * TURN_S + float(e.get("t", 0.0))
			e["tidx"] = k
			events.append(e)
		turns = k + 1

func _accent_of(side_name: String) -> String:
	return "side_a" if side_name == "allies" else "side_b"

func _units_of(w: World) -> Dictionary:
	var out := {}
	for uid: String in w.units:
		var u = w.units[uid]
		out[uid] = {"type": str(u.def.silhouette), "side": _accent_of(str(u.side)), "size_m": float(u.def.size_m), "def": str(u.def.id)}
	return out

func _resolve_into(sc: Scene, g: RefCounted, k: int) -> void:
	var w: World = sc.world
	if w.phase == World.PHASE_RESOLVED:
		w.begin_turn()
	if g != null and g.has_method("plan_hook"):
		g.call("plan_hook", k)
	w.commit(str(g.get("player")) if g != null else "local")
	var res := w.resolve()
	if res.is_empty():
		printerr("[gunfire] turn %d did not resolve: %s" % [k + 1, w.last_error])
		return
	sc.record_turn(k, res)

# Two turns of the tanks' duel across the river: the players' two tanks south of the bridge, two wave tanks brought in to 120 m north of its middle
# (the rest sent out of range), all on their own fire. PROPOSED fixture: the real mission starts the waves 300 m out.
func _scene_duel() -> Scene:
	var ov := {
		"tank_e1": {"x": 3847.0, "y": 600.0, "heading": 1.62},
		"tank_e2": {"x": 3847.5, "y": 580.0, "heading": 1.62},
		"tank_e3": {"x": 3860.0, "y": 150.0}, "tank_e4": {"x": 3860.0, "y": 130.0},
		"tank_e5": {"x": 3860.0, "y": 110.0}, "tank_e6": {"x": 3860.0, "y": 90.0},
	}
	var g := BridgePlay.new(DUEL_COMBAT_SEED, ov)
	if not g.ok() or g.world == null:
		printerr("[gunfire] the duel's world did not load: ", g.errors)
	var sc := Scene.new()
	sc.id = "duel"
	sc.seed_value = BR_SEED
	sc.combat_seed = DUEL_COMBAT_SEED
	sc.world = g.world
	sc.water = g.scenario.water()
	sc.terrain = sc.water.make_terrain(BR_SEED)
	sc.terrain.px_per_m = 2.0
	sc.units = _units_of(g.world)
	sc.bridge_id = BridgePlay.BRIDGE
	for k in 2:
		_resolve_into(sc, g, k)
	return sc

# The cruiser's salvo: the Main Guns planned in turn 1 at the first wave tank, brought in to 68 m north of the bridge, and the shells land in turn 3.
func _scene_salvo() -> Scene:
	var ov := {
		"tank_e1": {"x": 3847.5, "y": 668.0, "heading": 1.62},
		"tank_e2": {"x": 3848.0, "y": 648.0, "heading": 1.62},
		"tank_e3": {"x": 3860.0, "y": 150.0}, "tank_e4": {"x": 3860.0, "y": 130.0},
		"tank_e5": {"x": 3860.0, "y": 110.0}, "tank_e6": {"x": 3860.0, "y": 90.0},
	}
	var g := BridgePlay.new(SALVO_COMBAT_SEED, ov)
	var sc := Scene.new()
	sc.id = "salvo"
	sc.seed_value = BR_SEED
	sc.combat_seed = SALVO_COMBAT_SEED
	sc.world = g.world
	sc.water = g.scenario.water()
	sc.terrain = sc.water.make_terrain(BR_SEED)
	sc.terrain.px_per_m = 2.0
	sc.units = _units_of(g.world)
	sc.bridge_id = BridgePlay.BRIDGE
	var w: World = g.world
	for k in w.steps_per_turn("cruiser_1"):
		if k == 0:
			var st := w.plan_step("cruiser_1", 0, {"fire": {"special": "main_guns", "target": {"unit": "tank_e1"}}})
			if st.is_empty():
				printerr("[gunfire] the salvo could not be planned: ", w.last_error)
	for k in 3:
		_resolve_into(sc, g, k)
	return sc

# One turn of the strike: a bomber (the players', side A) flying east over the village battery with a heavy fighter (side B) 150 m behind it.
func _scene_strike(battery: Vector2) -> Scene:
	var start := battery + Vector2(-260.0, 30.0)
	var w := World.new()
	w.rng_seed = STRIKE_COMBAT_SEED
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": start.x, "y": start.y, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
	w.add_unit({"id": "hf", "type": "heavy_fighter", "side": "axis", "controller": "player", "x": start.x - 150.0, "y": start.y - 2.0, "heading": 0.0, "speed": 100.0, "altitude_band": "medium"})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "player", "x": battery.x, "y": battery.y, "heading": 0.0, "speed": 0.0})
	var sc := Scene.new()
	sc.id = "strike"
	sc.seed_value = ST_SEED
	sc.combat_seed = STRIKE_COMBAT_SEED
	sc.world = w
	sc.units = _units_of(w)
	_resolve_into(sc, null, 0)
	return sc

# --- Materials: what a landing is on ---------------------------------------------------------------------------------------------------------------

const MATERIAL_OF_UNIT := {"light_fighter": "metal", "heavy_fighter": "metal", "bomber": "metal", "tank": "metal", "mobile_aa": "metal", "anti_aircraft_battery": "ground",
	"radio_tower": "metal", "military_complex": "stone", "bridge": "stone", "cruiser": "metal", "patrol_boat": "metal", "supply_boat": "wood"}

# What is under a point (world m) at a time: a tank's hull, the bridge's deck and piers, the water, a tree's canopy, else the ground. PROPOSED rule (the
# material table of variants/gunfire/families.json); the sim has no such query.
func _material_at(sc: Scene, p: Vector2, tau: float) -> String:
	for uid: String in sc.units:
		var u: Dictionary = sc.units[uid]
		var ty := str(u["type"])
		if ty == "bridge" or ty == "small_cruiser" or ty in ["light_fighter", "heavy_fighter", "bomber"]:
			continue
		var pp := sc.pose(uid, tau)
		if pp.is_empty():
			continue
		if p.distance_to(pp["pos"]) < float(u["size_m"]) * 0.6:
			return str(MATERIAL_OF_UNIT.get(str(u["def"]), "metal"))
	if sc.bridge_id != "":
		var bp := sc.pose(sc.bridge_id, tau)
		if not bp.is_empty():
			var d: Vector2 = p - (bp["pos"] as Vector2)
			var hd := float(bp["h"])
			var along := d.dot(Vector2.from_angle(hd))
			var across := d.dot(Vector2(-sin(hd), cos(hd)))
			if absf(along) <= 20.0 and absf(across) <= 8.0:
				return "stone"
	if sc.water != null and float(sc.water.depth_at(p.x, p.y)) > 0.0:
		return "water"
	if sc.terrain != null:
		var ppm: float = float(sc.terrain.px_per_m)
		var rect := Rect2((p - Vector2(30, 30)) * ppm, Vector2(60, 60) * ppm)
		for tr: Dictionary in sc.terrain.trees_in_rect_px(rect):
			if Vector2(float(tr["x"]), float(tr["y"])).distance_to(p * ppm) < float(tr["r"]) * 0.85:
				return "wood"
	return "ground"

# --- The gun models: where a muzzle is, in the shooter's own metres ----------------------------------------------------------------------------------

func _tank_gun_fwd() -> float:
	var m = UnitMarkerArt.model_for(rig.ui_style, "tank")
	var ymin := 1e9
	for q: Vector2 in m.G.gun:
		ymin = minf(ymin, q.y)
	return -ymin

# The forward turrets' barrel tips of the cruiser: [{fwd, lat}], in model metres (the ship's bow is -y).
func _cruiser_barrels() -> Array:
	var m = UnitMarkerArt.model_for(rig.ui_style, "small_cruiser")
	var out: Array = []
	for t: Dictionary in m.G.turrets:
		if (t["c"] as Vector2).y >= 0.0:
			continue
		for bar: PackedVector2Array in t["bars"]:
			var ymin := 1e9
			var xs := 0.0
			for q: Vector2 in bar:
				ymin = minf(ymin, q.y)
				xs += q.x
			out.append({"fwd": -ymin, "lat": xs / float(bar.size())})
	return out

# --- Adapters: the sim's events become records ----------------------------------------------------------------------------------------------------------

func _hash_unit(tag: String, tau: float, salt: int) -> float:
	return Mulberry32.new(FxBake.seed_of(tag, int(round(tau * 1000.0)), salt)).next()

# Where a MISSED round lands: PROPOSED, visual only. Along the line of fire it carries on a little short or a good way past the target and to one side of it.
func _miss_point(shooter: Vector2, target: Vector2, tag: String, tau: float) -> Vector2:
	var rng := Mulberry32.new(FxBake.seed_of(tag, int(round(tau * 1000.0)), 31))
	var d := target - shooter
	var dist := maxf(d.length(), 1.0)
	var fwd := d / dist
	var nrm := Vector2(-fwd.y, fwd.x)
	var lateral := (4.0 + 12.0 * rng.next()) * (1.0 if rng.next() < 0.5 else -1.0)
	var along := -10.0 + 40.0 * rng.next()
	return target + fwd * along + nrm * lateral

# A hit's point on its target: inside the hull (a tank) or on the deck (the bridge), seeded.
func _hit_point(sc: Scene, tid: String, tau: float, tag: String) -> Vector2:
	var tp := sc.pose(tid, tau)
	var c: Vector2 = tp["pos"]
	var hd := float(tp["h"])
	var rng := Mulberry32.new(FxBake.seed_of(tag, int(round(tau * 1000.0)), 17))
	var fwd := Vector2.from_angle(hd)
	var nrm := Vector2(-fwd.y, fwd.x)
	var ty := str((sc.units[tid] as Dictionary)["type"])
	if ty == "bridge":
		return c + fwd * (rng.next() - 0.5) * 30.0 + nrm * (rng.next() - 0.5) * 9.0
	if ty == "tank":
		return c + fwd * (rng.next() - 0.5) * 3.0 + nrm * (rng.next() - 0.5) * 1.8
	return c + fwd * (rng.next() - 0.5) * 8.0 + nrm * (rng.next() - 0.5) * 4.0

# Fills the gunfire book and the game's own effects layer from a scene's events, for one family. G0 is today's: only what the game draws now (the shells as B3
# bombs, flak F2, tracers T5, W1 on a damaged plane); G1 to G4 add the muzzles and the impacts of the family.
func _play_scene(sc: Scene, fam: String) -> void:
	_fx_reset()
	gbook.clear()
	var new_look := fam != "G0"
	if new_look:
		gbook.select(fam)
	rig.fx.select_tracers("T5")
	rig.fx.select_strike("F2", "B3")
	rig.fx.set_wind(wind)
	gbook.set_wind(wind)
	var tank_fwd := _tank_gun_fwd()
	var barrels := _cruiser_barrels()
	var shell_i := 0
	for ev: Dictionary in sc.events:
		var tau := float(ev["tau"])
		var kind := str(ev["type"])
		if kind == "fire":
			var wp := str(ev.get("weapon", ""))
			var sid := str(ev["unit"])
			var tid := str(ev["target"])
			if not sc.units.has(sid) or not sc.units.has(tid):
				continue
			if sid in ["tank_e3", "tank_e4", "tank_e5", "tank_e6"]:
				continue
			var sp := sc.pose(sid, tau)
			var shot := "%s/%s/%d" % [sid, wp, int(round(tau * 100.0))]
			if wp == "turret_gun":
				if not new_look:
					continue
				var dir := float(sp["h"])
				gbook.add_muzzle(shot, "medium", sp["pos"], dir, tank_fwd, T0 + tau, 2.3)
				var tpos: Vector2 = sc.pos_of(tid, tau)
				var flight := tpos.distance_to(sp["pos"]) / SHELL_FLIGHT_MPS
				var land: Vector2
				var mat: String
				if bool(ev.get("hit", false)):
					land = _hit_point(sc, tid, tau + flight, shot)
					mat = str(MATERIAL_OF_UNIT.get(str((sc.units[tid] as Dictionary)["def"]), "metal"))
				else:
					land = _miss_point(sp["pos"], sc.pos_of(tid, tau + flight), shot, tau)
					mat = _material_at(sc, land, tau + flight)
				gbook.add_impact(shot + "/land", "medium", mat, land, T0 + tau + flight, (tpos - (sp["pos"] as Vector2)).angle(), 0.0)
			elif wp == "nose_cannon":
				if not new_look:
					continue
				gbook.add_muzzle(shot, "small", sp["pos"], float(sp["h"]), 8.0, T0 + tau, float(sp["z"]))
				if bool(ev.get("hit", false)):
					var tp := sc.pose(tid, tau + 0.15)
					var rng := Mulberry32.new(FxBake.seed_of(shot, 3, 5))
					var fwd := Vector2.from_angle(float(tp["h"]))
					var nrm := Vector2(-fwd.y, fwd.x)
					var land2: Vector2 = (tp["pos"] as Vector2) + fwd * (rng.next() - 0.5) * 12.0 + nrm * (rng.next() - 0.5) * 8.0
					gbook.add_impact(shot + "/land", "small", "metal", land2, T0 + tau + 0.15, float(sp["h"]), float(tp["z"]))
			elif wp == "flak" or wp == "light_flak":
				var tp2 := sc.pose(tid, tau)
				var dirv: Vector2 = (tp2["pos"] as Vector2) - (sp["pos"] as Vector2)
				if new_look:
					gbook.add_muzzle(shot, "medium" if wp == "flak" else "small", sp["pos"], dirv.angle(), 4.0, T0 + tau, 6.0 if wp == "flak" else 3.0)
				rig.fx.flak_burst(Vector2(float(ev.get("tx", 0.0)), float(ev.get("ty", 0.0))), float(tp2["z"]), T0 + tau, bool(ev.get("hit", false)), "%s/%s/%d" % [sid, wp, int(ev.get("tick", 0))], 0.0)
			elif wp in ["tail_turret", "rear_gunner", "nose_gun", "dorsal_turret", "wing_guns"]:
				var p0 := sc.pose(tid, tau)
				var p1 := sc.pose(tid, tau + rig.fx.tracer_flight_s())
				var lead: Vector2 = (p1["pos"] as Vector2) - (p0["pos"] as Vector2)
				FxTracer.feed_event(rig.fx, ev, T0 + tau, sp["pos"], float((sc.units[tid] as Dictionary)["size_m"]), str((sc.units[sid] as Dictionary)["side"]), 1.0, true, true, lead)
		elif kind == "shell_impact":
			var pos := Vector2(float(ev["x"]), float(ev["y"]))
			var land_tau := tau
			var shot2 := "main_guns/%d/%d" % [int(ev.get("step", 0)), int(ev.get("shell", 0))]
			var rel_tau := (float(int(ev.get("released_turn", 1)) - 1)) * TURN_S + float(ev.get("released_t", 0.0))
			var mat2 := _material_at(sc, pos, land_tau)
			if new_look:
				var sid2 := str(ev["unit"])
				var sp2 := sc.pose(sid2, rel_tau)
				if not barrels.is_empty():
					var b: Dictionary = barrels[shell_i % barrels.size()]
					gbook.add_muzzle(shot2, "large", sp2["pos"], float(sp2["h"]), float(b["fwd"]), T0 + rel_tau, 8.0, float(b["lat"]))
				gbook.add_impact(shot2 + "/land", "large", mat2, pos, T0 + land_tau, (pos - (sp2["pos"] as Vector2)).angle(), 0.0)
				if mat2 != "water" and mat2 != "metal":
					rig.fx.add_crater(shot2, pos, T0 + land_tau, float(ev.get("blast_m", 20.0)), FxBake.seed_of(shot2, 1, 2))
			else:
				rig.fx.bomb_impact(pos, T0 + land_tau, float(ev.get("blast_m", 20.0)), str(ev["unit"]), shell_i)
			shell_i += 1
		elif kind == "hit":
			# damage smoke (W1) on a plane: from the hit on, at the health fraction it left it with (the tracers board's rule)
			var hid := str(ev["unit"])
			if sc.units.has(hid) and str((sc.units[hid] as Dictionary)["type"]) in ["bomber", "heavy_fighter", "light_fighter"]:
				var full := float(sc.world.units[hid].def.health)
				var frac := clampf(float(ev["health"]) / full, 0.0, 1.0)
				var t_hit := tau
				var t_end := float(sc.turns) * TURN_S
				var next_hit := t_end
				for e2: Dictionary in sc.events:
					if str(e2["type"]) == "hit" and str(e2["unit"]) == hid and float(e2["tau"]) > t_hit + 1e-6:
						next_hit = minf(next_hit, float(e2["tau"]))
				var sampler := func(tg: float) -> Dictionary:
					var pp := sc.pose(hid, tg - T0)
					return {"x": (pp["pos"] as Vector2).x, "y": (pp["pos"] as Vector2).y, "height_m": float(pp["z"]), "heading": float(pp["h"])}
				rig.fx.emit_path(hid, sampler, T0 + t_hit, T0 + next_hit, frac, float((sc.units[hid] as Dictionary)["size_m"]))

# --- Frames -----------------------------------------------------------------------------------------------------------------------------------------------

func _planes_at(sc: Scene, tau: float) -> Array:
	var out: Array = []
	for uid: String in sc.units:
		var u: Dictionary = sc.units[uid]
		var ty := str(u["type"])
		if ty == "bridge":
			continue
		if uid in ["tank_e3", "tank_e4", "tank_e5", "tank_e6"]:
			continue
		var pp := sc.pose(uid, tau)
		if pp.is_empty():
			continue
		var h := float(pp["z"]) if ty in ["bomber", "heavy_fighter", "light_fighter"] else (2.5 if ty == "tank" else (6.0 if ty == "small_cruiser" else 0.0))
		out.append(grig.plane(pp["pos"], float(pp["h"]), h, str(u["side"]), ty))
	return out

func _bridge_at(sc: Scene, tau: float) -> Array:
	if sc.bridge_id == "":
		return []
	var pp := sc.pose(sc.bridge_id, tau)
	return [grig.plane(pp["pos"], float(pp["h"]), 0.0, "side_a", "bridge")]

func _gframe(sc: Scene, tau: float, zoom: float, at: Vector2, cap: String) -> Dictionary:
	return {"dt": tau, "zoom": zoom, "center": at, "sc": sc, "cap": "%s  (zoom %.2f)" % [cap, zoom]}

func _gcap(tau: float, note: String = "") -> String:
	return ("%.2f s" % tau) + (("  " + note) if note != "" else "")

# A row run with this board's rig: sets the clocks, the planes and the bridge, grabs the crop.
func _run_grow(r: Dictionary) -> Dictionary:
	var imgs: Array = []
	var caps: Array = []
	for f: Dictionary in r["frames"]:
		var sc: Scene = f["sc"]
		var tau := float(f["dt"])
		grig.fx.set_time(T0 + tau)
		grig.set_planes(_planes_at(sc, tau))
		grig.bridge_proxy.planes = _to_typed(_bridge_at(sc, tau))
		grig.set_towers([])
		var img: Image = await grig.grab_frame(f["center"], float(f["zoom"]), r["crop"], T0 + tau)
		imgs.append(img)
		caps.append(str(f["cap"]))
	print("[gunfire] row %s: %d frames (%s, gunfire %d records, %d bakes)" % [r["key"], imgs.size(), str(grig.fx.stats()), gbook.records.size(), gpainter.bakes])
	return {"key": r["key"], "title": r["title"], "frames": imgs, "caps": caps, "key_frame": int(r["key_frame"]), "crop": r["crop"]}

func _to_typed(list: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in list:
		out.append(p)
	return out

# --- The rows ---------------------------------------------------------------------------------------------------------------------------------------------

func _shell_times(sc: Scene) -> Dictionary:
	var rel0 := 1e9
	var land0 := 1e9
	var first_water := {}
	for ev: Dictionary in sc.events:
		if str(ev["type"]) == "shell_impact":
			var rel := (float(int(ev.get("released_turn", 1)) - 1)) * TURN_S + float(ev.get("released_t", 0.0))
			rel0 = minf(rel0, rel)
			land0 = minf(land0, float(ev["tau"]))
			if first_water.is_empty() and _material_at(sc, Vector2(float(ev["x"]), float(ev["y"])), float(ev["tau"])) == "water":
				first_water = {"pos": Vector2(float(ev["x"]), float(ev["y"])), "tau": float(ev["tau"])}
	return {"rel0": rel0, "land0": land0, "water": first_water}

func _rows_duel(sc: Scene) -> Array:
	var rows: Array = []
	var t1 := sc.pos_of("tank_1", 1.0)
	var e1 := sc.pos_of("tank_e1", 1.0)
	var bridge := sc.pos_of(sc.bridge_id, 1.0)
	var mid := (t1 + e1) * 0.5
	var f: Array = []
	for tau: float in [1.1, 2.2, 3.5, 5.5, 8.0, 10.0]:
		f.append(_gframe(sc, tau, 0.35, bridge + Vector2(0, -20), _gcap(tau)))
	rows.append(_row("duel_plan", "a. THE DUEL AT THE PLANNING ZOOM (0.35): two player tanks south of the bridge, two wave tanks 120 m north of it, all firing on their own (turn 1 at 1 to 5 s, turn 2 from 6 s)", BR_WIDE, Callable(), f, 3))
	f = []
	for tau: float in [1.1, 1.4, 2.2, 3.3, 5.0, 8.0]:
		f.append(_gframe(sc, tau, 1.0, mid + Vector2(0, 8), _gcap(tau)))
	rows.append(_row("duel_1", "b. THE DUEL, ZOOM 1.0: the tanks fire north across the bridge, the wave tanks at the bridge and at them; hits and misses as the sim rolled them", BR_CROP_P, Callable(), f, 2))
	f = []
	var muz := t1 + Vector2(0.0, -20.0)
	for tau: float in [1.06, 1.2, 1.7, 2.6, 4.2, 7.0]:
		f.append(_gframe(sc, tau, 3.0, muz, _gcap(tau)))
	rows.append(_row("muzzle_3", "c. A TANK FIRES, CLOSEST ZOOM (3.0): the muzzle flash and smoke of the player's tank, drifting with the wind (the first volley is at 1.0 s)", BR_CROP, Callable(), f, 1))
	f = []
	for tau: float in [2.1, 2.4, 3.0, 4.2, 6.0, 9.0]:
		f.append(_gframe(sc, tau, 3.0, bridge + Vector2(0.0, 2.0), _gcap(tau)))
	rows.append(_row("bridge_3", "d. LANDINGS AT THE BRIDGE, ZOOM 3.0: the wave tanks' rounds on the stone deck, and the ones that miss on the river, the road and the trees", BR_CROP, Callable(), f, 2))
	return rows

func _rows_salvo(sc: Scene) -> Array:
	var rows: Array = []
	var tm := _shell_times(sc)
	var rel0 := float(tm["rel0"])
	var land0 := float(tm["land0"])
	var ship := sc.pos_of("cruiser_1", rel0)
	var hd := float(sc.pose("cruiser_1", rel0)["h"])
	var bow := ship + Vector2.from_angle(hd) * 40.0
	var f: Array = []
	for dt: float in [0.08, 0.3, 0.9, 2.5, 6.0, 12.0]:
		f.append(_gframe(sc, rel0 + dt, 1.0, bow, _gcap(rel0 + dt, "+%.1f s after the first shell leaves" % dt)))
	rows.append(_row("ship_1", "e. THE CRUISER'S SALVO, ZOOM 1.0: six shells leave the forward turrets 0.2 s apart; the flash, the smoke drifting with the wind", BR_CROP, Callable(), f, 1))
	f = []
	for dt: float in [0.08, 0.5, 1.5, 4.0, 9.0, 16.0]:
		f.append(_gframe(sc, rel0 + dt, 0.35, ship + Vector2.from_angle(hd) * 30.0, _gcap(rel0 + dt, "+%.1f s" % dt)))
	rows.append(_row("ship_plan", "f. THE SAME AT THE PLANNING ZOOM (0.35): the cruiser is 120 m long, its muzzle a few pixels", BR_WIDE, Callable(), f, 1))
	# the landings, centred on the middle of the six
	var sum := Vector2.ZERO
	var n := 0
	for ev: Dictionary in sc.events:
		if str(ev["type"]) == "shell_impact":
			sum += Vector2(float(ev["x"]), float(ev["y"]))
			n += 1
	var cen := sum / float(maxi(n, 1))
	f = []
	for dt: float in [0.05, 0.45, 1.1, 2.4, 6.0, 14.0]:
		f.append(_gframe(sc, land0 + dt, 1.0, cen, _gcap(land0 + dt, "+%.1f s after the first shell lands" % dt)))
	rows.append(_row("salvo_1", "g. THE SALVO LANDS, ZOOM 1.0: six shells on five surfaces (ground, stone, water, a tree, a tank), one every 0.2 s", BR_CROP_P, Callable(), f, 3))
	f = []
	for dt: float in [0.3, 1.2, 3.0, 8.0, 16.0, 30.0]:
		f.append(_gframe(sc, land0 + dt, 0.35, cen, _gcap(land0 + dt, "+%.1f s" % dt)))
	rows.append(_row("salvo_plan", "h. THE SAME AT THE PLANNING ZOOM (0.35)", BR_WIDE, Callable(), f, 2))
	if not (tm["water"] as Dictionary).is_empty():
		var wat: Dictionary = tm["water"]
		var wt := float(wat["tau"])
		f = []
		for dt: float in [0.04, 0.25, 0.7, 1.6, 3.5, 8.0]:
			f.append(_gframe(sc, wt + dt, 3.0, wat["pos"], _gcap(wt + dt, "+%.2f s after it lands" % dt)))
		rows.append(_row("river_3", "i. A SHELL IN THE RIVER, ZOOM 3.0: a splash and rings on the water, no smoke", BR_CROP, Callable(), f, 1))
	return rows

func _rows_strike(sc: Scene, battery: Vector2) -> Array:
	var rows: Array = []
	var f: Array = []
	for tau: float in [1.1, 2.0, 3.0, 4.0, 5.0]:
		f.append(_gframe(sc, tau, 0.35, battery + Vector2(40.0, 0.0), _gcap(tau)))
	rows.append(_row("flak_plan", "j. THE STRIKE AT THE PLANNING ZOOM (0.35): the village battery fires flak at the bomber (F2 bursts), the heavy fighter's cannon from behind, the bomber's tail guns (T5)", BR_WIDE, Callable(), f, 2))
	f = []
	for tau: float in [1.2, 1.8, 2.4, 3.1, 3.9, 5.0]:
		f.append(_gframe(sc, tau, 1.0, battery + Vector2(30.0, -10.0), _gcap(tau)))
	rows.append(_row("flak_1", "k. THE BATTERY FIRES, ZOOM 1.0: the guns' muzzle puffs and the F2 burst the sim's rolls make at the bomber crossing overhead", BR_CROP, Callable(), f, 2))
	f = []
	for tau: float in [1.02, 1.15, 1.5, 2.0, 2.6, 3.6]:
		f.append(_gframe(sc, tau, 3.0, battery + Vector2(6.0, -4.0), _gcap(tau)))
	rows.append(_row("flak_3", "k2. THE BATTERY'S GUNS, CLOSEST ZOOM (3.0): the flak gun (medium) and the light flak gun (small) fire at the bomber approaching from the west", BR_CROP, Callable(), f, 1))
	f = []
	for tau: float in [1.1, 1.4, 2.2, 3.1, 3.5, 5.1]:
		var mid := (sc.pos_of("bomber", tau) + sc.pos_of("hf", tau)) * 0.5
		f.append(_gframe(sc, tau, 1.0, mid, _gcap(tau)))
	rows.append(_row("nose_1", "l. THE HEAVY FIGHTER'S NOSE CANNON, ZOOM 1.0: muzzle puffs left along its path, hits on the bomber (metal), the bomber's damage smoke W1 and its tail guns' T5 tracers", BR_CROP, Callable(), f, 3))
	f = []
	for tau: float in [1.04, 1.2, 1.7, 3.04, 3.22, 3.9]:
		var bp := sc.pos_of("bomber", tau)
		f.append(_gframe(sc, tau, 3.0, bp + Vector2(-8.0, 0.0), _gcap(tau)))
	rows.append(_row("nose_3", "m. THE CANNON'S HITS, CLOSEST ZOOM (3.0): rounds landing on the bomber's tail (metal); the hits are at 1.15 s, 3.15 s and 5.15 s", BR_CROP, Callable(), f, 4))
	f = []
	for tau: float in [1.02, 1.07, 1.2, 1.4, 1.8, 2.4]:
		var hp := sc.pos_of("hf", tau)
		f.append(_gframe(sc, tau, 3.0, hp + Vector2(10.0, 0.0), _gcap(tau)))
	rows.append(_row("nose_muz", "n. THE NOSE CANNON'S MUZZLE, CLOSEST ZOOM (3.0): the camera follows the heavy fighter; the puff is left in the air at 400 m and drifts with the faster wind up there", BR_CROP, Callable(), f, 1))
	return rows

# --- The board ----------------------------------------------------------------------------------------------------------------------------------------------

func _board() -> void:
	_light_rig()
	var names: Array = _names(FAMILY_ORDER)
	var only_scene := str(opts.get("scene", ""))
	gbook = FxGunfire.Book.new(cfg)
	gpainter = FxGunfire.Painter.new(fxs, fxd)
	var data := {}
	for n: String in names:
		data[n] = []
	var scenes_meta: Array = []
	# 1. HOLD THE BRIDGE (seed 55): the duel and the salvo, on one map
	if only_scene in ["", "duel", "salvo"]:
		var duel := _scene_duel()
		var salvo := _scene_salvo()
		if duel.events.is_empty() or salvo.events.is_empty():
			printerr("[gunfire] a scene played no events (a data file mid-edit by another builder?): duel %d, salvo %d" % [duel.events.size(), salvo.events.size()])
			quit(1)
			return
		print("[gunfire] duel: %d events, %d turns; salvo: %d events, %d turns, poses of %s" % [duel.events.size(), duel.turns, salvo.events.size(), salvo.turns, str(salvo.poses.keys())])
		var water: RefCounted = duel.water
		# the sea lies south of the bridge (the cruiser's station is 2.7 km that way): a sea breeze from the south, 15:00 (PROPOSED fixture)
		wind = Wind.from_params({"hour": 15.0, "toward_sea": [0.25, 0.97], "seed": BR_SEED, "v": 1})
		print("[gunfire] the wind: ", wind.describe(), "  at 5 s ", wind.at(5.0))
		grig = GfRig.new(self)
		await grig.setup_for(BR_SEED, water, 24.0, 12.0, gpainter, gbook)
		rig = grig
		fxs = grig.fxs
		fxd = grig.fxd
		FxGunfire.install_roles(fxs, cfg)
		var all_rows := {"duel": _rows_duel(duel), "salvo": _rows_salvo(salvo)}
		for sid: String in ["duel", "salvo"]:
			if only_scene != "" and only_scene != sid:
				continue
			var sc: Scene = duel if sid == "duel" else salvo
			for name: String in names:
				_play_scene(sc, name)
				for r: Dictionary in all_rows[sid]:
					if _only != "" and str(r["key"]) != _only:
						continue
					(data[name] as Array).append(await _run_grow(r))
		scenes_meta.append({"scene": "duel", "seed": BR_SEED, "combat_seed": DUEL_COMBAT_SEED, "events": duel.events.size()})
		scenes_meta.append({"scene": "salvo", "seed": BR_SEED, "combat_seed": SALVO_COMBAT_SEED, "events": salvo.events.size()})
		grig.free_all()
		await grig.frames(3)
	# 2. THE STRIKE (seed 20261009)
	if only_scene in ["", "strike"]:
		var WL: GDScript = load("res://scripts/world/world_layout.gd")
		var layout = WL.new(ST_SEED)
		var battery: Vector2 = (layout.sites()["aa_battery"] as Array)[0]
		var strike := _scene_strike(battery)
		wind = Wind.from_params({"hour": 15.0, "toward_sea": [-0.6, 0.8], "seed": ST_SEED, "v": 1})
		strike.terrain = null
		grig = GfRig.new(self)
		await grig.setup_for(ST_SEED, null, 36.0, 14.0, gpainter, gbook)
		rig = grig
		fxs = grig.fxs
		fxd = grig.fxd
		FxGunfire.install_roles(fxs, cfg)
		var st_rows := _rows_strike(strike, battery)
		for name: String in names:
			_play_scene(strike, name)
			for r: Dictionary in st_rows:
				if _only != "" and str(r["key"]) != _only:
					continue
				(data[name] as Array).append(await _run_grow(r))
		scenes_meta.append({"scene": "strike", "seed": ST_SEED, "combat_seed": STRIKE_COMBAT_SEED, "events": strike.events.size()})
		grig.free_all()
		await grig.frames(3)
	# 3. the sheets
	var specimens := {}
	rig = FxRig.new(self)
	_light_rig()
	for name: String in names:
		specimens[name] = await _specimen_matrix(name)
	await _write_gboard(names, data, specimens, scenes_meta)

# --- The specimen: round x material, and the muzzle by gun, at three ages --------------------------------------------------------------------------------

class GfNode extends Node2D:
	var painter: FxGunfire.Painter = null
	var book: FxGunfire.Book = null
	var mapping: RefCounted = null
	var ts: float = 1.0
	var now: float = 0.0
	var layers: Array = ["ground", "air"]
	var size_px := Vector2(1600, 900)
	func _draw() -> void:
		if painter == null or book == null or mapping == null:
			return
		for lay: String in layers:
			painter.draw(self, book, mapping, ts, now, Rect2(Vector2.ZERO, size_px), lay)

const SPEC_PPM := 6.0
const SPEC_NOW := 100.0
const SPEC_AGES := [0.07, 0.45, 2.4]
const SPEC_MATS := ["ground", "water", "stone", "metal", "wood"]
const SPEC_MUZZLE_AGES := [0.06, 0.25, 0.8, 2.5, 6.0]

func _spec_only() -> void:
	_light_rig()
	var names: Array = _names(["G1", "G2", "G3", "G4"])
	for name: String in names:
		var img: Image = await _specimen_matrix(name)
		var path := ProjectSettings.globalize_path("res://tmp/gunfire/spec_%s.png" % name)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		img.save_png(path)
		print("[gunfire] specimen ", path, " ", img.get_size())

# One family's specimen: for every round class (rows) and material (blocks of three ages), the impact on its backdrop; then the muzzle of each gun class.
func _specimen_matrix(fam_id: String) -> Image:
	if fam_id == "G0":
		var st0 := fxs
		return await rig.specimen(Vector2i(1576, 70), func(cl: CanvasLayer) -> void:
			_spec_label(cl, "Today nothing is drawn for a muzzle, or for a tank or cannon round that lands; a cruiser shell is a B3 bomb burst (flash, white W1 smoke, clods, crater) on every surface, water included.", Vector2(10, 8), 14, st0)
			_spec_label(cl, "The decided looks beside the new ones in every column: tracers T5, flak F2, the bomb B3's crater, the damage smoke W1.", Vector2(10, 36), 14, st0))
	var book := FxGunfire.Book.new(cfg)
	if fam_id != "G0":
		book.select(fam_id)
	book.world_seed = 5
	var wnd: Object = Wind.from_params({"hour": 15.0, "toward_sea": [-1.0, 0.0], "seed": 7, "v": 1})
	book.set_wind(wnd)
	var painter := FxGunfire.Painter.new(fxs, fxd)
	var cell := 96.0
	var left := 76.0
	var top := 26.0
	var rounds := ["bullet", "small", "medium", "large"]
	var guns := ["small", "medium", "large"]
	var mat_block := cell * float(SPEC_AGES.size()) + 10.0
	var width := int(left + mat_block * float(SPEC_MATS.size()) + 10.0)
	var muzzle_cell := Vector2(260.0, 150.0)
	var muz_top := top + cell * float(rounds.size()) + 40.0
	var height := int(muz_top + muzzle_cell.y * float(guns.size()) + 20.0)
	var sc_ppm := SPEC_PPM
	for ri in rounds.size():
		for mi in SPEC_MATS.size():
			for ai in SPEC_AGES.size():
				var centre := Vector2(left + mat_block * float(mi) + cell * (float(ai) + 0.5), top + cell * (float(ri) + 0.5)) / sc_ppm
				var tag := "%s/%s/%d" % [rounds[ri], SPEC_MATS[mi], ai]
				book.add_impact(tag, rounds[ri], SPEC_MATS[mi], centre, SPEC_NOW - float(SPEC_AGES[ai]), 0.0)
	var barrels: Array = []
	for gi in guns.size():
		for ai in SPEC_MUZZLE_AGES.size():
			var pxp := Vector2(left + 24.0 + (muzzle_cell.x * 0.78) * float(ai), muz_top + muzzle_cell.y * (float(gi) + 0.7))
			barrels.append(pxp)
			book.add_muzzle("g/%s/%d" % [guns[gi], ai], guns[gi], pxp / sc_ppm, -PI / 2.0, 0.0, SPEC_NOW - float(SPEC_MUZZLE_AGES[ai]), 2.0)
	var mapping := UiMapping.from(Transform2D(0.0, Vector2(sc_ppm, sc_ppm), 0.0, Vector2.ZERO))
	var st := fxs
	var water_color: Color = WaterDraw.new(RenderParams.new()).steps[1]
	var img: Image = await rig.specimen(Vector2i(width, height), func(cl: CanvasLayer) -> void:
		var holder := _SpecBack.new()
		holder.fxs = st
		holder.water = water_color
		holder.cell = cell
		holder.left = left
		holder.top = top
		holder.mat_block = mat_block
		holder.rows = rounds.size()
		holder.cols = SPEC_MATS.size()
		holder.ages = SPEC_AGES.size()
		holder.barrels = barrels
		cl.add_child(holder)
		var n := GfNode.new()
		n.painter = painter
		n.book = book
		n.mapping = mapping
		n.ts = 1.0
		n.now = SPEC_NOW
		n.size_px = Vector2(width, height)
		cl.add_child(n)
		for mi in SPEC_MATS.size():
			_spec_label(cl, SPEC_MATS[mi], Vector2(left + mat_block * float(mi) + 4.0, 4.0), 13, st)
		for ri in rounds.size():
			_spec_label(cl, str(rounds[ri]), Vector2(6.0, top + cell * (float(ri) + 0.45)), 13, st)
		for gi in guns.size():
			_spec_label(cl, "muzzle " + str(guns[gi]), Vector2(6.0, muz_top + muzzle_cell.y * (float(gi) + 0.55)), 12, st)
		_spec_label(cl, "round class and what it lands on, at %.2f s, %.2f s and %.1f s after the landing" % [SPEC_AGES[0], SPEC_AGES[1], SPEC_AGES[2]], Vector2(left, muz_top - 26.0), 12, st)
		)
	return img

func _spec_label(cl: Node, text: String, at: Vector2, px: int, st: FxStyle) -> void:
	var l := Label.new()
	l.text = text
	l.position = at
	UiStyle.shared().stamp(l)   # the style's own lettering look (the face, lettering.stamp.px, full ink, a paper outline), as the corner stamps take it
	cl.add_child(l)

# The backdrops of the specimen: the surface each material stands for under its cells, and the gun barrel each muzzle comes from.
class _SpecBack extends Node2D:
	var fxs: FxStyle = null
	var water: Color = Color.WHITE
	var cell := 96.0
	var left := 76.0
	var top := 26.0
	var mat_block := 300.0
	var rows := 4
	var cols := 5
	var ages := 3
	var barrels: Array = []
	func _draw() -> void:
		var ink: Color = fxs.palette["ink"]
		var wall: Color = fxs.palette["wall_fill"]
		var fill: Color = fxs.palette["object_fill"]
		for mi in cols:
			for ai in ages:
				for ri in rows:
					var r := Rect2(left + mat_block * float(mi) + cell * float(ai), top + cell * float(ri), cell - 3.0, cell - 3.0)
					match mi:
						1:
							draw_rect(r, water, true)
							draw_rect(r, Color(ink.r, ink.g, ink.b, 0.5), false, 1.0)
						2:
							var deck := Rect2(r.position + Vector2(0.0, r.size.y * 0.22), Vector2(r.size.x, r.size.y * 0.56))
							draw_rect(deck, wall, true)
							draw_rect(deck, Color(ink.r, ink.g, ink.b, 0.85), false, 1.2)
							draw_line(deck.position + Vector2(0, 4), deck.position + Vector2(deck.size.x, 4), Color(ink.r, ink.g, ink.b, 0.5), 1.0)
							draw_line(deck.position + Vector2(0, deck.size.y - 4), deck.position + Vector2(deck.size.x, deck.size.y - 4), Color(ink.r, ink.g, ink.b, 0.5), 1.0)
						3:
							var hull := Rect2(r.position + r.size * 0.5 - Vector2(18.0, 10.0), Vector2(36.0, 20.0))
							draw_rect(hull, fill, true)
							draw_rect(hull, Color(ink.r, ink.g, ink.b, 0.85), false, 1.2)
							draw_circle(hull.position + hull.size * 0.5, 6.0, Color(ink.r, ink.g, ink.b, 0.6), false, 1.0)
						4:
							var c := r.position + r.size * 0.5
							draw_circle(c, 30.0, fill, true)
							draw_arc(c, 30.0, 0.0, TAU, 28, Color(ink.r, ink.g, ink.b, 0.85), 1.2, true)
							draw_arc(c, 18.0, 0.0, TAU, 20, Color(ink.r, ink.g, ink.b, 0.5), 0.9, true)
		for b: Vector2 in barrels:
			draw_line(b + Vector2(0, 26), b + Vector2(0, 2), Color(ink.r, ink.g, ink.b, 0.9), 4.0, true)
			draw_line(b + Vector2(0, 26), b + Vector2(0, 2), fill, 2.0, true)

const STRIKE_KEYS := ["flak_plan", "flak_1", "flak_3", "nose_1", "nose_3", "nose_muz"]

func _per_line(c: Vector2i) -> int:
	return maxi(1, int(2960 / (c.x + 8)))

# A rough cost of a shot, in canvas operations (a polygon, a line, a dot, a sprite each count one; a flash fan counts its triangles), for the families' recipes:
# per muzzle by gun class and per impact by material at the medium and large rounds. Tanks fire a shell a second, so this is what a busy turn costs.
func _cost(fam: String) -> Dictionary:
	var f: Dictionary = (cfg["families"] as Dictionary)[fam]
	var out := {"muzzle": {}, "impact_medium": {}, "impact_large": {}}
	for cls: String in ["small", "medium", "large"]:
		(out["muzzle"] as Dictionary)[cls] = _ops(f["muzzle"], cls)
	for mat: String in ["ground", "water", "stone", "metal", "wood"]:
		(out["impact_medium"] as Dictionary)[mat] = _ops((f["impact"] as Dictionary)[mat], "medium")
		(out["impact_large"] as Dictionary)[mat] = _ops((f["impact"] as Dictionary)[mat], "large")
	return out

func _ops(parts: Array, cls: String) -> int:
	var n := 0
	for p: Dictionary in parts:
		if p.has("classes") and not (cls in (p["classes"] as Array)):
			continue
		var cnt := FxGunfire.cv(p.get("n", 1), cls, 1.0)
		match str(p["type"]):
			"flash":
				n += 2 * int(p.get("spikes", 8)) + 2 if str(p.get("form", "star")) != "disc" else 17
			"strokes", "stipple", "chips", "leaves", "puffs":
				n += int(cnt) * (2 if str(p["type"]) in ["chips", "leaves"] else 1)
			"rings":
				n += int(cnt)
			"scorch":
				n += 14 + int(p.get("dots", 0)) + int(p.get("hatch", 0))
			"disc":
				n += 29
	return n

# --- Writing the board --------------------------------------------------------------------------------------------------------------------------------------

func _fam_label(id: String) -> String:
	if id == "G0":
		return "G0  As built today (reference, not an option)"
	return str((cfg["families"] as Dictionary)[id].get("label", id))

func _fam_note(id: String) -> String:
	if id == "G0":
		return "What the game draws now, for comparison: no muzzle flash or smoke, no impact for a tank or cannon round, the cruiser's shell a B3 bomb burst on every surface (water included). Tracers T5, flak F2 and the damage smoke W1 are the decided looks and are drawn the same in every column."
	return str((cfg["families"] as Dictionary)[id].get("note", ""))

func _role_chips(sh: FxSheet, pos: Vector2, roles: Array) -> void:
	var x := pos.x
	var paper: Color = fxs.palette["paper"]
	for role: String in roles:
		var c: Color = fxs.color(role)
		var over := Color(paper.r + (c.r - paper.r) * c.a, paper.g + (c.g - paper.g) * c.a, paper.b + (c.b - paper.b) * c.a)
		sh.swatch(Vector2(x, pos.y), Vector2(46, 22), over)
		sh.label(role.replace("gf.", "").replace(".0.1", ""), Vector2(x, pos.y + 25), 10, false, FxSheet.FG)
		x += 68.0

func _write_gboard(names: Array, data: Dictionary, specimens: Dictionary, scenes_meta: Array) -> void:
	var id := "gunfire"
	var dir := out_dir.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir.path_join("frames"))
	var listing: Array = []
	var json_opts: Array = []
	for name: String in names:
		var rows_out: Array = []
		for r: Dictionary in data[name]:
			var frames_out: Array = []
			for i in (r["frames"] as Array).size():
				var rel := "frames/%s_%s_%d.png" % [name, r["key"], i]
				var err := ((r["frames"] as Array)[i] as Image).save_png(dir.path_join(rel))
				if err != OK:
					printerr("[gunfire] could not write ", rel)
				frames_out.append({"file": rel, "caption": str((r["caps"] as Array)[i])})
			rows_out.append({"title": str(r["title"]), "key": str(r["key"]), "size_px": [(r["crop"] as Vector2i).x, (r["crop"] as Vector2i).y], "frames": frames_out})
		listing.append({"option": name, "label": _fam_label(name), "note": _fam_note(name), "rows": rows_out})
	rig.write_json(dir.path_join("frames.json"), {"id": id, "options": listing})
	# two sheets per option, full size: Hold the bridge's rows and the Strike's, each under the option's specimen and palette strip
	var palette_roles := ["gf.dust.0.1", "gf.stone.0.1", "gf.dark.0.1", "gf.paper.0.1", "gf.paper_dust.0.1", "gf.paper_dark.0.1", "gf.splash", "gf.scorch", "gf.chip", "gf.leaf"]
	for name: String in names:
		var files: Array = []
		for grp: String in ["bridge", "strike"]:
			var rows: Array = []
			for r: Dictionary in data[name]:
				if (str(r["key"]) in STRIKE_KEYS) == (grp == "strike"):
					rows.append(r)
			if rows.is_empty():
				continue
			var w := 1700
			var h := 360
			for r: Dictionary in rows:
				var c: Vector2i = r["crop"]
				var per := _per_line(c)
				var n := (r["frames"] as Array).size()
				w = maxi(w, mini(n, per) * (c.x + 8) + 40)
				h += int(ceil(float(n) / float(per))) * (c.y + 40) + 30
			var sh := FxSheet.new(rig.tree.root, Vector2i(w, h))
			sh.label("Gunfire, option %s  --  %s" % [_fam_label(name), "HOLD THE BRIDGE (seed 55)" if grp == "bridge" else "THE STRIKE (seed 20261009)"], Vector2(16, 10), 22, true)
			var nl := sh.label(_fam_note(name), Vector2(16, 40), 13, false, FxSheet.DIM, w - 40.0)
			var y := 48.0 + nl.size.y
			sh.label("PROPOSED. Muzzle by gun class and impact by round class and surface (on the surface's backdrop), then the palette it is drawn in:", Vector2(16, y), 12, false, FxSheet.DIM)
			sh.image(specimens[name], Vector2(16, y + 18), 1.0)
			var py: float = y + 18.0 + float((specimens[name] as Image).get_height()) + 14.0
			_chips(sh, Vector2(16, py))
			_role_chips(sh, Vector2(16 + 9.0 * 74.0 + 24.0, py), palette_roles)
			y = py + 62.0
			for r: Dictionary in rows:
				sh.label(str(r["title"]), Vector2(16, y), 14, true)
				y += 22
				var c: Vector2i = r["crop"]
				var per := _per_line(c)
				for k in (r["frames"] as Array).size():
					var col := k % per
					var line := k / per
					var at := Vector2(16 + col * (c.x + 8), y + line * (c.y + 40))
					sh.image((r["frames"] as Array)[k], at, 1.0)
					sh.label(str((r["caps"] as Array)[k]), at + Vector2(0, c.y + 4), 12, false, FxSheet.DIM)
				y += int(ceil(float((r["frames"] as Array).size()) / float(per))) * (c.y + 40) + 8
			var fname := "option_%s_%s.png" % [name, grp]
			await sh.save(dir.path_join(fname), self)
			sh.free_sheet()
			files.append(fname)
		var params: Dictionary = {}
		if name != "G0":
			params = (cfg["families"] as Dictionary)[name].duplicate(true)
			params["cost_ops"] = _cost(name)
		json_opts.append({"name": name, "label": _fam_label(name), "note": _fam_note(name), "files": files, "parameters": params})
	# the compare sheet: one key frame per row, the options side by side
	var row_keys: Array = []
	for r: Dictionary in data[names[0]]:
		row_keys.append(str(r["key"]))
	var csc := 0.5
	var cmp_w := 400
	var cmp_h := 90
	for r: Dictionary in data[names[0]]:
		cmp_h += int((r["crop"] as Vector2i).y * csc) + 50
		cmp_w = maxi(cmp_w, int(names.size() * (int((r["crop"] as Vector2i).x * csc) + 6)) + 40)
	var cmp := FxSheet.new(rig.tree.root, Vector2i(cmp_w, cmp_h))
	cmp.label("Gunfire: the families side by side", Vector2(16, 10), 22, true)
	cmp.label("One key frame per row, the options left to right (%s). Shrunk to 50%%; the native frames are in frames/." % ", ".join(PackedStringArray(names)), Vector2(16, 42), 12, false, FxSheet.DIM, cmp_w - 40.0)
	var y3 := 76.0
	for ri in (data[names[0]] as Array).size():
		var r0: Dictionary = (data[names[0]] as Array)[ri]
		var c: Vector2i = r0["crop"]
		var cw2 := int(c.x * csc)
		var ch2 := int(c.y * csc)
		cmp.label("%s  --  %s" % [str(r0["title"]).substr(0, 110), (r0["caps"] as Array)[int(r0["key_frame"])]], Vector2(16, y3), 12, true)
		y3 += 20
		for ni in names.size():
			var rr: Dictionary = (data[names[ni]] as Array)[ri]
			cmp.image(_shrink((rr["frames"] as Array)[int(rr["key_frame"])], cw2, ch2), Vector2(16 + ni * (cw2 + 6), y3), 1.0)
			cmp.label(str(names[ni]), Vector2(20 + ni * (cw2 + 6), y3 + 3), 14, true, FxSheet.FG)
		y3 += ch2 + 28
	await cmp.save(dir.path_join("compare.png"), self)
	cmp.free_sheet()
	rig.write_json(dir.path_join("board.json"), _board_json(json_opts, scenes_meta))

func _board_json(json_opts: Array, scenes_meta: Array) -> Dictionary:
	var shared := {}
	for k: String in ["classes", "rounds", "roles", "puffs", "materials"]:
		shared[k] = cfg.get(k)
	return {
		"id": "gunfire",
		"date": "2026-10-11",
		"area": "Effects",
		"decision": "gunfire-looks (with impact-by-round-and-target)",
		"question": "How do big guns' muzzle flash and smoke look, and how does a round that lands without destroying look, by the round and by what it hits? (Alex 2026-10-11, third playtest: 'Fired shots should have smoke for large rounds (tanks, artillery and ship cannons). Landed shots should have an impact even if they don't destroy you.'; asked for options: '8 yes, give options'; and: 'this should probably be a property of either the round or the thing being hit or both. Ex a round hitting water would splash, not explode with smoke. Right?')",
		"source": "scripts/fx/fx_board_gunfire.gd over the real map (seed 55 with its water for Hold the bridge, seed 20261009 for the Strike); the effects are scripts/fx/fx_gunfire.gd reading variants/gunfire/families.json; the scenes are the real sim's events (the combat seeds below)",
		"seed": ST_SEED,
		"seeds": {"hold_the_bridge_map": BR_SEED, "strike_map": ST_SEED},
		"scenes": scenes_meta,
		"parameter": "variants/gunfire/families.json (every value PROPOSED); on a pick it moves to data/fx/fx.json as value records, and a `fires` field per weapon (decision round-model) names the gun and round class",
		"held_constant": {
			"scenes": "HOLD THE BRIDGE: two player tanks south of the bridge and two wave tanks brought to 120 m north of it for the DUEL (combat seed %d, two turns); the SALVO (combat seed %d, three turns) at a wave tank 68 m north of the bridge. THE STRIKE: a bomber and a heavy fighter 150 m behind it over the first battery (combat seed %d, one turn)" % [DUEL_COMBAT_SEED, SALVO_COMBAT_SEED, STRIKE_COMBAT_SEED],
			"events": "every fire / shell_fire / shell_impact of the real sim; PROPOSED and visual only: where a missed tank round lands (seeded 4 to 16 m aside, -10 to +30 m along the line), a tank round's flight (700 m/s), the material under a landing (the table below)",
			"light": "sun azimuth 315, elevation 46; shadow strength 0.44 (the live sun)",
			"wind": "the coastal wind of data/sim/wind.json at hour 15 (the sea breeze), the same for every column; puffs drift with it by height (decision wind-with-height)",
			"scale": "the planes' own scale: a tank 24 px at zoom 1 in Hold the bridge, a light fighter 36 px in the Strike; zooms 0.35 (planning), 1.0 and the new closest 3.0",
			"decided_looks_beside": "tracers T5, flak F2, the bomb B3's crater and W1 damage smoke are drawn by the game's own code in every column; the unit art is the game's",
			"fire": "none",
			"fog": "all units seen",
		},
		"options": json_opts,
		"shared": shared,
		"material_table": cfg.get("material_table"),
		"sheet": "compare.png (the options side by side, one key frame per row), option_<X>_bridge.png and option_<X>_strike.png (each family at full size, with the specimen and the palette strip); every frame at native size in frames/, listed in frames.json",
		"recommendation": {"option": "G3", "_proposed": true, "_reason": "PROPOSED by builder GF, not Alex's call. G3 draws a muzzle puff, a dust puff and a damage plume in ONE grammar (W1, which Alex chose), so the map has one kind of smoke; it is the calmest to read when two to eight tanks each fire a shell a second; it tells materials by lightness alone (dust is the dirt ink lightened toward paper, stone dust paler, a metal hit a dark wash), which is the style guide's rule, and a round in water is a pale ring and an ink ripple with no puff. Its cost: thin washes on cream paper read faintly at the planning zoom (the class table's min_px floors help; a larger floor is a number to tune). G2 is the pick if Alex wants every impact to read at zoom 1 to 3 as a drawn thing (edged puffs, a splash crown) and accepts a busier map; G4 if a crowded turn matters more than telling the materials apart; G1 reads best at the planning zoom (dark dots) but its smoke is made of dots and looks like soot."},
		"findings": [
			"The sizes and the material table are the same in every family: they can be decided apart from the look. Sizes: small 1.7 m, medium 2.4 m, large 6.5 m for a gun's flash; 1.7, 2.8 and 6.5 m (bullet 0.7 m) for an impact (all PROPOSED, drawn at the planes' scale with a floor in px).",
			"At the planning zoom (0.35) a tank is about 8 px and its muzzle puff sits at its 6.5 px floor: only the cruiser's salvo, the flak and G1's dark dots read there. Zoom 1 and 3 read in every family.",
			"A round that lands on stone makes dust and chips, not continuous smoke: this is also the answer to the bridge's smoke question (decision playtest-3, bridge_smoke, question 1): a hit on the bridge is a puff of dust and a few chips on the deck.",
			"A shell in water splashes in every family (a splash crown or a pale ring, ripples, no puff); today's game draws it as a B3 bomb burst with white smoke on the river (column G0).",
			"The sim gives a missed shot no landing point. Here a miss lands a seeded 4 to 16 m beside the target and -10 to +30 m along the line (visual only); the material under it is looked up from the map (a unit's footprint, the bridge deck, water, a tree's canopy, else ground). A real miss point is the line-of-fire proposal.",
			"Trees, houses and walls are baked scenery with no presence in the sim, so a round can show a tree or wall impact today only as the material under a MISS point; the table is ready for when they have one.",
			"The cost of a shot in canvas operations is in each family's parameters (cost_ops): G1 is the most (a stipple cloud of 80 to 210 dots a muzzle), G2 and G3 a handful of sprites, G4 the least."
		],
		"integration": "scripts/fx/fx_gunfire.gd is the effect code (a Book of muzzle and impact records, a Painter), written to become the game's, as fx_tracer.gd is. To build a pick: move the chosen family, the class tables and the material table into data/fx/fx.json as value records; give every weapon a `fires` round and gun class (decision round-model); call add_muzzle from CombatFeed on a cannon's `fire` event, a flak gun's and a Main Guns `shell_fire`/shell_impact release; call add_impact on a hit (the target's material), on a shell_impact (the material under it) and, once the sim carries a landing point, on a miss; mount a ground pass and a shadow pass under the unit markers and the air pass over them (as the board's GfRig does) with the effects layer's wind. A shell in water would no longer call bomb_impact.",
		"chosen": null,
		"chosen_by": null,
	}
