# Water: a style reference for the water design (saved 2026-10-10)

Alex, 2026-10-10: "I also got an example for water when we do that design. Let's save it."

**Source:** a screenshot of a post by Hannes Breuer, the developer of Might of Merchants and the
author of the video the whole style comes from (design doc, Reference), captioned "I added
circles". It is someone else's artwork, so the image is NOT in git: it lives on Alex's machine at
`reference/style/hannes_breuer_water_tower.png` (cropped to the map) and `..._full.png` (the
screenshot as sent), and as an image in the design doc's Reference section. As with the rest of the
style, the aim is a similar look reached procedurally, never a copy (CLAUDE.md rule 5).

**The scene:** a round stone tower with a conical plank roof on a small island, a wooden jetty
from the shore, a rowboat beside it, lily pads and flowers on the water, a cart on a dirt road,
scalloped trees on sand-coloured ground.

## What to take from it for Inkwood's water (observations; any choice is Alex's, on a board)

- **Depth is a soft gradient, not a line.** Deep water is a darker, more saturated teal; it
  lightens and turns greener toward the shallows, and the shallows melt into the ground through a
  wide, soft, lighter band. There is no inked shoreline at all on the sand side.
- **A pale halo around the land.** The ground right at the water's edge is lighter than the ground
  further away, so the shore glows; the island's own edge carries ink stipple and rubble.
- **Shadows fall on the water** as a darker teal with the same crisp edge as on land (the tower's
  shadow in the lower right), so the shadow pass simply darkens whatever it lands on.
- **Ink objects sit on the water unchanged:** the boat, the jetty's planks, lily pads and flowers
  use the same ink outline and pale fill as everything else, each with a small shadow on the water.
- **Faint shapes under the surface** (a dark silhouette in the deep water) add depth without ink.
- **Palette note:** the water is the one strongly coloured area of the scene, a teal far more
  chromatic than anything else, and the ground there is a warmer, more saturated yellow than
  Inkwood's paper. How water sits in Inkwood's palette is still open (art direction plan,
  palette decision 1); this reference argues for a real water hue with a lightness ramp toward
  the paper, judged beside the shadow tint (blue, oklch 0.513 0.076 242) and the slate-blue side
  accent so the three blues stay distinct.

## Alex's direction (2026-10-10)

"I might actually like to see like a stepped color washed version so under water is the same
height map as above." So, for the water board when water is designed: water drawn as STEPPED
colour washes rather than the reference's smooth gradient, with the seabed using the same height
map as the land -- depth levels below sea level thresholded and drawn the way the land's levels are
(today: levels at 0 / 12 / 24 m, contour lines, fills stepping in lightness), each depth step one
flat wash, darker and more saturated with depth. Land and sea then read as one continuous stepped
relief. The board should lead with this and show the smooth gradient beside it for comparison.
Open then (proposed questions): how many depth steps and how deep; whether underwater steps carry
contour lines, and what they mean (there is no passability under water except for ships' draught);
how the shore band and the pale halo on land meet the first step.
