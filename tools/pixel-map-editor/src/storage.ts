// Autosave in the browser (per-viewer convenience: the PNG export is the real
// file). Every access is guarded: storage may be blocked or full.

import { DEFAULT_SETTINGS, GeneratorSettings } from "./map/generator";
import { MAX_SIZE, PixelMap } from "./map/pixels";

const KEY = "pixel-map-editor.v1";

interface Saved {
  settings: GeneratorSettings;
  map: PixelMap;
  fromSeed: number | null;
}

function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function fromBase64(text: string): Uint8Array {
  const s = atob(text);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export function saveState(state: Saved): void {
  try {
    localStorage.setItem(
      KEY,
      JSON.stringify({
        settings: state.settings,
        fromSeed: state.fromSeed,
        width: state.map.width,
        height: state.map.height,
        data: toBase64(state.map.data),
      }),
    );
  } catch {
    // Storage blocked or full: nothing to do, the PNG export still works.
  }
}

export function loadSaved(): Saved | null {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return null;
    const v = JSON.parse(raw);
    const width = Number(v.width);
    const height = Number(v.height);
    const data = fromBase64(String(v.data));
    if (!(width >= 1 && height >= 1 && width <= MAX_SIZE && height <= MAX_SIZE) || data.length !== width * height) return null;
    if (data.some((c) => c > 3)) return null;
    return {
      settings: { ...DEFAULT_SETTINGS, ...(v.settings ?? {}) },
      map: { width, height, data },
      fromSeed: typeof v.fromSeed === "number" ? v.fromSeed : null,
    };
  } catch {
    return null;
  }
}
