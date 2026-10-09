extends RefCounted

# The prototype's paper-grain overlay (reference/inkwood-renderer.html):
#
#   function buildGrain(){ ... for(let i=0;i<d.length;i+=4){
#       let v=255-Math.random()*24; if(Math.random()<.004) v=150+Math.random()*60;
#       d[i]=v; d[i+1]=v-2; d[i+2]=v-6; d[i+3]=255; } ... }
#   // render():
#   ctx.globalCompositeOperation="multiply"; ctx.globalAlpha=P.grain; ctx.drawImage(grainC,0,0);
#
# A near-white, faintly warm per-pixel texture with 0.4% darker flecks,
# MULTIPLIED over the finished frame at strength s: out = frame * mix(1, grain, s)
# (shaders/grain.gdshader says why that is the Canvas formula and why Godot's
# MUL blend with a modulate alpha is not).
#
# SEEDED, where the prototype is not: it draws from Math.random(), so the
# browser's grain differs on every load and can never be matched pixel for
# pixel. Here it comes from Mulberry32 in the prototype's draw order (two draws
# a pixel, a third for a fleck), so a seed gives the same grain every time.
#
#   var grain := Grain.build_texture(Vector2i(W, H), seed)   // once per frame size
#   Grain.apply(frame, grain, strength)                      // last, over everything

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const GRAIN_SHADER = preload("res://scripts/render/shaders/grain.gdshader")

static func build_image(size: Vector2i, seed_value: int) -> Image:
	var rng := Mulberry32.new(seed_value)
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	var i := 0
	for _p in size.x * size.y:
		var v := 255.0 - rng.next() * 24.0
		if rng.next() < 0.004:
			v = 150.0 + rng.next() * 60.0
		data[i] = u8(v)
		data[i + 1] = u8(v - 2.0)
		data[i + 2] = u8(v - 6.0)
		data[i + 3] = 255
		i += 4
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)

static func build_texture(size: Vector2i, seed_value: int) -> ImageTexture:
	return ImageTexture.create_from_image(build_image(size, seed_value))

# Multiplies `grain` over all of `onto` at `strength`, 1:1 from the origin,
# whatever transform or alpha `onto` currently has (the prototype resets both).
static func apply(onto: InkCanvas, grain: Texture2D, strength: float) -> void:
	if strength <= 0.0:
		return
	var mat := ShaderMaterial.new()
	mat.shader = GRAIN_SHADER
	mat.set_shader_parameter("strength", strength)
	onto.save()
	onto.reset_transform()
	onto.global_alpha = 1.0
	onto.draw_image_with_material(grain, 0.0, 0.0, float(grain.get_width()), float(grain.get_height()), mat)
	onto.restore()

# A Uint8ClampedArray store: clamp to 0..255, round half to EVEN (ToUint8Clamp).
static func u8(v: float) -> int:
	if v <= 0.0:
		return 0
	if v >= 255.0:
		return 255
	var f := floorf(v)
	var d := v - f
	if d > 0.5 or (d == 0.5 and fmod(f, 2.0) == 1.0):
		f += 1.0
	return int(f)
