// Pixel map data: one byte per pixel, the class the plugin reads from the
// image colour (generation/image_generator.gd, classify_pixel).

export const EMPTY = 0;
export const GROUND = 1;
export const RAISED = 2;
export const LOWERED = 3;
export type PixelClass = 0 | 1 | 2 | 3;
export const CLASSES: PixelClass[] = [EMPTY, GROUND, RAISED, LOWERED];

export const MIN_SIZE = 1;
export const MAX_SIZE = 256;

/** Exact export colours, the plugin's reference colours. */
export const CLASS_RGB: Record<PixelClass, [number, number, number]> = {
  0: [255, 255, 255],
  1: [0, 255, 0],
  2: [255, 0, 0],
  3: [0, 0, 255],
};

export const CLASS_INFO: Record<PixelClass, { name: string; hint: string; css: string }> = {
  0: { name: "Empty", hint: "White: no ground (water around an island, holes).", css: "#ffffff" },
  1: { name: "Ground", hint: "Green: ground at height 0.", css: "#00ff00" },
  2: { name: "Raised", hint: "Red: raised ground (Pixel Map > Raised Ground Height).", css: "#ff0000" },
  3: { name: "Lowered", hint: "Blue: lowered ground (Pixel Map > Lowered Ground Depth).", css: "#0000ff" },
};

export interface PixelMap {
  width: number;
  height: number;
  data: Uint8Array;
}

export function clampSize(n: number): number {
  return Math.max(MIN_SIZE, Math.min(MAX_SIZE, Math.round(Number.isFinite(n) ? n : MIN_SIZE)));
}

export function createMap(width: number, height: number, fill: PixelClass = EMPTY): PixelMap {
  const w = clampSize(width);
  const h = clampSize(height);
  return { width: w, height: h, data: new Uint8Array(w * h).fill(fill) };
}

export function cloneMap(map: PixelMap): PixelMap {
  return { width: map.width, height: map.height, data: map.data.slice() };
}

export function inside(map: PixelMap, x: number, y: number): boolean {
  return x >= 0 && y >= 0 && x < map.width && y < map.height;
}

export function getPixel(map: PixelMap, x: number, y: number): PixelClass {
  return map.data[y * map.width + x] as PixelClass;
}

/** Pixels of each class. */
export function countClasses(map: PixelMap): [number, number, number, number] {
  const counts: [number, number, number, number] = [0, 0, 0, 0];
  for (let i = 0; i < map.data.length; i++) counts[map.data[i]]++;
  return counts;
}

export function sameMap(a: PixelMap, b: PixelMap): boolean {
  if (a.width !== b.width || a.height !== b.height) return false;
  for (let i = 0; i < a.data.length; i++) if (a.data[i] !== b.data[i]) return false;
  return true;
}

/**
 * Class of an RGBA colour (0-255), as the plugin reads it: transparent =
 * empty, else the nearest reference colour by the largest channel gap
 * (Chebyshev). Returns -1 when that gap is above `tolerance` (0-1), like the
 * plugin's "unknown" pixels (built as empty).
 */
export function classifyRgba(r: number, g: number, b: number, a: number, tolerance: number): PixelClass | -1 {
  if (a / 255 <= 0.01) return EMPTY;
  // Plugin order: white, green, red, blue.
  const order: PixelClass[] = [EMPTY, GROUND, RAISED, LOWERED];
  let best: PixelClass = EMPTY;
  let bestError = Infinity;
  for (const c of order) {
    const [rr, gg, bb] = CLASS_RGB[c];
    const error = Math.max(Math.abs(r - rr), Math.abs(g - gg), Math.abs(b - bb)) / 255;
    if (error < bestError) {
      bestError = error;
      best = c;
    }
  }
  return bestError > tolerance ? -1 : best;
}
