extends RefCounted

# THE FOREST FIRE ON SCREEN (track 'Forest fire', decision forest-fire): the one small piece that carries the sim's feed to the two
# things that draw it -- the effects layer's smoke (fx_fire.gd) and the map's trunks (MapView.set_burnt_trees) -- and nothing else.
# It holds no pixels. The sandbox makes one when its World has a fire (`world.get("fire") != null`; with the fire off there is none
# and nothing changes) and calls sync() every frame:
#
#   var view := FxFireView.new()
#   view.setup(world, ui.fx, map_view, ui.game_time)     # the World, the FxLayer, the MapView, a Callable () -> game seconds
#   view.visible_at = func(p: Vector2) -> bool: ...      # optional: is the ground there in the player's sight (fog.vision.is_visible)
#   view.sync()                                          # each frame
#
# EACH FRAME it (1) takes the feed again when the fire changed (fire.revision moves at a resolve or a net apply; fire.feed() builds the
# list, so it is not asked for every frame) and hands it to the layer (FxLayer.set_fire_feed); (2) asks the layer which trees are
# TRUNKS as of the game time on show (burnt out: the end of their out_turn has passed -- the playback's time while a turn plays, else
# the start of the turn being planned or the end of the turn just played) and, when that set changed, hands it to the map
# (MapView.set_burnt_trees: only the chunks those trees touch are baked again, the old ones shown until the new land). The map therefore
# changes when the playback reaches the end of the turn a tree burns out in (PROPOSED: forest_fire.map.rebake_at "playback_end"), and
# a client that joins late draws the trunks of every tree already out at once.

const FxFire = preload("res://scripts/fx/fx_fire.gd")

var world: Object = null
var fx: Object = null            # the FxLayer (set_fire_feed, fire)
var map_view: Object = null      # the MapView (set_burnt_trees)
var game_time: Callable = Callable()
var visible_at: Callable = Callable() :
	set(v):
		visible_at = v
		if fx != null and fx.get("fire") != null:
			fx.fire.visible_at = v
var sight_sig: Callable = Callable() :
	set(v):
		sight_sig = v
		if fx != null and fx.get("fire") != null:
			fx.fire.sight_sig = v

var feeds := 0                   # times the feed was handed to the layer
var pushes := 0                  # times the burnt set was handed to the map
var _revision := -1
var _fire_id := 0
var _burnt_n := -1

func setup(world_: Object, fx_: Object, map_view_: Object, game_time_: Callable) -> void:
	world = world_
	fx = fx_
	map_view = map_view_
	game_time = game_time_
	if fx != null and fx.get("fire") != null:
		fx.fire.visible_at = visible_at
		fx.fire.sight_sig = sight_sig

# Whether the World has a fire now (a client may be handed one after it was made).
func has_fire() -> bool:
	return world != null and world.get("fire") != null

# One frame. Returns whether the fire is on.
func sync() -> bool:
	if not has_fire() or fx == null:
		return false
	var fire: Object = world.get("fire")
	var rev: int = int(fire.get("revision")) if fire.get("revision") != null else -1
	# a different fire object (the World was handed another) is a different feed, whatever its revision says
	if rev != _revision or fire.get_instance_id() != _fire_id:
		_revision = rev
		_fire_id = fire.get_instance_id()
		var ts: float = float(world.rules.turn_seconds) if world.get("rules") != null else -1.0
		fx.set_fire_feed(fire.feed(), ts)
		feeds += 1
		_burnt_n = -1
	if map_view != null and game_time.is_valid() and fx.get("fire") != null:
		var trunks: Array = fx.fire.burnt_at(float(game_time.call()))
		if trunks.size() != _burnt_n:
			_burnt_n = trunks.size()
			map_view.set_burnt_trees(trunks)
			pushes += 1
	return true
