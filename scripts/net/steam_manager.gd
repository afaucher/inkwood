extends Node

# Autoload singleton: SteamManager
# --------------------------------
# Everything that talks to the Steamworks API lives behind this node. The rest
# of the game asks NetworkManager for a session and never touches `Steam.*`
# directly -- that separation is what lets the whole game run headless in the
# test gate, where there is no Steam client at all.
#
# Two facts drive the shape of this file:
#
#   1. Steam init FAILS on a machine with no running Steam client, which is
#      every CI box and every `--headless` test run. That is not an error
#      condition to abort on; it is the normal case for the gate. So init is
#      best-effort, `available` records the outcome, and every entry point
#      no-ops loudly rather than crashing when it is false.
#   2. `Steam.run_callbacks()` must be pumped every frame or NOTHING async ever
#      completes -- lobby_created, lobby_joined and friends just never fire, and
#      the symptom is a lobby that silently does not exist rather than an error.
#      It is pumped in _process below, gated on `available`.

signal lobby_created(lobby_id: int)
signal lobby_joined(lobby_id: int)
signal lobby_list(lobbies: Array)
signal lobby_error(what: String)

# Valve's public "Spacewar" test appid. Replace with the real one (here AND in
# steam_appid.txt, which must sit next to the exported binary) once the game has
# a store page. steam_appid.txt is how a NON-Steam-launched build tells the
# Steam client which app it is; without it a dev run reports "app not running".
const APP_ID := 480

# The lobby-list filter key. Two different games sharing appid 480 would
# otherwise see each other's lobbies -- which, on the Spacewar test appid, is
# not hypothetical.
const LOBBY_GAME_KEY := "inkwood"

var available: bool = false
var steam_id: int = 0
var username: String = ""
var on_steam_deck: bool = false

var lobby_id: int = 0
var lobby_max_members: int = 4

func _ready() -> void:
	# DebugSettings is listed above this node in project.godot's [autoload], so
	# it is already alive here. "off" is how a headless run skips Steam without
	# needing to know anything about the network layer.
	if DebugSettings.get_choice_name("steam") == "off":
		print("[Steam] disabled by DebugSettings.steam=off")
		return
	_initialize()

func _initialize() -> void:
	# GodotSteam has returned both a bool and a Dictionary from steamInit()
	# across versions -- accept either rather than pinning to one and failing
	# opaquely on an addon upgrade.
	var result: Variant = Steam.steamInit()
	var ok := false
	if typeof(result) == TYPE_DICTIONARY:
		ok = int(result.get("status", 1)) == 0
	else:
		ok = bool(result)

	if not ok:
		print("[Steam] not available (", result, ") -- running offline. This is expected headless.")
		return

	available = true
	steam_id = Steam.getSteamID()
	username = Steam.getPersonaName()
	on_steam_deck = Steam.isSteamRunningOnSteamDeck()
	print("[Steam] ready: ", username, " (", steam_id, ")")

	# AVATARS ARE ASYNC AND MAY NOT EXIST. GodotSteam has moved this signal's name
	# and its argument order across versions, and a missing signal is a crash at
	# connect() rather than a quiet nothing -- so it is guarded, and a build
	# without it simply never shows a face.
	if Steam.has_signal("avatar_loaded"):
		Steam.avatar_loaded.connect(_on_avatar_loaded)

	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.join_requested.connect(_on_join_requested)

func _process(_delta: float) -> void:
	if available:
		Steam.run_callbacks()

# --- Avatars ------------------------------------------------------------------
#
# THE ONLY PLACE Steam.* IS TOUCHED FOR THIS, per the rule at the top of the file
# and in CLAUDE.md: the gate has no Steam client, so anything that reaches past
# here is untestable the moment it is written. The HUD asks NetworkManager, which
# asks this, and gets `null` on any machine without Steam -- which is every CI
# box, every headless run and every ENet session.
#
# CACHED, because the HUD asks EVERY FRAME. Steam's own call is asynchronous:
# getPlayerAvatar() returns nothing useful and the image arrives later on a
# signal, so re-requesting per frame would queue thousands of fetches for one
# face. `_avatar_pending` is what stops that.
var _avatars: Dictionary = {}          # steam id -> ImageTexture
var _avatar_pending: Dictionary = {}   # steam id -> true

signal avatar_ready(id: int)

# Returns the texture if it has arrived, null otherwise -- and kicks off the fetch
# the first time it is asked. A caller polls it; there is nothing to await.
func avatar_of(id: int) -> Texture2D:
	if id == 0 or not available:
		return null
	if _avatars.has(id):
		return _avatars[id]
	if not _avatar_pending.has(id):
		_avatar_pending[id] = true
		if Steam.has_method("getPlayerAvatar"):
			# MEDIUM is 64x64. Large is 184 and would be resampled down to a HUD
			# row; small is 32 and looks like mud at any size worth having.
			Steam.getPlayerAvatar(Steam.AVATAR_MEDIUM, id)
	return null

func _on_avatar_loaded(id: int, size: int, buffer: PackedByteArray) -> void:
	# A zero-size or short buffer means Steam has no picture for this account --
	# a real state, not an error, and the answer is to keep showing the fallback.
	if size <= 0 or buffer.size() < size * size * 4:
		return
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, buffer)
	if image == null:
		return
	_avatars[id] = ImageTexture.create_from_image(image)
	avatar_ready.emit(id)

# --- Lobby lifecycle ---------------------------------------------------------

func create_lobby() -> bool:
	if not available:
		lobby_error.emit("Steam is not available")
		return false
	if lobby_id != 0:
		lobby_error.emit("already in a lobby")
		return false
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, lobby_max_members)
	return true

func request_lobby_list() -> bool:
	if not available:
		lobby_error.emit("Steam is not available")
		return false
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)
	Steam.addRequestLobbyListStringFilter("game", LOBBY_GAME_KEY, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.requestLobbyList()
	return true

func join_lobby(id: int) -> bool:
	if not available:
		lobby_error.emit("Steam is not available")
		return false
	Steam.joinLobby(id)
	return true

func leave_lobby() -> void:
	if available and lobby_id != 0:
		Steam.leaveLobby(lobby_id)
	lobby_id = 0

func lobby_owner_id() -> int:
	if not available or lobby_id == 0:
		return 0
	return Steam.getLobbyOwner(lobby_id)

# Returns a live SteamMultiplayerPeer, or null if Steam is unavailable. The
# caller (NetworkManager) owns assigning it to `multiplayer.multiplayer_peer` --
# this node deliberately does not touch the SceneTree's networking state.
func make_peer(as_host: bool) -> MultiplayerPeer:
	if not available:
		return null
	var peer := SteamMultiplayerPeer.new()
	if as_host:
		peer.create_host(0)
	else:
		var owner_id := lobby_owner_id()
		if owner_id == 0:
			lobby_error.emit("no lobby owner to connect to")
			return null
		peer.create_client(owner_id, 0)
	return peer

# --- Steam callbacks ---------------------------------------------------------

func _on_lobby_created(connect_result: int, id: int) -> void:
	if connect_result != 1:
		lobby_error.emit("could not create lobby (%d)" % connect_result)
		return
	lobby_id = id
	Steam.setLobbyData(lobby_id, "name", "%s's game" % username)
	Steam.setLobbyData(lobby_id, "game", LOBBY_GAME_KEY)
	print("[Steam] created lobby ", lobby_id)
	lobby_created.emit(lobby_id)

func _on_lobby_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:
		var reason := "unknown"
		match response:
			2: reason = "lobby does not exist"
			3: reason = "not allowed"
			4: reason = "lobby is full"
			5: reason = "error"
			6: reason = "banned"
			7: reason = "limited account"
			8: reason = "clan disabled"
			9: reason = "community ban"
			10: reason = "member blocked you"
			11: reason = "you blocked a member"
		lobby_error.emit("could not join lobby: %s (%d)" % [reason, response])
		return
	lobby_id = id
	print("[Steam] joined lobby ", lobby_id)
	lobby_joined.emit(lobby_id)

func _on_lobby_match_list(lobbies: Array) -> void:
	print("[Steam] found ", lobbies.size(), " lobbies")
	lobby_list.emit(lobbies)

# Fires when the player accepts an invite / "Join game" from the Steam overlay
# while this build is already running.
func _on_join_requested(id: int, _friend_id: int) -> void:
	join_lobby(id)
