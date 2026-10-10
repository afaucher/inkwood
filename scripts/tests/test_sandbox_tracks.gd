extends "res://scripts/test_support/test_case.gd"

# THE WHOLE-FLIGHT LINE GIVES WAY TO THE WINGTIP TRAIL (decision wingtip-trails, Alex 2026-10-10: "yes, the
# trail is to the current position"; trails on every moving unit). scripts/app/sandbox_tracks.gd records
# every resolved turn and draws the whole flight; where a unit has a wingtip ribbon (UnitUI.trail_start_t:
# the game time its ribbon begins at, NAN for none) the line stops there, so the last turn is drawn once,
# by the ribbon. Headless: the numbers behind the drawing (line_limit, drawn_points), with a World that
# really resolves three turns and a stand-in for the trail's start.
#
#   1. NO TRAIL: the line is drawn to the plane (every recorded point), planning and playing alike
#   2. A TRAIL while PLANNING: the line ends where the trail begins -- the start of the last resolved
#      turn when the window is one turn -- and the point there is the previous turn's last (a dot)
#   3. A TRAIL while a turn PLAYS BACK: the line reaches only as far as the trail's start and the playback's
#      own reach, whichever is less -- never ahead of the plane, never into the ribbon
#   4. PER UNIT: a unit with no trail (NAN) keeps its whole line while another's gives way
#   5. the unit's own turn dots are drawn only while they lie on the line

const World = preload("res://scripts/sim/world.gd")
const SandboxTracks = preload("res://scripts/app/sandbox_tracks.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

# A stand-in for the marker layer: is_playing() and playback_t, as SandboxTracks reads them.
class FakePlayback extends RefCounted:
	var playing := false
	var playback_t := 0.0
	func is_playing() -> bool:
		return playing

var _w: World
var _tracks: SandboxTracks
var _pb := FakePlayback.new()
var _turn_s := 5.0

func setup(_main) -> void:
	_w = World.new()
	_w.quiet = true
	_w.add_player("local")
	_w.add_unit({"id": "a", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0})
	_w.add_unit({"id": "b", "type": "bomber", "side": "axis", "controller": "ai", "x": 1000.0, "y": 2900.0, "heading": 0.0})
	_turn_s = _w.rules.turn_seconds
	var host := Node2D.new()
	add_child(host)
	_tracks = SandboxTracks.new()
	add_child(_tracks)
	_tracks.setup(_w, host, _pb, UiStyle.shared(), 0.25, 1.6)
	for n in 3:
		_w.commit("local")
		_w.commit(World.AI_PLAYER)
		_w.resolve()
		_w.begin_turn()
	var per_turn := int(ceil(_turn_s / 0.25))
	var total := 3 * per_turn + 1       # the first turn's start point, then every sample of three turns
	eq(_tracks.point_count("a"), total, "three turns are recorded: %d points" % total)

	# 1. No trail: the whole line, planning and playing.
	eq(_tracks.line_limit("a"), INF, "1. no trail and no playback: nothing limits the line")
	eq(_tracks.drawn_points("a"), total, "1. every recorded point is drawn")
	_pb.playing = true
	_pb.playback_t = 2.0
	# (The turn being played is the one resolved last: turns are 5 s, the third starts at 10 s.)
	near(_tracks.playback_limit(), 2.0 * _turn_s + 2.0, 1e-9, "1. while the last turn plays the line reaches the playback")
	_pb.playing = false

	# 2. A trail begins at the start of the last resolved turn (game time 10 s) while planning.
	var start := {"a": 2.0 * _turn_s, "b": NAN}
	_tracks.trail_start = func(id: String) -> float: return float(start.get(id, NAN))
	near(_tracks.line_limit("a"), 10.0, 1e-9, "2. the line of a unit with a trail ends where the trail begins")
	eq(_tracks.drawn_points("a"), 2 * per_turn + 1, "2. so the last turn's points are left to the ribbon (%d points)" % (2 * per_turn + 1))
	var ts: PackedFloat64Array = _tracks.tracks["a"].t
	near(float(ts[_tracks.drawn_points("a") - 1]), 10.0, 1e-9, "2. and the line's last point is the end of the turn before (a dot there)")
	var marks: PackedInt32Array = _tracks.tracks["a"].marks
	eq(int(marks[1]), _tracks.drawn_points("a") - 1, "2. the second turn's end dot is the last point on the line")
	check(int(marks[2]) >= _tracks.drawn_points("a"), "2. the third turn's end dot (at the plane) is not on it")

	# 3. While the last turn plays back, the line stops at the trail's start, or at the playback if that is less.
	_pb.playing = true
	_pb.playback_t = 3.0
	start["a"] = 2.0 * _turn_s + 3.0 - _turn_s    # a one-turn window: the ribbon begins a turn behind the plane
	near(_tracks.line_limit("a", _tracks.playback_limit()), 8.0, 1e-9, "3. playing, the line ends a turn behind the plane, where the ribbon begins")
	start["a"] = 2.0 * _turn_s + 9.0              # (a trail that begins ahead of the playback: the playback's reach rules)
	near(_tracks.line_limit("a", _tracks.playback_limit()), 13.0, 1e-9, "3. and never ahead of the plane")
	start["a"] = 2.0 * _turn_s + 3.0 - _turn_s
	var played := _tracks.drawn_points("a")
	check(played > 0 and played < total, "3. fewer points than the whole flight (%d of %d)" % [played, total])

	# 4. Per unit: no trail, the whole line.
	_pb.playing = false
	eq(_tracks.line_limit("b"), INF, "4. a unit with no trail keeps its whole line")
	eq(_tracks.drawn_points("b"), total, "4. every point of it")
	check(_tracks.drawn_points("a") < _tracks.drawn_points("b"), "4. while the other's gives way")
	# The trail's start moves with the game: next planning phase it is a turn later.
	start["a"] = 3.0 * _turn_s
	eq(_tracks.drawn_points("a"), total, "4. a trail that begins at the end of the flight leaves the whole line")
	# And a trail of no mode (NAN for everyone) is today's whole line.
	start["a"] = NAN
	eq(_tracks.drawn_points("a"), total, "4. no trail anywhere: the whole line again")
	finish()
