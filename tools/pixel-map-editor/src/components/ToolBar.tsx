import { ReactNode } from "react";
import { Brush, Mirror } from "../map/editing";
import { CLASSES, CLASS_INFO, PixelClass } from "../map/pixels";

export type Tool = "pencil" | "eraser" | "fill" | "line" | "rect" | "ellipse" | "picker";

const ICON: Record<Tool, ReactNode> = {
  pencil: <path d="M4 20l1-4L16 5l3 3L8 19zM14 7l3 3" />,
  eraser: <path d="M8 20h12M4 15l9-9 6 6-7 7H8z" />,
  fill: <path d="M5 11l7-7 7 7-7 7zM19 15s2 2.5 2 4a2 2 0 01-4 0c0-1.5 2-4 2-4z" />,
  line: <path d="M5 19L19 5" />,
  rect: <rect x="4" y="6" width="16" height="12" rx="1" />,
  ellipse: <ellipse cx="12" cy="12" rx="8" ry="6" />,
  picker: <path d="M14 4l6 6-2 2-6-6zM12 8l-7 7v4h4l7-7" />,
};

export const TOOLS: { id: Tool; name: string; key: string }[] = [
  { id: "pencil", name: "Pencil", key: "B" },
  { id: "eraser", name: "Eraser (paints Empty)", key: "E" },
  { id: "fill", name: "Paint Bucket", key: "G" },
  { id: "line", name: "Line", key: "L" },
  { id: "rect", name: "Rectangle", key: "R" },
  { id: "ellipse", name: "Ellipse", key: "O" },
  { id: "picker", name: "Colour Picker", key: "I" },
];

interface Props {
  tool: Tool;
  colour: PixelClass;
  brush: Brush;
  filled: boolean;
  mirror: Mirror;
  showGrid: boolean;
  canUndo: boolean;
  canRedo: boolean;
  onTool(t: Tool): void;
  onColour(c: PixelClass): void;
  onBrush(b: Brush): void;
  onFilled(f: boolean): void;
  onMirror(m: Mirror): void;
  onGrid(g: boolean): void;
  onUndo(): void;
  onRedo(): void;
  onFit(): void;
}

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

export function ToolBar(p: Props) {
  const shapeTool = p.tool === "rect" || p.tool === "ellipse";
  const brushTool = p.tool === "pencil" || p.tool === "eraser" || p.tool === "line" || (shapeTool && !p.filled);
  return (
    <div className="toolbar" role="toolbar" aria-label="Drawing tools">
      <div className="group" role="radiogroup" aria-label="Colour">
        {CLASSES.map((c, i) => (
          <button
            key={c}
            role="radio"
            aria-checked={p.colour === c}
            className={`colour ${p.colour === c ? "on" : ""}`}
            style={{ background: CLASS_INFO[c].css }}
            title={`${CLASS_INFO[c].name} (${i + 1}) — ${CLASS_INFO[c].hint}`}
            aria-label={CLASS_INFO[c].name}
            onClick={() => p.onColour(c)}
          />
        ))}
      </div>

      <div className="group" role="radiogroup" aria-label="Tool">
        {TOOLS.map((t) => (
          <button
            key={t.id}
            role="radio"
            aria-checked={p.tool === t.id}
            className={`icon-btn ${p.tool === t.id ? "on" : ""}`}
            title={`${t.name} (${t.key})`}
            aria-label={t.name}
            onClick={() => p.onTool(t.id)}
          >
            <Icon>{ICON[t.id]}</Icon>
          </button>
        ))}
      </div>

      <div className={`group ${brushTool ? "" : "dim"}`}>
        <label className="inline" title="Brush size in pixels ([ and ])">
          Size
          <input
            type="range"
            min={1}
            max={16}
            value={p.brush.size}
            onChange={(e) => p.onBrush({ ...p.brush, size: Number(e.target.value) })}
            disabled={!brushTool}
          />
          <output>{p.brush.size}</output>
        </label>
        <button
          className={`text-btn ${p.brush.round ? "on" : ""}`}
          onClick={() => p.onBrush({ ...p.brush, round: !p.brush.round })}
          title="Round or square brush"
          aria-pressed={p.brush.round}
          disabled={!brushTool}
        >
          {p.brush.round ? "Round" : "Square"}
        </button>
      </div>

      <div className={`group ${shapeTool ? "" : "dim"}`}>
        <button
          className={`text-btn ${p.filled ? "on" : ""}`}
          onClick={() => p.onFilled(!p.filled)}
          aria-pressed={p.filled}
          title="Rectangle / ellipse: filled or outline"
          disabled={!shapeTool}
        >
          Filled
        </button>
      </div>

      <div className="group" aria-label="Symmetry">
        <button
          className={`text-btn ${p.mirror.x ? "on" : ""}`}
          aria-pressed={p.mirror.x}
          onClick={() => p.onMirror({ ...p.mirror, x: !p.mirror.x })}
          title="Mirror left ↔ right (X)"
        >
          ⇆ Mirror
        </button>
        <button
          className={`text-btn ${p.mirror.y ? "on" : ""}`}
          aria-pressed={p.mirror.y}
          onClick={() => p.onMirror({ ...p.mirror, y: !p.mirror.y })}
          title="Mirror top ↕ bottom (Y)"
        >
          ⇅ Mirror
        </button>
      </div>

      <div className="group push">
        <button className="icon-btn" onClick={p.onUndo} disabled={!p.canUndo} title="Undo (Ctrl+Z)" aria-label="Undo">
          <Icon>
            <path d="M9 14L4 9l5-5M4 9h10a6 6 0 010 12h-3" />
          </Icon>
        </button>
        <button className="icon-btn" onClick={p.onRedo} disabled={!p.canRedo} title="Redo (Ctrl+Y)" aria-label="Redo">
          <Icon>
            <path d="M15 14l5-5-5-5M20 9H10a6 6 0 000 12h3" />
          </Icon>
        </button>
        <button className={`text-btn ${p.showGrid ? "on" : ""}`} aria-pressed={p.showGrid} onClick={() => p.onGrid(!p.showGrid)} title="Pixel grid when zoomed in (zoom ×8 and more)">
          Grid
        </button>
        <button className="text-btn" onClick={p.onFit} title="Fit the map in the view (F)">
          Fit
        </button>
      </div>
    </div>
  );
}
