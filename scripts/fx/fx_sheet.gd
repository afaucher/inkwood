extends RefCounted

# A board sheet built from Godot nodes and saved as a PNG (the variant boards' chrome:
# a dark ground, light labels, framed images). A tool's chrome, not game art: the
# colours here are the board's own and nothing in the game reads them.
#
#   var sh := FxSheet.new(root, Vector2i(1900, 1400))
#   sh.label("Title", Vector2(16, 12), 22, true)
#   sh.image(img, Vector2(16, 60), 1.0)
#   await sh.save("res://variants/x/board.png", tree)
#
# Text is drawn with a system sans (Segoe UI first, as the earlier boards).

const BG := Color(0.137, 0.129, 0.114)
const FG := Color(0.93, 0.91, 0.86)
const DIM := Color(0.72, 0.69, 0.62)
const FRAME := Color(0.30, 0.28, 0.24)

var vp: SubViewport
var holder: Control
var size: Vector2i
var _font: SystemFont
var _bold: SystemFont

func _init(parent: Node, sheet_size: Vector2i) -> void:
	size = sheet_size
	vp = SubViewport.new()
	vp.size = size
	vp.disable_3d = true
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(vp)
	holder = Control.new()
	holder.size = Vector2(size)
	vp.add_child(holder)
	var bg := ColorRect.new()
	bg.color = BG
	bg.size = Vector2(size)
	holder.add_child(bg)
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Segoe UI", "Arial", "Helvetica", "sans-serif"])
	_bold = SystemFont.new()
	_bold.font_names = _font.font_names
	_bold.font_weight = 700

func label(text: String, pos: Vector2, px: int = 14, bold: bool = false, color: Color = FG, width: float = -1.0) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.add_theme_font_override("font", _bold if bold else _font)
	l.add_theme_font_size_override("font_size", px)
	l.add_theme_color_override("font_color", color)
	if width > 0.0:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size = Vector2(width, 0)
	holder.add_child(l)
	if width > 0.0:
		l.size = Vector2(width, l.get_minimum_size().y)
	return l

func rect(pos: Vector2, sz: Vector2, color: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.position = pos
	r.size = sz
	holder.add_child(r)
	return r

# An image at `pos`, scaled (linear when shrunk), with a thin frame round it.
func image(img: Image, pos: Vector2, scale: float = 1.0, framed: bool = true) -> TextureRect:
	if framed:
		rect(pos - Vector2.ONE, Vector2(img.get_size()) * scale + Vector2(2, 2), FRAME)
	var tr := TextureRect.new()
	tr.texture = ImageTexture.create_from_image(img)
	tr.position = pos
	tr.size = Vector2(img.get_size()) * scale
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS if scale < 1.0 else CanvasItem.TEXTURE_FILTER_NEAREST
	holder.add_child(tr)
	return tr

func swatch(pos: Vector2, sz: Vector2, color: Color) -> void:
	rect(pos - Vector2.ONE, sz + Vector2(2, 2), FRAME)
	rect(pos, sz, color)

# Renders and saves. Returns the Image.
func save(path: String, tree: SceneTree) -> Image:
	for i in 4:
		await tree.process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err := img.save_png(path)
	if err != OK:
		printerr("[fx-sheet] could not write ", path, ": ", error_string(err))
	else:
		print("[fx-sheet] saved ", path, " ", img.get_size())
	return img

func free_sheet() -> void:
	vp.queue_free()
