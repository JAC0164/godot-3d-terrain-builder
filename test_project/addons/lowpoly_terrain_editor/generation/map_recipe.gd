@tool
class_name LowpolyMapRecipe
extends Resource
## How to generate a whole map from a seed: outline, relief, plateaus,
## lowlands, ground patches, tracks and dried waterholes, painted with the
## ground styles of a biome. The same recipe + seed always gives the same map,
## in the editor (Inspector > Map Generator) or in the game
## (LowpolyTerrainRuntime / MapGenerator.generate()).
##
## Style fields are names of the biome's ground styles (e.g. "Laterite").
## Duplicate a preset and tweak it per game.

const MapPatch = preload("map_patch.gd")

@export var name := "Map"
## Ground styles + detail layers + shading of the map. Empty = the terrain's
## current biome.
@export var biome: Resource
## Cells per side (MapGenerator.MIN_SIZE..MAX_SIZE; 1024 x 1.5 m cells = a
## 1.5 km open world).
@export_range(16, 1024, 1) var size := 128
## World units per cell (1 = the detail meshes' natural size).
@export_range(0.25, 8.0, 0.05) var cell_size := 1.0
## Turn on the terrain's ground collision (needed to walk on the map).
@export var ground_collision := true

@export_group("Outline")
## 0 = the map fills the whole square; higher = an irregular island.
@export_range(0.0, 1.0, 0.01) var island := 0.0
## How wobbly the island coast is.
@export_range(0.0, 1.0, 0.01) var coast_noise := 0.5

@export_group("Border")
## What closes the map at its square edge: nothing (the map just ends),
## hills rising towards the edge, or cliffs (two steps). Rivers cut a valley
## through it.
@export_enum("None", "Hills", "Cliffs") var border := 0
## Width of the border, in cells.
@export_range(4.0, 256.0, 1.0) var border_width := 40.0
## Height of the border at the map edge.
@export_range(0.0, 32.0, 0.1) var border_height := 8.0
## How irregular the border's inner edge is.
@export_range(0.0, 1.0, 0.01) var border_noise := 0.5
@export var border_style := "Laterite"

@export_group("Ground")
@export var base_style := "Dry Grass"
## Height of the gentle rolling relief over the whole map.
@export_range(0.0, 4.0, 0.05) var relief := 0.35
## Size of the relief undulations, in cells.
@export_range(8.0, 512.0, 1.0) var relief_scale := 70.0

@export_group("Plateaus")
@export var plateau_style := "Laterite"
## Share (0..1) of the map raised as plateaus.
@export_range(0.0, 0.9, 0.01) var plateau_coverage := 0.16
@export_range(0.0, 16.0, 0.1) var plateau_height := 2.5
## Average plateau size, in cells.
@export_range(4.0, 512.0, 1.0) var plateau_scale := 45.0
## Slope width at plateau edges, in cells (0 = vertical cliffs).
@export_range(0.0, 32.0, 0.5) var plateau_smoothness := 3.0

@export_group("Lowlands")
@export var lowland_style := "Green Savanna"
@export_range(0.0, 0.9, 0.01) var lowland_coverage := 0.1
@export_range(0.0, 8.0, 0.05) var lowland_depth := 0.8
@export_range(4.0, 512.0, 1.0) var lowland_scale := 35.0
@export_range(0.0, 32.0, 0.5) var lowland_smoothness := 4.0

@export_group("Patches")
@export var patches: Array[MapPatch] = []

@export_group("Rivers")
## Rivers along the low ground (the terrain is carved under them): the
## first crosses the map from edge to edge, the others flow into it.
@export_range(0, 8) var river_count := 0
## River width, in cells.
@export_range(0.5, 32.0, 0.1) var river_width := 3.0
@export_range(0.05, 8.0, 0.05) var river_depth := 0.8
## How much the rivers wander off the lowest path.
@export_range(0.0, 1.0, 0.01) var river_meander := 0.5

@export_group("Tracks")
## Tracks from edge to edge (with Track Network: the map exits).
@export_range(0, 16) var track_count := 1
@export_range(0.25, 16.0, 0.05) var track_width := 2.6
@export var track_color := Color(0.66, 0.4, 0.26)
## How much the tracks wind (0 = straight).
@export_range(0.0, 1.0, 0.01) var track_meander := 0.5
## Tracks join the map exits and the waterholes, along the easy ground
## (they go round plateaus, steep slopes and rivers), instead of crossing the
## map. The waterholes are placed first.
@export var track_network := false
## Waterholes the network joins (the most spread out ones).
@export_range(0, 64) var track_network_stops := 8

@export_group("Dried Waterholes")
## Waterholes per 100 x 100 cells (placed on flat open ground only).
@export_range(0.0, 20.0, 0.05) var waterholes_per_10k_cells := 1.0
## Radius range, in cells.
@export_range(1.0, 64.0, 0.25) var waterhole_radius_min := 4.0
@export_range(1.0, 64.0, 0.25) var waterhole_radius_max := 9.0

# -----------------------------------------------------------------------------
# Presets (saved as generation/presets/*.tres by test_project/tools/save_biome_presets.gd)
# -----------------------------------------------------------------------------

## Dry-season Sahel savanna: flat straw-coloured plain, low laterite
## plateaus, greener lowlands, burnt and sandy patches, red dirt tracks and
## a few dried waterholes.
static func make_senegal_savanna(savanna_biome: Resource) -> Resource:
	var recipe := new()
	recipe.name = "Senegal Savanna"
	recipe.biome = savanna_biome
	recipe.size = 192
	recipe.island = 0.0
	recipe.base_style = "Dry Grass"
	recipe.relief = 0.45
	recipe.relief_scale = 60.0
	recipe.plateau_style = "Laterite"
	recipe.plateau_coverage = 0.12
	recipe.plateau_height = 2.2
	recipe.plateau_scale = 40.0
	recipe.plateau_smoothness = 2.5
	recipe.lowland_style = "Green Savanna"
	recipe.lowland_coverage = 0.12
	recipe.lowland_depth = 0.7
	recipe.lowland_scale = 30.0
	recipe.lowland_smoothness = 5.0
	recipe.patches = [
		_patch("Laterite", 0.08, 14.0, ""),
		_patch("Burnt Ground", 0.035, 26.0, ""),
		_patch("Sand", 0.05, 10.0, ""),
	]
	recipe.track_count = 2
	recipe.track_width = 2.6
	recipe.track_color = Color(0.66, 0.4, 0.26)
	recipe.track_meander = 0.55
	recipe.waterholes_per_10k_cells = 1.6
	recipe.waterhole_radius_min = 4.0
	recipe.waterhole_radius_max = 8.0
	return recipe

## The savanna as a 1.5 km open world: hills close the map, two rivers
## cross it along the low ground, a track network joins the map exits and
## the waterholes, and wide zones of green savanna and dry clay break the
## plain.
static func make_senegal_open_world(savanna_biome: Resource) -> Resource:
	var recipe := new()
	recipe.name = "Senegal Open World"
	recipe.biome = savanna_biome
	recipe.size = 1024
	recipe.cell_size = 1.5
	recipe.border = 1
	recipe.border_width = 48.0
	recipe.border_height = 9.0
	recipe.border_noise = 0.6
	recipe.border_style = "Laterite"
	recipe.base_style = "Dry Grass"
	recipe.relief = 0.9
	recipe.relief_scale = 140.0
	recipe.plateau_style = "Laterite"
	recipe.plateau_coverage = 0.1
	recipe.plateau_height = 3.0
	recipe.plateau_scale = 110.0
	recipe.plateau_smoothness = 3.0
	recipe.lowland_style = "Green Savanna"
	recipe.lowland_coverage = 0.12
	recipe.lowland_depth = 0.9
	recipe.lowland_scale = 60.0
	recipe.lowland_smoothness = 6.0
	recipe.patches = [
		# Zones: wide areas of another ground.
		_patch("Green Savanna", 0.14, 220.0, ""),
		_patch("Dry Clay", 0.1, 160.0, ""),
		# Small patches in them.
		_patch("Laterite", 0.04, 24.0, ""),
		_patch("Burnt Ground", 0.04, 40.0, ""),
		_patch("Sand", 0.04, 12.0, ""),
	]
	recipe.river_count = 2
	recipe.river_width = 4.0
	recipe.river_depth = 0.9
	recipe.river_meander = 0.5
	recipe.track_count = 4
	recipe.track_width = 2.6
	recipe.track_color = Color(0.66, 0.4, 0.26)
	recipe.track_meander = 0.5
	recipe.track_network = true
	recipe.track_network_stops = 10
	recipe.waterholes_per_10k_cells = 0.6
	recipe.waterhole_radius_min = 4.0
	recipe.waterhole_radius_max = 9.0
	return recipe

## Green rolling island with rocky plateaus and sandy lowlands.
static func make_temperate_island(temperate_biome: Resource) -> Resource:
	var recipe := new()
	recipe.name = "Temperate Island"
	recipe.biome = temperate_biome
	recipe.size = 128
	recipe.island = 0.7
	recipe.coast_noise = 0.6
	recipe.base_style = "Grass"
	recipe.relief = 0.8
	recipe.relief_scale = 40.0
	recipe.plateau_style = "Rock"
	recipe.plateau_coverage = 0.18
	recipe.plateau_height = 4.0
	recipe.plateau_scale = 30.0
	recipe.plateau_smoothness = 2.0
	recipe.lowland_style = "Sand"
	recipe.lowland_coverage = 0.08
	recipe.lowland_depth = 0.5
	recipe.track_count = 1
	recipe.track_color = Color(0.55, 0.45, 0.32)
	recipe.waterholes_per_10k_cells = 0.0
	return recipe

static func _patch(style_name: String, coverage: float, patch_scale: float, on_style: String) -> Resource:
	var patch := MapPatch.new()
	patch.style = style_name
	patch.coverage = coverage
	patch.scale = patch_scale
	patch.on_style = on_style
	return patch
