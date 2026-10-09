// The prototype's paper tint, per pixel of the 1/S-resolution image
// (reference/inkwood-renderer.html, buildGround):
//
//   const wx=x*S,wy=y*S, n=fbm(wx*.008,wy*.008,11,4), m=fbm(wx*.0025,wy*.0025,23,3), k=.93+.11*n;
//   d[i]=PAPER[0]*k+(m-.5)*14; d[i+1]=PAPER[1]*k+(m-.5)*8; d[i+2]=PAPER[2]*k-(m-.5)*8; d[i+3]=255;
//
// The GPU path of scripts/render/paper.gd (build_shader): drawn once over the
// small image (`cells` pixels, set by paper.gd along with `scale`), read back
// and upscaled exactly like the GDScript path. Noise from noise.gdshaderinc:
// exact lattice, fp32 interpolation (see there). This is the measurement
// vehicle for the GDScript-vs-shader timing; the ground port picks one.
//
// ROUNDED HERE, NOT BY THE STORE: the prototype stores each channel through a
// Uint8ClampedArray (round to nearest). The GPU's float-to-8-bit store does
// not round to nearest -- measured 2026-10-09 (RTX 3080): values up to .55
// above a half went DOWN, 3.5% of samples one step low. Emitting an exact
// k/255 makes the store exact: 1 of 103,148 samples then differs from the
// GDScript path (a value 3e-6 from a half, i.e. fp32 noise).
shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://scripts/render/shaders/noise.gdshaderinc"

uniform vec2 cells = vec2(428.0, 241.0);
uniform float scale = 3.0;
uniform vec3 paper = vec3(217.0, 204.0, 170.0);  // the prototype's PAPER, in 0..255

void fragment() {
	vec2 px = floor(UV * cells);
	float wx = px.x * scale;
	float wy = px.y * scale;
	float n = ink_fbm(wx * 0.008, wy * 0.008, 11, 4);
	float m = ink_fbm(wx * 0.0025, wy * 0.0025, 23, 3);
	float k = 0.93 + 0.11 * n;
	vec3 c = vec3(paper.r * k + (m - 0.5) * 14.0, paper.g * k + (m - 0.5) * 8.0, paper.b * k - (m - 0.5) * 8.0);
	COLOR = vec4(floor(clamp(c, 0.0, 255.0) + 0.5) / 255.0, 1.0);
}
