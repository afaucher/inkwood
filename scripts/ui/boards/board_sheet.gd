extends RefCounted

# A variant board's sheet, composed in Godot (Track U1): a dark page of
# captioned crops of the real game's frames, the way the other boards in
# variants/ look (title, subtitle, one labelled row or cell per option, a
# palette strip). The page's own colours are derived from the palette roles
# (the ink darkened for the page, the paper for the lettering): no hex here.
#
#   var sheet := BoardSheet.new(style, Vector2i(1480, 2300))
#   sheet.text(Vector2(20, 14), "Title", 22, sheet.c_text)
#   sheet.image(img, Vector2(20, 100), Rect2(60, 200, 500, 300))    # a crop at 1:1
#   await sheet.save(tree, "res://variants/<id>/board.png")
#
# Drawn through a SubViewport and a Node2D so the lettering is the game's own
# serif (the UI style's font list), not a fallback.

const UiStyle = preload("res://scripts/ui/ui_style.gd")

var size: Vector2i
var style: UiStyle
var c_page: Color
var c_text: Color
var c_muted: Color
var c_rule: Color
var c_chip_line: Color
var _ops: Array = []
var _textures: Dictionary = {}     # Image id -> ImageTexture

func _init(st: RefCounted, sheet_size: Vector2i) -> void:
	style = st as UiStyle
	size = sheet_size
	var ink: Color = style.palette["ink"]
	var paper: Color = style.palette["paper"]
	c_page = ink.darkened(0.55)
	c_text = style.palette["object_fill"]
	c_muted = Color(paper.r, paper.g, paper.b, 0.72)
	c_rule = Color(paper.r, paper.g, paper.b, 0.16)
	c_chip_line = Color(paper.r, paper.g, paper.b, 0.35)

# --- Drawing ops ----------------------------------------------------------------

func rect(r: Rect2, col: Color, filled: bool = true, width: float = 1.0) -> void:
	_ops.append({"op": "rect", "r": r, "col": col, "filled": filled, "w": width})

func line(a: Vector2, b: Vector2, col: Color, width: float = 1.0) -> void:
	_ops.append({"op": "line", "a": a, "b": b, "col": col, "w": width})

# `src` empty: the whole image. 1:1 unless `to_size` is given.
func image(img: Image, pos: Vector2, src: Rect2 = Rect2(), to_size: Vector2 = Vector2.ZERO) -> void:
	var key := img.get_instance_id()
	if not _textures.has(key):
		_textures[key] = ImageTexture.create_from_image(img)
	var s := src if src.has_area() else Rect2(Vector2.ZERO, Vector2(img.get_size()))
	_ops.append({"op": "image", "tex": _textures[key], "src": s, "dst": Rect2(pos, to_size if to_size != Vector2.ZERO else s.size)})

func text(pos: Vector2, s: String, px: float, col: Color, italic: bool = false, width: float = -1.0, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	_ops.append({"op": "text", "p": pos, "s": s, "px": px, "col": col, "it": italic, "w": width, "al": align})

# A word-wrapped paragraph; returns the height used.
func paragraph(pos: Vector2, s: String, px: float, col: Color, width: float, italic: bool = false, line_gap: float = 3.0) -> float:
	var f: Font = style.font(italic)
	var lines := PackedStringArray()
	var cur := ""
	for word: String in s.split(" ", false):
		var trial := word if cur == "" else cur + " " + word
		if f.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(px))).x > width and cur != "":
			lines.append(cur)
			cur = word
		else:
			cur = trial
	if cur != "":
		lines.append(cur)
	var y := 0.0
	for l: String in lines:
		text(pos + Vector2(0.0, y + px), l, px, col, italic)
		y += px + line_gap
	return y

# A colour chip with its role name and measured OKLCH beneath it.
func chip(pos: Vector2, col: Color, label: String, sub: String, chip_size: Vector2 = Vector2(86, 40)) -> void:
	rect(Rect2(pos, chip_size), Color(col.r, col.g, col.b, 1.0))
	if col.a < 0.999:
		# Alpha shown as a diagonal half: the colour at its alpha over the page.
		rect(Rect2(pos + Vector2(chip_size.x * 0.5, 0.0), Vector2(chip_size.x * 0.5, chip_size.y)), col)
	rect(Rect2(pos, chip_size), c_chip_line, false, 1.0)
	text(pos + Vector2(0.0, chip_size.y + 14.0), label, 12.0, c_text)
	text(pos + Vector2(0.0, chip_size.y + 28.0), sub, 11.0, c_muted)

# --- Colour science (the palette doc's measure) --------------------------------------

# sRGB Color -> Vector3(L, C, h in degrees), OKLCH.
static func oklch(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l_ := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m_ := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s_ := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	var L := 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
	var A := 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
	var B := 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
	var h := rad_to_deg(atan2(B, A))
	if h < 0.0:
		h += 360.0
	return Vector3(L, sqrt(A * A + B * B), h)

# sRGB Color -> Vector3(L, a, b), OKLab: the space distances are measured in.
static func oklab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var bl := _lin(c.b)
	var l_ := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl, 1.0 / 3.0)
	var m_ := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl, 1.0 / 3.0)
	var s_ := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl, 1.0 / 3.0)
	return Vector3(0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
		1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
		0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)

# The distance between two colours in OKLab (about 0.02 is just noticeable, 0.1 plainly different).
static func delta_ok(c1: Color, c2: Color) -> float:
	return oklab(c1).distance_to(oklab(c2))

# `fg` at its own alpha laid over `bg` (opaque result).
static func over(fg: Color, bg: Color) -> Color:
	return Color(bg.r + (fg.r - bg.r) * fg.a, bg.g + (fg.g - bg.g) * fg.a, bg.b + (fg.b - bg.b) * fg.a, 1.0)

static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func oklch_text(c: Color) -> String:
	var v := oklch(c)
	return "L %.3f  C %.3f  h %d" % [v.x, v.y, int(round(v.z))]

# --- Output --------------------------------------------------------------------------

# Renders the ops and writes the PNG (res:// or absolute path). Returns the Error.
func save(tree: SceneTree, path: String) -> int:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var canvas := _Canvas.new()
	canvas.sheet = self
	vp.add_child(canvas)
	tree.root.add_child(vp)
	for _i in 4:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	return img.save_png(abs_path)

class _Canvas extends Node2D:
	var sheet

	func _init() -> void:
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crops are copied pixel for pixel

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, Vector2(sheet.size)), sheet.c_page)
		for o: Dictionary in sheet._ops:
			match o["op"]:
				"rect":
					if o["filled"]:
						draw_rect(o["r"], o["col"])
					else:
						draw_rect(o["r"], o["col"], false, o["w"])
				"line":
					draw_line(o["a"], o["b"], o["col"], o["w"])
				"image":
					draw_texture_rect_region(o["tex"], o["dst"], o["src"])
				"text":
					var f: Font = sheet.style.font(o["it"])
					draw_string(f, o["p"], o["s"], o["al"], o["w"], int(round(o["px"])), o["col"])
