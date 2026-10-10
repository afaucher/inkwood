extends Node2D

# THE EFFECTS LAYER (Track X): damage smoke, the three phases of a death, and what
# stays. The interface mounts it once Alex has chosen the look (variants/damage-smoke/,
# variants/crash-explosion/); until then it runs the data's working defaults.
#
#   var fx := FxLayer.new()
#   parent.add_child(fx)                       # or fx.mount(below_planes, above_planes)
#   fx.setup(host_mapping)                     # a Transform2D, or an object with world_to_screen / screen_to_world
#   fx.true_scale = k                          # the plane's drawn px per metre / the map's (marker.true_scale), each frame
#   fx.set_time(game_seconds)                  # each frame; game time advances only while a resolve plays
#
#   fx.emit_damage_smoke(unit_id, world_pos, height_m, health_fraction, t, size_m, heading)
#   fx.falling(unit_id, world_pos, height_m, t, size_m, heading)     # each frame while out of control
#   fx.explode_midair(unit_id, world_pos, height_m, t, size_m, heading)
#   fx.impact(unit_id, ground_pos, t, size_m, heading)
#   fx.add_scar(unit_id, ground_pos, t, size_m)                      # restore one: a game in progress
#   fx.clear()                                                       # the game ends
#
# FROM THE SIM'S EVENTS (scripts/sim/combat.gd; game time t = (turn - 1) x turn_seconds + the event's t):
#   hit   -> the unit's health fraction (health / its def's health) for emit_damage_smoke, each frame
#            of the playback while 0 < health < full (a full-health plane makes no smoke)
#   down, fate "exploded"        -> explode_midair(unit, Vector2(x, y), height above ground, t, size_m, heading)
#                                   and the marker layer stops drawing the unit from down_at
#   down, fate "out_of_control"  -> falling(unit, pos, height above ground, t, size_m, heading) EVERY FRAME
#                                   from World.sample while it falls (the unit is still drawn by the marker
#                                   layer: its path, heading and falling height are the sim's)
#   crash -> impact(unit, Vector2(x, y), t, size_m, heading); the marker layer stops drawing the unit then
# `height above ground` is the sim's height_m minus the terrain under (x, y) for a sea-level band, or the
# sample's own height for a fall (the sim's fall height is already above the ground).
#
# AN EXPLOSION, THEN A SMOKING WRECK (Alex): impact() gives the flash and burst, a billow, the wreck and
# its scar (they stay), and a column of smoke from the wreck that keeps coming for about twelve turns,
# thinning and greying as it goes (fx.json crash.options.X.impact.smolder).
#
# WHY SCREEN SPACE, THROUGH THE HOST'S MAPPING (as the unit markers): the planes are
# drawn at their own scale (a 9 m fighter about 36 px at zoom 1 whatever the map scale),
# and what they leave behind is sized by the same drawn scale -- a puff is the fraction
# of its plane's size it always was -- while WHERE it is stays a world position that
# the camera moves. In map space the effects would zoom with the map and be blurry or
# huge when the planes are not; here the ink stays a true pixel width, baked at the
# drawn scale through the drawing layer (InkCanvas: pen, supersampling, premultiplied
# alpha) and re-baked only when the scale drifts past rebake_ratio, as the marker art
# is. Heights are metres above the ground under the thing (the host subtracts the
# terrain, as UnitMarkerLayer.height_above_ground does); a shadow sits 1% of that height
# away from the thing along the light, scaled by true_scale so the gap follows the drawn
# size (Alex, plane-shadow-gap).
#
# Four passes, bottom to top: ground (scars, landed pieces, embers on a scar), shadows
# (one CanvasGroup at the map's shadow strength), air (smoke at altitude, pieces in
# flight), top (bursts, flames on falling planes). Mounted as one node every pass sits
# above the planes; fx.mount(below, above) puts the first three below the unit markers'
# planes and `top` above them, which is where smoke belongs (the plane flies in front of
# its own smoke).
#
# DETERMINISTIC: every puff, piece and scar comes from (world_seed, unit, game time) alone
# (fx_field.gd); two runs of the same calls draw the same frames.

const UiMapping = preload("res://scripts/ui/ui_mapping.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxField = preload("res://scripts/fx/fx_field.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPass = preload("res://scripts/fx/fx_pass.gd")
const FxShadowPass = preload("res://scripts/fx/fx_shadow_pass.gd")

var style: FxStyle = null
var data: FxData = null
var field: FxField = null
var mapping: UiMapping = null

var true_scale: float = 1.0          # the plane's drawn px per metre / the mapping's, set by the host
var now: float = 0.0                 # game seconds
var show_shadows: bool = true        # the ground shadow of smoke and pieces (the board compares it off)

var ground_node: Node2D = null
var shadow_node: CanvasGroup = null
var air_node: Node2D = null
var top_node: Node2D = null

var _puff_sets: Dictionary = {}
var _burst_sets: Dictionary = {}
var _parts_sets: Dictionary = {}
var _bakes: int = 0
var _bake_ms: float = 0.0
var _ratio: float = 1.15
var _draws: int = 0
var _built := false

func _init() -> void:
	name = "FxLayer"

func _ready() -> void:
	_build()

func _build() -> void:
	if _built:
		return
	_built = true
	if style == null:
		style = FxStyle.shared() as FxStyle
	if data == null:
		data = FxData.shared() as FxData
	if field == null:
		field = FxField.new(data)
	_ratio = data.common_num("rebake_ratio")
	ground_node = _make_pass("ground")
	var sg := FxShadowPass.new()
	sg.name = "Shadows"
	sg.layer = self
	var tint: Color = style.palette["shadow"]
	sg.self_modulate = Color(1.0, 1.0, 1.0, style.param("shadow_strength"))
	add_child(sg)
	shadow_node = sg
	air_node = _make_pass("air")
	top_node = _make_pass("top")
	_tint = Color(tint.r, tint.g, tint.b, 1.0)

var _tint := Color.WHITE

func _make_pass(kind: String) -> Node2D:
	var n := FxPass.new()
	n.name = kind.capitalize()
	n.layer = self
	n.kind = kind
	add_child(n)
	return n

# --- Setup ---------------------------------------------------------------------------------------------

func setup(host_mapping: Variant, world_seed: int = -1) -> void:
	_build()
	set_mapping(host_mapping)
	if world_seed >= 0:
		field.world_seed = world_seed
	else:
		field.world_seed = style.scene_seed

func set_mapping(host_mapping: Variant) -> void:
	mapping = UiMapping.from(host_mapping) as UiMapping

# Chooses the options (until Alex does, the data's working defaults); drops the baked art.
func select(smoke: String, crash: String, crash_smoke: String = "") -> void:
	_build()
	field.select(smoke, crash, crash_smoke)
	release_art()

# The fire machinery's switch (data: fx.json fire_switch.enabled, off since Alex's "no fire for now").
# Turning it on makes flames, embers, the flash and the fireball come back; it drops the baked art.
func set_fire(on: bool) -> void:
	_build()
	if style.fire_on != on:
		style.fire_on = on
		field.fire_on = on
		release_art()

func is_fire() -> bool:
	_build()
	return style.fire_on

# Puts the below-the-planes passes under `below` and `top` under `above` (both Nodes in the
# screen-space parent the markers use; `above` null leaves everything in one place).
func mount(below: Node, above: Node = null) -> void:
	_build()
	if get_parent() != below:
		if get_parent() != null:
			get_parent().remove_child(self)
		below.add_child(self)
	if above != null:
		top_node.reparent(above, false)

# --- Time -----------------------------------------------------------------------------------------------------

func set_time(t: float) -> void:
	now = t
	queue_redraws()

func advance(dt: float) -> void:
	set_time(now + dt)

func queue_redraws() -> void:
	if not _built:
		return
	ground_node.queue_redraw()
	shadow_node.queue_redraw()
	air_node.queue_redraw()
	top_node.queue_redraw()

func _process(_delta: float) -> void:
	# a camera that moves or zooms is followed with no call, as the markers are
	if mapping != null and mapping.is_live() and _anything():
		queue_redraws()

func _anything() -> bool:
	return not (field.puffs.is_empty() and field.bursts.is_empty() and field.scars.is_empty() and field.debris.is_empty() and field.riders.is_empty())

# --- The calls the interface makes -----------------------------------------------------------------------------------

func emit_damage_smoke(unit_id: String, world_pos: Vector2, height_m: float, health_fraction: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
	_build()
	return field.emit_damage_smoke(unit_id, world_pos, height_m, health_fraction, t, size_m, heading)

func emit_path(unit_id: String, sampler: Callable, t0: float, t1: float, health_fraction: float, size_m: float = 9.0) -> int:
	_build()
	return field.emit_path(unit_id, sampler, t0, t1, health_fraction, size_m)

func falling(unit_id: String, world_pos: Vector2, height_m: float, t: float, size_m: float = 9.0, heading: float = NAN) -> int:
	_build()
	return field.ride(unit_id, world_pos, height_m, t, size_m, heading)

func explode_midair(unit_id: String, world_pos: Vector2, height_m: float, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
	_build()
	field.explode_midair(unit_id, world_pos, height_m, t, size_m, heading)

func impact(unit_id: String, ground_pos: Vector2, t: float, size_m: float = 9.0, heading: float = NAN) -> void:
	_build()
	field.impact(unit_id, ground_pos, t, size_m, heading)

func add_scar(unit_id: String, ground_pos: Vector2, t: float, size_m: float = 9.0, rot: float = 0.0, seed_v: int = 0) -> void:
	_build()
	field.add_scar(unit_id, ground_pos, t, size_m, rot, seed_v)

# The game ends or restarts: every puff, burst, piece and scar goes. The baked art stays
# (it is the same art next game); release_art() drops it too.
func clear() -> void:
	_build()
	field.clear()
	now = 0.0
	queue_redraws()

func release_art() -> void:
	_puff_sets.clear()
	_burst_sets.clear()
	_parts_sets.clear()

func stats() -> Dictionary:
	var c := field.counts()
	c["baked_sets"] = _puff_sets.size() + _burst_sets.size() + _parts_sets.size()
	c["bakes"] = _bakes
	c["bake_ms"] = _bake_ms
	c["draws"] = _draws
	return c

# --- Baking (on first need, at the drawn scale) -----------------------------------------------------------------------

# The drawn px per metre of a plane at `at`: the mapping's scale x true_scale.
func drawn_ppm(at: Vector2) -> float:
	if mapping == null:
		return 1.0
	return mapping.px_per_m(at) * true_scale

# A bake scale on a geometric grid of rebake_ratio, so a slow zoom bakes at each step once.
func quantize(ppm: float) -> float:
	var lo := data.common_num("min_bake_ppm")
	var hi := data.common_num("max_bake_ppm")
	var q := roundi(log(clampf(ppm, lo, hi)) / log(_ratio))
	return pow(_ratio, q)

func _size_class(size_m: float) -> int:
	return maxi(1, roundi(size_m))

func _puffs_for(set_id: String, ppm_q: float, size_m: float) -> FxPuff.PuffSet:
	var o: Dictionary = field.set_defs.get(set_id, field.smoke_o)
	var key := "%s|%.3f|%d" % [set_id, ppm_q, _size_class(size_m)]
	if not _puff_sets.has(key):
		var t0 := Time.get_ticks_usec()
		_puff_sets[key] = FxPuff.bake_set(style, o, ppm_q, float(_size_class(size_m)))
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_puff_sets)
	return _puff_sets[key]

func _burst_for(phase: String, ppm_q: float, size_m: float, radius_m: float) -> FxBurst.BurstSet:
	var key := "%s|%.3f|%d|%.2f|f%d" % [phase, ppm_q, _size_class(size_m), radius_m, int(style.fire_on)]
	if not _burst_sets.has(key):
		var t0 := Time.get_ticks_usec()
		var b := FxData.grp(field.crash_o, "burst")
		_burst_sets[key] = FxBurst.bake_burst(style, b, radius_m, ppm_q, phase == "impact", FxBake.seed_of(field.crash_name, phase, _size_class(size_m)))
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_burst_sets)
	return _burst_sets[key]

func _parts_for(ppm_q: float, size_m: float) -> FxBurst.PartsSet:
	var key := "%.3f|%d|f%d" % [ppm_q, _size_class(size_m), int(style.fire_on)]
	if not _parts_sets.has(key):
		var t0 := Time.get_ticks_usec()
		_parts_sets[key] = FxBurst.bake_parts(style, field.crash_o, float(_size_class(size_m)), ppm_q, null, FxBake.seed_of(field.crash_name, "parts", _size_class(size_m)))
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_parts_sets)
	return _parts_sets[key]

func _trim(cache: Dictionary) -> void:
	while cache.size() > 24:
		cache.erase(cache.keys()[0])

# --- Drawing ------------------------------------------------------------------------------------------------------------

func draw_pass(item: CanvasItem, kind: String) -> void:
	if mapping == null or field == null or not FxBake.can_bake():
		return
	var view := Rect2(Vector2.ZERO, get_viewport_rect().size).grow(96.0)
	match kind:
		"ground":
			_draw_ground(item, view)
		"shadows":
			if show_shadows:
				_draw_shadows(item, view)
		"air":
			_draw_air(item, view)
		"top":
			_draw_top(item, view)
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# Draws `tex` with its `origin` at `pos`, rotated and scaled, tinted.
func _blit(item: CanvasItem, tex: Texture2D, origin: Vector2, pos: Vector2, rot: float, sc: float, mod: Color) -> void:
	if tex == null:
		return
	item.draw_set_transform(pos, rot, Vector2(sc, sc))
	item.draw_texture(tex, -origin, mod)
	_draws += 1

func _shadow_px(world_pos: Vector2, h: float) -> Vector2:
	if h <= 0.0:
		return Vector2.ZERO
	return mapping.screen_delta(world_pos, style.plane_shadow_offset_m(h) * true_scale)

func _draw_ground(item: CanvasItem, view: Rect2) -> void:
	for s in field.scars:
		var a := field.scar_alpha(s, now)
		if a <= 0.0:
			continue
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp)
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _parts_for(q, float(s["size_m"]))
		if ps == null or ps.scars.is_empty():
			continue
		var tex: Texture2D = ps.scars[int(s["variant"]) % ps.scars.size()]
		if not view.has_point(sp):
			continue
		_blit(item, tex, ps.scar_origin, sp, mapping.screen_angle(wp, float(s["rot"])), ppm / q, Color(1.0, 1.0, 1.0, a))
	for d in field.debris:
		var st := field.debris_state(d, now)
		if not bool(st["alive"]) or not bool(st["landed"]):
			continue
		var wp: Vector2 = st["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _parts_for(q, float(d["size_m"]))
		if ps == null or ps.shards.is_empty():
			continue
		var v := int(d["variant"]) % ps.shards.size()
		_blit(item, ps.shards[v], ps.shard_origin[v], sp, float(st["rot"]), ppm / q, Color(1.0, 1.0, 1.0, float(st["alpha"])))
	_draw_scar_embers(item, view)

# The embers glowing on a scar are puffs of kind scar_ember; they sit on the ground.
func _draw_scar_embers(item: CanvasItem, view: Rect2) -> void:
	for pair in field.alive_puffs(now):
		var p: Dictionary = pair[0]
		if p["kind"] != "scar_ember":
			continue
		var s: Dictionary = pair[1]
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _parts_for(q, float(p["size_m"]))
		if ps == null or ps.ember == null:
			continue
		_blit(item, ps.ember, ps.ember_origin, sp, 0.0, ppm / q, Color(1.0, 1.0, 1.0, float(s["alpha"])))

func _draw_shadows(item: CanvasItem, view: Rect2) -> void:
	for pair in field.alive_puffs(now):
		var p: Dictionary = pair[0]
		var s: Dictionary = pair[1]
		if p["kind"] == "ember" or p["kind"] == "scar_ember":
			continue
		var o: Dictionary = field.set_defs.get(p["set"], field.smoke_o)
		if not FxPuff.casts_shadow(o, int(p["tone"])):
			continue
		var wp: Vector2 = s["pos"]
		var off := _shadow_px(wp, float(s["h"]))
		if off.length() < data.common_num("min_shadow_px"):
			continue
		var sp := mapping.world_to_screen(wp) + off
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _puffs_for(str(p["set"]), q, float(p["size_m"]))
		if ps == null:
			continue
		var tone: int = p["tone"]
		var v := int(p["variant"]) % ps.variants
		# shadows are opaque inside the group; a puff that is mostly gone casts no shadow
		if float(s["alpha"]) < 0.25:
			continue
		var sc := (float(p["r_m"]) * ppm) / float(ps.radius_px[tone]) * float(s["scale"])
		_blit(item, (ps.mask[tone] as Array)[v], ps.origin[tone], sp, _puff_rot(o, p, wp), sc, _tint)
	for d in field.debris:
		var st := field.debris_state(d, now)
		if not bool(st["alive"]) or bool(st["landed"]):
			continue
		var wp: Vector2 = st["pos"]
		var off := _shadow_px(wp, float(st["h"]))
		var sp := mapping.world_to_screen(wp) + off
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _parts_for(q, float(d["size_m"]))
		if ps == null or ps.shard_masks.is_empty():
			continue
		var v := int(d["variant"]) % ps.shard_masks.size()
		_blit(item, ps.shard_masks[v], ps.shard_origin[v], sp, float(st["rot"]), ppm / q, _tint)

# A stretched puff is drawn along the way it was flying (its `dir`, a world heading); a round one is not turned.
func _puff_rot(o: Dictionary, p: Dictionary, wp: Vector2) -> float:
	if FxPuff.stretch_xy(o) == Vector2.ONE:
		return 0.0
	return mapping.screen_angle(wp, float(p.get("dir", 0.0)))

func _draw_air(item: CanvasItem, view: Rect2) -> void:
	for pair in field.alive_puffs(now):
		var p: Dictionary = pair[0]
		var s: Dictionary = pair[1]
		var kind: String = p["kind"]
		if kind == "scar_ember":
			continue
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		if kind == "ember":
			var pe := _parts_for(q, float(p["size_m"]))
			if pe != null and pe.ember != null:
				_blit(item, pe.ember, pe.ember_origin, sp, 0.0, ppm / q, Color(1.0, 1.0, 1.0, float(s["alpha"])))
			continue
		var ps := _puffs_for(str(p["set"]), q, float(p["size_m"]))
		if ps == null:
			continue
		var tone: int = p["tone"]
		var v := int(p["variant"]) % ps.variants
		var sc := (float(p["r_m"]) * ppm) / float(ps.radius_px[tone]) * float(s["scale"])
		var po: Dictionary = field.set_defs.get(p["set"], field.smoke_o)
		var stage := mini(FxPuff.stage_of(po, float(s["u"])), ps.stages - 1)
		_blit(item, (ps.tex[tone] as Array)[v + ps.variants * stage], ps.origin[tone], sp, _puff_rot(po, p, wp), sc, Color(1.0, 1.0, 1.0, float(s["alpha"])))
	for d in field.debris:
		var st := field.debris_state(d, now)
		if not bool(st["alive"]) or bool(st["landed"]):
			continue
		var wp: Vector2 = st["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var ps := _parts_for(q, float(d["size_m"]))
		if ps == null or ps.shards.is_empty():
			continue
		var v := int(d["variant"]) % ps.shards.size()
		_blit(item, ps.shards[v], ps.shard_origin[v], sp, float(st["rot"]), ppm / q, Color.WHITE)

func _draw_top(item: CanvasItem, view: Rect2) -> void:
	# the flames on planes the sim is flying out of control
	var fall := FxData.grp(field.crash_o, "falling")
	var fl := FxData.grp(fall, "flame")
	if style.fire_on and FxData.b(fl, "enabled"):
		for id: String in field.riders:
			var r: Dictionary = field.riders[id]
			if absf(float(r["t"]) - now) > 0.25:
				continue
			var wp: Vector2 = r["pos"]
			var sp := mapping.world_to_screen(wp)
			if not view.has_point(sp):
				continue
			var ppm := drawn_ppm(wp)
			var q := quantize(ppm)
			var ps := _parts_for(q, float(r["size_m"]))
			if ps == null or ps.flame.is_empty():
				continue
			var hd: float = r["heading"]
			if is_nan(hd):
				hd = 0.0
			var screen_h := mapping.screen_angle(wp, hd)
			var back := -Vector2.from_angle(screen_h)
			var base := sp + back * float(r["size_m"]) * 0.3 * ppm
			var k := int(floor(now * FxData.f(fl, "flicker_hz")) + (hash(id) & 7)) % ps.flame.size()
			_blit(item, ps.flame[k], ps.flame_origin, base, screen_h + PI / 2.0, ppm / q, Color.WHITE)
	# the bursts, a flipbook
	for b in field.bursts:
		var k := field.burst_frame(b, now)
		if k < 0:
			continue
		var wp: Vector2 = b["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var bs := _burst_for(str(b["phase"]), q, float(b["size_m"]), float(b["radius_m"]))
		if bs == null or k >= bs.frames.size():
			continue
		_blit(item, bs.frames[k]["tex"], bs.origin, sp, 0.0, ppm / q, Color.WHITE)
