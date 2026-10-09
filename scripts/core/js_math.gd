extends RefCounted

# NOT A REQUIREMENT ANY MORE. Alex, 2026-10-09: bit-exactness with the browser
# is not needed; visual parity is the bar, and the port tests compare to a
# tolerance. This file stays because it is written, proven (below) and free at
# runtime -- and because pure-GDScript math is what would keep a Windows and a
# Linux build placing the same trees from one seed if the world is ever
# generated on every peer (the engine's trig comes from each platform's C
# runtime). Nothing new has to use it; engine math on the placement path is
# fine. The rest of this header is the original reasoning, kept as a record.
#
# JavaScript's Math.hypot, Math.sin, Math.cos, Math.atan, Math.atan2 and
# Math.round EXACTLY AS V8 COMPUTES THEM, for the scene generator's placement
# path (scripts/world/). The prototype (reference/inkwood-renderer.html) feeds
# all of them into decisions: Math.hypot into the wall distance that rejects a
# tree, the road's sample count and normals, the fort's arc and segment counts;
# Math.cos/sin into every prop position and the fort and house transforms;
# Math.atan2 into the house's rotation. "The same seed draws the same scene" is
# a bit-for-bit claim, so a last-bit difference in any of these is a different
# scene sooner or later.
#
# WHY NOT THE ENGINE'S: Godot's sin/cos/atan2 call the C runtime of whatever
# compiled the engine, and sqrt(x*x + y*y) is not how V8 computes hypot. Both
# are within an ulp of the truth, neither is the same ulp as V8's. Measured
# 2026-10-09 under node 25.2.1 (V8 14.1): sqrt(a*a + b*b) differs from
# Math.hypot in 41% of random calls; the functions below matched V8 on 3
# million random inputs each (sin, cos, atan, atan2, hypot), zero mismatches.
#
# WHAT V8 USES: Math.hypot is a Torque builtin (src/builtins/math.tq,
# MathHypot): scale every argument by the largest, Kahan-sum the squares, take
# the root, scale back. sin/cos/atan/atan2 are fdlibm (src/base/ieee754.cc, the
# FreeBSD msun sources); that is what node's V8 runs, verified above.
#
# NODE IS NOT CHROME, measured 2026-10-09 in the Claude desktop app's built-in
# Chromium 152: its Math.hypot is the same, but its Math.sin and Math.cos
# differ from fdlibm in the last bit in about 3% of calls and Math.atan2 in
# about 18% (a V8 build can take sin/cos from glibc-derived code instead,
# v8_use_libm_trig_functions). The engine's own sin/cos/atan2 match neither.
# For the default scene the difference is three doubles of the house (its rot,
# one part's ss, the other's cc, 1 ulp each); every tree, prop, wall, road
# sample and house corner is identical. The port-check fixtures come from node,
# so this file is fdlibm; matching Chrome bit for bit would mean porting what
# Chromium's V8 runs, not this.
#
# CONSTANTS TRAVEL AS BIT PATTERNS. The fdlibm sources write each constant as a
# 21-digit decimal with its hex words in a comment; Godot's float parser is not
# correctly rounded past 15 significant digits (CLAUDE.md, engine traps), so
# every constant below is built from those hex words and the decimal is kept
# only as the comment.
#
# Not ported: fdlibm's __kernel_rem_pio2, the reduction for |x| > 2^19 * pi/2
# (about 823550). Nothing in the generator comes near it; an argument that does
# is reported loudly and yields NAN rather than a quietly different value.

static func _from_words(hi: int, lo: int) -> float:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u32(0, lo & 0xFFFFFFFF)
	b.encode_u32(4, hi & 0xFFFFFFFF)
	return b.decode_double(0)

# fdlibm's GET_HIGH_WORD, signed (int32_t) as fdlibm declares it.
static func _hi(x: float) -> int:
	return PackedFloat64Array([x]).to_byte_array().decode_s32(4)

# fdlibm's GET_LOW_WORD, unsigned.
static func _lo(x: float) -> int:
	return PackedFloat64Array([x]).to_byte_array().decode_u32(0)

# --- Math.hypot ---------------------------------------------------------------

# V8's MathHypot for two arguments:
#
#   max = largest |arg|; if max == Infinity return Infinity; if any NaN return
#   NaN; if max == 0 return 0;
#   for each arg: n = |arg| / max; summand = n*n - compensation;
#     preliminary = sum + summand; compensation = (preliminary - sum) - summand;
#     sum = preliminary;
#   return sqrt(sum) * max;
#
# With two arguments the compensation never reaches a term (the first term is
# added to an exact 0), so the loop is (|a|/max)^2 + (|b|/max)^2 in argument
# order. Written out rather than looped; the order of the sum is kept anyway.
static func hypot(a: float, b: float) -> float:
	var x := absf(a)
	var y := absf(b)
	if is_inf(x) or is_inf(y):
		return INF
	if is_nan(x) or is_nan(y):
		return NAN
	var m := maxf(x, y)
	if m == 0.0:
		return 0.0
	var nx := x / m
	var ny := y / m
	var sum := 0.0
	var compensation := 0.0
	var summand := nx * nx - compensation
	var preliminary := sum + summand
	compensation = (preliminary - sum) - summand
	sum = preliminary
	summand = ny * ny - compensation
	preliminary = sum + summand
	sum = preliminary
	return sqrt(sum) * m

# --- Math.round ----------------------------------------------------------------

# The nearest integer, ties toward +Infinity. Not floor(x + 0.5), which rounds
# 0.49999999999999994 up (the sum rounds to 1.0). x - floor(x) is exact for
# every double that has a fraction, so the comparison is exact.
static func round(x: float) -> float:
	var r := floorf(x)
	if x - r >= 0.5:
		r += 1.0
	return r

# --- sin / cos (fdlibm) --------------------------------------------------------

static var _S1: float = _from_words(0xBFC55555, 0x55555549)  # -1.66666666666666324348e-01
static var _S2: float = _from_words(0x3F811111, 0x1110F8A6)  #  8.33333333332248946124e-03
static var _S3: float = _from_words(0xBF2A01A0, 0x19C161D5)  # -1.98412698298579493134e-04
static var _S4: float = _from_words(0x3EC71DE3, 0x57B1FE7D)  #  2.75573137070700676789e-06
static var _S5: float = _from_words(0xBE5AE5E6, 0x8A2B9CEB)  # -2.50507602534068634195e-08
static var _S6: float = _from_words(0x3DE5D93A, 0x5ACFD57C)  #  1.58969099521155010221e-10

static var _C1: float = _from_words(0x3FA55555, 0x5555554C)  #  4.16666666666666019037e-02
static var _C2: float = _from_words(0xBF56C16C, 0x16C15177)  # -1.38888888888741095749e-03
static var _C3: float = _from_words(0x3EFA01A0, 0x19CB1590)  #  2.48015872894767294178e-05
static var _C4: float = _from_words(0xBE927E4F, 0x809C52AD)  # -2.75573143513906633035e-07
static var _C5: float = _from_words(0x3E21EE9E, 0xBDB4B1C4)  #  2.08757232129817482790e-09
static var _C6: float = _from_words(0xBDA8FAE9, 0xBE8838D4)  # -1.13596475577881948265e-11

static var _INVPIO2: float = _from_words(0x3FE45F30, 0x6DC9C883)  # 6.36619772367581382433e-01  53 bits of 2/pi
static var _PIO2_1: float = _from_words(0x3FF921FB, 0x54400000)   # 1.57079632673412561417e+00  first 33 bits of pi/2
static var _PIO2_1T: float = _from_words(0x3DD0B461, 0x1A626331)  # 6.07710050650619224932e-11  pi/2 - pio2_1
static var _PIO2_2: float = _from_words(0x3DD0B461, 0x1A600000)   # 6.07710050630396597660e-11  second 33 bits
static var _PIO2_2T: float = _from_words(0x3BA3198A, 0x2E037073)  # 2.02226624879595063154e-21
static var _PIO2_3: float = _from_words(0x3BA3198A, 0x2E000000)   # 2.02226624871116645580e-21  third 33 bits
static var _PIO2_3T: float = _from_words(0x397B839A, 0x252049C1)  # 8.47842766036889956997e-32

# High words of n * pi/2 for n = 1..32 (fdlibm's npio2_hw), the quick
# no-cancellation check of the medium-size reduction.
const _NPIO2_HW: Array[int] = [
	0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
	0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
	0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
	0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
	0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
	0x404858EB, 0x404921FB,
]

# __kernel_sin(x, y, iy): sin on [-pi/4, pi/4]; y is the tail of x, iy says
# whether it is meaningful.
static func _ksin(x: float, y: float, iy: int) -> float:
	var ix := _hi(x) & 0x7FFFFFFF
	if ix < 0x3E400000:  # |x| < 2^-27
		if int(x) == 0:
			return x
	var z := x * x
	var v := z * x
	var r := _S2 + z * (_S3 + z * (_S4 + z * (_S5 + z * _S6)))
	if iy == 0:
		return x + v * (_S1 + z * r)
	return x - ((z * (0.5 * y - v * r) - y) - v * _S1)

# __kernel_cos(x, y): cos on [-pi/4, pi/4].
static func _kcos(x: float, y: float) -> float:
	var ix := _hi(x) & 0x7FFFFFFF
	if ix < 0x3E400000:  # |x| < 2^-27
		if int(x) == 0:
			return 1.0
	var z := x * x
	var r := z * (_C1 + z * (_C2 + z * (_C3 + z * (_C4 + z * (_C5 + z * _C6)))))
	if ix < 0x3FD33333:  # |x| < 0.3
		return 1.0 - (0.5 * z - (z * r - x * y))
	var qx: float
	if ix > 0x3FE90000:  # |x| > 0.78125
		qx = 0.28125
	else:
		qx = _from_words(ix - 0x00200000, 0)  # x/4
	var iz := 0.5 * z - qx
	var a := 1.0 - qx
	return a - (iz - (z * r - x * y))

# __ieee754_rem_pio2(x, y): x - n*pi/2 as y[0] + y[1], returns n. Small and
# medium arguments only (see the header).
static func _rem_pio2(x: float, y: PackedFloat64Array) -> int:
	var hx := _hi(x)
	var ix := hx & 0x7FFFFFFF
	var z: float
	if ix <= 0x3FE921FB:  # |x| ~<= pi/4, no reduction
		y[0] = x
		y[1] = 0.0
		return 0
	if ix < 0x4002D97C:  # |x| < 3pi/4, n = +-1
		if hx > 0:
			z = x - _PIO2_1
			if ix != 0x3FF921FB:  # 33+53 bit pi is good enough
				y[0] = z - _PIO2_1T
				y[1] = (z - y[0]) - _PIO2_1T
			else:  # near pi/2, use 33+33+53 bit pi
				z -= _PIO2_2
				y[0] = z - _PIO2_2T
				y[1] = (z - y[0]) - _PIO2_2T
			return 1
		z = x + _PIO2_1
		if ix != 0x3FF921FB:
			y[0] = z + _PIO2_1T
			y[1] = (z - y[0]) + _PIO2_1T
		else:
			z += _PIO2_2
			y[0] = z + _PIO2_2T
			y[1] = (z - y[0]) + _PIO2_2T
		return -1
	if ix <= 0x413921FB:  # |x| ~<= 2^19 * (pi/2), medium size
		var t := absf(x)
		var n := int(t * _INVPIO2 + 0.5)
		var fn := float(n)
		var r := t - fn * _PIO2_1
		var w := fn * _PIO2_1T  # first round, good to 85 bits
		if n < 32 and ix != _NPIO2_HW[n - 1]:
			y[0] = r - w  # quick check: no cancellation
		else:
			var j := ix >> 20
			y[0] = r - w
			var i := j - ((_hi(y[0]) >> 20) & 0x7FF)
			if i > 16:  # second iteration, good to 118 bits
				t = r
				w = fn * _PIO2_2
				r = t - w
				w = fn * _PIO2_2T - ((t - r) - w)
				y[0] = r - w
				i = j - ((_hi(y[0]) >> 20) & 0x7FF)
				if i > 49:  # third iteration, 151 bits
					t = r
					w = fn * _PIO2_3
					r = t - w
					w = fn * _PIO2_3T - ((t - r) - w)
					y[0] = r - w
		y[1] = (r - y[0]) - w
		if hx < 0:
			y[0] = -y[0]
			y[1] = -y[1]
			return -n
		return n
	push_error("JsMath: argument %s needs __kernel_rem_pio2, which is not ported" % x)
	y[0] = NAN
	y[1] = NAN
	return 0

static func sin(x: float) -> float:
	var ix := _hi(x) & 0x7FFFFFFF
	if ix <= 0x3FE921FB:
		return _ksin(x, 0.0, 0)
	if ix >= 0x7FF00000:  # Inf or NaN
		return NAN
	var y := PackedFloat64Array([0.0, 0.0])
	var n := _rem_pio2(x, y)
	match n & 3:
		0:
			return _ksin(y[0], y[1], 1)
		1:
			return _kcos(y[0], y[1])
		2:
			return -_ksin(y[0], y[1], 1)
		_:
			return -_kcos(y[0], y[1])

static func cos(x: float) -> float:
	var ix := _hi(x) & 0x7FFFFFFF
	if ix <= 0x3FE921FB:
		return _kcos(x, 0.0)
	if ix >= 0x7FF00000:
		return NAN
	var y := PackedFloat64Array([0.0, 0.0])
	var n := _rem_pio2(x, y)
	match n & 3:
		0:
			return _kcos(y[0], y[1])
		1:
			return -_ksin(y[0], y[1], 1)
		2:
			return -_kcos(y[0], y[1])
		_:
			return _ksin(y[0], y[1], 1)

# --- atan / atan2 (fdlibm) -------------------------------------------------------

static var _ATANHI: PackedFloat64Array = PackedFloat64Array([
	_from_words(0x3FDDAC67, 0x0561BB4F),  # atan(0.5) hi  4.63647609000806093515e-01
	_from_words(0x3FE921FB, 0x54442D18),  # atan(1.0) hi  7.85398163397448278999e-01
	_from_words(0x3FEF730B, 0xD281F69B),  # atan(1.5) hi  9.82793723247329054082e-01
	_from_words(0x3FF921FB, 0x54442D18),  # atan(inf) hi  1.57079632679489655800e+00
])
static var _ATANLO: PackedFloat64Array = PackedFloat64Array([
	_from_words(0x3C7A2B7F, 0x222F65E2),  # 2.26987774529616870924e-17
	_from_words(0x3C81A626, 0x33145C07),  # 3.06161699786838301793e-17
	_from_words(0x3C700788, 0x7AF0CBBD),  # 1.39033110312309984516e-17
	_from_words(0x3C91A626, 0x33145C07),  # 6.12323399573676603587e-17
])
static var _AT: PackedFloat64Array = PackedFloat64Array([
	_from_words(0x3FD55555, 0x5555550D),  #  3.33333333333329318027e-01
	_from_words(0xBFC99999, 0x9998EBC4),  # -1.99999999998764832476e-01
	_from_words(0x3FC24924, 0x920083FF),  #  1.42857142725034663711e-01
	_from_words(0xBFBC71C6, 0xFE231671),  # -1.11111104054623557880e-01
	_from_words(0x3FB745CD, 0xC54C206E),  #  9.09088713343650656196e-02
	_from_words(0xBFB3B0F2, 0xAF749A6D),  # -7.69187620504482999495e-02
	_from_words(0x3FB10D66, 0xA0D03D51),  #  6.66107313738753120669e-02
	_from_words(0xBFADDE2D, 0x52DEFD9A),  # -5.83357013379057348645e-02
	_from_words(0x3FA97B4B, 0x24760DEB),  #  4.97687799461593236017e-02
	_from_words(0xBFA2B444, 0x2C6A6C2F),  # -3.65315727442169155270e-02
	_from_words(0x3F90AD3A, 0xE322DA11),  #  1.62858201153657823623e-02
])
static var _PI: float = _from_words(0x400921FB, 0x54442D18)     # 3.1415926535897931160e+00
static var _PI_O_2: float = _from_words(0x3FF921FB, 0x54442D18)  # 1.5707963267948965580e+00
static var _PI_O_4: float = _from_words(0x3FE921FB, 0x54442D18)  # 7.8539816339744827900e-01
static var _PI_LO: float = _from_words(0x3CA1A626, 0x33145C07)   # 1.2246467991473531772e-16

static func atan(x: float) -> float:
	return _atan(x)

static func _atan(x: float) -> float:
	var hx := _hi(x)
	var ix := hx & 0x7FFFFFFF
	var id: int
	if ix >= 0x44100000:  # |x| >= 2^66
		if is_nan(x):
			return x + x
		return _ATANHI[3] + _ATANLO[3] if hx > 0 else -_ATANHI[3] - _ATANLO[3]
	if ix < 0x3FDC0000:  # |x| < 0.4375
		if ix < 0x3E400000:  # |x| < 2^-27
			return x
		id = -1
	else:
		x = absf(x)
		if ix < 0x3FF30000:  # |x| < 1.1875
			if ix < 0x3FE60000:  # 7/16 <= |x| < 11/16
				id = 0
				x = (2.0 * x - 1.0) / (2.0 + x)
			else:  # 11/16 <= |x| < 19/16
				id = 1
				x = (x - 1.0) / (x + 1.0)
		elif ix < 0x40038000:  # |x| < 2.4375
			id = 2
			x = (x - 1.5) / (1.0 + 1.5 * x)
		else:  # 2.4375 <= |x| < 2^66
			id = 3
			x = -1.0 / x
	# end of argument reduction
	var z := x * x
	var w := z * z
	# the sum from i=0 to 10 of aT[i] z^(i+1), split into odd and even polynomials
	var s1 := z * (_AT[0] + w * (_AT[2] + w * (_AT[4] + w * (_AT[6] + w * (_AT[8] + w * _AT[10])))))
	var s2 := w * (_AT[1] + w * (_AT[3] + w * (_AT[5] + w * (_AT[7] + w * _AT[9]))))
	if id < 0:
		return x - x * (s1 + s2)
	z = _ATANHI[id] - ((x * (s1 + s2) - _ATANLO[id]) - x)
	return -z if hx < 0 else z

static func atan2(y: float, x: float) -> float:
	if is_nan(x) or is_nan(y):
		return x + y
	var hx := _hi(x)
	var lx := _lo(x)
	var ix := hx & 0x7FFFFFFF
	var hy := _hi(y)
	var ly := _lo(y)
	var iy := hy & 0x7FFFFFFF
	if ((hx - 0x3FF00000) | lx) == 0:  # x = 1.0
		return _atan(y)
	var m := ((hy >> 31) & 1) | ((hx >> 30) & 2)  # 2*sign(x) + sign(y)
	# when y = 0
	if (iy | ly) == 0:
		match m:
			0, 1:
				return y  # atan(+-0, +anything) = +-0
			2:
				return _PI  # atan(+0, -anything) = pi
			_:
				return -_PI  # atan(-0, -anything) = -pi
	# when x = 0
	if (ix | lx) == 0:
		return -_PI_O_2 if hy < 0 else _PI_O_2
	# when x is INF
	if ix == 0x7FF00000:
		if iy == 0x7FF00000:
			match m:
				0:
					return _PI_O_4  # atan(+INF, +INF)
				1:
					return -_PI_O_4  # atan(-INF, +INF)
				2:
					return 3.0 * _PI_O_4  # atan(+INF, -INF)
				_:
					return -3.0 * _PI_O_4  # atan(-INF, -INF)
		match m:
			0:
				return 0.0  # atan(+..., +INF)
			1:
				return -0.0  # atan(-..., +INF)
			2:
				return _PI  # atan(+..., -INF)
			_:
				return -_PI  # atan(-..., -INF)
	# when y is INF
	if iy == 0x7FF00000:
		return -_PI_O_2 if hy < 0 else _PI_O_2
	# compute y/x
	var k := (iy - ix) >> 20
	var z: float
	if k > 60:  # |y/x| > 2^60
		z = _PI_O_2 + 0.5 * _PI_LO
		m &= 1
	elif hx < 0 and k < -60:  # 0 > |y|/x > -2^-60
		z = 0.0
	else:
		z = _atan(absf(y / x))
	match m:
		0:
			return z  # atan(+, +)
		1:
			return -z  # atan(-, +)
		2:
			return _PI - (z - _PI_LO)  # atan(+, -)
		_:
			return (z - _PI_LO) - _PI  # atan(-, -)
