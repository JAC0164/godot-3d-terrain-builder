@tool
extends RefCounted
## Toolbar icons, drawn as small SVGs and rasterised at the editor scale (sharp
## at 100 %, 125 %, 150 %... without .import files). Light strokes on dark
## editor themes, dark strokes on light themes.

const _HEAD := '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="%s" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'

const _PATHS := {
	# Hill + plus.
	"new": '<path d="M1 14 L5.5 8.5 L8.5 11.5 L11 9 L15 14 Z"/><path d="M12 1.5v5M9.5 4h5"/>',
	# Brush.
	"paint": '<path d="M14 2 L7.5 8.5"/><path d="M7.5 8.5 C4.5 8.5 3.5 10.5 2 14 C5.5 13 7.5 12 8.5 9.5 Z"/>',
	# Ground line + arrow up.
	"raise": '<path d="M1.5 14 H14.5"/><path d="M8 11.5 V2.5"/><path d="M4.5 6 L8 2.5 L11.5 6"/>',
	# Press down onto a flat line.
	"flatten": '<path d="M1.5 14 H14.5"/><path d="M2 9.5 H14"/><path d="M5 3 L8 6 L11 3"/>',
	# Track in perspective, dashed centre line.
	"road": '<path d="M4 15 L6.5 1"/><path d="M12 15 L9.5 1"/><path d="M8 3v1.5M8 7.5v2M8 12.5v2"/>',
	# Two waves.
	"river": '<path d="M1.5 5.5 C3.5 3.5 5.5 7.5 8 5.5 S12.5 3.5 14.5 5.5"/><path d="M1.5 10.5 C3.5 8.5 5.5 12.5 8 10.5 S12.5 8.5 14.5 10.5"/>',
	# Cracked basin.
	"waterhole": '<ellipse cx="8" cy="9" rx="6.75" ry="4.75"/><path d="M8 4.5 V8 L5 10 M8 8 L11 9 L12 12 M5 10 L4.5 12.5"/>',
	# Tree (Vegetation brush).
	"vegetation": '<path d="M8 15 V9"/><path d="M8 9 C4.5 9 2.5 7.5 2.5 5.5 C2.5 3.5 4.5 2 8 2 C11.5 2 13.5 3.5 13.5 5.5 C13.5 7.5 11.5 9 8 9 Z"/><path d="M5 15 H11"/>',
	# Circle + radius (brush size).
	"size": '<circle cx="8" cy="8" r="6"/><path d="M8 8 H14"/><path d="M8 7.25 v1.5"/>',
	# Rising bars (brush strength).
	"strength": '<path d="M3 13.5 V10.5 M8 13.5 V7 M13 13.5 V3"/>',
}

static var _cache: Dictionary = {}

static func get_icon(icon_name: String) -> Texture2D:
	var scale := 1.0
	var stroke := "#e0e0e0"
	if Engine.is_editor_hint():
		scale = EditorInterface.get_editor_scale()
		var settings := EditorInterface.get_editor_settings()
		if settings and settings.has_setting("interface/theme/base_color"):
			var base: Color = settings.get_setting("interface/theme/base_color")
			if base.get_luminance() > 0.5:
				stroke = "#303030"
	var key := "%s@%s@%s" % [icon_name, scale, stroke]
	if _cache.has(key):
		return _cache[key]
	var image := Image.new()
	var path: String = _PATHS.get(icon_name, "")
	if image.load_svg_from_string((_HEAD % stroke) + path + "</svg>", scale) != OK:
		return null
	var texture := ImageTexture.create_from_image(image)
	_cache[key] = texture
	return texture
