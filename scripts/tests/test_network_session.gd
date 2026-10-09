extends "res://scripts/test_support/test_case.gd"

# Drives NetworkManager itself -- the code that ships -- rather than the raw
# MultiplayerAPI. test_enet_loopback proves the transport works; this proves our
# wrapper reports the session correctly, which is what every caller reads.
#
# ENet, not Steam: the gate has no Steam client. The transport swap is the whole
# point of NetworkManager having two.

# A different port from test_enet_loopback's -- the gate runs tests in PARALLEL
# processes on one machine, so two tests binding the same port is a race that
# fails whichever loses, intermittently, and reads as a networking bug.
const PORT := 28778

var started_as_host: int = -1
var ended_count: int = 0
var errors: Array[String] = []
var host_ok: bool = false
var frame: int = 0

func setup(_main) -> void:
	timeout_seconds = 20.0

	eq(NetworkManager.active, false, "no session before host()")
	eq(NetworkManager.local_id(), 0, "no peer id before host()")

	NetworkManager.session_started.connect(func(is_host: bool) -> void:
		started_as_host = 1 if is_host else 0)
	NetworkManager.session_ended.connect(func() -> void: ended_count += 1)
	NetworkManager.session_error.connect(func(what: String) -> void: errors.append(what))

	host_ok = await NetworkManager.host(NetworkManager.Transport.ENET, PORT)

	check(host_ok, "host() over ENet succeeds")
	eq(errors.size(), 0, "hosting reports no errors (%s)" % str(errors))
	eq(started_as_host, 1, "session_started fired with is_host = true")
	eq(NetworkManager.active, true, "the session is active after host()")
	eq(NetworkManager.is_host, true, "we are the host")
	eq(NetworkManager.local_id(), 1, "the host is peer 1")
	eq(NetworkManager.peers, [1] as Array[int], "the peer list contains only the host")

	# Hosting twice must be refused, not silently replace the live session.
	var second: bool = await NetworkManager.host(NetworkManager.Transport.ENET, PORT + 1)
	eq(second, false, "a second host() while already in a session is refused")
	eq(errors.size(), 1, "the refusal is reported through session_error")

func _physics_process(_delta: float) -> void:
	if not host_ok:
		finish()
		return
	frame += 1
	# A few frames of a live session before tearing it down, so leave() is
	# exercised against a polled peer rather than one created a moment ago.
	if frame == 30:
		NetworkManager.leave()
	elif frame == 40:
		eq(ended_count, 1, "session_ended fired exactly once")
		eq(NetworkManager.active, false, "the session is inactive after leave()")
		eq(NetworkManager.peers.size(), 0, "the peer list is empty after leave()")
		# Idempotent: a second leave() must not emit a second session_ended,
		# or every listener double-handles a disconnect.
		NetworkManager.leave()
		eq(ended_count, 1, "leave() on an already-closed session is a no-op")
		finish()
