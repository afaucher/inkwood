# Decision workflow: the variant board — PROPOSED, DEFERRED

Status 2026-10-09: outline agreed in conversation, build deferred by Alex until
there is a running build to put it in. Nothing here is built. The design doc's
"Execution plan > Decision workflow" is the source of truth; this is the
working outline for component 3 when it starts.

## What Alex decided (for the design doc's decision log)

- The board lives in the build. The alternative — an artifact page hosting the
  HTML prototype as a second renderer — is dropped.
- Two modes, both from one board definition: Claude shows a series of
  screenshots ("online"), or Alex plays a build with a knob that switches
  between the options ("offline").
- Deferred until a build runs. Component 3 therefore follows the render port
  (component 6) rather than sitting in phase 1.
- Bridge to Friendship's in-game version (the F1 debug console) was clunky for
  specific decisions; the board must not be that.

## What Bridge to Friendship teaches

Its screenshot half worked: `--run-shots art/shots.json` renders fixed framings
into a SubViewport (the manifest is the artefact, images are regenerable), and
`compare.html` puts one row per subject and one column per style, judged by a
rubric before taste. Its in-game half is the debug console: every knob as a raw
slider, one value at a time, replicated through the host, covering the thing
being judged, recording nothing. Good for tuning at large, wrong for choosing.

## Proposed shape

One board file, both modes read it: `variants/<decision-id>/board.json`

- the question and the design-doc area it belongs to
- the seed (20261009 unless the board says otherwise)
- framings: one or more cameras (position, zoom), so a candidate is judged at
  the zooms that matter — the camera/scale question is still open in the doc
- options: 3–6 named candidates, each a whole set of overrides on
  `data/params/render_defaults.json` (never a single slider value)
- after the choice: `chosen`, the comparison history, and the rubric scores

Same seed + same parameters = same picture, so the file is the archive and the
images are regenerable from it.

### Screenshot mode (Claude shows a series)

- A windowed entry point `--run-board <id>` beside `--run-test` in
  `scripts/app/main.gd`, modelled on Bridge to Friendship's shot runner:
  `--headless` disables rendering, so this is a windowed dev-box run and never
  a test. Renders into a SubViewport at the size the board says.
- For each framing x option: apply the overrides, regenerate from the seed,
  place the camera, wait for `RenderingServer.frame_post_draw`, save
  `<framing>-<option>.png`.
- Writes `board.html`: rows = framings, columns = options (the `compare.html`
  idea), plus a pair view where a key blinks between any two images.
- Wrapped by `board.ps1` / `board.sh` the way `test_runner.*` wraps a test.

### In-build mode (Alex plays with a knob)

- Not the knob panel. A `variant_option` choice knob in `DebugSettings`, its
  choices built from the loaded board, so the registry and the environment
  override (`INKWOOD_VARIANT_OPTION=<name>`) work unchanged.
- One key cycles options; a held key blinks back to the previous one in place;
  one key records the pick to `variants/<id>/choice.json` and prints it.
- Options are applied atomically as a set and the world regenerates once from
  the seed; sprites cached per parameter key (as the prototype does), so the
  switch is near-instant.
- Overlay: a corner label with the option name and its diff against the
  defaults. Nothing over the map.
- Local dev run only: no replication, no host round-trip.

### Head-to-head

Grid first for the gut reaction, then pairs with blink, king-of-the-hill: the
winner stays, the next option comes in; a 5-option board resolves in 4
comparisons. A parameter sweep is a board whose options are generated. A blend
is a slider between two options that mints a new one with concrete values.

### Judging

Rules before taste: the design doc's style rules become the rubric (sepia ink,
never pure black; one flat merged shadow tint; no gradients on objects; form
from lines and cast shadows; paper texture reads as one drawing), scored
per option, then taste.

### Recording

The pick lands in `board.json` and as a record in
`data/decisions/decisions.json` (shape documented there); Claude reports it for
the design doc's decision log. Losing options stay in the folder.

## Open questions for Alex

- Should the in-build pick write `choice.json`, or is telling Claude enough?
- Commit only `board.json` + the composite `board.html`/`board.png`, or every
  option image?
- What exactly was clunky in the Bridge to Friendship console — switching
  cost, missing comparison, or the raw sliders? It decides what to build
  first.
