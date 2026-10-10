extends "res://scripts/test_support/test_case.gd"

# THE END OF THE MISSION AND THE PLAYERS' NAMES (Track U2, "the first fight", part 2). Headless:
# the interface is mounted through UnitUI and given what Mission.evaluate() really returns.
#
#   1. show_result draws the card for "won" and "lost" (nothing for "playing"): the verdict, the
#      reason in plain words from the mission's own reason string (bomber down / the bomber
#      reached its target / both fighters down; the mission's own words when no rule fits), the turn
#   2. PLANNING INPUT IS LOCKED while it shows: the map, the Ready button and key, the orders
#      card's buttons; hide_result gives it back
#   3. the two buttons emit result_play_again and result_menu, each once, from a click on them
#      and from nowhere else on the card
#   4. a result handed over while a turn plays waits for the playback to end; handed over from the
#      turn_played signal it shows at once
#   5. player_name (player id -> display String) is used by the orders card's ready marks, and its
#      default returns the id

const World = preload("res://scripts/sim/world.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const ResultCard = preload("res://scripts/ui/result_card.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const CombatWorlds = preload("res://scripts/test_support/combat_worlds.gd")

const PPM := 1.0
const SIZE := Vector2(1280.0, 720.0)

var _st: UiStyle
var _ran := {}
var _again := 0
var _menu := 0

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	_card()
	_locked()
	_deferred()
	_names()
	var missing: Array = []
	for k: String in ["card", "locked", "deferred", "names"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- helpers ---------------------------------------------------------------------------------------------

func _world() -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.0})
	w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1200.0, "heading": 0.0})
	w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "ai", "x": 3000.0, "y": 3000.0, "heading": 0.0})
	return w

func _ui_on(w: World, player: String = "local") -> UnitUI:
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, Transform2D(0.0, Vector2(PPM, PPM), 0.0, Vector2.ZERO), player)
	ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)   # a window of this test's own size
	ui.hud.size = SIZE
	ui.result_play_again.connect(func() -> void: _again += 1)
	ui.result_menu.connect(func() -> void: _menu += 1)
	return ui

# What Mission.evaluate() returns for the Intercept mission, forced by the state of the units.
func _verdict(w: World, how: String) -> Dictionary:
	var m := Mission.new(w, Mission.intercept("bomber", [3000.0, 3000.0], 0.0))
	check(m.ok(), "the mission loads: %s" % str(m.errors))
	match how:
		"won":
			w.units["bomber"].down = true
			w.units["bomber"].down_at = 2.0
			w.units["bomber"].x = 100.0
			w.units["bomber"].y = 100.0
		"reached":
			pass   # the bomber sits on the target
		"fighters":
			w.units["bomber"].x = 100.0
			w.units["bomber"].y = 100.0
			w.units["p1"].down = true
			w.units["p2"].down = true
	return m.evaluate({"turn": 3})

func _click(card: Control, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = at
	card._gui_input(ev)

# --- 1 and 3: the card, its words and its buttons ---------------------------------------------------------------

func _card() -> void:
	var w := _world()
	var ui := _ui_on(w)
	var card: ResultCard = ui.result_card
	check(not card.visible and not ui.input_locked(), "no card before the mission ends")
	ui.show_result({"state": "playing", "reason": "", "turn": 1, "t": NAN})
	check(not card.visible, "a mission still playing shows nothing")
	ui.show_result({})
	check(not card.visible, "...nor an empty result")

	var won := _verdict(w, "won")
	eq(won["state"], "won", "(the mission says won: %s)" % str(won))
	ui.show_result(won)
	check(card.is_showing() and card.visible, "a won mission shows the card")
	eq(card.title_text(), _st.text("combat.result.text.won_title"), "the verdict is the data's victory")
	eq(card.reason_text(), "bomber down", "the reason in plain words: '%s' -> '%s'" % [won["reason"], card.reason_text()])
	eq(card.turn_text(), "on turn 3", "and the turn it was settled on")
	var r := card.card_rect()
	check(Rect2(Vector2.ZERO, SIZE).encloses(r) and absf(r.get_center().x - SIZE.x * 0.5) < 1.0, "the card is centred in the window (%s)" % str(r))
	var b := card.buttons()
	check(b.has("again") and b.has("menu"), "two buttons")
	check(r.encloses(b["again"]["rect"]) and r.encloses(b["menu"]["rect"]), "...on the card")
	check(not (b["again"]["rect"] as Rect2).intersects(b["menu"]["rect"]), "...side by side")
	eq(b["again"]["label"], _st.text("combat.result.text.again"), "Play again")
	eq(b["menu"]["label"], _st.text("combat.result.text.menu"), "and the way back to the menu")
	# The buttons emit the signals, once each, and only they do.
	_again = 0
	_menu = 0
	_click(card, r.position + Vector2(8.0, 8.0))
	_click(card, Vector2(5.0, 5.0))
	eq(_again + _menu, 0, "a click on the card's body or the veil does nothing")
	_click(card, (b["again"]["rect"] as Rect2).get_center())
	eq([_again, _menu], [1, 0], "Play again emits result_play_again")
	_click(card, (b["menu"]["rect"] as Rect2).get_center())
	eq([_again, _menu], [1, 1], "Back to the menu emits result_menu")
	check(card.press_button("again") and _again == 2, "press_button('again') does the same from code")
	ui.hide_result()
	check(not card.visible and not ui.input_locked(), "hide_result takes the card down")
	check(not card.press_button("again") and _again == 2, "...and its buttons are dead")

	# The lost mission, both ways to lose; and a reason no rule fits.
	var w2 := _world()
	var ui2 := _ui_on(w2)
	var reached := _verdict(w2, "reached")
	eq(reached["state"], "lost", "(the bomber on the target: lost: %s)" % str(reached))
	ui2.show_result(reached)
	eq(ui2.result_card.title_text(), _st.text("combat.result.text.lost_title"), "a lost mission says defeat")
	eq(ui2.result_card.reason_text(), "the bomber reached its target", "reason: '%s'" % reached["reason"])
	var w3 := _world()
	var ui3 := _ui_on(w3)
	var dead := _verdict(w3, "fighters")
	eq(dead["state"], "lost", "(both fighters down: lost: %s)" % str(dead))
	ui3.show_result(dead)
	eq(ui3.result_card.reason_text(), "both fighters down", "reason: '%s'" % dead["reason"])
	ui3.show_result({"state": "lost", "reason": "the weather turned", "turn": 9, "t": 1.0})
	eq(ui3.result_card.reason_text(), "the weather turned", "a reason no rule fits is shown as the mission wrote it")
	eq(ResultCard.reason_words(_st, w, "ghost is down"), "ghost down", "a unit the world does not have is named by its id")
	# The card draws whole (a frame is run by the engine; the draw is counted by the nodes themselves).
	_ran["card"] = true

# --- 2: planning input is locked --------------------------------------------------------------------------------

func _locked() -> void:
	var w := _world()
	var ui := _ui_on(w)
	var p := ui.marker_layer.marker("p1").position
	ui.select("p2")
	check(ui.map_press(p), "(before the card, a press on a plane selects it)")
	eq(ui.selection.unit_id, "p1", "(it selected p1)")
	ui.planner.release(p)
	check(ui.orders.buttons()["ready"]["enabled"], "(and Ready is on)")
	ui.show_result({"state": "won", "reason": "bomber is down", "turn": 2, "t": 1.0})
	check(ui.input_locked(), "the card locks planning input")
	ui.select("p2")
	check(not ui.map_press(ui.marker_layer.marker("p1").position), "a press on the map does nothing")
	check(not ui.map_press(Vector2(1000.0, 1000.0)), "...not even on the fan")
	check(not ui.map_drag(Vector2(1100.0, 1000.0)) and not ui.map_release(Vector2(1100.0, 1000.0)), "no drag, no release")
	eq(ui.planner.planned_count("p2"), 0, "no step was planned")
	ui.press_ready()
	check(not w.is_ready("local"), "Ready (by code) does nothing")
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	check(not ui._key(key), "...nor the Ready key")
	check(not w.is_ready("local"), "...no plane's players are ready")
	var b := ui.orders.buttons()
	var all_off := true
	for name: String in b:
		if bool(b[name]["enabled"]):
			all_off = false
	check(all_off, "every button of the orders card is off")
	check(not ui.orders.press_button("ready") and not w.is_ready("local"), "...and Ready by the card does nothing")
	ui.hide_result()
	check(not ui.input_locked(), "hide_result unlocks")
	check(ui.orders.buttons()["ready"]["enabled"], "...Ready is on again")
	ui.press_ready()
	check(w.is_ready("local"), "...and Ready works")
	_ran["locked"] = true

# --- 4: while a turn plays --------------------------------------------------------------------------------------

func _deferred() -> void:
	var w := CombatWorlds.world(CombatWorlds.find_hit_seed(), 8)
	var ui := _ui_on(w)
	CombatWorlds.turn(w)
	check(ui.is_playing(), "(a turn is playing)")
	ui.show_result({"state": "won", "reason": "bomber is down", "turn": 1, "t": 1.0})
	check(not ui.result_card.visible and not ui.input_locked(), "a result handed over mid-playback waits")
	CombatWorlds.play_out(ui)
	check(ui.result_card.is_showing() and ui.input_locked(), "...and shows when the playback ends")
	# From the turn_played signal (where a host evaluates the mission) it shows at once.
	ui.hide_result()
	var shown_in_handler := [false]   # (a lambda captures a local by value: a container carries the answer out)
	ui.turn_played.connect(func(_t: int) -> void:
		ui.show_result({"state": "lost", "reason": "bomber came within 150 m of the target", "turn": 2, "t": 2.0})
		shown_in_handler[0] = ui.result_card.is_showing())
	CombatWorlds.turn(w)
	CombatWorlds.play_out(ui)
	check(shown_in_handler[0], "handed over from turn_played it shows at once")
	eq(ui.result_card.reason_text(), "the bomber reached its target", "...with the reason in words")
	_ran["deferred"] = true

# --- 5: the players' names ------------------------------------------------------------------------------------

func _names() -> void:
	var w := _world()
	w.add_player("sam")
	var ui := _ui_on(w, "local")
	var marks: Array = ui.orders.ready_marks()
	var labels := {}
	for m: Dictionary in marks:
		labels[m["who"]] = m["label"]
	eq(labels.get("local"), "you", "this player is 'you'")
	eq(labels.get("sam"), "sam", "the default name of another player is its id")
	eq(labels.get(World.AI_PLAYER), "AI", "the AI is the AI")
	eq(ui.player_name.call("sam"), "sam", "UnitUI.player_name's default returns the id")
	var asked: Array = []
	ui.player_name = func(id: String) -> String:
		asked.append(id)
		return "Captain " + id.capitalize()
	labels.clear()
	for m: Dictionary in ui.orders.ready_marks():
		labels[m["who"]] = m["label"]
	eq(labels.get("sam"), "Captain Sam", "the ready marks print player_name's answer")
	eq(labels.get("local"), "you", "...but 'you' stays")
	eq(labels.get(World.AI_PLAYER), "AI", "...and the AI")
	check(asked == ["sam"], "player_name was asked about the other player and only that one: %s" % str(asked))
	w.commit("sam")
	var ready := false
	for m: Dictionary in ui.orders.ready_marks():
		if m["who"] == "sam":
			ready = bool(m["ready"])
	check(ready, "the ready mark follows the world")
	_ran["names"] = true
