extends "res://scripts/test_support/test_case.gd"

# THE RECOIL (builder BR, board 'recoil', 2026-10-14; backlog A5; Alex, decision tank-fire-feedback: "The turret or the whole tank should have some visual feedback.
# Either the whole tank rocks back or just the turret." and "The turret feedback should also apply to the ship."). Every number is PROPOSED (data/ui/ui.json
# unit_art.recoil); the default mode is none (nothing moves, today's look). Headless: the sprites are fake textures, the drawing is the board's business.
#
#   1. THE DATA     the mode in force is none; every other mode names parts with a positive kick, attack and return for the tank and the ship
#   2. THE CURVE    nothing before the shot, the full kick at attack_s, back to rest at attack_s + return_s, a settle passes rest once and stays small
#   3. THE SHOTS    the layer collects the tank's ordered shot and the cruiser's salvo from the turn's events, with their seconds
#   4. THE MARKER   none: no sprite moves, shot or not. barrel / turret / hull / turret_hull: the part moves back along the turret's bearing by the kick (floored
#                   at min_px), the others as the mode says; a salvo recoils turret by turret at the moment each one's first shell leaves; no turn playing: rest

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const Recoil = preload("res://scripts/ui/unit_marker_recoil.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")

const MODES := ["barrel", "turret", "hull", "turret_hull"]
const PPM := 3.8

var _st: UiStyle
var _done := 0

func setup(_main) -> void:
	timeout_seconds = 60.0
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	for part: Script in [World, UnitUI, TankWorlds, GunWorlds, Recoil]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_data()
	_curve()
	_tank()
	_ship()
	_st.ui["unit_art"]["recoil"]["mode"] = "none"
	eq(_done, 4, "the test reached its last section (a runtime error would have ended it silently)")
	finish()

# --- 1. The data -----------------------------------------------------------------------------------------------------

func _data() -> void:
	eq(Recoil.mode_of(_st), "none", "1. the default mode is none: today's look, nothing moves")
	check(not Recoil.wants_barrel(_st), "1. and the art carries no barrel parts")
	for kind: String in Recoil.KINDS:
		check(Recoil.min_px(_st, kind) > 0.0, "1. %s: a floor in px so that a kick reads at zoom 0.35" % kind)
		for mode: String in MODES:
			var spec: Dictionary = Recoil.spec(_st, kind, mode)
			check(not spec.is_empty(), "1. %s / %s: a record" % [kind, mode])
			for part: String in spec:
				check(Recoil.PARTS.has(part), "1. %s / %s: '%s' is a part the marker moves" % [kind, mode, part])
				var rec: Dictionary = spec[part]
				check(float(rec["m"]) > 0.0 and float(rec["attack_s"]) > 0.0 and float(rec["return_s"]) > float(rec["attack_s"]), "1. %s / %s / %s: kick, attack and return" % [kind, mode, part])
		check(Recoil.spec(_st, kind, "none").is_empty(), "1. %s / none: nothing" % kind)
		check(Recoil.spec(_st, kind, "no_such_mode").is_empty(), "1. %s / an unknown mode: nothing" % kind)
	check(Recoil.spec(_st, "tank", "barrel").has("barrel") and not Recoil.spec(_st, "tank", "turret").has("barrel"), "1. only the barrel mode moves the barrel on its own")
	check(Recoil.spec(_st, "tank", "turret_hull").has("turret") and Recoil.spec(_st, "tank", "turret_hull").has("hull"), "1. turret_hull moves the turret and the hull")
	_st.ui["unit_art"]["recoil"]["mode"] = "barrel"
	check(Recoil.wants_barrel(_st), "1. in barrel mode the art carries the barrels as parts")
	_st.ui["unit_art"]["recoil"]["mode"] = "none"
	_done += 1

# --- 2. The curve -----------------------------------------------------------------------------------------------------

func _curve() -> void:
	var p := {"m": 1.0, "attack_s": 0.05, "return_s": 0.4, "settle": 0.0}
	near(Recoil.kick(-0.01, p), 0.0, 1e-12, "2. nothing before the shot")
	near(Recoil.kick(0.0, p), 0.0, 1e-12, "2. nothing at the instant of the shot")
	near(Recoil.kick(0.05, p), 1.0, 1e-12, "2. the full kick at attack_s")
	check(Recoil.kick(0.025, p) > 0.5, "2. a fast rise (eased out: past half way in half the attack)")
	var prev := 1.0
	var monotone := true
	for i in range(1, 41):
		var k := Recoil.kick(0.05 + 0.4 * float(i) / 40.0, p)
		if k > prev + 1e-12:
			monotone = false
		prev = k
	check(monotone, "2. the return only falls")
	near(Recoil.kick(0.45, p), 0.0, 1e-12, "2. back to rest at attack_s + return_s")
	near(Recoil.kick(5.0, p), 0.0, 1e-12, "2. and at rest after")
	check(Recoil.kick(0.05 + 0.4 * 0.5, p) > 0.4 and Recoil.kick(0.05 + 0.4 * 0.5, p) < 0.6, "2. half way back at the half of the return")
	var s := {"m": 1.0, "attack_s": 0.05, "return_s": 0.4, "settle": 1.0}
	var lo := 0.0
	for i in range(0, 101):
		lo = minf(lo, Recoil.kick(0.05 + 0.4 * float(i) / 100.0, s))
	check(lo < -0.05 and lo > -0.35, "2. a settle passes rest once and stays small (lowest %.3f)" % lo)
	near(Recoil.kick(0.45, s), 0.0, 1e-9, "2. and ends at rest")
	# a salvo
	var shot := {"t": 0.5, "salvo": 6, "interval": 0.2}
	near(Recoil.shot_time(shot, 0, 2), 0.5, 1e-12, "2. a salvo's first turret kicks as the first shell leaves")
	near(Recoil.shot_time(shot, 1, 2), 0.9, 1e-12, "2. the second turret, two barrels later (0.4 s)")
	near(Recoil.shot_time(shot, 2, 2), 1.3, 1e-12, "2. the third")
	near(Recoil.shot_time(shot, 3, 2), -1.0, 1e-12, "2. a fourth turret has no shell in a salvo of six from two barrels each: it fires nothing")
	near(Recoil.shot_time({"t": 2.5}, 0, 1), 2.5, 1e-12, "2. a single shot is its own second")
	near(Recoil.px({"m": 0.7}, 4.0, 1.6, 1.0), 2.8, 1e-9, "2. 0.7 m at 4 px a metre is 2.8 px")
	near(Recoil.px({"m": 0.7}, 1.4, 1.6, 1.0), 1.6, 1e-9, "2. and at zoom 0.35 the floor holds it at 1.6 px")
	near(Recoil.px({"m": 0.7}, 4.0, 1.6, 0.5), 1.4, 1e-9, "2. the factor scales it")
	_done += 1

# --- 3 and 4. The marker ------------------------------------------------------------------------------------------------

# A fake Art with parts, for a marker that cannot bake (headless): `n` turrets (the first n_fwd drawn forward, the rest aft), each with a barrel.
func _fake_art(k: float, n: int, n_fwd: int) -> UnitMarkerArt.Art:
	var a := UnitMarkerArt.Art.new()
	a.ppm = PPM * k
	a.extent_m = 4.0
	a.origin = Vector2(8, 8)
	a.size_px = Vector2i(16, 16)
	var img := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	a.texture = ImageTexture.create_from_image(img)
	a.mask = a.texture
	a.hull_texture = a.texture
	a.hull_mask = a.texture
	for i in n:
		a.turret_parts.append({"tex": a.texture, "mask": null, "barrel_tex": a.texture, "barrel_mask": null, "origin": Vector2(8, 8),
			"pivot_m": Vector2(0.0, -1.0 if i < n_fwd else 1.0), "built_rel": 0.0 if i < n_fwd else PI})
	return a

# Every sprite position of a marker, to compare: the plane's, each turret's and each barrel's.
func _positions(mk: Node) -> Dictionary:
	var turrets: Array = []
	var barrels: Array = []
	for s: Variant in mk._turret_sprites:
		turrets.append((s as Sprite2D).position)
	for s: Variant in mk._barrel_sprites:
		barrels.append((s as Sprite2D).position)
	return {"plane": mk.plane.position, "turrets": turrets, "barrels": barrels}

func _at(ui: Node, mk: Node, t: float, mode: String) -> Dictionary:
	_st.ui["unit_art"]["recoil"]["mode"] = mode
	ui.marker_layer.set_playback_time(t)
	return _positions(mk)

func _tank() -> void:
	var a_at := TankWorlds.road(140)
	var b_at := TankWorlds.road(160)
	var w := TankWorlds.world("allies", false)
	w.rng_seed = 3
	TankWorlds.tank(w, "a", "allies", "player", a_at, (b_at - a_at).angle() + deg_to_rad(40.0), 0.0)
	TankWorlds.tank(w, "b", "axis", "player", b_at, (a_at - b_at).angle(), 0.0)
	var origin := a_at - Vector2(100.0, 100.0)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM), "local")
	ui.marker_layer.playback_paused = true
	(w.units["a"] as Object).turret = -deg_to_rad(40.0)   # on bearing at once
	TankWorlds.order_fire(w, "a", "b")
	w.commit("local")
	var res := w.resolve()
	var fires := TankWorlds.fires(res, "a", "b")
	if not check(fires.size() == 1, "3. the tank's ordered shot fired"):
		return
	var shots: Array = ui.marker_layer._shots.get("a", [])
	if not check(shots.size() == 1, "3. the layer collected one shot of the tank"):
		return
	near(float(shots[0]["t"]), float(fires[0]["t"]), 1e-12, "3. at the second the event says (%.2f)" % float(fires[0]["t"]))
	eq(int(shots[0]["salvo"]), 0, "3. a single shot")
	check(not ui.marker_layer._shots.has("b"), "3. the other tank fired nothing and has no shots")
	var mk = ui.marker_layer.marker("a")
	var k: float = _st.num("marker.true_scale") * mk.draw_scale
	mk.art = _fake_art(k, 1, 1)
	var t0 := float(shots[0]["t"])
	var rest := _at(ui, mk, t0 - 0.2, "none")
	# 4. none: nothing moves
	for t: float in [t0 - 0.1, t0 + 0.02, t0 + 0.05, t0 + 0.2, t0 + 0.5]:
		var p := _at(ui, mk, t, "none")
		check(str(p) == str(rest), "4. mode none, t = shot %+.2f: no sprite moves" % (t - t0))
	# back along the barrel: the turret's screen bearing is the line from a to b
	var back: Vector2 = (a_at - b_at).normalized()
	var px_m: float = PPM * k
	for mode: String in MODES:
		var spec: Dictionary = Recoil.spec(_st, "tank", mode)
		var before := _at(ui, mk, t0 - 0.1, mode)
		check(str(before) == str(rest), "4. %s: nothing moves before the shot" % mode)
		var rec: Dictionary = {}
		for part: String in spec:
			rec[part] = spec[part]
		var attack := 1.0
		for part: String in spec:
			attack = minf(attack, float((spec[part] as Dictionary)["attack_s"]))
		var peak := _at(ui, mk, t0 + attack, mode)
		var hull_want := 0.0
		var turret_want := 0.0
		var barrel_want := 0.0
		var fl := Recoil.min_px(_st, "tank")
		if spec.has("hull"):
			hull_want = Recoil.px(spec["hull"], px_m, fl, Recoil.kick(attack, spec["hull"]))
		if spec.has("turret"):
			turret_want = Recoil.px(spec["turret"], px_m, fl, Recoil.kick(attack, spec["turret"]))
		if spec.has("barrel"):
			barrel_want = Recoil.px(spec["barrel"], px_m, fl, Recoil.kick(attack, spec["barrel"]))
		var dp: Vector2 = (peak["plane"] as Vector2) - (rest["plane"] as Vector2)
		var dt: Vector2 = (peak["turrets"][0] as Vector2) - (rest["turrets"][0] as Vector2)
		var db: Vector2 = (peak["barrels"][0] as Vector2) - (rest["barrels"][0] as Vector2)
		near(dp.length(), hull_want, 1e-3, "4. %s: the hull moves %.2f px" % [mode, hull_want])
		near(dt.length(), hull_want + turret_want if spec.has("turret") else hull_want, 0.6 if (spec.has("hull") and spec.has("turret")) else 1e-3, "4. %s: the turret moves with the hull and by its own kick" % mode)
		near(db.length(), (dt.length() + barrel_want) if barrel_want > 0.0 else dt.length(), 0.6, "4. %s: the barrel moves with the turret and by its own kick (%.2f px)" % [mode, barrel_want])
		var moved: Vector2 = db if barrel_want > 0.0 else (dt if turret_want > 0.0 else dp)
		check(moved.length() > 0.0 and moved.normalized().dot(back) > 0.999, "4. %s: back along the turret's bearing, against the barrel" % mode)
		# at rest again
		var after := _at(ui, mk, t0 + 1.2, mode)
		check(str(after) == str(rest), "4. %s: at rest again after the return" % mode)
	# the barrel moves by its own in barrel mode and nothing else does
	var pb := _at(ui, mk, t0 + 0.04, "barrel")
	near((pb["turrets"][0] as Vector2).distance_to(rest["turrets"][0]), 0.0, 1e-9, "4. barrel: the turret stays")
	near((pb["plane"] as Vector2).distance_to(rest["plane"]), 0.0, 1e-9, "4. barrel: the hull stays")
	check((pb["barrels"][0] as Vector2).distance_to(rest["barrels"][0]) >= Recoil.min_px(_st, "tank") - 1e-6, "4. barrel: the barrel moves at least the floor")
	var ph := _at(ui, mk, t0 + 0.06, "hull")
	check((ph["plane"] as Vector2).distance_to(rest["plane"]) > 0.5 and (ph["turrets"][0] as Vector2).distance_to(rest["turrets"][0]) > 0.5, "4. hull: the whole tank moves, the turret with it")
	# a long way out the floor holds; close in the metres do
	# no turn playing: rest (the marker is told no second)
	ui.marker_layer.stop_playback()
	var stopped := _positions(mk)
	_st.ui["unit_art"]["recoil"]["mode"] = "hull"
	ui.marker_layer.update_poses()
	check(str(_positions(mk)) == str(stopped), "4. no turn playing: the tank is at rest in every mode")
	ui.queue_free()
	_done += 1

func _ship() -> void:
	var w := GunWorlds.world(1, true)
	var model := UnitMarkerArt.model_for(_st, "small_cruiser")
	var n: int = (model.G.turrets as Array).size()
	var n_fwd := 0
	for t: Dictionary in model.G.turrets:
		if (t.c as Vector2).y < 0.0:
			n_fwd += 1
	var origin := GunWorlds.SHIP - Vector2(300.0, 300.0)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM), "local")
	ui.marker_layer.playback_paused = true
	GunWorlds.fire(w, "aa")
	w.commit("local")
	var res := w.resolve()
	var salvo := GunWorlds.events_of(res, "shell_fire", "cruiser")
	if not check(salvo.size() == 1, "3. the cruiser's salvo left"):
		return
	var shots: Array = ui.marker_layer._shots.get("cruiser", [])
	if not check(shots.size() == 1, "3. the layer collected the salvo"):
		return
	near(float(shots[0]["t"]), float(salvo[0]["t"]), 1e-12, "3. at the second the event says (%.2f)" % float(salvo[0]["t"]))
	eq(int(shots[0]["salvo"]), int(salvo[0]["shells"]), "3. with its shells (%d)" % int(salvo[0]["shells"]))
	near(float(shots[0]["interval"]), 0.2, 1e-9, "3. and the interval between them")
	var mk = ui.marker_layer.marker("cruiser")
	var k: float = _st.num("marker.true_scale") * mk.draw_scale
	mk.art = _fake_art(k, n, n_fwd)
	var t0 := float(shots[0]["t"])
	var rest := _at(ui, mk, t0 - 0.2, "none")
	var nb: int = maxi(UnitMarkerArt.ship_muzzles(_st, "small_cruiser", 0.0).size() / n, 1)
	check(n >= 2, "4. the model has %d turrets of %d barrels" % [n, nb])
	# none: nothing moves
	for t: float in [t0 + 0.02, t0 + 0.1, t0 + 0.4]:
		check(str(_at(ui, mk, t, "none")) == str(rest), "4. ship, mode none, t = shot %+.2f: no sprite moves" % (t - t0))
	for mode: String in MODES:
		var spec: Dictionary = Recoil.spec(_st, "ship", mode)
		var first := _at(ui, mk, t0 + 0.05, mode)
		var moved0: float = (first["barrels"][0] as Vector2).distance_to(rest["barrels"][0])
		check(moved0 > 0.0, "4. ship / %s: the first turret recoils as its first shell leaves (%.2f px)" % [mode, moved0])
		if not spec.has("hull") and int(shots[0]["salvo"]) > 0:
			# the second turret has not started: its barrel is where it was (a hull kick moves everything, so not then)
			var d1: float = (first["barrels"][1] as Vector2).distance_to(rest["barrels"][1])
			near(d1, 0.0, 1e-9, "4. ship / %s: the second turret waits for its own first shell" % mode)
		# later, the second turret kicks
		var later := _at(ui, mk, t0 + float(nb) * 0.2 + 0.05, mode)
		var d2: float = (later["barrels"][1] as Vector2).distance_to(rest["barrels"][1])
		check(d2 > 0.0, "4. ship / %s: the second turret kicks %.2f s after the first (%.2f px)" % [mode, float(nb) * 0.2, d2])
		var end := _at(ui, mk, t0 + float(n * nb) * 0.2 + 3.0, mode)
		check(str(end) == str(rest), "4. ship / %s: everything at rest after the salvo" % mode)
	ui.queue_free()
	_done += 1
