extends RefCounted

# Colour ROLES for a drawn thing that is not in ui.json (the boats, the bridges): a role is
# {base, shade?, toward?, t?, alpha?} exactly as data/ui/ui.json's roles block defines it
# (scripts/ui/ui_style.gd _resolve), resolved against the style's palette, so no hex is typed
# in draw code (working rule 6, docs/proposals/palette-architecture.md). Hue stays reserved
# for paper, ink, shadow and the side accents; every role here is the paper ramp, the ink
# ramp, a mix toward the one shadow tint, or a side accent -- and the ONE exception, a
# PLACEHOLDER water, which is itself a mix of the shadow tint and paper.
#
#   var roles := InkRoles.resolve_all(style, boats_json["roles"])
#   roles["hull_patrol"]            # a Color
#
# A role the data names with a base the palette does not have is an error in `errors` and
# a loud magenta, never a quiet default.

const UiStyle = preload("res://scripts/ui/ui_style.gd")

static func resolve_all(st: RefCounted, roles: Dictionary, errors: Array = []) -> Dictionary:
	var out := {}
	for name: String in roles:
		if name.begins_with("_"):
			continue
		var def: Variant = roles[name]
		if def is Dictionary:
			out[name] = resolve(st, name, def, errors)
		else:
			errors.append("role '%s' is not an object" % name)
	return out

static func resolve(st: RefCounted, name: String, def: Dictionary, errors: Array = []) -> Color:
	var base := str(def.get("base", ""))
	if not st.palette.has(base):
		errors.append("role '%s': base '%s' is not a palette colour" % [name, base])
		return Color(1.0, 0.0, 1.0)
	var c: Color = st.palette[base]
	if def.has("shade"):
		var m := str(def["shade"])
		if st.mixes.has(m) and st.palette.has("shadow"):
			c = UiStyle.mix8(st.palette["shadow"], c, 1.0 - float(st.mixes[m]))
		else:
			errors.append("role '%s': shade '%s' is not a palette mix fraction" % [name, m])
	if def.has("toward"):
		var to := str(def["toward"])
		if st.palette.has(to):
			c = UiStyle.mix8(c, st.palette[to], float(def.get("t", 0.0)))
		else:
			errors.append("role '%s': toward '%s' is not a palette colour" % [name, to])
	if def.has("alpha"):
		var a: Variant = def["alpha"]
		if a is String:
			c.a = st.param(a)
		elif a is float or a is int:
			c.a = float(a)
		else:
			errors.append("role '%s': alpha must be a number or a parameter name" % name)
	return c
