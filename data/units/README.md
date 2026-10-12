# Unit definitions

One JSON file per unit type, read at runtime by `scripts/sim/unit_def.gd`.
The record is described in `_schema.json`. A missing or mistyped field is
an error at load, never a default that lives in code.

Values marked `"_proposed": true` are placeholders: Track S picked them
(2026-10-09) to plausible WWII-era figures, each with a one-line reason in
the file. None is a decision until Alex makes it one (see
`data/decisions/decisions.json`). `test_unit_defs` checks every file here
and recomputes the map-size rule in `data/sim/turn.json`, so a retune that
outgrows the map fails the gate.

## The strike's units (Track S2, 2026-10-10)

`radio_tower.json` and `anti_aircraft_battery.json` are **static** units
(`"mobility": "static"`): they never move, turn or plan, their envelope is all
zeros on the `surface` band, the World gives them one step a turn that stands
still and does not wait for them in the ready-up. A destroyed one is down with
the fate `destroyed` and stays in `World.units`. The battery has two weapons, both
cones aimed up and all around (`half_across_deg` 180 means the azimuth is not part
of the cone): `flak` (heavy, long reach) and `light_flak` (short and fast, so it
reaches the low band near the battery and never the medium band; added by Track F
on Alex's decision `low-band-flak`, 2026-10-10, numbers proposed). Every file carries a `bomb_load` section (`drops`,
`per_drop`): 0 and 0 for units that drop nothing, at least two drops for those
that do (Alex: everything gets at least two). The bombs' physics is shared and
lives in `data/sim/bombs.json`. All values are proposed; the tuning tables are
printed by `scripts/test_support/strike_tuning.gd`.

## The water's units (Track WS, 2026-10-10)

`patrol_boat.json` and `supply_boat.json` are `"domain": "sea"` units (the P1 Cutter, 27 m, with
machine guns on two mounts, `deck_mg`; the S2 barge, 34 m, unarmed) and `bridge.json` a static ground unit
that bombs can destroy like the tower. Every unit file now carries `draught_m`: the depth of
water a sea unit needs under it (above 0 for domain sea, 0 for the rest). The World keeps a sea
unit afloat (`World.set_water`, `data/sim/sea.json`: a step that would leave the water is slowed,
then held, with the limit `shore`); the boats sail their routes under the AI's `sail` role
(`data/sim/ai.json`). Where they and the bridge stand is `WaterGen.sites()`; `data/scenarios/strike.json`
carries them behind its `"water"` switch, off until the drawing can show them. All values are proposed.

## What a weapon fires decides its look and its cone (decision weapon-kinds, Alex, 2026-10-11)

"Flak would be shells shot that then explode. Machine guns would be bullets which don't. But Flak is pointed up and
machine guns are around and less up. So flak guns have better coverage in the area directly above them." The anti-aircraft
weapons are named for what they fire (the old shared id `aa_guns` is gone): `flak` and `light_flak` (the battery) and
`ship_flak` (the cruiser) are flak, a cone from 2 degrees above the horizon to straight up, drawn as bursts (F2); `quad_mg`
(the mobile AA's quad mount) and `deck_mg` (the cutter's guns) are machine guns, all around but from the horizon to 50
degrees up (the band is proposed), drawn as tracers (the ids are in `data/fx/fx.json` `tracers.weapons`). A machine gun
cannot hit a plane straight over it; flak can.

## The tank (Track TK2, 2026-10-11)

`tank.json` is the first `"domain": "ground"` unit that MOVES (`"mobility": "mobile"`; the tower, the batteries and the
bridge are ground units that stand). Alex's decision `mixed-warfare` is why it exists ("tanks move inland to spot for a ship
offshore"); the unit sheet's tank is its drawing; every number is proposed. It moves by the planes' envelope with a tank's
numbers (top speed 10 m/s, which is its speed ON A ROAD; pivot steering, one turn rate at any speed; two steps a turn) and one
turret gun that fires on its own by the engagement rules (a level cone all round, 350 m, one pip a hit; it never answers a plane).
Where it may go is the GROUND RULE (`data/sim/ground.json`, `scripts/sim/ground_rules.gd`, applied by the World like the water
rule): dry land only; no height step off the road (Alex's decision `terrain-passability` A: "every height step is a cliff");
no river but over an intact bridge unit; half speed off the road, a third in woods (trees slow it, they never block it). The
AI drives it with the `drive` role (`scripts/sim/ai_drive.gd`, `data/sim/ai.json` `drive`): waypoints and/or the road to a target,
from a start turn. A scenario with a tank gives its World the ground (`SandboxScenario.populate`, `scripts/world/ground_map.gd`).

## What a damaged unit smokes with (builder SMOKE, 2026-10-11; decisions smoke-consistency and impact-by-round-and-target)

Every unit file carries `damage_smoke`: `enabled`, `source_m`, `source_back_m`, `rise_mps`. The effects layer's damage smoke is sized
by this SOURCE (an engine deck, a funnel; at most about 8 m: Alex, 'a property of either the round or the thing being hit or both'),
never by `size_m`, so a 40 m bridge or a 120 m cruiser does not wear a puff as big as itself. `enabled` false is the stone bridge
(Alex: 'Right now bridges don't have anything, that is fine.'): the effects feed leaves no smoke for it and has no case for it in code.
`rise_mps` is how fast a puff climbs (a rising puff drifts with the wind at its height, so the plume leans downwind): 4.0 for ground and
sea units, the smoulder's rate of the ruins and wrecks, 0 for planes, whose trail is laid along their path (the reason is in each file).
All values are proposed; the audit that led to them is `docs/proposals/smoke-audit.md`.

## The unit's body for lines of fire (builder LOF1, 2026-10-11; decision line-of-fire; PROPOSED)

Every unit file now carries a `shape`: its `boxes`, lowest layer first (`_schema.json`). Alex: "yes, two layers, hull and turret", so a
ground vehicle that drives (the tank, the mobile AA) is two boxes and every other unit is one (the lead's proposal); the battery
adds its sandbag ring, which is the first sim shape the sandbags have had. A box has a size, a place on the unit (forward and right of its
middle), a bottom and a top above the unit's BASE, and a material (a name from `data/sim/line_of_fire.json`). The base is the ground (or the
bridge's deck) under a surface unit, the water's surface under a boat, and the band's absolute height under a plane (bands are absolute
heights), so a plane's box reaches below and above its band. `stamp` puts a static unit's box in the height grid as an obstacle while the
unit stands (the ring, the bridge's deck; `standable` lets other units stand on it: the deck); a mobile unit's boxes are only targets.
`scripts/sim/line_of_fire_shapes.gd` places them in the world and picks the points a line is traced to; combat does not read any of it yet
(`data/sim/line_of_fire.json` `enabled` false). The bridge deck's top is `data/world/bridges.json` arch.crown_h (6.5 m); `test_line_of_fire`
holds the two equal.
