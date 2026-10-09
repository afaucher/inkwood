// LINE OF SIGHT, step 1 of the vision mask (Track F): one unit's viewshed drawn as
// a shape, white where the unit can see, nothing elsewhere. scripts/render/
// fog_layer.gd draws one full-viewport ColorRect with this shader per revealing
// unit that has a viewshed (fog_viewshed.gd), into the small transparent
// SubViewport "VisionShapes"; where shapes overlap the white just stays white,
// so the viewport holds the UNION of what the units see. Steps 2 and 3
// (fog_los_cols.gdshader, fog_mask_los.gdshader) turn that coverage into the
// clamped signed distance field the compositor reads, exactly as the circle
// shader (fog_mask.gdshader) does for plain circles.
//
// The viewshed arrives as a texture straight from the CPU: one column per ray
// (ray r points at r x dtheta radians from +x, y down, the world's frame),
// FogViewshed.RUN_ROWS rows, each texel (from0, to0, from1, to1) the metres
// along the ray at which a visible run starts and ends. A pixel is inside when
// the ray nearest its bearing has a run holding its distance from the eye: the
// same rule as FogViewshed.Shed.visible_ground, so the picture and the query
// agree.
//
// The pixel's place in the world comes from three uniforms (mask px -> metres:
// a pure affine map, built by the layer from the camera's canvas transform).

shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D runs : filter_nearest, repeat_disable;
uniform int rays = 629;
uniform float dtheta = 0.01;
uniform vec2 eye = vec2(0.0);
uniform float range_m = 800.0;
uniform vec2 ax = vec2(1.0, 0.0);   // metres per mask px along x
uniform vec2 ay = vec2(0.0, 1.0);   // metres per mask px along y
uniform vec2 base_m = vec2(0.0);     // metres at mask px (0, 0)

void fragment() {
	vec2 w = ax * FRAGCOORD.x + ay * FRAGCOORD.y + base_m;
	vec2 d = w - eye;
	float dist = length(d);
	if (dist > range_m) {
		discard;
	}
	float a = atan(d.y, d.x);
	if (a < 0.0) {
		a += 6.28318530718;
	}
	int r = int(floor(a / dtheta + 0.5));
	if (r >= rays) {
		r -= rays;
	}
	bool inside = false;
	for (int row = 0; row < 3; row++) {
		vec4 q = texelFetch(runs, ivec2(r, row), 0);
		if ((dist >= q.x && dist < q.y) || (dist >= q.z && dist < q.w)) {
			inside = true;
		}
	}
	if (!inside) {
		discard;
	}
	COLOR = vec4(1.0);
}
