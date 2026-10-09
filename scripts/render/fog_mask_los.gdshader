// LINE OF SIGHT, step 3 of the vision mask (Track F): the final mask when any
// unit has a viewshed. The same clamped signed distance field as
// fog_mask.gdshader --
//
//   m = clamp(0.5 + signed distance / (2 range), 0, 1)     (mask pixels)
//
// -- so the compositor (fog_composite.gdshader) reads it unchanged -- with the
// signed distance of the SHAPES (the union of the units' viewsheds) from an
// exact Euclidean distance transform, and the plain circles' analytic distance
// (units without a viewshed) joined by max, which keeps the union exact.
//
// The columns came from fog_los_cols.gdshader (read back here through the
// viewport's own screen texture, so this must be drawn after it, with a
// BackBufferCopy between). Along this pixel's row, the nearest pixel of the
// opposite class is min over dx of sqrt(dx^2 + g(x + dx)^2); the pixel's centre
// is half a pixel from the edge between it and that neighbour, so
// signed distance = +-(that - 0.5), clamped to +-(reach - 0.5), which is past
// range_mask (the layer sets reach = ceil(range_mask) + 1).

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D cols : hint_screen_texture, filter_nearest, repeat_disable;
uniform int reach = 37;
uniform vec2 texel = vec2(0.0015625, 0.0027777);   // 1 / mask size
uniform int count = 0;
uniform vec4 circles[64];      // x, y, r in mask px; w unused
uniform float range_mask = 24.0;
uniform vec2 mask_size = vec2(640.0, 360.0);

void fragment() {
	bool inside = texture(cols, SCREEN_UV).b > 0.5;
	float best = float(reach);
	for (int i = -reach; i <= reach; i++) {
		vec4 c = texture(cols, SCREEN_UV + vec2(float(i) * texel.x, 0.0));
		float g = inside ? c.r : c.g;
		best = min(best, length(vec2(float(i), g)));
	}
	float sd = (inside ? 1.0 : -1.0) * (best - 0.5);
	float m = clamp(0.5 + sd / (2.0 * range_mask), 0.0, 1.0);
	vec2 p = UV * mask_size;
	for (int i = 0; i < count; i++) {
		vec4 c = circles[i];
		m = max(m, clamp(0.5 + (c.z - distance(p, c.xy)) / (2.0 * range_mask), 0.0, 1.0));
	}
	COLOR = vec4(m, m, m, 1.0);
}
