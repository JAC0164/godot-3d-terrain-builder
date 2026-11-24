extends SceneTree
## Where the road / river mesh time goes on a big map (phase 3): distance
## field, triangulation, surface upload, per connected group.
##   Godot --headless --path . --script res://tools/profile_roads.gd

const Meta = preload("res://addons/lowpoly_terrain_editor/core/terrain_meta.gd")
const TerrainData = preload("res://addons/lowpoly_terrain_editor/core/terrain_data.gd")
const MapGenerator = preload("res://addons/lowpoly_terrain_editor/generation/map_generator.gd")
const TerrainBuilder = preload("res://addons/lowpoly_terrain_editor/mesh/terrain_builder.gd")
const RoadMesher = preload("res://addons/lowpoly_terrain_editor/mesh/road_mesher.gd")
const RiverMesher = preload("res://addons/lowpoly_terrain_editor/mesh/river_mesher.gd")
const FeatureMesher = preload("res://addons/lowpoly_terrain_editor/mesh/feature_mesher.gd")

func _ms(start: int) -> float:
	return (Time.get_ticks_usec() - start) / 1000.0

func _initialize() -> void:
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	var recipe: Resource = load("res://addons/lowpoly_terrain_editor/generation/presets/senegal_savanna_map.tres").duplicate()
	recipe.size = 1024
	recipe.cell_size = 1.5
	MapGenerator.generate(terrain, recipe, 7)
	var builder := TerrainBuilder.new()
	var carve := builder.get_river_carve(terrain)
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	print("roads %d, rivers %d" % [roads.size(), rivers.size()])
	for group: Array in RoadMesher.group_connected(roads):
		var t := Time.get_ticks_usec()
		var cell_size := RoadMesher.union_cell_size(terrain)
		var field := RoadMesher.corner_field(group, cell_size, RoadMesher.union_grid_origin(terrain))
		var field_ms := _ms(t)
		t = Time.get_ticks_usec()
		var state := RoadMesher.union_begin(terrain, carve, group)
		var begin_ms := _ms(t)
		t = Time.get_ticks_usec()
		RoadMesher.union_step(state)
		var step_ms := _ms(t)
		var result := RoadMesher.union_result(state)
		var vertices: Array = result["vertices"]
		print("road group of %d: field %.0f ms (%d x %d corners, %d cells), begin %.0f ms, triangulate %.0f ms, %d vertices" % [
			group.size(), field_ms, field["width"], field["height"], (field["cells"] as PackedInt32Array).size(), begin_ms, step_ms, vertices.size()])
	var start := Time.get_ticks_usec()
	var job := FeatureMesher.start(terrain, carve)
	FeatureMesher.step(job)
	FeatureMesher.finish(job)
	print("whole feature mesh: %.0f ms" % _ms(start))
	quit()
