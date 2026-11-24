import { useRef } from "react";
import { GeneratorSettings, SHAPES, SHAPE_PRESETS, Shape, shares } from "../map/generator";
import { CLASS_INFO, EMPTY, GROUND, LOWERED, MAX_SIZE, PixelClass, RAISED } from "../map/pixels";

interface Props {
  settings: GeneratorSettings;
  onChange(patch: Partial<GeneratorSettings>): void;
  onGenerate(): void;
  onNewBlank(fill: PixelClass): void;
  onOpen(file: File): void;
  onExport(): void;
}

const SIZE_PRESETS = [32, 64, 96, 128, 192, 256];

function Slider(props: {
  label: string;
  hint: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  suffix?: string;
  swatch?: string;
  onChange(v: number): void;
}) {
  const id = `s-${props.label.replace(/\W+/g, "-").toLowerCase()}`;
  return (
    <div className="field" title={props.hint}>
      <label htmlFor={id} className="field-label">
        {props.swatch && <span className="swatch" style={{ background: props.swatch }} />}
        <span>{props.label}</span>
        <output htmlFor={id}>
          {props.value}
          {props.suffix ?? ""}
        </output>
      </label>
      <input
        id={id}
        type="range"
        min={props.min}
        max={props.max}
        step={props.step ?? 1}
        value={props.value}
        onChange={(e) => props.onChange(Number(e.target.value))}
      />
    </div>
  );
}

export function GeneratorPanel({ settings, onChange, onGenerate, onNewBlank, onOpen, onExport }: Props) {
  const fileRef = useRef<HTMLInputElement>(null);
  const preset = settings.width === settings.height && SIZE_PRESETS.includes(settings.width) ? String(settings.width) : "custom";
  const used = shares(settings);
  const ground = Math.max(0, 100 - used.empty - used.raised - used.lowered);
  const scaled = used.raised !== settings.raisedPercent || used.lowered !== settings.loweredPercent;

  return (
    <aside className="panel" aria-label="Generator">
      <header className="brand">
        <h1>Pixel Map Editor</h1>
        <p>For Lowpoly Terrain Editor › Advanced › Pixel Map</p>
      </header>

      <section>
        <h2>Map Size</h2>
        <div className="row">
          <select
            aria-label="Size preset"
            value={preset}
            onChange={(e) => {
              if (e.target.value !== "custom") onChange({ width: Number(e.target.value), height: Number(e.target.value) });
            }}
            title="One pixel = one terrain cell. The plugin reads up to 256 x 256."
          >
            {SIZE_PRESETS.map((s) => (
              <option key={s} value={s}>
                {s} × {s}
              </option>
            ))}
            <option value="custom">Custom</option>
          </select>
        </div>
        <div className="row two">
          <label className="mini">
            Width
            <input
              type="number"
              min={1}
              max={MAX_SIZE}
              value={settings.width}
              onChange={(e) => onChange({ width: Math.max(1, Math.min(MAX_SIZE, Number(e.target.value) || 1)) })}
            />
          </label>
          <label className="mini">
            Height
            <input
              type="number"
              min={1}
              max={MAX_SIZE}
              value={settings.height}
              onChange={(e) => onChange({ height: Math.max(1, Math.min(MAX_SIZE, Number(e.target.value) || 1)) })}
            />
          </label>
        </div>
      </section>

      <section>
        <h2>Shape</h2>
        <div className="shape-grid" role="radiogroup" aria-label="Shape">
          {SHAPES.map((s) => (
            <button
              key={s.id}
              role="radio"
              aria-checked={settings.shape === s.id}
              className={`chip ${settings.shape === s.id ? "on" : ""}`}
              title={s.hint}
              onClick={() => onChange({ shape: s.id as Shape, ...SHAPE_PRESETS[s.id as Shape] })}
            >
              {s.name}
            </button>
          ))}
        </div>
        <div className="row seed-row">
          <label className="mini grow" title="Same seed + same settings = same map.">
            Seed
            <input
              type="number"
              value={settings.seed}
              onChange={(e) => onChange({ seed: Math.trunc(Number(e.target.value) || 0) })}
            />
          </label>
          <button className="btn primary" onClick={onGenerate} title="New random seed (Enter)">
            Generate
          </button>
        </div>
      </section>

      <section>
        <h2>Noise</h2>
        <Slider label="Feature Size" hint="Size of the largest hills and coasts, in pixels." value={settings.scale} min={4} max={96} suffix=" px" onChange={(v) => onChange({ scale: v })} />
        <Slider label="Detail" hint="Noise layers: 1 = smooth blobs, 6 = ragged coasts." value={settings.octaves} min={1} max={6} onChange={(v) => onChange({ octaves: v })} />
        <Slider label="Edge Margin" hint="How strongly land is pulled away from the map edges (0 = land may touch the edges)." value={settings.margin} min={0} max={100} suffix="%" onChange={(v) => onChange({ margin: v })} />
      </section>

      <section>
        <h2>Colours</h2>
        <Slider label="Empty" swatch={CLASS_INFO[EMPTY].css} hint={CLASS_INFO[EMPTY].hint} value={settings.emptyPercent} min={0} max={95} suffix="%" onChange={(v) => onChange({ emptyPercent: v })} />
        <Slider label="Raised" swatch={CLASS_INFO[RAISED].css} hint={CLASS_INFO[RAISED].hint} value={settings.raisedPercent} min={0} max={80} suffix="%" onChange={(v) => onChange({ raisedPercent: v })} />
        <Slider label="Lowered" swatch={CLASS_INFO[LOWERED].css} hint={CLASS_INFO[LOWERED].hint} value={settings.loweredPercent} min={0} max={80} suffix="%" onChange={(v) => onChange({ loweredPercent: v })} />
        <p className="note">
          <span className="swatch" style={{ background: CLASS_INFO[GROUND].css }} /> Ground: the rest, {Math.round(ground)}%
          {scaled && <> · raised + lowered scaled down to fit</>}
        </p>
      </section>

      <section>
        <h2>Cleanup</h2>
        <Slider label="Smooth Borders" hint="Passes of a majority filter: fewer jagged pixels along the borders." value={settings.smoothPasses} min={0} max={4} onChange={(v) => onChange({ smoothPasses: v })} />
        <Slider label="Min Region" hint="Specks smaller than this many pixels are merged into what surrounds them." value={settings.minRegion} min={0} max={64} suffix=" px" onChange={(v) => onChange({ minRegion: v })} />
      </section>

      <section>
        <h2>File</h2>
        <div className="row two">
          <button className="btn" onClick={() => onNewBlank(GROUND)} title="Clear the map to ground (green), same size.">
            Blank Ground
          </button>
          <button className="btn" onClick={() => onNewBlank(EMPTY)} title="Clear the map to empty (white), same size.">
            Blank Empty
          </button>
        </div>
        <div className="row two">
          <button className="btn" onClick={() => fileRef.current?.click()} title="Open a 4-colour PNG (up to 256 x 256) to edit it.">
            Open PNG…
          </button>
          <button className="btn accent" onClick={onExport} title="Save the PNG to drag into Pixel Map › Source Image (Ctrl+S).">
            Export PNG
          </button>
        </div>
        <input
          ref={fileRef}
          type="file"
          accept="image/png,image/gif,image/bmp,image/webp"
          hidden
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) onOpen(file);
            e.target.value = "";
          }}
        />
      </section>
    </aside>
  );
}
