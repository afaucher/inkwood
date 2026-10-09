extends RefCounted

# Seeded value noise and fbm, ported from the prototype (reference/inkwood-renderer.html):
#
#   function hash2(i,j,s){let h=(Math.imul(i,374761393)+Math.imul(j,668265263)+Math.imul(s,1442695041))|0;
#     h=Math.imul(h^(h>>>13),1274126177);h^=h>>>16;return(h>>>0)/4294967296;}
#   function vnoise(x,y,s){const xi=Math.floor(x),yi=Math.floor(y),xf=x-xi,yf=y-yi,u=xf*xf*(3-2*xf),v=yf*yf*(3-2*yf);
#     const a=hash2(xi,yi,s),b=hash2(xi+1,yi,s),c=hash2(xi,yi+1,s),d=hash2(xi+1,yi+1,s);
#     return a+(b-a)*u+(c-a)*v+(a-b-c+d)*u*v;}
#   function fbm(x,y,s,o){let v=0,a=.5,f=1,n=0;for(let i=0;i<o;i++){v+=a*vnoise(x*f,y*f,s+i*17);n+=a;a*=.5;f*=2.03;}return v/n;}
#
# NOT FastNoiseLite: the design doc's handoff table says so in as many words.
# The paper tint, the dirt stipple, the tree density field and every wobbled
# contour read these, and a different noise is a different drawing from the
# same seed. The float arithmetic is written in the prototype's order of
# operations on purpose -- GDScript evaluates each operator as its own
# double-precision step, as JS does, so matching the order is what makes the
# results byte-identical (checked by scripts/tests/test_port_utils.gd).

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const MASK32 := 0xFFFFFFFF

# One lattice value in [0, 1) for integer cell (i, j) under seed s.
static func hash2(i: int, j: int, s: int) -> float:
	var h: int = (Mulberry32.imul(i, 374761393) + Mulberry32.imul(j, 668265263) + Mulberry32.imul(s, 1442695041)) & MASK32
	h = Mulberry32.imul(h ^ (h >> 13), 1274126177)
	h ^= h >> 16
	return float(h) / 4294967296.0

# Smoothstep-interpolated value noise in [0, 1).
static func vnoise(x: float, y: float, s: int) -> float:
	var xi: float = floorf(x)
	var yi: float = floorf(y)
	var xf: float = x - xi
	var yf: float = y - yi
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var ix: int = int(xi)
	var iy: int = int(yi)
	var a: float = hash2(ix, iy, s)
	var b: float = hash2(ix + 1, iy, s)
	var c: float = hash2(ix, iy + 1, s)
	var d: float = hash2(ix + 1, iy + 1, s)
	return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v

# Fractal sum of `octaves` vnoise layers, normalised to [0, 1). Each octave
# shifts the seed by 17 and the frequency by 2.03, as the prototype does.
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
