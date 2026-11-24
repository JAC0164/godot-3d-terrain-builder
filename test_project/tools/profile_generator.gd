extends SceneTree
## Time of each step of MapGenerator (start / step) on a 1 024-cell map
## (savanna, seed 7), three runs.
##   Godot --headless --path . --script res://tools/profile_generator.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")

func _initialize() -> void:
	var recipe: Resource = load(ADDON + "generation/presets/senegal_savanna_map.tres").duplicate()
	recipe.size = 1024
	recipe.cell_size = 1.5
	for run in 3:
		var terrain := Node3D.new()
		root.add_child(terrain)
		TerrainData.initialize(terrain)
		var generation := MapGenerator.start(terrain, recipe, 7)
		var line := ""
		var finished := false
		while not finished:
			var label := generation.next_step()
			var t := Time.get_ticks_usec()
			finished = MapGenerator.step(generation)
			line += "%s %.0f | " % [label, (Time.get_ticks_usec() - t) / 1000.0]
		print("generate %.0f ms: %s(cores %d)" % [generation.stats["ms"], line, OS.get_processor_count()])
		terrain.free()
	quit()
