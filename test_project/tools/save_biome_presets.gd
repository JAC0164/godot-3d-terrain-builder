extends SceneTree
## Writes the built-in biome presets and map recipes as .tres files into the
## addon.
##   godot --headless --path . --script res://tools/save_biome_presets.gd
## Copy addons/lowpoly_terrain_editor/biomes/presets/ and
## addons/lowpoly_terrain_editor/generation/presets/ back to the main addon.

const DIR := "res://addons/lowpoly_terrain_editor/biomes/presets/"
const MAP_DIR := "res://addons/lowpoly_terrain_editor/generation/presets/"
const TerrainBiome = preload("res://addons/lowpoly_terrain_editor/biomes/terrain_biome.gd")
const MapRecipe = preload("res://addons/lowpoly_terrain_editor/generation/map_recipe.gd")

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	DirAccess.make_dir_recursive_absolute(MAP_DIR)
	var presets := {
		"temperate.tres": TerrainBiome.make_temperate(),
		"senegal_savanna.tres": TerrainBiome.make_senegal_savanna(),
	}
	for file in presets:
		var err := ResourceSaver.save(presets[file], DIR + file)
		print("%s: %s" % [file, error_string(err)])
	# Recipes reference the saved biome files (not embedded copies).
	var savanna := ResourceLoader.load(DIR + "senegal_savanna.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	var temperate := ResourceLoader.load(DIR + "temperate.tres", "", ResourceLoader.CACHE_MODE_REPLACE)
	var recipes := {
		"senegal_savanna_map.tres": MapRecipe.make_senegal_savanna(savanna),
		"temperate_island_map.tres": MapRecipe.make_temperate_island(temperate),
		# MapPresets lists temperate_island_map first: the generic default.
		"senegal_savanna_open_world_map.tres": MapRecipe.make_senegal_open_world(savanna),
	}
	for file in recipes:
		var err := ResourceSaver.save(recipes[file], MAP_DIR + file)
		print("%s: %s" % [file, error_string(err)])
	quit(0)
