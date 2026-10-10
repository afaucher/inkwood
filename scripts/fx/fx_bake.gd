extends RefCounted

# Small helpers every effect baker shares: whether a bake can happen at all, the
# drawing layer's premultiplied images turned straight for Sprite2D / draw_texture,
# and one place that renders a batch of InkCanvases in ONE engine frame.
#
# HEADLESS: the dummy renderer produces no image, so can_bake() is false and the
# bakers return null; the effect layer's state (puffs, timings) still runs.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

static func can_bake() -> bool:
	return DisplayServer.get_name() != "headless"

# Renders the canvases in one frame; each returned Image is RGBA8, premultiplied
# (null where the renderer gave nothing).
static func render(canvases: Array) -> Array:
	var out: Array = []
	if canvases.is_empty():
		return out
	var imgs: Array[Image] = InkCanvas.render_all(canvases)
	for img in imgs:
		out.append(null if (img == null or img.is_empty()) else img)
	return out

# InkCanvas images are PREMULTIPLIED; a Sprite2D wants straight alpha. A mask
# keeps only its coverage (white).
static func straight(img: Image, white: bool) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		var a := data[i + 3]
		if a == 0:
			continue
		if white:
			data[i] = 255
			data[i + 1] = 255
			data[i + 2] = 255
		elif a < 255:
			data[i] = mini(255, roundi(data[i] * 255.0 / a))
			data[i + 1] = mini(255, roundi(data[i + 1] * 255.0 / a))
			data[i + 2] = mini(255, roundi(data[i + 2] * 255.0 / a))
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)

static func texture(img: Variant, white: bool = false) -> Texture2D:
	if img == null:
		return null
	return ImageTexture.create_from_image(straight(img as Image, white))

# A stable 31-bit seed from numbers and strings (Godot's String.hash is stable
# for a given build; the engine is pinned).
static func seed_of(a: Variant, b: Variant = 0, c: Variant = 0) -> int:
	var h: int = (str(a) + "|" + str(b) + "|" + str(c)).hash()
	return h & 0x7FFFFFFF
