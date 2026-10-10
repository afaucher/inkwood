extends "res://scripts/test_support/test_case.gd"

# THE SANDBOX IN A SESSION (Track N): two complete sandboxes in one process --
# a host and a client -- over a real ENet socket, driven the way the window is:
# through UnitUI's planner and Ready. Headless, so no pixels; what is checked is
# every join between the sandbox, UnitUI, the session and WorldSync:
#
#   1. START          Host / Join build the same scenario; each machine's player is
#                     "peer_<id>"; the AI is attached on the host only; UnitUI does not
#                     resolve (the host's WorldSync does)
#   2. EVERY PLAN     a plan made through the planner on one machine is a plan the roster
#                     of the other shows (which units have plans), and its planner draws
#   3. THE TURN       Ready on both machines: the HOST resolves, sends the result, both
#                     play it back, both begin turn 2 on their own; the Worlds are alike
#   4. THE MENU       Main's Host button starts a host sandbox over the transport knob and
#                     Esc ends the session
#
# Port 28780 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")

const PORT := 28780
const FIGHTER := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const BOMBER := "bomber_1"

var rig: NetRig = null
var main_node: Node = null
var _saved_speed := 0
var _saved_scenario := 0
var _saved_net := 0
var _saved_port := 0
var _saved_log := 0

func setup(main) -> void:
	timeout_seconds = 120.0
	main_node = main
	# The OLD flight-toy scenario (Local, Host and Join start the first fight's Intercept by default;
	# scripts/tests/test_intercept.gd covers that one over the net).
	_saved_scenario = DebugSettings.get_choice("scenario")
	DebugSettings.set_choice("scenario", 1)
	# Turns play back quickly (x8): the knob only changes how fast the markers animate.
	_saved_speed = DebugSettings.get_choice("playback_speed")
	DebugSettings.set_choice("playback_speed", 4)
	main.get_window().size = Vector2i(1280, 720)
	rig = NetRig.new()
	add_child(rig)
	for part: Script in [NetRig, WorldSync, World, Sandbox]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	var completed: Variant = await _run()
	check(completed == true, "the test ran to its last line (a runtime error would have ended it silently)")
	DebugSettings.set_choice("playback_speed", _saved_speed)
	DebugSettings.set_choice("scenario", _saved_scenario)
	finish()

func _run() -> bool:
	var h: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(h != null, "the host binds port %d" % PORT):
		return false
	var c: NetRig.Peer = await rig.add_client(PORT, "Cy", false)
	if not check(c != null, "the client connects"):
		return false

	# 1. Start ------------------------------------------------------------------------------------
	var sb_h: Node = Sandbox.new()
	sb_h.set("net_role", "host")
	h.root.add_child(sb_h)
	var sb_c: Node = Sandbox.new()
	sb_c.set("net_role", "client")
	c.root.add_child(sb_c)
	if not check(bool(sb_h.ok()) and bool(sb_c.ok()), "both sandboxes build: %s %s" % [str(sb_h.errors), str(sb_c.errors)]):
		return false
	# (so the rig's comparison reads these Worlds)
	h.world = sb_h.world
	h.sync = sb_h.session.sync
	c.world = sb_c.world
	c.sync = sb_c.session.sync
	eq(sb_h.ui.local_player, "peer_1", "1. the host's player is peer_1")
	eq(sb_c.ui.local_player, "peer_%d" % c.id(), "1. the client's player is peer_<id>")
	check(not sb_h.world.players.has("local") and not sb_c.world.players.has("local"), "1. neither World has the scenario's 'local' player")
	check(not sb_h.ui.auto_resolve and not sb_c.ui.auto_resolve, "1. UnitUI does not resolve on either machine: the host's WorldSync does")
	check(sb_h.ui.auto_begin_turn and sb_c.ui.auto_begin_turn, "1. but each machine begins the next turn after its own playback")
	check((sb_h.world.units[BOMBER].plan as Array).size() > 0, "1. the AI plans on the host")
	eq((sb_c.world.units[BOMBER].plan as Array).size(), 0, "1. and not on the client")
	var joined_ok: bool = await rig.wait_until(func() -> bool: return sb_c.session.sync.is_joined() and sb_h.world.players.size() == 2)
	if not check(joined_ok, "the client is welcomed once its sandbox is playable"):
		return false
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "1. the client holds the host's game")
	check("HOST" in sb_h.session.status_text() and "CLIENT" in sb_c.session.status_text(), "1. the status line says which is which")
	eq(sb_h.ui.roster.ordered_ids().size(), 2, "1. the roster lists the two player planes")

	# 2. Every plan, live ----------------------------------------------------------------------------
	sb_c.ui.select(FIGHTER)
	var f: Variant = sb_c.world.units[FIGHTER]
	sb_c.ui.planner.place_point(Vector2(float(f.x) + 300.0, float(f.y) - 40.0))
	sb_c.ui.planner.place_point(Vector2(float(f.x) + 600.0, float(f.y) - 120.0))
	var seen: bool = await rig.wait_until(func() -> bool: return (sb_h.world.units[FIGHTER].plan as Array).size() == 2)
	check(seen, "2. a plan made through the client's planner reaches the host")
	eq(_planned(sb_h, FIGHTER), 2, "2. the host's roster shows two steps planned for the fighter")
	eq(_planned(sb_h, HEAVY), 0, "2. and none for the heavy fighter")
	sb_h.ui.select(HEAVY)
	var g: Variant = sb_h.world.units[HEAVY]
	sb_h.ui.planner.place_point(Vector2(float(g.x) + 320.0, float(g.y) + 30.0))
	sb_h.ui.planner.place_point(Vector2(float(g.x) + 640.0, float(g.y) + 90.0))
	sb_h.ui.planner.place_point(Vector2(float(g.x) + 960.0, float(g.y) + 200.0))
	var seen2: bool = await rig.wait_until(func() -> bool: return (sb_c.world.units[HEAVY].plan as Array).size() == 3)
	check(seen2, "2. the host's plan reaches the client")
	eq(_planned(sb_c, HEAVY), 3, "2. the client's roster shows three steps planned for the heavy fighter")
	eq(_planned(sb_c, FIGHTER), 2, "2. and its own fighter's two")
	eq(sb_c.ui.planner.path_world(HEAVY).size(), sb_c.world.units[HEAVY].def.actions_per_turn, "2. the client's planner has a curve to draw for the host's plane")
	eq((sb_c.world.units[BOMBER].plan as Array).size(), 0, "2. the client still has no AI plan")
	check(WorldSync.same(sb_c.world.units[HEAVY].plan, sb_h.world.units[HEAVY].plan), "2. identical plans")

	# 3. The turn ----------------------------------------------------------------------------------------------
	var played := {"h": 0, "c": 0}
	sb_h.ui.turn_played.connect(func(_t: int) -> void: played["h"] += 1)
	sb_c.ui.turn_played.connect(func(_t: int) -> void: played["c"] += 1)
	sb_c.ui.press_ready()
	var cready: bool = await rig.wait_until(func() -> bool: return sb_h.world.is_ready(sb_c.ui.local_player))
	check(cready, "3. the client's Ready reaches the host")
	eq(sb_h.world.phase, World.PHASE_PLANNING, "3. the host waits for its own Ready")
	sb_h.ui.press_ready()
	var resolved: bool = await rig.wait_until(func() -> bool: return sb_h.world.phase != World.PHASE_PLANNING and sb_c.world.phase != World.PHASE_PLANNING)
	check(resolved, "3. the last Ready resolves the turn on the host and the result reaches the client")
	var began: bool = await rig.wait_until(func() -> bool: return sb_h.world.turn == 2 and sb_c.world.turn == 2 and sb_h.world.phase == World.PHASE_PLANNING and sb_c.world.phase == World.PHASE_PLANNING, 4000)
	check(began, "3. both machines played the turn back and began turn 2 on their own")
	eq(played["h"], 1, "3. the host played the turn back once")
	eq(played["c"], 1, "3. the client played the turn back once")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "3. after the turn the client's World is the host's")
	check(float(sb_c.world.units[FIGHTER].x) > 2900.0, "3. the fighter flew (a client's World moved)")
	check(sb_h.world.is_ready(World.AI_PLAYER) and sb_c.world.is_ready(World.AI_PLAYER), "3. the AI planned and readied turn 2 on the host; the client knows")
	check(not sb_h.world.is_ready(sb_h.ui.local_player) and not sb_c.world.is_ready(sb_c.ui.local_player), "3. the players are not ready on turn 2")

	# Shut the sandboxes down the way Esc does, the later first (the pen mode is put back as found).
	sb_c.shutdown()
	sb_c.queue_free()
	sb_h.shutdown()
	sb_h.queue_free()
	rig.close_all()
	await get_tree().process_frame

	# 4. The menu ------------------------------------------------------------------------------------------------
	var menu_ok: Variant = await _menu(main_node)
	return menu_ok == true

# Main's Host button, over the ENet transport knob: a host sandbox in a live NetworkManager
# session, and Esc ends both. (Join is the same path from the other side; two real
# processes do it in the two-window check, because a single process has one default
# MultiplayerAPI and the RPC paths of a second would differ.)
func _menu(main: Node) -> bool:
	_saved_net = DebugSettings.get_choice("net")
	_saved_port = int(DebugSettings.get_value("net_port"))
	_saved_log = DebugSettings.get_choice("net_log")
	DebugSettings.set_choice("net", 1)
	DebugSettings.set_value("net_port", PORT)
	main.setup_menu()
	check(main.menu.visible, "4. the menu is up")
	await main._on_host_pressed()
	check(NetworkManager.active and NetworkManager.is_host, "4. Host opened a session")
	check(main.sandbox != null, "4. and started the sandbox in it")
	if main.sandbox != null:
		eq(str(main.sandbox.net_role), "host", "4. as the host")
		eq(main.sandbox.session.player, "peer_1", "4. the host is peer_1")
		check(not main.menu.visible, "4. the menu is hidden")
		check(not main.sandbox.ui.auto_resolve, "4. UnitUI does not resolve; the host's WorldSync does")
		# Alone, the host's Ready resolves the turn (its player and the AI are everyone).
		main.sandbox.ui.press_ready()
		await get_tree().process_frame
		await get_tree().process_frame
		check(main.sandbox.world.phase != World.PHASE_PLANNING, "4. alone, the host's Ready resolves the turn through WorldSync")
		main.stop_sandbox()
	check(not NetworkManager.active, "4. leaving the sandbox ends the session")
	check(main.menu.visible, "4. and brings the menu back")
	DebugSettings.set_choice("net", _saved_net)
	DebugSettings.set_value("net_port", _saved_port)
	DebugSettings.set_choice("net_log", _saved_log)
	return true

func _planned(sb: Node, id: String) -> int:
	for r: Dictionary in sb.ui.roster.rows():
		if r["id"] == id:
			return int(r["planned"])
	return -1
