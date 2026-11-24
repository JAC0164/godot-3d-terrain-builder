// Seeded randomness: the same seed always gives the same numbers, so the same
// seed and settings always give the same map.

/** mulberry32: small, fast, good enough for map noise. Returns [0, 1). */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Integer hash of a lattice point and a seed, in [0, 1). */
function hash2(x: number, y: number, seed: number): number {
  let h = Math.imul(x | 0, 374761393) ^ Math.imul(y | 0, 668265263) ^ Math.imul(seed | 0, 2246822519);
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}

function smooth(t: number): number {
  return t * t * t * (t * (t * 6 - 15) + 10);
}

/** Value noise at (x, y), lattice spacing 1, in [0, 1). */
export function valueNoise(x: number, y: number, seed: number): number {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const fx = smooth(x - x0);
  const fy = smooth(y - y0);
  const a = hash2(x0, y0, seed);
  const b = hash2(x0 + 1, y0, seed);
  const c = hash2(x0, y0 + 1, seed);
  const d = hash2(x0 + 1, y0 + 1, seed);
  const top = a + (b - a) * fx;
  const bottom = c + (d - c) * fx;
  return top + (bottom - top) * fy;
}

/**
 * Fractal noise: `octaves` layers of value noise, each twice finer and half as
 * strong. `scale` = size of the largest features in pixels. Result in [0, 1).
 */
export function fbm(x: number, y: number, seed: number, scale: number, octaves: number): number {
  let sum = 0;
  let amplitude = 1;
  let total = 0;
  let frequency = 1 / Math.max(1, scale);
  for (let o = 0; o < octaves; o++) {
    sum += valueNoise(x * frequency, y * frequency, seed + o * 1013) * amplitude;
    total += amplitude;
    amplitude *= 0.5;
    frequency *= 2;
  }
  return sum / total;
}
