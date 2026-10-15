extends SceneTree

# THE SPLASH BOARD (builder BS, 2026-10-14): variants/splash/ = backlog B13. WINDOWED ONLY -- under --headless nothing is drawn:
#
#   .\tools\shot.ps1 -Script res://scripts/fx/fx_board_splash.gd -Out variants/splash [-Sheet] [-Args what=frames,only=S2]
#
# ALEX: "Water splashes are far too big and the style is inconsistent." and (decision soft-puffs-default) "Generally I like the look of the soft puffs as a default
# impact style". Three water looks were live (a unit going under: ink rings; a bomb or shell in water: the same rings sized by the blast at the units' enlarged scale; a
# tank or nose-cannon round in water: G3's pale ring and ripple). OPTIONS (all PROPOSED): S0 today, S1 soft spray small, S2 soft spray medium, S3 = S2 + a brief pale wash and
# ring on the water, S4 = S2 + a taller leaning column for bombs and shells, S5 = S2 drawn at the units' marker scale, as the G3 land dust is (data/fx/fx.json `splash`, drawn by scripts/fx/fx_gunfire.gd's painter from the soft puff sprites).
#
# THE FRAMES ARE THE GAME'S OWN CODE: the real map (seed 55, Hold the bridge's: the river at the bridge and the sea the cruiser sails in) under the real FxLayer, and every
# splash is made by the layer's own entry points, the calls CombatFeed makes (gunfire_impact for the tank's round, water_impact for a shell and a bomb, splash + down_flash for a
# cutter going under); the land impact of the same round beside it is the game's too (G3 earth dust for the tank round, the B3 blast for a shell and a bomb). Only the one data
# key (fx.json splash.mode) changes between the options: here through FxLayer.set_splash_mode, which is what the data key sets. One seed, one wind, one sun.
#
# WHAT IS IN EACH FRAME. RIVER (zoom 1.0 and 0.35): the river is 26 m wide, bending south-east past an open field; on its water, left to right, a tank round (cannon_medium), a cruiser shell, a bomb; on the field
# across the bank from each, the SAME round on land. Two tanks (drawn at the units' scale) stand about for size. SEA: on open water the same three, then a cutter (27 m) going under with
# the game's down flash. Each at two moments: PEAK (+0.35 s) and LATE (+1.6 s) after they land together.
#
# OUTPUT (variants/splash/): <option>_<scene>_<zoom>_<phase>.png crops at native size (the same crop for every option of a scene), context_*.png whole 1280 x 720 frames,
# palette_strip.png (paper, ink, the flash step and the spray ramp over the water), board.json, frames.json.

const FxRig = preload("res://scripts/fx/fx_board_rig.gd")
const FxSheet = preload("res://scripts/fx/fx_sheet.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FxPlaneProxy = preload("res://scripts/fx/fx_plane_proxy.gd")
const FxStructProxy = preload("res://scripts/fx/fx_struct_proxy.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const Wind = preload("res://scripts/sim/wind.gd")

const SEED := 55
const T0 := 100.0
const OPTIONS := ["S0", "S1", "S2", "S3", "S4", "S5"]
const PHASES := [["peak", 0.35, "at its peak, 0.35 s after it lands"], ["late", 1.6, "late in its life, 1.6 s after it lands"]]
const ZOOMS := [1.0, 0.35]
const CROPS := {1.0: Vector2i(640, 340), 0.35: Vector2i(560, 280)}
const PLANE_PX := 24.0
const PLANE_MIN := 12.0
const RIVER_X := [4225.0, 4255.0, 4285.0]       # a tank round, a shell, a bomb along the river where it bends south-east past an open field (about 50 m apart)
const BANK_OFF := Vector2(-46.0, 36.0)          # the land impact of the same round: this far across the bank, onto the field
const SEA_AT := Vector2(4540.0, 3430.0)
const SEA_DX := [-120.0, -40.0, 40.0, 120.0]     # a tank round, a shell, a bomb, the cutter
const CUTTER_M := 27.0
const SINK_FLASH_FRAC := 0.7

const LABELS := {
	"S0": ["S0", "Today: ink rings (units, bombs, shells) and G3's pale ring (tank rounds)", "ink rings"],
	"S1": ["S1", "Soft spray, small", "soft puffs"],
	"S2": ["S2", "Soft spray, medium", "soft puffs"],
	"S3": ["S3", "Soft spray with a pale wash and ring on the water", "soft puffs + wash"],
	"S4": ["S4", "Soft spray, a tall column for bombs and shells", "soft puffs + column"],
	"S5": ["S5", "Soft spray, medium, at the markers' scale (the land dust's)", "soft puffs, marker scale"],
}

# The rig: the strike boards' (real map under a camera, the real FxLayer, the proxies for units), with this board's seed, its water, the markers' scale of Hold the bridge (a tank 24 px
# at zoom 1) and the effects layer's AIR pass between the surface units and the aircraft (UnitMarkerLayer.smoke_slot), where the game puts smoke and spray.
class SplashRig extends "res://scripts/fx/fx_board_rig.gd":
	var plane_px := PLANE_PX
	var plane_min := PLANE_MIN
	var slot: Node2D = null

	func setup_for(seed_v: int, water: RefCounted) -> void:
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
		proxy = FxPlaneProxy.new()
		layer.add_child(proxy)
		proxy.setup(view, ui_style, fxs)
		slot = Node2D.new()
		slot.name = "SmokeSlot"
		layer.add_child(slot)
		var above := Node2D.new()
		above.name = "AbovePlanes"
		layer.add_child(above)
		fx.mount(layer, above)
		fx.mount_smoke(slot)   # (the game's order: units, then smoke and spray, then aircraft)
		if not view.errors().is_empty():
			printerr("[splash] map errors: ", view.errors())

	func true_scale_at(zoom: float) -> float:
		var ppm_drawn := maxf(plane_px * zoom, plane_min) / 9.0
		return ppm_drawn / (view.px_per_m * zoom)

	func free_all() -> void:
		view.baker.clear()
		view.queue_free()
		vp.queue_free()

var opts: Dictionary = {}
var out_dir := ""
var rig: SplashRig = null
var water: RefCounted = null
var wind: Object = null
var _frames: Array = []
var _failures := 0
var _water_px: Color = Color(0.6, 0.7, 0.75)

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[splash] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", "variants/splash"))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	_run.call_deferred()

func _run() -> void:
	water = WaterGen.shared(SEED)
	if water == null or not water.ok():
		printerr("[splash] the water of seed %d did not build" % SEED)
		quit(1)
		return
	wind = Wind.from_params({"hour": 15.0, "toward_sea": [0.25, 0.97], "seed": SEED, "v": 1})
	rig = SplashRig.new(self)
	await rig.setup_for(SEED, water)
	if not rig.fxs.ok() or not rig.ui_style.ok():
		printerr("[splash] style errors: ", rig.fxs.errors, rig.ui_style.errors)
		quit(1)
		return
	rig.fx.select_strike("F2", "B3")
	rig.fx.set_wind(wind)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var only := str(opts.get("only", ""))
	var what := str(opts.get("what", "frames"))
	var names: Array = []
	for o: String in OPTIONS:
		if only == "" or only == o:
			names.append(o)
	if what == "frames":
		await _scene_river(names)
		await _scene_sea(names)
		await _context(names)
		await _palette_strip()
		_write_json(names)
	rig.free_all()
	await rig.frames(3)
	quit(1 if (_failures > 0 or rig.failures > 0) else 0)

# --- The scenes --------------------------------------------------------------------------------------------------------------------

# The river's middle at x (the deepest water along a short north-south line).
func _river_y(x: float) -> float:
	var best_y := 720.0
	var best := -1.0
	var y := 690.0
	while y <= 1100.0:
		var d: float = water.depth_at(x, y)
		if d > best:
			best = d
			best_y = y
		y += 1.0
	return best_y

# A dry point near (x, y), moved north until it is dry.
func _dry(x: float, y: float) -> Vector2:
	var q := y
	while water.depth_at(x, q) > 0.0 and q > y - 80.0:
		q -= 4.0
	return Vector2(x, q)

# The point itself if it is dry, else the nearest dry one stepping away from the river.
func _dry_at(p: Vector2) -> Vector2:
	var q := p
	var k := 0
	while water.depth_at(q.x, q.y) > 0.0 and k < 30:
		q += BANK_OFF.normalized() * 4.0
		k += 1
	return q

# Lands every round of the scene at T0, by the layer's own entry points. `land`: the same rounds on the bank too.
func _land_all(kind: String, option: String) -> Dictionary:
	var fx: FxLayer = rig.fx
	fx.clear()
	fx.set_splash_mode(option)
	fx.set_wind(wind)
	fx.select_strike("F2", "B3")
	var info := {}
	if kind == "river":
		var ys: Array = []
		for x: float in RIVER_X:
			ys.append(_river_y(x))
		var pw: Array = []
		for i in 3:
			pw.append(Vector2(RIVER_X[i], ys[i]))
		var pl: Array = []
		for i in 3:
			pl.append(_dry_at(pw[i] + BANK_OFF))
		# the water side (what the feed calls)
		fx.gunfire_impact("tank/water", "medium", "water", pw[0], T0)
		fx.water_impact(pw[1], T0, 20.0, "cruiser_1", "shell_large")
		fx.water_impact(pw[2], T0, 45.0, "bomber", "bomb")
		# the land side of the same rounds
		fx.gunfire_impact("tank/land", "medium", "earth", pl[0], T0)
		fx.bomb_impact(pl[1], T0, 20.0, "cruiser_1", 500000)
		fx.bomb_impact(pl[2], T0, 45.0, "bomber", 0)
		info = {"water": pw, "land": pl, "centre": (pw[1] + pl[1]) * 0.5}
		var tanks: Array = []
		tanks.append(rig.plane(_dry_at(pw[0] + BANK_OFF * 1.9 + Vector2(40.0, 0.0)), -1.2, 0.0, "side_a", "tank"))
		tanks.append(rig.plane(_dry_at(pw[2] - BANK_OFF * 1.0), 0.5, 0.0, "side_b", "tank"))
		rig.set_planes(tanks)
	else:
		var ps: Array = []
		for dx: float in SEA_DX:
			ps.append(SEA_AT + Vector2(dx, 0.0))
		fx.gunfire_impact("tank/water", "medium", "water", ps[0], T0)
		fx.water_impact(ps[1], T0, 20.0, "cruiser_1", "shell_large")
		fx.water_impact(ps[2], T0, 45.0, "bomber", "bomb")
		fx.splash("patrol_1", ps[3], T0, CUTTER_M)
		fx.down_flash("patrol_1", ps[3], T0, CUTTER_M * SINK_FLASH_FRAC)
		info = {"water": ps, "land": [], "centre": SEA_AT + Vector2(0.0, 0.0)}
		rig.set_planes([rig.plane(ps[3], 0.4, 0.0, "side_a", "patrol_boat")])
	return info

func _scene_river(names: Array) -> void:
	for option: String in names:
		var info := _land_all("river", option)
		for z: float in ZOOMS:
			for ph: Array in PHASES:
				rig.fx.set_time(T0 + float(ph[1]))
				var img: Image = await rig.grab(info["centre"], z, CROPS[z])
				_save(img, option, "river", z, str(ph[0]), str(ph[2]))

func _scene_sea(names: Array) -> void:
	for option: String in names:
		var info := _land_all("sea", option)
		for z: float in ZOOMS:
			for ph: Array in PHASES:
				rig.fx.set_time(T0 + float(ph[1]))
				var img: Image = await rig.grab(info["centre"], z, CROPS[z])
				if option == "S0" and z == 1.0 and str(ph[0]) == "peak":
					_water_px = img.get_pixel(6, 6)
				_save(img, option, "sea", z, str(ph[0]), str(ph[2]))

# Whole 1280 x 720 frames: the river at zoom 1.0 and 0.35, S0 and the recommendation's S2, late.
func _context(names: Array) -> void:
	for option: String in names:
		if not (option in ["S0", "S2"]):
			continue
		var info := _land_all("river", option)
		rig.fx.set_time(T0 + 0.35)
		var img: Image = await rig.grab(info["centre"], 1.0, rig.SIZE)
		var f := "context_%s_river_z1.0.png" % option
		img.save_png(out_dir.path_join(f))
		_frames.append({"file": f, "option": option, "title": "%s - the whole frame, river, zoom 1.0" % option, "caption": "A whole 1280 x 720 frame of the river at zoom 1.0, 0.35 s after the rounds land: the map, the tanks and the splashes together.", "scene": "context_river", "zoom": 1.0, "phase": "peak", "size": [img.get_width(), img.get_height()]})

func _save(img: Image, option: String, scene: String, z: float, phase: String, phase_note: String) -> void:
	var f := "%s_%s_z%s_%s.png" % [option, scene, ("%.2f" % z).rstrip("0").rstrip("."), phase]
	var err := img.save_png(out_dir.path_join(f))
	if err != OK:
		printerr("[splash] could not write ", f)
		_failures += 1
		return
	var scene_note := "RIVER: left to right on the water a tank round, a cruiser shell, a bomb; the same three rounds on the field across the bank; two tanks for size" if scene == "river" \
		else "SEA: left to right a tank round, a cruiser shell, a bomb, a 27 m cutter going under (with the game's down flash)"
	_frames.append({"file": f, "option": option, "title": "%s - %s - zoom %s - %s" % [option, scene, ("%.2f" % z).rstrip("0").rstrip("."), phase],
		"caption": "%s. %s, zoom %s, %s. 1:1 crop of the game's frame." % [LABELS[option][1], scene_note, ("%.2f" % z).rstrip("0").rstrip("."), phase_note],
		"scene": scene, "zoom": z, "phase": phase, "size": [img.get_width(), img.get_height()]})

# The palette strip: paper, ink, the knock-out flash step the spray is made of, and the spray ramp (fresh, middle, old x thin, medium, thick) laid over the water as the frames
# have it. Hue is reserved for paper, ink, shadow and accents: the spray adds none.
func _palette_strip() -> void:
	var st: FxStyle = rig.fxs
	var sh := FxSheet.new(root, Vector2i(960, 150))
	sh.label("The splash palette: no new hue. The spray is the knock-out flash step (the lightest value on the map) at the alpha of each ramp step, over the water", Vector2(12, 8), 13, true)
	var x := 12.0
	for it: Array in [["paper", "paper"], ["ink", "ink"], ["flash", "flash step"], ["shadow", "shadow tint"]]:
		sh.swatch(Vector2(x, 36), Vector2(54, 40), st.palette[it[0]])
		sh.label(str(it[1]), Vector2(x, 80), 11, false, FxSheet.DIM)
		x += 70.0
	sh.swatch(Vector2(x, 36), Vector2(54, 40), _water_px)
	sh.label("water", Vector2(x, 80), 11, false, FxSheet.DIM)
	x += 90.0
	for s in 3:
		for t in 3:
			var c: Color = st.color("splash.spray.%d.%d" % [s, t])
			var over := _water_px.lerp(Color(c.r, c.g, c.b, 1.0), c.a)
			sh.swatch(Vector2(x, 36), Vector2(40, 40), over)
			sh.label("%d.%d" % [s, t], Vector2(x, 80), 11, false, FxSheet.DIM)
			x += 46.0
		x += 8.0
	var w1: Color = st.color("splash.wash")
	var r1: Color = st.color("splash.ring")
	sh.swatch(Vector2(x - 4, 36), Vector2(40, 40), _water_px.lerp(Color(w1.r, w1.g, w1.b, 1.0), w1.a))
	sh.label("wash", Vector2(x - 4, 80), 11, false, FxSheet.DIM)
	sh.swatch(Vector2(x + 46, 36), Vector2(40, 40), _water_px.lerp(Color(r1.r, r1.g, r1.b, 1.0), r1.a))
	sh.label("ring", Vector2(x + 46, 80), 11, false, FxSheet.DIM)
	sh.label("spray ramp: stage 0 (fresh), 1, 2 (old); in each, tone 0 (thin), 1, 2 (thick)", Vector2(12, 112), 12, false, FxSheet.DIM)
	var img: Image = await sh.save(out_dir.path_join("palette_strip.png"), self)
	sh.free_sheet()
	_frames.append({"file": "palette_strip.png", "option": "all", "title": "The palette beside the water", "caption": "Paper, ink, the flash step, the shadow tint and the water, then the nine spray roles laid over the water, then the wash and the ring of S3. One palette: lightness is a ramp off the paper, no new hue.", "scene": "palette", "zoom": 0.0, "phase": "", "size": [img.get_width(), img.get_height()]})

func _write_json(names: Array) -> void:
	var fxd: FxData = rig.fxd
	var sec := fxd.splash_section()
	var options: Array = []
	for o: String in names:
		var rec := {"id": o, "label": LABELS[o][1], "look": LABELS[o][2]}
		if o == "S0":
			rec["description"] = "TODAY, as a reference: a unit going under is three widening ink rings (data/world/boats.json game.sunk.splash); a bomb or a shell in water the same ink rings sized 0.35 x its blast (fx.json impacts.water) at the units' enlarged marker scale; a tank or nose-cannon round in water G3's pale disc, ring and ink ripple."
			rec["selects"] = {"fx.json splash.mode": "S0"}
		else:
			var opt: Dictionary = (sec["options"] as Dictionary)[o]
			rec["description"] = str(opt["description"])
			rec["selects"] = {"fx.json splash.mode": o}
			var sz: Dictionary = opt["sizes"]
			var table := {}
			for tag: String in ["bullet", "cannon_small", "cannon_medium", "shell_large", "bomb"]:
				table[tag] = "%.2f m" % float((sz[tag] as Dictionary)["r_m"])
			table["unit going under"] = "%.0f%% of its size_m, at most %.0f m (a 27 m cutter %.1f m), at the units' scale" % [100.0 * float((sz["unit"] as Dictionary)["frac"]), float((sz["unit"] as Dictionary)["max_m"]), minf(27.0 * float((sz["unit"] as Dictionary)["frac"]), float((sz["unit"] as Dictionary)["max_m"]))]
			rec["size_table_radius_m"] = table
			rec["size_table_note"] = "PROPOSED. Radius of the spray cloud in metres of the MAP (a metre is 2 px at zoom 1.0, 0.7 px at the planning zoom 0.35, where each is floored at 2 to 6 px so it still reads)." + (" S5 draws the same table at the units' marker scale (in Hold the bridge about 2 x the map's at zoom 1.0)." if o == "S5" else "")
		options.append(rec)
	var board := {
		"id": "splash",
		"date": "2026-10-14",
		"area": "FX",
		"backlog": "B13",
		"question": "How does a splash look, once, for everything that enters water? Alex: 'Water splashes are far too big and the style is inconsistent.' And, as a rule (decision soft-puffs-default): 'Generally I like the look of the soft puffs as a default impact style'.",
		"source": "scripts/fx/fx_board_splash.gd: the real map (seed 55, Hold the bridge's river at the bridge and its sea) under the real FxLayer; every splash made by the layer's own entry points (gunfire_impact, water_impact, splash + down_flash), the land impact of the same round beside it the game's own (G3 earth dust, B3 blast); ONLY fx.json splash.mode changes between the options",
		"seed": SEED,
		"held_constant": {
			"map": "seed 55 (data/scenarios/bridge.json): the river at the bridge (3845, 714), 26 m wide, flowing east; the sea the cruiser sails in at (4540, 3430), 25 m deep",
			"rounds": "a tank round (cannon_medium), a cruiser shell (shell_large, blast 20 m), a bomb (blast 45 m), a 27 m cutter going under; all land together; the land counterpart about 58 m away across the bank, on an open field (river scene only)",
			"zooms": "1.0 (2 px/m) and the planning zoom 0.35 (0.7 px/m)",
			"unit_going_under": "the cutter's splash is sized by the unit (20% of its 27 m, 5.4 m) and drawn at the markers' scale with its hull; the game's own down flash (the white disc and ink stipple) is drawn as it always is and is not part of this board",
			"phases": "peak (+0.35 s) and late (+1.6 s)",
			"scale": "the splash is drawn at the MAP's scale (a metre of map is a metre of splash); the units, the G3 land dust and the cutter's splash are at the markers' scale (a tank is drawn 24 px at zoom 1.0, twice its map length). fx.json splash.scale 'marker' (S5 sets it for itself) puts the splashes at the markers' scale too",
			"wind": "a 15:00 sea breeze toward the south (the gunfire board's), so spray and columns lean south",
			"decisions_in_force": "soft puffs as the default impact style (soft-puffs-default); no ink-mark indicators (no-ink-marks); gunfire family G3 (gunfire-looks); the land impacts are as decided (G3 dust for rounds, the B3 blast for shells and bombs); shadow strength 0.44"
		},
		"options": options,
		"recommendation": {
			"value": "S2",
			"_proposed": true,
			"_reason": "PROPOSED by builder BS: S2 keeps one grammar for everything in water (the same pale puffs for a tank round, a shell, a bomb and a sinking hull, sized by the round), at the map's true scale it is a fraction of today's rings, and it still reads at the planning zoom. S1 is the quietest but a tank round at zoom 0.35 is a few pixels; S3 adds the wash and the ring, which is a second thing to read for little; S4's column is the nicest for a bomb but shells and bombs are rare and Alex asked first for 'smaller and consistent'. S5 is the question to settle beside it: the same puffs at the markers' scale, which is the scale the G3 land dust is drawn at, so a round on water and a round on land match; if S2 reads too small next to the dust, S5 (or splash.scale 'marker') is the answer."
		},
		"how_to_switch": "data/fx/fx.json splash.mode (value 'S0' to 'S5'); splash.scale 'map' or 'marker'. Today's default stays S0 until Alex picks.",
		"chosen": null,
		"chosen_by": null,
	}
	_json("board.json", board)
	_json("frames.json", {"id": "splash", "about": "Every frame of the splash board as its own PNG at native size: <option>_<scene>_z<zoom>_<phase>.png are 1:1 crops of the game's frames (640 x 340 at zoom 1, 560 x 280 at zoom 0.35; the same crop for every option), context_* whole 1280 x 720 frames, palette_strip.png the colours. S0 is today.", "frames": _frames})

func _json(name: String, d: Dictionary) -> void:
	var f := FileAccess.open(out_dir.path_join(name), FileAccess.WRITE)
	if f == null:
		printerr("[splash] could not write ", name)
		_failures += 1
		return
	f.store_string(JSON.stringify(d, "  ", false) + "\n")
	f.close()
	print("[splash] wrote ", name)
