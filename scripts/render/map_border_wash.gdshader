// THE SEA PAST THE MAP'S EDGE, option C (builder, map-border board, 2026-10-11; PROPOSED). One quad over the ring round the map:
// its mask texture holds the water's depth `s` in metres (the generator's s_at, sampled on a coarse grid and mapped to 0..1 over
// s_lo .. s_lo + s_range; bilinear, so the depth steps are smooth lines), and this paints each of the water's three depth steps in
// its own colour at the fog's quiet strength (the same eased washes the contour map shows the sea in, topo.water.quiet), nothing on
// land (s <= 0) and nothing inside the map. It fades to blank paper between `fade_from` and `fade_to` map px from the map's rectangle,
// as the contours do. The step colours are roles: the water palette's own (data/world/water.json), resolved by water_draw.gd.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D mask : filter_linear, repeat_disable, hint_default_black;
uniform vec4 area = vec4(0.0);                                 // the mask's origin x, y and size w, h, MAP px
uniform vec4 map_rect = vec4(0.0, 0.0, 10000.0, 10000.0);
uniform vec4 step0 = vec4(0.0);                                // shallows: rgb and alpha
uniform vec4 step1 = vec4(0.0);                                // shelf
uniform vec4 step2 = vec4(0.0);                                // deep
uniform vec3 thresholds = vec3(0.0, 6.0, 18.0);                // where each step begins, metres of depth
uniform float s_lo = -8.0;
uniform float s_range = 56.0;
uniform float fade_from = 1400.0;
uniform float fade_to = 2200.0;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 uv = (world - area.xy) / area.zw;
	float s = texture(mask, uv).r * s_range + s_lo;
	vec2 q = max(max(map_rect.xy - world, world - map_rect.zw), vec2(0.0));
	float d = length(q);
	float outside = step(0.001, d);
	vec4 c = s >= thresholds.z ? step2 : (s >= thresholds.y ? step1 : step0);
	float shore = smoothstep(0.0, 0.8, s);
	float fade = 1.0 - smoothstep(fade_from, fade_to, d);
	COLOR = vec4(c.rgb, c.a * shore * fade * outside);
}
