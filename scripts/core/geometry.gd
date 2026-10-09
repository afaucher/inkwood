extends RefCounted

# Polyline and polygon helpers, ported from the prototype (reference/inkwood-renderer.html):
# the convex hull (prism shadows), Catmull-Rom sampling (the road), Chaikin
# smoothing and arc-length resampling (freehand walls).
#
# PRECISION, STATED ONCE: Vector2 stores float32 in a standard Godot build. The
# arithmetic below runs in GDScript floats (64-bit) in the prototype's order,
# but every stored point is rounded to float32, so geometry matches the browser
# to about 1e-4 px rather than bit for bit. That is invisible on a map (the
# style's own hand wobble is 0.6 px) and is the trade-off for using the engine's
# own vector type. The RNG and noise are what "same seed, same scene" rests on,
# and those ARE bit-exact -- see mulberry32.gd and noise.gd.
#
# One documented divergence: where the prototype measures a length with
# Math.hypot (which V8 computes as a scaled Kahan sum), this file uses
# sqrt(dx*dx + dy*dy). They differ in the last bit in roughly a third of calls
# -- far inside the tolerance, and only worth matching if geometry ever moves to
# float64.

static func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)

# Convex hull by Andrew's monotone chain, counter-clockwise, collinear points
# dropped (the `<= 0` pops), first point not repeated at the end.
static func hull(points: PackedVector2Array) -> PackedVector2Array:
	var p: Array = Array(points)
	p.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	var lower: Array[Vector2] = []
	for q: Vector2 in p:
		while lower.size() >= 2 and _cross(lower[-2], lower[-1], q) <= 0.0:
			lower.pop_back()
		lower.append(q)
	var upper: Array[Vector2] = []
	for i in range(p.size() - 1, -1, -1):
		var q: Vector2 = p[i]
		while upper.size() >= 2 and _cross(upper[-2], upper[-1], q) <= 0.0:
			upper.pop_back()
		upper.append(q)
	upper.pop_back()
	lower.pop_back()
	return PackedVector2Array(lower + upper)

static func _catmull(p0: float, p1: float, p2: float, p3: float, t: float, t2: float, t3: float) -> float:
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)

# A Catmull-Rom spline through `control`, sampled about every `spacing` px --
# the prototype's buildRoad: each segment takes max(2, ceil(length / spacing))
# samples at t = k / steps, so the final control point itself is not emitted.
static func catmull_rom(control: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := control.size()
	for i in n - 1:
		var p0: Vector2 = control[maxi(i - 1, 0)]
		var p1: Vector2 = control[i]
		var p2: Vector2 = control[i + 1]
		var p3: Vector2 = control[mini(i + 2, n - 1)]
		var dx: float = p2.x - p1.x
		var dy: float = p2.y - p1.y
		var steps: int = maxi(2, ceili(sqrt(dx * dx + dy * dy) / spacing))
		for s in steps:
			var t: float = float(s) / steps
			var t2: float = t * t
			var t3: float = t2 * t
			out.append(Vector2(
				_catmull(p0.x, p1.x, p2.x, p3.x, t, t2, t3),
				_catmull(p0.y, p1.y, p2.y, p3.y, t, t2, t3)))
	return out

# One pass of Chaikin corner cutting. An open polyline keeps its two endpoints.
static func chaikin(p: PackedVector2Array, closed: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := p.size()
	var lim: int = n if closed else n - 1
	if not closed:
		out.append(p[0])
	for i in lim:
		var a: Vector2 = p[i]
		var b: Vector2 = p[(i + 1) % n]
		out.append(Vector2(a.x * 0.75 + b.x * 0.25, a.y * 0.75 + b.y * 0.25))
		out.append(Vector2(a.x * 0.25 + b.x * 0.75, a.y * 0.25 + b.y * 0.75))
	if not closed:
		out.append(p[n - 1])
	return out

# Resample a polyline at a fixed arc-length `step`. Open: the last source point
# is kept unless the last sample already sits within 0.3 step of it. Closed: the
# ring is walked back to its start, and a final sample within 0.5 step of the
# first is dropped so the ring does not double up at the seam.
static func resample(src: PackedVector2Array, step: float, closed: bool) -> PackedVector2Array:
	var pts := PackedVector2Array(src)
	if closed:
		pts.append(src[0])
	var out := PackedVector2Array([pts[0]])
	var acc: float = 0.0
	for i in range(1, pts.size()):
		var ax: float = pts[i - 1].x
		var ay: float = pts[i - 1].y
		var bx: float = pts[i].x
		var by: float = pts[i].y
		var seg: float = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
		while acc + seg >= step:
			var t: float = (step - acc) / seg
			ax += (bx - ax) * t
			ay += (by - ay) * t
			out.append(Vector2(ax, ay))
			seg = sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
			acc = 0.0
		acc += seg
	if not closed:
		var e: Vector2 = pts[pts.size() - 1]
		var l: Vector2 = out[out.size() - 1]
		if sqrt((e.x - l.x) * (e.x - l.x) + (e.y - l.y) * (e.y - l.y)) > step * 0.3:
			out.append(e)
	elif out.size() > 2:
		var l: Vector2 = out[out.size() - 1]
		var f: Vector2 = out[0]
		if sqrt((l.x - f.x) * (l.x - f.x) + (l.y - f.y) * (l.y - f.y)) < step * 0.5:
			out.remove_at(out.size() - 1)
	return out
