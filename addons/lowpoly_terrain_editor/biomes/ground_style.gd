@tool
class_name LowpolyGroundStyle
extends Resource
## A named ground type of a biome (e.g. "Laterite", "Dry grass", "Clay").
##
## Shown in the toolbar list next to the Ground tool: picking it
## copies these values into the Custom Ground Style (what the Ground tool paints).

@export var name := "Ground":
	set(value):
		name = value
		emit_changed()
@export var top_color := Color(0.44, 0.69, 0.20):
	set(value):
		top_color = value
		emit_changed()
@export var side_color := Color(0.45, 0.25, 0.13):
	set(value):
		side_color = value
		emit_changed()
@export var top_texture: Texture2D:
	set(value):
		top_texture = value
		emit_changed()
@export var side_texture: Texture2D:
	set(value):
		side_texture = value
		emit_changed()
@export_range(0.1, 64.0, 0.1) var top_tile_size := 4.0:
	set(value):
		top_tile_size = value
		emit_changed()
@export_range(0.1, 64.0, 0.1) var side_tile_size := 4.0:
	set(value):
		side_tile_size = value
		emit_changed()

@export_subgroup("Surface (optional)")
## Normal map of the top texture (relief under the light). Empty = flat.
## A realistic look: albedo + normal + roughness from the same texture set.
@export var top_normal: Texture2D:
	set(value):
		top_normal = value
		emit_changed()
## Roughness map of the top texture (red channel; black = shiny, white =
## matte). Empty = fully matte.
@export var top_roughness: Texture2D:
	set(value):
		top_roughness = value
		emit_changed()
## Normal map of the side (cliff) texture. Empty = flat.
@export var side_normal: Texture2D:
	set(value):
		side_normal = value
		emit_changed()
## Roughness map of the side (cliff) texture (red channel). Empty = matte.
@export var side_roughness: Texture2D:
	set(value):
		side_roughness = value
		emit_changed()

## True when a surface texture is set (the ground then uses the PBR variant
## of its materials).
func has_surface() -> bool:
	return top_normal != null or top_roughness != null or side_normal != null or side_roughness != null
