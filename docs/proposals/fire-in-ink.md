# Fire in ink -- PROPOSED

Research and proposals, 2026-10-10. Nothing here is a decision. Every
candidate, value, principle and the recommendation below is the researcher's
proposal, not Alex's call; the only decision quoted is Alex's rejection. Read
beside `docs/proposals/palette-architecture.md` (the palette rule) and
`docs/proposals/art-direction-plan.md` (rows fx.explosion, fx.fire, fx.smoke,
fx.muzzle, which all use `acc:fire`). The design doc was read from its dated
snapshot `docs/inkwood-design-doc.md`, not the live artifact.

Mock-ups (recolours of the existing board frames, shapes unchanged):

- `tmp/fire_research/sheet.png` -- the contact sheet: the original in the first
  column, one column per candidate, 11 frames at native size (380 px wide)
- `tmp/fire_research/sheet_zoom.png` -- the fire areas of six frames at 3x
  (nearest neighbour), to read the marks
- `tmp/fire_research/<candidate>/<frame>.png` -- each recoloured frame:
  `1_knockout`, `2_scorch`, `3_sienna`, `4_rubric`, `5_lamplight`, `6_blend`
- `tmp/fire_research/_tools/recolour.py` (with `oklch.py`) -- regenerates all of
  it: `python tmp/fire_research/_tools/recolour.py .` from the repo root

## 1. The problem

Alex, on the 2026-10-09 effects boards (`variants/crash-explosion/`): *"The fire
is not okay. It looks cartoony on this color palette. Let's do some more
research."* The rejected value is `accents.fire` in `data/fx/fx.json`,
oklch(0.72 0.14 56), #E68B44, with its roles `fire.pale` (55 % toward object
fill), `fire.dim` (45 % toward dirt) and `fire.shade` (30 % toward ink), used for
flashes, fireballs, flames and embers.

Measured from the board frames (`tmp/fxview/crash-explosion/*.png`), the fire
fill pixels are exactly oklch(0.72 0.14 56): the effects layer is drawn above
the 55 % grain pass, so the fire is the only flat, grain-free fill on screen.

Why it reads cartoony on this palette (diagnosis, proposed):

1. **It out-shouts everything.** Chroma 0.14 is the highest on the map: 40 %
   above the side accents (0.100) and nearly double the shadow tint (0.076),
   the only other thing above C 0.05. The fire, not the sides, is the loudest
   colour in every frame it appears in.
2. **It is darker than the paper, so it reads as a thing, not as light.** L 0.72
   sits 0.13 below paper (0.847) and 0.2 below the trees' object fill (0.925).
   On paper the only way to show light is to be the lightest thing in view; a
   saturated colour darker than its ground reads as a painted object -- a
   pumpkin, a sticker -- however hot it is meant to be.
3. **Flat, opaque, above the grain, inside an ink contour.** That is a cel or
   sticker. Everything else on the map has paper texture in it.
4. **It cools toward pastel.** `fire.pale` mixes toward cream, so the 0.3 s
   frames (B_0_3, B_2_2) are peach lobes -- confectionery colours. Fire and
   printed fire both cool toward dark: char, smoke, ink.
5. **Form amplifies it.** A closed, flat-filled star or lobed puff with an
   outline is the comic "POW" vocabulary. Colour is half the problem; the
   mock-ups show that the disc of option A and the lobes of option B stay
   "badge-like" in every colour (section 5).

Distinctness from brick red was *not* the problem: ΔE_OK(rejected, side A) is
0.182, as far apart as the two sides are from each other (0.181).

## 2. Research findings

### Maps that mark fire and destruction

- **Hollar's survey after the Great Fire of London (1666)** leaves the burnt
  city as blank paper: the title explains that the empty space is the burnt
  part, with only the street lines and the ground plans of churches and major
  buildings drawn in it. The fire is shown by *absence* -- the paper is the
  burnt ground. ([Crouch Rare Books](https://crouchrarebooks.com/browse/hollars-post-fire-survey-of-london/?print=pdf),
  [National Archives teaching resource](https://www.nationalarchives.gov.uk/education/resources/tactile-3d-printer-models/great-fire-of-london-map/))
- **Chicago, 1871, "burnt district" maps** lay a red, orange or dark-red tint
  over the area while the street grid stays readable through it -- colour as a
  transparent wash over the drawing, not a fill that replaces it.
  ([Library of Congress, Worlds Revealed blog](https://blogs.loc.gov/maps/2021/10/the-city-which-would-not-be-cowed-the-great-chicago-fire-of-1871/),
  [Geographicus, Watson 1871](https://www.geographicus.com/P/AntiqueMap/chicagoburntdistrict-watson-1871))
- **The LCC bomb damage maps (London, 1939-45)** are hand coloured with a
  severity ramp: yellow (minor blast) -> orange -> light red -> dark red ->
  purple -> black (total destruction), with circles for V-1 and V-2 impacts.
  The ramp ends in black: the worst damage is the most ink, not the most hue.
  ([Atlas Obscura](https://www.atlasobscura.com/articles/intricately-colorcoded-maps-marking-bomb-damage-from-the-london-blitz),
  [Local Local History](https://www.locallocalhistory.co.uk/studies/bombingmap))
- **Sanborn fire-insurance maps** colour *materials*, not fire: pink-red for
  brick, yellow for wood frame, olive for fire-resistive.
  ([Library of Congress](https://www.loc.gov/collections/sanborn-maps/about-this-collection/))
  A warning for Inkwood: on a period map a red tint already means brick, and on
  ours a brick red already means side A.
- **18th-century battle plans** draw burning towns pictorially and locate
  active fires in the key (e.g. Norman's 1782 Bunker Hill plan, Charlestown
  shown ablaze). ([Unique Maps](https://uniquemaps.co/products/old-battle-map-of-bunker-hill-by-norman-1782-boston-harbor-charles-river-charlestown-north-battery-long-wharf.oembed))
  Colour on such plans was usually added by hand after printing and varies
  between impressions.

### Prints and manuscripts

- **Chiaroscuro woodcut** (Burgkmair, Augsburg, c. 1509; Ugo da Carpi): a line
  block plus one or more tone blocks; the highlights are not printed at all --
  they are paper where the tone block was cut away. The light *is* the paper.
  ([The Met, "The Printed Image in the West: Woodcut"](https://www.metmuseum.org/essays/the-printed-image-in-the-west-woodcut))
- **Goya, Disasters of War pl. 41, "They escape through the flames"**: a blaze
  of light at the centre of a night scene, made in etching and (in some states)
  burnished aquatint -- light by contrast with the bitten darks around it, not
  by colour. ([Fundación Goya en Aragón](https://mail.fundaciongoyaenaragon.es/eng/obra/escapan-entre-las-llamas/785?print=1),
  [National Gallery of Art](https://www.nga.gov/collection/art-object-page.7581.html))
- **Dürer's woodcuts** reach a full range from paper-white to black with line
  density alone: hatching that swells and tapers models form without any tint.
  ([National Gallery of Art, Apocalypse](https://www.nga.gov/collection/art-object-page.141215.html))
- **Kobayashi Kiyochika's fire prints (Tokyo, 1881)**: orange flames driven by
  the wind against dark foreground silhouettes, with a brushed gradation
  (fukibokashi) in the sky; surviving impressions vary in sky colour, i.e. the
  colour was a printing variable while the drawing stayed fixed. He reportedly
  sketched the Ryogoku fire so intently that he missed his own house burning.
  ([Art of Weather, Amherst](https://artofweather.wordpress.amherst.edu/2025/06/11/kobayashi-kiyochikas-outbreak-of-fire),
  [Princeton University Art Museum](https://artmuseum.princeton.edu/art/collections/objects/57765),
  [Bokashi](https://en.wikipedia.org/wiki/Bokashi_(printing)))
- **Japanese narrative handscrolls**: the Heiji scroll's Night Attack on the
  Sanjō Palace is known for red flames over black smoke
  ([Facsimiles.com](https://www.facsimiles.com/facsimiles/heiji-monogatari-e),
  [Wikipedia](https://en.wikipedia.org/wiki/Heiji_Monogatari_Emaki)); the Ban
  Dainagon scroll's burning Ōtenmon gate is described as an astounding
  conflagration ([Wikipedia](https://en.wikipedia.org/wiki/Ban_Dainagon_Ekotoba)).
  A Web Japan feature, surfaced in a search summary, describes its flames as
  cinnabar, red and orange chosen selectively, the sparks as *spattered* red
  pigment and the smoke in charcoal shades; that page refused a direct fetch,
  so treat the pigment detail as secondary.
- **Manuscript reds**: rubrication is red used for emphasis, a specialist's
  job, sparingly; the two reds are vermilion (deeper) and red lead / minium
  (orange-red), often mixed.
  ([Rubrication](https://en.wikipedia.org/wiki/Rubrication),
  [British Library, "The colour red"](https://www.bl.uk/stories/blogs/posts/the-colour-red),
  [UGA Hargrett Hours Project](https://ctlsites.uga.edu/hargretthoursproject/puzzling-reds-the-mysteries-of-medieval-pigment-making))
  In the Hours of Albrecht of Brandenburg the hell scene is red lead with
  sparks of shell gold, and the border flames add an organic red, with
  lead-tin yellow for the bright flashes. ([Fitzwilliam Museum](https://fitzmuseum.cam.ac.uk/illuminated/manuscript/discover/leaves-from-the-hours-of-albrecht-of-brandenburg/technique/light-effects/folio/ms-294d))

### War artists

- **Paul Nash**: field sketches in chalk on brown paper, worked up later; the
  1918 lithographs (black and a tone) were praised by Arnold Bennett as a
  "ruthlessly selective" convention that keeps a few forms, the curves of
  shell-bursts among them. ([1914-1918 Online](https://encyclopedia.1914-1918-online.net/article/nash_paul),
  [British Council Collection](https://visualarts.britishcouncil.org/collection/artists/nash-paul-1889/object/the-mine-crater-hill-60-ypres-salient-nash-1917-p2991),
  [Australian War Memorial, "Shell bursting, Passchendaele"](https://www.awm.gov.au/collection/ART19838),
  [Piano Nobile, "Shellburst, Zillebeke"](https://www.piano-nobile.com/artworks/1050-paul-nash-shellburst-zillebeke-1917))
- **Muirhead Bone** (first official war artist, 1916): pencil, pen, charcoal
  and chalk; recorded the context of the battle more than explosions.
  ([IWM](https://www.iwm.org.uk/history/first-world-war/somme/muirhead-bone))
- **Edward Ardizzone** (WWII): pen, ink and wash, restrained colour, almost 400
  sketches and watercolours now at the IWM.
  ([Wikipedia](https://en.wikipedia.org/wiki/Edward_Ardizzone),
  [Eye magazine](https://eyemagazine.com/feature/article/ardizzone-at-peace-and-in-conflict))
- **Leonard Rosoman**, an Auxiliary Fire Service fireman, painted the Blitz
  fires from the inside; firemen artists exhibited at the Royal Academy in
  1941. ([Wikipedia](https://en.wikipedia.org/wiki/Leonard_Rosoman),
  [IWM, art in the Blitz](https://www.iwm.org.uk/history/second-world-war/blitz/art-and-photography-in-the-blitz))
  I found no technical account of the palettes these artists used for fire.

### Comics in ink and spot colour

- **Two-colour printing**: Sunday strips were often black line plus one red
  spot, the red *screened* mechanically into lighter tints; the second colour
  can be laid under the greys and the black line rather than over them.
  ([The Comics Journal, "Second color notes"](https://www.tcj.com/color-workbook-3/),
  [Spot color](https://en.wikipedia.org/wiki/Spot_color))
- **Mike Mignola** keeps red back for the moments that matter; in Hellboy in
  Hell he and Dave Stewart deliberately drained red from the hero so it could
  return when things heat up.
  ([Inverse](https://www.inverse.com/article/15225-hellboy-creator-mike-mignola-i-save-the-color-red-for-when-things-heat-up))
- **Jacques Tardi's WWI books**: in the black-and-white one, a shell burst is a
  wash of black and white smudges with figures thrown through it, and its
  greys come from Craftint tones; in the painted one, the single shock is a
  red-orange panel against the subdued blues and greys of the rest.
  ([NYRB](https://www.nybooks.com/online/2014/08/06/jacques-tardi-great-war-trenches/),
  [Lambiek](https://www.lambiek.net/shop/series/it-was-the-war-of-trenches/51505/it-was-the-war-of-trenches.html))

### 1940s technical illustration

I found no good source on fire in 1940s technical manuals specifically. The
period's general means are the two above: black plus one spot colour, and
mechanical tints (Ben-Day / Craftint screens) for tone.

### Games with inked, drawn or parchment looks

| game | what is documented | relevance to fire |
| --- | --- | --- |
| Might of Merchants (Quill Peak) | hand-drawn, stylised, minimalist; fire is a town disaster in the economy ([Steam](https://store.steampowered.com/app/1736220/Might_of_Merchants/), [itch.io](https://quillpeak.itch.io/might-of-merchants)) | I found no public technique note on fire or explosions; r/mightofmerchants is not reachable from these tools. Alex may know posts worth reading. |
| Pentiment | palette taken from the pigments of the 1493 Nuremberg Chronicle; deliberate stylistic flattening; religious terms in red ink in the dialogue, like rubrication ([Gamereactor](https://www.gamereactor.eu/how-obsidan-brought-the-past-to-life-in-pentiment-1221583/), [Game Developer](https://www.gamedeveloper.com/art/deep-dive-the-art-of-pentiment), [Wikipedia](https://en.wikipedia.org/wiki/Pentiment_(video_game))) | the 1525 revolt burns the mill and abbey; I could not verify how the flames are drawn |
| Inkulinati | medieval marginalia; units drawn in ink as they act; combat described as sprays of black ink ([Film Stories](https://filmstories.co.uk/gaming/inkulinati-preview-pen-mighty-sword/), [The Sixth Axis](https://www.thesixthaxis.com/2019/10/31/playing-with-history-illuminating-the-insane-game-world-of-inkulinati/)) | violence as ink spatter, not colour |
| Return of the Obra Dinn | 1-bit; dithering made two tones read as grey, and Pope's lesson was to use it as little as possible; blue-noise patterns, reworked so the dots stop swimming as the camera moves ([PlayStation Blog](https://blog.playstation.com/archive/2019/10/17/lucas-pope-on-return-of-the-obra-dinns-art-style), [Kill Screen](https://killscreen.com/articles/return-obra-dinn-update-details-challenges-1-bit-rendering/)) | with two colours, fire can only be value and form; stipple should be sparse and stable |
| Darkest Dungeon | no dead grey or black anywhere but the inks; a warm, slightly yellowed palette; strong linework lets unexpected hits of colour land; Dürer, woodcuts, Mignola as references ([GameSpot](https://www.gamespot.com/articles/the-gothic-sensibilities-of-darkest-dungeon/1100-6424880/), via search summary; [80.lv](https://80.lv/articles/red-hook-studios-talks-about-the-creation-of-darkest-dungeon)) | colour as rare hits inside a warm ink world |
| Valiant Hearts | French comic look, dark muted palette, one artist drawing from reference ([Vice](https://www.vice.com/sv/article/making-of-valiant-hearts-283/)) | explosion treatment not documented |
| The Banner Saga | Eyvind Earle's flattened, detailed style ([Kill Screen](https://killscreen.com/art-trumps-design-banner-saga)) | nothing on fire found |
| Sable | Moebius and ligne claire, muted pastels, readability-driven ([Game Developer](https://www.gamedeveloper.com/marketing/how-shedworks-refined-the-art-of-sable-in-pursuit-of-readability)) | nothing on fire found |
| Heaven's Vault | hand-drawn characters in 3D, after Moebius and Hergé ([inkle](https://www.inklestudios.com/heavensvault/)) | nothing on fire found |

For 80 Days, Hand of Fate, Kingdom Two Crowns and Townscaper I found nothing
documented about fire and have not guessed.

## 3. Principles (proposed)

1. **On paper, light is the paper.** The flash is the lightest value on screen
   -- a knock-out -- and it looks bright because of the dark around it (ink rays,
   stipple, smoke), not because of a saturated colour (chiaroscuro woodcut,
   Goya, Kiyochika, Hollar's blank city).
2. **Heat is ink density plus, at most, a quiet earth colour.** Hue is a
   temperature cue, not the light. Line and dot density carry intensity (Dürer,
   Tardi's smudges, option A's stipple burst).
3. **Fire never out-shouts the sides.** Chroma at or below the side accents'
   0.100; lightness a step on the existing ramp; hue on the warm paper-ink axis
   (h 60-75), well away from brick red's h 30, so "fire" never reads as "side
   A" and "red tint" never reads as "brick" (Sanborn).
4. **Colour goes into the paper, not on top of it.** A wash under the grain
   (Chicago tint over the street grid) or a screen of dots (two-colour strips).
   An opaque, grain-free fill above everything is the sticker.
5. **Cooling goes to ink, never to pastel.** Hot -> earth -> dirt -> ink ->
   scorch mark. The LCC ramp ends in black; the burnt city is blank paper with
   its plan inked over it.
6. **Open marks over closed fills.** Rays, hatch, stipple and spatter read as
   ink (Ban Dainagon's spattered sparks, Inkulinati's ink spray, Nash's
   selective curves). A flat-filled closed shape with an outline reads as a
   badge.
7. **Spend colour rarely.** The first tenths of a second and the embers, not
   the whole decay (rubrication, Mignola, Tardi's single shock). This is also
   Alex's rule in print terms: the *fast flash* may carry colour; the *very
   slow decay* is ink.
8. **Stipple and screens sparingly and stably.** Fixed per-effect seeds so dots
   do not swim between frames (Obra Dinn).

## 4. Candidate treatments (all PROPOSED)

ΔE is Euclidean distance in OKLab. References: the two sides are 0.181 apart;
the rejected fire is 0.182 from side A. All values are inside sRGB.

| # | name | value(s) | hex | L - paper | C vs sides (0.100) | ΔE side A | ΔE side B | ΔE paper | ΔE dirt |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| -- | rejected | oklch(0.72 0.14 56) | #E68B44 | -0.127 | 0.14, louder | 0.182 | 0.289 | 0.164 | 0.299 |
| 1 | Knock-out | flash oklch(0.967 0.016 90) + ink | #F8F4E8 | +0.120 | 0.016 | 0.426 | 0.432 | 0.124 | 0.525 |
| 2 | Scorch | oklch(0.70 0.085 70) | #C19563 | -0.147 | 0.085, quieter | 0.162 | 0.237 | 0.153 | 0.264 |
| 3 | Tempered sienna | oklch(0.66 0.090 52) | #BE825E | -0.187 | 0.090, quieter | 0.115 | 0.214 | 0.196 | 0.227 |
| 4 | Rubric | red lead oklch(0.63 0.120 45), screened 0-40 % over the flash | #C47048 | -0.217 solid; screen average L 0.86-0.92 | 0.12 solid; screen average C 0.023-0.035 | 0.086 solid; 0.32-0.38 as a screen | 0.224 | 0.236 | 0.211 |
| 5 | Lamplight | oklch(0.87 0.090 83) | #F1CF8F | +0.023 | 0.090, quieter | 0.330 | 0.371 | 0.049 | 0.432 |
| 6 | Knock-out + scorch edge | flash (0.967 0.016 90), scorch (0.70 0.085 70), cooling (0.60 0.045 70) | #F8F4E8, #C19563, #927C63 | +0.120 / -0.147 / -0.247 | <= 0.085 | 0.426 / 0.162 / 0.087 | -- | -- | -- |

The flash step is new (paper + 0.12 L, chroma eased to 0.016): the one value
lighter than every fill (object fill 0.925, light fibre 0.944). The cooling
step's 0.087 from side A is a lightness coincidence, not a hue one: it is a
grey-brown at C 0.045, h 70.

### 1. Knock-out -- no fire hue at all

*Idea.* Fire is shown the way a woodcut shows light: the flash is paper knocked
out to the lightest step, and heat is ink -- dense stipple and hatch where the
fire is strongest, thinning as it dies. Accents stay two (the sides).

*Palette.* Flash oklch(0.967 0.016 90) #F8F4E8; ink oklch(0.325 0.026 69) at the
existing alpha steps (dot 0.85, soft 0.55, faint 0.40); dirt for char. No new
hue; hue stays reserved for paper, ink, shadow and the sides.

| moment | drawn as |
| --- | --- |
| flash (0-0.1 s) | a knock-out shape lighter than anything on the map, ringed by short radial ink hatch (option A's) |
| burst (0.1-0.5 s) | knock-out core inside a ring of dense ink stipple; density = heat, thinning over seconds |
| flames on a falling plane | small knock-out tongues with an ink contour and an ink-stipple rim, flickering by redrawn shape, not colour |
| embers | paper-white specks each with an ink dot beside it, then ink dots only |
| smoking wreck | dirt and ink stipple scorch (as today); no colour at any time |

*Fits* C (the white star with ink rays reads strongly as light) and A (the
burst is already ink stipple). Not B: white lobes read as smoke or tree
canopies. *Risk:* at planning zoom (0.35) a burning tree group must be legible
for fog-of-war play (design doc: fire changes the battlefield); with no hue it
has to read by marks alone.

### 2. Scorch -- low-chroma earth spot on the warm axis

*Idea.* Fire is the colour paper turns when it burns: a raw-sienna wash on the
paper-ink hue axis (ink h 69, dirt h 76, scorch h 70), laid under the grain.
It is the palette's own warm axis lifted in chroma, so it adds a role, not a
new hue.

*Palette.* oklch(0.70 0.085 70) #C19563; toward dirt 45 % = oklch(0.587 0.062
71) #947753; toward ink 30 % = oklch(0.594 0.069 70) #997750. L 0.70 is a step
on the ramp between paper and dirt; C 0.085 is below the sides; 0.162 from
brick red, about as far as the sides are from each other.

| moment | drawn as |
| --- | --- |
| flash | the knock-out step for 1-2 frames, scorch only as a thin rim |
| burst | scorch wash under the grain, ink contour, darkening toward dirt as it cools |
| flames on a falling plane | scorch tongues with a knock-out core |
| embers | scorch dots, fading to dirt |
| smoking wreck | a scorch-to-dirt ring on the ground for a turn, then dirt stipple only |

*Fits* A and C; on B it reads as a brown puff close to the smoke. *Risk:* tan
can read as earth or cardboard rather than fire; the mock suggests it reads as
fire only next to a knock-out core.

### 3. Tempered sienna -- today's hue family at earth chroma (the control)

*Idea.* Keep the hue family of the rejected orange and cut it to an earth
pigment: lower chroma, lower lightness, under the grain. It answers the
question "was it only the chroma?".

*Palette.* oklch(0.66 0.090 52) #BE825E. Chroma below the sides; ΔE 0.115 from
brick red, the closest of the wash candidates.

Drawn like candidate 2 throughout. *Fits* B (the smallest change to the current
look). *Risk:* terracotta and brick connotations (Sanborn), nearer side A, and
its pale role goes salmon (see B_0_3 in the sheet).

### 4. Rubric -- the printers' spot red, used sparingly

*Idea.* Black plus one spot colour, as in two-colour printing and rubrication:
a red-lead (minium) ink that never appears as a solid, only as a screen of
dots over the knock-out, and only at the hottest instant and in the sparks.
The texture, not only the hue, separates it from side A's solid accent.

*Palette.* Solid ink oklch(0.63 0.120 45) #C47048, screened at 15 deg, 3.6 px,
0-40 % coverage. The solid is above the sides' chroma and only 0.086 from
brick red; as a screen it averages oklch(0.86-0.92, 0.023-0.035, 53-66), 0.32 or
more from brick red. Usage rules carry the separation: always screened, never
on a unit, gone by 0.3 s.

| moment | drawn as |
| --- | --- |
| flash | knock-out with the densest screen at its rim, 1-2 frames |
| burst | screen coverage falls from 40 % to 0 by 0.3 s; ink hatch and stipple remain |
| flames on a falling plane | small screened tongues with a knock-out core |
| embers | spattered single red-lead dots (the Ban Dainagon spatter), never screened |
| smoking wreck | ink only |

*Fits* C (period print vocabulary) and A. *Risk:* a dot screen at 3-4 px is a
pattern that can read as gingham at close zoom (see `sheet_zoom.png`), and
it needs a screen shader.

### 5. Lamplight -- a gamboge glaze lighter than the paper

*Idea.* Fire as warm light: a pale gamboge glaze that is lighter than the
paper, so it reads as light rather than as an object, with the knock-out at
its core.

*Palette.* oklch(0.87 0.090 83) #F1CF8F. L +0.023 over paper, C below the sides,
hue beside paper's. Far from both sides (0.33, 0.37) but only 0.049 from the
paper.

Drawn like candidate 2, lighter. *Fits* C and D. *Risk:* too close to the paper
to read at planning zoom; on B's lobes it goes buttery.

### 6. Knock-out + scorch edge -- candidates 1 and 2 together

*Idea.* The flash is the knock-out; the scorch earth appears only at the hot
edge for the first few tenths of a second and in the embers; cooling goes to a
grey-brown and ink stipple, then to the existing smoke. Colour lives in the
fast flash; the very slow decay is ink.

*Palette.* Flash oklch(0.967 0.016 90) #F8F4E8; scorch oklch(0.70 0.085 70)
#C19563; cooling oklch(0.60 0.045 70) #927C63; then ink and dirt at the existing
steps. Every chroma at or below 0.085.

| moment | drawn as |
| --- | --- |
| flash (0-0.1 s) | knock-out shape lighter than any fill, ink rays or stipple around it |
| burst (0.1-0.5 s) | scorch wash at the rim, under the grain, around the knock-out core |
| cooling (0.3 s onward) | cooling step plus sparse ink stipple, handing over to the smoke option |
| flames on a falling plane | scorch tongues with a knock-out core, ink contour; flicker by shape |
| embers | scorch dots with ink partners, fading to dirt within a turn |
| smoking wreck | dirt and ink scorch mark; scorch only as a few embers in the first turn |

*Fits* C first (white-hot star, scorch rays, ink), A second. B's lobes are
better kept for smoke than used as the fire shape.

## 5. The mock-ups

**These are recolours of the existing drawings, not new drawings: every shape
is the board's own.** Per pixel, the script estimates how much of the rejected
fire colour it carries (its OKLab offset from the warm neutrals, projected on
the fire direction; offsets toward brick red are left alone, so the planes'
roundels are untouched) and replaces that share with the candidate, linearly in
sRGB as the board blended the roles. Beyond the hue swap:

- the burst's cream core (`burst.core`, object fill) is lifted to the flash
  step in every candidate;
- wash candidates (2, 3, 5, 6) get a paper-grain stand-in over the fire, since
  the board draws fire above the grain;
- 1 adds ink stipple inside the old fire area (density from fire strength), 4
  prints its spot as a dot screen, 6 maps the pale (cooling) role to the
  cooling step plus stipple;
- timing is the board's. A real round would re-time the colour (section 7), so
  candidates 4 and 6 in particular are shown at their worst moment for colour.

Frames: A_0_2, A_2_1 (stipple burst), B_0_2, B_0_3, B_1_3, B_2_1, B_2_2 (lobed
fireball, falling flames), C_0_2, C_2_1, C_1_3 (woodcut blast and its flame),
D_2_1 (restrained).

What the sheets show (the researcher's reading; Alex's eye decides):

- **1 Knock-out**: the C star becomes a white-hot star and reads as light; the
  A disc becomes a stippled ring (lace-like); B's lobes become white puffs that
  read like smoke or tree canopies.
- **2 Scorch**: calm and in the paper's family; it reads as fire next to a
  knock-out core, as caramel or cardboard without one.
- **3 Tempered sienna**: closest to the old look; terracotta at full strength,
  salmon in the pale role.
- **4 Rubric**: unmistakably printed; at close zoom the screen is a busy
  pattern.
- **5 Lamplight**: the softest glow; nearly vanishes into the paper at small
  sizes.
- **6 Knock-out + scorch edge**: identical to 2 at 0.1 s; at 0.3 s the B lobes
  turn grey-brown and stippled and hand over to the smoke instead of going
  peach.
- In every column the A disc and the B lobes stay badge-like: part of
  "cartoony" is the closed, flat-filled shape, which a colour change does not
  fix.

## 6. Recommendation (proposed)

**Treatment 6, Knock-out + scorch edge, on the woodcut form of option C (or
A's stipple burst), with B's lobes kept for smoke.** It follows every
principle above: the flash is the lightest value on screen and gets its
brightness from ink; the only colour is an earth on the paper-ink axis, below
the sides' chroma and as far from brick red as the sides are from each other;
the colour exists only in the fast flash and the embers; the very slow decay is
ink. Treatment 1 is the strict alternative if Alex wants the palette to keep
exactly two accents, provided a burning tree group still reads at planning zoom
(0.35).

What it would change in data, proposed, nothing done:

- `accents.fire` -> oklch(0.70 0.085 70);
- a new top ramp step `flash` (paper + 0.12 L, C 0.016) for `burst.core`;
- `fire.pale` retired; a new `fire.cool` -> oklch(0.60 0.045 70); `fire.dim`
  (toward dirt) and `fire.shade` (toward ink) kept;
- the fire roles drawn under the grain pass (an order change in code, not a
  value);
- the same accent for fx.fire (burning trees and houses) and the fx.muzzle tip,
  which share `acc:fire` in the art-direction plan.

## 7. What a proper in-engine board round should render

A variant board, proposed id `fx.fire_palette` (recorded in
`data/decisions/decisions.json` only once Alex chooses), output under
`variants/fire-palette/`, seed 20261009, the real map, sun NW, shadows 44 %:

- **Columns:** the candidates Alex keeps from `sheet.png` (proposed: 1, 2, 4, 6)
  plus today's value as the reference column.
- **Rows:** (a) mid-air at 0, 0.05, 0.1, 0.3, 1, 3 s and one turn later;
  (b) out of control: the flames at 3 s and 9 s at zoom 1 and 0.35; (c) ground
  impact at 0, 0.1, 0.3, 1 s, then the wreck at one, three and eight turns;
  (d) **fx.fire**: a tree group and a house burning, two turns in, at planning
  zoom 0.35 -- the gameplay legibility test; (e) the fx.muzzle tip; (f) the
  swatch row (rule 6) with a side-A and a side-B plane placed beside the flash,
  so brick red and fire are judged touching.
- **Forms:** each candidate drawn on C's star and A's stipple burst (B's lobes
  as smoke only), so colour and form are not judged together by accident.
- **Timing re-done in the style:** knock-out for the first 1-2 frames, colour
  peak by 0.1 s, colour gone by about 0.5 s except embers, then the smoke
  option's slow decay. A short capture of the sequence in motion, since "fast
  flash, very slow decay" is a judgement about time, not a still.
- **Engine work it needs:** the roles above in `data/fx/fx.json` (no hex in draw
  code); fire drawn under the grain or the grain applied to the fx layer; heat
  as stipple density with a fixed per-effect seed (option A already draws
  stipple); a halftone-screen pass only if candidate 4 survives.
- **Checks (proposed gate invariants):** fire chroma <= side chroma for every
  solid fire role; ΔE_OK(fire role, side A) >= 0.12 for every solid fire role;
  flash L >= the highest fill L + 0.02; fire roles only on fx layers, never on a
  unit.

## Open questions for Alex

1. Is a fire hue wanted at all (treatments 2-6), or should accents stay the two
   sides (treatment 1)?
2. If a hue: the warm axis (scorch, h 70) or nearer today's (sienna, h 52)?
3. Are there Might of Merchants posts on fire or effects (u/mightofmerchants)
   worth reading before the board round? None were reachable from here.
