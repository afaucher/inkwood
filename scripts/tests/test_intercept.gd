extends "res://scripts/test_support/test_case.gd"

# INTERCEPT, THE FIRST FIGHT, ASSEMBLED (Track A, 2026-10-10): data/scenarios/intercept.json
# behind the menu, the AI that flies the enemy, the mission that judges the game, the result
# card and Play again -- and the same game over a real ENet socket between a host and a client.
# Headless, so no pixels (scripts/app/intercept_shot.gd is the windowed proof). Combat's odds are
# still being tuned (Track C), so nothing here depends on a particular seed winning: the chase
# looks for a winning seed at run time, in a bounded range, and asserts that one exists.
#
#   1. THE SCENARIO STANDS UP   reads cleanly; two player fighters (a light and a heavy, callsigns
#      from the pools) and two AI units (the bomber HIGH and its escort), all on the map; the
#      players start where they cannot see the enemy; the AI is the pilot, attached, the bomber
#      on its route and the escort on station; the Mission is attached and playing; the target
#      ring is data.
#   2. DOING NOTHING IS A LOSS  the bomber flies its route (past both waypoints) and reaches the
#      target in about twelve turns: lost, with the reason, on a turn between 10 and 14.
#   3. THE OTHER ENDS, FORCED   both fighters down is a loss (the bomber nowhere near its target);
#      the bomber down is a win. Forced through the World, so combat's odds cannot move them.
#   4. A CHASE CAN WIN          a scripted lead pursuit (scripts/test_support/intercept_play.gd,
#      omniscient) wins on some seed in 1..SEEDS: the bomber really is shot down, with hits on it
#      in the events; the same seed plays out the same way twice.
#   5. LOCAL, THROUGH THE MENU  Local starts Intercept by default; the sandbox attaches the pilot
#      and the mission, frames only the players' own planes (never the enemy's plan), gives the
#      camera the HUD insets, hides the enemy in the fog; a game played through the interface to
#      its end puts the result card up once (after the playback), Play again replaces the sandbox
#      with a fresh game, and Menu returns to the menu.
#   6. OVER THE NET             a host and a client, each a complete sandbox: the AI exists on the
#      host only; the client's mission reaches the host's verdict from the applied results; the
#      cards name players by the sync's names; both put the card up; the client's Play again asks
#      the host, the host replaces its sandbox and tells the client to replace its own, and the
#      new game is joined as a game is joined the first time.
#
# Port 28782 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const InterceptPlay = preload("res://scripts/test_support/intercept_play.gd")

const PORT := 28782
const SEEDS := 40          # how many combat seeds the chase may try before the test calls the scenario unwinnable
const LIGHT := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const BOMBER := "bomber_1"
const ESCORT := "escort_1"

var _main: Node = null
var _saved_scenario := 0
var _saved_speed := 0
var _saved_net := 0
var rig: NetRig = null
var _boxes: Dictionary = {}       # "host" | "client" -> the peer's current Sandbox (replaced by Play again)
var _roots: Dictionary = {}       # "host" | "client" -> the peer's root node

func setup(main) -> void:
	timeout_seconds = 300.0
	_main = main
	_saved_scenario = DebugSettings.get_choice("scenario")
	_saved_speed = DebugSettings.get_choice("playback_speed")
	DebugSettings.set_choice("scenario", 0)          # intercept: the default, whatever the environment says
	DebugSettings.set_choice("playback_speed", 4)    # x8: the knob only changes how fast the markers animate
	main.get_window().size = Vector2i(1280, 720)
	for part: Script in [NetRig, WorldSync, World, Sandbox, SandboxScenario, InterceptPlay]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_scenario()
	_idle_is_a_loss()
	_forced_ends()
	_chase_can_win()
	var local_ok: Variant = await _local()
	check(local_ok == true, "the local part ran to its last line (a runtime error would have ended it silently)")
	rig = NetRig.new()
	add_child(rig)
	var net_ok: Variant = await _net()
	check(net_ok == true, "the network part ran to its last line (a runtime error would have ended it silently)")
	DebugSettings.set_choice("scenario", _saved_scenario)
	DebugSettings.set_choice("playback_speed", _saved_speed)
	finish()

# --- 1. The scenario -----------------------------------------------------------------------------

func _scenario() -> void:
	var sc := SandboxScenario.new("intercept")
	if not check(sc.ok(), "1. the Intercept scenario reads cleanly: %s" % str(sc.errors)):
		return
	eq(sc.ai_kind, SandboxScenario.AI_PILOT, "1. it asks for the pilot AI")
	eq(sc.units.size(), 4, "1. four units")
	var by_id: Dictionary = {}
	var pools: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SandboxScenario.CALLSIGNS_PATH))
	var seen: Dictionary = {}
	var bounds := World.new().bounds
	for spec: Dictionary in sc.units:
		by_id[str(spec["id"])] = spec
		check(bounds.has_point(Vector2(float(spec["x"]), float(spec["y"]))), "1. %s starts on the map" % spec["id"])
		var pool_name := ""
		for k: String in sc.sides:
			if (sc.sides[k] as Dictionary)["world_side"] == spec["side"]:
				pool_name = str((sc.sides[k] as Dictionary)["callsign_pool"])
		var names: Array = (pools[pool_name] as Dictionary).get(spec["type"], [])
		check(spec.has("callsign") and names.has(spec["callsign"]), "1. %s's callsign comes from the %s pool" % [spec["id"], pool_name])
		check(not seen.has(spec.get("callsign", "")), "1. no callsign twice")
		seen[spec.get("callsign", "")] = true
	for id: String in [LIGHT, HEAVY, BOMBER, ESCORT]:
		check(by_id.has(id), "1. the scenario has %s" % id)
	eq(by_id[LIGHT]["type"], "light_fighter", "1. player 1 is the light fighter")
	eq(by_id[HEAVY]["type"], "heavy_fighter", "1. player 2 is the heavy fighter")
	eq(by_id[BOMBER]["type"], "bomber", "1. the enemy bomber")
	eq(by_id[ESCORT]["type"], "light_fighter", "1. and one escort fighter")
	eq(by_id[LIGHT]["controller"], "player", "1. the fighters are the players'")
	eq(by_id[BOMBER]["controller"], "ai", "1. the bomber is the AI's")
	eq(by_id[BOMBER]["altitude_band"], "high", "1. the bomber starts HIGH (Alex: the players must climb)")
	check(not by_id[LIGHT].has("altitude_band") or by_id[LIGHT]["altitude_band"] != "high", "1. and the players do not")
	check(sc.ai_assignments.has(BOMBER) and sc.ai_assignments.has(ESCORT), "1. the AI has orders for the bomber and the escort")
	eq(sc.ai_assignments[BOMBER]["role"], "strike", "1. the bomber strikes")
	eq(sc.ai_assignments[ESCORT]["role"], "escort", "1. the escort escorts")
	eq(sc.ai_assignments[ESCORT]["protect"], BOMBER, "1. the bomber")
	var target := sc.objective()
	check(not target.is_empty(), "1. the mission names a target ring")
	if not target.is_empty():
		check(bounds.has_point(target["point"]), "1. the target is on the map")
		near(float(target["radius_m"]), 300.0, 1e-9, "1. with the capture radius of the AI data")
	for k: String in ["fog", "plane_px", "plane_min_px", "start_zoom_max", "start_pad_m", "start_look_ahead_turns", "start_frame_objective", "track_sample_s", "track_line_px", "bake_pause_overview", "result_card_delay_s"]:
		check(sc.view.has(k), "1. view.%s is in the scenario" % k)
	check(sc.briefing != "", "1. and a briefing line")

	# Standing up: the World, the pilot and the mission, as the sandbox attaches them.
	var g := InterceptPlay.new("intercept", 7)
	if not check(g.ok(), "1. the scenario stands up as a game: %s" % str(g.errors)):
		return
	eq(g.world.units.size(), 4, "1. the World has four units")
	eq(g.player_ids().size(), 2, "1. two of them the players'")
	check(g.ai is AiPilot, "1. the AI is the pilot")
	eq(g.ai.state_of(BOMBER), AiPilot.S_ROUTE, "1. the bomber is on its route")
	eq(g.ai.state_of(ESCORT), AiPilot.S_STATION, "1. the escort on station")
	check(g.world.is_ready(World.AI_PLAYER), "1. the AI has planned and readied")
	check(g.mission != null and g.mission.ok() and g.mission.state == Mission.PLAYING, "1. the mission is attached and playing")
	eq(g.world.rng_seed, 7, "1. the combat seed is the one asked for (a scenario sets it; the host rolls)")
	eq(SandboxScenario.new("intercept").rng_seed, 7, "1. and the scenario's own is its rng_seed")
	# The fog has something to hide: nobody sees anybody to begin with, and the bomber is higher than the players.
	var fighters: Array[Unit] = [g.world.units[LIGHT], g.world.units[HEAVY]]
	for f: Unit in fighters:
		for e_id: String in [BOMBER, ESCORT]:
			var e: Unit = g.world.units[e_id]
			var d := Vector2(f.x, f.y).distance_to(Vector2(e.x, e.y))
			check(d > maxf(float(f.def.sight_range_m), float(e.def.sight_range_m)), "1. %s and %s start %.0f m apart, out of each other's sight" % [f.id, e_id, d])
	check(g.world.band_height(g.world.units[BOMBER].altitude_band) > g.world.band_height(g.world.units[LIGHT].altitude_band), "1. the bomber starts above the players")

# --- 2. Doing nothing is a loss -----------------------------------------------------------------------

func _idle_is_a_loss() -> void:
	var g := InterceptPlay.new("intercept", 7)
	if not g.ok():
		fail("2. the game did not stand up: %s" % str(g.errors))
		return
	var r: Dictionary = g.play("idle", 20)
	eq(r["state"], Mission.LOST, "2. nobody plans anything: the bomber reaches the target, lost")
	check(int(r["turn"]) >= 10 and int(r["turn"]) <= 14, "2. on turn %d (about twelve turns of route, 10 to 14 expected)" % int(r["turn"]))
	check(str(r["reason"]).contains(BOMBER) and str(r["reason"]).contains("target"), "2. the reason says so: %s" % str(r["reason"]))
	check(not g.world.units[BOMBER].down, "2. the bomber is not down")
	for id: String in g.player_ids():
		check(not g.world.units[id].down, "2. and %s is not either: nobody fought" % id)
	eq(int(r["turns"]), int(r["turn"]), "2. the turn counter and the mission agree")
	# It flew its route: past both waypoints, then at the target.
	var wp1 := Vector2(2300.0, 1000.0)
	var wp2 := Vector2(3500.0, 1900.0)
	check(g.nearest_pass(BOMBER, wp1) < 300.0, "2. the bomber passed its first waypoint (nearest %.0f m)" % g.nearest_pass(BOMBER, wp1))
	check(g.nearest_pass(BOMBER, wp2) < 300.0, "2. and its second (nearest %.0f m)" % g.nearest_pass(BOMBER, wp2))
	check(g.nearest_pass(BOMBER, Vector2(3600.0, 3900.0)) <= 300.0, "2. and came to the target ring (nearest %.0f m)" % g.nearest_pass(BOMBER, Vector2(3600.0, 3900.0)))
	check(int(g.ai.info(BOMBER)["wp"]) >= 2, "2. the pilot counted the waypoints off")
	eq(g.ai.state_of(ESCORT), AiPilot.S_STATION, "2. the escort stayed on station: nobody came near")
	var b: Unit = g.world.units[BOMBER]
	var e: Unit = g.world.units[ESCORT]
	check(Vector2(b.x, b.y).distance_to(Vector2(e.x, e.y)) < 600.0, "2. and flew with the bomber (%.0f m apart at the end)" % Vector2(b.x, b.y).distance_to(Vector2(e.x, e.y)))
	# Sticky: the mission stays lost.
	eq(g.mission.evaluate({"turn": 99})["state"], Mission.LOST, "2. a decided mission stays decided")

# --- 3. The other ends, forced -------------------------------------------------------------------------

func _down(u: Unit, at: float) -> void:
	u.health = 0
	u.down = true
	u.down_at = at
	u.fate = Unit.FATE_EXPLODED

func _forced_ends() -> void:
	# Both fighters down: lost, with the bomber nowhere near its target.
	var g := InterceptPlay.new("intercept", 7)
	for id: String in g.player_ids():
		_down(g.world.units[id], NAN)
	var r: Dictionary = g.play("idle", 3)
	eq(r["state"], Mission.LOST, "3. both fighters down: lost")
	eq(int(r["turn"]), 1, "3. on the first resolve that sees it")
	check(str(r["reason"]).contains("player") and str(r["reason"]).contains("down"), "3. the reason names the players: %s" % str(r["reason"]))
	check(Vector2(g.world.units[BOMBER].x - 3600.0, g.world.units[BOMBER].y - 3900.0).length() > 2000.0, "3. the bomber was nowhere near the target")
	# One fighter down is not the end.
	var g1 := InterceptPlay.new("intercept", 7)
	_down(g1.world.units[LIGHT], NAN)
	var r1: Dictionary = g1.play("idle", 2)
	eq(r1["state"], Mission.PLAYING, "3. one fighter down: still playing")
	# The bomber down: won.
	var g2 := InterceptPlay.new("intercept", 7)
	_down(g2.world.units[BOMBER], NAN)
	var r2: Dictionary = g2.play("idle", 3)
	eq(r2["state"], Mission.WON, "3. the bomber down: won")
	check(str(r2["reason"]).contains(BOMBER), "3. the reason names it: %s" % str(r2["reason"]))

# --- 4. A chase can win ------------------------------------------------------------------------------------

func _chase_can_win() -> void:
	var won_seed := -1
	var won_turn := 0
	var wins := 0
	var losses := 0
	var open := 0
	var t0 := Time.get_ticks_msec()
	var first: InterceptPlay = null
	for s in range(1, SEEDS + 1):
		var g := InterceptPlay.new("intercept", s)
		var r: Dictionary = g.play("chase", 18)
		match str(r["state"]):
			Mission.WON:
				wins += 1
				if won_seed < 0:
					won_seed = s
					won_turn = int(r["turn"])
					first = g
			Mission.LOST:
				losses += 1
			_:
				open += 1
		if won_seed >= 0 and s >= 8:
			break   # a win found, and a few more seeds seen for the report
	print("[test] chase: %d won, %d lost, %d undecided over the first seeds tried; first win on seed %d (turn %d); %.1f s" % [wins, losses, open, won_seed, won_turn, (Time.get_ticks_msec() - t0) / 1000.0])
	if not check(won_seed >= 0, "4. the scripted chase wins on some seed in 1..%d (it won on none: the scenario cannot be won, or combat's odds moved it out of reach)" % SEEDS):
		return
	var w: World = first.world
	check(w.units[BOMBER].down, "4. the bomber is down")
	check(w.units[BOMBER].health <= 0, "4. with no health left")
	var hits_on_bomber := 0
	var down_events := 0
	for ev: Dictionary in first.events:
		if str(ev.get("unit", "")) == BOMBER:
			if ev["type"] == "hit":
				hits_on_bomber += 1
			elif ev["type"] == "down":
				down_events += 1
	check(hits_on_bomber >= 1, "4. the events carry the hits on the bomber (%d)" % hits_on_bomber)
	eq(down_events, 1, "4. and exactly one 'down' event for it")
	check(won_turn >= 3 and won_turn <= 16, "4. it took until turn %d (a bomber with 8 pips, a route of about 12 turns)" % won_turn)
	check(str(first.mission.reason).contains(BOMBER), "4. the mission's reason: %s" % first.mission.reason)
	var alive := 0
	for id: String in first.player_ids():
		if not w.units[id].down:
			alive += 1
	check(alive >= 1, "4. a player fighter was still up when it ended")
	# The same seed, played again, ends the same way (a replay draws the same dice).
	var again := InterceptPlay.new("intercept", won_seed)
	var r2: Dictionary = again.play("chase", 18)
	eq(r2["state"], Mission.WON, "4. the same seed wins again")
	eq(int(r2["turn"]), won_turn, "4. on the same turn")
	near(float(r2["t"]), float(first.mission.time), 1e-9, "4. at the same moment")

# --- 5. Local, through the menu ----------------------------------------------------------------------------------

func _until(cond: Callable, max_frames: int = 3000) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

# Both fighters circle in place (every step asks for more turn than it can give), so nobody leaves the map.
func _circle(sb: Node) -> void:
	var w: World = sb.world
	for id: String in w.units:
		var u: Unit = w.units[id]
		if u.controller == World.CONTROLLER_PLAYER and not u.down:
			for i in w.steps_per_turn(id):
				w.plan_step(id, i, {"turn": 1.5})

func _local() -> bool:
	_main.setup_menu()
	check(_main.menu.visible, "5. the menu is up")
	check(_main.start_sandbox(), "5. Local builds the sandbox")
	var sb: Node = _main.sandbox
	if sb == null:
		return false
	eq(sb.scenario.id, "intercept", "5. Local starts Intercept by default")
	sb.scenario.view["result_card_delay_s"] = 0.1
	var playable := await _until(func() -> bool: return sb.is_playable)
	if not check(playable, "5. the sandbox becomes playable"):
		return false
	var w: World = sb.world
	eq(w.units.size(), 4, "5. four units")
	check(sb.ai is AiPilot, "5. Local attaches the pilot")
	check(sb.mission != null and sb.mission.state == Mission.PLAYING, "5. and the mission, playing")
	check(sb.objective != null, "5. the target ring is on the map")
	if sb.objective != null:
		var ring: Dictionary = sb.objective.screen_ring()
		check(not ring.is_empty() and float(ring["radius_px"]) >= 9.0, "5. drawn at least %.0f px across" % (float(ring.get("radius_px", 0.0)) * 2.0))
	eq(sb.ui.roster.rows().size(), 2, "5. the roster lists the two player planes, not the enemy's")
	check(sb.hint.headline.contains("INTERCEPT"), "5. the briefing is in the hint card")
	# The camera: the HUD insets in, the roster clear of the map at full zoom-out.
	check(sb.ctl.insets.right > 0.0 and is_equal_approx(sb.ctl.insets.right, float(sb.ui.hud_insets()["right"])), "5. the camera has the HUD insets (the roster sidebar, %.0f px)" % sb.ctl.insets.right)
	sb.ctl.set_view(sb.terrain.map_rect_px().get_center(), 1e-6)
	var tl: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().position)
	var br: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().end)
	var vs: Vector2 = sb.get_viewport().get_visible_rect().size
	check(br.x <= vs.x - sb.ctl.insets.right + 0.5 and tl.x >= -0.5, "5. fully zoomed out the whole map is left of the sidebar (map %s to %s, sidebar from x = %.0f)" % [tl.round(), br.round(), vs.x - sb.ctl.insets.right])
	# The opening view frames the players and never the enemy's plan.
	sb._frame_start_view()
	var view: Rect2 = sb.ctl.visible_rect_px()
	var ppm: float = sb.map_view.px_per_m
	for id in [LIGHT, HEAVY]:
		check(view.has_point(Vector2(float(w.units[id].x), float(w.units[id].y)) * ppm), "5. %s is in the opening view" % id)
	var b_plan: Array = w.planned_states(BOMBER)
	var b_end := Vector2(float(b_plan.back()["x"]), float(b_plan.back()["y"]))
	check(not view.has_point(b_end * ppm), "5. the bomber's planned path is not in the opening view (the AI's plan is never framed)")
	check(not view.has_point(Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y)) * ppm), "5. nor the bomber itself")
	# The target ring is.
	var tp: Dictionary = sb.scenario.objective()
	check(view.has_point(tp["point"] * ppm), "5. but the target ring is (view.start_frame_objective)")
	# The fog hides the enemy; the players' own planes show.
	sb.ui.marker_layer.update_poses()
	check(sb.ui.marker_layer.marker(LIGHT).visible and sb.ui.marker_layer.marker(HEAVY).visible, "5. the players' planes are shown")
	check(not sb.ui.marker_layer.marker(BOMBER).visible and not sb.ui.marker_layer.marker(ESCORT).visible, "5. the bomber and its escort are in the fog")

	# Played through the interface: nobody fights, so the bomber reaches the target.
	var ended: Array = []
	sb.mission_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	var shown: Array = []
	sb.result_shown.connect(func(res: Dictionary) -> void: shown.append(res))
	var last_turn := 0
	for n in 20:
		var ready_for_orders := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and w.turn > last_turn))
		if not ready_for_orders or sb.result_decided():
			break
		last_turn = w.turn
		_circle(sb)
		sb.ui.press_ready()
	eq(ended.size(), 1, "5. the mission ended once")
	if ended.is_empty():
		return false
	eq(ended[0]["state"], Mission.LOST, "5. lost: the bomber reached the target")
	check(int(ended[0]["turn"]) >= 10 and int(ended[0]["turn"]) <= 14, "5. on turn %d" % int(ended[0]["turn"]))
	eq(sb.result["state"], Mission.LOST, "5. the sandbox keeps the result")
	var card_up := await _until(func() -> bool: return sb.result_card_shown())
	check(card_up, "5. the result card is put up after the playback")
	check(not sb.ui.is_playing(), "5. (the deciding turn has been played back first)")
	eq(shown.size(), 1, "5. once")
	check(sb.ui.input_locked(), "5. the card locks planning input")
	check(sb.ui.result_card != null and sb.ui.result_card.is_showing(), "5. and shows")
	eq(str(sb.ui.result_card.result.get("state", "")), "lost", "5. the card has the verdict")
	await get_tree().physics_frame

	# Play again: a fresh sandbox of the same scenario in its place.
	var old_id := sb.get_instance_id()
	sb.ui.result_card.play_again.emit()
	var swapped := await _until(func() -> bool: return _main.sandbox != null and _main.sandbox.get_instance_id() != old_id)
	if not check(swapped, "5. Play again replaces the sandbox"):
		return false
	var fresh: Node = _main.sandbox
	eq(fresh.scenario.id, "intercept", "5. with the same scenario")
	eq(fresh.world.turn, 1, "5. a new game on turn 1")
	eq(fresh.mission.state, Mission.PLAYING, "5. whose mission is playing again")
	check(fresh.result.is_empty() and not fresh.ui.input_locked(), "5. with no result and no card")
	check(not _main.menu.visible, "5. and the menu stays hidden")
	var again := await _until(func() -> bool: return fresh.is_playable)
	check(again, "5. and it becomes playable")
	# Menu: back to the menu.
	fresh.ui.result_card.menu.emit()
	var back := await _until(func() -> bool: return _main.sandbox == null)
	check(back, "5. Menu leaves the sandbox")
	check(_main.menu.visible, "5. and brings the menu back")
	return true

# --- 6. Over the net -----------------------------------------------------------------------------------------

func _arm(role: String) -> void:
	var sb: Node = _boxes[role]
	sb.scenario.view["result_card_delay_s"] = 0.1
	sb.restart_requested.connect(_replace.bind(role), CONNECT_DEFERRED)

# What main.gd's restart_sandbox does, under a rig peer's root: the old one out of the tree first (the new
# one must be named "Sandbox" again: the node path is the address of the RPCs), a new one in its place.
func _replace(role: String) -> void:
	var old: Node = _boxes[role]
	old.call("shutdown")
	(_roots[role] as Node).remove_child(old)
	old.queue_free()
	var nb: Node = Sandbox.new()
	nb.set("net_role", role)
	nb.set("announce_restart", role == "host")
	_boxes[role] = nb
	_arm(role)
	(_roots[role] as Node).add_child(nb)

func _net() -> bool:
	var h: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(h != null, "6. the host binds port %d" % PORT):
		return false
	var c: NetRig.Peer = await rig.add_client(PORT, "Cy", false)
	if not check(c != null, "6. the client connects"):
		return false
	_roots = {"host": h.root, "client": c.root}
	var sb_h: Node = Sandbox.new()
	sb_h.set("net_role", "host")
	var sb_c: Node = Sandbox.new()
	sb_c.set("net_role", "client")
	_boxes = {"host": sb_h, "client": sb_c}
	_arm("host")
	_arm("client")
	h.root.add_child(sb_h)
	c.root.add_child(sb_c)
	if not check(bool(sb_h.ok()) and bool(sb_c.ok()), "6. both sandboxes build: %s %s" % [str(sb_h.errors), str(sb_c.errors)]):
		return false
	h.world = sb_h.world
	h.sync = sb_h.session.sync
	c.world = sb_c.world
	c.sync = sb_c.session.sync
	eq(sb_h.scenario.id, "intercept", "6. Host starts Intercept by default")
	check(sb_h.ai is AiPilot, "6. the pilot flies the enemy on the host")
	check(sb_c.ai == null, "6. and does not exist on the client: its World never plans the enemy")
	check((sb_h.world.units[BOMBER].plan as Array).size() > 0, "6. the host has the bomber's plan")
	eq((sb_c.world.units[BOMBER].plan as Array).size(), 0, "6. the client never gets it")
	eq((sb_c.world.units[ESCORT].plan as Array).size(), 0, "6. nor the escort's")
	check(sb_h.mission != null and sb_c.mission != null and sb_h.mission.state == Mission.PLAYING and sb_c.mission.state == Mission.PLAYING, "6. both machines judge the game")
	check(sb_h.ui.player_name == sb_h.session.sync.name_of and sb_c.ui.player_name == sb_c.session.sync.name_of, "6. the cards name players by the sync's names (UnitUI.player_name)")
	var joined: bool = await rig.wait_until(func() -> bool: return sb_c.session.sync.is_joined() and sb_h.world.players.size() == 2)
	if not check(joined, "6. the client is welcomed"):
		return false
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the client holds the host's game")

	# Play to the end with nobody fighting: both fighters circle, both players ready each turn.
	var guard := 0
	var last := 0
	while guard < 20 and not (sb_h.result_decided() and sb_c.result_decided()):
		guard += 1
		var up: bool = await rig.wait_until(func() -> bool:
			return (sb_h.result_decided() and sb_c.result_decided()) or (sb_h.world.phase == World.PHASE_PLANNING and sb_c.world.phase == World.PHASE_PLANNING \
				and sb_h.world.turn == sb_c.world.turn and sb_h.world.turn > last and not sb_h.ui.is_playing() and not sb_c.ui.is_playing()), 4000)
		if not check(up, "6. both machines reach the planning phase of the turn after %d" % last):
			return false
		if sb_h.result_decided() and sb_c.result_decided():
			break
		last = sb_h.world.turn
		_circle(sb_h)   # (any player edits any plan: the host edits both fighters; the plans go to the client)
		var planned: bool = await rig.wait_until(func() -> bool: return (sb_c.world.units[LIGHT].plan as Array).size() > 0 and (sb_c.world.units[HEAVY].plan as Array).size() > 0)
		if not check(planned, "6. the client sees the plans"):
			return false
		sb_c.ui.press_ready()
		sb_h.ui.press_ready()
	var both: bool = await rig.wait_until(func() -> bool: return sb_h.result_decided() and sb_c.result_decided(), 4000)
	if not check(both, "6. the mission ends on both machines"):
		return false
	eq(sb_c.result["state"], sb_h.result["state"], "6. the client ends in the host's state")
	eq(sb_c.result["state"], Mission.LOST, "6. (lost: nobody fought)")
	eq(sb_c.result["turn"], sb_h.result["turn"], "6. on the same turn")
	eq(sb_c.result["reason"], sb_h.result["reason"], "6. for the same reason")
	near(float(sb_c.result["t"]), float(sb_h.result["t"]), 1e-9, "6. at the same moment")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the Worlds are the same at the end")
	var cards: bool = await rig.wait_until(func() -> bool: return sb_h.result_card_shown() and sb_c.result_card_shown(), 4000)
	check(cards, "6. both machines put the card up")
	check(sb_h.ui.result_card.is_showing() and sb_c.ui.result_card.is_showing(), "6. and it shows on both")

	# A player who walks into the finished game never saw the deciding turn resolve: on joining, her mission looks at the
	# snapshot's last turn and is decided at once, the same verdict (the host is in turn 13's planning phase now).
	var dee: NetRig.Peer = await rig.add_client(PORT, "Dee", false)
	if not check(dee != null, "6. a late player connects"):
		return false
	var sb_d: Node = Sandbox.new()
	sb_d.set("net_role", "client")
	sb_d.scenario.view["result_card_delay_s"] = 0.1
	dee.root.add_child(sb_d)
	dee.world = sb_d.world
	dee.sync = sb_d.session.sync
	var dee_in: bool = await rig.wait_until(func() -> bool: return sb_d.session.sync.is_joined() and sb_d.result_decided(), 4000)
	check(dee_in, "6. a player who joins the finished game has its result decided on joining")
	if sb_d.result_decided():
		eq(sb_d.result["state"], sb_h.result["state"], "6. the same verdict as the host's")
		eq(sb_d.result["turn"], sb_h.result["turn"], "6. for the same turn")
		near(float(sb_d.result["t"]), float(sb_h.result["t"]), 1e-9, "6. at the same moment")
	var dee_card: bool = await rig.wait_until(func() -> bool: return sb_d.result_card_shown(), 2000)
	check(dee_card, "6. and she gets the card")
	sb_d.shutdown()
	sb_d.queue_free()
	rig.drop(dee)
	var gone: bool = await rig.wait_until(func() -> bool: return sb_h.world.players.size() == 2, 2000)
	check(gone, "6. (she leaves again)")

	# Play again from the CLIENT: it asks the host, the host replaces its sandbox and tells the client to replace its own.
	var old_h := sb_h.get_instance_id()
	var old_c := sb_c.get_instance_id()
	sb_c.ui.result_card.play_again.emit()
	var swapped: bool = await rig.wait_until(func() -> bool: return _boxes["host"].get_instance_id() != old_h and _boxes["client"].get_instance_id() != old_c, 4000)
	if not check(swapped, "6. the client's Play again replaces BOTH sandboxes (host: %s, client: %s)" % [_boxes["host"].get_instance_id() != old_h, _boxes["client"].get_instance_id() != old_c]):
		return false
	var nh: Node = _boxes["host"]
	var nc: Node = _boxes["client"]
	check(nh.ok() and nc.ok(), "6. the new sandboxes build")
	h.world = nh.world
	h.sync = nh.session.sync
	c.world = nc.world
	c.sync = nc.session.sync
	var rejoined: bool = await rig.wait_until(func() -> bool: return nc.session.sync.is_joined() and nh.world.players.size() == 2, 4000)
	check(rejoined, "6. the client joins the new game as it joined the first")
	eq(nh.world.turn, 1, "6. a new game on turn 1")
	check(nh.mission.state == Mission.PLAYING and nc.mission.state == Mission.PLAYING, "6. both missions playing again")
	check(nh.result.is_empty() and nc.result.is_empty(), "6. no result")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the client holds the new host game")
	check((nh.world.units[BOMBER].plan as Array).size() > 0 and (nc.world.units[BOMBER].plan as Array).size() == 0, "6. the enemy's plan is on the host only, again")
	# A stale second press (the game is playing again) does nothing.
	nc.session.request_restart()
	for i in 90:
		await get_tree().physics_frame
	check(_boxes["host"] == nh and _boxes["client"] == nc, "6. a Play again pressed on a game that is not over restarts nothing")

	for role: String in ["client", "host"]:
		var sb: Node = _boxes[role]
		sb.shutdown()
		sb.queue_free()
	rig.close_all()
	await get_tree().process_frame
	return true
