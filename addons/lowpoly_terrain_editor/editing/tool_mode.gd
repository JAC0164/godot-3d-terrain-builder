@tool
extends RefCounted
## Viewport editing tools.

const Meta = preload("../core/terrain_meta.gd")

enum Mode {
	NONE, PAINT, ERASE, RAISE, LOWER, FLATTEN, SMOOTH, ROAD, RIVER, WATERHOLE,
	## Vegetation brush: thicker (VEGETATION), thinner down to none (Ctrl),
	## back to the biome's own density (Shift).
	VEGETATION, VEGETATION_CLEAR, VEGETATION_RESET
}

## Limits of the toolbar Size / Strength fields, the [ ] and - + keys and the
## Inspector width rows. Defined once here so every place agrees.
## Brush tools: radius (m).
const BRUSH_RADIUS_MIN := 0.5
const BRUSH_RADIUS_MAX := 12.0
const BRUSH_RADIUS_STEP := 0.25
## Brush tools: strength.
const BRUSH_STRENGTH_MIN := 0.05
const BRUSH_STRENGTH_MAX := 4.0
const BRUSH_STRENGTH_STEP := 0.05
## Road / River tools: width (m) of the next road or river.
const FEATURE_WIDTH_MIN := 0.25
const FEATURE_WIDTH_MAX := 24.0
const FEATURE_WIDTH_STEP := 0.1

static func display_name(mode: Mode) -> String:
	match mode:
		Mode.PAINT: return "Ground"
		Mode.ERASE: return "Ground: remove"
		Mode.RAISE: return "Relief"
		Mode.LOWER: return "Relief: dig"
		Mode.FLATTEN: return "Flatten"
		Mode.SMOOTH: return "Smooth"
		Mode.ROAD: return "Road"
		Mode.RIVER: return "River"
		Mode.WATERHOLE: return "Waterhole"
		Mode.VEGETATION: return "Vegetation +"
		Mode.VEGETATION_CLEAR: return "Vegetation -"
		Mode.VEGETATION_RESET: return "Vegetation reset"
		_: return "Select"

static func is_feature_tool(mode: Mode) -> bool:
	return mode == Mode.ROAD or mode == Mode.RIVER

## Terrain setting holding the width of the next road (ROAD) or river.
static func feature_width_key(mode: Mode) -> String:
	return Meta.ROAD_WIDTH if mode == Mode.ROAD else Meta.RIVER_WIDTH

## Width of the next road (ROAD) or river drawn on `terrain`.
static func feature_width(terrain: Node3D, mode: Mode) -> float:
	var fallback := Meta.DEFAULT_ROAD_WIDTH if mode == Mode.ROAD else Meta.DEFAULT_RIVER_WIDTH
	return Meta.get_float(terrain, feature_width_key(mode), fallback)

## Circular brush tools (radius + strength, Ctrl / Shift variants).
static func is_brush_tool(mode: Mode) -> bool:
	return mode in [Mode.PAINT, Mode.ERASE, Mode.RAISE, Mode.LOWER, Mode.FLATTEN, Mode.SMOOTH] or is_vegetation_tool(mode)

## The Vegetation brush and its variants: they only change where details grow.
static func is_vegetation_tool(mode: Mode) -> bool:
	return mode == Mode.VEGETATION or mode == Mode.VEGETATION_CLEAR or mode == Mode.VEGETATION_RESET

## The tool a click applies with the modifiers held (common terrain-editor
## convention: Terrain3D, Unity, Blender): Ctrl inverts (Paint <-> Erase,
## Raise <-> Lower), Shift smooths.
static func with_modifiers(mode: Mode, invert: bool, smooth: bool) -> Mode:
	if is_vegetation_tool(mode):
		# Ctrl: fewer / none · Shift: back to normal.
		if smooth:
			return Mode.VEGETATION_RESET
		if invert:
			return Mode.VEGETATION if mode == Mode.VEGETATION_CLEAR else Mode.VEGETATION_CLEAR
		return mode
	if not is_brush_tool(mode):
		return mode
	if smooth:
		return Mode.SMOOTH
	if invert:
		match mode:
			Mode.PAINT: return Mode.ERASE
			Mode.ERASE: return Mode.PAINT
			Mode.RAISE: return Mode.LOWER
			Mode.LOWER: return Mode.RAISE
	return mode

## One-line usage hint (status bar).
static func hint(mode: Mode) -> String:
	match mode:
		Mode.PAINT: return "Ground: drag to add ground · Ctrl erase · Shift smooth"
		Mode.ERASE: return "Ground: remove · a stroke starting on a road / river removes it · Ctrl add · Shift smooth"
		Mode.RAISE: return "Relief: drag to raise · Ctrl dig · Shift smooth"
		Mode.LOWER: return "Relief: dig · Ctrl raise · Shift smooth"
		Mode.FLATTEN: return "Flatten: drag, to the height under the click · Shift smooth"
		Mode.SMOOTH: return "Smooth: drag"
		Mode.ROAD: return "Road: drag to draw · [ ] width"
		Mode.RIVER: return "River: drag to draw · [ ] width"
		Mode.WATERHOLE: return "Waterhole: click to place · Ctrl+click in it with Ground to remove"
		Mode.VEGETATION: return "Vegetation: drag for more trees / grass · Ctrl fewer, none · Shift back to normal"
		Mode.VEGETATION_CLEAR: return "Vegetation -: drag for fewer, then none · Ctrl more · Shift back to normal"
		Mode.VEGETATION_RESET: return "Vegetation reset: drag back to the biome's own density"
		_: return "Pick a tool"
