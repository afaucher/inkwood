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
# THE STRIKE (Track X2, 2026-10-10: flak, bombs, the radio tower; every look is a PROPOSED option in fx.json
# flak / bomb / ruin, chosen from variants/flak, variants/bomb-impact, variants/tower-ruin; fx.select_strike()):
#
#   fx.flak_burst(target_pos, height_m, t, hit, shot_id = "", size_m = 0.0)
#       A flak shell bursts near its target. Feed it from a "fire" event whose shooter is a ground unit and whose target is
#       in the air: target_pos = Vector2(ev.tx, ev.ty), height_m = the target's height ABOVE THE GROUND (the marker layer's
#       height_above_ground of the target's pose; the event's theight_m is above the sim's 0), t = the game time, hit = ev.hit.
#       A hit bursts on the target, a miss beside it (where is the effects' call). shot_id: any string that tells two shots
#       at one moment apart (ev.unit + "/" + str(ev.tick) is plenty). A dark ragged puff and a fast flash at the burst's
#       height, its shadow by the altitude rule; the puff hangs for a few turns.
#   fx.bomb_drop(unit_id, bomb_id, from_pos, height_m, t_release, to_pos, t_impact)
#       A bomb in the air, from the sim's bomb record (x0, y0, h0 above the ground, x, y; the game times of its release and
#       impact): drawn flying from release to impact with its shadow closing on it. OPTIONAL, and nearly invisible: the sim's
#       bombs keep the bomber's speed (no drag), so a stick falls in a column under the bomber and its icon hides them
#       (they are drawn over it, small); call it once per bomb when the release is seen (the record is in the bomb_release
#       event's turn, World.bombs_in_flight) only if the interface wants the dark specks.
#   fx.bomb_impact(ground_pos, t, blast_m = 45.0, unit_id = "", bomb_id = 0)
#       A bomb lands (the "bomb_impact" event: x, y, blast_m, t, bomb): a fast flash, a thick shadowed smoke burst, clods,
#       a billow, and the crater that stays for the rest of the game. The sizes follow blast_m (fractions of it, in data).
#   fx.ruin(unit_id, world_pos, t, kind = "radio_tower", size_m = 12.0, heading = 0.0)
#       The radio tower is destroyed (a "down" event, fate "destroyed", for the tower): the flash, the smoke, the mast falling
#       (or flung apart, by option), a column of smoke that thins over turns, and the ruin (crater, scorch, broken base, the
#       mast lying) that stays for the rest of the game. heading = the unit's heading (the marker's convention).
#       Any other kind (kind = "anti_aircraft_battery" for a destroyed battery, proposed) gets the flash, the smoke, the column
#       and a scorch, a pit and scraps that stay: no mast, footings or hut.
#   fx.add_crater(unit_id, ground_pos, t, blast_m, seed_v)           # restore a crater alone (a late joiner)
#   fx.add_ruin(unit_id, world_pos, t, kind, size_m, heading, seed_v) # restore a ruin alone; returns nothing (see field.add_ruin)
#       RESTORING A LATE JOINER: the strike is deterministic from (world seed, the call's arguments), so replaying
#       bomb_impact() and ruin() with their TRUE game times draws exactly what the other players saw, including the smoke
#       column of a ruin that is turns old (and the craters, which stay). The add_* calls put the bare mark down when the
#       time is not known.
#
# THE FOREST FIRE (track 'Forest fire', decision forest-fire, 2026-10-11; scripts/fx/fx_fire.gd, fx_fire_view.gd; the look is PROPOSED, a stand-in
# in data/fx/fx.json "forest_fire"):
#   fx.set_fire_feed(feed, turn_seconds = -1.0)
#       The sim's feed (world.fire.feed(): {id, x_m, y_m, r_m, lit_turn, lit_t, out_turn} for every tree ever lit) is all it needs: a column of W1
#       smoke (decision damage-smoke; no flame, decision fire-colour) rises from every tree burning at the layer's game time, appearing AT lit_t,
#       thick while the tree burns and thinning away within about a turn after its out_turn; thick smoke casts a shadow (smoke-shadow). It is
#       drawn by FxFire inside the shadows and air passes, not through the field's puffs (a grove of hundreds would crowd the planes' smoke out
#       of the field's cap), at the MAP's scale. FxFireView (the sandbox makes it when the World has a fire) hands the feed over once per fire
#       revision and the burnt-out trees to the MapView as trunks. An empty feed makes and draws nothing; clear() empties it.
#
# THE WIND (decision coastal-wind, 2026-10-11; the sim's Wind is scripts/sim/wind.gd):
#   fx.set_wind(wind)
#       `wind` is a Wind (or any object with at(game_s) -> Vector2: the air's velocity, m/s, world axes) or null. With one set ALL smoke drifts
#       with it: every puff takes its drift from wind.at(its birth game time) (a damaged plane's trail, a crash's burst, plume and wreck column, a
#       bomb's, a flak shell's and a ruin's smoke -- fx_field.gd) and a burning tree's column leans downwind by the sim's smoke.drift_s
#       (fx_fire.gd), so the smoke you see sits where the sim's untrackable zone is. Thick smoke's shadow follows the drifted puffs. With null
#       (the boards, a shot without a World) every option keeps its own data wind, exactly as before. Puffs already made keep the drift they were
#       born with; the burning trees' columns are made again from the new wind. The sandbox sets it from `world.wind` (sandbox.gd _sync_wind).
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
const FxBomb = preload("res://scripts/fx/fx_bomb.gd")
const FxRuin = preload("res://scripts/fx/fx_ruin.gd")
const FxTracer = preload("res://scripts/fx/fx_tracer.gd")
const FxFire = preload("res://scripts/fx/fx_fire.gd")

var style: FxStyle = null
var data: FxData = null
var field: FxField = null
# THE FOREST FIRE's smoke (track 'Forest fire', decision forest-fire; scripts/fx/fx_fire.gd): one column per burning tree, from the
# sim's feed (set_fire_feed). Empty feed: nothing is made or drawn and the layer is as it was.
var fire: FxFire = null
# THE WIND (decision coastal-wind): the air all smoke drifts with, or null for each option's own data wind (see set_wind).
var wind: Object = null
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
var _bomb_sets: Dictionary = {}
var _drop_sets: Dictionary = {}
var _ruin_sets: Dictionary = {}
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
	if fire == null:
		fire = FxFire.new(data)
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

# Chooses the strike's options (flak, bombs, the tower's ruin; "" keeps the current one); drops the baked art.
func select_strike(flak: String = "", bomb: String = "", ruin_option: String = "") -> void:
	_build()
	field.select_strike(flak, bomb, ruin_option)
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
	if mapping != null and mapping.is_live() and (_anything() or _tracers_live()):
		queue_redraws()

func _tracers_live() -> bool:   # (Track TR) a tracer in flight moves with the camera too
	return field.tracers != null and field.tracers.live_count(now) > 0

func _anything() -> bool:
	return fire.active() or not (field.puffs.is_empty() and field.bursts.is_empty() and field.scars.is_empty() and field.debris.is_empty() and field.riders.is_empty() \
		and field.craters.is_empty() and field.ruins.is_empty() and field.drops.is_empty() and field.splashes_live(now, _splash_life_s()) == 0)

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

# --- The strike's calls (documented in the header) ---------------------------------------------------------------------------

func flak_burst(target_pos: Vector2, height_m: float, t: float, hit: bool, shot_id: String = "", size_m: float = 0.0) -> void:
	_build()
	field.flak_burst(target_pos, height_m, t, hit, shot_id, size_m)

func bomb_drop(unit_id: String, bomb_id: int, from_pos: Vector2, height_m: float, t_release: float, to_pos: Vector2, t_impact: float) -> void:
	_build()
	field.bomb_drop(unit_id, bomb_id, from_pos, height_m, t_release, to_pos, t_impact)

func bomb_impact(ground_pos: Vector2, t: float, blast_m: float = 45.0, unit_id: String = "", bomb_id: int = 0) -> void:
	_build()
	field.bomb_impact(ground_pos, t, blast_m, unit_id, bomb_id)

func add_crater(unit_id: String, ground_pos: Vector2, t: float, blast_m: float = 45.0, seed_v: int = 0) -> void:
	_build()
	field.add_crater(unit_id, ground_pos, t, blast_m, seed_v)

func ruin(unit_id: String, world_pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0) -> void:
	_build()
	field.ruin(unit_id, world_pos, t, kind, size_m, heading)

func add_ruin(unit_id: String, world_pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0, seed_v: int = 0) -> void:
	_build()
	field.add_ruin(unit_id, world_pos, t, kind, size_m, heading, seed_v)

# A sea unit that sinks (Track BB, decision ship-sinks): the flash every destroyed unit gets, no smoke, no ruin.
func down_flash(unit_id: String, world_pos: Vector2, t: float, size_m: float) -> void:
	_build()
	field.down_flash(unit_id, world_pos, t, size_m)

# The splash where a unit goes under the water: rings in the ink (PROPOSED look, data/world/boats.json game.sunk.splash).
func splash(unit_id: String, world_pos: Vector2, t: float, size_m: float) -> void:
	_build()
	field.add_splash(unit_id, world_pos, t, size_m)

# MACHINE-GUN TRACERS (Track TR, 2026-10-11, PROPOSED; fx.json tracers, scripts/fx/fx_tracer.gd). The feed asks tracer_weapon(weapon) of a
# "fire" event (a weapon in the data's list, while tracers are on: it is then no flak burst) and calls tracer() with the event's
# fields (FxTracer.feed_event). A hit ends on the target, a miss passes beside it; it lives a short time on the playback clock.
func tracer_weapon(weapon: String) -> bool:
	_build()
	return field.tracer_book().is_weapon(weapon)

func tracer(shot_id: String, weapon: String, muzzle: Vector2, centre: Vector2, aim: Vector2, aim_size_m: float, t: float, hit: bool, accent: String = "", draw_k: float = 1.0, seen_shooter: bool = true, seen_target: bool = true) -> bool:
	_build()
	return field.tracer(shot_id, weapon, muzzle, centre, aim, aim_size_m, t, hit, accent, draw_k, seen_shooter, seen_target)

func select_tracers(option_name: String) -> void:
	_build()
	field.select_tracers(option_name)

func tracer_flight_s() -> float:   # the feed leads the target by what it flies in this time
	_build()
	return field.tracer_book().flight_s()

# THE FOREST FIRE (decision forest-fire): the sim's feed -- one Dictionary per tree ever lit, {id, x_m, y_m, r_m, lit_turn, lit_t, out_turn}
# (world.fire.feed(); fx_fire.gd's header has the meaning) -- is all the layer needs: it draws a column of W1 smoke for every tree
# burning at the layer's game time (set_time), and none for one that is lit later or has burnt out and faded. Calling it again with
# a longer feed (each resolved turn) or the same one is safe. `turn_seconds` (> 0) is the sim's; the layer's 5 otherwise.
func set_fire_feed(feed: Array, turn_seconds: float = -1.0) -> void:
	_build()
	if turn_seconds > 0.0:
		fire.set_turn_seconds(turn_seconds)
	fire.set_feed(feed)
	queue_redraws()

# THE WIND (header): the air all smoke drifts with -- a Wind, or null for today's data winds. Safe to call again with another (or the same,
# changed in place) wind.
func set_wind(w: Object) -> void:
	_build()
	wind = w
	field.wind = w
	fire.set_wind(w)
	queue_redraws()

# The game ends or restarts: every puff, burst, piece and scar goes. The baked art stays
# (it is the same art next game); release_art() drops it too.
func clear() -> void:
	_build()
	field.clear()
	fire.clear()
	now = 0.0
	queue_redraws()

func release_art() -> void:
	_puff_sets.clear()
	_burst_sets.clear()
	_parts_sets.clear()
	_bomb_sets.clear()
	_drop_sets.clear()
	_ruin_sets.clear()

func stats() -> Dictionary:
	var c := field.counts()
	c["fire_trees"] = fire.tree_count() if fire != null else 0
	c["baked_sets"] = _puff_sets.size() + _burst_sets.size() + _parts_sets.size() + _bomb_sets.size() + _drop_sets.size() + _ruin_sets.size()
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

# The flipbook of a burst record (a crash's, or the strike's flash), at one scale. The strike's flashes are drawn on the
# ground for a bomb or the tower and in the air for flak; a hit's is a different drawing from a miss's.
func _burst_for(b: Dictionary, ppm_q: float) -> FxBurst.BurstSet:
	var phase := str(b["phase"])
	var grp := str(b.get("grp", "crash"))
	var hit := bool(b.get("hit", false))
	var radius_m := float(b["radius_m"])
	var size_m := float(b["size_m"])
	var opt := field.crash_name
	match grp:
		"flak":
			opt = field.flak_name
		"bomb":
			opt = field.bomb_name
		"ruin":
			opt = field.ruin_name
	var key := "%s|%s|%s|%.3f|%d|%.2f|h%d|f%d" % [grp, opt, phase, ppm_q, _size_class(size_m), radius_m, int(hit), int(style.fire_on)]
	if not _burst_sets.has(key):
		var t0 := Time.get_ticks_usec()
		var def := field.burst_def(b)
		if grp != "crash":
			def = def.duplicate()
			def["hit"] = hit
		_burst_sets[key] = FxBurst.bake_burst(style, def, radius_m, ppm_q, phase == "impact" or phase == "bomb" or phase == "tower", FxBake.seed_of(opt, phase + str(int(hit)), _size_class(size_m)))
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_burst_sets)
	return _burst_sets[key]

# The crater, clod and bomb sprites of the bomb option at one scale, for blasts of one size class.
func _bomb_set_for(ppm_q: float, blast_m: float) -> FxBomb.BombSet:
	var key := "%s|%.3f|%d" % [field.bomb_name, ppm_q, _size_class(blast_m)]
	if not _bomb_sets.has(key):
		var t0 := Time.get_ticks_usec()
		var o := field.bomb_o
		_bomb_sets[key] = FxBomb.bake_set(style, FxData.grp(o, "crater"), FxData.grp(o, "debris"), FxData.grp(o, "fall"), float(_size_class(blast_m)), ppm_q, FxBake.seed_of(field.bomb_name, "bomb", _size_class(blast_m)))
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_bomb_sets)
	return _bomb_sets[key]

# A falling bomb's sprite at one scale.
func _drop_set_for(ppm_q: float) -> FxBomb.BombSet:
	var key := "%s|%.3f" % [field.bomb_name, ppm_q]
	if not _drop_sets.has(key):
		var t0 := Time.get_ticks_usec()
		_drop_sets[key] = FxBomb.bake_drop(style, FxData.grp(field.bomb_o, "fall"), ppm_q)
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_drop_sets)
	return _drop_sets[key]

# The tower's ruin sprites at one scale: what stays at the foot, the mast lying, the mast falling, a loose bar.
func _ruin_set_for(ppm_q: float, rot: float = 0.0) -> FxRuin.RuinSet:
	var rq := snappedf(rot, deg_to_rad(1.0))
	var key := "%s|%.3f|%.3f" % [field.ruin_name, ppm_q, rq]
	if not _ruin_sets.has(key):
		var t0 := Time.get_ticks_usec()
		_ruin_sets[key] = FxRuin.bake_set(style, field.ruin_o, field.tower_model(), ppm_q, FxBake.seed_of(field.ruin_name, "ruin", 0), rq)
		_bakes += 1
		_bake_ms += (Time.get_ticks_usec() - t0) / 1000.0
		_trim(_ruin_sets)
	return _ruin_sets[key]

# The sprite, its shadow mask and its origin for a piece of debris, by what it is: earth, a bar of lattice, or a piece of a plane.
func _debris_art(d: Dictionary, q: float) -> Dictionary:
	var kind := str(d.get("kind", "shard"))
	var v := int(d["variant"])
	if kind == "clod":
		var bs := _bomb_set_for(q, float(d["size_m"]))
		if bs == null or bs.clods.is_empty():
			return {}
		v = v % bs.clods.size()
		return {"tex": bs.clods[v], "mask": bs.clod_masks[v], "origin": bs.clod_origin[v]}
	if kind == "bar":
		var rs := _ruin_set_for(q)
		if rs == null or rs.bars.is_empty():
			return {}
		v = v % rs.bars.size()
		return {"tex": rs.bars[v], "mask": rs.bar_masks[v], "origin": rs.bar_origin[v]}
	var ps := _parts_for(q, float(d["size_m"]))
	if ps == null or ps.shards.is_empty():
		return {}
	v = v % ps.shards.size()
	return {"tex": ps.shards[v], "mask": ps.shard_masks[v], "origin": ps.shard_origin[v]}

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
				fire.draw_shadows(self, item, view)
		"air":
			_draw_air(item, view)
			fire.draw_air(self, item, view)
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
		var art := _debris_art(d, q)
		if art.is_empty():
			continue
		_blit(item, art["tex"], art["origin"], sp, float(st["rot"]), ppm / q, Color(1.0, 1.0, 1.0, float(st["alpha"])))
	_draw_scar_embers(item, view)
	_draw_strike_ground(item, view)

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
		var art := _debris_art(d, q)
		if art.is_empty():
			continue
		_blit(item, art["mask"], art["origin"], sp, float(st["rot"]), ppm / q, _tint)
	_draw_strike_shadows(item, view)

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
		var art := _debris_art(d, q)
		if art.is_empty():
			continue
		_blit(item, art["tex"], art["origin"], sp, float(st["rot"]), ppm / q, Color.WHITE)

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
		var bs := _burst_for(b, q)
		if bs == null or k >= bs.frames.size():
			continue
		_blit(item, bs.frames[k]["tex"], bs.origin, sp, 0.0, ppm / q, Color.WHITE)
	_draw_strike_air(item, view)   # the bombs falling: over the bomber they were dropped from (they are under it in the air)
	if field.tracers != null:   # Track TR: machine-gun tracers, over the planes (a round leaves the gun and ends on the target)
		FxTracer.draw_all(item, field.tracers, mapping, style, true_scale, now, view)

# --- The strike's drawing (Track X2) -----------------------------------------------------------------------------------------------

# THE SPLASHES (Track BB, decision ship-sinks; PROPOSED look): where a unit goes under the water, a few rings in the effects palette's ink widen and fade
# on the water, under the unit. The numbers are data/world/boats.json game.sunk.splash.
func _splash_data() -> Dictionary:
	return load("res://scripts/ui/unit_sunk.gd").data()["splash"]

func _splash_life_s() -> float:
	var d := _splash_data()
	var u = load("res://scripts/render/boat_art.gd")
	return float(u.val(d["duration_s"])) + float(u.val(d["stagger_s"])) * float(int(u.val(d["rings"])) - 1)

func _draw_splashes(item: CanvasItem, view: Rect2) -> void:
	if field.splashes.is_empty():
		return
	var d := _splash_data()
	var bv = load("res://scripts/render/boat_art.gd")
	var dur := float(bv.val(d["duration_s"]))
	var rings := int(bv.val(d["rings"]))
	var stagger := float(bv.val(d["stagger_s"]))
	var r0 := float(bv.val(d["radius_start_m"]))
	var r1f := float(bv.val(d["radius_end_frac"]))
	var a0 := float(bv.val(d["alpha"]))
	var w := float(bv.val(d["line_px"]))
	var squash := float(bv.val(d["squash"]))
	var ink: Color = style.ink()
	item.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for s: Dictionary in field.splashes:
		var age := now - float(s["t0"])
		if age < 0.0 or age > dur + stagger * float(rings - 1):
			continue
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.grow(160.0).has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		for k in rings:
			var ak := age - float(k) * stagger
			if ak <= 0.0 or ak >= dur:
				continue
			var f := ak / dur
			var radius := (r0 + (r1f * float(s["size_m"]) - r0) * (1.0 - (1.0 - f) * (1.0 - f))) * ppm
			var pts := PackedVector2Array()
			for j in 33:
				var ang := float(j) / 32.0 * TAU
				pts.append(sp + Vector2(cos(ang) * radius, sin(ang) * radius * squash))
			item.draw_polyline(pts, Color(ink.r, ink.g, ink.b, a0 * (1.0 - f)), w, true)

# On the ground: the craters, then each ruin (what stays at the foot, the mast falling or lying).
func _draw_strike_ground(item: CanvasItem, view: Rect2) -> void:
	_draw_splashes(item, view)
	for c in field.craters:
		var a := field.crater_alpha(c, now)
		if a <= 0.0:
			continue
		var wp: Vector2 = c["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var bs := _bomb_set_for(q, float(c["size_m"]))
		if bs == null or bs.craters.is_empty():
			continue
		var tex: Texture2D = bs.craters[int(c["variant"]) % bs.craters.size()]
		_blit(item, tex, bs.crater_origin, sp, mapping.screen_angle(wp, float(c["rot"])), ppm / q, Color(1.0, 1.0, 1.0, a))
	for r in field.ruins:
		var a := field.ruin_alpha(r, now)
		if a <= 0.0:
			continue
		var wp: Vector2 = r["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.grow(160.0).has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		if str(r.get("kind", "")) == "military_complex":
			_blit_complex_ruin(item, r, sp, ppm, q, Color(1.0, 1.0, 1.0, a), false)   # mission 2: the compound's own destroyed art
			continue
		if _boats_ruin_kind(str(r.get("kind", ""))):
			_blit_boats_ruin(item, r, sp, Color(1.0, 1.0, 1.0, a), false)   # Track BB: the bridge's ruin, a boat's wreck
			continue
		# the foot is baked ALREADY TURNED by the unit's heading (as the static markers are: the light is the map's at any heading)
		var rs := _ruin_set_for(q, mapping.screen_angle(wp, float(r["heading"])) + PI / 2.0)
		if rs == null or rs.remains.is_empty():
			continue
		var v := int(r["variant"]) % rs.remains.size()
		var tower := str(r.get("kind", "radio_tower")) == "radio_tower"
		_blit(item, rs.remains[v] if tower else rs.remains_other[v], rs.remains_origin, sp, 0.0, ppm / q, Color(1.0, 1.0, 1.0, a))
		if not tower:
			continue   # a destroyed battery: scorch, crater and scraps; no mast
		# the mast: falling (a flipbook of its angles), then lying; both in the frame of its fall
		var rot := mapping.screen_angle(wp, float(r["fall_rad"]))
		var fk := field.ruin_collapse_frame(r, now)
		var frames: Array = rs.collapse[v]
		if fk >= 0 and fk < frames.size():
			_blit(item, (frames[fk] as Dictionary)["tex"], rs.lying_origin, sp, rot, ppm / q, Color.WHITE)
		elif field.ruin_lying(r, now) and rs.lying[v] != null:
			_blit(item, rs.lying[v], rs.lying_origin, sp, rot, ppm / q, Color.WHITE)

# THE DESTROYED MILITARY COMPLEX (mission 2, Track M2U): the art unit_marker_art_static.gd bakes (complex_ruin_art), already turned by
# the unit's heading as its marker was (the sprite angle heading + 90 degrees), at the drawn scale, with its low cast shadow as the mask.
# `shadow` draws the mask (in the shadow pass) in place of the sprite.
func _blit_complex_ruin(item: CanvasItem, r: Dictionary, sp: Vector2, ppm: float, q: float, mod: Color, shadow: bool) -> void:
	var ui: RefCounted = load("res://scripts/ui/ui_style.gd").shared()
	var rot := mapping.screen_angle(r["pos"], float(r["heading"])) + PI / 2.0
	var art = load("res://scripts/ui/unit_marker_art_static.gd").complex_ruin_art(ui, q, rot)
	if art == null or art.texture == null:
		return
	var tex: Texture2D = art.mask if shadow else art.texture
	_blit(item, tex, art.origin, sp, 0.0, ppm / art.ppm, mod)

# THE DESTROYED BRIDGE AND THE WRECKED BOATS (Track BB, 2026-10-11): the art unit_marker_art_boats.gd bakes (ruin_art), already turned by the
# unit's heading as its marker was. The bridge is map scenery, so it is drawn at the MAP's scale; a boat's wreck at the planes' (the boats'
# rule), as the boat was. `shadow` draws the cast-shadow mask (in the shadow pass) in place of the sprite.
func _boats_ruin_kind(kind: String) -> bool:
	return load("res://scripts/ui/unit_marker_art_boats.gd").has_ruin(kind)

func _blit_boats_ruin(item: CanvasItem, r: Dictionary, sp: Vector2, mod: Color, shadow: bool) -> void:
	var ui: RefCounted = load("res://scripts/ui/ui_style.gd").shared()
	var boats = load("res://scripts/ui/unit_marker_art_boats.gd")
	var kind := str(r.get("kind", ""))
	var wp: Vector2 = r["pos"]
	var ppm: float = mapping.px_per_m(wp) if boats.is_map_scale(kind) else drawn_ppm(wp)
	var rot := mapping.screen_angle(wp, float(r["heading"])) + PI / 2.0
	var art = boats.ruin_art(ui, kind, quantize(ppm), rot)
	if art == null or art.texture == null:
		return
	var tex: Texture2D = art.mask if shadow else art.texture
	_blit(item, tex, art.origin, sp, 0.0, ppm / art.ppm, mod)

# Bombs in the air cast their shadow by the altitude rule, the gap closing as they fall.
func _draw_strike_shadows(item: CanvasItem, view: Rect2) -> void:
	for r in field.ruins:
		if _boats_ruin_kind(str(r.get("kind", ""))):
			var bp: Vector2 = r["pos"]
			var bsp := mapping.world_to_screen(bp)
			var ba := field.ruin_alpha(r, now)
			if ba > 0.0 and view.grow(160.0).has_point(bsp):
				_blit_boats_ruin(item, r, bsp, Color(_tint.r, _tint.g, _tint.b, ba), true)
			continue
		if str(r.get("kind", "")) != "military_complex":
			continue
		var ra := field.ruin_alpha(r, now)
		var rp: Vector2 = r["pos"]
		var rsp := mapping.world_to_screen(rp)
		if ra <= 0.0 or not view.grow(160.0).has_point(rsp):
			continue
		var rppm := drawn_ppm(rp)
		_blit_complex_ruin(item, r, rsp, rppm, quantize(rppm), Color(_tint.r, _tint.g, _tint.b, ra), true)
	for d in field.drops:
		var s := field.drop_state(d, now)
		if not bool(s["alive"]):
			continue
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp) + _shadow_px(wp, float(s["h"]))
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var bs := _drop_set_for(q)
		if bs == null or bs.bomb_mask == null:
			continue
		_blit(item, bs.bomb_mask, bs.bomb_origin, sp, mapping.screen_angle(wp, float(s["heading"])), ppm / q, _tint)

func _draw_strike_air(item: CanvasItem, view: Rect2) -> void:
	for d in field.drops:
		var s := field.drop_state(d, now)
		if not bool(s["alive"]):
			continue
		var wp: Vector2 = s["pos"]
		var sp := mapping.world_to_screen(wp)
		if not view.has_point(sp):
			continue
		var ppm := drawn_ppm(wp)
		var q := quantize(ppm)
		var bs := _drop_set_for(q)
		if bs == null or bs.bomb == null:
			continue
		_blit(item, bs.bomb, bs.bomb_origin, sp, mapping.screen_angle(wp, float(s["heading"])), ppm / q, Color.WHITE)
