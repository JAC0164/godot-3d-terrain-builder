// Drawing operations on a pixel map. Every one writes through `plot`, which
// also writes the mirrored pixels (symmetry).

import { PixelClass, PixelMap, inside } from "./pixels";

export interface Mirror {
  x: boolean; // left <-> right
  y: boolean; // top <-> bottom
}

export const NO_MIRROR: Mirror = { x: false, y: false };

export interface Brush {
  size: number; // 1-16 pixels across
  round: boolean;
}

/** Sets (x, y) and its mirrors. */
export function plot(map: PixelMap, x: number, y: number, cls: PixelClass, mirror: Mirror): void {
  const { width: w, height: h, data } = map;
  if (!inside(map, x, y)) return;
  data[y * w + x] = cls;
  const mx = w - 1 - x;
  const my = h - 1 - y;
  if (mirror.x) data[y * w + mx] = cls;
  if (mirror.y) data[my * w + x] = cls;
  if (mirror.x && mirror.y) data[my * w + mx] = cls;
}

/** One brush dab centred on (cx, cy). */
export function stamp(map: PixelMap, cx: number, cy: number, brush: Brush, cls: PixelClass, mirror: Mirror): void {
  const size = Math.max(1, Math.min(64, Math.round(brush.size)));
  const lo = -Math.floor((size - 1) / 2);
  const hi = lo + size - 1;
  const r = size / 2;
  // Centre of the dab, in pixel units relative to (cx, cy).
  const c = (lo + hi) / 2;
  for (let dy = lo; dy <= hi; dy++) {
    for (let dx = lo; dx <= hi; dx++) {
      if (brush.round && size > 2) {
        const ex = dx - c;
        const ey = dy - c;
        if (ex * ex + ey * ey > r * r) continue;
      }
      plot(map, cx + dx, cy + dy, cls, mirror);
    }
  }
}

/** Integer points of the segment (Bresenham). */
export function linePoints(x0: number, y0: number, x1: number, y1: number): [number, number][] {
  const points: [number, number][] = [];
  let x = x0;
  let y = y0;
  const dx = Math.abs(x1 - x0);
  const dy = -Math.abs(y1 - y0);
  const sx = x0 < x1 ? 1 : -1;
  const sy = y0 < y1 ? 1 : -1;
  let err = dx + dy;
  for (;;) {
    points.push([x, y]);
    if (x === x1 && y === y1) break;
    const e2 = 2 * err;
    if (e2 >= dy) {
      err += dy;
      x += sx;
    }
    if (e2 <= dx) {
      err += dx;
      y += sy;
    }
  }
  return points;
}

/** Brush dabs along a segment (pencil strokes and the Line tool). */
export function strokeLine(map: PixelMap, x0: number, y0: number, x1: number, y1: number, brush: Brush, cls: PixelClass, mirror: Mirror): void {
  for (const [x, y] of linePoints(x0, y0, x1, y1)) stamp(map, x, y, brush, cls, mirror);
}

/** Rectangle between two corners, filled or as an outline drawn with the brush. */
export function drawRect(map: PixelMap, x0: number, y0: number, x1: number, y1: number, filled: boolean, brush: Brush, cls: PixelClass, mirror: Mirror): void {
  const left = Math.min(x0, x1);
  const right = Math.max(x0, x1);
  const top = Math.min(y0, y1);
  const bottom = Math.max(y0, y1);
  if (filled) {
    for (let y = top; y <= bottom; y++) for (let x = left; x <= right; x++) plot(map, x, y, cls, mirror);
    return;
  }
  strokeLine(map, left, top, right, top, brush, cls, mirror);
  strokeLine(map, right, top, right, bottom, brush, cls, mirror);
  strokeLine(map, right, bottom, left, bottom, brush, cls, mirror);
  strokeLine(map, left, bottom, left, top, brush, cls, mirror);
}

/** Ellipse inscribed in the box between two corners, filled or as an outline. */
export function drawEllipse(map: PixelMap, x0: number, y0: number, x1: number, y1: number, filled: boolean, brush: Brush, cls: PixelClass, mirror: Mirror): void {
  const left = Math.min(x0, x1);
  const right = Math.max(x0, x1);
  const top = Math.min(y0, y1);
  const bottom = Math.max(y0, y1);
  const cx = (left + right) / 2;
  const cy = (top + bottom) / 2;
  const rx = (right - left) / 2 + 0.5;
  const ry = (bottom - top) / 2 + 0.5;
  if (filled) {
    for (let y = top; y <= bottom; y++) {
      for (let x = left; x <= right; x++) {
        const ex = (x - cx) / rx;
        const ey = (y - cy) / ry;
        if (ex * ex + ey * ey <= 1) plot(map, x, y, cls, mirror);
      }
    }
    return;
  }
  // Outline: walk the angle finely enough to leave no gaps, then join points.
  const steps = Math.max(16, Math.ceil((rx + ry) * 4));
  let prev: [number, number] | null = null;
  for (let s = 0; s <= steps; s++) {
    const a = (s / steps) * Math.PI * 2;
    const px = Math.round(cx + Math.cos(a) * (rx - 0.5));
    const py = Math.round(cy + Math.sin(a) * (ry - 0.5));
    if (prev) strokeLine(map, prev[0], prev[1], px, py, brush, cls, mirror);
    else stamp(map, px, py, brush, cls, mirror);
    prev = [px, py];
  }
}

/** Fills the 4-connected region of the same class under (x, y). */
function fillOne(map: PixelMap, x: number, y: number, cls: PixelClass): void {
  if (!inside(map, x, y)) return;
  const { width: w, height: h, data } = map;
  const target = data[y * w + x];
  if (target === cls) return;
  const stack = [y * w + x];
  data[y * w + x] = cls;
  while (stack.length) {
    const i = stack.pop()!;
    const px = i % w;
    const py = (i - px) / w;
    if (px > 0 && data[i - 1] === target) {
      data[i - 1] = cls;
      stack.push(i - 1);
    }
    if (px < w - 1 && data[i + 1] === target) {
      data[i + 1] = cls;
      stack.push(i + 1);
    }
    if (py > 0 && data[i - w] === target) {
      data[i - w] = cls;
      stack.push(i - w);
    }
    if (py < h - 1 && data[i + w] === target) {
      data[i + w] = cls;
      stack.push(i + w);
    }
  }
}

/** Paint bucket at (x, y), and at its mirrored points. */
export function floodFill(map: PixelMap, x: number, y: number, cls: PixelClass, mirror: Mirror): void {
  const mx = map.width - 1 - x;
  const my = map.height - 1 - y;
  fillOne(map, x, y, cls);
  if (mirror.x) fillOne(map, mx, y, cls);
  if (mirror.y) fillOne(map, x, my, cls);
  if (mirror.x && mirror.y) fillOne(map, mx, my, cls);
}

/** The map resized to w x h: kept centred, new pixels empty. */
export function resizeCentred(map: PixelMap, w: number, h: number, fill: PixelClass): PixelMap {
  const out: PixelMap = { width: w, height: h, data: new Uint8Array(w * h).fill(fill) };
  const ox = Math.floor((w - map.width) / 2);
  const oy = Math.floor((h - map.height) / 2);
  for (let y = 0; y < map.height; y++) {
    const ty = y + oy;
    if (ty < 0 || ty >= h) continue;
    for (let x = 0; x < map.width; x++) {
      const tx = x + ox;
      if (tx < 0 || tx >= w) continue;
      out.data[ty * w + tx] = map.data[y * map.width + x];
    }
  }
  return out;
}
