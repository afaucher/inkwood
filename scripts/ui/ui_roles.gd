extends RefCounted

# A palette role defined INLINE in data, resolved without UiStyle's own table.
#
# data/ui/ui.json's top-level "roles" block is the UI's table (ui_style.gd loads
# it once). The variant switches of Track U1 (marker.standout, planner.cones)
# keep their colours beside their own parameters, so a board's option is one
# self-contained record; this resolves such a {base, shade?, toward?, t?, alpha?}
# the way UiStyle._resolve does: same keys, same 8-bit mixes, same palette.
# PROPOSED: UiStyle could expose its resolver as a public function and this file
# go away (a change in a file this track does not own, so it is not made here).
#
#   var c: Color = UiRoles.resolve(style, {"base": "paper", "alpha": 0.9}, "marker.standout.halo.role")
#
# A role that names a colour the palette does not have is an error, reported
# through the style (style.errors, pushed once) and answered with the loud
# placeholder, never a default.

const UiStyle = preload("res://scripts/ui/ui_style.gd")

# `where` names the data path, for the error message.
static func resolve(style: RefCounted, def: Variant, where: String) -> Color:
	if not (def is Dictionary):
		style._err_once("role:" + where, "ui.json %s is not a role object" % where)
		return Color(1.0, 0.0, 1.0)
	var d: Dictionary = def
	var base := str(d.get("base", ""))
	if not style.palette.has(base):
		style._err_once("role:" + where, "ui.json %s: base '%s' is not a palette colour" % [where, base])
		return Color(1.0, 0.0, 1.0)
	var c: Color = style.palette[base]
	if d.has("shade"):
		var m := str(d["shade"])
		if style.mixes.has(m) and style.palette.has("shadow"):
			c = UiStyle.mix8(style.palette["shadow"], c, 1.0 - float(style.mixes[m]))
		else:
			style._err_once("role:" + where, "ui.json %s: shade '%s' is not a palette mix fraction" % [where, m])
	if d.has("toward"):
		var to := str(d["toward"])
		if style.palette.has(to):
			c = UiStyle.mix8(c, style.palette[to], float(d.get("t", 0.0)))
		else:
			style._err_once("role:" + where, "ui.json %s: toward '%s' is not a palette colour" % [where, to])
	if d.has("alpha"):
		var a: Variant = d["alpha"]
		if a is String:
			c.a = style.param(a)
		elif a is float or a is int:
			c.a = float(a)
		else:
			style._err_once("role:" + where, "ui.json %s: alpha must be a number or a parameter name" % where)
	return c
