// Undo / redo of whole-map snapshots (a 256 x 256 map is 64 KB: 100 steps
// stay under 7 MB).

import { PixelMap, cloneMap, sameMap } from "./pixels";

export const HISTORY_LIMIT = 100;

export class History {
  private past: PixelMap[] = [];
  private future: PixelMap[] = [];

  /** Call with the map as it was BEFORE a change. Clears the redo steps. */
  record(before: PixelMap): void {
    const last = this.past[this.past.length - 1];
    if (last && sameMap(last, before)) return;
    this.past.push(cloneMap(before));
    if (this.past.length > HISTORY_LIMIT) this.past.shift();
    this.future.length = 0;
  }

  /** The previous map, or null. `current` goes to the redo steps. */
  undo(current: PixelMap): PixelMap | null {
    const previous = this.past.pop();
    if (!previous) return null;
    this.future.push(cloneMap(current));
    return previous;
  }

  redo(current: PixelMap): PixelMap | null {
    const next = this.future.pop();
    if (!next) return null;
    this.past.push(cloneMap(current));
    return next;
  }

  get canUndo(): boolean {
    return this.past.length > 0;
  }

  get canRedo(): boolean {
    return this.future.length > 0;
  }
}
