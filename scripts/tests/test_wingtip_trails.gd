extends "res://scripts/test_support/test_case.gd"

# WINGTIP TRAILS (Track U1; variants/wingtip-trails/). EVERY STYLE AND RULE IS PROPOSED;
# this holds what must be true whichever Alex picks. Headless: a World with two player
# planes and an AI bomber is flown for two REAL turns (World.resolve), the trail node
# records them through World.turn_resolved exactly as in the game, and it is read through
# its own collect().
#
#   1. THE DEFAULT DRAWS NOTHING: marker.trails.mode is "none" in the shipped data; with
#      two resolved turns on record it collects nothing and draws nothing (the marker layer
#      keeps its own flown-so-far line)
#   2. THE TRAIL FOLLOWS THE HISTORY AT THE WINGTIPS: every point is the history's pose at
#      that game time, offset square to the heading by the drawn half-span (the wing
#      outline's half-span x marker.true_scale), on each side; it starts AT the plane
#   3. THE SPAN IS THE DRAWN SPAN, AT EVERY ZOOM: it scales with marker.true_scale and is
#      unchanged when the map scale halves and true_scale doubles (the sandbox's own-scale rule)
#   4. THE WINDOW: the whole last turn while planning, fading from the plane (age 0, full) to
#      the far end; a rolling window while a turn plays back, reaching back into the turn before
#   5. WHOSE: own units only ("own"); every unit in sight with "all"; none for a unit out of
#      sight or a down one
#   6. THE STEP ENDS are marked: one per step of the unit's turn
#   7. EVERY STYLE DRAWS TO THE END; the marker layer drops its solid flown line only when a
#      trail replaces it

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const WingtipTrails = preload("res://scripts/ui/wingtip_trails.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const PPM := 2.0

class _Playback extends RefCounted:
	var playback_turn := 2
	var playback_t := 2.5
	func is_playing() -> bool:
		return true
	func marker(_id: String) -> Object:
		return null

var _st: UiStyle
var _tr: WingtipTrails
var _w: World
var _modes: Array = []
var _next := 0
var _frame := 0
var _counts := {}
var _saved: Dictionary = {}
var _setup_done := false     # set at the end of setup(): a runtime error in setup() ends it silently

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_saved = {"mode": _st.text("marker.trails.mode"), "applies": _st.text("marker.trails.applies_to"), "k": _st.num("marker.true_scale"),
		"min_alpha": _st.num("marker.trails.min_alpha")}
	_modes = _st.lookup("marker.trails.modes")
	# Alex 2026-10-10 (decision wingtip-trails): D, one ribbon between the wingtips.
	eq(_saved["mode"], "ribbon", "the data holds Alex's choice: the ribbon")
	check(_modes.has("none") and _modes.size() >= 5, "the data lists the modes: %s" % str(_modes))

	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.0})
	_w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1400.0, "heading": 0.0})
	_w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 4200.0, "y": 4200.0, "heading": 3.0})
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, Vector2.ZERO)
	_tr = WingtipTrails.new()
	add_child(_tr)
	_tr.setup(_w, xf, null, _st)

	# Turn 1, then turn 2: gentle turns, so the paths curve. The trail records each as it resolves.
	var turn_len: float = _w.rules.turn_seconds
	var s1_mid := {}
	for turn_no in [1, 2]:
		for id: String in ["p1", "p2"]:
			for k in _w.steps_per_turn(id):
				_w.plan_step(id, k, {"turn": 0.1 if id == "p1" else -0.08})
		_w.commit("local")
		_w.commit(World.AI_PLAYER)
		var res := _w.resolve()
		check(not res.is_empty(), "turn %d resolves" % turn_no)
		if turn_no == 1:
			s1_mid = _w.sample("p1", 2.5, "history")
		if turn_no == 1:
			_w.begin_turn()

	# 1. Mode none (today's look before the choice) draws nothing.
	_data("mode", "none")
	eq(_tr.collect().size(), 0, "mode none: nothing is collected although two turns are on record")
	check(_tr._buf.has("p1") and (_tr._buf["p1"]["t"] as PackedFloat64Array).size() > 20, "the turns are recorded all the same, so a trail can be switched on mid-game")
	eq(_tr.failed_draws, 0, "mode none draws nothing, whole")

	# 2. The trail follows the history at the wingtips.
	_data("mode", "lines")
	var items := _tr.collect()
	eq(items.size(), 2, "lines: the two player planes have a trail, the AI's does not")
	var k: float = _st.num("marker.true_scale")
	var hs := UnitMarkerArt.half_span_m(_st, "light_fighter")
	check(hs > 3.0 and hs < 8.0, "the light fighter's drawn half-span is a few metres (%s)" % str(hs))
	var it := _item(items, "p1")
	if check(not it.is_empty(), "p1 has a trail"):
		var u = _w.units["p1"]
		var right := Vector2.from_angle(float(u.heading) + PI / 2.0)
		var pos := Vector2(float(u.x), float(u.y))
		check((it["left"][0] as Vector2).is_equal_approx(xf * (pos - right * hs * k)), "the trail starts at the plane's port wingtip")
		check((it["right"][0] as Vector2).is_equal_approx(xf * (pos + right * hs * k)), "and its starboard wingtip")
		near((it["age"] as PackedFloat64Array)[0], 0.0, 1e-9, "age 0 at the plane")
		var n: int = (it["left"] as PackedVector2Array).size()
		check(n > 15, "the trail has many points (%d)" % n)
		# A point in the middle of the window is the history's pose then, at the wingtips.
		var j := n / 2
		var age: float = (it["age"] as PackedFloat64Array)[j]
		var t_game: float = 2.0 * turn_len - age * turn_len
		var s: Dictionary = _w.sample("p1", t_game - turn_len, "history")   # turn 2 starts at one turn length
		var r2 := Vector2.from_angle(float(s["heading"]) + PI / 2.0)
		var p2 := Vector2(float(s["x"]), float(s["y"]))
		check((it["left"][j] as Vector2).distance_to(xf * (p2 - r2 * hs * k)) < 0.2, "a point in the middle of the trail is where the history had the port wingtip")
		check((it["right"][j] as Vector2).distance_to(xf * (p2 + r2 * hs * k)) < 0.2, "and the starboard one")
		var monotone := true
		var ages: PackedFloat64Array = it["age"]
		for i in range(1, ages.size()):
			if ages[i] < ages[i - 1] - 1e-12:
				monotone = false
		check(monotone, "age only grows away from the plane")
		check(ages[ages.size() - 1] > 0.9 and ages[ages.size() - 1] <= 1.0, "the far end is at the far end of the window (%s)" % str(ages[ages.size() - 1]))
		eq(WingtipTrails.fade(0.0, _st), 1.0, "full alpha at the plane")
		check(WingtipTrails.fade(0.5, _st) < 1.0 and WingtipTrails.fade(0.5, _st) > WingtipTrails.fade(0.9, _st), "alpha falls with age")
		eq(WingtipTrails.fade(1.0, _st), 0.0, "and is nothing at the far end")
		# 6. A mark at each step's end.
		var marks := 0
		for f: int in (it["step"] as PackedInt32Array):
			marks += f
		eq(marks, int(u.def.actions_per_turn), "one step end per step of the turn on the light fighter's trail (%d)" % marks)

	# 3. The span is the drawn span, at every zoom.
	# (Screen points are float32: a few thousandths of a pixel at 2,000 px.)
	var span0 := ((it["left"][0] as Vector2) - (it["right"][0] as Vector2)).length()
	near(span0, 2.0 * hs * k * PPM, 2e-3, "the two lines start one drawn span apart")
	_st.set_num("marker.true_scale", k * 2.5)
	var span1 := _span_px(_tr.collect(), "p1")
	near(span1, span0 * 2.5, 5e-3, "a plane drawn 2.5 x larger has its lines 2.5 x further apart")
	_tr.set_mapping(xf.scaled_local(Vector2(0.5, 0.5)))
	_st.set_num("marker.true_scale", k * 2.0)
	near(_span_px(_tr.collect(), "p1"), span0, 2e-3, "at half the map scale with the plane drawn the same size, the span is the same")
	_st.set_num("marker.true_scale", _saved["k"])
	_tr.set_mapping(xf)

	# 4. The window: playing back turn 2 at 2.5 s, it reaches back 2.5 s into turn 1.
	_st.ui["marker"]["trails"]["min_alpha"] = 0.0
	_tr.marker_layer = _Playback.new()
	var play := _item(_tr.collect(), "p1")
	if check(not play.is_empty(), "a rolling window while a turn plays back"):
		near(_tr.now(), 1.0 * turn_len + 2.5, 1e-9, "the trail ends at the playback clock, in game time")
		var last: int = (play["left"] as PackedVector2Array).size() - 1
		var rr := Vector2.from_angle(float(s1_mid["heading"]) + PI / 2.0)
		var pm := Vector2(float(s1_mid["x"]), float(s1_mid["y"]))
		check((play["left"][last] as Vector2).distance_to(xf * (pm - rr * hs * k)) < 0.2, "its far end is where the plane was 2.5 s into the turn before")
		near((play["age"] as PackedFloat64Array)[last], 1.0, 1e-9, "at the far end of the window")
		var now_pose: Dictionary = _w.sample("p1", 2.5, "history")
		var rn := Vector2.from_angle(float(now_pose["heading"]) + PI / 2.0)
		var pn := Vector2(float(now_pose["x"]), float(now_pose["y"]))
		check((play["left"][0] as Vector2).distance_to(xf * (pn - rn * hs * k)) < 0.2, "and it starts at the plane's wingtip now, 2.5 s into the turn")
	_tr.marker_layer = null
	_st.ui["marker"]["trails"]["min_alpha"] = _saved["min_alpha"]

	# 5. Whose.
	_data("applies_to", "all")
	var all_items := _tr.collect()
	check(not _item(all_items, "ai1").is_empty(), "applies_to all: the enemy bomber has one too, in its own accent")
	if not _item(all_items, "ai1").is_empty():
		check((_item(all_items, "ai1")["accent"] as Color).is_equal_approx(_st.side_color("axis")), "the enemy's trail is the axis accent")
		check((_item(all_items, "p1")["accent"] as Color).is_equal_approx(_st.side_color("allies")), "the players' is the allies' accent")
	_tr.unit_visible = func(id: String) -> bool: return id != "ai1"
	check(_item(_tr.collect(), "ai1").is_empty(), "a unit out of sight has none")
	_tr.unit_visible = Callable()
	_data("applies_to", "own")

	# 7. The marker layer drops its own flown line only when a trail replaces it.
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(_w, xf, "local")
	var layer = ui.marker_layer
	_data("mode", "none")
	check(not layer._flown_line_replaced(layer.marker("p1")), "mode none: the marker layer keeps its flown line")
	_data("mode", "lines")
	check(layer._flown_line_replaced(layer.marker("p1")), "a trail on: the player's flown line is the trail's")
	check(not layer._flown_line_replaced(layer.marker("ai1")), "but the AI's is not (own only)")
	_data("applies_to", "all")
	check(layer._flown_line_replaced(layer.marker("ai1")), "applies_to all: the AI's too")
	_data("applies_to", "own")
	_data("mode", "none")

	_setup_done = true
	# Every style draws, in turn: one per three frames; checked in _done().
	_next = 0
	timeout_seconds = 60.0

func _data(key: String, value: String) -> void:
	_st.ui["marker"]["trails"][key] = value

func _item(items: Array, id: String) -> Dictionary:
	for it: Dictionary in items:
		if it["unit"] == id:
			return it
	return {}

func _span_px(items: Array, id: String) -> float:
	var it := _item(items, id)
	return ((it["left"][0] as Vector2) - (it["right"][0] as Vector2)).length() if not it.is_empty() else -1.0

func _physics_process(_delta: float) -> void:
	if _modes.is_empty() or _next > _modes.size() + 1:
		return
	_frame += 1
	if _frame % 3 == 1:
		if _next > 0:
			_counts[_modes[_next - 1]] = _tr.draw_count
		if _next >= _modes.size():
			_done()
			return
		_data("mode", _modes[_next])
		_next += 1

func _done() -> void:
	_next = _modes.size() + 2
	check(_setup_done, "setup() ran to its end (a runtime error would have ended it early, leaving every assertion above unrun)")
	var last := -1
	for m: String in _modes:
		var c: int = int(_counts.get(m, 0))
		check(c > last, "style '%s': the trail drew" % m)
		last = c
	eq(_tr.failed_draws, 0, "every sub-draw of every style ran to its end (a runtime error would end one early)")
	eq(_st.errors.size(), 0, "no style error was raised: %s" % str(_st.errors))
	_data("mode", _saved["mode"])
	_data("applies_to", _saved["applies"])
	finish()
