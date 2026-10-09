extends RefCounted

# Mulberry32, ported bit for bit from the prototype (reference/inkwood-renderer.html):
#
#   function mulberry32(a){return function(){a|=0;a=a+0x6D2B79F5|0;
#     let t=Math.imul(a^a>>>15,1|a);t=t+Math.imul(t^t>>>7,61|t)^t;
#     return((t^t>>>14)>>>0)/4294967296;};}
#
# THE SAME SEED MUST DRAW THE SAME SCENE as the browser prototype, which is why
# this is a port and not RandomNumberGenerator. JavaScript does the arithmetic
# in 32-bit integers; GDScript ints are 64-bit, so every step is masked back to
# 32 bits and the multiply is split so no intermediate can overflow. The stream
# is held in UNSIGNED form (0 .. 2^32-1) throughout -- xor, shift and the final
# division come out the same as JS's signed int32 as long as the representation
# is consistent, and unsigned is the one where `>>` means what `>>>` meant.
#
# scripts/tests/test_port_utils.gd compares this stream byte for byte against the
# prototype's own code run under node.
#
# DELIBERATELY NOT THE GLOBAL RNG. randi()/randf() are seeded once per launch
# and consumed by everything, so a scene drawn from them would differ between two
# machines that had drawn a different number of randoms before asking. Every
# generator takes one of these, seeded, and the seed is the whole scene.

const MASK32 := 0xFFFFFFFF

var _state: int

func _init(seed_value: int) -> void:
	_state = seed_value & MASK32

# Math.imul: the low 32 bits of a * b. Split a into 16-bit halves so that no
# intermediate exceeds 2^48 -- a full 32x32 product can reach 2^64, which is
# past what a signed 64-bit int holds.
static func imul(a: int, b: int) -> int:
	a &= MASK32
	b &= MASK32
	var lo: int = (a & 0xFFFF) * b
	var hi: int = (((a >> 16) * b) & 0xFFFF) << 16
	return (lo + hi) & MASK32

# The next value in [0, 1), exactly as the prototype's rng() returns it.
func next() -> float:
	_state = (_state + 0x6D2B79F5) & MASK32
	var a := _state
	var t := imul(a ^ (a >> 15), a | 1)
	t = ((t + imul(t ^ (t >> 7), t | 61)) ^ t) & MASK32
	return float((t ^ (t >> 14)) & MASK32) / 4294967296.0

# The prototype's `(rng()*2147483647)|0`: how it mints a seed for a sub-generator
# (one per tree, prop, wall and house).
func next_seed() -> int:
	return int(next() * 2147483647.0)
