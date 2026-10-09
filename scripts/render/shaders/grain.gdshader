// The prototype's grain overlay, composited (reference/inkwood-renderer.html, render()):
//
//   ctx.globalCompositeOperation = "multiply"; ctx.globalAlpha = P.grain; ctx.drawImage(grainC, 0, 0);
//
// Canvas "multiply" at globalAlpha s over an opaque frame works out to
//   out = frame * (1 - s) + frame * grain * s  =  frame * mix(1, grain, s)
// so the shader emits mix(1, grain, s) and blend_mul multiplies it in
// (Godot's MUL blend: dst.rgb * src.rgb, dst.a * src.a). NOT BLEND_MODE_MUL with
// the strength in the modulate alpha: MUL ignores source alpha, so that would
// apply the grain at full strength. Drawn 1:1 by scripts/render/grain.gd.
shader_type canvas_item;
render_mode unshaded, blend_mul;

uniform float strength = 0.55;

void fragment() {
	vec3 g = texture(TEXTURE, UV).rgb;
	COLOR = vec4(mix(vec3(1.0), g, strength), 1.0);
}
