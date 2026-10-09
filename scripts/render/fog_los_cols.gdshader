// LINE OF SIGHT, step 2 of the vision mask (Track F): the vertical half of an
// exact Euclidean distance transform of the shape coverage
// (fog_los_shape.gdshader), limited to `reach` mask pixels.
//
// For each pixel, in its own column: g_out = the distance up or down to the
// nearest OUTSIDE pixel (0 when this pixel is outside), g_in = the same to the
// nearest INSIDE pixel (0 when this pixel is inside); `reach + 1` when there is
// none within reach. Output (g_out, g_in, inside, 1).
//
// Step 3 (fog_mask_los.gdshader) combines the columns along a row:
//   nearest opposite pixel from (x, y) = min over dx of sqrt(dx^2 + g(x + dx)^2)
// which is exact because the nearest opposite pixel of a column is the best
// candidate in that column. Two passes of 2 reach + 1 samples replace one of
// (2 reach + 1)^2. Pixels outside the viewport count as their nearest edge pixel.

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D shape : filter_nearest, repeat_disable;
uniform int reach = 37;
uniform vec2 texel = vec2(0.0015625, 0.0027777);   // 1 / mask size

void fragment() {
	float inside = texture(shape, UV).a > 0.5 ? 1.0 : 0.0;
	float far = float(reach + 1);
	float g_out = inside > 0.5 ? far : 0.0;
	float g_in = inside > 0.5 ? 0.0 : far;
	for (int i = 1; i <= reach; i++) {
		float fi = float(i);
		float a1 = texture(shape, UV + vec2(0.0, fi * texel.y)).a;
		float a2 = texture(shape, UV - vec2(0.0, fi * texel.y)).a;
		if (a1 > 0.5 || a2 > 0.5) {
			g_in = min(g_in, fi);
		}
		if (a1 <= 0.5 || a2 <= 0.5) {
			g_out = min(g_out, fi);
		}
	}
	COLOR = vec4(g_out, g_in, inside, 1.0);
}
