extends SceneTree
## Fingerprint of MapGenerator's data (both map presets, 3 sizes, 2 seeds):
## an optimisation of the generator must print the same lines. Also the
## time of each generation.
##   Godot --headless --path . --script res://tools/hash_generator.gd
## Compare the "map" lines with results/big_world/generator_baseline.txt.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")

const KEYS := ["_lte_resolution", "_lte_world_size", "_lte_heights", "_lte_mask", "_lte_cell_active", "_lte_cell_styles",
	"_lte_style_palette", "_lte_roads", "_lte_waterholes", "_lte_height_max", "_lte_height_min", "_lte_cell_vegetation"]

func _initialize() -> void:
	for preset in ["senegal_savanna_map", "temperate_island_map"]:
		for size in [64, 256, 1024]:
			for map_seed in [1, 7]:
				var recipe: Resource = load(ADDON + "generation/presets/%s.tres" % preset).duplicate()
				recipe.size = size
				recipe.cell_size = 1.5
				var terrain := Node3D.new()
				root.add_child(terrain)
				TerrainData.initialize(terrain)
				var start := Time.get_ticks_usec()
				MapGenerator.generate(terrain, recipe, map_seed)
				var ms := (Time.get_ticks_usec() - start) / 1000.0
				var parts: Array = []
				for key: String in KEYS:
					parts.append(var_to_str(terrain.get_meta(key, null)).hash())
				print("map %s %d seed %d: %d (%.0f ms)" % [preset, size, map_seed, hash(parts), ms])
				terrain.free()
	quit()
