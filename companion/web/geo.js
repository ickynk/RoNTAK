// Geometry helpers: world (Unreal units) <-> floor-plan image pixels.
// A transform is {a, b, c, d, e, f}:  u = a*x + b*y + e,  v = c*x + d*y + f
(function (root) {
  "use strict";

  // Top-down view used when a floor has no calibration: +X up, +Y right, 0.5 px per unit.
  const DEFAULT = { a: 0, b: 0.5, c: -0.5, d: 0, e: 0, f: 0 };

  // Two anchors: rotation + uniform scale + offset (no mirroring).
  function similarity(p, q) {
    const [x1, y1] = p.world, [x2, y2] = q.world;
    const [u1, v1] = p.px, [u2, v2] = q.px;
    const wx = x2 - x1, wy = y2 - y1, pu = u2 - u1, pv = v2 - v1;
    const den = wx * wx + wy * wy;
    if (den === 0) return null;
    // Complex division s = (pu + i pv) / (wx + i wy) gives scale*rotation; px = s * world + t.
    // Unreal top-down (X up, Y right) and image pixels (v down) share orientation, so no mirroring.
    const sr = (pu * wx + pv * wy) / den;
    const si = (pv * wx - pu * wy) / den;
    const a = sr, b = -si, c = si, d = sr;
    return { a, b, c, d, e: u1 - (a * x1 + b * y1), f: v1 - (c * x1 + d * y1) };
  }

  function solve3(m, r) {
    const det = (A) =>
      A[0][0] * (A[1][1] * A[2][2] - A[1][2] * A[2][1]) -
      A[0][1] * (A[1][0] * A[2][2] - A[1][2] * A[2][0]) +
      A[0][2] * (A[1][0] * A[2][1] - A[1][1] * A[2][0]);
    const D = det(m);
    if (Math.abs(D) < 1e-12) return null;
    return [0, 1, 2].map((col) => det(m.map((row, i) => row.map((v, j) => (j === col ? r[i] : v)))) / D);
  }

  // Three or more anchors: least-squares affine (handles mirrored or stretched images).
  function affine(anchors) {
    const m = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
    const ru = [0, 0, 0], rv = [0, 0, 0];
    for (const { world: [x, y], px: [u, v] } of anchors) {
      const row = [x, y, 1];
      for (let i = 0; i < 3; i++) {
        for (let j = 0; j < 3; j++) m[i][j] += row[i] * row[j];
        ru[i] += row[i] * u;
        rv[i] += row[i] * v;
      }
    }
    const U = solve3(m, ru), V = solve3(m, rv);
    if (!U || !V) return null;
    return { a: U[0], b: U[1], e: U[2], c: V[0], d: V[1], f: V[2] };
  }

  function fit(anchors) {
    if (!anchors || anchors.length < 2) return DEFAULT;
    return (anchors.length === 2 ? similarity(anchors[0], anchors[1]) : affine(anchors)) || DEFAULT;
  }

  function apply(t, x, y) {
    return [t.a * x + t.b * y + t.e, t.c * x + t.d * y + t.f];
  }

  function invert(t) {
    const det = t.a * t.d - t.b * t.c;
    const a = t.d / det, b = -t.b / det, c = -t.c / det, d = t.a / det;
    return { a, b, c, d, e: -(a * t.e + b * t.f), f: -(c * t.e + d * t.f) };
  }

  function pointInPolygon(x, y, poly) {
    let inside = false;
    for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      const [xi, yi] = poly[i], [xj, yj] = poly[j];
      if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  }

  function distToSegment(px, py, [ax, ay], [bx, by]) {
    const dx = bx - ax, dy = by - ay;
    const len = dx * dx + dy * dy;
    const t = len ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len)) : 0;
    return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
  }

  function distToPolygonEdge(x, y, poly) {
    let best = Infinity;
    for (let i = 0; i < poly.length; i++) {
      best = Math.min(best, distToSegment(x, y, poly[i], poly[(i + 1) % poly.length]));
    }
    return best;
  }

  function centroid(poly) {
    const n = poly.length;
    return [poly.reduce((s, p) => s + p[0], 0) / n, poly.reduce((s, p) => s + p[1], 0) / n];
  }

  // Finds floors in a list of heights (e.g. every door's Z). A floor is a
  // height where at least `minCount` doors sit within `window` of each other;
  // floors are at least `separation` apart. Doors in between (stairs,
  // landings, split levels) don't make floors of their own: picking the
  // densest heights first lets them be absorbed by a nearby floor.
  // Returns [{ zMin, zMax, z }] lowest first; neighbouring floors meet halfway
  // between their heights, and the lowest / highest bands are open-ended.
  function floorBands(zs, separation = 200, minCount = 2, window = 60) {
    const heights = zs.filter((z) => Number.isFinite(z)).sort((a, b) => a - b);
    if (!heights.length) return [];
    const near = (z) => heights.filter((h) => Math.abs(h - z) <= window);
    let candidates = heights.slice();
    const floors = [];
    while (candidates.length) {
      let best = null, bestCount = 0;
      for (const z of candidates) {
        const n = near(z).length;
        if (n > bestCount) { best = z; bestCount = n; }
      }
      if (bestCount < minCount && floors.length) break;
      const cluster = near(best);
      floors.push(cluster.reduce((sum, h) => sum + h, 0) / cluster.length);
      candidates = candidates.filter((z) => Math.abs(z - best) > separation);
    }
    floors.sort((a, b) => a - b);
    const OPEN = 1e7;
    return floors.map((z, i) => ({
      z,
      zMin: i === 0 ? -OPEN : (floors[i - 1] + z) / 2,
      zMax: i === floors.length - 1 ? OPEN : (z + floors[i + 1]) / 2,
    }));
  }

  const api = { DEFAULT, fit, apply, invert, pointInPolygon, distToPolygonEdge, centroid, floorBands };
  root.Geo = api;
  if (typeof module !== "undefined") module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
