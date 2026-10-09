extends "res://scripts/test_support/test_case.gd"

# The gate's canary. Everything else in scripts/tests/ assumes the project
# BOOTS -- this is the test that says so, and it is the one to read first when
# the whole suite goes red at once (a broken autoload or a renamed scene fails
# every test, and only this one says why in a single line).

func setup(main) -> void:
	# Autoloads, by the names the rest of the code calls them, in the order
	# project.godot lists them.
	check(DebugSettings != null, "DebugSettings autoload is present")
	check(SteamManager != null, "SteamManager autoload is present")
	check(NetworkManager != null, "NetworkManager autoload is present")
	eq(DebugSettings.get_choice_name("net_log"), "off", "net_log defaults to off so the gate stays quiet")

	# The main scene is the application shell: a menu and nothing else. The
	# world, when there is one, is created at runtime so a test can stand up
	# its own.
	check(main is Node2D, "main scene root is a Node2D")
	var menu: Node = main.get_node_or_null("CanvasLayer/Menu")
	if check(menu != null, "main scene has a menu"):
		for button in ["HostButton", "JoinButton", "LocalButton"]:
			check(menu.get_node_or_null(button) != null, "menu has " + button)

	# The data files the build reads parse and carry what they say they carry.
	var params: Variant = _load_json("res://data/params/render_defaults.json")
	if check(params is Dictionary, "render_defaults.json parses"):
		eq(int(params.get("scene_seed", 0)), 20261009, "the fixed scene seed is the prototype's")
		for section in ["parameters", "palette", "constants"]:
			check(params.has(section), "render_defaults.json has a '%s' section" % section)
		var p: Dictionary = params.get("parameters", {})
		eq(int(p.get("canopy_size", {}).get("default", 0)), 19, "canopy size default is 19 px")
		eq(str(params.get("palette", {}).get("ink", "")), "#3D3226", "ink is the sepia from the style rules")
	var decisions: Variant = _load_json("res://data/decisions/decisions.json")
	if check(decisions is Dictionary, "decisions.json parses"):
		check(decisions.get("decisions", null) is Array, "decisions.json holds a list of decisions")

	# No session has been started, so nothing should think it is networked.
	eq(NetworkManager.active, false, "no session is active at boot")
	eq(NetworkManager.peers.size(), 0, "no peers at boot")
	eq(NetworkManager.local_id(), 0, "no local peer id without a session")

	finish()

func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		fail("missing data file: " + path)
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))
