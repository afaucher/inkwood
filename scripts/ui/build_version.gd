extends RefCounted

# The build stamp in the bottom-left corner.
#
# WHY IT EXISTS: a playtest report is worth very little if nobody can tell which
# build produced it. "the balls feel too safe" against an unknown binary costs a
# round trip to establish what was even being played. The corner of the screen is
# the only place that information survives a screenshot.
#
# WHERE THE STRING COMES FROM: build.ps1 writes `version.txt` into the project
# root immediately BEFORE the export (build.ps1:222), so it is packed into the
# .pck and travels with the .exe. It is gitignored -- it is an output, not source,
# and committing it would make every build a diff.
#
# The resolution is a pure static function taking what it needs as arguments,
# because the interesting cases (missing file, stale file, a BOM) are exactly the
# ones that are awkward to stand up for real, and a corner label is not worth a
# fixture directory.

const UNKNOWN := "unversioned"

# `in_editor` is OS.has_feature("editor") -- true from the editor or a
# --headless source run, false only in an exported build.
#
# That distinction matters more than it looks. version.txt is written to the
# PROJECT ROOT and never cleaned up, so after one local build every subsequent
# editor run finds a real-looking timestamp sitting there and would happily
# present the last export's stamp as its own. A dev run must never be mistaken
# for a build in a bug report, so it is labelled as one regardless of what the
# file says.
static func resolve(exists: bool, raw: String, in_editor: bool) -> String:
	var stamp := UNKNOWN
	if exists:
		# strip_edges() handles whitespace and the trailing newline Set-Content
		# leaves. It does NOT handle a byte-order mark, which is not whitespace:
		# it would survive into the label as a stray box glyph. CLAUDE.md already
		# records what a BOM costs in a .tscn; this is the same trap, cheaper.
		# Written as a codepoint, not as a literal: a BOM pasted into source is an
		# invisible character that the next person to edit this line deletes by
		# accident and cannot see they have deleted.
		var text := raw.strip_edges().trim_prefix(String.chr(0xFEFF)).strip_edges()
		if text != "":
			stamp = text
	if in_editor:
		return "dev (%s)" % stamp
	return stamp

static func text() -> String:
	var exists := FileAccess.file_exists("res://version.txt")
	var raw := ""
	if exists:
		var f := FileAccess.open("res://version.txt", FileAccess.READ)
		# file_exists() and open() are two separate questions, and open() is the
		# one that can still fail.
		if f == null:
			exists = false
		else:
			raw = f.get_as_text()
	return resolve(exists, raw, OS.has_feature("editor"))

# Bottom-left, dim, and deliberately NOT part of the HUD: the HUD hides itself
# whenever there is no live world, and the menu -- where someone sits before
# reporting anything -- is precisely when the build stamp is most wanted.
static func make_label() -> Label:
	var label := Label.new()
	label.name = "BuildVersion"
	label.text = text()
	label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	label.offset_left = 10.0
	label.offset_top = -26.0
	label.offset_bottom = -6.0
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.62, 0.64, 0.70, 0.75))
	# It must never eat a click meant for the menu button above it.
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
