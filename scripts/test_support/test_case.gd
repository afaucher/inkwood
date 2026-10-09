extends Node

# Base class for everything in scripts/tests/. Subclass it with:
#
#   extends "res://scripts/test_support/test_case.gd"
#   func setup(main) -> void:
#       eq(2 + 2, 4, "arithmetic")
#       finish()
#
# WHY A BASE CLASS AT ALL: the runner decides pass/fail by grepping stdout for
# `[TEST PASSED]`, so a test that forgets the marker, or prints it before its
# last assertion, is reported as a pass regardless of what happened. Funnelling
# every test through finish() makes that impossible to get wrong.
#
# TESTS THAT NEED FRAMES override _physics_process, NOT _process -- the deadline
# below uses _process, and an override without a super() call would disable it.
# Live in physics frames anyway: they are the fixed-delta ones, and --fixed-fps
# 60 makes them exactly reproducible.
#
# Carried over from Bridge to Friendship without its game-mode stamping, which
# has nothing to stamp here yet.

var test_name: String = ""

# Backstop for a test that waits for something that never arrives. The runner
# also has a 600s hang timeout, but that reports "TIMEOUT" with no idea which
# condition was never met -- this reports the test's own name in seconds, and
# any test that wants longer just raises it in setup().
var timeout_seconds: float = 30.0

var _failures: Array[String] = []
var _elapsed: float = 0.0
var _finished: bool = false

func _ready() -> void:
	if test_name == "":
		var path: String = get_script().resource_path
		test_name = path.get_file().get_basename()

func _process(delta: float) -> void:
	if _finished:
		return
	_elapsed += delta
	if _elapsed > timeout_seconds:
		fail("timed out after %.1fs waiting for the test to finish" % timeout_seconds)
		finish()

# --- Assertions --------------------------------------------------------------
#
# These RECORD rather than abort, so one run reports every problem instead of
# only the first. Each returns whether it held, for the cases where continuing
# past a failure would be nonsense (`if not check(node != null, ...): return`).

func check(condition: bool, message: String) -> bool:
	if not condition:
		fail(message)
	return condition

func eq(actual: Variant, expected: Variant, message: String) -> bool:
	if actual != expected:
		fail("%s -- expected %s, got %s" % [message, expected, actual])
		return false
	return true

func near(actual: float, expected: float, tolerance: float, message: String) -> bool:
	if absf(actual - expected) > tolerance:
		# No %g here: GDScript's `%` has none, and a format error here would
		# replace the message with the format string (observed 2026-10-09).
		fail("%s -- expected %.6f +/- %s, got %.6f" % [message, expected, str(tolerance), actual])
		return false
	return true

func fail(message: String) -> void:
	_failures.append(message)

# --- Completion --------------------------------------------------------------

func finish() -> void:
	if _finished:
		return
	_finished = true
	if _failures.is_empty():
		print(">>> [TEST PASSED] %s <<<" % test_name)
		get_tree().quit(0)
	else:
		for f in _failures:
			printerr("  ASSERT FAILED: ", f)
		print(">>> [TEST FAILED] %s (%d failed) <<<" % [test_name, _failures.size()])
		get_tree().quit(1)
