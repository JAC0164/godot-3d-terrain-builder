import { useCallback, useEffect, useRef, useState } from "react";
import { GeneratorPanel } from "./components/GeneratorPanel";
import { MapCanvas, MapCanvasHandle } from "./components/MapCanvas";
import { StatusBar } from "./components/StatusBar";
import { TOOLS, Tool, ToolBar } from "./components/ToolBar";
import { Brush, Mirror, NO_MIRROR, drawEllipse, drawRect, floodFill, stamp, strokeLine } from "./map/editing";
import { DEFAULT_SETTINGS, GeneratorSettings, generate } from "./map/generator";
import { History } from "./map/history";
import { EMPTY, GROUND, PixelClass, PixelMap, cloneMap, createMap, getPixel, inside, sameMap } from "./map/pixels";
import { downloadPng, exportFileName, readImageFile } from "./map/png";
import { loadSaved, saveState } from "./storage";

interface Stroke {
  base: PixelMap;
  work: PixelMap;
  start: { x: number; y: number };
  last: { x: number; y: number };
  cls: PixelClass;
}

const saved = loadSaved();

export function App() {
  const [settings, setSettings] = useState<GeneratorSettings>(saved?.settings ?? DEFAULT_SETTINGS);
  const [map, setMap] = useState<PixelMap>(() => saved?.map ?? generate(saved?.settings ?? DEFAULT_SETTINGS));
  // Seed in the exported file name: null once the map is blank / opened.
  const [fromSeed, setFromSeed] = useState<number | null>(saved ? saved.fromSeed : DEFAULT_SETTINGS.seed);
  const [tool, setTool] = useState<Tool>("pencil");
  const [colour, setColour] = useState<PixelClass>(GROUND);
  const [brush, setBrush] = useState<Brush>({ size: 3, round: true });
  const [filled, setFilled] = useState(true);
  const [mirror, setMirror] = useState<Mirror>(NO_MIRROR);
  const [showGrid, setShowGrid] = useState(true);
  const [hover, setHover] = useState<{ x: number; y: number } | null>(null);
  const [message, setMessage] = useState("");
  const [, setHistoryVersion] = useState(0);

  const history = useRef(new History());
  const mapRef = useRef(map);
  mapRef.current = map;
  const stroke = useRef<Stroke | null>(null);
  const pendingGenerate = useRef(false);
  const canvas = useRef<MapCanvasHandle>(null);

  const bumpHistory = () => setHistoryVersion((v) => v + 1);

  /** Replaces the map, as one undo step. */
  const commit = useCallback((next: PixelMap) => {
    if (sameMap(next, mapRef.current)) return;
    history.current.record(mapRef.current);
    setMap(next);
    bumpHistory();
  }, []);

  const flashTimer = useRef(0);
  const flash = useCallback((text: string) => {
    setMessage(text);
    window.clearTimeout(flashTimer.current);
    flashTimer.current = window.setTimeout(() => setMessage(""), 6000);
  }, []);

  // --- Generator ---------------------------------------------------------

  const changeSettings = useCallback((patch: Partial<GeneratorSettings>) => {
    pendingGenerate.current = true;
    setSettings((s) => ({ ...s, ...patch }));
  }, []);

  // Live: regenerate shortly after the last settings change.
  useEffect(() => {
    if (!pendingGenerate.current) return;
    const t = window.setTimeout(() => {
      pendingGenerate.current = false;
      commit(generate(settings));
      setFromSeed(settings.seed);
    }, 120);
    return () => window.clearTimeout(t);
  }, [settings, commit]);

  const newSeed = useCallback(() => changeSettings({ seed: Math.floor(Math.random() * 1_000_000) }), [changeSettings]);

  const newBlank = useCallback(
    (fill: PixelClass) => {
      commit(createMap(settings.width, settings.height, fill));
      setFromSeed(null);
    },
    [commit, settings.width, settings.height],
  );

  const open = useCallback(
    async (file: File) => {
      try {
        const { map: opened, offColour } = await readImageFile(file);
        commit(opened);
        setFromSeed(null);
        // Size fields follow the opened image, without regenerating.
        setSettings((s) => ({ ...s, width: opened.width, height: opened.height }));
        flash(
          offColour > 0
            ? `Opened ${file.name}: ${offColour} pixel(s) were not one of the 4 colours and took the nearest one.`
            : `Opened ${file.name} (${opened.width} × ${opened.height}).`,
        );
      } catch (e) {
        flash(e instanceof Error ? e.message : "Could not open this image.");
      }
    },
    [commit, flash],
  );

  const exportPng = useCallback(() => {
    const name = exportFileName(mapRef.current, fromSeed);
    downloadPng(mapRef.current, name);
    flash(`Saved ${name}: drag it into Pixel Map › Source Image, then Generate from Image.`);
  }, [fromSeed, flash]);

  // --- History -----------------------------------------------------------

  const undo = useCallback(() => {
    const previous = history.current.undo(mapRef.current);
    if (previous) {
      setMap(previous);
      bumpHistory();
    }
  }, []);

  const redo = useCallback(() => {
    const next = history.current.redo(mapRef.current);
    if (next) {
      setMap(next);
      bumpHistory();
    }
  }, []);

  // --- Drawing -----------------------------------------------------------

  const applyStroke = (s: Stroke, x: number, y: number) => {
    switch (tool) {
      case "pencil":
      case "eraser":
        strokeLine(s.work, s.last.x, s.last.y, x, y, brush, s.cls, mirror);
        break;
      case "line":
        s.work = cloneMap(s.base);
        strokeLine(s.work, s.start.x, s.start.y, x, y, brush, s.cls, mirror);
        break;
      case "rect":
        s.work = cloneMap(s.base);
        drawRect(s.work, s.start.x, s.start.y, x, y, filled, brush, s.cls, mirror);
        break;
      case "ellipse":
        s.work = cloneMap(s.base);
        drawEllipse(s.work, s.start.x, s.start.y, x, y, filled, brush, s.cls, mirror);
        break;
      default:
        break;
    }
    s.last = { x, y };
    setMap(cloneMap(s.work));
  };

  const onStrokeStart = (x: number, y: number, button: number) => {
    const current = mapRef.current;
    const cls: PixelClass = tool === "eraser" || button === 2 ? EMPTY : colour;
    if (tool === "picker") {
      if (inside(current, x, y)) setColour(getPixel(current, x, y));
      return;
    }
    if (tool === "fill") {
      if (!inside(current, x, y)) return;
      const next = cloneMap(current);
      floodFill(next, x, y, cls, mirror);
      commit(next);
      return;
    }
    const s: Stroke = { base: cloneMap(current), work: cloneMap(current), start: { x, y }, last: { x, y }, cls };
    stroke.current = s;
    if (tool === "pencil" || tool === "eraser") {
      stamp(s.work, x, y, brush, cls, mirror);
      setMap(cloneMap(s.work));
    } else {
      applyStroke(s, x, y);
    }
  };

  const onStrokeMove = (x: number, y: number) => {
    const s = stroke.current;
    if (s) applyStroke(s, x, y);
  };

  const onStrokeEnd = () => {
    const s = stroke.current;
    stroke.current = null;
    if (!s || sameMap(s.base, s.work)) return;
    // The map already shows the stroke: record the map from before it.
    history.current.record(s.base);
    setMap(cloneMap(s.work));
    bumpHistory();
  };

  // --- Keyboard ----------------------------------------------------------

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement;
      const typing = target instanceof HTMLInputElement && (target.type === "number" || target.type === "text");
      if (typing || target instanceof HTMLSelectElement || target instanceof HTMLTextAreaElement) return;
      const ctrl = e.ctrlKey || e.metaKey;
      const key = e.key.toLowerCase();
      if (ctrl && key === "z") {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
        return;
      }
      if (ctrl && key === "y") {
        e.preventDefault();
        redo();
        return;
      }
      if (ctrl && key === "s") {
        e.preventDefault();
        exportPng();
        return;
      }
      if (ctrl || e.altKey) return;
      if (key >= "1" && key <= "4") {
        setColour((Number(key) - 1) as PixelClass);
        return;
      }
      if (key === "[") return setBrush((b) => ({ ...b, size: Math.max(1, b.size - 1) }));
      if (key === "]") return setBrush((b) => ({ ...b, size: Math.min(16, b.size + 1) }));
      if (key === "f") return canvas.current?.fit();
      if (key === "enter" && !(target instanceof HTMLButtonElement)) return newSeed();
      const t = TOOLS.find((tt) => tt.key.toLowerCase() === key);
      if (t) setTool(t.id);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [undo, redo, exportPng, newSeed]);

  // --- Autosave ----------------------------------------------------------

  useEffect(() => {
    const t = window.setTimeout(() => saveState({ settings, map, fromSeed }), 400);
    return () => window.clearTimeout(t);
  }, [settings, map, fromSeed]);

  return (
    <div className="app">
      <GeneratorPanel settings={settings} onChange={changeSettings} onGenerate={newSeed} onNewBlank={newBlank} onOpen={open} onExport={exportPng} />
      <main className="workspace">
        <ToolBar
          tool={tool}
          colour={colour}
          brush={brush}
          filled={filled}
          mirror={mirror}
          showGrid={showGrid}
          canUndo={history.current.canUndo}
          canRedo={history.current.canRedo}
          onTool={setTool}
          onColour={setColour}
          onBrush={setBrush}
          onFilled={setFilled}
          onMirror={setMirror}
          onGrid={setShowGrid}
          onUndo={undo}
          onRedo={redo}
          onFit={() => canvas.current?.fit()}
        />
        <MapCanvas
          ref={canvas}
          map={map}
          showGrid={showGrid}
          cursor={tool === "picker" ? "copy" : "crosshair"}
          onStrokeStart={onStrokeStart}
          onStrokeMove={onStrokeMove}
          onStrokeEnd={onStrokeEnd}
          onHover={setHover}
        />
        <StatusBar map={map} hover={hover} message={message} />
      </main>
    </div>
  );
}
