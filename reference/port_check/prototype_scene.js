#!/usr/bin/env node
'use strict';
// Runs the PROTOTYPE'S OWN scene generator and writes the default scene -- seed
// 20261009 on a 1280x720 stage -- to expected_scene_20261009.json beside this
// file. scripts/tests/test_scene_gen.gd generates the same scene with the
// GDScript port (scripts/world/) and compares object for object, bit for bit.
//
// Nothing is retyped. The functions, the `const P={...}` defaults, the
// constants and the scene state are sliced out of reference/inkwood-renderer.html
// by name (brace matching, as prototype_sample.js does) and evaluated as they
// stand, in one strict-mode scope so they share W, H, trees, props, structs,
// grid and roadPts as they do in the page. The only stand-ins are for the
// canvas, and none of them touches the scene's random stream:
//   buildTreeSprite / buildPropSprite  sprite = null, half = 0 (they draw from
//                                      their own mulberry32(seed), never the scene's)
//   drawWall / drawHouse               syncStruct's canvas part (likewise their own
//                                      mulberry32(s.seed)); syncStruct itself runs
//                                      verbatim, geometry, h and bounds included
//   document.createElement, DPR        the canvas syncStruct sizes; DPR only scales it
//   requestRender                      a no-op
// The page's resize() runs buildRoad(); buildGround(); buildGrain(); newScene(20261009)
// on first layout; ground and grain are pixels, so this runs buildRoad() and
// newScene(20261009) at the Godot viewport size.
//
// Floats are written as { value, bits }: `bits` is the little-endian IEEE-754
// bytes of the double (what PackedFloat64Array.to_byte_array().hex_encode()
// gives), because Godot's float parser is not exact past 15 significant digits
// and a decimal can agree while the bits do not. Point lists are written as
// { values: [[x, y], ...], bits: ["<x bits><y bits>", ...] } (32 hex digits a point).
//
// Re-run only when the prototype changes:   node reference/port_check/prototype_scene.js

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

// `function NAME(...) {...}` by brace matching.
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

// A `const ...;` / `let ...;` statement: from its head to the first `;` outside brackets.
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

const W = 1280, H = 720, SEED = 20261009;

const statements = ['const LX=', 'const CELL=', 'const P=', 'let W=0,H=0,', 'const cr=', 'const maxCr='];
const functions = [
  'mulberry32', 'hash2', 'vnoise', 'fbm',
  'makeTree', 'makeProp', 'syncTree',
  'rrectLocal', 'resample', 'chaikin', 'wallCenterline', 'wallGeom', 'houseParts',
  'makeHouse', 'makeWall', 'makeFort', 'syncStruct', 'sDist', 'addStruct',
  'gAdd', 'gRebuild', 'gQuery', 'roadDist', 'canPlace', 'buildRoad', 'newScene',
];
const standIns = `
const DPR = 1;
function buildTreeSprite(t) { t.sprite = null; t.half = 0; }
function buildPropSprite(p) { p.sprite = null; p.half = 0; }
function drawWall(g, s) {}
function drawHouse(g, s) {}
function requestRender() {}
const document = { createElement: () => ({ width: 0, height: 0, getContext: () => ({ setTransform() {} }) }) };
`;
const body = [
  '"use strict";',
  ...statements.map(sliceStatement),
  standIns,
  ...functions.map(slice),
  `W = ${W}; H = ${H};
   buildRoad();
   newScene(${SEED});
   // Not part of the scene: one freehand OPEN wall with round caps, which the
   // default scene never makes (the fort's walls are closed or capless), so the
   // caps branch of wallGeom and the "free" centre line get checked too. The
   // stroke is a seeded random walk; it goes through finishWall's own pipeline
   // (resample, chaikin twice, resample) and makeWall + syncStruct as they
   // stand, with a seeded rng where finishWall passes Math.random. It is not
   // added to the scene.
   const walk = mulberry32(${SEED} + 7), stroke = [];
   let wx = 300, wy = 500;
   for (let i = 0; i < 30; i++) { wx += 8 + walk() * 4; wy += (walk() - .5) * 10; stroke.push([wx, wy]); }
   const fpts = resample(chaikin(chaikin(resample(stroke, 6, false), false), false), 3, false);
   const free = makeWall(mulberry32(${SEED} + 8), {type: "free", pts: fpts}, {closed: false, caps: true});
   syncStruct(free);
   return { P, CELL, ROAD_HALF, LX, LY, maxCr: maxCr(), trees, props, structs, roadPts, grid, free, stroke };`,
].join('\n');
const S = new Function(body)();

// --- serialisation ------------------------------------------------------------
const dv = new DataView(new ArrayBuffer(8));
const bits = x => {
  dv.setFloat64(0, x, true);
  let s = '';
  for (let i = 0; i < 8; i++) s += dv.getUint8(i).toString(16).padStart(2, '0');
  return s;
};
const f = x => {
  if (typeof x !== 'number') throw new Error(`expected a number, got ${x}`);
  return { value: x, bits: bits(x) };
};
const points = list => ({ values: list.map(p => [p[0], p[1]]), bits: list.map(p => bits(p[0]) + bits(p[1])) });
// Every own field of a plain record: numbers as f(), the rest as they are.
const record = o => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, typeof v === 'number' ? f(v) : v]));

const tree = t => ({ seed: t.seed, big: t.big, x: f(t.x), y: f(t.y), sr: f(t.sr), hr: f(t.hr), r: f(t.r), h: f(t.h) });
const prop = p => ({ type: p.type, seed: p.seed, x: f(p.x), y: f(p.y), s: f(p.s), rot: f(p.rot), h: f(p.h) });
const bounds = s => ({ bx: s.bx, by: s.by, bw: s.bw, bh: s.bh });
function struct(s) {
  if (s.kind === 'wall') {
    const gen = {};
    for (const [k, v] of Object.entries(s.gen)) gen[k] = typeof v === 'number' ? f(v) : k === 'pts' ? points(v) : v;
    return {
      kind: 'wall', gen, ws: f(s.ws), hs: f(s.hs), closed: s.closed, seed: s.seed, h: f(s.h), hw: f(s.hw), ...bounds(s),
      // wallGeom has replaced the makeWall flag with the cap polygons by now.
      caps: s.caps.map(points),
      outline: s.outline.map(o => o.length), edges: s.edges.map(e => ({ n: e.p.length, closed: e.closed })),
      pts: points(s.pts), nrm: points(s.nrm), L: points(s.L), R: points(s.R),
    };
  }
  return {
    kind: 'house', x: f(s.x), y: f(s.y), rot: f(s.rot), hs: f(s.hs), chimney: s.chimney, seed: s.seed, h: f(s.h), ...bounds(s),
    parts: s.parts.map(record),
    geo: s.geo.map(g => ({ cx: f(g.cx), cy: f(g.cy), w: f(g.w), d: f(g.d), cc: f(g.cc), ss: f(g.ss), corners: points(g.corners) })),
  };
}
const road = [];
for (let i = 0; i < S.roadPts.length; i += 10) road.push(i);
if (road[road.length - 1] !== S.roadPts.length - 1) road.push(S.roadPts.length - 1);

const P = {};
for (const [k, v] of Object.entries(S.P)) P[k] = typeof v === 'number' ? f(v) : v;
let gridObjects = 0;
for (const a of S.grid.values()) gridObjects += a.length;

const out = {
  _about: 'The prototype\'s default scene (seed 20261009, 1280x720 stage), generated by prototype_scene.js from inkwood-renderer.html. Read by scripts/tests/test_scene_gen.gd. Do not edit by hand. Floats are {value, bits} with bits the little-endian IEEE-754 bytes; point lists are {values, bits} with 32 hex digits (x then y) a point.',
  generated_by: { node: process.version, v8: process.versions.v8 },
  seed: SEED, w: W, h: H,
  P, constants: { CELL: S.CELL, ROAD_HALF: S.ROAD_HALF, LX: f(S.LX), LY: f(S.LY), maxCr: f(S.maxCr) },
  counts: {
    trees: S.trees.length, props: S.props.length, structs: S.structs.length,
    walls: S.structs.filter(s => s.kind === 'wall').length, houses: S.structs.filter(s => s.kind === 'house').length,
    road: S.roadPts.length, grid_cells: S.grid.size, grid_objects: gridObjects,
  },
  road: road.map(i => ({ i, x: f(S.roadPts[i].x), y: f(S.roadPts[i].y), nx: f(S.roadPts[i].nx), ny: f(S.roadPts[i].ny) })),
  structs: S.structs.map(struct),
  free_wall: { stroke: points(S.stroke), wall: struct(S.free) },
  props: S.props.map(prop),
  trees: S.trees.map(tree),
};

// One object a line under the long arrays, so the file stays diffable without
// running to a hundred thousand lines.
const lines = ['{'];
const keys = Object.keys(out);
keys.forEach((k, ki) => {
  const comma = ki < keys.length - 1 ? ',' : '';
  const v = out[k];
  if (Array.isArray(v) && v.length && typeof v[0] === 'object') {
    lines.push(`  ${JSON.stringify(k)}: [`);
    v.forEach((e, i) => lines.push(`    ${JSON.stringify(e)}${i < v.length - 1 ? ',' : ''}`));
    lines.push(`  ]${comma}`);
  } else {
    lines.push(`  ${JSON.stringify(k)}: ${JSON.stringify(v)}${comma}`);
  }
});
lines.push('}');
const target = path.join(here, `expected_scene_${SEED}.json`);
fs.writeFileSync(target, lines.join('\n') + '\n');

// The same summary test_scene_gen.gd prints, for a side-by-side read: 17
// significant digits, trailing zeros dropped (prototype_sample.js's format).
const g = x => x.toPrecision(17).replace(/\.?0+$/, '');
const t0 = S.trees[0], p0 = S.props[0];
const walls = S.structs.filter(s => s.kind === 'wall');
console.log(`scene ${SEED} at ${W}x${H}: ${S.trees.length} trees, ${S.props.length} props, ${S.structs.length} structures (${out.counts.walls} walls, ${out.counts.houses} houses), road ${S.roadPts.length} samples, grid ${S.grid.size} cells / ${gridObjects} objects`);
console.log(`walls: ${walls.map(s => `${s.gen.type} ${s.pts.length} pts seed ${s.seed}`).join(', ')}`);
console.log(`first tree: (${g(t0.x)}, ${g(t0.y)}) r=${g(t0.r)} h=${g(t0.h)} seed=${t0.seed} big=${t0.big}`);
console.log(`first prop: ${p0.type} (${g(p0.x)}, ${g(p0.y)}) s=${g(p0.s)} seed=${p0.seed}`);
console.log(`free wall: ${S.free.pts.length} pts, caps ${S.free.caps[0].length} + ${S.free.caps[1].length} pts, outline ${S.free.outline[0].length}, seed ${S.free.seed}`);
console.log(`wrote ${path.relative(process.cwd(), target)} (node ${process.version}, V8 ${process.versions.v8})`);
