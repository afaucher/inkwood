extends "res://scripts/test_support/test_case.gd"

# A REAL host and a REAL client, in one headless process, exchanging a real RPC
# over ENet on localhost.
#
# This is the test the whole networking layer hangs off. Everything else about
# multiplayer can be asserted with mocks, and mocks cannot tell you the packet
# ever arrives -- a green unit test on a serializer says nothing about whether
# anything is listening. Steam's transport cannot run in the gate (no Steam
# client on a CI box), so ENet stands in: it is the same MultiplayerAPI, the
# same RPC routing and the same peer-id semantics, with a different socket
# underneath.
#
# HOW TWO PEERS FIT IN ONE PROCESS: a SceneTree can hold several MultiplayerAPI
# instances, each rooted at a different node, via SceneTree.set_multiplayer().
# RPC targets are resolved by node path RELATIVE to that root -- so `Pinger`
# under NetHost and `Pinger` under NetClient are the same address as far as the
# API is concerned, and the call routes across the socket between them.

const PORT := 28777
const PING_VALUE := 4242

var host_mp: SceneMultiplayer = null
var client_mp: SceneMultiplayer = null
var host_pinger: Node = null
var client_pinger: Node = null

var client_connected: bool = false
var host_saw_peer: int = 0
var sent_frame: int = -1
var frame: int = 0

func setup(_main) -> void:
	timeout_seconds = 20.0

	var host_root := Node.new()
	host_root.name = "NetHost"
	add_child(host_root)
	var client_root := Node.new()
	client_root.name = "NetClient"
	add_child(client_root)

	host_mp = SceneMultiplayer.new()
	get_tree().set_multiplayer(host_mp, host_root.get_path())
	client_mp = SceneMultiplayer.new()
	get_tree().set_multiplayer(client_mp, client_root.get_path())

	var pinger_script := load("res://scripts/test_support/pinger.gd")
	host_pinger = Node.new()
	host_pinger.name = "Pinger"
	host_pinger.set_script(pinger_script)
	host_root.add_child(host_pinger)
	client_pinger = Node.new()
	client_pinger.name = "Pinger"
	client_pinger.set_script(pinger_script)
	client_root.add_child(client_pinger)

	var host_peer := ENetMultiplayerPeer.new()
	if not check(host_peer.create_server(PORT, 4) == OK, "host binds port %d" % PORT):
		finish()
		return
	host_mp.multiplayer_peer = host_peer

	var client_peer := ENetMultiplayerPeer.new()
	if not check(client_peer.create_client("127.0.0.1", PORT) == OK, "client opens a socket"):
		finish()
		return
	client_mp.multiplayer_peer = client_peer

	host_mp.peer_connected.connect(func(id: int) -> void: host_saw_peer = id)
	client_mp.connected_to_server.connect(func() -> void: client_connected = true)

	eq(host_mp.get_unique_id(), 1, "the host is peer 1")

func _physics_process(_delta: float) -> void:
	frame += 1

	# WAIT FOR BOTH SIDES. The client's connected_to_server fires a frame or two
	# BEFORE the host admits the peer -- each MultiplayerAPI reports what its own
	# poll has seen, and the two polls do not agree within a frame. Sending on
	# `client_connected` alone broadcasts to an empty peer list: the call
	# succeeds, nothing receives it, and the symptom is a silently lost RPC three
	# seconds later rather than an error at the send.
	if client_connected and host_saw_peer != 0 and sent_frame == -1:
		eq(host_saw_peer, client_mp.get_unique_id(),
			"the host observes the same peer id the client reports for itself")
		check(client_mp.get_unique_id() > 1, "the client got a peer id above the host's")
		host_pinger.ping.rpc(PING_VALUE)
		sent_frame = frame
		return

	if sent_frame != -1:
		if client_pinger.ping_count > 0:
			eq(client_pinger.last_value, PING_VALUE, "the client received the value the host sent")
			eq(host_pinger.ping_count, 0, "call_remote did not run the RPC on the sender")
			finish()
		# 3s of physics frames is far past a localhost round trip; past that
		# the packet is not late, it is lost.
		elif frame - sent_frame > 180:
			fail("the RPC never arrived at the client (%d frames after send)" % (frame - sent_frame))
			finish()
