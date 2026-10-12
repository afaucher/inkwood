extends RefCounted

# THE GUNFIRE LOOKS (builder GF, 2026-10-11; decisions gunfire-looks and impact-by-round-and-target). ALEX CHOSE THE FAMILY G3 (decision gunfire-looks,
# 2026-10-11: 'G3 W1 soft puffs'), and builder G3 made it live (2026-10-12): the game reads it from data/fx/fx.json `gunfire` (cfg_from_data), the board still
# reads variants/gunfire/families.json (load_cfg). Every number inside the family stays PROPOSED. Alex, in the third playtest: "Fired shots should have smoke for large
# rounds (tanks, artillery and ship cannons). Landed shots should have an impact even if they don't destroy you." and "this should probably be a
# property of either the round or the thing being hit or both. Ex a round hitting water would splash, not explode with smoke. Right?"
#
# TWO KINDS OF RECORD, made like fx_tracer.gd's, from the sim's events and kept in a Book:
#   MUZZLE  a gun fires (a "fire" event of a cannon, a "shell_fire" of the Main Guns): a flash and smoke at the gun, sized by the GUN's class
#           (small, medium, large), drifting with the wind like the other smoke (W1; decision wind-with-height).
#   IMPACT  a round lands without destroying: a mark sized by the ROUND's class (bullet, small, medium, large) and shaped by the MATERIAL it lands
#           on (ground, water, stone, metal, wood). A round that hits water splashes; it never smokes.
# A FAMILY (variants/gunfire/families.json) is one consistent treatment: the recipe of parts (flash, strokes, rings, stipple, puffs, chips, leaves,
# scorch, disc) for the muzzle and for each material. The data is read from that file (working rule 4); this file only knows how to draw a part.
#
#   var cfg := FxGunfire.load_cfg()
#   FxGunfire.install_roles(style, cfg)           # the board's proposed colour roles, resolved as fx.json roles are
#   var book := FxGunfire.Book.new(cfg)
#   book.select("G2")
#   book.set_wind(wind)                            # a Wind (scripts/sim/wind.gd): puffs drift with it by height
#   book.add_muzzle("tank_1/3", "medium", centre, heading, fwd_m, t, 2.3)
#   book.add_impact("tank_1/3/hit", "medium", "metal", pos, t, heading)
#   var painter := FxGunfire.Painter.new(style, fx_data)
#   painter.draw(canvas_item, book, mapping, true_scale, now, view, "ground" | "air" | "shadows")
#
# SCALE. As the damage smoke and the tracers: a size is drawn metres (the planes' own scale) x the mapping's px per metre x true_scale, floored at the
# class's min_px so the smallest still reads at the planning zoom; WHERE a puff is stays a world position that the wind moves and the camera follows.
# DETERMINISTIC. Every random number comes from Mulberry32 seeded by (world seed, shot id, time), so two peers drawing the same events draw the same marks.
# Game time, as the effects layer's.
#
# IN THE GAME (builder G3, 2026-10-12): FxLayer owns a Book and a Painter made from fx.json (gunfire_muzzle / gunfire_impact), draws them in its ground,
# shadows and air passes, and scripts/ui/gunfire_feed.gd makes the records from the sim's events. The materials are the round model's one vocabulary
# (data/sim/rounds.json: metal, stone, wood, earth, water); an impact record may carry `off`, a world offset from `pos` in the unit's own metres that the
# drawn scale applies at draw time (a hit inside a tank's drawn hull, a miss beside it), as the tracers' offsets are.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxFlash = preload("res://scripts/fx/fx_flash.gd")
const FxWindProfile = preload("res://scripts/fx/fx_wind_profile.gd")

const FAMILIES_PATH := "res://variants/gunfire/families.json"
const CLASS_ORDER := ["bullet", "small", "medium", "large"]
const TONES := 3
const STAGES := 3

# --- Data ---------------------------------------------------------------------------------------------------------------------------

# The game's configuration, from data/fx/fx.json `gunfire` (values unwrapped), in the shape the Book reads: {classes, materials, puffs, families: {<id>:
# {muzzle, impact}}, game: the whole unwrapped section (the feed's own settings: which rounds, the geometry, the fog, the miss)}. {} when the file has none.
static func cfg_from_data(fxd: FxData) -> Dictionary:
	var raw: Variant = fxd.raw.get("gunfire")
	if not (raw is Dictionary):
		return {}
	var g: Dictionary = FxData.unwrap(raw)
	var recipes: Dictionary = g.get("recipes", {})
	return {"classes": g.get("classes", {}), "materials": g.get("materials", {}), "puffs": g.get("puffs", {}), "game": g,
		"families": {str(g.get("family", "G3")): {"muzzle": recipes.get("muzzle", []), "impact": recipes.get("impact", {})}}}

static func load_cfg(path: String = FAMILIES_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("FxGunfire: %s does not exist" % path)
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (v is Dictionary):
		push_error("FxGunfire: %s did not parse" % path)
		return {}
	return v

# The board's proposed colour roles go into the style's own role table, resolved exactly as fx.json roles are.
static func install_roles(st: FxStyle, cfg: Dictionary) -> void:
	var rl: Dictionary = cfg.get("roles", {})
	var ramps: Dictionary = rl.get("ramps", {})
	for name: String in ramps:
		if name.begins_with("_"):
			continue
		var d: Dictionary = ramps[name]
		var rows: Array = d["alpha"]
		for s in rows.size():
			var cols: Array = rows[s]
			for t in cols.size():
				var spec := {"base": d["base"], "alpha": float(cols[t])}
				if d.has("toward"):
					spec["toward"] = d["toward"]
					spec["t"] = float(d["t"])
				st._roles["%s.%d.%d" % [name, s, t]] = st._resolve(name, spec)
	var single: Dictionary = rl.get("single", {})
	for name: String in single:
		if name.begins_with("_"):
			continue
		st._roles[name] = st._resolve(name, single[name])

# A number that may vary by class: a plain number, or {bullet, small, medium, large} (a missing class takes the nearest smaller, then larger).
static func cv(v: Variant, cls: String, dflt: float = 0.0) -> float:
	if v == null:
		return dflt
	if v is Dictionary:
		var d: Dictionary = v
		var i := CLASS_ORDER.find(cls)
		if i < 0:
			i = 2
		var k := i
		while k >= 0:
			if d.has(CLASS_ORDER[k]):
				return float(d[CLASS_ORDER[k]])
			k -= 1
		k = i + 1
		while k < CLASS_ORDER.size():
			if d.has(CLASS_ORDER[k]):
				return float(d[CLASS_ORDER[k]])
			k += 1
		return dflt
	return float(v)

# --- The record book --------------------------------------------------------------------------------------------------------------------

class Book extends RefCounted:
	# A number that may vary by class: a plain number, or {bullet, small, medium, large} (a missing class takes the nearest smaller, then larger).
	static func cv(v: Variant, cls: String, dflt: float = 0.0) -> float:
		if v == null:
			return dflt
		if v is Dictionary:
			var d: Dictionary = v
			var i := CLASS_ORDER.find(cls)
			if i < 0:
				i = 2
			var k := i
			while k >= 0:
				if d.has(CLASS_ORDER[k]):
					return float(d[CLASS_ORDER[k]])
				k -= 1
			k = i + 1
			while k < CLASS_ORDER.size():
				if d.has(CLASS_ORDER[k]):
					return float(d[CLASS_ORDER[k]])
				k += 1
			return dflt
		return float(v)

	var cfg: Dictionary = {}
	var fam_id: String = ""
	var fam: Dictionary = {}
	var records: Array[Dictionary] = []
	var world_seed: int = 20261009
	var wind: Object = null
	var profile: RefCounted = null
	var max_records: int = 0               # 0: no cap; else the oldest go first (data fx.json gunfire.limits.max_records)
	var _seen: Dictionary = {}
	var _next: int = 0

	func _init(c: Dictionary) -> void:
		cfg = c

	func family_ids() -> Array:
		var out: Array = []
		for k: String in (cfg.get("families", {}) as Dictionary):
			out.append(k)
		return out

	func select(id: String) -> bool:
		var fams: Dictionary = cfg.get("families", {})
		if not fams.has(id):
			push_error("FxGunfire: no family '%s'" % id)
			return false
		fam_id = id
		fam = fams[id]
		return true

	func set_wind(w: Object) -> void:
		wind = w
		profile = FxWindProfile.from_wind(w)

	func clear() -> void:
		records.clear()
		_seen.clear()
		_next = 0

	func wind_at(t: float) -> Vector2:
		return wind.call("at", t) if wind != null else Vector2.ZERO

	# A gun fires. `centre` is the shooter's centre (world m), `dir` the firing direction (a world heading), `fwd_m` how far the muzzle is ahead of the
	# centre in the shooter's own metres (taken in the drawn scale at draw time), `lat_m` to its side; `height_m` above the ground (the wind rises with it).
	func add_muzzle(shot_id: String, gun: String, centre: Vector2, dir: float, fwd_m: float, t: float, height_m: float = 2.0, lat_m: float = 0.0) -> bool:
		if fam.is_empty() or _seen.has("m|" + shot_id):
			return false
		_seen["m|" + shot_id] = true
		_next += 1
		records.append({"id": _next, "kind": "muzzle", "shot": shot_id, "cls": gun, "centre": centre, "dir": dir, "fwd_m": fwd_m, "lat_m": lat_m, "t0": t,
			"h": height_m, "seed": FxBake.seed_of(world_seed, shot_id, int(round(t * 1000.0))), "mat": "", "off": Vector2.ZERO})
		_trim()
		return true

	# A round lands without destroying: `round_cls` (bullet, small, medium, large), `material` (ground, water, stone, metal, wood), `pos` world m.
	# `off`: a world offset from `pos`, metres in the unit's own scale (the drawn scale applies at draw time): where inside a hull a hit lands, how far
	# beside a target a miss does.
	func add_impact(shot_id: String, round_cls: String, material: String, pos: Vector2, t: float, dir: float = 0.0, height_m: float = 0.0, off: Vector2 = Vector2.ZERO) -> bool:
		if fam.is_empty() or _seen.has("i|" + shot_id):
			return false
		_seen["i|" + shot_id] = true
		_next += 1
		records.append({"id": _next, "kind": "impact", "shot": shot_id, "cls": round_cls, "centre": pos, "dir": dir, "fwd_m": 0.0, "lat_m": 0.0, "t0": t,
			"h": height_m, "seed": FxBake.seed_of(world_seed, shot_id, int(round(t * 1000.0))), "mat": material, "off": off})
		_trim()
		return true

	func _trim() -> void:
		while max_records > 0 and records.size() > max_records:
			var gone: Dictionary = records[0]
			_seen.erase(("m|" if str(gone["kind"]) == "muzzle" else "i|") + str(gone["shot"]))
			records.remove_at(0)

	func look_of(material: String) -> String:
		var m: Dictionary = (cfg.get("materials", {}) as Dictionary).get(material, {})
		return str(m.get("look", "ground"))

	func size_mult(material: String) -> float:
		var m: Dictionary = (cfg.get("materials", {}) as Dictionary).get(material, {})
		return float(m.get("size_mult", 1.0))

	func parts_of(rec: Dictionary) -> Array:
		if fam.is_empty():
			return []
		if str(rec["kind"]) == "muzzle":
			return fam.get("muzzle", [])
		return (fam.get("impact", {}) as Dictionary).get(look_of(str(rec["mat"])), [])

	func class_table(rec: Dictionary) -> Dictionary:
		var which := "gun" if str(rec["kind"]) == "muzzle" else "round"
		var tbl: Dictionary = (cfg.get("classes", {}) as Dictionary).get(which, {})
		var cls := str(rec["cls"])
		if tbl.has(cls):
			return tbl[cls]
		return tbl.get("medium", {"r_m": 1.0, "min_px": 4.0, "life": 1.0})

	# The part's life in seconds (a class-varying life is the data's own; a plain one is scaled by the class's `life`).
	func part_life(part: Dictionary, cls: String, ct: Dictionary) -> float:
		var l: Variant = part.get("life_s", 1.0)
		if l is Dictionary:
			return cv(l, cls, 1.0)
		var life := float(l) * float(ct.get("life", 1.0))
		return life

	# When the record's last part is over, in game seconds.
	func end_of(rec: Dictionary) -> float:
		var ct := class_table(rec)
		var cls := str(rec["cls"])
		var e := 0.0
		for p: Dictionary in parts_of(rec):
			if p.has("classes") and not (cls in (p["classes"] as Array)):
				continue
			e = maxf(e, float(p.get("delay_s", 0.0)) + part_life(p, cls, ct) + float(p.get("stagger_s", 0.0)) * maxf(cv(p.get("n", 1), cls, 1.0) - 1.0, 0.0)
				+ float(p.get("interval_s", 0.0)) * maxf(cv(p.get("n", 1), cls, 1.0) - 1.0, 0.0))
		return float(rec["t0"]) + e

	func live_count(now: float) -> int:
		var n := 0
		for rec: Dictionary in records:
			if now >= float(rec["t0"]) and now <= end_of(rec):
				n += 1
		return n

# --- The painter ------------------------------------------------------------------------------------------------------------------------------

class Painter extends RefCounted:
	# A number that may vary by class: a plain number, or {bullet, small, medium, large} (a missing class takes the nearest smaller, then larger).
	static func cv(v: Variant, cls: String, dflt: float = 0.0) -> float:
		if v == null:
			return dflt
		if v is Dictionary:
			var d: Dictionary = v
			var i := CLASS_ORDER.find(cls)
			if i < 0:
				i = 2
			var k := i
			while k >= 0:
				if d.has(CLASS_ORDER[k]):
					return float(d[CLASS_ORDER[k]])
				k -= 1
			k = i + 1
			while k < CLASS_ORDER.size():
				if d.has(CLASS_ORDER[k]):
					return float(d[CLASS_ORDER[k]])
				k += 1
			return dflt
		return float(v)

	var style: FxStyle
	var data: FxData
	var _sets: Dictionary = {}          # "set|ppm|r_px" -> FxPuff.PuffSet
	var _puff_opts: Dictionary = {}     # set id -> the FxPuff option (soft) or the edged option
	var bakes: int = 0

	# per call
	var item: CanvasItem
	var mapping: RefCounted
	var book: Book
	var ts: float = 1.0
	var now: float = 0.0
	var view: Rect2
	var layer: String = "air"
	# per record
	var rec: Dictionary
	var cls: String = "medium"
	var ct: Dictionary = {}
	var R: float = 8.0           # the class radius, px
	var ppm: float = 1.0         # drawn px per metre
	var wpos: Vector2            # world position of the record's origin
	var c: Vector2               # its screen position
	var dir_s: float = 0.0       # the firing / incoming direction as a screen angle
	var age0: float = 0.0

	func _init(st: FxStyle, fx_data: FxData) -> void:
		style = st
		data = fx_data

	func release() -> void:
		_sets.clear()

	# Draws one layer of every record. `layer`: "ground" (marks on the map, under the units), "air" (over the units), "shadows" (puffs' ground shadows, into the shadow group).
	func draw(canvas_item: CanvasItem, b: Book, m: RefCounted, true_scale: float, game_t: float, view_rect: Rect2, which_layer: String) -> int:
		item = canvas_item
		book = b
		mapping = m
		ts = true_scale
		now = game_t
		view = view_rect.grow(220.0)
		layer = which_layer
		var n := 0
		item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		for r: Dictionary in b.records:
			if game_t < float(r["t0"]):
				continue
			if game_t > b.end_of(r) + 0.01:
				continue
			if _begin(r):
				n += _parts()
		item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return n

	func _begin(r: Dictionary) -> bool:
		rec = r
		cls = str(r["cls"])
		ct = book.class_table(r)
		var centre: Vector2 = r["centre"]
		var dir_w := float(r["dir"])
		wpos = centre + (r.get("off", Vector2.ZERO) as Vector2) * ts
		if str(r["kind"]) == "muzzle":
			var fwd := Vector2.from_angle(dir_w)
			var side := Vector2(-fwd.y, fwd.x)
			wpos = centre + fwd * float(r["fwd_m"]) * ts + side * float(r["lat_m"]) * ts
		c = mapping.world_to_screen(wpos)
		if not view.has_point(c):
			return false
		ppm = mapping.px_per_m(wpos) * ts
		var mult := book.size_mult(str(r["mat"])) if str(r["kind"]) == "impact" else 1.0
		R = maxf(float(ct.get("r_m", 1.0)) * mult * ppm, float(ct.get("min_px", 4.0)) * sqrt(mult))
		dir_s = mapping.screen_angle(wpos, dir_w)
		age0 = now - float(r["t0"])
		return true

	func _parts() -> int:
		var made := 0
		var parts: Array = book.parts_of(rec)
		for i in parts.size():
			var p: Dictionary = parts[i]
			if p.has("classes") and not (cls in (p["classes"] as Array)):
				continue
			var lay := str(p.get("layer", "air"))
			var is_puff := str(p["type"]) == "puffs"
			if layer == "shadows":
				if not (is_puff and bool(p.get("shadow", false))):
					continue
			elif lay != layer:
				continue
			var age := age0 - float(p.get("delay_s", 0.0))
			if age < 0.0:
				continue
			match str(p["type"]):
				"flash":
					_flash(p, i, age)
				"strokes":
					_strokes(p, i, age)
				"rings":
					_rings(p, i, age)
				"stipple":
					_stipple(p, i, age)
				"puffs":
					_puffs(p, i, age)
				"chips":
					_chips(p, i, age)
				"leaves":
					_leaves(p, i, age)
				"scorch":
					_scorch(p, i, age)
				"disc":
					_disc(p, i, age)
			made += 1
		return made

	# --- helpers ----------------------------------------------------------------------------------------------------------------------------

	func _n(p: Dictionary, key: String, dflt: float = 0.0) -> float:
		return cv(p.get(key, dflt), cls, dflt)

	func _life(p: Dictionary) -> float:
		return book.part_life(p, cls, ct)

	func _rng(i: int, salt: int = 0) -> Mulberry32:
		return Mulberry32.new(FxBake.seed_of(int(rec["seed"]), i, salt))

	func _col(role: String, a: float = 1.0) -> Color:
		if role == "":
			return Color(0, 0, 0, 0)
		var col: Color = style.color(role)
		return Color(col.r, col.g, col.b, col.a * a)

	func _pair(p: Dictionary, key: String, dflt_lo: float, dflt_hi: float) -> Vector2:
		var v: Variant = p.get(key)
		if v is Array and (v as Array).size() >= 2:
			return Vector2(float((v as Array)[0]), float((v as Array)[1]))
		if v is float or v is int:
			return Vector2(float(v), float(v))
		return Vector2(dflt_lo, dflt_hi)

	func _origin(p: Dictionary) -> Vector2:
		return c + Vector2.from_angle(dir_s) * float(p.get("fwd", 0.0)) * R

	# 1 - the fade of a part at fraction u of its life: held, then falling with a power.
	static func _fade(u: float, hold: float, power: float) -> float:
		if u <= hold:
			return 1.0
		return pow(clampf(1.0 - (u - hold) / maxf(1.0 - hold, 1e-6), 0.0, 1.0), power)

	# The wind's drift of a thing born at the record's time, in world metres, after `age` seconds, by its height and rise.
	func _drift_world(h0: float, rise: float, age: float, mult: float) -> Vector2:
		var w: Vector2 = book.wind_at(float(rec["t0"]))
		var d := age
		var prof: Variant = book.profile
		if prof != null and not bool(prof.get("flat")):
			d = float(prof.call("integral", h0, rise, age))
		return w * d * mult

	func _drift_px(h0: float, rise: float, age: float, mult: float) -> Vector2:
		if mult == 0.0:
			return Vector2.ZERO
		return mapping.screen_delta(wpos, _drift_world(h0, rise, age, mult))

	# --- parts ------------------------------------------------------------------------------------------------------------------------------

	func _fan(centre: Vector2, pts: PackedVector2Array, col: Color) -> void:
		if col.a <= 0.003 or pts.size() < 2:
			return
		for i in pts.size():
			var q := pts[(i + 1) % pts.size()]
			if absf((pts[i] - centre).cross(q - centre)) < 0.02:
				continue
			item.draw_colored_polygon(PackedVector2Array([centre, pts[i], q]), col)

	# A knock-out flash: a pale star, a cone of one, or a disc, with an optional ink edge. Quick up, long down.
	func _flash(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var u := age / life
		var env := (u / 0.15) if u < 0.15 else pow(clampf((1.0 - u) / 0.85, 0.0, 1.0), 1.3)
		var g := _pair(p, "grow", 0.6, 1.0)
		var r := R * float(p.get("r", 1.0)) * lerpf(g.x, g.y, 1.0 - pow(1.0 - clampf(u * 2.5, 0.0, 1.0), 2.0))
		var o := _origin(p)
		var rng := _rng(idx)
		var form := str(p.get("form", "star"))
		var pts := PackedVector2Array()
		if form == "disc":
			var n := 16
			var a0 := rng.next() * TAU
			for k in n:
				var a := a0 + float(k) / float(n) * TAU
				pts.append(o + Vector2.from_angle(a) * r * (0.85 + 0.3 * rng.next()))
		elif form == "star" or form == "cone":
			var spikes := int(p.get("spikes", 8))
			var inner := float(p.get("inner", 0.5))
			var vr := float(p.get("var", 0.3))
			if form == "star":
				var a0 := rng.next() * TAU
				for k in spikes * 2:
					var a := a0 + float(k) / float(spikes * 2) * TAU
					var rr := r * (1.0 - vr * rng.next()) if k % 2 == 0 else r * inner * (0.8 + 0.4 * rng.next())
					pts.append(o + Vector2.from_angle(a) * rr)
			else:
				var cone := deg_to_rad(float(p.get("cone_deg", 45.0)))
				var m := spikes
				pts.append(o - Vector2.from_angle(dir_s) * r * 0.28)
				pts.append(o + Vector2.from_angle(dir_s - PI * 0.5) * r * 0.3)
				for k in m * 2 + 1:
					var f := float(k) / float(m * 2)
					var a := dir_s - cone + f * 2.0 * cone
					var along := cos((f - 0.5) * PI * 0.9)
					var rr := r * (0.45 + 0.55 * along) * (1.0 - vr * rng.next()) if k % 2 == 0 else r * inner * (0.5 + 0.5 * along) * (0.8 + 0.4 * rng.next())
					pts.append(o + Vector2.from_angle(a) * rr)
				pts.append(o + Vector2.from_angle(dir_s + PI * 0.5) * r * 0.3)
		_fan(o, pts, _col(str(p.get("fill", "burst.core")), env))
		var edge := str(p.get("edge", ""))
		if edge != "" and pts.size() > 2:
			var ring := PackedVector2Array(pts)
			ring.append(pts[0])
			item.draw_polyline(ring, _col(edge, env * 0.9), maxf(float(p.get("edge_w", 1.0)) * 0.9, 0.7), true)

	func _disc(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var u := age / life
		var o := _origin(p)
		var r := R * lerpf(float(p.get("r0", 0.2)), float(p.get("r1", 1.4)), 1.0 - pow(1.0 - u, 2.0))
		var a := pow(1.0 - u, 1.2)
		var pts := PackedVector2Array()
		var n := 28
		for k in n:
			pts.append(o + Vector2.from_angle(float(k) / float(n) * TAU) * r)
		_fan(o, pts, _col(str(p.get("fill", "gf.splash.soft")), a))
		var edge := str(p.get("edge", ""))
		if edge != "":
			pts.append(pts[0])
			item.draw_polyline(pts, _col(edge, a), 1.0, true)

	func _strokes(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var u := age / life
		var n := int(round(_n(p, "n", 6.0)))
		var rng := _rng(idx)
		var spread := deg_to_rad(_n(p, "spread_deg", 360.0))
		var full := spread >= TAU - 0.01
		var r0 := _n(p, "r0", 0.3) * R
		var rr := _pair(p, "r1", 1.2, 2.0)
		var w := _n(p, "w_px", 1.2)
		var zig := bool(p.get("zig", false))
		var o := _origin(p)
		var e := 1.0 - pow(1.0 - clampf(age / (life * 0.45), 0.0, 1.0), 2.0)
		var alpha := pow(1.0 - u, 1.3)
		var role := str(p.get("role", "ink"))
		for i in n:
			var a: float
			if full:
				a = (float(i) + rng.next() * 0.8) / float(n) * TAU
			else:
				a = dir_s + (rng.next() - 0.5) * 2.0 * spread
			var d := Vector2.from_angle(a)
			var rs := r0 * (0.8 + 0.4 * rng.next())
			var re := R * lerpf(rr.x, rr.y, rng.next())
			var head := rs + (re - rs) * e
			var tail := rs + (head - rs) * clampf((u - 0.35) / 0.65, 0.0, 1.0) * 0.9
			var wj := w * (0.8 + 0.4 * rng.next())
			var jig := (rng.next() - 0.5) * 0.5
			if zig:
				var nrm := Vector2(-d.y, d.x)
				var mid := (head + tail) * 0.5
				var pts := PackedVector2Array([o + d * tail, o + d * mid + nrm * (head - tail) * jig * 1.6, o + d * head])
				item.draw_polyline(pts, _col(role, alpha), wj, true)
			else:
				item.draw_line(o + d * tail, o + d * head, _col(role, alpha), wj, true)

	func _rings(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		var n := int(round(_n(p, "n", 1.0)))
		var stagger := float(p.get("stagger_s", 0.1))
		var o := _origin(p)
		var r0 := _n(p, "r0", 0.3) * R
		var r1 := _n(p, "r1", 2.0) * R
		var w := _n(p, "w_px", 1.0)
		var role := str(p.get("role", "ink.ring"))
		var squash := float(p.get("squash", 1.0))
		for k in n:
			var ak := age - float(k) * stagger
			if ak <= 0.0 or ak >= life:
				continue
			var f := ak / life
			var r := lerpf(r0, r1, 1.0 - pow(1.0 - f, 2.0))
			var pts := PackedVector2Array()
			var segs := clampi(int(r * 1.2) + 14, 14, 56)
			for j in segs + 1:
				var a := float(j) / float(segs) * TAU
				pts.append(o + Vector2(cos(a) * r, sin(a) * r * squash))
			item.draw_polyline(pts, _col(role, pow(1.0 - f, 1.4)), w, true)

	func _stipple(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var n := int(round(_n(p, "n", 20.0)))
		var rng := _rng(idx)
		var cone := deg_to_rad(_n(p, "cone_deg", 360.0))
		var full := cone >= TAU - 0.01
		var th := _pair(p, "throw", 1.0, 2.0)
		var tau := maxf(float(p.get("tau_s", 0.4)), 0.05)
		var dot := _n(p, "dot_px", 1.0)
		var role := str(p.get("role", "ink.dot"))
		var wmult := float(p.get("wind", 1.0))
		var rise := float(p.get("rise_mps", 0.0))
		var o := _origin(p)
		var h0 := float(rec["h"])
		for i in n:
			var a: float
			if full:
				a = rng.next() * TAU
			else:
				a = dir_s + (rng.next() - 0.5) * cone
			var sp := lerpf(th.x, th.y, rng.next()) * R
			var ul := 0.45 + 0.55 * rng.next()      # this dot's own life share: the cloud thins as dots go
			var dl := rng.next() * 0.1
			var da := age - dl * life
			if da <= 0.0 or da >= life * ul:
				continue
			var dr := rng.next()
			var f := da / (life * ul)
			var pos := o + Vector2.from_angle(a) * sp * tau * (1.0 - exp(-da / tau)) + _drift_px(h0, rise, da, wmult)
			var rad := dot * (0.7 + 0.6 * dr)
			item.draw_circle(pos, rad, _col(role, _fade(f, 0.25, 1.3)))

	func _chips(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var u := age / life
		var n := int(round(_n(p, "n", 6.0)))
		var rng := _rng(idx)
		var len_px := maxf(_n(p, "len", 0.34) * R, 2.0)
		var r1 := _n(p, "r1", 2.0) * R
		var thin := bool(p.get("thin", false))
		var fill := bool(p.get("fill", true))
		var o := _origin(p)
		var alpha := pow(1.0 - u, 1.2)
		for i in n:
			var a := rng.next() * TAU
			var fr := 0.45 + 0.55 * rng.next()
			var spin := (rng.next() - 0.5) * 6.0
			var side := 1.0 if rng.next() < 0.5 else -1.0
			var pos := o + Vector2.from_angle(a) * r1 * fr * (1.0 - exp(-age / 0.14))
			var rot := a + spin * age
			var s := len_px * (0.7 + 0.6 * rng.next())
			var pts := PackedVector2Array()
			if thin:
				pts = PackedVector2Array([Vector2(1.7 * s, 0.0), Vector2(-0.8 * s, 0.2 * s), Vector2(-0.8 * s, -0.2 * s)])
			else:
				pts = PackedVector2Array([Vector2(s, 0.0), Vector2(-0.55 * s, 0.6 * s * side), Vector2(-0.4 * s, -0.55 * s)])
			var xf := Transform2D(rot, pos)
			var wp := PackedVector2Array()
			for q in pts:
				wp.append(xf * q)
			if absf((wp[1] - wp[0]).cross(wp[2] - wp[0])) < 0.15:
				continue
			if fill:
				item.draw_colored_polygon(wp, _col(str(p.get("role", "gf.chip")), alpha))
			var edge := str(p.get("edge", "ink"))
			if edge != "":
				var ring := PackedVector2Array(wp)
				ring.append(wp[0])
				item.draw_polyline(ring, _col(edge, alpha * 0.9), 0.9, true)

	func _leaves(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life:
			return
		var u := age / life
		var n := int(round(_n(p, "n", 6.0)))
		var rng := _rng(idx)
		var sz := maxf(_n(p, "size", 0.2) * R, 1.8)
		var r1 := _n(p, "r1", 2.0) * R
		var wmult := float(p.get("drift", 1.0))
		var ink_only := bool(p.get("ink_only", false))
		var o := _origin(p)
		var h0 := float(rec["h"]) + 3.0
		var alpha := _fade(u, 0.45, 1.2)
		for i in n:
			var a := rng.next() * TAU
			var fr := 0.35 + 0.65 * rng.next()
			var spin := (rng.next() - 0.5) * 4.0
			var pos := o + Vector2.from_angle(a) * r1 * fr * (1.0 - exp(-age / 0.3)) + _drift_px(h0, 0.0, age, wmult)
			var rot := a + spin * age
			var s := sz * (0.7 + 0.6 * rng.next())
			if ink_only:
				var d := Vector2.from_angle(rot)
				var nrm := Vector2(-d.y, d.x)
				var pts := PackedVector2Array([pos - d * s, pos + nrm * s * 0.45, pos + d * s])
				item.draw_polyline(pts, _col("ink", alpha * 0.9), 1.0, true)
				continue
			var lens := PackedVector2Array()
			for k in 8:
				var t := float(k) / 8.0 * TAU
				lens.append(Transform2D(rot, pos) * Vector2(cos(t) * s, sin(t) * s * 0.5))
			item.draw_colored_polygon(lens, _col(str(p.get("fill", "gf.leaf")), alpha))
			lens.append(lens[0])
			item.draw_polyline(lens, _col(str(p.get("edge", "ink")), alpha * 0.85), 0.9, true)

	# A ground mark that stays: a faint wash blot, ink dots and short hatching.
	func _scorch(p: Dictionary, idx: int, age: float) -> void:
		var o := _origin(p)
		var fin := maxf(float(p.get("fade_in_s", 0.4)), 0.01)
		var a := clampf(age / fin, 0.0, 1.0)
		var life := float(p.get("life_s", -1.0))
		if life > 0.0:
			a *= 1.0 - smoothstep(life - 20.0, life, age)
		if a <= 0.0:
			return
		var rng := _rng(idx)
		var r := R * _n(p, "r", 0.8)
		var pts := PackedVector2Array()
		var n := 14
		var a0 := rng.next() * TAU
		for k in n:
			pts.append(o + Vector2.from_angle(a0 + float(k) / float(n) * TAU) * r * (0.72 + 0.5 * rng.next()))
		_fan(o, pts, _col(str(p.get("wash_role", "gf.scorch")), a))
		var dots := int(p.get("dots", 0))
		for i in dots:
			var da := rng.next() * TAU
			var dd := sqrt(rng.next()) * r * 1.35
			item.draw_circle(o + Vector2.from_angle(da) * dd, 0.8 * (0.7 + 0.6 * rng.next()), _col(str(p.get("dot_role", "scar.dot")), a))
		var hatch := int(p.get("hatch", 0))
		for i in hatch:
			var ha := rng.next() * TAU
			var hr0 := r * (0.3 + 0.3 * rng.next())
			var hr1 := hr0 + r * (0.4 + 0.5 * rng.next())
			item.draw_line(o + Vector2.from_angle(ha) * hr0, o + Vector2.from_angle(ha) * hr1, _col(str(p.get("hatch_role", "ink.hatch")), a), 0.9, true)

	# --- puffs: baked sprites drifting with the wind -----------------------------------------------------------------------------------------

	func _puffs(p: Dictionary, idx: int, age: float) -> void:
		var life := _life(p)
		if age >= life + float(p.get("interval_s", 0.0)) * 8.0:
			return
		var set_id := str(p["set"])
		var n := int(round(_n(p, "n", 1.0)))
		var rng := _rng(idx)
		var r_part := R * float(p.get("r", 0.7))
		var tone := int(p.get("tone", 1))
		var iv := float(p.get("interval_s", 0.04))
		var grow := _pair(p, "grow", 0.8, 1.6)
		var gtau := maxf(float(p.get("grow_tau", 0.2)), 0.02)
		var hold := float(p.get("hold", 0.15))
		var fpow := float(p.get("fade_power", 1.5))
		var th := float(p.get("throw", 2.0))
		var ttau := maxf(float(p.get("throw_tau", 0.4)), 0.05)
		var side := float(p.get("side", 0.0))
		var spread := float(p.get("spread", 0.0))
		var rise := float(p.get("rise_mps", 0.5))
		var wmult := float(p.get("wind", 1.0))
		var o := _origin(p)
		var h0 := float(rec["h"])
		var shadow_pass := layer == "shadows"
		var tint: Color = style.palette["shadow"]
		var ps := _set_for(set_id, r_part)
		if ps == null:
			return
		var popt := {"hold": hold, "fade_power": fpow, "peak_alpha": 1.0, "alpha_steps": [], "stages": STAGES, "stage_edges": [0.25, 0.55]}
		for i in n:
			var pa := age - float(i) * iv
			var a := rng.next() * TAU
			var variant := int(rng.next() * float(ps.variants))
			var rs := 0.85 + 0.3 * rng.next()
			var sd := 0.0
			if side != 0.0:
				sd = (rng.next() - 0.5) * 2.0 * side * R
			var spr := Vector2.ZERO
			if spread > 0.0:
				spr = Vector2.from_angle(a) * sqrt(rng.next()) * spread * R
			var thrown_dir := Vector2.from_angle(dir_s) if str(rec["kind"]) == "muzzle" else Vector2.from_angle(a)
			if pa <= 0.0 or pa >= life:
				continue
			var u := pa / life
			var pos := o + spr + Vector2(-thrown_dir.y, thrown_dir.x) * sd + thrown_dir * th * R * ttau * (1.0 - exp(-pa / ttau)) + _drift_px(h0, rise, pa, wmult)
			var sc := (r_part * rs / float(ps.radius_px[tone])) * lerpf(grow.x, grow.y, (1.0 - exp(-u / gtau)) / (1.0 - exp(-1.0 / gtau)))
			var alpha := FxPuff.alpha_at(popt, u)
			var stage := mini(FxPuff.stage_of(popt, u), ps.stages - 1)
			if shadow_pass:
				if tone < 1 or alpha < 0.25:
					continue
				var hh := h0 + rise * pa
				var off: Vector2 = mapping.screen_delta(wpos, style.plane_shadow_offset_m(hh) * ts)
				if off.length() < 1.5:
					continue
				item.draw_set_transform(pos + off, 0.0, Vector2(sc, sc))
				item.draw_texture((ps.mask[tone] as Array)[variant], -(ps.origin[tone] as Vector2), Color(tint.r, tint.g, tint.b, 1.0))
				continue
			item.draw_set_transform(pos, 0.0, Vector2(sc, sc))
			item.draw_texture((ps.tex[tone] as Array)[variant + ps.variants * stage], -(ps.origin[tone] as Vector2), Color(1, 1, 1, alpha))
		item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# A baked set at the part's radius (px), quantized so a slow zoom bakes once per step.
	func _set_for(set_id: String, r_px: float) -> FxPuff.PuffSet:
		var rq := maxf(snappedf(r_px, 1.0), 3.0)
		var key := "%s|%.0f" % [set_id, rq]
		if _sets.has(key):
			return _sets[key]
		if not FxBake.can_bake():
			return null
		var cfg_puffs: Dictionary = (book.cfg.get("puffs", {}) as Dictionary)
		if not cfg_puffs.has(set_id):
			push_error("FxGunfire: no puff set '%s'" % set_id)
			return null
		var def: Dictionary = cfg_puffs[set_id]
		var ps: FxPuff.PuffSet = null
		if str(def.get("form", "soft")) == "soft":
			ps = FxPuff.bake_set(style, _soft_option(def), 1.0, rq)
		else:
			ps = _bake_edged(def, rq, key)
		bakes += 1
		_sets[key] = ps
		return ps

	# W1 with the set's roles in place of its own, baked at a radius of exactly the part's (radius_frac 1, size_m = px at 1 px per metre).
	func _soft_option(def: Dictionary) -> Dictionary:
		var o: Dictionary = data.smoke_option(str(def.get("base", "W1"))).duplicate(true)
		var roles: Array = []
		if def.has("ramp"):
			for s in STAGES:
				for t in TONES:
					roles.append("%s.%d.%d" % [def["ramp"], s, t])
		else:
			roles = def["roles"]
		o["lit_roles"] = roles
		o["shade_roles"] = roles
		o["radius_frac"] = [1.0, 1.0]
		o["variants"] = 3
		o["stages"] = STAGES
		return o

	# The EDGED puff: a ragged paper-light cloud with an ink outline and a few hatch strokes on the shade side (the side away from the light).
	func _bake_edged(def: Dictionary, r_px: float, key: String) -> FxPuff.PuffSet:
		var ps := FxPuff.PuffSet.new()
		ps.ppm = 1.0
		ps.size_m = r_px
		ps.variants = 3
		ps.stages = STAGES
		var canvases: Array = []
		var meta: Array = []
		for tone in TONES:
			var half := int(ceil(r_px * 1.32 + 4.0))
			ps.radius_px.append(r_px)
			ps.origin.append(Vector2(half, half))
			ps.tex.append([])
			ps.mask.append([])
			for stage in STAGES:
				for v in ps.variants:
					var seed_v := FxBake.seed_of(key, tone * 97 + v, 11)
					var g := InkCanvas.new(Vector2i(half * 2, half * 2))
					g.line_cap = "round"
					_draw_edged(g, def, tone, stage, seed_v, r_px, Vector2(half, half), false)
					canvases.append(g)
					meta.append([tone, v, stage, false])
					if stage == 0:
						var m := InkCanvas.new(Vector2i(half * 2, half * 2))
						_draw_edged(m, def, tone, stage, seed_v, r_px, Vector2(half, half), true)
						canvases.append(m)
						meta.append([tone, v, stage, true])
		var imgs := FxBake.render(canvases)
		for k in meta.size():
			var tn: int = meta[k][0]
			if bool(meta[k][3]):
				(ps.mask[tn] as Array).append(FxBake.texture(imgs[k], true))
			else:
				(ps.tex[tn] as Array).append(FxBake.texture(imgs[k], false))
		return ps

	func _draw_edged(g: InkCanvas, def: Dictionary, tone: int, stage: int, seed_v: int, r_px: float, at: Vector2, mask_only: bool) -> void:
		var rng := Mulberry32.new(seed_v)
		var n_lobes := 5 + int(rng.next() * 3.0)
		var a0 := rng.next() * TAU
		var polys: Array = []
		for i in n_lobes:
			var a := a0 + float(i) / float(n_lobes) * TAU + (rng.next() - 0.5) * 0.5
			var d := r_px * (0.4 + rng.next() * 0.14)
			var rl := r_px * (0.3 + rng.next() * 0.14)
			polys.append(FxFlash._jag(rng, at.x + cos(a) * d, at.y + sin(a) * d, rl, 8 + int(rng.next() * 3.0), 0.2, 0.1))
		polys.append(FxFlash._jag(rng, at.x + (rng.next() - 0.5) * r_px * 0.12, at.y + (rng.next() - 0.5) * r_px * 0.12, r_px * 0.5, 10, 0.18, 0.08))
		var cur: PackedVector2Array = polys[0]
		for j in range(1, polys.size()):
			var res: Array = Geometry2D.merge_polygons(cur, polys[j])
			var best := -1.0
			for poly: PackedVector2Array in res:
				if Geometry2D.is_polygon_clockwise(poly):
					continue
				var area := _area(poly)
				if area > best:
					best = area
					cur = poly
		var outline := cur
		g.begin_path()
		for k in outline.size():
			if k == 0:
				g.move_to(outline[k].x, outline[k].y)
			else:
				g.line_to(outline[k].x, outline[k].y)
		g.close_path()
		if mask_only:
			g.fill_color = Color.WHITE
			g.fill()
			return
		var ramp := str(def.get("ramp", "gf.paper"))
		var fill: Color = style.color("%s.%d.%d" % [ramp, stage, tone])
		g.fill_color = fill
		g.fill()
		# the ink edge, thinning as the puff ages; the pen is the map's (it keys on the exact ink colour)
		var wgt := style.line_weight() * style.lw("tree_outline") * 0.85 * clampf(r_px / 14.0, 0.55, 1.0)
		g.stroke_color = style.ink()
		g.line_width = wgt
		g.global_alpha = [1.0, 0.78, 0.5][stage]
		g.begin_path()
		for k in outline.size():
			if k == 0:
				g.move_to(outline[k].x, outline[k].y)
			else:
				g.line_to(outline[k].x, outline[k].y)
		g.close_path()
		g.stroke()
		g.global_alpha = 1.0
		# hatching on the shade side (away from the detail light), a few short strokes inside the edge
		var hn := int(round(float(def.get("hatch", 3)) * [1.0, 0.6, 0.0][stage]))
		if hn > 0:
			var shade_dir := (-style.detail_light).normalized() if style.detail_light.length() > 0.001 else Vector2(0.7, 0.7)
			g.stroke_color = style.color("ink.hatch")
			g.line_width = wgt * 0.8
			g.begin_path()
			var drawn := false
			for i in hn * 3:
				if i >= hn * 3:
					break
				var ang := shade_dir.angle() + (rng.next() - 0.5) * 1.6
				var dist := r_px * (0.42 + rng.next() * 0.35)
				var p0 := at + Vector2.from_angle(ang) * dist
				var tdir := Vector2.from_angle(ang + PI * 0.5 + (rng.next() - 0.5) * 0.4)
				var ln := r_px * (0.16 + rng.next() * 0.14)
				var p1 := p0 + tdir * ln
				if Geometry2D.is_point_in_polygon(p0, outline) and Geometry2D.is_point_in_polygon(p1, outline):
					g.move_to(p0.x, p0.y)
					g.line_to(p1.x, p1.y)
					drawn = true
					hn -= 0
			if drawn:
				g.stroke()

	static func _area(p: PackedVector2Array) -> float:
		var s := 0.0
		for i in p.size():
			var a := p[i]
			var b := p[(i + 1) % p.size()]
			s += a.x * b.y - b.x * a.y
		return absf(s) * 0.5
