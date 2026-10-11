// A BAKED CONTOUR TILE of option C (builder, map-border board, 2026-10-11; PROPOSED). The tile's texture holds the lines' coverage in
// its red channel (R8: the lines are recorded in white); this colours it with the contour ink role, at the role's alpha, and fades
// it to blank paper between `fade_from` and `fade_to` map px from the map's rectangle, so the ring of contours never ends in a hard
// square. The map's rectangle is in MAP px; the fade is by distance outside it. World position comes from the vertex stage, as
// fog_composite.gdshader's does.
shader_type canvas_item;
render_mode unshaded;

uniform vec4 ink = vec4(0.0);
uniform vec4 map_rect = vec4(0.0, 0.0, 10000.0, 10000.0);
uniform float fade_from = 1800.0;
uniform float fade_to = 3000.0;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	float cov = texture(TEXTURE, UV).r;
	vec2 q = max(max(map_rect.xy - world, world - map_rect.zw), vec2(0.0));
	float d = length(q);
	float fade = 1.0 - smoothstep(fade_from, fade_to, d);
	COLOR = vec4(ink.rgb, ink.a * cov * fade);
}
