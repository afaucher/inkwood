// The prototype's paper tint (reference/inkwood-renderer.html, buildGround) for
// a CHUNK of a larger map, evaluated per pixel at its WORLD position so that
// neighbouring chunks continue each other's tint with no seam:
//
//   n=fbm(wx*.008,wy*.008,11,4), m=fbm(wx*.0025,wy*.0025,23,3), k=.93+.11*n;
//   r=PAPER[0]*k+(m-.5)*14; g=PAPER[1]*k+(m-.5)*8; b=PAPER[2]*k-(m-.5)*8;
//
// Drawn as one quad of a 1x1 texture whose SOURCE rectangle is the chunk's
// rectangle in WORLD px (InkCanvas.draw_image_region_with_material), so UV IS
// the world position (InkCanvas stores image quads in device space, so VERTEX
// would not be). The prototype evaluates the tint on a
// 1/3-resolution grid and upscales it; small pixel k is the sample at world
// 3k, displayed centred on 3k + 1.5 (scripts/render/paper.gd). Evaluating the
// same function per pixel at world - 1.5 is that upscale without the grid,
// within a level of it everywhere (the tint's features are ~100 px across),
// and has no grid to misalign at a chunk border. fp32 noise, exact lattice
// (noise.gdshaderinc). Opaque: the paper is the bottom layer.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://scripts/render/shaders/noise.gdshaderinc"

uniform vec3 paper = vec3(217.0, 204.0, 170.0);  // P.PAPER in 0..255, set from data by the provider

void fragment() {
	vec2 p = UV - vec2(1.5);
	float n = ink_fbm(p.x * 0.008, p.y * 0.008, 11, 4);
	float m = ink_fbm(p.x * 0.0025, p.y * 0.0025, 23, 3);
	float k = 0.93 + 0.11 * n;
	vec3 c = vec3(paper.r * k + (m - 0.5) * 14.0, paper.g * k + (m - 0.5) * 8.0, paper.b * k - (m - 0.5) * 8.0);
	COLOR = vec4(floor(clamp(c, 0.0, 255.0) + 0.5) / 255.0, 1.0);
}
