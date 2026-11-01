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

  // ------------------------------------------------------------ rooms from walls

  // Finds rooms in traced walls ([x1, y1, x2, y2] segments, world cm).
  // The walls are drawn onto a grid and thickened by closeCm, which closes
  // gaps up to about 2 * closeCm: ordinary doorways, archways, and windows
  // the trace passed through. Wider openings are closed with a plug around
  // each door marker (double doors). Every enclosed area is a room. All
  // areas, the outdoors included, are then grown back out to the real walls
  // together, so they meet in the middle of each gap and the thickening
  // doesn't eat into the rooms. Areas touching the edge (outdoors) and areas
  // outside minM2..maxM2 are dropped. Returns outlines: [[x, y], ...] in world cm.
  function roomsFromWalls(walls, doors, opts = {}) {
    const cell = opts.cell || 15;
    const closeCm = opts.closeCm ?? 45;
    const plugCm = opts.plugCm ?? 110;
    const minM2 = opts.minM2 ?? 2, maxM2 = opts.maxM2 ?? 600;
    if (!walls.length) return [];
    const xs = walls.flatMap((w) => [w[0], w[2]]), ys = walls.flatMap((w) => [w[1], w[3]]);
    const pad = closeCm + plugCm + 2 * cell;
    const x0 = Math.min(...xs) - pad, y0 = Math.min(...ys) - pad;
    const W = Math.ceil((Math.max(...xs) + pad - x0) / cell) + 1;
    const H = Math.ceil((Math.max(...ys) + pad - y0) / cell) + 1;
    const at = (i, j) => j * W + i;
    const toCell = (x, y) => [Math.round((x - x0) / cell), Math.round((y - y0) / cell)];

    // Walls, one cell thick each side of the traced line.
    const wall = new Uint8Array(W * H);
    for (const [ax, ay, bx, by] of walls) {
      const steps = Math.max(1, Math.ceil(Math.hypot(bx - ax, by - ay) / (cell / 2)));
      for (let s = 0; s <= steps; s++) {
        const [i, j] = toCell(ax + ((bx - ax) * s) / steps, ay + ((by - ay) * s) / steps);
        for (let dj = -1; dj <= 1; dj++) {
          for (let di = -1; di <= 1; di++) {
            const ii = i + di, jj = j + dj;
            if (ii >= 0 && jj >= 0 && ii < W && jj < H) wall[at(ii, jj)] = 1;
          }
        }
      }
    }
    // Thickened walls plus door plugs: rooms are separated in this.
    const closed = dilate(wall, W, H, Math.round(closeCm / cell));
    const r = Math.round(plugCm / cell);
    for (const d of doors) {
      const [ci, cj] = toCell(d.x, d.y);
      for (let dj = -r; dj <= r; dj++) {
        for (let di = -r; di <= r; di++) {
          const ii = ci + di, jj = cj + dj;
          if (di * di + dj * dj <= r * r && ii >= 0 && jj >= 0 && ii < W && jj < H) closed[at(ii, jj)] = 1;
        }
      }
    }
    // Label the enclosed areas.
    const label = new Int32Array(W * H);
    const queue = new Int32Array(W * H);
    const keep = [0];
    let next = 0;
    for (let start = 0; start < W * H; start++) {
      if (closed[start] || label[start]) continue;
      next++;
      let head = 0, tail = 0, edge = false;
      queue[tail++] = start;
      label[start] = next;
      while (head < tail) {
        const k = queue[head++];
        const i = k % W, j = (k - i) / W;
        if (i === 0 || j === 0 || i === W - 1 || j === H - 1) edge = true;
        for (const n of [k - 1, k + 1, k - W, k + W]) {
          const ni = n % W;
          if (n < 0 || n >= W * H || Math.abs(ni - i) > 1 || closed[n] || label[n]) continue;
          label[n] = next;
          queue[tail++] = n;
        }
      }
      keep.push(!edge);
    }
    // Grow every area back into the thickening and plugs (not into walls).
    // The outdoors grows too, so a room can't spread out through a gap.
    let frontier = [];
    for (let k = 0; k < W * H; k++) if (label[k]) frontier.push(k);
    while (frontier.length) {
      const grown = [];
      for (const k of frontier) {
        const i = k % W;
        for (const n of [k - 1, k + 1, k - W, k + W]) {
          if (n < 0 || n >= W * H || Math.abs((n % W) - i) > 1) continue;
          if (label[n] || wall[n] || !closed[n]) continue;
          label[n] = label[k];
          grown.push(n);
        }
      }
      frontier = grown;
    }
    for (let k = 0; k < W * H; k++) if (label[k] && !keep[label[k]]) label[k] = 0;
    // Outline each room.
    const cellsOf = new Map();
    for (let k = 0; k < W * H; k++) {
      if (!label[k]) continue;
      if (!cellsOf.has(label[k])) cellsOf.set(label[k], []);
      cellsOf.get(label[k]).push(k);
    }
    const rooms = [];
    for (const [id, cells] of cellsOf) {
      const m2 = (cells.length * cell * cell) / 10000;
      if (m2 < minM2 || m2 > maxM2) continue;
      const ring = outline(cells, (k) => label[k] === id, W);
      const simple = simplify(ring, 1.5);
      if (simple.length >= 3) rooms.push(simple.map(([i, j]) => [x0 + (i - 0.5) * cell, y0 + (j - 0.5) * cell]));
    }
    return rooms;
  }

  // Grows set cells by radius (square neighbourhood), as a new grid.
  function dilate(grid, W, H, radius) {
    let cur = grid.slice();
    for (let n = 0; n < radius; n++) {
      const out = cur.slice();
      for (let j = 0; j < H; j++) {
        for (let i = 0; i < W; i++) {
          if (cur[j * W + i]) continue;
          for (let dj = -1; dj <= 1 && !out[j * W + i]; dj++) {
            for (let di = -1; di <= 1; di++) {
              const ii = i + di, jj = j + dj;
              if (ii >= 0 && jj >= 0 && ii < W && jj < H && cur[jj * W + ii]) { out[j * W + i] = 1; break; }
            }
          }
        }
      }
      cur = out;
    }
    return cur;
  }

  // The outer boundary of a set of cells, as grid-corner points.
  function outline(cells, inside, W) {
    const next = new Map();
    const add = (a, b) => next.set(a[0] + "," + a[1], b);
    for (const k of cells) {
      const i = k % W, j = (k - i) / W;
      // Edges with the room on the left, walking round each cell's open sides.
      if (!inside(k - W) || j === 0) add([i, j], [i + 1, j]);
      if (!inside(k + 1) || (k + 1) % W === 0) add([i + 1, j], [i + 1, j + 1]);
      if (!inside(k + W)) add([i + 1, j + 1], [i, j + 1]);
      if (!inside(k - 1) || i === 0) add([i, j + 1], [i, j]);
    }
    let best = [];
    const seen = new Set();
    for (const key of next.keys()) {
      if (seen.has(key)) continue;
      const ring = [];
      let cur = key;
      while (!seen.has(cur) && next.has(cur)) {
        seen.add(cur);
        const [ci, cj] = cur.split(",").map(Number);
        ring.push([ci, cj]);
        const b = next.get(cur);
        cur = b[0] + "," + b[1];
      }
      if (ring.length > best.length) best = ring;
    }
    return best;
  }

  // Ramer-Douglas-Peucker on a closed ring.
  function simplify(ring, tolerance) {
    if (ring.length < 4) return ring;
    let far = 0, farD = -1;
    for (let k = 1; k < ring.length; k++) {
      const d = Math.hypot(ring[k][0] - ring[0][0], ring[k][1] - ring[0][1]);
      if (d > farD) { far = k; farD = d; }
    }
    const half = (pts) => {
      if (pts.length < 3) return pts;
      const [a, b] = [pts[0], pts[pts.length - 1]];
      let idx = 0, dmax = 0;
      for (let k = 1; k < pts.length - 1; k++) {
        const d = distToSegment(pts[k][0], pts[k][1], a, b);
        if (d > dmax) { idx = k; dmax = d; }
      }
      if (dmax <= tolerance) return [a, b];
      const left = half(pts.slice(0, idx + 1)), right = half(pts.slice(idx));
      return left.slice(0, -1).concat(right);
    };
    const first = half(ring.slice(0, far + 1)), second = half(ring.slice(far).concat([ring[0]]));
    return first.slice(0, -1).concat(second.slice(0, -1));
  }

  const api = { DEFAULT, fit, apply, invert, pointInPolygon, distToPolygonEdge, centroid, floorBands, roomsFromWalls };
  root.Geo = api;
  if (typeof module !== "undefined") module.exports = api;
})(typeof window !== "undefined" ? window : globalThis);
