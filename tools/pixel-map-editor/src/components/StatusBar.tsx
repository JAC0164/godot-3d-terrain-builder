import { CLASSES, CLASS_INFO, PixelMap, countClasses, getPixel } from "../map/pixels";

interface Props {
  map: PixelMap;
  hover: { x: number; y: number } | null;
  message: string;
}

export function StatusBar({ map, hover, message }: Props) {
  const counts = countClasses(map);
  const total = map.width * map.height;
  return (
    <footer className="status" aria-live="polite">
      <span className="pos">
        {map.width} × {map.height}
        {hover && (
          <>
            {" · "}
            {hover.x}, {hover.y} · {CLASS_INFO[getPixel(map, hover.x, hover.y)].name}
          </>
        )}
      </span>
      <span className="counts">
        {CLASSES.map((c) => (
          <span key={c} className="count" title={`${counts[c]} ${CLASS_INFO[c].name.toLowerCase()} pixels`}>
            <span className="swatch" style={{ background: CLASS_INFO[c].css }} />
            {((counts[c] / total) * 100).toFixed(1)}%
          </span>
        ))}
      </span>
      {message && <span className="message">{message}</span>}
    </footer>
  );
}
