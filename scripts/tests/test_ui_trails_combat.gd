extends "res://scripts/test_support/test_case.gd"

# THE WINGTIP TRAILS IN A FIGHT (Track U2; Alex 2026-10-10, decision wingtip-trails). Headless:
# worlds are fought for real (World.resolve, the seeds FOUND for each fate,
# scripts/test_support/combat_worlds.gd) with the interface mounted through UnitUI, and the
# trail node is read through its own collect(). What must be true:
#
#   1. EVERY UNIT IN SIGHT has a ribbon (applies_to all, each in its own side colour)
#   2. A PLANE FALLING OUT OF CONTROL KEEPS ITS TRAIL: the ribbon follows the sampled fall path
#      to the crash; then it stops at the crash and fades as the window rolls on, until it is gone
#   3. AN EXPLODED PLANE'S TRAIL STOPS AT down_at (the wreck stays where it blew) and fades
#   4. THE TRAIL IS TO THE CURRENT POSITION: the ribbon's front edge is the plane's wingtips,
#      now -- with the turn planned (the plane's place at the end of the last turn) and at every
#      frame of a playback, run in the real frame order (a negative control puts the trail node
#      BEFORE the markers in the frame order and shows the gap a frame behind leaves)
#   5. WHERE THE RIBBON BEGINS is readable (start_t / UnitUI.trail_start_t), so the whole-flight
#      line can stop there

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")
const CombatWorlds = preload("res://scripts/test_support/combat_worlds.gd")

const PPM := 1.5
const ORIGIN := Vector2(1000.0, 2200.0)
const HEAD_TOL_PX := 0.3

var _st: UiStyle
var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
var _ran := {}

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	eq(_st.text("marker.trails.applies_to"), "all", "the data holds Alex's choice: trails on every moving unit")
	eq(_st.text("marker.trails.mode"), "ribbon", "...as one ribbon")
	var ooc := CombatWorlds.find_seed("out_of_control")
	var exploded := CombatWorlds.find_seed("exploded")
	if check(ooc > 0 and exploded > 0, "seeds found (out of control %d, exploded %d)" % [ooc, exploded]):
		_falls(ooc)
		_explodes(exploded)
		await _no_gap()
	var missing: Array = []
	for k: String in ["falls", "explodes", "no_gap"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- helpers ---------------------------------------------------------------------------------------------

func _ui_on(w: World) -> UnitUI:
	var mount := Node2D.new()
	add_child(mount)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local", mount, null)
	return ui

func _item(ui: UnitUI, id: String) -> Dictionary:
	for it: Dictionary in ui.trails.collect():
		if it["unit"] == id:
			return it
	return {}

func _screen(w: World, id: String, t: float) -> Vector2:
	var s := w.sample(id, t, "history")
	return _xf * Vector2(float(s["x"]), float(s["y"]))

# --- 1 and 2: out of control ---------------------------------------------------------------------------

func _falls(seed_value: int) -> void:
	var w := CombatWorlds.world(seed_value)
	var ui := _ui_on(w)
	var u: Unit = w.units["bomber"]
	var res := CombatWorlds.turn(w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	CombatWorlds.play_out(ui)
	# Turn 1 is over and the plane is falling: it has a ribbon, and so has the shooter (all units).
	var it := _item(ui, "bomber")
	check(not _item(ui, "fighter").is_empty(), "applies_to all: the shooter has a ribbon")
	if check(not it.is_empty(), "the plane that lost control at %.2f s keeps its ribbon" % t_down):
		check((it["accent"] as Color).is_equal_approx(_st.side_color("axis")), "in its own side's colour")
		var centre: PackedVector2Array = it["centre"]
		var ages: PackedFloat64Array = it["age"]
		check(centre[0].distance_to(_xf * Vector2(u.x, u.y)) < HEAD_TOL_PX, "its front is the plane's place now, after the fall began")
		# A point of the ribbon from the fall: the sample's place at that time.
		var t_f := t_down + (5.0 - t_down) * 0.5
		var j := 0
		for i in ages.size():
			if absf(ages[i] - (5.0 - t_f) / 5.0) < absf(ages[j] - (5.0 - t_f) / 5.0):
				j = i
		var t_j := 5.0 - ages[j] * 5.0
		check(centre[j].distance_to(_screen(w, "bomber", t_j)) < 0.3, "the ribbon follows the sampled fall path (the point at %.2f s is where the sample had it)" % t_j)
		check(t_j > t_down + 0.2, "...a point well into the fall (%.2f s, down at %.2f s)" % [t_j, t_down])
		# The ribbon spans the drawn wing at the fall's heading: the two edges stay one span apart.
		var l: PackedVector2Array = it["left"]
		var r: PackedVector2Array = it["right"]
		var span0 := l[0].distance_to(r[0])
		check(absf(l[j].distance_to(r[j]) - span0) < 0.05, "the edges stay one drawn span apart along the fall")
	# The turns on, until the crash.
	var turn_no := 1
	var crash := {}
	while turn_no < 7 and crash.is_empty():
		turn_no += 1
		var r2 := CombatWorlds.turn(w)
		crash = CombatWorlds.event_of(r2, "crash")
		if crash.is_empty():
			ui.marker_layer.set_playback_time(2.5)
			check(not _item(ui, "bomber").is_empty(), "turn %d: still falling, mid-turn, with its ribbon" % turn_no)
			CombatWorlds.play_out(ui)
	if not check(not crash.is_empty(), "the bomber crashes within a few turns"):
		return
	var t_c := float(crash["t"])
	# During the crash turn the ribbon's front is the plane until the crash, then the wreck.
	ui.marker_layer.set_playback_time(t_c * 0.5)
	var mid := _item(ui, "bomber")
	if check(not mid.is_empty(), "the crash turn, before the crash: a ribbon"):
		check((mid["centre"] as PackedVector2Array)[0].distance_to(ui.marker_layer.marker("bomber").position) < HEAD_TOL_PX, "its front is the plane")
	ui.marker_layer.set_playback_time(minf(t_c + 0.4, 4.9))
	var after := _item(ui, "bomber")
	if check(not after.is_empty(), "just after the crash the ribbon is still there"):
		check((after["centre"] as PackedVector2Array)[0].distance_to(_xf * Vector2(u.x, u.y)) < HEAD_TOL_PX, "...and stops AT the crash: its front is the wreck, not where the fall would have gone on")
		check((after["age"] as PackedFloat64Array)[0] > 0.0, "...its front is already ageing")
	CombatWorlds.play_out(ui)
	var wreck := _item(ui, "bomber")
	if check(not wreck.is_empty(), "the turn after the crash is planned: what the fall left is on the map"):
		check((wreck["centre"] as PackedVector2Array)[0].distance_to(_xf * Vector2(u.x, u.y)) < HEAD_TOL_PX, "ending at the wreck")
		var age0: float = (wreck["age"] as PackedFloat64Array)[0]
		near(age0, (5.0 - t_c) / 5.0, 1e-6, "...fading: its front is %.2f of a window old (crashed %.2f s before the turn's end)" % [age0, 5.0 - t_c])
	# Two turns on, nothing of it is left (the ribbon has faded with the window).
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	check(_item(ui, "bomber").is_empty(), "a turn or two later the wreck's ribbon has faded away")
	check(not _item(ui, "fighter").is_empty(), "...and the plane still flying keeps its own")
	_ran["falls"] = true

# --- 3: exploded ----------------------------------------------------------------------------------------------

func _explodes(seed_value: int) -> void:
	var w := CombatWorlds.world(seed_value)
	var ui := _ui_on(w)
	var u: Unit = w.units["bomber"]
	var res := CombatWorlds.turn(w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	eq(down["fate"], "exploded", "the bomber exploded at %.2f s" % t_down)
	var full: Dictionary = u.history[u.history.size() - 1]
	var down_pos := _xf * Vector2(float(down["x"]), float(down["y"]))
	# Before the blast the ribbon's front is the plane; after, it stays where the plane blew.
	ui.marker_layer.set_playback_time(t_down * 0.5)
	var before := _item(ui, "bomber")
	if check(not before.is_empty(), "before it blows the bomber has a ribbon"):
		check((before["centre"] as PackedVector2Array)[0].distance_to(ui.marker_layer.marker("bomber").position) < HEAD_TOL_PX, "its front is the plane")
	ui.marker_layer.set_playback_time(minf(t_down + 0.6, 4.9))
	var after := _item(ui, "bomber")
	if check(not after.is_empty(), "after the blast the ribbon is still on the map, fading"):
		var head: Vector2 = (after["centre"] as PackedVector2Array)[0]
		check(head.distance_to(down_pos) < HEAD_TOL_PX, "its front is stopped at the place it blew")
		check(head.distance_to(_xf * Vector2(float(full["x"]), float(full["y"]))) > 10.0, "...not where the path would have carried it")
		check((after["age"] as PackedFloat64Array)[0] > 0.05, "its front is ageing")
	CombatWorlds.play_out(ui)
	var planned := _item(ui, "bomber")
	if check(not planned.is_empty(), "with the next turn being planned the ribbon is still there"):
		check((planned["centre"] as PackedVector2Array)[0].distance_to(_xf * Vector2(u.x, u.y)) < HEAD_TOL_PX, "ending at the wreck")
		near((planned["age"] as PackedFloat64Array)[0], (5.0 - t_down) / 5.0, 1e-6, "...a front (5 - %.2f) / 5 of a window old" % t_down)
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	check(_item(ui, "bomber").is_empty(), "a turn or two later it has faded away")
	_ran["explodes"] = true

# --- 4 and 5: no gap, and where the ribbon begins ---------------------------------------------------------------

func _no_gap() -> void:
	var w := CombatWorlds.world(CombatWorlds.find_hit_seed(), 8)
	var ui := _ui_on(w)
	var layer = ui.marker_layer
	eq(_st.flag("marker.trails.replaces_flown_line"), true, "(the data has the ribbon replace the marker layer's own flown line)")
	check(is_nan(ui.trail_start_t("fighter")), "no turn flown yet: no ribbon, no start")
	# Turn 1 in real frames.
	CombatWorlds.turn(w)
	var worst := 0.0
	var frames := 0
	while layer.is_playing() and frames < 700:
		await get_tree().process_frame
		frames += 1
		for id: String in ["fighter", "bomber"]:
			worst = maxf(worst, _head_gap(ui, id))
	check(frames > 200, "turn 1 played in real frames (%d)" % frames)
	check(worst < HEAD_TOL_PX, "at every frame of the playback the ribbon's front is the plane (worst gap %.3f px)" % worst)
	await get_tree().process_frame
	# Planning turn 2: the ribbon runs up to the plane's place at the end of turn 1.
	for id: String in ["fighter", "bomber"]:
		var it := _item(ui, id)
		if check(not it.is_empty(), "%s: a ribbon with turn 2 being planned" % id):
			var gap := (it["centre"] as PackedVector2Array)[0].distance_to(layer.marker(id).position)
			check(gap < HEAD_TOL_PX, "%s: its front is the plane's place (gap %.3f px)" % [id, gap])
			near((it["age"] as PackedFloat64Array)[0], 0.0, 1e-9, "%s: the front is the newest point" % id)
	# Where the ribbon begins.
	near(ui.trail_start_t("fighter"), 0.0, 1e-9, "one turn flown: the ribbon begins at the game's start")
	var it1 := _item(ui, "fighter")
	var c1: PackedVector2Array = it1["centre"]
	var age1: float = (it1["age"] as PackedFloat64Array)[c1.size() - 1]
	# (The ribbon stops at the last recorded sample before its alpha drops below min_alpha: a sample step, 0.1 s, inside the window.)
	check(age1 > 0.97 and absf((5.0 - age1 * 5.0) - ui.trail_start_t("fighter")) < 0.15, "...its far end is at that time (age %.4f)" % age1)
	check(c1[c1.size() - 1].distance_to(_screen(w, "fighter", 5.0 - age1 * 5.0)) < HEAD_TOL_PX, "...and there the plane was where the ribbon's far end is")
	# Turn 2, then the third turn's playback: the start follows the window.
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	near(ui.trail_start_t("fighter"), 5.0, 1e-9, "two turns flown: it begins at the start of the last one (game 5 s)")
	var it2 := _item(ui, "fighter")
	var c2: PackedVector2Array = it2["centre"]
	var age2: float = (it2["age"] as PackedFloat64Array)[c2.size() - 1]
	check(age2 > 0.97 and absf((10.0 - age2 * 5.0) - ui.trail_start_t("fighter")) < 0.15, "...its far end is at that time (age %.4f)" % age2)
	check(c2[c2.size() - 1].distance_to(_screen(w, "fighter", 10.0 - age2 * 5.0 - 5.0)) < HEAD_TOL_PX, "...and there the plane was where the ribbon's far end is (turn 2's history)")
	CombatWorlds.turn(w)
	layer.set_playback_time(2.0)
	near(ui.trail_start_t("fighter"), 10.0 + 2.0 - 5.0, 1e-9, "playing turn 3 at 2 s: it begins one window before the clock (game 7 s)")
	CombatWorlds.play_out(ui)
	# A mode of none or a unit not covered has no start.
	_st.ui["marker"]["trails"]["mode"] = "none"
	check(is_nan(ui.trail_start_t("fighter")), "mode none: no start")
	_st.ui["marker"]["trails"]["mode"] = "ribbon"
	_st.ui["marker"]["trails"]["applies_to"] = "own"
	w.units["bomber"].controller = "ai"
	check(is_nan(ui.trail_start_t("bomber")) and not is_nan(ui.trail_start_t("fighter")), "applies_to own: the AI's unit has none")
	_st.ui["marker"]["trails"]["applies_to"] = "all"
	w.units["bomber"].controller = "player"

	# THE NEGATIVE CONTROL: the trail node processed BEFORE the markers reads last frame's clock.
	ui.trails.process_priority = -10
	CombatWorlds.turn(w)
	var lagged := 0.0
	var n := 0
	while layer.is_playing() and n < 700:
		await get_tree().process_frame
		n += 1
		lagged = maxf(lagged, _head_gap(ui, "fighter"))
	check(lagged > 1.0, "(control) a trail node processed before the markers trails the plane by a frame's flight: %.2f px" % lagged)
	ui.trails.process_priority = 20
	_ran["no_gap"] = true

# The distance from a unit's marker to the front of its ribbon as the trail node last drew it.
func _head_gap(ui: UnitUI, id: String) -> float:
	for it: Dictionary in ui.trails._items:
		if it["unit"] == id:
			return (it["centre"] as PackedVector2Array)[0].distance_to(ui.marker_layer.marker(id).position)
	return 0.0
