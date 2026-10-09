# Reference material

- `inkwood-renderer.html` -- the browser prototype (Inkwood Renderer version 2),
  copied as-is from https://claude.ai/artifact/SweR4FtZewp8FAX4xbNb6G on
  2026-10-09. It is the reference implementation for the generators and the
  look. Open it in a browser; no build step.
- `port_check/prototype_sample.js` -- runs the prototype's own utility functions
  under node and writes `port_check/expected_seed_20261009.json`, which
  `scripts/tests/test_port_utils.gd` checks the GDScript port against.

Nothing in this folder ships: `export_presets.cfg` excludes it.
