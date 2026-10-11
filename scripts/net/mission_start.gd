extends Node

# THE MISSION'S START, host to client (decision sun-time, 2026-10-11; the wire is PROPOSED).
#
# A client builds its map before it says hello to the host's WorldSync (the map is baked under a sun, and the
# sun is the host's clock at the mission's start). So the start has to reach the client BEFORE its sandbox
# exists, which is why this node is not in the sandbox: main.gd adds one to itself (Main/MissionStart, the
# same path on every machine), the host fills `start`, a client asks for it and builds its game from the
# answer.
#
#   host:    ms.start = {"sun": Sun.start_message()}        after Sun.begin_mission (main.gd start_sandbox)
#   client:  ms.received.connect(func(s): ...)               then ms.request()
#            ... Sun.apply_start(s["sun"]); start the sandbox
#
# The payload is plain Variants (a Dictionary of numbers and words). It is the place for anything else the
# host decides when a mission starts and every peer must build the same (the way the scenario id is checked
# by WorldSync's hello): add a key to `start`, not a new message.
#
# MESSAGES (reliable):
#   rpc_request()        client -> host   "send me the start"
#   rpc_answer(start)    host -> client   the host's `start`, {} while the host has no mission
#
# Over Steam and ENet alike (the node's own `multiplayer`), and in the gate through scripts/net/net_rig.gd.

signal received(start: Dictionary)

const HOST_ID := 1

# Host: what a client is answered with.
var start: Dictionary = {}
# Host: how many clients asked.
var served := 0

# Client: ask the host for the mission's start. False when there is no host to ask.
func request() -> bool:
	if multiplayer.multiplayer_peer == null or multiplayer.is_server():
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	rpc_request.rpc_id(HOST_ID)
	return true

@rpc("any_peer", "call_remote", "reliable")
func rpc_request() -> void:
	if not multiplayer.is_server():
		return
	served += 1
	rpc_answer.rpc_id(multiplayer.get_remote_sender_id(), start)

@rpc("authority", "call_remote", "reliable")
func rpc_answer(answer: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != HOST_ID:
		return
	received.emit(answer)
