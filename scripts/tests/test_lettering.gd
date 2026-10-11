extends "res://scripts/test_support/test_case.gd"

# LETTERING: TWO-LINE STEP LABELS, AND EVERY WORD READABLE OR LEFT OFF (Track L, 2026-10-10). Headless, on the real World, mounted
# through UnitUI and the sandbox's own cards. Alex, on the playtest: "2 lines. Remove the step # as well" and "Readable or leave it off".
#
#   1. THE DATA        the lettering block, the sizes every card reads, the face and the ink roles: nothing under the minimum, nothing
#                      italic, every word's ink clear of its paper by the data's contrast
#   2. THE SOURCE      no script puts a string on the screen except through UiInk.text / UiLabels.draw, none asks for the thin italic,
#                      and the two Godot Labels (the corner stamps) take their look from the style
#   3. THE STEP LABEL  two lines (speed over height), no step number, the special's words as a line of its own, a carry-on node the
#                      same; the proposed removal (the band line) behind its switch
#   4. WHAT IS DRAWN   the interface is driven through a bomber's plan with a Bomb Drop on step 2 and every card is made to draw (the
#                      roster, the orders card with its strip and its target lines, the side view, the node and unit labels, the
#                      refused marks, the clock and its warning, the key hint, the knob panel, the loading card, the TARGET ring, the
#                      result card): UiInk.logging records every string, and each is upright, at least lettering.min_px (the listed
#                      exceptions: a number inside a mark), in ink that reads against what is behind it, and inside its box
#   5. THE REMOVALS    the loading card's seed line is off by its switch and comes back with it
#   6. THE LAYOUT      1280x720 with three units in the roster: the cards are on screen, the side view under the orders card still
#                      shows (its picture at least the data's minimum), and the card sizes are what the data says

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")
const SandboxClock = preload("res://scripts/app/sandbox_clock.gd")
const SandboxHint = preload("res://scripts/app/sandbox_hint.gd")
const SandboxKnobs = preload("res://scripts/app/sandbox_knobs.gd")
const SandboxLoading = preload("res://scripts/app/sandbox_loading.gd")
const SandboxObjective = preload("res://scripts/app/sandbox_objective.gd")

const PPM := 1.0
const SCREEN := Vector2(1280.0, 720.0)

# The map host the TARGET ring reads: a Node2D with a scale.
class _Host extends Node2D:
	var px_per_m := 2.0

# What the F2 knob panel asks of the sandbox.
class _Knobs extends RefCounted:
	func knob_keys() -> Array[String]:
		return ["map_scale", "fog"]
	func knob_label(k: String) -> String:
		return "Map scale (px per m)" if k == "map_scale" else "Fog of war"
	func knob_text(k: String) -> String:
		return "2.0 px/m (data)" if k == "map_scale" else "on (data)"
	func knob_step(_k: String, _d: int) -> void:
		pass
	func frame_line() -> String:
		return "frame 23.0 ms (worst 142)  turn 1"

var _st: UiStyle
var _w: World
var _ui: UnitUI
var _holder: Control

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	if not check(_st.ok(), "the UI style data loads: %s" % str(_st.errors)):
		finish()
		return
	timeout_seconds = 60.0
	_check_data()
	_check_source()
	_build()
	_check_step_label()
	await _check_drawn()
	await _check_removals_and_layout()
	finish()

# --- 1. The data ------------------------------------------------------------------------------------------

func _check_data() -> void:
	var min_px := _st.min_px()
	check(min_px >= 14.0, "1. the lettering minimum is at least the size Track C chose for the labels (%s px)" % str(min_px))
	check(_st.text_px() >= min_px and UiLabels.px(_st) >= min_px, "1. the labels' own size is not under it (%s px)" % str(UiLabels.px(_st)))
	check(_st.fit_floor_px() >= 12.0 and _st.fit_floor_px() <= min_px, "1. a too-long line shrinks to at most %s px" % str(_st.fit_floor_px()))
	for k: String in ["fonts.title_px", "fonts.name_px", "fonts.detail_px", "fonts.button_px", "fonts.small_px", "labels.px", "combat.result.title_px",
			"combat.result.reason_px", "bombs.aim.label.px", "bombs.aoe.rings.label_px", "planner.cones.label_px", "target.blocked.label_px", "lettering.stamp.px"]:
		check(_st.num(k) >= min_px, "1. %s is %s px, not under %s" % [k, str(_st.num(k)), str(min_px)])
	# The numbers inside a mark (the step selection's, Track B): the one listed exception, and none of them under its floor.
	var ex: Dictionary = _st.lookup("lettering.exceptions")
	check(ex.has("mark_number") and ex.has("engine_theme"), "1. the exceptions are listed in the data, each with its reason")
	for k: String in ex:
		check(str((ex[k] as Dictionary).get("_why", "")).length() > 20, "1. exception '%s' says why" % k)
	var mark_min: float = float((ex["mark_number"] as Dictionary)["min_px"])
	for k: String in ["planner.select.number_px", "orders.strip.number_px", "bombs.pin.tag.px"]:
		check(_st.num(k) >= mark_min, "1. %s (%s px) is not under the mark-number floor (%s)" % [k, str(_st.num(k)), str(mark_min)])
	# The face: upright, semibold, by the data.
	var f := _st.text_font() as SystemFont
	if check(f != null and f == _st.label_font(), "1. the lettering face is the label face"):
		eq(f.font_italic, false, "1. upright, not the thin italic")
		check(f.font_weight >= 500, "1. a regular-to-semibold weight (%d)" % f.font_weight)
	# The ink: every role a word is drawn in reads against its paper (the card's fill, or the map's paper under the halo).
	var min_c: float = _st.num("lettering.contrast_min")
	for role: String in ["ink", "text_quiet"]:
		check(_contrast(_st.color(role), _st.color("card_fill")) >= min_c, "1. role '%s' on a card: contrast %.2f (>= %.1f)" % [role, _contrast(_st.color(role), _st.color("card_fill")), min_c])
	for role: String in ["label_ink", "label_carry"]:
		check(_contrast(_st.color(role), _st.palette["paper"]) >= min_c, "1. role '%s' on the map's paper: contrast %.2f (>= %.1f)" % [role, _contrast(_st.color(role), _st.palette["paper"]), min_c])
	check(_st.color("label_halo").a >= 0.95 and _st.num("labels.halo_px") >= 4.0, "1. a firm, wide paper halo for the map's words")
	eq(_st.errors.size(), 0, "1. no style lookups failed: %s" % str(_st.errors))

# --- 2. The source ----------------------------------------------------------------------------------------------

func _check_source() -> void:
	var offences := PackedStringArray()
	var scanned := 0
	for root: String in ["res://scripts/ui", "res://scripts/app", "res://scripts/fx", "res://scripts/render", "res://scripts/world", "res://scripts/sim"]:
		for path: String in _gd_files(root):
			var name := path.get_file()
			if path.contains("/boards/") or name.ends_with("_shot.gd") or name == "fx_sheet.gd":
				continue   # (board and shot tools are not the game)
			scanned += 1
			var src := FileAccess.get_file_as_string(path)
			var stamps := src.contains(".stamp(")
			for line: String in src.split("\n"):
				var t := line.strip_edges()
				if t.begins_with("#"):
					continue
				if t.contains(".font(true)"):
					offences.append("%s asks for the thin italic: %s" % [name, t])
				if (t.contains("draw_string(") or t.contains("draw_string_outline(")) and not ["ui_ink.gd", "ui_labels.gd"].has(name):
					offences.append("%s draws a string itself (go through UiInk.text or UiLabels.draw): %s" % [name, t])
				if t.contains("Label.new()") and not stamps:
					offences.append("%s makes a Label that never takes the style's stamp look: %s" % [name, t])
	check(scanned > 40, "2. the scan looked at the game's scripts (%d)" % scanned)
	eq(offences.size(), 0, "2. no thin italic, no string drawn behind the lettering log's back, no unstyled Label: %s" % "; ".join(offences))
	# The two Godot Labels take the look.
	var BuildVersion := load("res://scripts/ui/build_version.gd")
	var label: Label = BuildVersion.make_label()
	eq(label.get_theme_font_size("font_size"), int(_st.num("lettering.stamp.px")), "2. the build stamp is the data's size (not 12 px)")
	check(label.get_theme_font("font") == _st.text_font(), "2. in the label face")
	eq(label.get_theme_color("font_color").a, 1.0, "2. in full ink")
	check(label.get_theme_constant("outline_size") >= 4, "2. with a paper outline")
	label.free()

func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f: String in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	for sub: String in d.get_directories():
		out.append_array(_gd_files(dir_path.path_join(sub)))
	return out

# --- the world ----------------------------------------------------------------------------------------------

func _build() -> void:
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2600.0, "heading": 0.0})
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2800.0, "heading": 0.0})
	_w.add_unit({"id": "e1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 2300.0, "y": 2300.0, "heading": PI, "altitude_band": "low"})
	_w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2700.0, "y": 2800.0, "heading": 0.0})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		return
	_holder = Control.new()
	_holder.size = SCREEN
	add_child(_holder)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1300.0, 2200.0) * PPM)
	_ui = UnitUI.new()
	_holder.add_child(_ui)
	_ui.setup(_w, xf, "local")
	_ui.auto_resolve = false
	_ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ui.hud.size = SCREEN
	_ui.layout()

# --- 3. The step label --------------------------------------------------------------------------------------

func _check_step_label() -> void:
	_ui.select("b1")
	var pl = _ui.planner
	pl.clear()
	for k in 3:
		check(not pl.place_point(Vector2(1500.0 + 140.0 * float(k + 1), 2800.0)).is_empty(), "3. step %d is placed" % (k + 1))
	pl.select_step(1)
	# The tower where step 2's bombs can fall on it (the cone's ideal aim), so the drop can be switched on there.
	var ideal: Vector2 = pl.bombs.cone("b1", 1)["ideal_aim"]
	_w.units["tower"].x = ideal.x
	_w.units["tower"].y = ideal.y
	_ui.marker_layer.update_poses()
	_ui.set_target_unit("tower")
	check(_ui.orders.press_button("drop"), "3. Bomb Drop is pressed on step 2")
	var st: Array = pl.states("b1")
	var labels: Array = pl.step_labels("b1")
	var special: String = pl.special_label("b1")
	eq(special, "Bomb Drop", "3. the special's words come from the unit's data")
	for k in 3:
		var lines: PackedStringArray = labels[k]
		eq(lines[0], "%d m/s" % roundi(float(st[k]["speed"])), "3. step %d: the first line is the speed" % (k + 1))
		eq(lines[1], "%d m" % roundi(_w.band_height(str(st[k]["altitude_band"]))), "3. step %d: the second is the height" % (k + 1))
		for ln: String in lines:
			check(not ln.contains("·") and not ln.begins_with("%d " % (k + 1)), "3. step %d: no step number in '%s'" % [k + 1, ln])
	eq(labels[0].size(), 2, "3. a step without its special is two lines")
	eq(labels[1].size(), 3, "3. a step with its special on has the special's words as a third line")
	eq(labels[1][2], special, "3. 'Bomb Drop'")
	eq(labels[2].size(), 2, "3. and the step after it is two lines again")
	# A carry-on node (the light fighter has five steps a turn, two of them planned): the same lines (it was a one-line "76 m/s · 400 m"),
	# in the fainter ink the draw routine picks (label_carry).
	_ui.select("p1")
	pl.clear()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 130.0})
	_w.plan_step("p1", 1, {"turn": 0.0, "speed": 60.0})
	var fl: Array = pl.step_labels("p1")
	eq(fl.size(), 5, "3. the fighter has five steps, two of them planned")
	for k in 5:
		eq((fl[k] as PackedStringArray).size(), 2, "3. step %d (%s) has two lines" % [k + 1, "planned" if k < 2 else "carry-on"])
	eq(fl[3][0], "%d m/s" % roundi(float(pl.states("p1")[3]["speed"])), "3. a carry-on node says its speed ...")
	eq(fl[3][1], "400 m", "3. ... over its height")
	check(_st.color("label_carry").a < _st.color("label_ink").a, "3. and a fainter ink (alpha %s against %s)" % [str(_st.color("label_carry").a), str(_st.color("label_ink").a)])
	pl.clear()
	_ui.select("b1")
	# The proposed removal and its switch: the band line.
	eq(_st.flag("labels.band_change_line"), false, "3. the band line is off by default (proposed removal)")
	pl.select_step(1)
	check(not pl.change_band(-1).is_empty(), "3. step 2 dives (the bomber starts high)")
	eq((pl.step_labels("b1")[1] as PackedStringArray).has("dive to medium"), false, "3. a diving step does not say 'dive to medium' ...")
	_st.ui["labels"]["band_change_line"] = true
	eq((pl.step_labels("b1")[1] as PackedStringArray).has("dive to medium"), true, "3. ... until the data's switch is turned on")
	_st.ui["labels"]["band_change_line"] = false
	pl.change_band(0)

# --- 4. What is drawn -----------------------------------------------------------------------------------------

func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame

func _check_drawn() -> void:
	var pl = _ui.planner
	# Every card the sandbox adds, mounted beside the interface.
	var clock := SandboxClock.new()
	_holder.add_child(clock)
	_w.turn = 18   # (two turns from the end of 20: the warning line)
	clock.setup(_st, _w, 20, _ui.sidebar_width_px())
	var hint := SandboxHint.new()
	_holder.add_child(hint)
	hint.headline = "STRIKE  -  bring the bomber over the village and destroy the radio tower by turn 20; the fighters keep the patrol off it."
	hint.setup(_st, "F2 knobs   ·   Esc menu   ·   right-drag or WASD pans   ·   wheel or Q E zooms   ·   Enter readies   ·   click an enemy or right-click the map to aim a drop", 16.0)
	hint.start()
	var knobs := SandboxKnobs.new()
	_holder.add_child(knobs)
	knobs.setup(_Knobs.new(), _st)
	knobs.visible = true
	var loading := SandboxLoading.new()
	_holder.add_child(loading)
	loading.setup(_st, true)
	loading.seed_text = 20261009
	loading.set_progress(12, 27, 8.0)
	if loading.has_method("set_fog_progress"):   # (the map-speed track's fog progress, when the card has it)
		loading.call("set_fog_progress", 300, 1200, 0.3)
	var host := _Host.new()
	_holder.add_child(host)
	var ring := SandboxObjective.new()
	_holder.add_child(ring)
	ring.setup(host, _st, Vector2(2700.0, 2800.0), 120.0, "TARGET")
	# The refused marks (they live REFUSED_SHOW_MS of real time: the frames below take far less).
	pl.refused_world = Vector2(1900.0, 2800.0)
	pl.refused_ms = Time.get_ticks_msec()
	pl.refused_aim = Vector2(1800.0, 2900.0)
	pl.refused_aim_ms = Time.get_ticks_msec()
	_ui.select("b1")
	pl.select_step(1)
	await _frames(3)
	UiInk.logging = true
	UiInk.drawn.clear()
	_redraw_all([clock, hint, knobs, loading, ring])
	await _frames(3)
	var base := UiInk.drawn.duplicate()
	# The result card, over everything (planning input is locked while it shows).
	_ui.show_result({"state": "won", "reason": "tower is down", "turn": 7, "t": 1.0})
	_redraw_all([])
	await _frames(3)
	_ui.hide_result()
	UiInk.logging = false
	var entries: Array = UiInk.drawn.duplicate()
	print("[test] the interface drew %d strings (%d before the result card)" % [entries.size(), base.size()])
	check(entries.size() > 60, "4. the log holds what the interface drew (%d strings)" % entries.size())

	# Where each came from: every card and mark must be in it, or the rule is not looking at it.
	var sources := {}
	for e: Dictionary in entries:
		var name := _source_of(e)
		sources[name] = int(sources.get(name, 0)) + 1
	print("[test] strings by source: %s" % str(sources))
	for src: String in ["roster.gd", "motion_planner_panel.gd", "side_view.gd", "motion_planner.gd", "unit_marker_layer.gd", "sandbox_clock.gd",
			"sandbox_hint.gd", "sandbox_knobs.gd", "sandbox_loading.gd", "sandbox_objective.gd", "result_card.gd"]:
		check(sources.has(src), "4. %s's words are in the log" % src)

	var by_text := {}
	for e: Dictionary in entries:
		by_text[str(e["text"])] = e
	for s: String in ["TARGET", "off the map", "outside the cone", "Bomb Drop", "85 m/s", "400 m", "2 turns left", "turn 18 of 20", "views, step 2"]:
		check(by_text.has(s) or _any_text_contains(entries, s), "4. '%s' is on the screen" % s)
	check(_any_text_contains(entries, "plan: 3 of 3 steps") or _any_text_contains(entries, "no plan (flies on)"), "4. the roster's plan status is on the screen")
	check(_any_text_contains(entries, "Bomber · 85 m/s · high"), "4. the roster's second line is on the screen")
	check(_any_text_contains(entries, "target: radio tower"), "4. the orders card's target line is on the screen")
	check(_any_text_contains(entries, "you planning") or _any_text_contains(entries, "AI ready"), "4. the ready marks are on the screen")
	check(_any_text_contains(entries, "mission accomplished"), "4. the result card's lines are on the screen")

	# THE RULE, on every string.
	var fits: Array[String] = []
	var small_marks := 0
	var worst_c := 99.0
	var smallest := 99.0
	for e: Dictionary in entries:
		var kind := str(e["kind"])
		var where := "'%s' (%s, %s px, from %s)" % [str(e["text"]), kind if kind != "" else "plain", str(e["px"]), _source_of(e)]
		var broken := _violations(e)
		check(broken.is_empty(), "4. %s breaks the rule: %s" % [where, "; ".join(broken)])
		if kind == "mark_number":
			small_marks += 1
		elif kind == "fit":
			fits.append(where)
		smallest = minf(smallest, float(e["px"]))
		worst_c = minf(worst_c, _ratio_of(e))
	print("[test] smallest string %s px; %d number(s) inside marks; worst contrast %.2f; shrunk to fit: %s" % [str(smallest), small_marks, worst_c, str(fits)])
	# (a line's width is a property of the machine's fonts, so a line that shrank is listed above, not failed, as long as it kept the floor)
	check(small_marks >= 3, "4. the numbers inside the marks were drawn and checked (%d)" % small_marks)
	_check_rule_has_teeth()

	# The orders card's own lines at their drawn size: the longest the data and the card can say at the card's width.
	var panel = _ui.orders
	var detail := _st.num("fonts.detail_px")
	var tf := _st.text_font()
	var longest: Array[String] = [_st.text("bombs.text.target_none"), _st.text("orders.text.hint_full"), _st.text("orders.text.hint_more") % 3,
		"altitude, step 3:  medium  to  medium", _st.text("bombs.text.target_unit") % "radio tower" + _st.text("bombs.text.target_accuracy") % 100,
		_st.text("bombs.text.expected_on") % [2, "Bomb Drop", "radio tower", "5", 8], _st.text("bombs.text.free") % [3, "Bomb Drop", 2, 3],
		_st.text("bombs.text.wont_release"), _st.text("bombs.text.target_outside") % 2, _st.text("bombs.text.on") % [2, "Bomb Drop", 45]]
	for s: String in longest:
		var fp: float = panel.fitted_px(tf, s, detail)
		print("[test] the card says '%s' at %s px" % [s, str(fp)])
		check(fp >= _st.min_px() - 1.0, "4. the card says '%s' at %s px, at most one px under %s (a font a little wider than this machine's)" % [s, str(fp), str(_st.min_px())])
	# A long unit name is the case the shrink is for: it shrinks, never under the floor, and then fits.
	var very_long: String = _st.text("bombs.text.expected_on") % [2, "Bomb Drop", "anti-aircraft battery on the ridge", "5", 8]
	var fp2: float = panel.fitted_px(tf, very_long, detail)
	check(fp2 >= _st.fit_floor_px() and fp2 < detail, "4. a very long line shrinks (%s px), never under the floor (%s)" % [str(fp2), str(_st.fit_floor_px())])

func _redraw_all(extra: Array) -> void:
	for c: CanvasItem in [_ui.roster, _ui.orders, _ui.planner, _ui.marker_layer, _ui.result_card] + extra:
		if c != null:
			c.queue_redraw()
	var sv: Variant = _ui.get_meta("side_view", null)
	if sv != null:
		(sv as CanvasItem).queue_redraw()
	if _ui.marker_layer.get("_marks") != null:
		(_ui.marker_layer.get("_marks") as CanvasItem).queue_redraw()

# THE RULE for one drawn string (a record of UiInk.drawn): what it breaks, as words; empty when it breaks nothing.
func _violations(e: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var s := str(e["text"])
	var px := float(e["px"])
	var kind := str(e["kind"])
	var font: Font = e["font"]
	if not (font is SystemFont) or (font as SystemFont).font_italic:
		out.append("it is in an italic or an unknown face")
	if kind == "mark_number":
		var mark_min: float = float((_st.lookup("lettering.exceptions.mark_number") as Dictionary)["min_px"])
		if px < mark_min:
			out.append("a number in a mark under %s px" % str(mark_min))
	elif kind == "fit":
		if px < _st.fit_floor_px():
			out.append("a shrunk line under the floor (%s px)" % str(_st.fit_floor_px()))
	elif px < _st.min_px():
		out.append("under %s px" % str(_st.min_px()))
	var ratio := _ratio_of(e)
	if ratio < _st.num("lettering.contrast_min"):
		out.append("contrast %.2f against what is behind it" % ratio)
	var wbox := float(e["width"])
	if wbox > 0.0 and kind != "fit" and UiInk.text_width(font, s, px) > wbox + 0.5:
		out.append("%.0f px wide in a %.0f px box" % [UiInk.text_width(font, s, px), wbox])
	return out

# The contrast of a drawn string's ink against what is behind it: the card's fill, the map's paper under the halo, or (paper lettering)
# the ink of a pressed button or a selected node's disc.
func _ratio_of(e: Dictionary) -> float:
	var c: Color = e["color"]
	var bg: Color = _st.palette["paper"] if bool(e["on_paper"]) else _st.color("card_fill")
	if _luminance(c) > 0.45:
		bg = _st.color("button_on_fill")
	elif str(e["kind"]) == "mark_number":
		bg = _st.color("button_fill")   # (an ink number is in a paper disc)
	return _contrast(c, bg)

# The rule is only worth having if it can fail: the old lettering, fed through it, is caught on every count.
func _check_rule_has_teeth() -> void:
	var good := {"node": null, "font": _st.text_font(), "text": "Bomber · 85 m/s · high", "px": 14.0, "color": _st.color("ink"), "on_paper": false, "kind": "", "width": 250.0}
	eq(_violations(good).size(), 0, "4. (the rule passes a plain 14 px line in full ink)")
	var old_small := good.duplicate()
	old_small["font"] = _st.font(true)
	old_small["px"] = 11.0
	old_small["color"] = _st.color("ink_soft")
	var v1 := _violations(old_small)
	check(v1.size() >= 2 and "; ".join(v1).contains("italic") and "; ".join(v1).contains("under"), "4. (and catches the old thin italic at 11 px: %s)" % "; ".join(v1))
	var pale := good.duplicate()
	pale["color"] = _st.color("ink_faint")
	check(_violations(pale).size() == 1 and "; ".join(_violations(pale)).contains("contrast"), "4. (and a pale grey word: %s)" % "; ".join(_violations(pale)))
	var wide := good.duplicate()
	wide["width"] = 40.0
	check("; ".join(_violations(wide)).contains("box"), "4. (and a word wider than its box)")
	var tiny_mark := good.duplicate()
	tiny_mark["kind"] = "mark_number"
	tiny_mark["px"] = 8.0
	check("; ".join(_violations(tiny_mark)).contains("mark"), "4. (and a number in a mark that is too small)")
	var plain_small := good.duplicate()
	plain_small["px"] = 12.0
	check(_violations(plain_small).size() == 1, "4. (and a 12 px line that is not a listed exception)")

# The script a drawn string came from: its node's, or its parent's for a bare drawing node (the marker layer's marks).
func _source_of(e: Dictionary) -> String:
	var node: Object = e["node"]
	if node == null or not is_instance_valid(node):
		return "?"
	if (node as Object).get_script() != null:
		return ((node as Object).get_script() as Script).resource_path.get_file()
	var p: Node = (node as Node).get_parent()
	if p != null and p.get_script() != null:
		return (p.get_script() as Script).resource_path.get_file()
	return "?"

func _any_text_contains(entries: Array, needle: String) -> bool:
	for e: Dictionary in entries:
		if str(e["text"]).contains(needle):
			return true
	return false

# --- 5. The removals, 6. the layout ------------------------------------------------------------------------------

func _check_removals_and_layout() -> void:
	# The loading card's seed line: not drawn by default, drawn (readable) when the data's switch is on.
	eq(_st.flag("lettering.show.loading_seed"), false, "5. the loading card's seed line is a proposed removal, off by default")
	var off: Array = await _loading_texts()
	check(not _any_text_contains(off, "the same map every time"), "5. so the loading card does not say 'the same map every time'")
	check(_any_text_contains(off, " of "), "5. (its progress line is still there)")
	_st.ui["lettering"]["show"]["loading_seed"] = true
	var on: Array = await _loading_texts()
	_st.ui["lettering"]["show"]["loading_seed"] = false
	check(_any_text_contains(on, "the same map every time: seed 20261009"), "5. and says it again when the switch is on")
	for e: Dictionary in on:
		if str(e["text"]).contains("seed"):
			check(float(e["px"]) >= _st.min_px(), "5. (and then at %s px, not 11)" % str(e["px"]))

	# 1280x720 with three units: the sidebar is on screen and the side view still shows under the orders card.
	var roster: Control = _ui.roster
	var orders: Control = _ui.orders
	eq(roster.size.x, _st.num("roster.width_px"), "6. the roster is the data's width (%s px; it was 286)" % str(_st.num("roster.width_px")))
	eq(orders.size.x, roster.size.x, "6. and the orders card is as wide")
	check(roster.position.y + roster.size.y < orders.position.y, "6. the roster is above the orders card")
	check(orders.position.y + orders.size.y <= SCREEN.y - _st.num("card.margin_px") + 0.5, "6. the orders card is on screen at 720 px (bottom %.0f)" % (orders.position.y + orders.size.y))
	check(roster.position.x + roster.size.x <= SCREEN.x - _st.num("card.margin_px") + 0.5, "6. and inside the right edge")
	var sv: Variant = _ui.get_meta("side_view", null)
	if check(sv != null, "6. the side view is mounted under the orders card"):
		var view: Object = sv
		check(bool(view.call("is_active")), "6. the side view is showing for the selected bomber")
		var m: Dictionary = view.call("model")
		var pic: Vector2 = m["size"]
		check(pic.y >= _st.num("side_view.section.min_picture_h_px"), "6. its picture is %.0f x %.0f px, not under the data's minimum (%s)" % [pic.x, pic.y, str(_st.num("side_view.section.min_picture_h_px"))])
		print("[test] at 1280x720 with 3 units the roster is %.0f x %.0f, the orders card %.0f x %.0f (base %s), the side view's picture %.0f x %.0f px" % [roster.size.x, roster.size.y, orders.size.x, orders.size.y, str(_st.num("orders.height_px")), pic.x, pic.y])
	eq(_st.num("orders.height_px"), 276.0, "6. the orders card's own height did not grow (276 px): only the width did")

# What a blocking loading card draws, as the log has it.
func _loading_texts() -> Array:
	var card := SandboxLoading.new()
	_holder.add_child(card)
	card.setup(_st, true)
	card.seed_text = 20261009
	card.set_progress(12, 27, 8.0)
	if card.has_method("set_fog_progress"):
		card.call("set_fog_progress", 300, 1200, 0.3)
	await _frames(2)
	UiInk.logging = true
	UiInk.drawn.clear()
	card.queue_redraw()
	await _frames(2)
	UiInk.logging = false
	var out := UiInk.drawn.duplicate()
	card.queue_free()
	return out

# --- helpers --------------------------------------------------------------------------------------------------------

# WCAG relative luminance, and the contrast ratio of `fg` (blended over `bg` by its alpha) against `bg`.
func _luminance(c: Color) -> float:
	var f := func(v: float) -> float:
		return v / 12.92 if v <= 0.03928 else pow((v + 0.055) / 1.055, 2.4)
	return 0.2126 * float(f.call(c.r)) + 0.7152 * float(f.call(c.g)) + 0.0722 * float(f.call(c.b))

func _contrast(fg: Color, bg: Color) -> float:
	var seen := Color(bg.r + (fg.r - bg.r) * fg.a, bg.g + (fg.g - bg.g) * fg.a, bg.b + (fg.b - bg.b) * fg.a, 1.0)
	var a := _luminance(seen)
	var b := _luminance(Color(bg.r, bg.g, bg.b, 1.0))
	return (maxf(a, b) + 0.05) / (minf(a, b) + 0.05)
