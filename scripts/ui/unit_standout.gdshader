shader_type canvas_item;

// The shapes under an own unit's plane (scripts/ui/unit_standout.gd): a grown
// copy of the plane's silhouette (kind 0: the halo and the rim) or a soft pool
// of colour centred on the unit (kind 1: the paper lift). The colour comes from
// the draw call (draw_rect's colour, a palette role), only its alpha is shaped
// here, so no colour lives in this file.
//
// Coordinates are NODE-LOCAL px with the unit's centre at 0: the node carries
// the plane's own rotation and scale, so the texture is read in its own px and
// a radius given in screen px arrives divided by the sprite's scale.

uniform int kind = 0;
uniform sampler2D mask : filter_linear, repeat_disable;
uniform vec2 rect_min;     // the drawn rect's top-left, node-local
uniform vec2 rect_size;
uniform vec2 origin_px;    // the unit's centre in mask texture px
uniform vec2 tex_px;       // the mask texture's size
uniform float radius = 3.0;   // kind 0: full to here ...
uniform float soft = 0.0;     // ... and gone this much further out
uniform float inner = 10.0;   // kind 1: full to here ...
uniform float outer = 30.0;   // ... and gone here

void fragment() {
	vec2 p = rect_min + UV * rect_size;
	float cover = 0.0;
	if (kind == 0) {
		float reach = radius + soft;
		// Rings of taps from the pixel outwards; the weight is 1 inside `radius` and
		// falls to 0 at `reach`. 14 directions per ring, turned a little each ring so
		// the taps do not line up into spokes.
		for (int ri = 0; ri <= 6; ri++) {
			float rr = reach * float(ri) / 6.0;
			float w = 1.0 - smoothstep(radius, max(reach, radius + 0.001), rr);
			if (ri == 0) {
				cover = max(cover, texture(mask, (p + origin_px) / tex_px).a * w);
			} else {
				for (int a = 0; a < 14; a++) {
					float ang = (float(a) + 0.5 * float(ri)) * 6.2831853 / 14.0;
					vec2 q = p + vec2(cos(ang), sin(ang)) * rr + origin_px;
					cover = max(cover, texture(mask, q / tex_px).a * w);
				}
			}
		}
	} else {
		cover = 1.0 - smoothstep(inner, max(outer, inner + 0.001), length(p));
	}
	COLOR.a *= cover;
}
