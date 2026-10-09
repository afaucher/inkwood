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
