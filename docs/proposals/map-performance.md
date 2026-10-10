# Map performance: findings for a later milestone -- RECORDED, NOT DECIDED

Alex, 2026-10-09: "Let's do the easy ones and record the findings for execution as a later
milestone with decisions made then (not now)." The easy ones (the fog layer's async read-back
and off-main-thread recording; scheduling quick wins) are being built in the first-fight pass.
Everything below waits for that later milestone, and every choice in it is Alex's to make then.

Source: an Opus investigation on 2026-10-09. Probes and logs are in `tmp/perf/` (gitignored;
`bake_probe.gd`, `probe_baker.gd`, `cached_baker.gd`, `priority_baker.gd`, `sandbox_probe.gd`,
`sprite_bench.gd`). Numbers vary by about +-2 s between runs (other agents shared the machine).

## What was measured

Per chunk at 2 px/m (1024 px chunks, 4096 px supersampled targets), cold; mean of 30 chunks:

| Work | Where | ms per chunk |
| --- | --- | --- |
| Terrain generation | worker, the serial terrain lane | 255 |
| Shadow silhouettes, contours (tessellated under the terrain lock) | worker, terrain lane | 192 |
| Ground: 11.6k specks and fibres, 87k dirt noise samples | worker, parallel | 581 |
| Tree sprites (~374 per chunk) | worker | 2,099 (5.6 ms each on 8 threads, 3.15 ms alone) |
| Baker GDScript inside the 6 ms/frame budget | main | 212 (sprite submission 120) |
| Engine command recording for the bake viewports | main | ~70 |
| GPU: the chunk's canvases / its sprites | GPU | 5.4 / ~185 (28.5 canvas groups per sprite) |
| Render and read-back round trips | frames | 6 per chunk, 2-3 frames each |

- Totals: ~3.1 s worker CPU per chunk (sprites 67%), ~0.28 s main thread, ~0.19 s GPU.
- Worker slots were 47% busy: the rest waited on the serial terrain lane (53% busy), the
  main-thread budget and render round trips. More threads would not help.
- Real sandbox: first view at 1280x720 playable after 9.6-15.2 s (6 chunks); maximized at
  3840x2054, 28.4 s (15 chunks). A map-scale change: 15-25 s.
- Pop-in: unbaked chunks inside vision show blank paper; outside vision the fog's opaque
  topographic layer covers them (but they are still baked at full cost). Views land in bursts
  because up to 8 jobs advance round-robin and sprite pages take every free worker slot.
- Choppy frames after pans: every frame over 50 ms had a fog topographic bake in it
  (synchronous `texture_2d_get`). Async read-back alone: 24 -> 6 such frames per two pans.
- The sandbox builds two Terrain instances (map provider; fog/camera/UI), so terrain is
  generated twice, the fog's copy on the main thread.

## Options recorded for the milestone (gain / cost / risk as estimated then)

1. **Disk cache of finished chunks**, keyed by seed, scale, pen, tree pool and a hash of the
   code and data inputs. Prototype: repeat views and scale switches 15-20 s -> about 0.2 s.
   Cost: ~25 ms per chunk to write; 2.4 MB per chunk; ~240 MB per seed at 2 px/m, ~1.3 GB for
   all four scales, so it needs a size cap with oldest-first eviction. Risk: a stale cache if
   the key misses an input. No help for a new seed's first view.
   *To decide then: whether to build it, the cap, where it lives.*
2. **What unbaked ground shows meanwhile**: blank paper (today), the topographic map resolving
   into ink (the design doc's fog rule), or stretched old chunks after a scale change.
   *To decide then, from a variant board.*
3. **A new seed's first view**: a GDExtension in C++ for InkCanvas tessellation and the
   sprite, ground and terrain loops (estimated 15 s -> 2-4 s, not measured; large cost;
   reopens the build-tooling decision and the GDScript question); the tree pool (2.5x faster,
   trees repeat: a look change); or accept 10-15 s behind the loading card.
   *To decide then.*
4. **Unserialize the terrain lane**: tessellate outside the lock, generate in parallel, share
   one Terrain between map, fog and UI. Becomes the limit as soon as sprites get cheaper.
   Medium cost and risk (thread safety; `test_terrain` covers determinism).
5. **One render round trip per chunk instead of six** (chain the mask viewports in a frame):
   at most ~30% judging by a vsync-off run. Medium cost and risk.
6. **GDScript thread contention** (3.15 ms per sprite alone vs 5.6 ms on 8 threads; suspected
   shared refcounts): small cost, unknown gain.

Not worth it (measured or reasoned then): more threads or another pool; a lower-resolution
first pass (cost is per object, not per pixel); bigger chunks; recording geometry once in metres
(trees are placed per scale).
