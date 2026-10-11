extends RefCounted

# A UNIT BELOW THE WATER (Track BB, 2026-10-11). Alex, decision ship-sinks: "For destroyed ships, ideally we just sink them to the bottom.
# We don't even need to show damage if we just height-appropriately flood them with water." "Just like a downed plane its altitude
# should decrease until it hits the floor. It just does so through the water." "In fact we could have planes do the same if they crash
# there." The sim does the falling (World._fall_step: height below 0 m, the floor at minus the water's depth); this is how the interface
# DRAWS a unit whose height is below 0 m: its own intact art, under the water layer's OWN depth wash for the metres of water above it.
#
#   var wash := UnitSunk.wash(world, style, floor_depth_m, metres_above)       # {color, amount}
#   UnitSunk.apply(sprite, wash["color"], wash["amount"])                      # on any Sprite2D of a unit's art
#
# THE WASH is a mix of the sprite's colours toward the water's colour. The colour is the map's own: the step of the water at the unit's
# floor (WaterGen.step_of(depth): shallows, shelf, deep) as the map bake resolves it (data/world/water.json draw.palette through
# WaterDraw.oklch_color, scripts/render/water_placeholder.gd wb_steps): no new tint, so a unit lying on the floor fades into the very wash
# the map draws there. HOW MUCH is by the metres of water above it: none at the surface, 1 - exp(-metres / extinction_m) below
# (data/world/boats.json game.sunk.extinction_m, PROPOSED), so in deep water a hull on the floor is nearly the water's own colour
# ("deep water should hide the hull almost completely") and in the shallows it shows through. Nothing else is changed: the sprite keeps its
# silhouette and its alpha; the marker takes the shadow and the wake away once the unit is under (unit_marker.gd).
#
# REUSABLE (Alex asked to "consider some wrecked litter just for visual interest. A sunken boat or plane in the water adds some
# character"; its own board, later): the picture takes a kind (the silhouette: UnitMarkerArt.art_for), a position and heading (the
# sprite's), and a depth (the floor's and how far under it lies), so the litter can be this same art placed by a seed.

const WaterPlaceholder = preload("res://scripts/render/water_placeholder.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")

const SHADER_CODE := """
shader_type canvas_item;
uniform vec4 wash = vec4(0.5, 0.6, 0.7, 1.0);
uniform float amount = 0.0;
void fragment() {
	// COLOR already holds the sprite's texel times its modulate (Godot multiplies the texture in before fragment() runs)
	COLOR = vec4(mix(COLOR.rgb, wash.rgb, amount), COLOR.a);
}
"""

static var _shader: Shader = null
static var _steps: Array = []

static func data() -> Dictionary:
	return (BoatArt.data()["game"] as Dictionary)["sunk"]

# Metres of water over a unit that wash it out to 63 percent (data game.sunk.extinction_m, proposed).
static func extinction_m() -> float:
	return float(BoatArt.val(data()["extinction_m"]))

# How much of the water's colour a unit `metres_above` metres under the surface wears: 0 at the surface, toward 1 with depth.
static func amount(metres_above: float) -> float:
	if metres_above <= 0.0:
		return 0.0
	return 1.0 - exp(-metres_above / maxf(extinction_m(), 1e-6))

# The map's water colour for a floor `depth_m` deep: the step the water layer puts that depth in (WaterGen.step_of, the object the World's
# water query belongs to), the step's colour as the map bake resolves it. Paper's own colour when the style or the water is not there.
static func step_color(world: Object, st: RefCounted, depth_m: float) -> Color:
	if _steps.is_empty():
		_steps = WaterPlaceholder.wb_steps(st)
	if _steps.size() != 3:
		return st.palette["paper"]
	var k := 0
	var wd: Callable = world.get("water_depth") if world != null else Callable()
	var obj: Object = wd.get_object() if wd.is_valid() else null
	if obj != null and obj.has_method("step_of"):
		k = clampi(int(obj.call("step_of", depth_m)), 0, 2)
	else:
		k = 0 if depth_m < 6.0 else (1 if depth_m < 18.0 else 2)   # (data water.json levels.step_from_m, when there is no generator to ask)
	return _steps[k]

# The wash of a unit lying `metres_above` metres under the surface over a floor `floor_depth_m` deep: {color, amount}.
static func wash(world: Object, st: RefCounted, floor_depth_m: float, metres_above: float) -> Dictionary:
	return {"color": step_color(world, st, floor_depth_m), "amount": amount(metres_above)}

# Puts the wash on a sprite (its art, its wake's copy ...): a ShaderMaterial made for it once; none while the amount is 0, so a
# unit above the surface draws exactly as it did.
static func apply(sprite: Sprite2D, color: Color, amount_value: float) -> void:
	if amount_value <= 0.0:
		if sprite.material != null:
			sprite.material = null
		return
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	var mat := sprite.material as ShaderMaterial
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = _shader
		sprite.material = mat
	mat.set_shader_parameter("wash", color)
	mat.set_shader_parameter("amount", amount_value)
