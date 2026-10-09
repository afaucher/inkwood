#!/usr/bin/env node
'use strict';
// Runs the PROTOTYPE'S OWN draw routines (reference/inkwood-renderer.html)
// against a stand-in canvas and writes what the drawing port must agree with
// to expected_render_20261009.json beside this file. Read by
// scripts/tests/test_render_layer.gd.
//
// What it records:
//   draws    -- how many rng() draws each sprite builder takes from its own
//               mulberry32(seed) for a set of FIXED objects (trees, each prop
//               type, the walls of one fort, houses with and without a wing,
//               the road, the ground's specks and darts). The draw routines
//               branch on rng() and on geometry, so the count is what keeps
//               the GDScript port's stream aligned with the browser's: one
//               draw too few or too many and every later lobe, ring break,
//               stipple dot and pebble lands somewhere else.
//   scallop  -- the points of one scallop() contour (geometry, to 1e-3 px).
//   paper    -- the 1/3-resolution paper tint of a 48x30 ground, as the
//               Uint8ClampedArray stores it (round to nearest).
//
// Nothing is retyped: the functions and constants are sliced out of the page
// by name (brace matching, as prototype_scene.js does) and run as they stand.
// The stand-ins are the canvas (every method a no-op, every property
// assignable), document.createElement, and mulberry32, wrapped so each
// generator it makes counts its own draws. The fixed objects are built with
// the prototype's own makeTree / makeProp / makeFort / makeHouse from fixed
// seeds -- the test builds the same objects with scripts/world/ -- so this
// does not depend on the default scene staying what it is.
//
// Re-run when the prototype changes:   node reference/port_check/prototype_render_sample.js

const fs = require('fs');
const path = require('path');

const here = __dirname;
const html = fs.readFileSync(path.join(here, '..', 'inkwood-renderer.html'), 'utf8');

function unique(needle) {
  const at = html.indexOf(needle);
  if (at < 0) throw new Error(`prototype has no "${needle}"`);
  if (html.indexOf(needle, at + 1) >= 0) throw new Error(`"${needle}" is not unique in the prototype`);
  return at;
}
function slice(name) {
  const start = unique(`function ${name}(`);
  let i = html.indexOf('{', start);
  let depth = 0;
  for (; i < html.length; i++) {
    if (html[i] === '{') depth++;
    else if (html[i] === '}' && --depth === 0) break;
  }
  return html.slice(start, i + 1);
}
function sliceStatement(head) {
  const start = unique(head);
  let depth = 0;
  for (let i = start; i < html.length; i++) {
    const ch = html[i];
    if (ch === '(' || ch === '[' || ch === '{') depth++;
    else if (ch === ')' || ch === ']' || ch === '}') depth--;
    else if (ch === ';' && depth === 0) return html.slice(start, i + 1);
  }
  throw new Error(`unterminated statement "${head}"`);
}

const SEED = 20261009;

const statements = ['const PAPER=', 'const LX=', 'const CELL=', 'const P=', 'let W=0,H=0,',
  'const hexRGB=', 'const mix=', 'const cr=', 'const maxCr='];
const functions = [
  'hash2', 'vnoise', 'fbm', 'shadowDir', 'hull',
  'scallop', 'tracePath', 'drawLobe', 'buildTreeSprite', 'buildPropSprite',
  'makeTree', 'makeProp', 'syncTree', 'syncProp',
  'rrectLocal', 'resample', 'chaikin', 'wallCenterline', 'wallGeom', 'addPoly', 'drawWall',
  'houseParts', 'drawHouse', 'makeHouse', 'makeWall', 'makeFort', 'syncStruct',
  'buildRoad', 'drawRoad', 'buildGround',
];
const standIns = `
const DPR = 1;
// mulberry32, wrapped: every generator records its seed and how many draws it gave.
${slice('mulberry32').replace('function mulberry32(', 'function mulberry32Real(')}
const MADE = [];
function mulberry32(a) { const f = mulberry32Real(a), rec = { seed: a, draws: 0 }; MADE.push(rec); return () => { rec.draws++; return f(); }; }
// A canvas context that accepts everything and draws nothing (createImageData
// hands back a real buffer, which buildGround writes its paper tint into).
const stubCtx = () => new Proxy({ createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }) },
  { get: (o, k) => (k in o ? o[k] : () => {}), set: (o, k, v) => { o[k] = v; return true; } });
const document = { createElement: () => ({ width: 0, height: 0, getContext: () => stubCtx() }) };
const gctx = stubCtx();
let ground = { width: 0, height: 0 };
`;
const body = [
  '"use strict";',
  ...statements.map(sliceStatement),
  standIns,
  ...functions.map(slice),
  `
  // Draws taken from each generator created while fn runs, as [{seed, draws}].
  const counted = fn => { MADE.length = 0; fn(); return MADE.map(r => ({ seed: r.seed, draws: r.draws })); };
  const out = { trees: [], props: [], walls: [], houses: [] };

  // Trees: makeTree from fixed seeds (syncTree sets r from sr/big; its sprite
  // build is the one counted). Big and small both appear.
  for (const s of [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]) {
    const t = makeTree(mulberry32Real(s), 100, 100);
    const c = counted(() => syncTree(t));
    out.trees.push({ maker_seed: s, seed: t.seed, sr: t.sr, big: t.big, r: t.r, draws: c[0].draws });
  }
  // Props: a run of seeds until every type has appeared twice.
  const seen = { rock: 0, barrel: 0, crate: 0 };
  for (let s = 100; Object.values(seen).some(v => v < 2); s++) {
    const p = makeProp(mulberry32Real(s), 200, 200);
    if (seen[p.type] >= 2) continue;
    seen[p.type]++;
    const c = counted(() => syncProp(p));
    out.props.push({ maker_seed: s, type: p.type, seed: p.seed, s: p.s, rot: p.rot, draws: c[0].draws });
  }
  // Walls: one fort (ring, divider, inner ring) from a fixed generator.
  for (const w of makeFort(mulberry32Real(5), 640, 300, 340, -0.3)) {
    const c = counted(() => syncStruct(w));
    out.walls.push({ type: w.gen.type, closed: w.closed, seed: w.seed, n: w.pts.length, draws: c[0].draws });
  }
  // Houses: generator seeds picked so both shapes (wing / no wing) appear.
  for (const s of [6, 7, 8, 9]) {
    const h = makeHouse(mulberry32Real(s), 500, 400, 0.4);
    const c = counted(() => syncStruct(h));
    out.houses.push({ maker_seed: s, parts: h.parts.length, chimney: h.chimney, seed: h.seed, draws: c[0].draws });
  }
  // Road and ground on a small stage: buildGround draws its specks and darts
  // from mulberry32(4242) and then drawRoad from mulberry32(77).
  W = 160; H = 90;
  buildRoad();
  {
    const c = counted(() => buildGround());
    out.ground = { W, H, road_samples: roadPts.length, streams: c };
  }
  {
    W = 1280; H = 720;
    buildRoad();
    const c = counted(() => drawRoad(gctx));
    out.road = { W, H, road_samples: roadPts.length, streams: c };
  }

  // scallop(): one contour with drawLobe's inputs drawn from mulberry32(SEED).
  {
    const rng = mulberry32Real(${SEED});
    const x = 3.5, y = -2.25, R = 12.3, n = Math.max(5, Math.round(4.5 + R / 3)), ph = rng() * Math.PI, ns = (rng() * 1e6) | 0;
    const amps = Array.from({ length: n }, () => .13 + rng() * .12);
    const pts = scallop(x, y, R, n, ph, amps, P.wob, ns);
    out.scallop = { x, y, R, n, ph, ns, amps, wob: P.wob, points: pts };
  }

  // The paper tint at 1/3 resolution, verbatim from buildGround's first loop.
  {
    const W = 48, H = 30, S = 3, lw = Math.ceil(W / S) + 1, lh = Math.ceil(H / S) + 1, d = new Uint8ClampedArray(lw * lh * 4);
    for (let y = 0; y < lh; y++) for (let x = 0; x < lw; x++) {
      const wx = x * S, wy = y * S, n = fbm(wx * .008, wy * .008, 11, 4), m = fbm(wx * .0025, wy * .0025, 23, 3), k = .93 + .11 * n, i = (y * lw + x) * 4;
      d[i] = PAPER[0] * k + (m - .5) * 14; d[i + 1] = PAPER[1] * k + (m - .5) * 8; d[i + 2] = PAPER[2] * k - (m - .5) * 8; d[i + 3] = 255;
    }
    out.paper = { W, H, S, lw, lh, rgb: Array.from({ length: lw * lh }, (_, j) => [d[j * 4], d[j * 4 + 1], d[j * 4 + 2]]) };
  }
  return out;`,
].join('\n');
const R = new Function(body)();

const result = Object.assign({
  _about: 'Prototype output for the drawing port, generated by prototype_render_sample.js from inkwood-renderer.html. Read by scripts/tests/test_render_layer.gd. Do not edit by hand.',
}, R);
const outPath = path.join(here, 'expected_render_20261009.json');
fs.writeFileSync(outPath, JSON.stringify(result, null, 1) + '\n');
console.log(`trees: ${R.trees.map(t => t.draws).join(' ')}`);
console.log(`props: ${R.props.map(p => p.type + ':' + p.draws).join(' ')}`);
console.log(`walls: ${R.walls.map(w => w.type + '/' + w.n + ':' + w.draws).join(' ')}`);
console.log(`houses: ${R.houses.map(h => h.parts + 'p' + (h.chimney ? '+c' : '') + ':' + h.draws).join(' ')}`);
console.log(`ground (${R.ground.W}x${R.ground.H}): ${R.ground.streams.map(s => s.seed + ':' + s.draws).join(' ')}`);
console.log(`road (${R.road.W}x${R.road.H}, ${R.road.road_samples} samples): ${R.road.streams.map(s => s.seed + ':' + s.draws).join(' ')}`);
console.log(`scallop: ${R.scallop.points.length} points; paper ${R.paper.lw}x${R.paper.lh}`);
console.log(`wrote ${path.relative(process.cwd(), outPath)}`);
