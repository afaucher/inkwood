extends RefCounted

# Builds a frame-sized image from a per-pixel function evaluated at 1/S
# resolution and upscaled smoothly -- how the prototype makes its paper tint
# (reference/inkwood-renderer.html, buildGround):
#
#   const S=3, lw=Math.ceil(W/S)+1, lh=Math.ceil(H/S)+1, small=document.createElement("canvas");
#   for(let y=0;y<lh;y++)for(let x=0;x<lw;x++){ const wx=x*S,wy=y*S, ... d[i]=...; }
#   sg.putImageData(img,0,0); g.imageSmoothingEnabled=true; g.imageSmoothingQuality="high";
#   g.drawImage(small,0,0,lw*S,lh*S);
#
# The small image is one pixel larger than W/S each way and is drawn at
# lw*S x lh*S from the origin, so the frame shows its top-left W x H. Small
# pixel (x, y) is the sample at world (x*S, y*S) and lands, upscaled, centred
# on world (x*S + S/2, y*S + S/2) -- the prototype's own half-cell shift, kept.
#
# UPSCALE: bilinear, pixel-centre aligned (Image.resize INTERPOLATE_BILINEAR,
# which maps centres and weights in 1/256 steps). Chrome's
# imageSmoothingQuality "high" upscales with a bicubic (Mitchell) filter
# instead; over a tint whose features are ~100 px across, the two differ by
# well under one 8-bit step except right at the frame edge.
#
# TWO WAYS TO EVALUATE THE PIXELS:
#   build(size, S, pixel)                 GDScript: pixel.call(wx, wy) -> Vector3,
#                                          channels in 0..255 like ImageData,
#                                          stored as a Uint8ClampedArray would.
#                                          Works headless (no rendering involved).
#   build_shader(size, S, material)       a canvas_item shader computes each pixel
#                                          on the GPU (shaders/paper_tint.gdshader,
#                                          noise from noise.gdshaderinc). Needs a
#                                          WINDOWED run. paper.gd sets its `cells`
#                                          (small size) and `scale` uniforms.
# Measured 2026-10-09, 1280x720 at S = 3 (428 x 241 = 103,148 samples), two
# runs each, RTX 3080: GDScript with a trivial callable 73 ms; GDScript with the
# real ground (fbm(wx*.008, wy*.008, 11, 4) and fbm(wx*.0025, wy*.0025, 23, 3)
# per sample, scripts/core/noise.gd) 2.21 s; the shader 13 ms (19 ms the first
# time, compile included). The two agree on 921,582 of 921,600 frame pixels;
# the other 18 are one 8-bit step apart (fp32 noise landing on a half).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Grain = preload("res://scripts/render/grain.gd")

static func small_size(size: Vector2i, scale: int) -> Vector2i:
	return Vector2i(ceili(float(size.x) / float(scale)) + 1, ceili(float(size.y) / float(scale)) + 1)

static func build(size: Vector2i, scale: int, pixel: Callable) -> ImageTexture:
	return ImageTexture.create_from_image(build_image(size, scale, pixel))

static func build_image(size: Vector2i, scale: int, pixel: Callable) -> Image:
	var small := small_size(size, scale)
	var data := PackedByteArray()
	data.resize(small.x * small.y * 4)
	var i := 0
	for y in small.y:
		for x in small.x:
			var c: Vector3 = pixel.call(float(x * scale), float(y * scale))
			data[i] = Grain.u8(c.x)
			data[i + 1] = Grain.u8(c.y)
			data[i + 2] = Grain.u8(c.z)
			data[i + 3] = 255
			i += 4
	return upscale(Image.create_from_data(small.x, small.y, false, Image.FORMAT_RGBA8, data), size, scale)

static func build_shader(size: Vector2i, scale: int, material: ShaderMaterial) -> ImageTexture:
	return ImageTexture.create_from_image(build_image_shader(size, scale, material))

static func build_image_shader(size: Vector2i, scale: int, material: ShaderMaterial) -> Image:
	var small := small_size(size, scale)
	material.set_shader_parameter("cells", Vector2(small))
	material.set_shader_parameter("scale", float(scale))
	var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	var quad := ImageTexture.create_from_image(white)
	var img := InkCanvas.render_to_image(small, func(g: InkCanvas) -> void:
		g.draw_image_with_material(quad, 0.0, 0.0, float(small.x), float(small.y), material), 1)
	return upscale(img, size, scale)

# drawImage(small, 0, 0, lw*S, lh*S), then the frame's W x H from the origin.
static func upscale(small: Image, size: Vector2i, scale: int) -> Image:
	small.resize(small.get_width() * scale, small.get_height() * scale, Image.INTERPOLATE_BILINEAR)
	return small.get_region(Rect2i(Vector2i.ZERO, size))
