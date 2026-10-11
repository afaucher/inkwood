// THE WATER'S WASH FOR ONE MAP CHUNK (Track WB, 2026-10-10; scripts/render/water_draw.gd draw_chunk_wash).
//
// Two masks of the chunk's size carry the water: the sea's and the river's. Each holds the DEPTH STEP as a grey level on
// black: dry 0, the shallows 1/3, the shelf 2/3, the deep 1 (water_draw.gd chunk_masks paints the rings, largest first,
// each in the level of the water inside it, so the levels nest and an island or a shallow is a hole that shows the
// level round it). A pixel takes the deeper of the two. Between two levels the mask is an antialiased blend, which
// reads as the blend of the two step colours, so the wash's edges are as smooth as the masks' (the ink line lies on them).
//
// The wash is a wash on paper: the step's colour is multiplied by the paper's own tint at the pixel, relative to the
// paper's mean (the paper shader's low-frequency mottle, evaluated at the WORLD position as map_paper.gdshader does, so
// two chunks continue each other's mottle). `up` is the level-1-or-more mask of the terrain: an upland is never water.
// Premultiplied output, over the ground and under the level fill.
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;

#include "res://scripts/render/shaders/noise.gdshaderinc"

uniform sampler2D sea : filter_linear;
uniform sampler2D river : filter_linear;
uniform sampler2D up : filter_nearest;
uniform vec3 c0;                         // the three step colours, sRGB 0..1
uniform vec3 c1;
uniform vec3 c2;
uniform vec3 paper = vec3(217.0, 204.0, 170.0);  // P.PAPER in 0..255, as the paper shader's
uniform vec2 origin;                     // the chunk's rectangle in world px
uniform vec2 extent;
uniform float alpha = 1.0;
uniform float mottle = 0.85;

void fragment() {
	float v = max(texture(sea, UV).r, texture(river, UV).r) * 3.0;
	float u = texture(up, UV).r;
	float cov = clamp(v, 0.0, 1.0) * (1.0 - u) * alpha;
	vec3 col = mix(c0, c1, clamp(v - 1.0, 0.0, 1.0));
	col = mix(col, c2, clamp(v - 2.0, 0.0, 1.0));
	vec2 p = origin + UV * extent - vec2(1.5);
	float n = ink_fbm(p.x * 0.008, p.y * 0.008, 11, 4);
	float m = ink_fbm(p.x * 0.0025, p.y * 0.0025, 23, 3);
	float k = 0.93 + 0.11 * n;
	vec3 tint = vec3(paper.r * k + (m - 0.5) * 14.0, paper.g * k + (m - 0.5) * 8.0, paper.b * k - (m - 0.5) * 8.0);
	float ratio = dot(tint, vec3(0.299, 0.587, 0.114)) / dot(paper, vec3(0.299, 0.587, 0.114));
	col *= mix(1.0, ratio, mottle);
	COLOR = vec4(col * cov, cov);
}
