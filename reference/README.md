# Reference material

- `inkwood-renderer.html` -- the browser prototype (Inkwood Renderer version 2),
  copied as-is from https://claude.ai/artifact/SweR4FtZewp8FAX4xbNb6G on
  2026-10-09. It is the reference implementation for the generators and the
  look. Open it in a browser; no build step.
- `port_check/prototype_sample.js` -- runs the prototype's own utility functions
  under node and writes `port_check/expected_seed_20261009.json`, which
  `scripts/tests/test_port_utils.gd` checks the GDScript port against.
- `port_check/prototype_scene.js` -- runs the prototype's own scene generator
  (newScene and everything it calls, sliced out of the HTML) under node for
  seed 20261009 on a 1280x720 stage and writes
  `port_check/expected_scene_20261009.json`: every tree, prop, wall, house and
  road sample as exact doubles. `scripts/tests/test_scene_gen.gd` checks
  `scripts/world/` against it bit for bit.

Both fixtures record what NODE computes. Chrome's V8 can take Math.sin, cos and
atan2 from a different library than node's (measured 2026-10-09: Chromium 152
differs in the last bit in a few percent of calls), so the browser's default
scene can differ from the fixture in the last bit of a value; for seed 20261009
it is three doubles of the house and nothing that moves an object. See the
header of `scripts/core/js_math.gd`.

Nothing in this folder ships: `export_presets.cfg` excludes it.
