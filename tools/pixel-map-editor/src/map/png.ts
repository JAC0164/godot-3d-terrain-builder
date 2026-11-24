// Pixels <-> RGBA, PNG export and reopening an image.

import { CLASS_RGB, EMPTY, MAX_SIZE, PixelClass, PixelMap, classifyRgba } from "./pixels";

/** The plugin's default Color Tolerance (core/terrain_meta.gd). */
export const PLUGIN_TOLERANCE = 0.08;

/** RGBA bytes with the exact plugin colours (opaque). */
export function mapToRgba(map: PixelMap): Uint8ClampedArray {
  const out = new Uint8ClampedArray(map.width * map.height * 4);
  for (let i = 0; i < map.data.length; i++) {
    const [r, g, b] = CLASS_RGB[map.data[i] as PixelClass];
    out[i * 4] = r;
    out[i * 4 + 1] = g;
    out[i * 4 + 2] = b;
    out[i * 4 + 3] = 255;
  }
  return out;
}

export interface ReadResult {
  map: PixelMap;
  /** Pixels the plugin would not recognise (beyond its default tolerance): read here as their nearest colour. */
  offColour: number;
}

/** Map from RGBA bytes: each pixel takes the nearest of the 4 colours. */
export function rgbaToMap(rgba: ArrayLike<number>, width: number, height: number): ReadResult {
  const data = new Uint8Array(width * height);
  let offColour = 0;
  for (let i = 0; i < data.length; i++) {
    const r = rgba[i * 4];
    const g = rgba[i * 4 + 1];
    const b = rgba[i * 4 + 2];
    const a = rgba[i * 4 + 3];
    const strict = classifyRgba(r, g, b, a, PLUGIN_TOLERANCE);
    if (strict === -1) offColour++;
    const nearest = classifyRgba(r, g, b, a, 1);
    data[i] = nearest === -1 ? EMPTY : nearest;
  }
  return { map: { width, height, data }, offColour };
}

export function exportFileName(map: PixelMap, seed: number | null): string {
  return `pixel-map-${map.width}x${map.height}${seed === null ? "" : `-seed${seed}`}.png`;
}

/** Downloads the map as a PNG (browser only). */
export function downloadPng(map: PixelMap, fileName: string): void {
  const canvas = document.createElement("canvas");
  canvas.width = map.width;
  canvas.height = map.height;
  const ctx = canvas.getContext("2d")!;
  ctx.putImageData(new ImageData(mapToRgba(map), map.width, map.height), 0, 0);
  canvas.toBlob((blob) => {
    if (!blob) return;
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = fileName;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }, "image/png");
}

/** Reads an image file into a map (browser only). Rejects images over 256 px. */
export async function readImageFile(file: File): Promise<ReadResult> {
  const bitmap = await createImageBitmap(file);
  const { width, height } = bitmap;
  if (width > MAX_SIZE || height > MAX_SIZE) {
    bitmap.close();
    throw new Error(`The image is ${width} x ${height} pixels: the plugin reads at most ${MAX_SIZE} x ${MAX_SIZE}.`);
  }
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(bitmap, 0, 0);
  bitmap.close();
  return rgbaToMap(ctx.getImageData(0, 0, width, height).data, width, height);
}
