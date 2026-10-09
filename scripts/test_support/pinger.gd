extends Node

# Minimal RPC endpoint used by test_enet_loopback.gd. It exists as its own
# script, rather than inline in the test, because an RPC is resolved by NODE
# PATH relative to the multiplayer root -- so the host copy and the client copy
# must be the same node name under their respective roots. Two instances of one
# script is the cheapest way to guarantee that.

signal pinged(value: int)

var last_value: int = -1
var ping_count: int = 0

@rpc("any_peer", "call_remote", "reliable")
func ping(value: int) -> void:
	last_value = value
	ping_count += 1
	pinged.emit(value)
