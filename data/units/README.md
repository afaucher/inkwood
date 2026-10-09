# Unit definitions

Empty until execution-plan component 4 (unit data model) lands. One file per
unit type, named after the design doc's initial roster: `light_fighter`,
`heavy_fighter`, `bomber`, `tank`, `anti_aircraft_battery`, `small_cruiser`,
plus `radio_tower` as the example static unit.

Each file carries what the design doc's unit design sheet lists (role,
silhouette variant, size, height layer, speed and actions per turn, engagement
envelope and parameters, specials with uses and reload, health and armor, sight,
shadow behaviour, card contents). The sheet values come from variant boards and
are recorded in `data/decisions/decisions.json` before they are written here.
