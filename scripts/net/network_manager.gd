extends Node

# Autoload singleton: NetworkManager
# ----------------------------------
# The game's ONE entry point for "am I in a session, and who else is in it".
# Game code connects to the signals below and never reads
# `multiplayer.multiplayer_peer` directly.
#
# TWO TRANSPORTS, ON PURPOSE:
#
#   STEAM -- what ships. Peer-to-peer over the Steam relay via
#            SteamMultiplayerPeer; needs a running Steam client and a lobby.
#   ENET  -- what develops and what tests. Plain UDP over localhost. It needs no
#            Steam client, so two windows on one machine (or a headless test)
#            can play together, which is the only practical way to iterate on
#            replication. See scripts/tests/test_enet_loopback.gd.
#
# They are interchangeable because everything above this file talks in peer ids
# and RPCs, which are transport-agnostic. Keep it that way: the moment gameplay
# code calls a `Steam.*` function directly, the test gate stops being able to
# exercise it.
#
# TOPOLOGY: host-authoritative. Peer 1 is the host and owns world state; clients
# own their own input. There is no dedicated server mode -- the host is a player.

signal session_started(is_host: bool)
signal session_ended()
signal peer_joined(peer_id: int)
signal peer_left(peer_id: int)
signal session_error(what: String)

enum Transport { STEAM, ENET }

const DEFAULT_PORT := 27015
const MAX_PLAYERS := 4

var active: bool = false
var is_host: bool = false
var transport: int = Transport.STEAM
# Every peer currently in the session INCLUDING us. Ordered by join; the host is
# always 1. Kept here rather than read from multiplayer.get_peers() at each call
# site because the latter excludes the local peer, which is a reliable source of
# off-by-one bugs in player counts.
var peers: Array[int] = []

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# --- Session lifecycle -------------------------------------------------------

func host(via: int = Transport.STEAM, port: int = DEFAULT_PORT) -> bool:
	if active:
		session_error.emit("already in a session")
		return false

	var peer: MultiplayerPeer = null
	match via:
		Transport.STEAM:
			if not SteamManager.create_lobby():
				return false
			# The Steam peer cannot be created until the lobby exists, so hand
			# off to the callback. `await` here rather than a state machine:
			# lobby creation is the only asynchronous step in the whole flow.
			var created_id: int = await SteamManager.lobby_created
			if created_id == 0:
				session_error.emit("lobby creation failed")
				return false
			peer = SteamManager.make_peer(true)
		Transport.ENET:
			var enet := ENetMultiplayerPeer.new()
			var err := enet.create_server(port, MAX_PLAYERS)
			if err != OK:
				session_error.emit("could not bind port %d (error %d)" % [port, err])
				return false
			peer = enet

	if peer == null:
		session_error.emit("no transport peer")
		return false

	transport = via
	multiplayer.multiplayer_peer = peer
	active = true
	is_host = true
	peers = [1]
	_log("hosting via %s" % _transport_name(via))
	session_started.emit(true)
	return true

func join(via: int = Transport.STEAM, address: String = "127.0.0.1", port: int = DEFAULT_PORT) -> bool:
	if active:
		session_error.emit("already in a session")
		return false

	var peer: MultiplayerPeer = null
	match via:
		Transport.STEAM:
			peer = SteamManager.make_peer(false)
		Transport.ENET:
			var enet := ENetMultiplayerPeer.new()
			var err := enet.create_client(address, port)
			if err != OK:
				session_error.emit("could not reach %s:%d (error %d)" % [address, port, err])
				return false
			peer = enet

	if peer == null:
		session_error.emit("no transport peer")
		return false

	transport = via
	multiplayer.multiplayer_peer = peer
	# NOT active yet: a client is only in the session once
	# connected_to_server fires. Setting it here would make the first frames
	# after `join()` report a session that may still fail to connect.
	is_host = false
	_log("connecting via %s" % _transport_name(via))
	return true

func leave() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	SteamManager.leave_lobby()
	var was_active := active
	active = false
	is_host = false
	peers.clear()
	if was_active:
		_log("session ended")
		session_ended.emit()

func local_id() -> int:
	# 0 means "not in a session". Gated on `active` rather than on
	# `multiplayer_peer == null`, because Godot's MultiplayerAPI is never
	# peerless: with no session it holds an OfflineMultiplayerPeer whose unique
	# id is 1. So `get_unique_id() == 1` does NOT mean "I am the host" -- it is
	# also exactly what a game that never connected to anything reports.
	if not active:
		return 0
	return multiplayer.get_unique_id()

# The local player's name as Steam knows it, or "" when Steam is not available.
#
# A thin accessor and nothing more, because THIS is the boundary: D5 wants a
# friend's name on the HUD, and the obvious way to get one is `Steam.*` from the
# HUD -- which the gate, having no Steam client, could never run. The caller
# decides the fallback; it knows its own peer id and this file does not.
func steam_display_name() -> String:
	if not SteamManager.available:
		return ""
	return SteamManager.username

# OUR OWN Steam id, or 0. Published with the name so that everybody else can ask
# Steam for our face -- an avatar is far too big for the snapshot wire, but the
# ID is eight bytes and Steam already has the picture cached on every machine
# that can see us.
func steam_id_of_self() -> int:
	if not SteamManager.available:
		return 0
	return SteamManager.steam_id

# Somebody's avatar, or null. Null is the ordinary answer: no Steam, no picture
# on the account, or it simply has not arrived yet.
func steam_avatar(id: int) -> Texture2D:
	if not SteamManager.available:
		return null
	return SteamManager.avatar_of(id)

# --- Multiplayer callbacks ---------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if id not in peers:
		peers.append(id)
	_log("peer %d joined (%d in session)" % [id, peers.size()])
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	peers.erase(id)
	_log("peer %d left (%d in session)" % [id, peers.size()])
	peer_left.emit(id)

func _on_connected_to_server() -> void:
	active = true
	is_host = false
	# The host (1) and ourselves are both in the session; other clients arrive
	# as peer_connected events.
	peers = [1, multiplayer.get_unique_id()]
	_log("connected as peer %d" % multiplayer.get_unique_id())
	session_started.emit(false)

func _on_connection_failed() -> void:
	multiplayer.multiplayer_peer = null
	active = false
	session_error.emit("connection failed")

func _on_server_disconnected() -> void:
	_log("host disconnected")
	leave()

# --- Helpers -----------------------------------------------------------------

func _transport_name(via: int) -> String:
	return "steam" if via == Transport.STEAM else "enet"

func _log(msg: String) -> void:
	if DebugSettings.is_on("net_log"):
		print("[Net] ", msg)
