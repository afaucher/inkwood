extends RefCounted

# The prototype's hash2 / vnoise / fbm (scripts/core/noise.gd), BIT FOR BIT
# the same values, about five times faster: the drawing layer calls vnoise for
# every point of every scallop contour, wall crest and road rut, and fbm for
# every dirt dart -- the largest share of a chunk's CPU time.
#
# Why it can be faster and still exact: core/noise.gd multiplies through
# Mulberry32.imul, which splits each factor into 16-bit halves because a full
# 32 x 32 bit product can overflow a signed 64-bit int. The hash's constants
# are all below 2^31 and its other factor is masked to 32 bits first, so every
# product here is below 2^63 and needs no split; and the four lattice hashes
# of a vnoise are written inline rather than as 17 function calls.
# scripts/tests/test_render_layer.gd checks these against core/noise.gd on
# thousands of inputs, negative and huge coordinates included.

const M := 0xFFFFFFFF

static func hash2(i: int, j: int, s: int) -> float:
	var h: int = (((i & M) * 374761393) & M) + (((j & M) * 668265263) & M) + (((s & M) * 1442695041) & M)
	h &= M
	h = ((h ^ (h >> 13)) * 1274126177) & M
	h ^= h >> 16
	return float(h) / 4294967296.0

static func vnoise(x: float, y: float, s: int) -> float:
	var xi: float = floorf(x)
	var yi: float = floorf(y)
	var xf: float = x - xi
	var yf: float = y - yi
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var ix: int = int(xi)
	var iy: int = int(yi)
	var hs: int = ((s & M) * 1442695041) & M
	var hx0: int = ((ix & M) * 374761393) & M
	var hx1: int = (((ix + 1) & M) * 374761393) & M
	var hy0: int = ((iy & M) * 668265263) & M
	var hy1: int = (((iy + 1) & M) * 668265263) & M
	var h: int = (hx0 + hy0 + hs) & M
	h = ((h ^ (h >> 13)) * 1274126177) & M
	h ^= h >> 16
	var a: float = float(h) / 4294967296.0
	h = (hx1 + hy0 + hs) & M
	h = ((h ^ (h >> 13)) * 1274126177) & M
	h ^= h >> 16
	var b: float = float(h) / 4294967296.0
	h = (hx0 + hy1 + hs) & M
	h = ((h ^ (h >> 13)) * 1274126177) & M
	h ^= h >> 16
	var c: float = float(h) / 4294967296.0
	h = (hx1 + hy1 + hs) & M
	h = ((h ^ (h >> 13)) * 1274126177) & M
	h ^= h >> 16
	var d: float = float(h) / 4294967296.0
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v

static func fbm(x: float, y: float, s: int, octaves: int) -> float:
	var v: float = 0.0
	var a: float = 0.5
	var f: float = 1.0
	var n: float = 0.0
	for i in octaves:
		v += a * vnoise(x * f, y * f, s + i * 17)
		n += a
		a *= 0.5
		f *= 2.03
	return v / n
