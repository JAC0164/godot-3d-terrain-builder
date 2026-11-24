"""Web images for the documentation site (docs/img/), from the showcase renders
without captions (render_showcase.gd -- --clean=1 writes docs/showcase/clean/), and
the brush-ring close-ups of the editor tour (docs/editor/ring_*.webp), cut from the
3D view shots of tools/editor_shots/run_editor_shots.sh.

    python tools/site_images.py        (from test_project/, needs Pillow)

The hero stays 1920 wide; the other shots are 1280 wide (the site never shows
them bigger). WebP quality 82.
"""
from pathlib import Path

from PIL import Image

DOCS = Path(__file__).resolve().parents[2] / "docs"
SOURCE = DOCS / "showcase" / "clean"
OUT = DOCS / "img"
WIDTHS = {"hero": 1920}
PIXEL_MAP = Path(__file__).resolve().parents[1] / "assets" / "pixel_maps" / "savane_anneau.png"


def main() -> None:
    OUT.mkdir(exist_ok=True)
    sources = sorted(SOURCE.glob("*.jpg"))
    for path in sources:
        image = Image.open(path).convert("RGB")
        width = WIDTHS.get(path.stem, 1280)
        if image.width > width:
            image = image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)
        target = OUT / (path.stem + ".webp")
        image.save(target, "WEBP", quality=82, method=6)
        print(f"{target.name} {image.width}x{image.height} {target.stat().st_size // 1024} KB")
    # The pixel map behind pixel_map_terrain, blown up without smoothing (lossless).
    pixel = Image.open(PIXEL_MAP).convert("RGB")
    pixel = pixel.resize((pixel.width * 4, pixel.height * 4), Image.NEAREST)
    pixel.save(OUT / "pixel_map_source.webp", "WEBP", lossless=True)
    print(f"pixel_map_source.webp {pixel.width}x{pixel.height}")
    # The ring is drawn at 42 % / 60 % of the view (shots.gd), its label to the right.
    for tool in ("relief", "vegetation", "river"):
        view = Image.open(DOCS / "editor" / f"viewport_{tool}.webp").convert("RGB")
        cx, cy = int(0.42 * view.width) + 110, int(0.6 * view.height) - 20
        view.crop((cx - 240, cy - 180, cx + 240, cy + 180)).save(
            DOCS / "editor" / f"ring_{tool}.webp", "WEBP", quality=88, method=6)
        print(f"ring_{tool}.webp 480x360")


if __name__ == "__main__":
    main()
