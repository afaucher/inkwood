extends "res://scripts/test_support/test_case.gd"

# The build stamp in the corner of the screen. Small, and worth a gate anyway:
# it is the only thing that tells us which binary a playtest report is about, so
# it failing SILENTLY -- a blank corner, or worse, a confident wrong number --
# costs a round trip on every report until someone notices.
#
# resolve() takes what it needs as arguments precisely so the awkward cases can
# be asserted without standing up a filesystem: no file, an empty file, a file
# with a byte-order mark, and an editor run.

const BuildVersion = preload("res://scripts/ui/build_version.gd")

func setup(_main) -> void:
	# An exported build with a real stamp shows exactly that stamp and nothing
	# else -- this is the string that ends up in a bug report.
	eq(BuildVersion.resolve(true, "2026-08-08.143012", false), "2026-08-08.143012",
		"an exported build shows its stamp verbatim")

	# build.ps1 writes it with Set-Content, which appends a line ending.
	eq(BuildVersion.resolve(true, "2026-08-08.143012\r\n", false), "2026-08-08.143012",
		"the trailing newline Set-Content leaves is stripped")

	# A BOM is not whitespace, so strip_edges() alone leaves it, and it renders as
	# a stray box glyph in front of the version. CLAUDE.md records what a BOM in a
	# .tscn cost; this is the same trap for the price of one trim_prefix.
	var bom := String.chr(0xFEFF)
	eq(BuildVersion.resolve(true, bom + "2026-08-08.143012\n", false),
		"2026-08-08.143012", "a byte-order mark does not reach the label")

	# Never blank. A corner with nothing in it is indistinguishable from a label
	# that failed to build, which is the one thing this must not look like.
	eq(BuildVersion.resolve(false, "", false), BuildVersion.UNKNOWN,
		"a build with no version.txt says so rather than showing nothing")
	eq(BuildVersion.resolve(true, "   \n", false), BuildVersion.UNKNOWN,
		"and so does an empty one")

	# THE CASE THAT MATTERS MOST. version.txt is written to the project root and
	# never cleaned up, so every editor run after a local build finds a genuine
	# timestamp sitting there. Without this, a dev run would present the last
	# export's stamp as its own -- a confidently wrong version in a bug report is
	# worse than an absent one, because nobody thinks to doubt it.
	var dev := BuildVersion.resolve(true, "2026-08-08.143012", true)
	check(dev.contains("dev"), "an editor run is labelled dev, whatever version.txt says (%s)" % dev)
	check(dev != "2026-08-08.143012", "and never passes a stale stamp off as its own")

	# The label itself builds, sits bottom-left, and cannot swallow a click meant
	# for the menu button above it.
	var label: Label = BuildVersion.make_label()
	check(label.text != "", "the label carries a version string")
	eq(label.mouse_filter, Control.MOUSE_FILTER_IGNORE, "and never eats a click")
	check(label.offset_left > 0.0 and label.offset_bottom < 0.0,
		"anchored to the bottom-left corner")
	label.free()

	finish()
