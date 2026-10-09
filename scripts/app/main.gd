extends Node2D

# Application shell: the menu, the headless test entry point and the session
# wiring, carried over from Bridge to Friendship's scripts/app/main.gd. It holds
# no game world yet -- the sandbox world arrives with the execution plan's later
# components -- and when it does, it is created at runtime from here (the way
# Bridge to Friendship's GameWorld is) rather than placed in the scene, so that a
# test can stand up its own.

const BuildVersion = preload("res://scripts/ui/build_version.gd")

@onready var menu: VBoxContainer = $CanvasLayer/Menu
@onready var status_label: Label = $CanvasLayer/Menu/StatusLabel

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

func _unhandled_input(_event: InputEvent) -> void:
	if Input.is_action_just_pressed("system_exit"):
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
	# No world to show yet, so the menu stays up and the status says why.
	_set_status("Local session. No sandbox world yet (execution plan, phase 2+).")

# --- Session -----------------------------------------------------------------

func _on_session_started(is_host: bool) -> void:
	# The menu stays visible until there is a world to hide it for.
	_set_status("%s via %s as peer %d. No sandbox world yet." % [
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
