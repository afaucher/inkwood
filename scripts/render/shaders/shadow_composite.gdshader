// The last two steps of the prototype's castShadows (reference/inkwood-renderer.html):
//
//   m.globalCompositeOperation = "source-in"; m.fillStyle = P.shadowCol; m.fillRect(...)  // tint, keep mask alpha
//   ctx.globalAlpha = P.shadowStr; ctx.drawImage(mask, 0, 0)                            // composite once
//
// in one draw: the colour is the tint, the alpha is the mask's alpha times the
// strength. Every silhouette was merged into that one alpha channel first, so
// where two shadows overlap they are tinted ONCE and never darken twice.
// Drawn 1:1 over the frame by scripts/render/shadow_pass.gd (blend: mix).
shader_type canvas_item;
render_mode unshaded;

uniform vec3 tint = vec3(0.239216, 0.423529, 0.560784);  // #3D6C8F, steel
uniform float strength = 0.92;

void fragment() {
	COLOR = vec4(tint, texture(TEXTURE, UV).a * strength);
}
