// Map generator: seeded noise shaped by a preset, cut by percentiles so the
// requested share of each colour is what you get, then cleaned up.

import { EMPTY, GROUND, LOWERED, RAISED, PixelMap, PixelClass, clampSize } from "./pixels";
import { fbm, mulberry32 } from "./random";

export type Shape = "island" | "archipelago" | "continent" | "lake" | "valley" | "plateau";

export const SHAPES: { id: Shape; name: string; hint: string }[] = [
  { id: "island", name: "Island", hint: "One island surrounded by empty pixels." },
  { id: "archipelago", name: "Archipelago", hint: "Several islands of different sizes." },
  { id: "continent", name: "Continent", hint: "Land everywhere, touching the edges, with a few holes." },
  { id: "lake", name: "Central Lake", hint: "Land around a lowered (blue) basin in the middle." },
  { id: "valley", name: "Valley", hint: "A winding lowered (blue) band across the map, like a river bed." },
  { id: "plateau", name: "Plateau", hint: "A large raised (red) area in the middle, with cliffs." },
];

/**
 * Settings a shape starts from when picked (the sliders stay free after):
 * an archipelago needs much more water than a continent, for example.
 */
export const SHAPE_PRESETS: Record<Shape, Partial<GeneratorSettings>> = {
  island: { emptyPercent: 35, raisedPercent: 15, loweredPercent: 8, margin: 50, scale: 24 },
  archipelago: { emptyPercent: 70, raisedPercent: 7, loweredPercent: 3, margin: 30, scale: 12 },
  continent: { emptyPercent: 12, raisedPercent: 18, loweredPercent: 10, margin: 20, scale: 28 },
  lake: { emptyPercent: 30, raisedPercent: 12, loweredPercent: 12, margin: 50, scale: 24 },
  valley: { emptyPercent: 10, raisedPercent: 16, loweredPercent: 12, margin: 20, scale: 28 },
  plateau: { emptyPercent: 30, raisedPercent: 22, loweredPercent: 6, margin: 50, scale: 24 },
};

export interface GeneratorSettings {
  width: number;
  height: number;
  seed: number;
  shape: Shape;
  /** Size of the largest noise features, in pixels. */
  scale: number;
  /** Noise layers (1 = smooth blobs, 6 = ragged coasts). */
  octaves: number;
  /** 0-100: how strongly land is pulled away from the edges. */
  margin: number;
  /** Shares of the whole map, in percent (ground = the rest). */
  emptyPercent: number;
  raisedPercent: number;
  loweredPercent: number;
  /** Majority-filter passes (smoother borders). */
  smoothPasses: number;
  /** Regions smaller than this many pixels are merged into their surroundings. */
  minRegion: number;
}

export const DEFAULT_SETTINGS: GeneratorSettings = {
  width: 96,
  height: 96,
  seed: 1234,
  shape: "island",
  scale: 24,
  octaves: 4,
  margin: 50,
  emptyPercent: 35,
  raisedPercent: 15,
  loweredPercent: 8,
  smoothPasses: 1,
  minRegion: 6,
};

/** Shares actually used: clamped, and scaled down if they add up to more than 100. */
export function shares(s: GeneratorSettings): { empty: number; raised: number; lowered: number } {
  const empty = Math.max(0, Math.min(100, s.emptyPercent));
  let raised = Math.max(0, Math.min(100, s.raisedPercent));
  let lowered = Math.max(0, Math.min(100, s.loweredPercent));
  const left = 100 - empty;
  if (raised + lowered > left) {
    const k = left / Math.max(raised + lowered, 0.0001);
    raised *= k;
    lowered *= k;
  }
  return { empty, raised, lowered };
}

export function generate(settings: GeneratorSettings, cleanup = true): PixelMap {
  const w = clampSize(settings.width);
  const h = clampSize(settings.height);
  const n = w * h;
  const seed = settings.seed | 0;
  const scale = Math.max(2, settings.scale);
  const octaves = Math.max(1, Math.min(8, Math.round(settings.octaves)));
  const margin = Math.max(0, Math.min(100, settings.margin)) / 100;
  const rand = mulberry32(seed ^ 0x5bd1e995);

  const land = new Float32Array(n);
  const relief = new Float32Array(n);

  // Archipelago island centres (normalised -1..1) and radii.
  const centres: [number, number, number][] = [];
  if (settings.shape === "archipelago") {
    // One island in 5 to 7 of the 9 cells of a 3 x 3 grid, jittered: spread
    // out, with water between them.
    const cells = [0, 1, 2, 3, 4, 5, 6, 7, 8];
    for (let i = cells.length - 1; i > 0; i--) {
      const j = Math.floor(rand() * (i + 1));
      [cells[i], cells[j]] = [cells[j], cells[i]];
    }
    const count = 5 + Math.floor(rand() * 3);
    for (let k = 0; k < count; k++) {
      const gx = (cells[k] % 3) - 1;
      const gy = Math.floor(cells[k] / 3) - 1;
      centres.push([gx * 0.62 + (rand() * 2 - 1) * 0.1, gy * 0.62 + (rand() * 2 - 1) * 0.1, 0.17 + rand() * 0.11]);
    }
  }
  // Valley: a meandering line across the map, along X or Z.
  const valleyAlongX = rand() < 0.5;
  const valleyPhase = rand() * Math.PI * 2;
  const valleyFreq = 1.5 + rand() * 1.5;

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = y * w + x;
      const nx = w > 1 ? (x / (w - 1)) * 2 - 1 : 0;
      const ny = h > 1 ? (y / (h - 1)) * 2 - 1 : 0;
      const dist = Math.sqrt(nx * nx + ny * ny);
      const noise = fbm(x, y, seed, scale, octaves);
      const noise2 = fbm(x + 7919, y + 104729, seed + 77, scale * 0.75, octaves);
      // Edge pull: 0 at the centre, growing towards the edges (as the old
      // generator's Island Padding).
      const edge = margin > 0 ? Math.pow(dist, 1 + (1 - margin) * 5) * (0.5 + margin * 1.5) : 0;

      let l = noise;
      let r = noise2;
      switch (settings.shape) {
        case "island":
          l = noise - edge;
          break;
        case "archipelago": {
          let bump = 0;
          for (const [cx, cy, cr] of centres) {
            // Cone with a soft top: islands stay apart, with water between.
            const d = Math.hypot(nx - cx, ny - cy) / cr;
            bump = Math.max(bump, Math.pow(Math.max(0, 1 - d), 0.7));
          }
          l = noise * 0.3 + bump - edge * 0.3;
          break;
        }
        case "continent":
          l = noise - edge * 0.25;
          break;
        case "lake":
          l = noise * 0.6 + (1 - dist) * 0.4 - edge;
          // Lowest relief (blue) in the middle.
          r = noise2 * 0.35 + Math.min(1, dist / 0.55);
          break;
        case "valley": {
          const along = valleyAlongX ? nx : ny;
          const across = valleyAlongX ? ny : nx;
          const line = Math.sin(along * Math.PI * valleyFreq + valleyPhase) * 0.35;
          l = noise - edge * 0.25;
          r = noise2 * 0.3 + Math.min(1, Math.abs(across - line) / 0.5);
          break;
        }
        case "plateau":
          l = noise * 0.6 + (1 - dist) * 0.4 - edge;
          // Highest relief (red) in the middle, with a sharp rim.
          r = noise2 * 0.3 + (dist < 0.45 ? 1 : 0.2 * (1 - dist));
          break;
      }
      land[i] = l;
      relief[i] = r;
    }
  }

  const { empty, raised, lowered } = shares(settings);
  const data = new Uint8Array(n).fill(GROUND);

  // Empty: the lowest `empty` % of the land field.
  const order = rankAscending(land);
  const emptyCount = Math.round((empty / 100) * n);
  for (let k = 0; k < emptyCount; k++) data[order[k]] = EMPTY;

  // Lowered / raised: the lowest / highest relief among the land pixels.
  const landPixels: number[] = [];
  for (let i = 0; i < n; i++) if (data[i] !== EMPTY) landPixels.push(i);
  landPixels.sort((a, b) => relief[a] - relief[b] || a - b);
  const lowCount = Math.min(landPixels.length, Math.round((lowered / 100) * n));
  const highCount = Math.min(landPixels.length - lowCount, Math.round((raised / 100) * n));
  for (let k = 0; k < lowCount; k++) data[landPixels[k]] = LOWERED;
  for (let k = 0; k < highCount; k++) data[landPixels[landPixels.length - 1 - k]] = RAISED;

  const map: PixelMap = { width: w, height: h, data };
  if (cleanup) {
    for (let p = 0; p < Math.max(0, Math.min(8, Math.round(settings.smoothPasses))); p++) majorityPass(map);
    mergeSmallRegions(map, Math.max(0, Math.round(settings.minRegion)));
  }
  return map;
}

/** Indices sorted by value (ties by index: stable, same result everywhere). */
function rankAscending(values: Float32Array): Uint32Array {
  const order = new Uint32Array(values.length);
  for (let i = 0; i < order.length; i++) order[i] = i;
  return order.sort((a, b) => values[a] - values[b] || a - b);
}

/** Each pixel takes the most common class of its 3x3 block (ties: unchanged). */
export function majorityPass(map: PixelMap): void {
  const { width: w, height: h } = map;
  const src = map.data.slice();
  const counts = [0, 0, 0, 0];
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      counts[0] = counts[1] = counts[2] = counts[3] = 0;
      for (let dy = -1; dy <= 1; dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (let dx = -1; dx <= 1; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          counts[src[yy * w + xx]]++;
        }
      }
      const own = src[y * w + x];
      let best = own;
      for (let c = 0; c < 4; c++) if (counts[c] > counts[best]) best = c;
      map.data[y * w + x] = best;
    }
  }
}

/**
 * Regions (4-connected, same class) under `minSize` pixels take the most
 * common class around them. Removes single stray pixels and specks.
 */
export function mergeSmallRegions(map: PixelMap, minSize: number): void {
  if (minSize <= 1) return;
  const { width: w, height: h, data } = map;
  const seen = new Uint8Array(data.length);
  const stack: number[] = [];
  const region: number[] = [];
  for (let start = 0; start < data.length; start++) {
    if (seen[start]) continue;
    const cls = data[start];
    region.length = 0;
    stack.push(start);
    seen[start] = 1;
    while (stack.length) {
      const i = stack.pop()!;
      region.push(i);
      const x = i % w;
      const y = (i - x) / w;
      const next = [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, y > 0 ? i - w : -1, y < h - 1 ? i + w : -1];
      for (const j of next) {
        if (j >= 0 && !seen[j] && data[j] === cls) {
          seen[j] = 1;
          stack.push(j);
        }
      }
    }
    if (region.length >= minSize || region.length === data.length) continue;
    const around = [0, 0, 0, 0];
    for (const i of region) {
      const x = i % w;
      const y = (i - x) / w;
      if (x > 0 && data[i - 1] !== cls) around[data[i - 1]]++;
      if (x < w - 1 && data[i + 1] !== cls) around[data[i + 1]]++;
      if (y > 0 && data[i - w] !== cls) around[data[i - w]]++;
      if (y < h - 1 && data[i + w] !== cls) around[data[i + w]]++;
    }
    let best: PixelClass = cls as PixelClass;
    let bestCount = 0;
    for (let c = 0; c < 4; c++) {
      if (around[c] > bestCount) {
        bestCount = around[c];
        best = c as PixelClass;
      }
    }
    if (best !== cls) for (const i of region) data[i] = best;
  }
}
