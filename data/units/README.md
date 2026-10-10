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
