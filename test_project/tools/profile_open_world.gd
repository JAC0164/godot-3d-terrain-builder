extends SceneTree
## The open-world preset (1 024 cells, rivers, border, track network): time
## of each generation step, of the river carve and of the road / river mesh.
##   Godot --headless --path . --script res://tools/profile_open_world.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")

func _ms(t: int) -> float:
	return (Time.get_ticks_usec() - t) / 1000.0

func _initialize() -> void:
	var recipe: Resource = load(ADDON + "generation/presets/senegal_savanna_open_world_map.tres")
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
		line += "%s %.0f | " % [label, _ms(t)]
	print("generate %.0f ms: %s%s" % [generation.stats["ms"], line, generation.stats])
	var builder := TerrainBuilder.new()
	var t := Time.get_ticks_usec()
	builder.rebuild_river_carve(terrain)
	print("river carve: %.0f ms" % _ms(t))
	t = Time.get_ticks_usec()
	var result: Dictionary = FeatureMesher.build(terrain, builder.get_river_carve(terrain))
	var mesh: ArrayMesh = result["mesh"]
	var vertices := 0
	for s in mesh.get_surface_count():
		vertices += (mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	print("roads + rivers mesh: %.0f ms, %d surfaces, %d vertices" % [_ms(t), mesh.get_surface_count(), vertices])
	quit()
