import { describe, expect, it } from "vitest";
import { drawEllipse, drawRect, floodFill, plot, strokeLine, NO_MIRROR } from "./editing";
import { DEFAULT_SETTINGS, SHAPES, generate, shares } from "./generator";
import { History } from "./history";
import { EMPTY, GROUND, LOWERED, RAISED, classifyRgba, cloneMap, countClasses, createMap, getPixel, sameMap } from "./pixels";
import { PLUGIN_TOLERANCE, mapToRgba, rgbaToMap } from "./png";

describe("generator", () => {
  it("same seed and settings give the same map, another seed another map", () => {
    for (const shape of SHAPES) {
      const s = { ...DEFAULT_SETTINGS, shape: shape.id };
      expect(sameMap(generate(s), generate(s))).toBe(true);
      expect(sameMap(generate(s), generate({ ...s, seed: s.seed + 1 }))).toBe(false);
    }
  });

  it("gives the requested shares before cleanup (exact) and close after", () => {
    for (const shape of SHAPES) {
      const s = { ...DEFAULT_SETTINGS, shape: shape.id, width: 128, height: 96 };
      const n = s.width * s.height;
      const want = shares(s);
      const raw = countClasses(generate(s, false));
      expect(Math.abs(raw[EMPTY] - (want.empty / 100) * n)).toBeLessThanOrEqual(1);
      expect(Math.abs(raw[RAISED] - (want.raised / 100) * n)).toBeLessThanOrEqual(1);
      expect(Math.abs(raw[LOWERED] - (want.lowered / 100) * n)).toBeLessThanOrEqual(1);
      const clean = countClasses(generate(s));
      for (const [cls, pct] of [
        [EMPTY, want.empty],
        [RAISED, want.raised],
        [LOWERED, want.lowered],
      ] as const) {
        expect(Math.abs((clean[cls] / n) * 100 - pct), `${shape.id} class ${cls}`).toBeLessThan(5);
      }
    }
  });

  it("scales raised + lowered down when the shares add up to more than 100", () => {
    const s = shares({ ...DEFAULT_SETTINGS, emptyPercent: 60, raisedPercent: 40, loweredPercent: 40 });
    expect(s.raised + s.lowered).toBeCloseTo(40);
  });

  it("puts the lake's blue in the middle and the plateau's red in the middle", () => {
    const lake = generate({ ...DEFAULT_SETTINGS, shape: "lake", width: 64, height: 64 });
    expect(getPixel(lake, 32, 32)).toBe(LOWERED);
    const plateau = generate({ ...DEFAULT_SETTINGS, shape: "plateau", width: 64, height: 64 });
    expect(getPixel(plateau, 32, 32)).toBe(RAISED);
  });

  it("handles 1 x 1 and 256 x 256", () => {
    expect(generate({ ...DEFAULT_SETTINGS, width: 1, height: 1 }).data.length).toBe(1);
    expect(generate({ ...DEFAULT_SETTINGS, width: 999, height: 256 }).width).toBe(256);
  });
});

describe("editing", () => {
  it("flood fill fills one region only, with mirrors", () => {
    const m = createMap(8, 4, GROUND);
    for (let y = 0; y < 4; y++) plot(m, 3, y, EMPTY, NO_MIRROR); // wall at x = 3
    floodFill(m, 0, 0, RAISED, NO_MIRROR);
    expect(countClasses(m)[RAISED]).toBe(12);
    expect(getPixel(m, 5, 0)).toBe(GROUND);
    const m2 = createMap(8, 4, GROUND);
    for (let y = 0; y < 4; y++) {
      plot(m2, 2, y, EMPTY, NO_MIRROR);
      plot(m2, 5, y, EMPTY, NO_MIRROR);
    }
    floodFill(m2, 0, 0, RAISED, { x: true, y: false });
    expect(getPixel(m2, 7, 0)).toBe(RAISED);
    expect(getPixel(m2, 3, 0)).toBe(GROUND);
  });

  it("mirrors a pencil stroke", () => {
    const m = createMap(10, 10, EMPTY);
    strokeLine(m, 1, 1, 3, 1, { size: 1, round: false }, GROUND, { x: true, y: true });
    for (const [x, y] of [
      [1, 1],
      [8, 1],
      [1, 8],
      [8, 8],
      [6, 8],
    ])
      expect(getPixel(m, x, y)).toBe(GROUND);
    expect(countClasses(m)[GROUND]).toBe(12);
  });

  it("draws filled rectangles and ellipses inside their box", () => {
    const m = createMap(20, 20, EMPTY);
    drawRect(m, 2, 3, 6, 5, true, { size: 1, round: false }, GROUND, NO_MIRROR);
    expect(countClasses(m)[GROUND]).toBe(15);
    const e = createMap(20, 20, EMPTY);
    drawEllipse(e, 2, 2, 12, 8, true, { size: 1, round: false }, GROUND, NO_MIRROR);
    expect(getPixel(e, 7, 5)).toBe(GROUND);
    expect(getPixel(e, 2, 2)).toBe(EMPTY);
    expect(getPixel(e, 13, 5)).toBe(EMPTY);
  });
});

describe("history", () => {
  it("undoes and redoes", () => {
    const h = new History();
    const a = createMap(4, 4, EMPTY);
    const b = cloneMap(a);
    plot(b, 1, 1, GROUND, NO_MIRROR);
    h.record(a);
    const back = h.undo(b)!;
    expect(sameMap(back, a)).toBe(true);
    const fwd = h.redo(back)!;
    expect(sameMap(fwd, b)).toBe(true);
    expect(h.canRedo).toBe(false);
  });
});

describe("png", () => {
  it("exports only the 4 exact plugin colours, all recognised by the plugin rule", () => {
    const m = generate({ ...DEFAULT_SETTINGS, shape: "archipelago" });
    const rgba = mapToRgba(m);
    const seen = new Set<string>();
    for (let i = 0; i < rgba.length; i += 4) {
      seen.add(`${rgba[i]},${rgba[i + 1]},${rgba[i + 2]},${rgba[i + 3]}`);
      expect(classifyRgba(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3], PLUGIN_TOLERANCE)).toBe(m.data[i / 4]);
    }
    for (const c of seen) expect(["255,255,255,255", "0,255,0,255", "255,0,0,255", "0,0,255,255"]).toContain(c);
  });

  it("reopens an exported map unchanged, and maps off colours to the nearest", () => {
    const m = generate({ ...DEFAULT_SETTINGS, shape: "valley", width: 50, height: 30 });
    const back = rgbaToMap(mapToRgba(m), m.width, m.height);
    expect(sameMap(back.map, m)).toBe(true);
    expect(back.offColour).toBe(0);
    const odd = rgbaToMap([200, 30, 20, 255, 10, 10, 10, 0, 40, 220, 40, 255], 3, 1);
    expect(Array.from(odd.map.data)).toEqual([RAISED, EMPTY, GROUND]);
    expect(odd.offColour).toBe(2);
  });
});
