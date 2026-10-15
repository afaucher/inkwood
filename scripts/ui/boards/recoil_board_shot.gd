extends SceneTree

# BOARD: THE RECOIL (builder BR, 2026-10-14; backlog A5, decision tank-fire-feedback). WINDOWED ONLY.
#
#   .\tools\shot.ps1 -Script res://scripts/ui/boards/recoil_board_shot.gd -Out variants/recoil
#
# Alex (decision tank-fire-feedback): "The turret or the whole tank should have some visual feedback. Either the whole tank rocks back or just the turret." and
# "The turret feedback should also apply to the ship." The turret turns to its bearing and the G3 muzzle puff leaves the barrel's tip; what is missing is the recoil
# at the moment of the shot. This board films it: the game's own markers (scripts/ui/unit_marker.gd, scripts/ui/unit_marker_recoil.gd) in the running sandbox over seed
# 20261009 (variants/recoil/scenario.json, water on, fog off), a REAL turn resolved (a tank ordered to fire at an enemy tank, the cruiser's Main Guns at one on the
# shore), the playback held and stepped to the moments around the shot, photographed once per option with ONLY data/ui/ui.json unit_art.recoil.mode changed:
#
#   R0 none         today: nothing moves
#   R1 barrel       the barrel alone slides back along its axis (under the mantlet / the gun house) and returns
#   R2 turret       the whole turret kicks back along the barrel
#   R3 hull         the whole tank (the whole ship) shifts against the barrel's direction and settles
#   R4 turret_hull  the turret kick plus a smaller hull shift
#
# Two scenes x two zooms (1.0 and the start zoom 0.35), six moments around the shot (t = -0.1, 0, 0.05, 0.1, 0.2, 0.4 s; the ship adds 0.6 and 1.0 so the salvo
# is seen walking from turret to turret): the same seed, the same tank on the same road, the same bearing, the same ship, for every option. The camera, the
# crop and the moments are the same in every option.
#
# Output (out=): <option>_<scene>_z<zoom>_strip.png (one option's moments side by side, native size), <option>_strip.png (all of an option's scenes), compare_<scene>_z<zoom>.png
# (options as rows, moments as columns), compare_<scene>_z0.35_x3.png (the 0.35 grid enlarged 3x, nearest-neighbour, a loupe: the real size is the plain one),
# frames/<option>_<scene>_z<zoom>_t<ms>.png (every raw crop, 1:1), context_*.png (whole 1280 x 720 frames), board.json, frames.json.
#
# EVERY OPTION AND VALUE IS PROPOSED by builder BR; none is a decision.

const World = preload("res://scripts/sim/world.gd")
const Turret = preload("res://scripts/sim/turret.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const Recoil = preload("res://scripts/ui/unit_marker_recoil.gd")

const SEED := 20261009
const SCENARIO := "../../variants/recoil/scenario"
const CENTRE_SCREEN := Vector2(640.0, 360.0)   # where the filmed unit's centre is put on screen for every frame
const GAP := 10.0
const MARGIN := 22.0

const OPTIONS := [
	{"id": "r0_none", "letter": "R0", "mode": "none", "title": "Today: nothing moves"},
	{"id": "r1_barrel", "letter": "R1", "mode": "barrel", "title": "The barrel alone slides back"},
	{"id": "r2_turret", "letter": "R2", "mode": "turret", "title": "The whole turret kicks back"},
	{"id": "r3_hull", "letter": "R3", "mode": "hull", "title": "The whole tank rocks back"},
	{"id": "r4_turret_hull", "letter": "R4", "mode": "turret_hull", "title": "The turret kicks, the hull rocks a little"},
]

# Seconds before and after the shot. The ship's list is longer: its salvo walks along the turrets (0.4 s apart with two barrels each).
const TIMES_TANK := [-0.1, 0.0, 0.05, 0.1, 0.2, 0.4]
const TIMES_SHIP := [-0.1, 0.0, 0.05, 0.1, 0.2, 0.4, 0.6, 1.0]

# A scene: the unit filmed, its crop at each zoom (size and where the unit's centre falls in it).
const SCENES := [
	{"id": "tank", "title": "Tank on the village road", "unit": "tank_1", "times": "tank",
		"crops": {"1.0": {"size": Vector2i(130, 100), "at": Vector2i(64, 64)}, "0.35": {"size": Vector2i(70, 54), "at": Vector2i(30, 32)}}, "loupe": {"1.0": 3, "0.35": 4}},
	{"id": "cruiser", "title": "Cruiser off the east coast", "unit": "cruiser_1", "times": "ship",
		"crops": {"1.0": {"size": Vector2i(260, 560), "at": Vector2i(165, 280)}, "0.35": {"size": Vector2i(110, 210), "at": Vector2i(62, 105)}}, "loupe": {"1.0": 1, "0.35": 3}},
]
const ZOOMS := [1.0, 0.35]

var out_dir := "variants/recoil"
var scene: BoardScene = null
var style = null
var ui = null
var w = null
var failures := 0
var shot_t := {}                     # unit id -> the second of the turn its first shell / its shot leaves
var targets := {}                    # unit id -> the enemy it was ordered at
var crops: Dictionary = {}           # "<option>/<scene>/<zoom>/<k>" -> Image
var contexts: Dictionary = {}        # name -> Image
var measured: Dictionary = {}        # "<option>/<scene>/<zoom>" -> {...}
var rest_pos: Dictionary = {}        # scene id -> sprite positions at rest
var info: Dictionary = {}            # facts about the rig, for the sheet

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[recoil-board] ", msg)

func _fail(msg: String) -> void:
	failures += 1
	printerr("[recoil-board] FAIL ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d, scenario %s)..." % [SEED, SCENARIO])
	if not await scene.start(240.0, SCENARIO):
		printerr("[recoil-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	ui = scene.sb.ui
	w = scene.world()
	ui.hud.visible = false
	scene.sb.clock.visible = false
	ui.set_process_input(false)
	ui.selection.clear()
	style.ui["unit_art"]["recoil"]["mode"] = "none"
	style.ui["labels"]["enabled"] = false   # (a rig action: the speed label sits over the tank; the board is about the hull and the turret)
	if not _rig():
		quit(1)
		return
	ui.marker_layer.playback_paused = true
	w.commit("local")
	var res: Dictionary = w.resolve()
	if res.is_empty():
		_fail("the turn did not resolve: %s" % w.last_error)
		quit(1)
		return
	_find_shots(res)
	await scene.frames(4)
	if failures == 0:
		await _film()
		await _write()
	scene.shutdown()
	await scene.frames(2)
	quit(1 if failures > 0 else 0)

# --- the rig ---------------------------------------------------------------------------------------------

func _land(p: Vector2) -> bool:
	return w.water_depth_at(p.x, p.y) <= 0.0

# Stands the tank on the village road short of the river, facing along it, and orders its gun at an enemy tank 40 degrees to its right; stands the cruiser by the
# coast, nose north, the turrets trained 90 degrees to port on an enemy tank on the shore, and orders the Main Guns. Both turrets are on bearing at the start, so
# the shot leaves at its step's fire_at (the tank's second step, 2.5 s in; the cruiser's 0.5 s) and the traverse delays nothing.
func _rig() -> bool:
	var sc = scene.sb.scenario
	var at: Vector2 = sc.site_point("water.bridge", 0, 0.0, 0.0, true, -53.0)
	var hd: float = sc._road_heading_to_site("water.bridge", -53.0, "tank", true)
	var tank = w.units["tank_1"]
	tank.x = at.x
	tank.y = at.y
	tank.heading = hd
	tank.speed = 0.0
	var placed := false
	for off_deg: float in [40.0, 30.0, 50.0, -40.0]:
		for dist: float in [130.0, 110.0, 150.0, 90.0, 170.0]:
			var tgt := at + Vector2.from_angle(hd + deg_to_rad(off_deg)) * dist
			if not _land(tgt):
				continue
			var e = w.units["tank_e1"]
			e.x = tgt.x
			e.y = tgt.y
			e.heading = (at - tgt).angle()
			e.speed = 0.0
			tank.turret = Turret.rel_to(at, hd, tgt)
			w.clear_plan("tank_1")
			if w.plan_step("tank_1", 0, {"hold": true}).is_empty():
				continue
			if w.plan_step("tank_1", 1, {"hold": true, "fire": {"special": "tank_gun", "target": {"unit": "tank_e1"}}}).is_empty():
				continue
			targets["tank_1"] = "tank_e1"
			info["tank_bearing_deg"] = snappedf(rad_to_deg(tank.turret), 0.1)
			info["tank_range_m"] = snappedf(dist, 1.0)
			info["tank_at"] = at
			placed = true
			break
		if placed:
			break
	if not placed:
		_fail("no place found for the enemy tank that the tank may fire at (%s)" % w.last_error)
		return false
	# the cruiser
	var ship = w.units["cruiser_1"]
	var s_at := Vector2(3594.0, 1300.0)
	ship.x = s_at.x
	ship.y = s_at.y
	ship.heading = -PI / 2.0
	ship.speed = 0.0
	placed = false
	for dist: float in [420.0, 380.0, 460.0, 340.0, 500.0, 300.0, 550.0, 600.0]:
		for dy: float in [0.0, -60.0, 60.0, -120.0, 120.0]:
			var tgt := s_at + Vector2(-dist, dy)
			if not _land(tgt):
				continue
			var e2 = w.units["tank_e2"]
			e2.x = tgt.x
			e2.y = tgt.y
			e2.heading = 0.0
			e2.speed = 0.0
			ship.turret = Turret.rel_to(s_at, ship.heading, tgt)
			w.clear_plan("cruiser_1")
			if w.plan_step("cruiser_1", 0, {"hold": true, "fire": {"special": "main_guns", "target": {"unit": "tank_e2"}}}).is_empty():
				continue
			targets["cruiser_1"] = "tank_e2"
			info["ship_bearing_deg"] = snappedf(rad_to_deg(ship.turret), 0.1)
			info["ship_range_m"] = snappedf(Vector2(-dist, dy).length(), 1.0)
			info["ship_at"] = s_at
			placed = true
			break
		if placed:
			break
	if not placed:
		_fail("no shore tank found that the cruiser may fire at (%s)" % w.last_error)
		return false
	ui.marker_layer.sync_units()
	_say("tank at %s heading %.2f, turret %.1f deg, target %.0f m; cruiser at %s, turrets %.1f deg, target %.0f m" % [str(at.round()), hd, info["tank_bearing_deg"], info["tank_range_m"], str(s_at), info["ship_bearing_deg"], info["ship_range_m"]])
	return true

func _find_shots(res: Dictionary) -> void:
	for ev: Dictionary in res.get("events", []):
		var kind := str(ev.get("type", ""))
		var id := str(ev.get("unit", ""))
		if kind == "fire" and id == "tank_1" and ev.has("bearing") and not shot_t.has(id):
			shot_t[id] = float(ev["t"])
		elif kind == "shell_fire" and id == "cruiser_1" and not shot_t.has(id):
			shot_t[id] = float(ev["t"])
			info["shells"] = int(ev.get("shells", 0))
	for id: String in ["tank_1", "cruiser_1"]:
		if not shot_t.has(id):
			_fail("%s fired nothing in the turn (%s)" % [id, str(res.get("events", [])).substr(0, 300)])
	_say("shots: %s" % str(shot_t))

# --- the film ---------------------------------------------------------------------------------------------

func _times(sc: Dictionary) -> Array:
	return TIMES_TANK if str(sc["times"]) == "tank" else TIMES_SHIP

func _unit_world(id: String) -> Vector2:
	return Vector2(float(w.units[id].x), float(w.units[id].y))

func _film() -> void:
	for sc: Dictionary in SCENES:
		var id := str(sc["unit"])
		var centre := _unit_world(id)
		for z: float in ZOOMS:
			var zk := "%.1f" % z if z >= 1.0 else "%.2f" % z
			await scene.look(centre, CENTRE_SCREEN, z)
			var settle_s: float = await scene.settle()
			_say("%s zoom %s baked in %.1f s" % [str(sc["id"]), zk, settle_s])
			var cs: Dictionary = (sc["crops"] as Dictionary)[("1.0" if z >= 1.0 else "0.35")]
			var t_shot: float = shot_t[id]
			for o: Dictionary in OPTIONS:
				style.ui["unit_art"]["recoil"]["mode"] = str(o["mode"])
				ui.marker_layer.refresh_art()
				ui.marker_layer.set_playback_time(maxf(t_shot - 0.6, 0.0))
				await scene.frames(4)
				var times: Array = _times(sc)
				var mk = ui.marker_layer.marker(id)
				var m := {"peak_px": {"hull": 0.0, "turret": 0.0, "barrel": 0.0}, "barrel_part": false}
				for k in times.size():
					var tt: float = t_shot + float(times[k])
					ui.marker_layer.set_playback_time(tt)
					await scene.frames(3)
					var img: Image = await scene.grab()
					crops["%s/%s/%s/%d" % [str(o["id"]), str(sc["id"]), zk, k]] = _crop(img, centre, cs)
					_measure(mk, sc, m)
					if str(o["mode"]) == "none" and k == 1 and zk == "1.0":
						contexts["context_%s_z%s_r0.png" % [str(sc["id"]), zk]] = img
					if str(o["mode"]) == "turret_hull" and k == 2 and zk == "1.0":
						contexts["context_%s_z%s_r4.png" % [str(sc["id"]), zk]] = img
				measured["%s/%s/%s" % [str(o["id"]), str(sc["id"]), zk]] = m
	style.ui["unit_art"]["recoil"]["mode"] = "none"
	ui.marker_layer.refresh_art()

func _crop(img: Image, centre: Vector2, cs: Dictionary) -> Image:
	var a: Vector2 = scene.sb.map_view.world_to_screen(centre)
	var size: Vector2i = cs["size"]
	var at: Vector2i = cs["at"]
	var o := Vector2i(roundi(a.x), roundi(a.y)) - at
	return img.get_region(Rect2i(o, size))

# What moved, in screen px from the unit's resting positions (the marker's own sprite positions): the largest the hull, the turret and the barrel got.
func _measure(mk: Node, sc: Dictionary, m: Dictionary) -> void:
	var key := str(sc["id"])
	var pos := {"plane": mk.plane.position, "turrets": [], "barrels": []}
	for s: Variant in mk._turret_sprites:
		(pos["turrets"] as Array).append((s as Sprite2D).position)
	for s: Variant in mk._barrel_sprites:
		(pos["barrels"] as Array).append((s as Sprite2D).position)
	m["barrel_part"] = bool(m["barrel_part"]) or (mk.art != null and not mk.art.turret_parts.is_empty() and (mk.art.turret_parts[0] as Dictionary).get("barrel_tex") != null)
	var pk: Dictionary = m["peak_px"]
	# the hull's kick is the plane sprite's position (it is at 0 at rest); the turret's is its position less the hull's and less where it stands on the hull; the barrel's, less the turret's
	var hull: Vector2 = pos["plane"]
	pk["hull"] = maxf(float(pk["hull"]), hull.length())
	if mk.art != null:
		var sc_px: float = mk.screen_ppm * style.num("marker.true_scale") * mk.draw_scale
		for i in (pos["turrets"] as Array).size():
			var part: Dictionary = mk.art.turret_parts[i]
			var rest := ((part["pivot_m"] as Vector2) * sc_px).rotated(mk.screen_heading + PI / 2.0)
			var tpos: Vector2 = (pos["turrets"] as Array)[i] - hull - rest
			pk["turret"] = maxf(float(pk["turret"]), tpos.length())
			if i < (pos["barrels"] as Array).size() and (mk._barrel_sprites[i] as Sprite2D).visible:
				var bpos: Vector2 = (pos["barrels"] as Array)[i] - (pos["turrets"] as Array)[i]
				pk["barrel"] = maxf(float(pk["barrel"]), bpos.length())

# --- the sheets ---------------------------------------------------------------------------------------------

func _tl(t: float) -> String:
	return "t = %+.2f s" % t if t != 0.0 else "t = 0 (the shot)"

func _zk(z: float) -> String:
	return "%.1f" % z if z >= 1.0 else "%.2f" % z

func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	if err != OK:
		_fail("could not write %s: %s" % [path, error_string(err)])

# The enlargement of a crop in the strips and in the extra grids (nearest-neighbour, a loupe; the plain crops are kept): a tank is 24 px long at zoom 1 and 8 px at 0.35.
func _loupe_of(sc: Dictionary, z: float) -> int:
	return int((sc["loupe"] as Dictionary).get("1.0" if z >= 1.0 else "0.35", 1))

func _loupe(img: Image, n: int) -> Image:
	var c := img.duplicate() as Image
	c.resize(img.get_width() * n, img.get_height() * n, Image.INTERPOLATE_NEAREST)
	return c

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base.path_join("frames"))
	var frames: Array = []
	var records: Array = []
	# raw crops
	for sc: Dictionary in SCENES:
		var times: Array = _times(sc)
		for z: float in ZOOMS:
			for o: Dictionary in OPTIONS:
				for k in times.size():
					var img: Image = crops["%s/%s/%s/%d" % [str(o["id"]), str(sc["id"]), _zk(z), k]]
					_save(img, base.path_join("frames").path_join("%s_%s_z%s_t%+04d.png" % [str(o["id"]), str(sc["id"]), _zk(z), roundi(float(times[k]) * 1000.0)]))
	# the strips: one option, one scene, one zoom: the moments side by side
	var strip_files := {}   # option id -> Array of [scene, zoom, Image]
	for o: Dictionary in OPTIONS:
		strip_files[str(o["id"])] = []
		for sc: Dictionary in SCENES:
			var times: Array = _times(sc)
			for z: float in ZOOMS:
				var cs: Dictionary = (sc["crops"] as Dictionary)[("1.0" if z >= 1.0 else "0.35")]
				var sz: Vector2i = cs["size"]
				var scale_up := _loupe_of(sc, z)
				var cw := sz.x * scale_up
				var ch := sz.y * scale_up
				var width := int(MARGIN * 2.0 + (cw + GAP) * float(times.size()) - GAP)
				var height := int(64.0 + ch + 30.0)
				var sh := BoardSheet.new(style, Vector2i(width, height))
				sh.text(Vector2(MARGIN, 26), "%s  ·  %s  ·  %s  ·  zoom %s%s" % [o["letter"], o["title"], sc["title"], _zk(z), ("  ·  enlarged %dx (a loupe)" % scale_up) if scale_up > 1 else "  ·  1:1"], 15.0, sh.c_text)
				sh.text(Vector2(MARGIN, 46), "unit_art.recoil.mode = %s   ·   the same seed, camera and crop in every option" % o["mode"], 11.0, sh.c_muted, true)
				var strip_img := Image.create(int((cw + GAP) * float(times.size()) - GAP), ch, false, Image.FORMAT_RGBA8)
				for k in times.size():
					var img: Image = crops["%s/%s/%s/%d" % [str(o["id"]), str(sc["id"]), _zk(z), k]]
					var show: Image = _loupe(img, scale_up) if scale_up > 1 else img
					var x := MARGIN + (float(cw) + GAP) * float(k)
					sh.image(show, Vector2(x, 64.0))
					sh.text(Vector2(x, 64.0 + ch + 18.0), _tl(float(times[k])), 11.0, sh.c_muted, true)
					strip_img.blit_rect(show, Rect2i(0, 0, show.get_width(), show.get_height()), Vector2i(k * (cw + int(GAP)), 0))
				var f := "%s_%s_z%s_strip.png" % [str(o["id"]), str(sc["id"]), _zk(z)]
				var err: int = await sh.save(self, base.path_join(f))
				if err != OK:
					_fail("could not write %s" % f)
				frames.append({"file": f, "option": o["letter"], "title": "%s  ·  %s  ·  zoom %s" % [o["letter"], sc["title"], _zk(z)],
					"caption": "%s: %s, zoom %s, %d moments around the shot (%s)%s. Crops of the game's own frames." % [o["title"], sc["title"], _zk(z), times.size(), ", ".join(times.map(func(t: float) -> String: return "%+.2f" % t)), ("; enlarged %dx with nearest-neighbour as a loupe, the plain size is in frames/ and in the compare_ grids" % scale_up) if scale_up > 1 else "; 1:1, native size"],
					"scene": str(sc["id"]), "zoom": z, "moments_s": times, "size": [width, height]})
				(strip_files[str(o["id"])] as Array).append([sc, z, strip_img])
	# the grids: options as rows, moments as columns, per scene and zoom
	for sc: Dictionary in SCENES:
		var times: Array = _times(sc)
		for z: float in ZOOMS:
			for scale_up: int in ([1, _loupe_of(sc, z)] if _loupe_of(sc, z) > 1 else [1]):
				var cs: Dictionary = (sc["crops"] as Dictionary)[("1.0" if z >= 1.0 else "0.35")]
				var sz: Vector2i = cs["size"]
				var cw := sz.x * scale_up
				var ch := sz.y * scale_up
				var head := 64.0
				var label_w := 190.0
				var width := int(MARGIN + label_w + (cw + GAP) * float(times.size()) + MARGIN - GAP)
				var row_h := float(ch) + 34.0
				var height := int(head + row_h * float(OPTIONS.size()) + 24.0)
				var sh := BoardSheet.new(style, Vector2i(width, height))
				sh.text(Vector2(MARGIN, 26), "The recoil  ·  %s  ·  zoom %s%s" % [sc["title"], _zk(z), ("  ·  enlarged %dx (a loupe)" % scale_up) if scale_up > 1 else "  ·  1:1, native size"], 16.0, sh.c_text)
				sh.text(Vector2(MARGIN, 46), "rows are the options (unit_art.recoil.mode), columns are the moments around the shot; the same seed, camera and crop in every cell", 11.0, sh.c_muted, true)
				for oi in OPTIONS.size():
					var o: Dictionary = OPTIONS[oi]
					var y := head + row_h * float(oi)
					sh.line(Vector2(MARGIN, y - 4.0), Vector2(float(width) - MARGIN, y - 4.0), sh.c_rule, 1.0)
					sh.text(Vector2(MARGIN, y + 16.0), str(o["letter"]), 18.0, sh.c_text)
					sh.paragraph(Vector2(MARGIN, y + 36.0), str(o["title"]), 11.5, sh.c_muted, label_w - 14.0, true)
					for k in times.size():
						var img: Image = crops["%s/%s/%s/%d" % [str(o["id"]), str(sc["id"]), _zk(z), k]]
						var show: Image = _loupe(img, scale_up) if scale_up > 1 else img
						var x := MARGIN + label_w + (float(cw) + GAP) * float(k)
						sh.image(show, Vector2(x, y))
						if oi == 0 or true:
							sh.text(Vector2(x + 3.0, y + float(ch) + 14.0), _tl(float(times[k])), 10.0, sh.c_muted, true)
				var f := "compare_%s_z%s%s.png" % [str(sc["id"]), _zk(z), "_x%d" % scale_up if scale_up > 1 else ""]
				var err: int = await sh.save(self, base.path_join(f))
				if err != OK:
					_fail("could not write %s" % f)
				frames.append({"file": f, "option": "all", "title": "all options  ·  %s  ·  zoom %s%s" % [sc["title"], _zk(z), " (loupe %dx)" % scale_up if scale_up > 1 else ""],
					"caption": "The five options as rows and the moments around the shot as columns, %s, zoom %s%s." % [sc["title"], _zk(z), "; enlarged %dx with nearest-neighbour" % scale_up if scale_up > 1 else ", native size"],
					"scene": str(sc["id"]), "zoom": z, "moments_s": times, "size": [width, height]})
	# the per-option contact strip: all of an option's scenes and zooms in one picture
	for o: Dictionary in OPTIONS:
		var items: Array = strip_files[str(o["id"])]
		var wmax := 0
		var htot := 70
		for it: Array in items:
			var im: Image = it[2]
			wmax = maxi(wmax, im.get_width())
			htot += im.get_height() + 30
		var sh := BoardSheet.new(style, Vector2i(int(MARGIN * 2.0) + wmax, htot))
		sh.text(Vector2(MARGIN, 28), "%s  ·  %s  ·  a contact strip, every scene and zoom" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(MARGIN, 50), "unit_art.recoil.mode = %s   ·   moments left to right: the shot is the second frame; rows that say so are enlarged (a loupe, nearest-neighbour), the others are 1:1" % [o["mode"]], 11.0, sh.c_muted, true)
		var yy := 70.0
		for it: Array in items:
			var sc2: Dictionary = it[0]
			var z2: float = it[1]
			var im2: Image = it[2]
			sh.text(Vector2(MARGIN, yy + 14.0), "%s  ·  zoom %s" % [sc2["title"], _zk(z2)], 12.0, sh.c_muted, true)
			sh.image(im2, Vector2(MARGIN, yy + 22.0))
			yy += float(im2.get_height()) + 30.0
		var f2 := "%s_strip.png" % str(o["id"])
		var err2: int = await sh.save(self, base.path_join(f2))
		if err2 != OK:
			_fail("could not write %s" % f2)
		frames.append({"file": f2, "option": o["letter"], "title": "%s  ·  contact strip" % o["letter"], "caption": "%s: all scenes and zooms in one picture" % o["title"],
			"scene": "all", "zoom": 0, "size": [int(MARGIN * 2.0) + wmax, htot]})
		records.append(_record(o))
	for key: String in contexts:
		_save(contexts[key], base.path_join(key))
		frames.append({"file": key, "option": "R0" if key.ends_with("r0.png") else "R4", "title": "context: " + key.get_basename(), "caption": "The whole 1280 x 720 frame at the moment of the shot", "scene": key.split("_")[1], "zoom": float(key.split("_z")[1].split("_")[0]), "size": [1280, 720]})
	_write_json(base.path_join("board.json"), records)
	_write_frames(base.path_join("frames.json"), frames)
	_say("wrote %d frame entries" % frames.size())

# --- the records ---------------------------------------------------------------------------------------------

func _spec_text(o: Dictionary) -> String:
	var parts: Array = []
	for kind: String in ["tank", "ship"]:
		var spec: Dictionary = Recoil.spec(style, kind, str(o["mode"]))
		var bits: Array = []
		for part: String in spec:
			var r: Dictionary = spec[part]
			bits.append("%s %s m, %s s in, %s s back" % [part, String.num(float(r["m"]), 2), String.num(float(r["attack_s"]), 2), String.num(float(r["return_s"]), 2)])
		if not bits.is_empty():
			parts.append("%s: %s" % [kind, "; ".join(bits)])
	return " | ".join(parts) if not parts.is_empty() else "nothing moves"

func _record(o: Dictionary) -> Dictionary:
	var params := {}
	for kind: String in ["tank", "ship"]:
		var spec: Variant = style.lookup("unit_art.recoil.%s.modes.%s" % [kind, str(o["mode"])])
		if spec is Dictionary:
			params[kind] = (spec as Dictionary).duplicate(true)
	var pk := {}
	for sc: Dictionary in SCENES:
		for z: float in ZOOMS:
			var m: Dictionary = measured.get("%s/%s/%s" % [str(o["id"]), str(sc["id"]), _zk(z)], {})
			if not m.is_empty():
				var pp: Dictionary = (m["peak_px"] as Dictionary).duplicate()
				for k: String in pp:
					pp[k] = snappedf(float(pp[k]), 0.01)
				pk["%s/z%s" % [str(sc["id"]), _zk(z)]] = pp
	return {"name": o["letter"], "title": o["title"], "unit_art.recoil.mode": o["mode"], "description": _describe(o), "file": "%s_strip.png" % str(o["id"]), "proposed": true,
		"parameters": params, "measured_peak_px": pk}

func _describe(o: Dictionary) -> String:
	var mode := str(o["mode"])
	match mode:
		"none":
			return "Today: the turret turns, the G3 puff leaves the barrel's tip, and nothing else moves at the shot."
		"barrel":
			return "The barrel alone slides back along its axis, under the mantlet (the tank) or the gun house (the ship), fast out and slower back. Tank: %s. Ship: %s. Reads as a gun, not a vehicle." % [_one("tank", mode, "barrel"), _one("ship", mode, "barrel")]
		"turret":
			return "The whole turret (the gun with it) kicks back along the barrel's axis and returns. Tank: %s. Ship: %s, each turret at the moment its first shell leaves." % [_one("tank", mode, "turret"), _one("ship", mode, "turret")]
		"hull":
			return "The whole tank shifts against the barrel's direction (hull, turret and shadow together) and settles with one small swing past rest. Tank: %s. Ship: %s, a rock you can barely see, as a 120 m hull would give." % [_one("tank", mode, "hull"), _one("ship", mode, "hull")]
		"turret_hull":
			return "R2's turret kick with a smaller hull shift: the gun jumps and the tank takes the push. Tank: %s, %s. Ship: %s, %s." % [_one("tank", mode, "turret"), _one("tank", mode, "hull"), _one("ship", mode, "turret"), _one("ship", mode, "hull")]
	return ""

func _one(kind: String, mode: String, part: String) -> String:
	var rec: Variant = style.lookup("unit_art.recoil.%s.modes.%s.%s" % [kind, mode, part])
	if rec is Dictionary:
		return "%s %s m (%s s out, %s s back)" % [part, String.num(float(rec["m"]), 2), String.num(float(rec["attack_s"]), 2), String.num(float(rec["return_s"]), 2)]
	return part

func _write_json(path: String, records: Array) -> void:
	var doc := {
		"id": "recoil",
		"date": "2026-10-14",
		"area": "UI",
		"question": "What does the drawn tank (and the ship) do at the moment of a shot? Alex (decision tank-fire-feedback): 'The turret or the whole tank should have some visual feedback. Either the whole tank rocks back or just the turret.' and 'The turret feedback should also apply to the ship.'",
		"source": "scripts/ui/boards/recoil_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map, scenario variants/recoil/scenario.json (seed 20261009, water on, fog off), the game's own markers (scripts/ui/unit_marker.gd, scripts/ui/unit_marker_recoil.gd) playing a REAL resolved turn held and stepped to the moments around the shot, photographed once per option with ONLY data/ui/ui.json unit_art.recoil.mode changed",
		"seed": SEED,
		"held_constant": {
			"tank": "tank_1 of side_a (brick red) on the village road 53 m short of the bridge, hull standing still (a hold step), turret 40 degrees to the right of the nose, ordered 'Turret Fire' on an enemy tank %s m away: the turret is on bearing at the start of the turn's second step, so the shot leaves at %.2f s into the turn" % [str(info.get("tank_range_m", "?")), float(shot_t.get("tank_1", 0.0))],
			"ship": "cruiser_1 at (3594, 1300) off the east coast, nose north, standing still, all its turrets trained %s degrees (to port) on an enemy tank on the shore %s m away, ordered 'Main Guns Fire': a salvo of %s shells 0.2 s apart, the first leaving at %.2f s into the turn" % [str(info.get("ship_bearing_deg", "?")), str(info.get("ship_range_m", "?")), str(info.get("shells", "?")), float(shot_t.get("cruiser_1", 0.0))],
			"moments": {"tank": TIMES_TANK, "cruiser": TIMES_SHIP, "_about": "seconds from the shot (the first shell of the salvo). Playback seconds are game seconds; marker.playback_speed is 1, so they are real seconds in the game"},
			"zooms": {"zoom_1": "camera zoom 1.0 (units are drawn at 4 px per metre)", "start_zoom": "camera zoom 0.35 (data/view/camera.json zoom.start; 1.4 px per metre)"},
			"labels": "the unit speed labels are switched off for the board (a rig action; labels.enabled): the label sits over the tank",
			"smoke": "the G3 soft puff leaves the barrel's tip at the shot (gunfire-looks, decision soft-puffs-default); unchanged by the recoil",
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red (allies) and slate blue (axis); soft puffs as the default impact and muzzle style",
		},
		"parameter": "data/ui/ui.json#unit_art.recoil.mode (none | barrel | turret | hull | turret_hull); the numbers are unit_art.recoil.<tank|ship>.modes.<mode>.<barrel|turret|hull> {m, attack_s, return_s, settle} and unit_art.recoil.<kind>.min_px. The kicks are metres of the DRAWN unit (4 px a metre at zoom 1) with a floor in screen px so that they still read at zoom 0.35",
		"options": records,
		"palette_check": {
			"hue": "No option adds a colour: the recoil MOVES existing linework (the barrel, the turret, the hull and their shadows); no role is added, no hex is written. The palette on the page is the one the moving things are drawn in.",
			"lightness": "Unchanged: the ramp off the paper (the art's cream fill, its shaded fill, the ink) and the shadow's 0.44 strength; a part that moves casts its shadow with it.",
			"material": "Linework and motion. The feedback comes from the thing itself (decision no-ink-marks): no symbol is drawn.",
		},
		"recommendation_proposed": _recommendation(),
		"how_to_switch": "data/ui/ui.json unit_art.recoil.mode (default none). Then re-bake (restart): R1 makes the art carry the barrels as parts.",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()

func _recommendation() -> String:
	return "R2, the whole turret kicks back along the barrel (PROPOSED by builder BR; Alex decides). It is the one grammar that says the same thing for the tank and the ship: Alex's own two sentences ('just the turret', 'the turret feedback should also apply to the ship') and the thing the sim already turns, so the ship's turrets kick one after another as their shells leave and the tank's turret kicks once. It reads at both zooms (0.55 m is 2.2 px at zoom 1; the floor holds it at 1.6 px at 0.35) and moves a drawn part that already exists, so it costs no extra art and changes no outline. R1 (the barrel alone) is the most like a real gun but the smallest mark: 3.6 px on a tank at zoom 1 and about 1.6 px at 0.35, and its art carries the barrels as separate sprites. R3 (the whole tank) is the clearest on a 24 px tank but, on the ship, a 120 m hull that shifts by a pixel or two reads as a glitch (the board keeps it at 0.3 m with a long settle), so the ship would want R2 anyway. R4 is R2 with a little hull push: the one to take if R2 feels too small in play. The kicks are in data and cheap to retune; the stills are subtle by nature, and the real test is to set unit_art.recoil.mode in data/ui/ui.json and play Hold the bridge."

func _write_frames(path: String, frames: Array) -> void:
	var doc := {
		"id": "recoil",
		"about": "The recoil board. compare_<scene>_z<zoom>.png: options as rows, the moments around the shot as columns, native size (the 0.35 grids also as _x3 loupes); <option>_<scene>_z<zoom>_strip.png: one option's moments side by side (the 0.35 strips enlarged 3x with nearest-neighbour; the plain 1:1 crops are in frames/); <option>_strip.png: all of an option's scenes and zooms in one picture; frames/<option>_<scene>_z<zoom>_t<ms>.png: every raw crop at 1:1; context_*.png: whole 1280 x 720 frames.",
		"frames": frames,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
