// The VISION MASK (Track F, first option), drawn every frame into a small
// SubViewport by scripts/render/fog_layer.gd: a clamped signed distance field
// of the union of the vision circles, in mask pixels.
//
//   m(p) = max over circles of clamp(0.5 + (r - |p - c|) / (2 range), 0, 1)
//
// so m >= 0.5 exactly on the union (the max keeps it exact where two edges
// meet), 1 deeper than `range` inside, 0 farther than `range` outside. The
// compositor (fog_composite.gdshader) turns it back into screen px.
// scripts/render/fog_vision.gd mask_value() is this formula on the CPU, which
// is what the headless test checks; fog_shot.gd reads the GPU result back and
// compares the two.
//
// The line-of-sight seam: a later vision rule draws each unit's visibility
// polygon into this viewport instead of the circles; the compositor only
// reads the texture.

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform int count = 0;
uniform vec4 circles[64];      // x, y, r in mask px; w unused
uniform float range_mask = 24.0;
uniform vec2 mask_size = vec2(640.0, 360.0);

void fragment() {
	// UV spans the ColorRect, which spans the mask: pixel centres in mask px.
	vec2 p = UV * mask_size;
	float m = 0.0;
	for (int i = 0; i < count; i++) {
		vec4 c = circles[i];
		m = max(m, clamp(0.5 + (c.z - distance(p, c.xy)) / (2.0 * range_mask), 0.0, 1.0));
	}
	COLOR = vec4(m, m, m, 1.0);
}
