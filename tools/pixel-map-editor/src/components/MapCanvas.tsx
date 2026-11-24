import { useCallback, useEffect, useImperativeHandle, useRef, useState, forwardRef } from "react";
import { PixelMap } from "../map/pixels";
import { mapToRgba } from "../map/png";

export interface MapCanvasHandle {
  fit(): void;
}

interface Props {
  map: PixelMap;
  showGrid: boolean;
  cursor: string;
  /** Pixel under the pointer when a stroke starts; button 0 = left, 2 = right. */
  onStrokeStart(x: number, y: number, button: number): void;
  onStrokeMove(x: number, y: number): void;
  onStrokeEnd(): void;
  onHover(pixel: { x: number; y: number } | null): void;
}

interface View {
  zoom: number; // screen px per map pixel
  ox: number; // screen position of the map's top-left corner
  oy: number;
}

const MIN_ZOOM = 1;
const MAX_ZOOM = 64;

/**
 * The map, drawn pixel-sharp. Wheel = zoom towards the cursor; middle button
 * or Space + drag = pan; left / right button = draw (handled by the parent).
 */
export const MapCanvas = forwardRef<MapCanvasHandle, Props>(function MapCanvas(props, ref) {
  const { map, showGrid, cursor, onStrokeStart, onStrokeMove, onStrokeEnd, onHover } = props;
  const wrapRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const bufferRef = useRef<HTMLCanvasElement | null>(null);
  const [view, setView] = useState<View>({ zoom: 4, ox: 0, oy: 0 });
  const [size, setSize] = useState({ w: 0, h: 0 });
  const drag = useRef<{ mode: "draw" | "pan"; lastX: number; lastY: number; pointer: number } | null>(null);
  const spaceDown = useRef(false);
  const lastPixel = useRef<string>("");

  const fit = useCallback(() => {
    const { w, h } = size;
    if (w === 0 || h === 0) return;
    const zoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, Math.floor(Math.min((w - 32) / map.width, (h - 32) / map.height)) || 1));
    setView({ zoom, ox: Math.round((w - map.width * zoom) / 2), oy: Math.round((h - map.height * zoom) / 2) });
  }, [size, map.width, map.height]);

  useImperativeHandle(ref, () => ({ fit }), [fit]);

  // Track the container size.
  useEffect(() => {
    const wrap = wrapRef.current;
    if (!wrap) return;
    const observer = new ResizeObserver(() => setSize({ w: wrap.clientWidth, h: wrap.clientHeight }));
    observer.observe(wrap);
    setSize({ w: wrap.clientWidth, h: wrap.clientHeight });
    return () => observer.disconnect();
  }, []);

  // Fit when the map size or the container size changes.
  useEffect(() => {
    fit();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map.width, map.height, size.w, size.h]);

  // Space = pan while held.
  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.code === "Space" && !(e.target instanceof HTMLInputElement)) {
        spaceDown.current = true;
        e.preventDefault();
      }
    };
    const up = (e: KeyboardEvent) => {
      if (e.code === "Space") spaceDown.current = false;
    };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
    };
  }, []);

  // Draw.
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || size.w === 0) return;
    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(size.w * dpr);
    canvas.height = Math.round(size.h * dpr);
    canvas.style.width = `${size.w}px`;
    canvas.style.height = `${size.h}px`;
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, size.w, size.h);

    let buffer = bufferRef.current;
    if (!buffer) buffer = bufferRef.current = document.createElement("canvas");
    buffer.width = map.width;
    buffer.height = map.height;
    buffer.getContext("2d")!.putImageData(new ImageData(mapToRgba(map), map.width, map.height), 0, 0);

    const { zoom, ox, oy } = view;
    const w = map.width * zoom;
    const h = map.height * zoom;
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.5)";
    ctx.shadowBlur = 18;
    ctx.fillStyle = "#000";
    ctx.fillRect(ox, oy, w, h);
    ctx.restore();
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(buffer, ox, oy, w, h);

    if (showGrid && zoom >= 8) {
      ctx.beginPath();
      for (let x = 0; x <= map.width; x++) {
        ctx.moveTo(ox + x * zoom + 0.5, oy);
        ctx.lineTo(ox + x * zoom + 0.5, oy + h);
      }
      for (let y = 0; y <= map.height; y++) {
        ctx.moveTo(ox, oy + y * zoom + 0.5);
        ctx.lineTo(ox + w, oy + y * zoom + 0.5);
      }
      ctx.strokeStyle = "rgba(0,0,0,0.18)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    ctx.strokeStyle = "rgba(255,255,255,0.25)";
    ctx.strokeRect(ox - 0.5, oy - 0.5, w + 1, h + 1);
  }, [map, view, size, showGrid]);

  const toPixel = (clientX: number, clientY: number) => {
    const rect = canvasRef.current!.getBoundingClientRect();
    return {
      x: Math.floor((clientX - rect.left - view.ox) / view.zoom),
      y: Math.floor((clientY - rect.top - view.oy) / view.zoom),
    };
  };

  const onPointerDown = (e: React.PointerEvent) => {
    if (drag.current) return;
    canvasRef.current!.setPointerCapture(e.pointerId);
    if (e.button === 1 || (e.button === 0 && spaceDown.current)) {
      drag.current = { mode: "pan", lastX: e.clientX, lastY: e.clientY, pointer: e.pointerId };
      e.preventDefault();
      return;
    }
    if (e.button !== 0 && e.button !== 2) return;
    drag.current = { mode: "draw", lastX: e.clientX, lastY: e.clientY, pointer: e.pointerId };
    const p = toPixel(e.clientX, e.clientY);
    lastPixel.current = `${p.x},${p.y}`;
    onStrokeStart(p.x, p.y, e.button);
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const p = toPixel(e.clientX, e.clientY);
    const insideMap = p.x >= 0 && p.y >= 0 && p.x < map.width && p.y < map.height;
    onHover(insideMap ? p : null);
    const d = drag.current;
    if (!d || d.pointer !== e.pointerId) return;
    if (d.mode === "pan") {
      const dx = e.clientX - d.lastX;
      const dy = e.clientY - d.lastY;
      d.lastX = e.clientX;
      d.lastY = e.clientY;
      setView((v) => ({ ...v, ox: v.ox + dx, oy: v.oy + dy }));
      return;
    }
    const key = `${p.x},${p.y}`;
    if (key === lastPixel.current) return;
    lastPixel.current = key;
    onStrokeMove(p.x, p.y);
  };

  const endDrag = (e: React.PointerEvent) => {
    const d = drag.current;
    if (!d || d.pointer !== e.pointerId) return;
    drag.current = null;
    if (d.mode === "draw") onStrokeEnd();
  };

  const onWheel = (e: React.WheelEvent) => {
    const rect = canvasRef.current!.getBoundingClientRect();
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;
    setView((v) => {
      const factor = e.deltaY < 0 ? 1.25 : 0.8;
      let zoom = v.zoom * factor;
      zoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, zoom));
      if (zoom >= 2) zoom = Math.round(zoom);
      if (zoom === v.zoom) return v;
      // Keep the map point under the cursor in place.
      const px = (mx - v.ox) / v.zoom;
      const py = (my - v.oy) / v.zoom;
      return { zoom, ox: Math.round(mx - px * zoom), oy: Math.round(my - py * zoom) };
    });
  };

  return (
    <div
      ref={wrapRef}
      className="canvas-wrap"
      onWheel={onWheel}
      onContextMenu={(e) => e.preventDefault()}
    >
      <canvas
        ref={canvasRef}
        style={{ cursor }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onPointerLeave={() => onHover(null)}
        aria-label={`Pixel map, ${map.width} by ${map.height} pixels`}
        role="img"
      />
      <div className="zoom-badge" aria-hidden="true">×{view.zoom}</div>
    </div>
  );
});
