// THE OUTSIDE OF THE MAP (builder, map-border board, 2026-10-11; PROPOSED -- see data/view/map_border.json).
// scripts/render/map_border_fill.gd draws four rectangles round the map's rectangle with this material:
//
//   * THE PAPER: the map's own tint per pixel at WORLD coordinates (the formula of shaders/map_paper.gdshader, buildGround's
//     n = fbm(wx*.008, wy*.008, 11, 4), m = fbm(wx*.0025, wy*.0025, 23, 3)), rounded to 8 bits as the chunks round it, so the
//     paper runs on past the edge with no seam, then the grain tile multiplied at the map's strength (shaders/grain.gdshader's
//     mix(1, g, s)), in phase with the chunks' own grain (the tile is chunk_px square and the chunks sit on multiples of it).
//     `paper` is a colour in 0..255: the map's paper, or (option D) the table's, a step off it.
//   * THE EDGE (edge_on): the map's rectangle in MAP px; the fill is opaque outside it and transparent inside, so it hides the
//     last chunk's 120 m that stick out past the 5,000 m bounds (the map's chunks and the fog's topographic ones are whole 512 m
//     and 256 m squares) and shows the map through where the rectangles reach in under an ink line. The cover and the lines use
//     the distance to the rectangle in SCREEN px (map px x zoom), pushed INWARD only by a world-anchored hand wobble, so the map
//     past the edge is never revealed. Rounded at the corners (the distance to the nearest point of the rectangle).
//   * A heavy line on the edge, a fine rule `rule2_gap` px outside it (option A's doubled rule, C's thin line: rule2_px 0 is none).
//   * A HATCH BAND (hatch_on, option A): ink lines perpendicular to the edge, `hatch_spacing` px apart along it, each its own
//     length between hatch_min and 100% of hatch_depth, tapering at the far end, clipped to `band_px` (the band's depth in screen
//     px). At a corner the lines fan out from it, thinned toward the corner by halves (a line exists only past the radius at which
//     its neighbours are `hatch_spacing` apart), so the corner is not a solid wedge. The fog's own edge (fog_composite.gdshader)
//     is the model: the same line coverage and world-anchored noise, in screen px so a line keeps its width at every zoom.
//
// All colours arrive resolved from palette roles (working rule 6); nothing here is a hex.

shader_type canvas_item;
render_mode unshaded;

#include "res://scripts/render/shaders/noise.gdshaderinc"

uniform vec3 paper = vec3(217.0, 204.0, 170.0);
uniform sampler2D grain : filter_linear_mipmap, repeat_enable, hint_default_white;
uniform float grain_strength = 0.55;
uniform float grain_tile = 1024.0;

uniform bool edge_on = true;
uniform vec4 map_rect = vec4(0.0, 0.0, 10000.0, 10000.0);   // x0, y0, x1, y1, MAP px
uniform float zoom = 1.0;                                   // screen px per map px

uniform vec4 line_color = vec4(0.0);
uniform float line_px = 0.0;
uniform float wobble_px = 0.0;
uniform float wobble_freq = 0.02;
uniform vec4 rule2_color = vec4(0.0);
uniform float rule2_px = 0.0;
uniform float rule2_gap = 4.5;

uniform bool hatch_on = false;
uniform vec4 hatch_color = vec4(0.0);
uniform float hatch_spacing = 3.0;
uniform float hatch_width = 1.1;
uniform float hatch_depth = 56.0;
uniform float hatch_min = 0.45;
uniform float hatch_jitter = 0.3;
uniform float hatch_taper = 0.5;
uniform float hatch_start = 4.5;
uniform float band_px = 200.0;

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

// Coverage of a line `width` px wide at distance d px from its centre: a 1 px box filter, and below 1 px the hairline rule the
// drawing layer uses (one pixel wide, alpha x width).
float line_cov(float d, float width) {
	float w = max(width, 1.0);
	return clamp(w * 0.5 + 0.5 - abs(d), 0.0, 1.0) * min(width, 1.0);
}

vec4 over(vec4 top, vec4 bot) {
	float a = top.a + bot.a * (1.0 - top.a);
	vec3 rgb = a > 0.0 ? (top.rgb * top.a + bot.rgb * bot.a * (1.0 - top.a)) / a : vec3(0.0);
	return vec4(rgb, a);
}

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// the paper, as map_paper.gdshader
	vec2 p = world - vec2(1.5);
	float n = ink_fbm(p.x * 0.008, p.y * 0.008, 11, 4);
	float m = ink_fbm(p.x * 0.0025, p.y * 0.0025, 23, 3);
	float k = 0.93 + 0.11 * n;
	vec3 c = vec3(paper.r * k + (m - 0.5) * 14.0, paper.g * k + (m - 0.5) * 8.0, paper.b * k - (m - 0.5) * 8.0);
	c = floor(clamp(c, 0.0, 255.0) + 0.5) / 255.0;
	vec4 col = vec4(c, 1.0);

	if (edge_on) {
		vec2 q = max(map_rect.xy - world, world - map_rect.zw);                 // per axis, > 0 outside
		vec2 qo = max(q, vec2(0.0));
		float sd = (qo.x > 0.0 || qo.y > 0.0) ? length(qo) : max(q.x, q.y);       // signed distance to the rectangle, map px
		float e = sd * zoom + vnoise(world * wobble_freq) * wobble_px;           // SCREEN px, pushed inward only
		col.a = clamp(e + 0.5, 0.0, 1.0);
		float l1 = line_cov(e, line_px) * line_color.a;
		float l2 = line_cov(e - rule2_gap, rule2_px) * rule2_color.a;
		float hat = 0.0;
		if (hatch_on && e > hatch_start - 1.0) {
			float he = e - hatch_start;
			float tc;
			float rmin = 0.0;
			float unit = hatch_spacing;
			if (qo.x > 0.0 && qo.y > 0.0) {
				float refr = max(hatch_depth * 0.8, 8.0);
				tc = atan(qo.y, qo.x) * refr;
				float idx0 = floor(tc / unit);
				int ii = int(idx0);
				int low = ii & (-ii);
				rmin = ii == 0 ? 0.0 : refr / float(low);
			} else if (qo.x > 0.0) {
				tc = world.y * zoom;
			} else {
				tc = world.x * zoom;
			}
			float idx = floor(tc / unit);
			float jit = (hash12(vec2(idx, 3.0)) - 0.5) * 2.0 * hatch_jitter * unit;
			float across = tc - (idx + 0.5) * unit - jit;
			float reach = hatch_depth * (hatch_min + (1.0 - hatch_min) * hash12(vec2(idx, 7.0)));
			float taper = mix(1.0, hatch_taper, clamp(he / max(reach, 1.0), 0.0, 1.0));
			float len_fade = 1.0 - smoothstep(reach - 3.0, reach, he);
			float band_fade = 1.0 - smoothstep(band_px - 2.0, band_px, e);
			float radial_ok = rmin > 0.0 ? smoothstep(rmin - 1.0, rmin + 1.0, sd * zoom) : 1.0;
			hat = line_cov(across, hatch_width) * len_fade * band_fade * taper * radial_ok * smoothstep(-0.5, 0.5, he) * hatch_color.a;
		}
		col = over(vec4(rule2_color.rgb, l2), col);
		col = over(vec4(hatch_color.rgb, hat), col);
		col = over(vec4(line_color.rgb, l1), col);
	}
	// the grain multiplies everything, ink included, as it does over the finished map
	col.rgb *= mix(vec3(1.0), texture(grain, world / grain_tile).rgb, grain_strength);
	COLOR = col;
}
