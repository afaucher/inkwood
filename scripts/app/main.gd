extends Node2D

# Application shell: the menu, the headless test entry point and the session
# wiring, carried over from Bridge to Friendship's scripts/app/main.gd. The
# game world is created at runtime from here (the way Bridge to Friendship's
# GameWorld is) rather than placed in the scene, so that a test can stand up its
# own: the menu's Local button starts the SANDBOX (scripts/app/sandbox.gd, the
# sandbox demo assembled -- LOADED here, not preloaded, so a parse error in any
# part fails Local and the sandbox's own test, never every test through this
# file), and Esc goes back to the menu. WHICH scenario it plays is the 'scenario'
# knob (INKWOOD_SCENARIO), which the menu's selector sets (Track A2, proposed): the
# Strike by default (the newest layer), Intercept (the first fight), "sandbox" (the
# old flight toy). Local, Host and Join all start it; a joiner must have chosen the
# host's scenario, or the host refuses its hello and says which one it plays.
#
# THE RESULT CARD's two buttons come back here: Play again (the sandbox's
# restart_requested) replaces the sandbox with a fresh one of the same scenario and role
# -- on a host the new sandbox tells every client to do the same
# (scripts/app/sandbox_session.gd) -- and Menu (menu_requested) is Esc.

const BuildVersion = preload("res://scripts/ui/build_version.gd")

# The menu's scenario selector: the knob's choices in the order the menu lists them, and their words.
const SCENARIO_ORDER: Array[String] = ["strike", "intercept", "sandbox"]
const SCENARIO_WORDS := {
	"strike": "STRIKE: bomb the radio tower",
	"intercept": "INTERCEPT: shoot down the bomber",
	"sandbox": "SANDBOX: the flight toy",
}

@onready var menu: VBoxContainer = $CanvasLayer/Menu
@onready var status_label: Label = $CanvasLayer/Menu/StatusLabel

# The running sandbox (a Node2D child of this node), or null at the menu.
var sandbox: Node = null
var scenario_select: OptionButton = null   # the menu's selector (built by setup_menu, not in the .tscn)
var _menu_ready := false
var _local_pressed_ms := 0

func _ready() -> void:
	# Headless entry point first, before any menu, network or Steam wiring: a
	# test run must not touch any of it.
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--run-test" and i + 1 < args.size():
			_run_test(args[i + 1])
			return
		if args[i] == "--render-shot" and i + 1 < args.size():
			_render_shot(args[i + 1])
			return
		if args[i] == "--render-scene" and i + 1 < args.size():
			_render_scene(args, i)
			return

	setup_menu()

# The menu's wiring: the build stamp, the buttons and the session signals. Split
# out of _ready (which a headless test run leaves before this point) so the
# sandbox's test can stand the menu up on the test's own Main and drive Local
# and Esc through it.
func setup_menu() -> void:
	if _menu_ready:
		return
	_menu_ready = true
	# A sibling of the menu rather than a child of it, so hiding the menu to
	# start a game leaves the build stamp on screen. Added here and not in the
	# .tscn because a headless run returns above this line, so a test never
	# builds a Label it will not look at.
	$CanvasLayer.add_child(BuildVersion.make_label())
	_add_scenario_selector()

	$CanvasLayer/Menu/HostButton.pressed.connect(_on_host_pressed)
	$CanvasLayer/Menu/JoinButton.pressed.connect(_on_join_pressed)
	$CanvasLayer/Menu/LocalButton.pressed.connect(_on_local_pressed)

	NetworkManager.session_started.connect(_on_session_started)
	NetworkManager.session_ended.connect(_on_session_ended)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.peer_left.connect(_on_peer_left)
	NetworkManager.session_error.connect(_set_status)
	SteamManager.lobby_error.connect(_set_status)

	if not SteamManager.available:
		_set_status("Steam not available -- local only.")

	# INKWOOD_AUTOSTART=local[_shot]: press Local without a click (see _autostart).
	if DebugSettings.get_choice_name("autostart") != "off":
		_autostart.call_deferred()

# The scenario selector, under the title: one item per scenario file the knob knows. It SETS the knob
# (the sandbox reads the knob when it is built), so the menu, INKWOOD_SCENARIO and a test agree, and Play
# again, which builds a new sandbox from the knob, plays the same scenario.
func _add_scenario_selector() -> void:
	var choices: Array = DebugSettings.OPTIONS["scenario"]["choices"]
	var current := DebugSettings.get_choice_name("scenario")
	scenario_select = OptionButton.new()
	scenario_select.name = "ScenarioSelect"
	scenario_select.tooltip_text = "Which scenario Local, Host and Join start (a joiner must pick the host's)."
	var at := 0
	for id: String in SCENARIO_ORDER:
		if not choices.has(id):
			continue
		scenario_select.add_item(str(SCENARIO_WORDS.get(id, id.to_upper())))
		scenario_select.set_item_metadata(scenario_select.item_count - 1, id)
		if id == current:
			at = scenario_select.item_count - 1
	scenario_select.select(at)
	scenario_select.item_selected.connect(_on_scenario_selected)
	menu.add_child(scenario_select)
	menu.move_child(scenario_select, 1)   # under the title

func _on_scenario_selected(index: int) -> void:
	var choices: Array = DebugSettings.OPTIONS["scenario"]["choices"]
	var at := choices.find(str(scenario_select.get_item_metadata(index)))
	if at >= 0:
		DebugSettings.set_choice("scenario", at)

# The scenario the next Local / Host / Join starts (the knob's choice).
func selected_scenario() -> String:
	return DebugSettings.get_choice_name("scenario")

# Closing the window with the sandbox up: drop its bake jobs first (their worker
# threads read the map view's baker; the exported build crashed on exit without this).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and sandbox != null:
		stop_sandbox()

# Esc: out of the sandbox to the menu; at the menu, quit.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("system_exit"):
		if sandbox != null:
			stop_sandbox()
		else:
			get_tree().quit()

# --- Menu --------------------------------------------------------------------

func _on_host_pressed() -> void:
	# The transport is the 'net' knob (INKWOOD_NET): a Steam lobby as shipped, or ENet
	# for two windows on one machine (Track N, proposed).
	var via := _transport()
	_set_status("Creating lobby..." if via == NetworkManager.Transport.STEAM else "Starting the host...")
	# The host's net log goes on HERE, before the session exists: NetworkManager
	# logs "hosting via steam" on the line before it emits session_started, so a
	# switch flipped from that signal misses the one event it is most wanted for.
	# Set locally, not pushed, and not as the knob's default (which would print
	# [Net] lines under every test that stands up a session).
	DebugSettings.set_value("net_log", 1)
	await NetworkManager.host(via, _net_port())

# THE JOIN FLOW, verbatim from Bridge to Friendship: Join connects to the first
# global Steam lobby it finds. One game at a time suits the test group (design
# doc, decision log 2026-10-09); a lobby browser is deliberately not here.
# (With the 'net' knob on enet it connects to INKWOOD_NET_ADDRESS, else this
# machine, on the 'net_port' knob.)
func _on_join_pressed() -> void:
	if _transport() == NetworkManager.Transport.ENET:
		var address := OS.get_environment("INKWOOD_NET_ADDRESS")
		if address == "":
			address = "127.0.0.1"
		_set_status("Joining %s:%d..." % [address, _net_port()])
		NetworkManager.join(NetworkManager.Transport.ENET, address, _net_port())
		return
	if not SteamManager.request_lobby_list():
		return
	_set_status("Searching for lobbies...")
	var lobbies: Array = await SteamManager.lobby_list
	if lobbies.is_empty():
		_set_status("No lobbies found.")
		return
	SteamManager.join_lobby(int(lobbies[0]))
	await SteamManager.lobby_joined
	NetworkManager.join(NetworkManager.Transport.STEAM)

func _on_local_pressed() -> void:
	start_sandbox()

func _transport() -> int:
	return NetworkManager.Transport.ENET if DebugSettings.get_choice_name("net") == "enet" else NetworkManager.Transport.STEAM

func _net_port() -> int:
	return int(DebugSettings.get_value("net_port"))

# --- The sandbox ---------------------------------------------------------------

# Local: build the sandbox over the menu and hide the menu. Returns whether it
# stands. The menu is hidden at once and the sandbox's own "Drawing the map..."
# card covers the bake; a sandbox that did not build leaves the menu up with
# the reason in the status line.
#
# `role` (Track N, proposed): "" is Local; "host" or "client" starts the same
# sandbox in the session NetworkManager just opened (_on_session_started).
# `replacing` (Track A, proposed): this sandbox takes the place of a finished one in the
# same session (Play again), so a host tells its clients to do the same.
func start_sandbox(role: String = "", replacing: bool = false) -> bool:
	if sandbox != null:
		return true
	_local_pressed_ms = Time.get_ticks_msec()
	var script: Resource = load("res://scripts/app/sandbox.gd")
	if script == null or not (script as Script).can_instantiate():
		_set_status("The sandbox did not compile -- see the Parse Error in the log.")
		return false
	var sb: Node = script.new()
	sb.set("net_role", role)
	sb.set("announce_restart", replacing and role == "host")
	add_child(sb)
	if not bool(sb.call("ok")):
		_set_status("The sandbox did not start: %s" % str(sb.get("errors")))
		sb.queue_free()
		return false
	sandbox = sb
	sb.connect("playable", _on_sandbox_playable)
	# Deferred: both come from a button of the sandbox's own interface, which the answer frees.
	sb.connect("restart_requested", restart_sandbox, CONNECT_DEFERRED)
	sb.connect("menu_requested", stop_sandbox, CONNECT_DEFERRED)
	menu.hide()
	_set_status("Local sandbox." if role == "" else "%s sandbox." % role.capitalize())
	return true

func stop_sandbox() -> void:
	if sandbox == null:
		return
	var networked := str(sandbox.get("net_role")) != ""
	sandbox.call("shutdown")
	sandbox.queue_free()
	sandbox = null
	menu.show()
	_set_status("Back at the menu.")
	# Out of the game is out of the session (NetworkManager.leave() ends it for the others too).
	if networked and NetworkManager.active:
		NetworkManager.leave()

# Play again: a fresh sandbox of the same scenario and role in the place of this one. The old
# one leaves the tree FIRST, so the new one is named "Sandbox" again -- the node path is the
# address of its RPCs, the same on every machine (scripts/app/sandbox_session.gd). The session,
# if any, stays: only the game is replaced.
func restart_sandbox() -> bool:
	if sandbox == null:
		return false
	var role := str(sandbox.get("net_role"))
	var old := sandbox
	sandbox = null
	old.call("shutdown")
	remove_child(old)
	old.queue_free()
	_set_status("Restarting the scenario...")
	return start_sandbox(role, true)

func _on_sandbox_playable() -> void:
	print("[Main] Local pressed -> first playable frame in %d ms" % (Time.get_ticks_msec() - _local_pressed_ms))

# The exported build's proof without a tool that drives the window: Local at
# launch, and with INKWOOD_AUTOSTART=local_shot one frame of the running sandbox
# saved to INKWOOD_SHOT_OUT (else user://autostart.png) once it is playable and
# has settled; then quit.
func _autostart() -> void:
	var mode := DebugSettings.get_choice_name("autostart")
	if mode.begins_with("host") or mode.begins_with("join"):
		await _autostart_net(mode)
		return
	if not start_sandbox():
		get_tree().quit(1)
		return
	if DebugSettings.get_choice_name("autostart") != "local_shot":
		return
	if not bool(sandbox.get("is_playable")):
		await sandbox.playable
	for i in 150:
		await get_tree().process_frame
	var out := OS.get_environment("INKWOOD_SHOT_OUT")
	if out == "":
		out = "user://autostart.png"
	var img := get_viewport().get_texture().get_image()
	var path := out
	if not path.begins_with("user://") and path.is_relative_path():
		path = OS.get_executable_path().get_base_dir().path_join(path)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := img.save_png(path)
	print("[Main] autostart frame %s -> %s (%s)" % [str(img.get_size()), ProjectSettings.globalize_path(path), error_string(err)])
	stop_sandbox()
	await get_tree().process_frame
	get_tree().quit(0 if err == OK else 1)

# INKWOOD_AUTOSTART=host|join (Track N, proposed): press Host / Join without a
# click, over the transport the 'net' knob names. With host_shot / join_shot it
# is the TWO-WINDOW CHECK: one window hosts and the other joins; each plans one
# plane through the planner, waits until it shows the other window's plan, saves
# a frame (INKWOOD_SHOT_OUT, else tmp/net/<host|join>.png), readies, waits for the
# host's resolve and the next turn, saves a second frame (..._turn2.png) and
# quits 0, or 1 with the reason. How to run it: tmp/net/README.txt.
func _autostart_net(mode: String) -> void:
	if mode.begins_with("host"):
		await _on_host_pressed()
	else:
		_on_join_pressed()
	var t0 := Time.get_ticks_msec()
	while sandbox == null and Time.get_ticks_msec() - t0 < 30000:
		await get_tree().process_frame
	if sandbox == null:
		printerr("[Main] autostart %s: no session after 30 s (%s)" % [mode, status_label.text if status_label != null else ""])
		get_tree().quit(1)
		return
	if not mode.ends_with("_shot") and not mode.ends_with("_game"):
		return
	if not bool(sandbox.get("is_playable")):
		await sandbox.playable
	var out := OS.get_environment("INKWOOD_SHOT_OUT")
	if out == "":
		out = "tmp/net/%s.png" % ("host" if mode.begins_with("host") else "join")
	if out.is_relative_path():
		out = ProjectSettings.globalize_path("res://").path_join(out)
	if mode.ends_with("_game"):
		await _autostart_game(mode, out)
		return
	var problem: String = await sandbox.get("session").call("run_check", out)
	if problem != "":
		printerr("[Main] two-window check FAILED: ", problem)
	else:
		print("[Main] two-window check passed (%s)" % mode)
	stop_sandbox()
	await get_tree().process_frame
	get_tree().quit(0 if problem == "" else 1)

# INKWOOD_AUTOSTART=host_game / join_game (Track A, proposed): the TWO-WINDOW GAME. The first fight
# played to its end in two windows (scripts/app/sandbox_session.gd run_game): a frame of the result
# card in each (`out`), then PLAY AGAIN from the joining window -- the host replaces its sandbox, the
# joiner is told to replace its own, and both end up in a new game that the joiner has rejoined -- and
# a frame of that (`out` with "_again" before the extension). Quits 0, or 1 with the reason.
func _autostart_game(mode: String, out: String) -> void:
	var session: Node = sandbox.get("session")
	var problem: String = await session.call("run_game", out)
	if problem == "":
		var old_id := sandbox.get_instance_id()
		var is_host := mode.begins_with("host")
		if not is_host:
			# The joiner presses Play again on its card: it asks the host, which replaces its sandbox and tells it to replace its own.
			sandbox.get("ui").get("result_card").play_again.emit()
		var t0 := Time.get_ticks_msec()
		while (sandbox == null or sandbox.get_instance_id() == old_id) and Time.get_ticks_msec() - t0 < 120000:
			await get_tree().process_frame
		if sandbox == null or sandbox.get_instance_id() == old_id:
			problem = "Play again never replaced this window's sandbox"
		else:
			if not bool(sandbox.get("is_playable")):
				await sandbox.playable
			var again: Node = sandbox.get("session")
			var sync: Node = again.get("sync")
			while Time.get_ticks_msec() - t0 < 180000 and not (bool(sync.call("is_joined")) and sync.get("world").players.size() >= 2):
				await get_tree().process_frame
			if not (bool(sync.call("is_joined")) and sync.get("world").players.size() >= 2):
				problem = "the new game never had both players in it"
			else:
				for i in 60:
					await get_tree().process_frame
				problem = str(again.call("save_frame", out.get_basename() + "_again." + out.get_extension()))
	if problem != "":
		printerr("[Main] two-window game FAILED: ", problem)
	else:
		print("[Main] two-window game passed (%s)" % mode)
	stop_sandbox()
	await get_tree().process_frame
	get_tree().quit(0 if problem == "" else 1)

# --- Session -----------------------------------------------------------------

# A session opened (Host: the lobby or the port is up; Join: connected to the
# host): start the sandbox in it. Both machines build the same scenario World
# (scripts/app/sandbox_session.gd, scripts/net/world_sync.gd); the host's
# decides every turn. Alex 2026-10-09: Join connects straight to the first
# global Steam game it finds; there is no lobby screen.
func _on_session_started(is_host: bool) -> void:
	_set_status("%s via %s as peer %d." % [
		"Hosting" if is_host else "Joined",
		"steam" if NetworkManager.transport == NetworkManager.Transport.STEAM else "enet",
		NetworkManager.local_id()])
	if not start_sandbox("host" if is_host else "client"):
		NetworkManager.leave()

# The session is over (the host went away, or we left): out of the game.
func _on_session_ended() -> void:
	if sandbox != null:
		stop_sandbox()
	menu.show()
	_set_status("Disconnected.")

func _on_peer_joined(id: int) -> void:
	_set_status("Peer %d joined (%d in session)." % [id, NetworkManager.peers.size()])

func _on_peer_left(id: int) -> void:
	_set_status("Peer %d left (%d in session)." % [id, NetworkManager.peers.size()])

func _set_status(text: String) -> void:
	if status_label != null:
		status_label.text = text
	print("[Main] ", text)

# --- Render shot (windowed) --------------------------------------------------

# --render-shot <png>: draws the drawing layer's 1280x720 demo frame
# (scripts/render/demo_frame.gd) and saves it, then quits 0. Run it through
# render.ps1 / render.sh. WINDOWED ONLY: --headless swaps in a dummy renderer
# that produces no pixels at all, so this is never a test. The demo is LOADED
# here, not preloaded, so a parse error in scripts/render/ fails this run alone
# instead of breaking main.gd and with it every test in the gate.
func _render_shot(out_path: String) -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[render-shot] needs a windowed run: under --headless nothing is drawn")
		get_tree().quit(1)
		return
	var path := out_path
	if path.is_relative_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	var script: Resource = load("res://scripts/render/demo_frame.gd")
	if script == null or not (script as Script).can_instantiate():
		printerr("[render-shot] scripts/render/demo_frame.gd did not compile -- see the Parse Error above")
		get_tree().quit(1)
		return
	var img: Variant = script.call("render", Vector2i(1280, 720))
	if not img is Image:
		printerr("[render-shot] the demo frame returned no image")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := (img as Image).save_png(path)
	if err != OK:
		printerr("[render-shot] could not write ", path, ": ", error_string(err))
		get_tree().quit(1)
		return
	print("[render-shot] saved ", path)
	get_tree().quit(0)

# --- Render scene (windowed) -------------------------------------------------

# --render-scene <seed> [<png>] [--no-grain] [--parity] [--paper-shader]:
# generates the scene for <seed> at 1280x720 (scripts/world/scene_gen.gd) and
# draws it with the port of the prototype's draw routines
# (scripts/render/ink_renderer.gd), saves it -- by default to
# tmp/render/scene_<seed>.png -- and quits 0. Same shape as --render-shot:
# WINDOWED ONLY, the renderer LOADED rather than preloaded so a parse error in
# scripts/render/ or scripts/world/ fails this run alone, exit code 1 on any
# failure. Run it through render.ps1 -Scene <seed> / render.sh --scene <seed>.
#   --no-grain      the grain pass off (the prototype's "Grain" toggle), for
#                   comparing with a browser capture: its grain is Math.random
#   --parity        parameters with a prototype_default in render_defaults.json
#                   set back to it (shadow strength 0.92 instead of 0.44), so
#                   the frame matches the prototype's own defaults
#   --paper-shader  the paper tint from the GPU twin instead of GDScript fbm
func _render_scene(args: PackedStringArray, at: int) -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[render-scene] needs a windowed run: under --headless nothing is drawn")
		get_tree().quit(1)
		return
	var seed_arg := args[at + 1]
	if not seed_arg.is_valid_int():
		printerr("[render-scene] the seed must be an integer, got '", seed_arg, "'")
		get_tree().quit(1)
		return
	var seed_value := seed_arg.to_int()
	var path := "tmp/render/scene_%d.png" % seed_value
	if at + 2 < args.size() and not args[at + 2].begins_with("--"):
		path = args[at + 2]
	if path.is_relative_path():
		path = ProjectSettings.globalize_path("res://").path_join(path)
	var options := {"grain": not args.has("--no-grain"), "parity": args.has("--parity"),
		"paper_shader": args.has("--paper-shader")}
	var script: Resource = load("res://scripts/render/ink_renderer.gd")
	if script == null or not (script as Script).can_instantiate():
		printerr("[render-scene] scripts/render/ink_renderer.gd did not compile -- see the Parse Error above")
		get_tree().quit(1)
		return
	var img: Variant = script.call("render_scene", seed_value, Vector2i(1280, 720), options)
	if not img is Image:
		printerr("[render-scene] the renderer returned no image")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := (img as Image).save_png(path)
	if err != OK:
		printerr("[render-scene] could not write ", path, ": ", error_string(err))
		get_tree().quit(1)
		return
	print("[render-scene] saved ", path)
	get_tree().quit(0)

# --- Headless entry point ----------------------------------------------------

func _run_test(test_name: String) -> void:
	print("Starting automated test: ", test_name)

	# Deterministic RNG for every test. The global randi/randf is otherwise
	# seeded from entropy per launch, which makes any test whose outcome depends
	# on a random draw flaky run to run -- and a flaky gate gets ignored, which
	# costs the one real regression it exists to catch. Do NOT remove it; if a
	# new test is flaky, check this first. (The project's generators do not use
	# the global RNG at all -- see scripts/core/mulberry32.gd.)
	seed(20261009)

	var path := "res://scripts/tests/%s.gd" % test_name
	if not ResourceLoader.exists(path):
		printerr("[TEST FAILED] test script not found: ", path)
		get_tree().quit(1)
		return

	# A script with a PARSE ERROR must fail loudly here, not present as a 600s
	# HANG with the real message (Parse Error) sitting in the .err.log. Bridge to
	# Friendship guards `load() == null` -- but on 4.7 a broken script loads as a
	# NON-null resource that cannot be instantiated (observed 2026-10-09), so the
	# null check alone never fires and the typo surfaces as "has no setup()".
	# Both conditions, so either engine behaviour is caught by name.
	var script: Resource = load(path)
	if script == null or not (script as Script).can_instantiate():
		printerr("[TEST FAILED] ", test_name, " did not compile -- see the .err.log for the Parse Error")
		get_tree().quit(1)
		return

	var node := Node.new()
	node.name = test_name
	node.set_script(script)
	add_child(node)
	if not node.has_method("setup"):
		printerr("[TEST FAILED] ", test_name, " has no setup(main) entry point")
		get_tree().quit(1)
		return
	node.setup(self)
