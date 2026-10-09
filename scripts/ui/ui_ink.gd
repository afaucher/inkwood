extends RefCounted

# Hand-inked drawing for the interface's live layers (CanvasItem _draw), in the
# map's manner: lines are wobbled by the same seeded value noise the prototype
# uses (scripts/core/noise.gd), so a card edge or a ring is never geometrically
# perfect; rules and rings use the sheet's double line (a heavy line and a fine
# one just inside it). Colours come in as resolved style roles, never literals.
#
# These draw every frame, so they are cheap: polylines and circles through the
# engine's own antialiased draw calls, not InkCanvas tessellation (which is for
# the baked art).

const ValueNoise = preload("res://scripts/core/noise.gd")

# A closed or open polyline pushed along its normals by value noise of arc
# length: the sheet's wobble(), sized in px.
static func wobble(pts: PackedVector2Array, closed: bool, amp: float, seed_value: int, freq: float = 0.045) -> PackedVector2Array:
	var n := pts.size()
	if amp <= 0.0 or n < 2:
		return pts
	var out := PackedVector2Array()
	out.resize(n)
	var s := 0.0
	for i in n:
		if i > 0:
			s += pts[i].distance_to(pts[i - 1])
		var a := pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b := pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var t := b - a
		var nrm := Vector2(-t.y, t.x).normalized() if t.length_squared() > 0.0 else Vector2.ZERO
		var v := ValueNoise.vnoise(s * freq, 1.7, seed_value)
		out[i] = pts[i] + nrm * (v * 2.0 - 1.0) * amp
	return out

# Points every `step` px along a polyline (closed: back to the start).
static func densify(pts: PackedVector2Array, closed: bool, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	if n == 0:
		return out
	var lim := n if closed else n - 1
	for i in lim:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var k := maxi(1, ceili(a.distance_to(b) / step))
		for j in k:
			out.append(a.lerp(b, float(j) / float(k)))
	if not closed:
		out.append(pts[n - 1])
	return out

static func rect_pts(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])

static func circle_pts(c: Vector2, r: float, n: int = 40) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out

static func closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(pts)
	if not pts.is_empty():
		out.append(pts[0])
	return out

# An inked outline: wobbled, drawn as one antialiased polyline.
static func ink_line(ci: CanvasItem, pts: PackedVector2Array, is_closed: bool, color: Color, width: float,
		seed_value: int = 1, amp: float = 0.6) -> void:
	if pts.size() < 2:
		return
	var p := wobble(densify(pts, is_closed, 6.0), is_closed, amp, seed_value)
	ci.draw_polyline(closed(p) if is_closed else p, color, width, true)

# A dashed open polyline, dash and gap in px along its length.
static func dashed(ci: CanvasItem, pts: PackedVector2Array, color: Color, width: float, dash: float, gap: float) -> void:
	var on := true
	var left := dash
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		var t := 0.0
		while t < seg:
			var d := minf(left, seg - t)
			var p0 := a.lerp(b, t / seg)
			var p1 := a.lerp(b, (t + d) / seg)
			if on:
				ci.draw_line(p0, p1, color, width, true)
			t += d
			left -= d
			if left <= 0.0:
				on = not on
				left = dash if on else gap

# The sheet's card: a filled rectangle, an outer inked edge and a fine inner rule.
static func card(ci: CanvasItem, r: Rect2, fill: Color, ink: Color, outer_w: float, inner_w: float,
		inset: float, amp: float, seed_value: int) -> void:
	ci.draw_rect(r, fill, true)
	ink_line(ci, rect_pts(r), true, ink, outer_w, seed_value, amp)
	var ri := r.grow(-inset)
	var faint := Color(ink.r, ink.g, ink.b, ink.a * 0.8)
	ink_line(ci, rect_pts(ri), true, faint, inner_w, seed_value + 17, amp)

# The plane's roundel as a mark: an accent disc, a cream eye, an ink rim.
static func roundel(ci: CanvasItem, c: Vector2, r: float, accent: Color, eye: Color, ink: Color) -> void:
	ci.draw_circle(c, r, accent, true, -1.0, true)
	ci.draw_circle(c, r * 0.4, eye, true, -1.0, true)
	ci.draw_circle(c, r, ink, false, 1.0, true)

# The sheet's "chosen" corner brackets around a rect.
static func brackets(ci: CanvasItem, r: Rect2, k: float, ink: Color, width: float) -> void:
	var x0 := r.position.x
	var y0 := r.position.y
	var x1 := r.end.x
	var y1 := r.end.y
	for c: Array in [[x0, y0, 1.0, 1.0], [x1, y0, -1.0, 1.0], [x1, y1, -1.0, -1.0], [x0, y1, 1.0, -1.0]]:
		var x: float = c[0]
		var y: float = c[1]
		ci.draw_polyline(PackedVector2Array([Vector2(x + c[2] * k, y), Vector2(x, y), Vector2(x, y + c[3] * k)]), ink, width, true)

# Text in ink: `align` HORIZONTAL_ALIGNMENT_*, `pos` is the baseline start (or
# the box's left edge for centre/right alignment over `width`).
static func text(ci: CanvasItem, font: Font, pos: Vector2, s: String, size: float, color: Color,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, width: float = -1.0) -> void:
	ci.draw_string(font, pos, s, align as HorizontalAlignment, width, int(round(size)), color)

static func text_width(font: Font, s: String, size: float) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(size))).x

# A card's cast shadow: the card's rect shifted away from the sun, in the map's
# shadow tint at the map's strength (the role carries both).
static func card_shadow(ci: CanvasItem, r: Rect2, offset: Vector2, shadow: Color) -> void:
	ci.draw_rect(Rect2(r.position + offset, r.size), shadow, true)
