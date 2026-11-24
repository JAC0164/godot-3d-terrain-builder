# Pixel Map Editor

Generator and editor of pixel maps for the terrain's **Pixel Map** import (Inspector >
Advanced > Pixel Map > Source Image > Generate from Image). One pixel = one terrain cell:

| Colour | Terrain |
|---|---|
| White `#FFFFFF` | empty |
| Green `#00FF00` | ground |
| Red `#FF0000` | raised ground (Raised Ground Height) |
| Blue `#0000FF` | lowered ground (Lowered Ground Depth) |

Up to 256 x 256 pixels. The export uses these exact colours, so every pixel is recognised by
the plugin.

**To use it:** open it online at https://jac0164.github.io/godot-3d-terrain-builder/map-editor.html, or open
`docs/map-editor.html` from the repository in a browser (one file, works offline, no install).
This folder is only its source code.

## Features

- **Generator**:
  - size, seed (same seed + settings = same map);
  - shapes: Island, Archipelago, Continent, Central Lake, Valley, Plateau;
  - Feature Size, Detail, Edge Margin;
  - shares of each colour (what you ask is what you get);
  - cleanup: Smooth Borders, Min Region.

  Picking a shape loads its starting shares. Settings apply live; **Generate** = new seed.
- **Editor**:
  - colours 1-4;
  - Pencil (B), Eraser (E), Paint Bucket (G), Line (L), Rectangle (R), Ellipse (O), Colour
    Picker (I);
  - brush size `[` `]`, round / square;
  - filled or outline shapes;
  - mirror left-right / top-bottom;
  - right click paints Empty.
- **View**:
  - undo / redo: Ctrl+Z, Ctrl+Y, 100 steps;
  - wheel zoom, pan with Space + drag or the middle button;
  - grid from zoom x8, Fit (F).
- **File**:
  - Blank Ground / Blank Empty;
  - Open PNG… (a 4-colour map up to 256 px, nearest colour per pixel);
  - Export PNG (Ctrl+S).

  The map and settings are also kept in the browser between sessions.

## Development

```
npm install
npm run dev      # http://localhost:5173
npm test         # vitest: generator, drawing, history, PNG colours
npm run build    # typecheck + single-file build -> ../../docs/map-editor.html
```

Vite + React + TypeScript. `vite-plugin-singlefile` inlines everything into one HTML file.
`exemple_formes_godot.png` shows the six shapes (128 px, seed 7), each built by the plugin's
own import.
