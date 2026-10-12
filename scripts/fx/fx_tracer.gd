extends RefCounted

# MACHINE-GUN TRACERS (Track TR, 2026-10-11). Alex's note from the second playtest was "We should show tracers for machine guns"
# (decision playtest-2); the scope is machine guns only (decision tracers-mg) and the look is his pick from variants/tracers/, T5, an
# ink streak with a dot for a hit and a tick for a miss (decision tracers-look). STILL PROPOSED: every number of the options, in
# data/fx/fx.json `tracers`. WHICH WEAPONS draw one is the ROUND's tracer flag (builder G3, 2026-10-12, decision round-model: data/sim/rounds.json; a weapon
# names its round in data/units/*.json), no longer a list of weapon ids here: exactly the weapons that fire the bullet round, as the list was.
#
# WHAT IT DRAWS. A "fire" event (scripts/sim/combat.gd: one per roll, with the weapon id, the hardpoint, the muzzle's place x/y,
# the target's centre tx/ty and whether the roll hit) from a weapon whose round has a tracer gets one tracer: a short-lived line of fire
# from the gun's hardpoint toward the target. A HIT ends on the target (a point on its airframe, picked by the event); a MISS
# passes beside it (a lateral offset picked by the event) and carries on a little past. Flak, light flak, the cruiser's shells
# and bombs are not tracers (they have their own events and looks). Visual only: nothing here is read by the sim.
#
# DETERMINISTIC. Every number a tracer needs beyond its event comes from Mulberry32 seeded by (world seed, the shot's id), so two
# peers given the same events draw the same tracers. A shot id seen twice makes one tracer (a replayed event adds nothing).
#
# TIME is GAME time, as the rest of the effects layer: a tracer is born at its event's game time and lives `life_s` of the
# playback clock; looking at an earlier time shows it as not yet born (scrubbing is safe).
#
# SCALE. Planes are drawn at their own scale, not the map's (fx_layer.gd: true_scale), so a gun's place relative to its plane
# and a miss's offset from its target are taken in the DRAWN scale: centre + (muzzle - centre) x true_scale x draw_k, the target's
# size likewise. Widths and dashes are screen px / drawn metres, so a tracer reads at the planning zoom and close in alike.
#
#   var book := FxTracer.Book.new(FxData.shared())
#   book.add(world_seed, shot_id, weapon, muzzle, centre, aim, aim_size_m, t, hit, accent, draw_k, seen_shooter, seen_target)
#   FxTracer.draw_all(canvas_item, book, mapping, fx_style, true_scale, now, view)

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const Rounds = preload("res://scripts/sim/rounds.gd")

# --- The call a fire event becomes -------------------------------------------------------------------------------

# THE ONE PLACE a fire event's fields become the layer's tracer() call (the feed and the boards both call it). `fx` has
# tracer_weapon(weapon) and tracer(...) (the FxLayer, or a test's recording fake; one without them is left alone). Returns true when
# the weapon is a tracer weapon (whether or not one was drawn: out of sight it is still not flak), false when it is not or fx cannot.
#   centre         the shooter's centre at the event (the hardpoint's offset from it is taken in the drawn scale)
#   aim_size_m     the target's size_m x its marker's draw scale (a hit lands inside it, a miss passes it by a share of it)
#   accent         the shooter's side accent, a palette name ("side_a"); "" when unknown
#   aim_lead       how far the target flies while the round is on its way (its displacement over the tracer's flight_s, from the
#                  sim's own path): the line is aimed there, so a hit ends on the plane as it is drawn when the round arrives
static func feed_event(fx: Object, ev: Dictionary, game_t: float, centre: Vector2, aim_size_m: float, accent: String, draw_k: float = 1.0, seen_shooter: bool = true, seen_target: bool = true, aim_lead: Vector2 = Vector2.ZERO) -> bool:
	if fx == null or not fx.has_method("tracer_weapon") or not fx.has_method("tracer"):
		return false
	var weapon := str(ev.get("weapon", ""))
	if not bool(fx.call("tracer_weapon", weapon)):
		return false
	var shot := "%s/%s/%d/%d/%d" % [str(ev.get("unit", "")), weapon, int(ev.get("hardpoint", 0)), int(ev.get("turn", 0)), int(ev.get("tick", 0))]
	var muzzle := Vector2(float(ev.get("x", centre.x)), float(ev.get("y", centre.y)))
	var aim := Vector2(float(ev.get("tx", muzzle.x)), float(ev.get("ty", muzzle.y))) + aim_lead
	fx.call("tracer", shot, weapon, muzzle, centre, aim, aim_size_m, game_t, bool(ev.get("hit", false)), accent, draw_k, seen_shooter, seen_target)
	return true

# --- The record book ----------------------------------------------------------------------------------------------------

class Book extends RefCounted:
	var data: FxData
	var rounds: Rounds = null                # the round model (data/sim/rounds.json): which weapons fire a round with a tracer
	var cfg: Dictionary = {}                 # fx.json tracers, unwrapped
	var name: String = ""
	var opt: Dictionary = {}                 # the selected option, unwrapped
	var records: Array[Dictionary] = []
	var _seen: Dictionary = {}               # shot id -> true
	var _next_id: int = 0

	func _init(fx_data: FxData = null, round_model: Rounds = null) -> void:
		data = fx_data if fx_data != null else FxData.shared()
		rounds = round_model if round_model != null else (Rounds.shared() as Rounds)
		var raw: Variant = data.raw.get("tracers")
		if raw is Dictionary:
			cfg = FxData.unwrap(raw)
			select(data.working_default("tracers"))

	# Chooses the option (T1..; until Alex does, the data's working default).
	func select(option_name: String) -> void:
		var opts: Variant = cfg.get("options")
		if opts is Dictionary and (opts as Dictionary).get(option_name) is Dictionary:
			name = option_name
			opt = (opts as Dictionary)[option_name]
		else:
			push_error("FxTracer: fx.json tracers has no option '%s'" % option_name)

	func option_names() -> Array:
		var out: Array = []
		var opts: Variant = cfg.get("options")
		if opts is Dictionary:
			for k: String in opts:
				out.append(k)
		return out

	# The seconds a round takes to fly its line, in the selected option (the feed leads the target by what it flies in that time).
	func flight_s() -> float:
		return FxData.f(FxData.grp(opt, "timing"), "flight_s") if not opt.is_empty() else 0.0

	func enabled() -> bool:
		return not cfg.is_empty() and bool(cfg.get("enabled", false)) and not opt.is_empty()

	# Whether a weapon id (data/units/*.json weapons[].id) draws a tracer: its round's tracer flag (data/sim/rounds.json), while tracers are on.
	func is_weapon(weapon: String) -> bool:
		return enabled() and rounds.weapon_tracer(weapon)

	# Whether the fog lets the layer show this shot (the data's policy; the feed says what the player sees).
	func shown(seen_shooter: bool, seen_target: bool) -> bool:
		var mode := str(FxData.grp(cfg, "fog").get("shown_when", "shooter_seen"))
		match mode:
			"always":
				return true
			"either_seen":
				return seen_shooter or seen_target
		return seen_shooter

	func clear() -> void:
		records.clear()
		_seen.clear()
		_next_id = 0

	# One tracer for one fire event. Returns whether a record was made (false: off, not a tracer weapon, out of sight, a
	# shot already drawn). `muzzle`, `centre`, `aim` are world metres (the event's x/y, the shooter's centre, the event's tx/ty).
	func add(world_seed: int, shot_id: String, weapon: String, muzzle: Vector2, centre: Vector2, aim: Vector2, aim_size_m: float, t: float, hit: bool, accent: String = "", draw_k: float = 1.0, seen_shooter: bool = true, seen_target: bool = true) -> bool:
		if not is_weapon(weapon) or not shown(seen_shooter, seen_target) or _seen.has(shot_id):
			return false
		_seen[shot_id] = true
		var rng := Mulberry32.new(FxBake.seed_of(world_seed, shot_id, "tracer"))
		var aimg := FxData.grp(cfg, "aim")
		var size := maxf(aim_size_m, 1.0)
		var off := Vector2.ZERO
		var over := 0.0
		var dir := aim - muzzle
		dir = dir.normalized() if dir.length() > 1e-6 else Vector2.RIGHT
		if hit:
			# on the airframe: a point inside a disc of hit_spread x the target's size
			off = Vector2.from_angle(rng.next() * TAU) * sqrt(rng.next()) * FxData.f(aimg, "hit_spread") * size
		else:
			# beside it, on a side picked by the event, between miss_min and miss_max of the target's size from its centre
			var side := -1.0 if rng.next() < 0.5 else 1.0
			var mag := lerpf(FxData.f(aimg, "miss_min"), FxData.f(aimg, "miss_max"), rng.next()) * size
			off = Vector2(-dir.y, dir.x) * side * mag
			over = FxData.f(aimg, "miss_overshoot") * (0.6 + 0.8 * rng.next())
		_next_id += 1
		var rec := {
			"id": _next_id, "shot": shot_id, "weapon": weapon, "born": t, "life": FxData.f(FxData.grp(opt, "timing"), "life_s"),
			"muzzle": muzzle, "centre": centre, "aim": aim, "off": off, "over": over, "hit": hit, "accent": accent,
			"draw_k": draw_k, "seed": FxBake.seed_of(world_seed, shot_id, "dash"),
		}
		records.append(rec)
		var cap := int(FxData.grp(cfg, "limits").get("max_records", 96))
		while records.size() > cap:
			records.remove_at(0)
		return true

	# The line of fire in world metres with the drawn-scale rules applied (k = the layer's true_scale): from the muzzle (its
	# offset from the shooter's centre scaled) to the end (a hit: on the target; a miss: past it).
	func line_world(rec: Dictionary, k: float) -> Dictionary:
		var kd := k * float(rec["draw_k"])
		var centre: Vector2 = rec["centre"]
		var a := centre + ((rec["muzzle"] as Vector2) - centre) * kd
		var aim_pt: Vector2 = (rec["aim"] as Vector2) + (rec["off"] as Vector2) * k
		var b := aim_pt
		if not bool(rec["hit"]):
			b = a + (aim_pt - a) * (1.0 + float(rec["over"]))
		return {"a": a, "b": b}

	# {alive, age, u (0..1 of its life), head (0..1 how far along the line the round has flown), alpha} at game time t.
	func state(rec: Dictionary, t: float) -> Dictionary:
		var age := t - float(rec["born"])
		var life := float(rec["life"])
		if age < 0.0 or age >= life:
			return {"alive": false}
		var tm := FxData.grp(opt, "timing")
		var u := age / maxf(life, 1e-6)
		return {"alive": true, "age": age, "u": u,
			"head": clampf(age / maxf(FxData.f(tm, "flight_s"), 1e-3), 0.0, 1.0),
			"alpha": fade(u, FxData.f(tm, "hold_frac"), FxData.f(tm, "fade_power"))}

	# 1 while u <= hold, then falling to 0 at u = 1 along (1 - x)^power.
	static func fade(u: float, hold: float, power: float) -> float:
		if u <= hold:
			return 1.0
		return pow(clampf(1.0 - (u - hold) / maxf(1.0 - hold, 1e-6), 0.0, 1.0), power)

	func live_count(t: float) -> int:
		var n := 0
		for rec in records:
			if bool(state(rec, t)["alive"]):
				n += 1
		return n

	# Forgets what is long dead (past its end by 10 s at `t`).
	func prune(t: float) -> void:
		var keep: Array[Dictionary] = []
		for rec in records:
			if t <= float(rec["born"]) + float(rec["life"]) + 10.0:
				keep.append(rec)
			else:
				_seen.erase(str(rec["shot"]))
		records = keep

# --- Drawing --------------------------------------------------------------------------------------------------------------------

# Every live tracer at game time `now`, on `item` (a CanvasItem in the screen-space parent the host's markers use). Returns how
# many were drawn. `mapping` is the layer's UiMapping, `style` its FxStyle (colour roles), `true_scale` the layer's.
static func draw_all(item: CanvasItem, book: Book, mapping: RefCounted, style: RefCounted, true_scale: float, now: float, view: Rect2) -> int:
	if book == null or book.records.is_empty() or not book.enabled():
		return 0
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	var n := 0
	for rec in book.records:
		var st := book.state(rec, now)
		if not bool(st["alive"]):
			continue
		var ln := book.line_world(rec, true_scale)
		var a: Vector2 = mapping.world_to_screen(ln["a"])
		var b: Vector2 = mapping.world_to_screen(ln["b"])
		var box := Rect2(a, Vector2.ZERO).expand(b).grow(10.0)
		if not view.intersects(box):
			continue
		var ppm: float = mapping.px_per_m(rec["centre"]) * true_scale * float(rec["draw_k"])
		draw_one(item, book, style, rec, st, a, b, ppm)
		n += 1
	return n

# One tracer, from screen point a (the muzzle) to b (its end), `ppm` drawn px per metre.
static func draw_one(item: CanvasItem, book: Book, style: RefCounted, rec: Dictionary, st: Dictionary, a: Vector2, b: Vector2, ppm: float) -> void:
	var o := book.opt
	var length := a.distance_to(b)
	if length < 1.0:
		return
	var dir := (b - a) / length
	var nrm := Vector2(-dir.y, dir.x)
	var head_len := length * float(st["head"])
	if head_len < 0.5:
		return
	var al: float = st["alpha"]
	var col := FxData.grp(o, "colour")
	var core := _role(style, FxData.s(col, "core_role"), str(rec["accent"]), al)
	var edge := _role(style, FxData.s(col, "edge_role"), str(rec["accent"]), al)
	var halo := _role(style, FxData.s(col, "halo_role"), str(rec["accent"]), al)
	var halo_px := FxData.f(col, "halo_px")
	match FxData.s(o, "form"):
		"dashes":
			_dashes(item, o, rec, st, a, dir, nrm, length, head_len, ppm, core, halo, halo_px)
		"streak":
			var trace := _role(style, FxData.s(FxData.grp(o, "streak"), "trace_role"), str(rec["accent"]), al)
			_streak(item, o, a, dir, nrm, length, head_len, ppm, core, edge, trace, halo, halo_px)
		"dots":
			_dots(item, o, rec, st, a, dir, nrm, length, head_len, ppm, core, halo, halo_px)
	if o.has("marks") and float(st["head"]) >= 1.0:
		_marks(item, FxData.grp(o, "marks"), bool(rec["hit"]), b, dir, nrm, core, halo, halo_px)

# A colour role (FxStyle), "@side" in its name taken as the shooter's accent ("tracer.@side" -> "tracer.side_a"); "" is no colour.
static func _role(style: RefCounted, role: String, accent: String, alpha: float) -> Color:
	if role == "":
		return Color(0, 0, 0, 0)
	var r := role.replace("@side", accent if accent != "" else "side_a")
	var c: Color = style.call("color", r)
	return Color(c.r, c.g, c.b, c.a * alpha)

# A small deterministic number in [0, 1) from a seed and an index (integer arithmetic only: the same on every peer).
static func _hash(seed_v: int, i: int) -> float:
	var h: int = (seed_v * 374761393 + i * 668265263) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float((h ^ (h >> 16)) & 0xFFFF) / 65536.0

# A train of short ink dashes along the line, swept out to the head, flowing outward a little, thinning toward the far end.
static func _dashes(item: CanvasItem, o: Dictionary, rec: Dictionary, st: Dictionary, a: Vector2, dir: Vector2, nrm: Vector2, length: float, head_len: float, ppm: float, core: Color, halo: Color, halo_px: float) -> void:
	var g := FxData.grp(o, "dashes")
	var dash := maxf(FxData.f(g, "dash_m") * ppm, FxData.f(g, "dash_min_px"))
	var gap := maxf(FxData.f(g, "gap_m") * ppm, FxData.f(g, "gap_min_px"))
	var pitch := dash + gap
	var phase := fposmod(float(st["age"]) * FxData.f(g, "flow_mps") * ppm, pitch)
	var jitter := FxData.f(g, "jitter_px")
	var tail_fade := FxData.f(g, "tail_fade")
	var seed_v: int = rec["seed"]
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var hcols := PackedColorArray()
	var i := 0
	while true:
		var s0 := -phase + float(i) * pitch
		if s0 >= head_len:
			break
		var s1 := minf(s0 + dash, head_len)
		s0 = maxf(s0, 0.0)
		if s1 - s0 > 0.4:
			var j := (_hash(seed_v, i) - 0.5) * 2.0 * jitter
			var fade := 1.0 - tail_fade * clampf(0.5 * (s0 + s1) / length, 0.0, 1.0)
			pts.append(a + dir * s0 + nrm * j)
			pts.append(a + dir * s1 + nrm * j)
			cols.append(Color(core.r, core.g, core.b, core.a * fade))
			hcols.append(Color(halo.r, halo.g, halo.b, halo.a * fade))
		i += 1
	if pts.is_empty():
		return
	var w := FxData.f(FxData.grp(o, "widths"), "width_px")
	if halo_px > 0.0 and halo.a > 0.0:
		item.draw_multiline_colors(pts, hcols, w + 2.0 * halo_px, true)
	item.draw_multiline_colors(pts, cols, w, true)

# A bright comet flying out along the line (a tapered body, blunt head, an ink edge if the option has one), the thin line of its
# passage left behind it.
static func _streak(item: CanvasItem, o: Dictionary, a: Vector2, dir: Vector2, nrm: Vector2, length: float, head_len: float, ppm: float, core: Color, edge: Color, trace: Color, halo: Color, halo_px: float) -> void:
	var g := FxData.grp(o, "streak")
	var wd := FxData.grp(o, "widths")
	var seg := maxf(FxData.f(g, "streak_m") * ppm, FxData.f(g, "streak_min_px"))
	var t1 := head_len
	var t0 := maxf(0.0, t1 - seg)
	var trace_w := FxData.f(g, "trace_px")
	var trace_a := FxData.f(g, "trace_alpha")
	if trace_w > 0.0 and trace_a > 0.0 and t0 > 0.5:
		# the line of passage is fainter toward the gun (trace_fade: how much of its strength it has lost there), full where the streak is
		var fade := clampf(FxData.f(g, "trace_fade"), 0.0, 1.0)
		var steps := clampi(int(t0 / 40.0) + 2, 2, 14)
		var tp := PackedVector2Array()
		var tcs := PackedColorArray()
		var hcs := PackedColorArray()
		for k in steps + 1:
			var u := float(k) / float(steps)
			var m := trace_a * (1.0 - fade * (1.0 - u))
			tp.append(a + dir * (t0 * u))
			tcs.append(Color(trace.r, trace.g, trace.b, trace.a * m))
			hcs.append(Color(halo.r, halo.g, halo.b, halo.a * m))
		if halo_px > 0.0 and halo.a > 0.0:
			item.draw_polyline_colors(tp, hcs, trace_w + 2.0 * halo_px, true)
		item.draw_polyline_colors(tp, tcs, trace_w, true)
	if t1 - t0 < 0.6:
		return
	var hw := FxData.f(wd, "width_px") * 0.5
	var pw := FxData.f(g, "taper_pow")
	var n := 8
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for k in n + 1:
		var u := float(k) / float(n)
		var s := lerpf(t0, t1, u)
		# a bullet: thin at the tail, full near the head, rounding off at the very end
		var w := hw * pow(u, pw) * (1.0 - 0.55 * smoothstep(0.82, 1.0, u))
		left.append(a + dir * s + nrm * w)
		right.append(a + dir * s - nrm * w)
	var poly := PackedVector2Array(left)
	for k in range(n, -1, -1):
		poly.append(right[k])
	if halo_px > 0.0 and halo.a > 0.0:
		var hl := PackedVector2Array()
		var hr := PackedVector2Array()
		for k in n + 1:
			var u2 := float(k) / float(n)
			var s2 := lerpf(t0, t1, u2)
			var w2 := hw * pow(u2, pw) * (1.0 - 0.55 * smoothstep(0.82, 1.0, u2)) + halo_px
			hl.append(a + dir * s2 + nrm * w2)
			hr.append(a + dir * s2 - nrm * w2)
		var hpoly := PackedVector2Array(hl)
		for k in range(n, -1, -1):
			hpoly.append(hr[k])
		item.draw_colored_polygon(hpoly, halo)
	item.draw_colored_polygon(poly, core)
	var edge_w := FxData.f(wd, "edge_px")
	if edge.a > 0.0 and edge_w > 0.0:
		item.draw_polyline(left, edge, edge_w, true)
		item.draw_polyline(right, edge, edge_w, true)

# Bunches of ink dots along the line, appearing out to the head and fading from the muzzle end outward.
static func _dots(item: CanvasItem, o: Dictionary, rec: Dictionary, st: Dictionary, a: Vector2, dir: Vector2, nrm: Vector2, length: float, head_len: float, ppm: float, core: Color, halo: Color, halo_px: float) -> void:
	var g := FxData.grp(o, "dots")
	var tm := FxData.grp(o, "timing")
	var pitch := maxf(FxData.f(g, "pitch_m") * ppm, FxData.f(g, "pitch_min_px"))
	var bunch := maxi(FxData.i(g, "bunch"), 1)
	var bgap := maxf(FxData.f(g, "bunch_gap_m") * ppm, FxData.f(g, "bunch_gap_min_px"))
	var r_max := FxData.f(g, "dot_px")
	var r_min := FxData.f(g, "dot_min_px")
	var stagger := clampf(FxData.f(g, "stagger"), 0.0, 0.95)
	var life := float(rec["life"])
	var hold := FxData.f(tm, "hold_frac")
	var power := FxData.f(tm, "fade_power")
	var seed_v: int = rec["seed"]
	var age: float = st["age"]
	var s := 0.0
	var k := 0
	while s <= head_len:
		var u := s / length
		# the near dots fade first: dot k's clock runs behind by stagger x life x its share of the line
		var dur := life * (1.0 - stagger)
		var fa := Book.fade(clampf((age - stagger * life * u) / maxf(dur, 1e-6), 0.0, 1.0), hold, power)
		if fa > 0.01:
			var jr := _hash(seed_v, k)
			var r := lerpf(r_max, r_min, u) * (0.75 + 0.5 * jr)
			var p := a + dir * s + nrm * ((_hash(seed_v, k + 977) - 0.5) * 2.0 * FxData.f(g, "jitter_px"))
			if halo_px > 0.0 and halo.a > 0.0:
				item.draw_circle(p, r + halo_px, Color(halo.r, halo.g, halo.b, halo.a * fa / maxf(float(st["alpha"]), 1e-3)))
			item.draw_circle(p, r, Color(core.r, core.g, core.b, core.a * fa / maxf(float(st["alpha"]), 1e-3)))
		k += 1
		s += pitch + (bgap if k % bunch == 0 else 0.0)

# A small mark where the round ended: a dot on the airframe for a hit, a short cross-tick for a miss.
static func _marks(item: CanvasItem, g: Dictionary, hit: bool, b: Vector2, dir: Vector2, nrm: Vector2, core: Color, halo: Color, halo_px: float) -> void:
	if hit:
		var r := FxData.f(g, "hit_dot_px")
		if r > 0.0:
			if halo_px > 0.0 and halo.a > 0.0:
				item.draw_circle(b, r + halo_px, halo)
			item.draw_circle(b, r, core)
	else:
		var half := FxData.f(g, "miss_tick_px")
		if half > 0.0:
			var w := FxData.f(g, "miss_tick_w_px")
			if halo_px > 0.0 and halo.a > 0.0:
				item.draw_line(b - nrm * half, b + nrm * half, halo, w + 2.0 * halo_px, true)
			item.draw_line(b - nrm * half, b + nrm * half, core, w, true)
