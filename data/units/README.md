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
light AA guns on two mounts; the S2 barge, 34 m, unarmed) and `bridge.json` a static ground unit
that bombs can destroy like the tower. Every unit file now carries `draught_m`: the depth of
water a sea unit needs under it (above 0 for domain sea, 0 for the rest). The World keeps a sea
unit afloat (`World.set_water`, `data/sim/sea.json`: a step that would leave the water is slowed,
then held, with the limit `shore`); the boats sail their routes under the AI's `sail` role
(`data/sim/ai.json`). Where they and the bridge stand is `WaterGen.sites()`; `data/scenarios/strike.json`
carries them behind its `"water"` switch, off until the drawing can show them. All values are proposed.

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
