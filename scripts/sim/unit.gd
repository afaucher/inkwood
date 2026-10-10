extends RefCounted

# One unit in the World: its runtime state, its plan for this turn, and what
# happened to it in the last resolve. Created by World.add_unit; everything
# that changes it goes through the World, so the World can keep the plan's
# preview, the ready flags and the turn phase consistent.
#
# Field names are the demo-plan interface's (docs/proposals/demo-plan.md,
# "S exposes"): id, type, side, controller, x, y, heading, speed,
# altitude_band, plan -- plus def, history and out_of_bounds. The UI reads
# them as properties (unit.x) or as a Dictionary through to_dict().
#
# UNITS (proposed, Track S): metres, radians, metres per second. x right, y
# down (the prototype's canvas and Godot 2D); heading 0 points along +x and a
# positive turn is clockwise on screen, so the direction of motion is
# Vector2(cos(heading), sin(heading)). x and y are float64 -- never round them
# through a Vector2 (float32) on the way back in.
#
# No unit belongs to a player (design doc, Co-op and turns): `controller` says
# only whether players or the AI give it orders.

const UnitDef = preload("res://scripts/sim/unit_def.gd")

const CONTROLLER_PLAYER := "player"
const CONTROLLER_AI := "ai"

var id: String = ""
# The unit's callsign ("Wizard"), optional: a scenario assigns it from the
# pools in data/names/callsigns.json. The roster shows it first, with the type
# under it; "" means none, and the UI falls back to the id.
var callsign: String = ""
var type: String = ""          # the unit type id: data/units/<type>.json
var def: UnitDef = null
var side: String = ""
var controller: String = ""    # CONTROLLER_PLAYER or CONTROLLER_AI
var x: float = 0.0
var y: float = 0.0
var heading: float = 0.0
var speed: float = 0.0
var altitude_band: String = ""
# This turn's step requests (envelope.gd's request shape), index = step. Steps
# past the end of the plan are "carry on": straight, holding speed.
var plan: Array = []
# The last resolve: [state at the start of the turn, state after step 0, ...],
# def.actions_per_turn + 1 entries, each with t (seconds into the turn).
var history: Array = []
var out_of_bounds: bool = false
# Combat state (the first fight's contract, proposed by the lead 2026-10-09):
# health in pips, set from the type's data by World.add_unit; down once it
# reaches 0. down_at is the time into the last resolved turn, in seconds, at
# which the unit went down, NAN if it did not go down in that turn. A down unit
# no longer plans, fires or is fired at (Track C builds that).
var health: int = 0
var down: bool = false
var down_at: float = NAN

func state() -> Dictionary:
	return {"x": x, "y": y, "heading": heading, "speed": speed, "altitude_band": altitude_band}

func apply_state(s: Dictionary) -> void:
	x = float(s["x"])
	y = float(s["y"])
	heading = float(s["heading"])
	speed = float(s["speed"])
	altitude_band = str(s["altitude_band"])

# The interface's Dictionary view. Deep copies: changing it changes nothing.
func to_dict() -> Dictionary:
	return {
		"id": id,
		"callsign": callsign,
		"type": type,
		"side": side,
		"controller": controller,
		"x": x,
		"y": y,
		"heading": heading,
		"speed": speed,
		"altitude_band": altitude_band,
		"plan": plan.duplicate(true),
		"history": history.duplicate(true),
		"out_of_bounds": out_of_bounds,
		"health": health,
		"down": down,
		"down_at": down_at,
	}

# Everything a resolve changes, for sending a resolved turn over the network
# (World.apply_resolution). A track that adds runtime state a resolve changes
# adds it here and in apply_net_state, or clients drift from the host.
func net_state() -> Dictionary:
	return {
		"x": x, "y": y, "heading": heading, "speed": speed, "altitude_band": altitude_band,
		"out_of_bounds": out_of_bounds, "health": health, "down": down, "down_at": down_at,
	}

func apply_net_state(s: Dictionary) -> void:
	apply_state(s)
	out_of_bounds = bool(s["out_of_bounds"])
	health = int(s["health"])
	down = bool(s["down"])
	down_at = float(s["down_at"])
