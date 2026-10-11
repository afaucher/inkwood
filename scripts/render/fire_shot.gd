extends SceneTree

# THE FOREST FIRE'S LOOK (track 'Forest fire', decision forest-fire; scripts/fx/fx_fire.gd, scripts/render/fire_trunk.gd) with a FAKE FEED,
# so it needs no sim. WINDOWED ONLY -- under --headless nothing is drawn (scripts/tests/test_fire_render.gd is the headless proof):
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/fire_shot.gd -- [seed] [out=tmp/fire] [size=1600x900] [what=all|frames|wind|cost] [trees=N]
#
# Finds the densest grove of the seed's terrain (default 20261009), builds a feed over its trees -- the west third burnt out to trunks, the
# middle burning since an earlier turn, the east third just lit, the rest beside it unburnt -- and draws it through a MapView and the
# effects layer in a SubViewport at the NATIVE size, writing:
#
#   01_unburnt_play.png         the grove at play zoom (1.0), nothing burning
#   02_rebaking_play.png        the same moment the feed arrives: the smoke is up, the trunks are still canopies (the stale chunks are kept)
#   03_burning_play.png         the chunks baked again: smoke over the burning trees, trunks where the canopies were, unburnt trees beside
#   04_burning_plan.png         the planning zoom (0.35)
#   05_burning_close.png        zoom 2.0 on the border between the burnt and the burning
#   06_tail_play.png            a turn and a half later: the middle third is out too (the map baked again), its smoke thinning away
#
# THE WIND (decision coastal-wind, 2026-10-11; what=wind, and part of all): the same burning grove under the sim's own Wind (scripts/sim/wind.gd, built
# from its params as a client builds it: the day at 14:00, the night at 01:30, the dawn calm at 07:30, the sea lying to the west-south-west; the seed is the
# shot's) -- a stand-in FakeWind with its shape is used only if that Wind will not load -- each at play zoom, at 0.35 and (the day) close:
#
#   08_wind_day_play.png / 08_wind_day_plan.png / 08_wind_day_close.png     the plumes lean and trail downwind
#   09_wind_night_play.png / 09_wind_night_plan.png                          lighter, and the other way
#   10_wind_dawn_play.png / 10_wind_dawn_plan.png                            near calm: the smoke stands over its trees
#   11_plumes_day.png / 12_plumes_night.png / 13_plumes_dawn.png            six trees burning alone, so each plume's lean can be read
#
# and PRINTS the cost: how long the chunks took to bake again, and the frame time with the grove burning against the same view with no fire
# (VSync off, 180 frames, the smoke advancing), with what the smoke's own code spent (make the puffs, record the draws). A script that quits
# with the baker's workers running segfaults (CLAUDE.md), so it clears the baker first.

const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")

const TS := 5.0
const GRID_M := 30.0

# A stand-in for the sim's Wind (at(game_s) -> Vector2 m/s, world axes; mean()): a base velocity whose direction wanders +-15 degrees and whose speed
# wanders +-30% over a few turns, with a short gust now and then.
const WindScript = preload("res://scripts/sim/wind.gd")

# The wind of one hour of the day, on the sim's own model (a stand-in FakeWind if it will not load).
func _wind_for(hour: float, fallback: Vector2, phase: float) -> Object:
	var w: Object = WindScript.from_params({"hour": hour, "toward_sea": [-0.93, 0.37], "seed": seed_value, "v": 1}, WindScript.PATH, true)
	if w != null and bool(w.call("ok")):
		return w
	printerr("[fire-shot] the sim's Wind did not load (%s): a FakeWind stands in" % str(w.get("errors") if w != null else "null"))
	return FakeWind.new(fallback, phase)

class FakeWind extends RefCounted:
	var base := Vector2(3.8, -1.3)
	var phase := 0.0
	func _init(velocity: Vector2 = Vector2(3.8, -1.3), ph: float = 0.0) -> void:
		base = velocity
		phase = ph
	func at(t: float) -> Vector2:
		var ang := deg_to_rad(15.0) * sin(t * TAU / 27.0 + phase)
		var speed := 1.0 + 0.3 * sin(t * TAU / 19.0 + phase * 1.7)
		var gust := 1.0 + 0.35 * pow(maxf(0.0, sin(t * TAU / 7.3 + phase * 0.6)), 6.0)
		return base.rotated(ang) * speed * gust
	func mean() -> Vector2:
		return base

var out_dir := "tmp/fire"
var seed_value := 20261009
var size := Vector2i(1600, 900)
var opts: Dictionary = {}

var vp: SubViewport = null
var view = null
var fx: FxLayer = null
var canvas: CanvasLayer = null
var centre_m := Vector2.ZERO
var feed: Array = []
var all_trees: Array = []          # the middle of the map's trees: {x_m, y_m, r_m, id}
var t_show := 0.0
var code := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[fire-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	var pos := 0
	for a: String in args:
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
		elif pos == 0:
			seed_value = int(a)
			pos += 1
	out_dir = str(opts.get("out", out_dir))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var sz := str(opts.get("size", "1600x900")).split("x")
	if sz.size() == 2:
		size = Vector2i(int(sz[0]), int(sz[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[fire-shot] ", msg)

func _save(name: String) -> void:
	var img := vp.get_texture().get_image()
	var path := out_dir.path_join(name)
	img.save_png(path)
	_say("saved %s (%dx%d)" % [path, img.get_width(), img.get_height()])

func _run() -> void:
	var what := str(opts.get("what", "all"))
	_build()
	if not view.errors().is_empty():
		printerr("[fire-shot] errors: ", view.errors())
		_finish(1)
		return
	_find_grove()
	await _frames(2)
	view.look_at_m(centre_m)
	view.set_zoom(1.0)
	var t_cold := await _wait_complete(120.0)
	_say("the grove at play zoom, cold bake: %.1f s" % t_cold)
	if what == "all" or what == "frames":
		await _frames_run()
	if what == "all" or what == "wind":
		await _wind_run()
		await _plume_run()
	if what == "all" or what == "cost":
		await _cost_run()
	_finish(code)

func _finish(c: int) -> void:
	if view != null:
		view.baker.clear()
	if vp != null:
		vp.queue_free()
	await _frames(3)
	quit(c)

func _build() -> void:
	vp = SubViewport.new()
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var P := RenderParams.new()
	view = MapView.new(seed_value, Rect2(), 0.0, "terrain", P)
	view.input_enabled = false
	vp.add_child(view)
	canvas = CanvasLayer.new()
	canvas.layer = 1
	vp.add_child(canvas)
	fx = FxLayer.new()
	canvas.add_child(fx)
	fx.setup(view, seed_value)
	fx.true_scale = 1.0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

func _wait_complete(max_s: float, dirty_too: bool = false) -> float:
	var t0 := Time.get_ticks_msec()
	await _frames(2)
	while view.missing_in_view() > 0 or view.pending() > 0 or (dirty_too and view.dirty_count() > 0):
		if (Time.get_ticks_msec() - t0) / 1000.0 > max_s:
			printerr("[fire-shot] not complete after %.0f s (%d missing, %d pending, %d dirty)" % [max_s, view.missing_in_view(), view.pending(), view.dirty_count()])
			code = 1
			break
		await process_frame
	await _frames(3)
	return (Time.get_ticks_msec() - t0) / 1000.0

# --- The grove and the fake feed -----------------------------------------------------------------------------

func _find_grove() -> void:
	var terr = view.provider.terrain
	var ppm: float = terr.px_per_m
	var mr: Rect2 = terr.map_rect_px()
	var cpx: float = float(terr.chunk_m) * ppm
	var mid := mr.get_center()
	var c0 := Vector2i(floori(mid.x / cpx), floori(mid.y / cpx))
	var bins: Dictionary = {}
	var all: Array = []
	for cy in range(c0.y - 2, c0.y + 3):
		for cx in range(c0.x - 2, c0.x + 3):
			if not terr.chunk_in_map(cx, cy):
				continue
			for t: Dictionary in terr.trees_in_chunk(cx, cy):
				var m := Vector2(float(t["x"]), float(t["y"])) / ppm
				var cell := Vector2i(floori(m.x / GRID_M), floori(m.y / GRID_M))
				bins[cell] = int(bins.get(cell, 0)) + 1
				all.append({"x_m": m.x, "y_m": m.y, "r_m": float(t["r"]) / ppm, "id": "%d_%d" % [roundi(float(t["x"]) * 10.0), roundi(float(t["y"]) * 10.0)]})
	var best := -1
	var best_cell := Vector2i.ZERO
	for cell: Vector2i in bins:
		var sum := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				sum += int(bins.get(cell + Vector2i(dx, dy), 0))
		if sum > best:
			best = sum
			best_cell = cell
	centre_m = (Vector2(best_cell) + Vector2(0.5, 0.5)) * GRID_M
	all_trees = all
	_say("%d trees in the middle of the map; the densest grove (5 x 5 cells of %d m) has %d, centred at %s m" % [all.size(), int(GRID_M), best, centre_m.round()])
	# the feed: the trees within the radius, west to east: burnt out, burning, just lit; beyond the east edge unburnt
	var radius := float(opts.get("radius", "95"))
	var inside: Array = []
	for t: Dictionary in all:
		if Vector2(t["x_m"], t["y_m"]).distance_to(centre_m) <= radius:
			inside.append(t)
	inside.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["x_m"]) < float(b["x_m"]))
	var n := inside.size()
	var cap := int(opts.get("trees", "0"))
	t_show = 2.0 * TS + 3.5   # turn 3, 3.5 s in
	feed = []
	for i in n:
		var t: Dictionary = inside[i]
		var f := float(i) / float(maxi(n - 1, 1))
		var rec := {"id": t["id"], "x_m": t["x_m"], "y_m": t["y_m"], "r_m": t["r_m"]}
		var jitter := fposmod(float(i) * 0.6180339, 1.0)
		if f < 0.30:
			rec["lit_turn"] = 1
			rec["lit_t"] = jitter * TS
			rec["out_turn"] = 2   # out at the end of turn 2 (10 s): a trunk from then on
		elif f < 0.62:
			rec["lit_turn"] = 2
			rec["lit_t"] = jitter * TS
			rec["out_turn"] = 4   # burning through the end of turn 4 (20 s)
		elif f < 0.86:
			rec["lit_turn"] = 3
			rec["lit_t"] = jitter * 3.4   # lit in the first 3.4 s of turn 3: the smoke is seconds old at 13.5 s
			rec["out_turn"] = 5
		else:
			continue   # unburnt, beside the fire
		feed.append(rec)
	_say("%d trees within %d m of the centre; %d of them in the fake feed (the rest unburnt); shown at game time %.1f s (turn 3, 3.5 s in)" % [n, int(radius), feed.size(), t_show])
	if cap > 0 and feed.size() > cap:
		feed = feed.slice(0, cap)

# --- The frames -----------------------------------------------------------------------------------------------------

func _frames_run() -> void:
	view.look_at_m(centre_m)
	view.set_zoom(1.0)
	fx.set_time(t_show)
	await _frames(3)
	_save("01_unburnt_play.png")
	# the feed arrives: smoke at once, the map follows
	var t0 := Time.get_ticks_msec()
	fx.set_fire_feed(feed, TS)
	fx.set_time(t_show)
	var burnt: Array = fx.fire.burnt_at(t_show)
	var old_sprites := {}
	for c: Vector2i in view._chunks:
		old_sprites[c] = view._chunks[c]
	var n_chunks: int = view.chunk_count()
	var changed: int = view.set_burnt_trees(burnt)
	_say("%d trees are trunks at %.1f s; %d chunks changed, %d shown ones marked to bake again (of %d shown)" % [burnt.size(), t_show, changed, view.dirty_count(), n_chunks])
	await _frames(2)
	var kept := 0
	for c: Vector2i in old_sprites:
		if view.is_dirty(c) and is_instance_valid(old_sprites[c]) and view._chunks.get(c) == old_sprites[c]:
			kept += 1
	_say("two frames later: %d of the marked chunks still show their old sprite, %d chunks shown (was %d: nothing went blank), %d still waiting" % [kept, view.chunk_count(), n_chunks, view.dirty_count()])
	_save("02_rebaking_play.png")
	var t_rebake := await _wait_complete(120.0, true)
	_say("the %d chunks baked again and swapped in: %.1f s after the feed arrived (%.1f s of it waiting for the last read-back)" % [changed, (Time.get_ticks_msec() - t0) / 1000.0, t_rebake])
	var swapped := 0
	for c: Vector2i in old_sprites:
		if view._chunks.has(c) and view._chunks[c] != old_sprites[c]:
			swapped += 1
	_say("%d chunks have a new sprite now" % swapped)
	_save("03_burning_play.png")
	view.set_zoom(0.35)
	await _wait_complete(120.0, true)
	_save("04_burning_plan.png")
	# the border between the burnt and the burning, close
	var border := centre_m
	for rec: Dictionary in feed:
		if int(rec["lit_turn"]) == 2:
			border = Vector2(rec["x_m"], rec["y_m"])
			break
	view.look_at_m(border)
	view.set_zoom(2.0)
	await _wait_complete(120.0, true)
	_save("05_burning_close.png")
	view.look_at_m(centre_m)
	view.set_zoom(1.0)
	var t_tail := t_show + 1.5 * TS
	fx.set_time(t_tail)
	var burnt2: Array = fx.fire.burnt_at(t_tail)
	var changed2: int = view.set_burnt_trees(burnt2)   # (what the game does when the playback reaches the end of turn 4: the middle third is out)
	await _wait_complete(120.0, true)
	_say("a turn and a half later (%.1f s): %d trees are trunks, %d chunks baked again" % [t_tail, burnt2.size(), changed2])
	_save("06_tail_play.png")

# --- The wind -----------------------------------------------------------------------------------------------------------------

# How far the smoke sits downwind of its trees: the mean displacement (m) of a puff from its tree, over the feed's burning columns.
func _mean_lean() -> String:
	var puffs: Array = fx.fire.puffs_at(t_show)
	if puffs.is_empty():
		return "no puffs"
	var trees := {}
	for rec: Dictionary in feed:
		trees[str(rec["id"])] = Vector2(rec["x_m"], rec["y_m"])
	var sum := Vector2.ZERO
	for p: Dictionary in puffs:
		sum += (p["pos"] as Vector2) - (trees[str(p["tree"])] as Vector2)
	sum /= float(puffs.size())
	return "%.1f m east, %.1f m south of its tree on average (%.1f m)" % [sum.x, sum.y, sum.length()]

func _wind_run() -> void:
	view.look_at_m(centre_m)
	view.set_zoom(1.0)
	fx.set_fire_feed(feed, TS)
	fx.set_time(t_show)
	view.set_burnt_trees(fx.fire.burnt_at(t_show))
	await _wait_complete(120.0, true)
	_say("WIND: the grove burning at %.1f s; drift_s from data/sim/fire.json: %s, the gain on the wind %.2f (a puff reads as smoke for %.2f s)" % [
		t_show, str(fx.fire.drift_s()) if fx.fire.drift_s() > 0.0 else "none yet (the sim builder adds it): the wind is used as it blows", fx.fire.drift_gain(), fx.fire.zone_age_s()])
	_say("WIND: with no wind, the options' data wind (2.5 east, 1.0 south m/s): smoke %s" % _mean_lean())
	var regimes := [
		["day (14:00)", "08_wind_day", _wind_for(14.0, Vector2(3.8, -1.3), 0.0), true],
		["night (01:30)", "09_wind_night", _wind_for(1.5, Vector2(-1.8, 0.7), 1.3), false],
		["dawn (07:30)", "10_wind_dawn", _wind_for(7.5, Vector2(0.25, 0.12), 2.1), false],
	]
	for r: Array in regimes:
		var w: Object = r[2]
		fx.set_wind(w)
		fx.set_time(t_show)
		view.look_at_m(centre_m)
		view.set_zoom(1.0)
		await _frames(4)
		var at: Vector2 = w.at(t_show)
		_say("WIND %s: the air blows %.1f m/s toward (%.1f, %.1f) at %.1f s (the regime's mean (%.1f, %.1f)); smoke %s" % [r[0], at.length(), at.x, at.y, t_show, w.mean().x, w.mean().y, _mean_lean()])
		_save("%s_play.png" % r[1])
		view.set_zoom(0.35)
		await _wait_complete(120.0, true)
		_save("%s_plan.png" % r[1])
		if bool(r[3]):
			view.look_at_m(centre_m)
			view.set_zoom(2.0)
			await _wait_complete(120.0, true)
			_save("%s_close.png" % r[1])
	fx.set_wind(null)
	view.set_zoom(1.0)

# A few trees burning alone (spaced out, none in the grove, the biggest), under the same three winds, at zoom 2: each plume's lean can be read.
func _plume_run() -> void:
	var picks: Array = []
	var cand: Array = []
	for t: Dictionary in all_trees:
		var d := Vector2(t["x_m"], t["y_m"]).distance_to(centre_m)
		if d > 120.0 and d < 330.0:
			cand.append(t)
	cand.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["r_m"]) > float(b["r_m"]) or (float(a["r_m"]) == float(b["r_m"]) and str(a["id"]) < str(b["id"])))
	for t: Dictionary in cand:
		var p := Vector2(t["x_m"], t["y_m"])
		var ok := true
		for q: Dictionary in picks:
			var dq := p.distance_to(Vector2(q["x_m"], q["y_m"]))
			if dq < 55.0 or dq > 120.0:
				ok = false
		if ok:
			picks.append(t)
		if picks.size() >= 4:
			break
	if picks.size() < 3:
		return
	var lone: Array = []
	var mid := Vector2.ZERO
	for i in picks.size():
		var t: Dictionary = picks[i]
		lone.append({"id": t["id"], "x_m": t["x_m"], "y_m": t["y_m"], "r_m": t["r_m"], "lit_turn": 2, "lit_t": 0.4 * float(i), "out_turn": 5})
		_say("plume tree %d: %s, canopy radius %.1f m" % [i, Vector2(t["x_m"], t["y_m"]).round(), float(t["r_m"])])
		mid += Vector2(t["x_m"], t["y_m"])
	mid /= float(picks.size())
	fx.set_fire_feed(lone, TS)
	view.set_burnt_trees([])
	view.look_at_m(mid)
	view.set_zoom(2.0)
	await _wait_complete(120.0, true)
	for r: Array in [["day", "11_plumes_day", _wind_for(14.0, Vector2(3.8, -1.3), 0.0)], ["night", "12_plumes_night", _wind_for(1.5, Vector2(-1.8, 0.7), 1.3)], ["dawn", "13_plumes_dawn", _wind_for(7.5, Vector2(0.25, 0.12), 2.1)]]:
		fx.set_wind(r[2])
		fx.set_time(t_show + 1.0)
		await _frames(4)
		_save("%s.png" % r[1])
	fx.set_wind(null)

# --- The cost ------------------------------------------------------------------------------------------------------------

# Frames of the view with the grove burning, the smoke advancing in game time, against the same with no fire.
func _measure(label: String, n: int) -> void:
	var ms: Array = []
	fx.fire.reset_timing()
	var t := t_show
	var last := Time.get_ticks_usec()
	for _i in n:
		await process_frame
		var now := Time.get_ticks_usec()
		ms.append((now - last) / 1000.0)
		last = now
		t += 0.04
		fx.set_time(t)
	ms.sort()
	var sum := 0.0
	for x: float in ms:
		sum += x
	var st: Dictionary = fx.fire.stats()
	_say("FRAME %s: %d frames, mean %.2f ms, median %.2f, p95 %.2f, worst %.2f; the smoke: %d trees, %d columns, %d puffs a frame (%d thinned), %.2f ms making the puffs (%d times), %.2f ms recording the draws, per frame" % [
		label, n, sum / float(n), ms[n / 2], ms[int(n * 0.95)], ms[n - 1], int(st["trees"]), int(st["columns"]), int(st["puffs"]), int(st["thinned"]),
		float(st["compute_ms"]) / float(n), int(st["computes"]), float(st["draw_ms"]) / float(n)])

func _cost_run() -> void:
	view.look_at_m(centre_m)
	view.set_zoom(1.0)
	fx.set_fire_feed([], TS)
	view.set_burnt_trees([])
	await _wait_complete(120.0, true)
	await _measure("no fire, play zoom", 180)
	fx.set_fire_feed(feed, TS)
	view.set_burnt_trees(fx.fire.burnt_at(t_show))
	await _wait_complete(120.0, true)
	await _measure("grove burning (%d trees), play zoom" % feed.size(), 180)
	view.set_zoom(0.35)
	await _wait_complete(120.0, true)
	await _measure("grove burning, planning zoom 0.35", 180)
	view.set_zoom(1.0)
	# the worst case: every tree of the middle of the map burning at once, in view or not (past the draw budget the puffs are thinned)
	var big: Array = []
	var terr = view.provider.terrain
	var ppm: float = terr.px_per_m
	for cy in range(0, 12):
		for cx in range(0, 12):
			if not terr.chunk_in_map(cx, cy):
				continue
			for t: Dictionary in terr.trees_in_chunk(cx, cy):
				var m := Vector2(float(t["x"]), float(t["y"])) / ppm
				if m.distance_to(centre_m) < 420.0:
					big.append({"id": "%d_%d" % [roundi(float(t["x"]) * 10.0), roundi(float(t["y"]) * 10.0)], "x_m": m.x, "y_m": m.y, "r_m": float(t["r"]) / ppm,
						"lit_turn": 1, "lit_t": fposmod(float(big.size()) * 0.37, 1.0) * 3.0, "out_turn": 4})
	fx.set_fire_feed(big, TS)
	view.look_at_m(centre_m)
	await _frames(3)
	await _measure("%d trees burning in a 420 m disc, play zoom" % big.size(), 120)
	view.set_zoom(0.35)
	await _frames(3)
	await _measure("%d trees burning, planning zoom 0.35" % big.size(), 120)
	_save("07_everything_burning_plan.png")
	view.set_zoom(1.0)
	await _frames(3)
	_save("07_everything_burning_play.png")
