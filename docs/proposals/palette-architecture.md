# Palette architecture — PROPOSED

Alex's rule (2026-10-09): every art choice includes looking at how the palette
stays unified across all the parts. Each unit has custom draw behaviour, so the
question is how numbers get picked such that a tree, a house, a tank and a
bomber read as one drawing. This proposes the structure; nothing is built, and
the decisions at the end are Alex's.

## What the prototype palette actually is

Measured in OKLCH (perceptual lightness L, chroma C, hue h) from the design
doc's Style rules > Palette:

| role | hex | L | C | h |
| --- | --- | --- | --- | --- |
| paper | #D9CCAA | 0.847 | 0.048 | 90 |
| wall fill | #E2D7BA | 0.880 | 0.040 | 90 |
| rock fill | #E4D9BD | 0.887 | 0.039 | 89 |
| roof, lit | #EBE5D2 | 0.922 | 0.026 | 92 |
| object fill | #EFE6CD | 0.925 | 0.034 | 91 |
| light fibre | #F4ECD6 | 0.944 | 0.030 | 90 |
| dirt stipple | #5D5140 | 0.442 | 0.031 | 76 |
| ink | #3D3226 | 0.325 | 0.026 | 69 |
| shadow (steel) | #3D6C8F | 0.513 | 0.076 | 242 |
| roof, shaded = mix(shadow, roof, 0.58) | #A2B2B6 | 0.752 | 0.019 | 214 |
| wall slope = mix(shadow, wall, 0.70) | #B1B7AD | 0.772 | 0.015 | 133 |

Three facts fall out, and they are the whole system:

1. **One warm surface hue.** Paper and every fill sit at h ≈ 90 with C ≤ 0.05.
   The fills are paper lifted in L by fixed steps (+0.03, +0.04, +0.08) with
   chroma eased down as they lighten. Nothing is "cream" by choice; it is paper
   plus a step.
2. **One dark warm ink hue.** Ink and dirt sit at h ≈ 70, a two-step dark ramp
   (L 0.33, 0.44). Everything else that is dark is one of these at an alpha
   step (stipple 0.55, hatch 0.5, dirt 0.15–0.40, rings 0.88).
3. **One cool tint, derived never picked.** The shadow colour is the only thing
   above C 0.05. Shaded surfaces are a mix *toward* it (roof 42%, wall slope
   30%), which is why they land on cool hues at L ≈ 0.75 and still belong.

Everything the reference does with *material* — rock vs wood vs earth — it does
with linework (hatch, stipple density, crack lines, plank lines), not hue.

## The rule, in one line

**Hue is reserved for paper, ink, shadow and accents; lightness is a ramp off
paper; material is linework; nobody types a hex in draw code.**

## Architecture

### 1. Style tokens are data

`data/style/ink_style.json` (proposed name) holds, and only holds:

- **bases**: `paper`, `ink`, `shadow` — the three hues — plus **accents**, a
  small fixed list (`side_a`, `side_b` for the two sides; `fire`; possibly
  `water`, see decisions) each with a fixed chroma and lightness.
- **ramps**: `fill_steps` (lightness offsets from paper, with the chroma ease),
  `ink_steps` (ink, dirt), `shade_mix` (the mix fractions toward the shadow),
  `alpha_steps` (the handful of alphas ink marks use), `weight_steps` (the
  line-weight multipliers from Style rules > Linework).
- **roles**: a flat map from a drawing role to a base and a step, e.g.
  `tree.fill: [fill, 2]`, `house.roof: [fill, 2]`, `house.roof_shaded: [shade,
  1]`, `wall.slope: [shade, 0]`, `rock.fill: [fill, 1]`, `tree.stipple: [ink, 0,
  alpha 2]`, `unit.insignia: [accent side]`.

The existing `data/params/render_defaults.json` palette becomes the first
style, expressed this way; its hexes are what the ramps resolve to today.

### 2. A resolver, not a table

`scripts/render/style.gd` (proposed) resolves a role to a `Color` at load:
paper and ink from their hexes; fills as `paper` shifted in OK lightness by the
step (Godot 4 has `Color.from_ok_hsl` and the `ok_hsl_*` properties, so the
ramp is perceptual, not RGB arithmetic); shaded surfaces as the mix toward the
shadow tint exactly as the prototype computes them; alphas and weights from the
step tables. Draw code asks `style.color("house.roof")` and `style.alpha(2)`,
never a literal. A role the file does not define is an error at load, not a
silent default.

### 3. Invariants, tested in the gate

A headless test over the style file and the draw code:

- ink is never pure black and is darker than every fill by at least a stated
  ΔL; dirt is between ink and paper;
- every fill's hue is within a band of paper's and its chroma under a cap;
- exactly one shadow tint is in use; every shaded role is a `shade` step, not
  a free colour;
- every accent is at its declared chroma and is used only by roles tagged
  accent (the sides' insignia, fire);
- every role string that appears in `scripts/render/` and the unit drawers
  exists in the style file, and no hex literal appears in draw code at all.

The last one is the one that keeps the rule true a year from now.

### 4. The swatch board is the consistency test a person can see

A variant board (component 3) whose rows are *every drawn thing* — tree, rock,
barrel, crate, wall, house, each unit type — under one style, same seed, same
light, at the game's zoom. Every art decision's board carries this row beside
its options, so a change to a tank is judged next to the tree it will stand
under, never alone. The style's alternates (ink, teal, umber shadow tints) are
whole-board variants, not per-object choices.

### 5. Units follow the same rule, with one addition

Units have custom draw behaviour; what they may not have is custom colour.
A unit is: an outline at the unit weight step, fills from the fill ramp,
shading by the shade mix, material by linework (riveted plates are hatch and
dot rows, canvas is a stipple field, decking is plank lines), and **one accent
zone per side** — a roundel, a flag, a painted panel — carrying the side's
accent at its fixed chroma. Silhouette carries what the unit is; the accent
carries whose it is; nothing else is coloured. (Bridge to Friendship's art
direction reached the same split: silhouette for identity, colour for team,
with a designated tint zone so the style survives the team colour.)

### 6. Process

- A new drawn thing adds roles to the style file and a cell to the swatch
  board before it adds code.
- A variant board for anything drawn includes the swatch row.
- A decision that changes a base, a ramp step or an accent is logged like any
  other (data/decisions), and re-renders the whole swatch board.

## Decisions for Alex

1. **Water.** An island game needs the sea on every screen. Either water stays
   on the warm axis (paper with ruled ripple lines and a shade-mix wash) and the
   palette keeps its one cool tint, or water becomes a second cool accent. The
   first keeps the drawing one drawing; the second makes water read instantly.
   A variant board, judged with the swatch row.
2. **Accents.** How many, and at what chroma: two sides and fire is the
   minimum; mission markers and the UI leader lines may want to share the ink
   ramp rather than add a hue.
3. **Resolved or pinned.** Colours computed from the ramps at load (one knob
   moves everything together) or hand-pinned hexes with the invariants as a
   lint (more control per role, the ramp as a check rather than a generator).
   Proposed: resolved, with the swatch board as the eye.
