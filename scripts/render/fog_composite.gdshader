// THE FOG COMPOSITOR (Track F, first option). scripts/render/fog_layer.gd draws
// the topographic chunks (fog_topo.gd) as quads in WORLD px over the full
// render, with this material: each fragment shows the topographic map where
// the vision mask says it is out of sight, and nothing (the full render below)
// where it is in sight. Everything is a uniform from data/view/fog.json and
// camera.json; every colour arrives resolved from a palette role (rule 6).
//
// mask: fog_mask.gdshader's texture, the same size ratio as the screen, so
// SCREEN_UV addresses it. Its value is a clamped signed distance: (m - .5) x 2
// x range_px is SCREEN px from the vision edge, positive inside.
//
// edge_mode 0, INKED: a hard cut (1 px antialiased) on the edge with
//   world-anchored wobble, an ink line on it, and ink hatching on the fog side
//   whose lines end raggedly within band_px.
// edge_mode 1, SOFT: a cross-fade over feather_px with two octaves of noise
//   on the edge.
// overview (0..1, from camera.json far_zoom): the topographic map shows
//   everywhere; the edge (when show_edge is 1) and a faint wash over what is
//   NOT seen (outside_color, overview only) still show what the players see.
//
// Noise is anchored to the WORLD (world px x zoom = screen-scaled world
// coordinates), so the edge does not swim when the view pans.

shader_type canvas_item;
render_mode unshaded;

uniform sampler2D mask : filter_linear, repeat_disable;
uniform float range_px = 64.0;
uniform int edge_mode = 0;
uniform float zoom = 1.0;
uniform float overview = 0.0;
uniform float show_edge = 1.0;
uniform vec4 outside_color;

uniform vec4 line_color;
uniform float line_px = 1.5;
uniform float wobble_px = 2.5;
uniform float wobble_freq = 0.02;
uniform float band_px = 26.0;
uniform vec4 hatch_color;
uniform float hatch_spacing = 4.0;
uniform float hatch_width = 0.9;
uniform vec2 hatch_dir = vec2(0.7071, 0.7071);

uniform float feather_px = 80.0;
uniform float soft_wobble_px = 16.0;
uniform float soft_wobble_freq = 0.012;

varying vec2 world;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Coverage of a line `width` px wide at distance d px from its centre: a 1 px
// box filter, and below 1 px the hairline rule the drawing layer uses (one
// pixel wide, alpha x width).
float line_cov(float d, float width) {
	float w = max(width, 1.0);
	return clamp(w * 0.5 + 0.5 - abs(d), 0.0, 1.0) * min(width, 1.0);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 topo = texture(TEXTURE, UV) * COLOR;
	float sdf = (texture(mask, SCREEN_UV).r - 0.5) * 2.0 * range_px;
	vec2 s = world * zoom;
	float vis;
	float line = 0.0;
	float hatch = 0.0;
	if (edge_mode == 0) {
		float e = sdf + (vnoise(s * wobble_freq) - 0.5) * 2.0 * wobble_px;
		vis = clamp(e + 0.5, 0.0, 1.0);
		line = line_cov(e, line_px);
		if (e < 0.0) {
			float h = dot(s, hatch_dir) / hatch_spacing;
			float idx = floor(h + 0.5);
			float reach = band_px * (0.45 + 0.55 * hash12(vec2(idx, 7.0)));
			hatch = line_cov((h - idx) * hatch_spacing, hatch_width) * (1.0 - smoothstep(reach - 2.0, reach, -e));
		}
	} else {
		float n = (vnoise(s * soft_wobble_freq) - 0.5) * 2.0 + (vnoise(s * soft_wobble_freq * 2.7 + 17.0) - 0.5);
		vis = smoothstep(-feather_px * 0.5, feather_px * 0.5, sdf + n * soft_wobble_px);
	}
	float fog = mix(1.0 - vis, 1.0, overview);
	vec3 col = mix(topo.rgb, outside_color.rgb, outside_color.a * (1.0 - vis) * overview);
	col = mix(col, hatch_color.rgb, hatch_color.a * hatch * show_edge);
	float la = line_color.a * line * show_edge;
	float a = la + fog * (1.0 - la);
	vec3 rgb = (line_color.rgb * la + col * fog * (1.0 - la)) / max(a, 1e-5);
	COLOR = vec4(rgb, a);
}
