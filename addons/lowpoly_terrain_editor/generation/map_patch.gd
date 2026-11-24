@tool
class_name LowpolyMapPatch
extends Resource
## Ground patches of one style painted by a map recipe (see map_recipe.gd):
## noise blobs covering a share of the cells that have `on_style`.

## Name of a ground style of the recipe's biome.
@export var style := "Burnt Ground"
## Share (0..1) of the eligible cells covered.
@export_range(0.0, 1.0, 0.01) var coverage := 0.1
## Average patch size, in cells.
@export_range(2.0, 256.0, 0.5) var scale := 20.0
## Only paint over this ground style ("" = the recipe's base style).
@export var on_style := ""
