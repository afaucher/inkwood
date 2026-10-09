extends Node2D

# Application shell: the menu, the headless test entry point and the session
# wiring, carried over from Bridge to Friendship's scripts/app/main.gd. The
# game world is created at runtime from here (the way Bridge to Friendship's
# GameWorld is) rather than placed in the scene, so that a test can stand up its
# own: the menu's Local button starts the SANDBOX (scripts/app/sandbox.gd, the
# sandbox demo assembled -- LOADED here, not preloaded, so a parse error in any
# part fails Local and the sandbox's own test, never every test through this
# file), and Esc goes back to the menu.

const BuildVersion = preload("res://scripts/ui/build_version.gd")

@onready var menu: VBoxContainer = $CanvasLayer/Menu
@onready var status_label: Label = $CanvasLayer/Menu/StatusLabel

# The running sandbox (a Node2D child of this node), or null at the menu.
var sandbox: Node = null
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
	_set_status("Creating lobby...")
	# The host's net log goes on HERE, before the session exists: NetworkManager
	# logs "hosting via steam" on the line before it emits session_started, so a
	# switch flipped from that signal misses the one event it is most wanted for.
	# Set locally, not pushed, and not as the knob's default (which would print
	# [Net] lines under every test that stands up a session).
	DebugSettings.set_value("net_log", 1)
	await NetworkManager.host(NetworkManager.Transport.STEAM)

# THE JOIN FLOW, verbatim from Bridge to Friendship: Join connects to the first
# global Steam lobby it finds. One game at a time suits the test group (design
# doc, decision log 2026-10-09); a lobby browser is deliberately not here.
func _on_join_pressed() -> void:
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

# --- The sandbox ---------------------------------------------------------------

# Local: build the sandbox over the menu and hide the menu. Returns whether it
# stands. The menu is hidden at once and the sandbox's own "Drawing the map..."
# card covers the bake; a sandbox that did not build leaves the menu up with
# the reason in the status line.
func start_sandbox() -> bool:
	if sandbox != null:
		return true
	_local_pressed_ms = Time.get_ticks_msec()
	var script: Resource = load("res://scripts/app/sandbox.gd")
	if script == null or not (script as Script).can_instantiate():
		_set_status("The sandbox did not compile -- see the Parse Error in the log.")
		return false
	var sb: Node = script.new()
	add_child(sb)
	if not bool(sb.call("ok")):
		_set_status("The sandbox did not start: %s" % str(sb.get("errors")))
		sb.queue_free()
		return false
	sandbox = sb
	sb.connect("playable", _on_sandbox_playable)
	menu.hide()
	_set_status("Local sandbox.")
	return true

func stop_sandbox() -> void:
	if sandbox == null:
		return
	sandbox.call("shutdown")
	sandbox.queue_free()
	sandbox = null
	menu.show()
	_set_status("Back at the menu.")

func _on_sandbox_playable() -> void:
	print("[Main] Local pressed -> first playable frame in %d ms" % (Time.get_ticks_msec() - _local_pressed_ms))

# The exported build's proof without a tool that drives the window: Local at
# launch, and with INKWOOD_AUTOSTART=local_shot one frame of the running sandbox
# saved to INKWOOD_SHOT_OUT (else user://autostart.png) once it is playable and
# has settled; then quit.
func _autostart() -> void:
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

# --- Session -----------------------------------------------------------------

func _on_session_started(is_host: bool) -> void:
	# The menu stays visible: networking is not part of the sandbox demo (exit
	# criterion 1: Local only), so a session has no world to show yet.
	_set_status("%s via %s as peer %d. No networked world yet." % [
		"Hosting" if is_host else "Joined",
		"steam" if NetworkManager.transport == NetworkManager.Transport.STEAM else "enet",
		NetworkManager.local_id()])

func _on_session_ended() -> void:
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
