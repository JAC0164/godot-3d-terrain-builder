extends SceneTree
## Times each step of the road/river mesh rebuild on a saved terrain scene,
## and the end of a sculpt stroke over a feature (the editor freeze).
##
##   godot --headless --path . --script res://tools/profile_features.gd -- --terrain=res://scenes/savanna_128.tscn

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const RoadMesher = preload(ADDON + "mesh/road_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const StrokeController = preload(ADDON + "editing/stroke_controller.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _ms(start: int) -> float:
	return snappedf(float(Time.get_ticks_usec() - start) / 1000.0, 0.1)

func _initialize() -> void:
	var path := "res://scenes/savanna_128.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):
			path = arg.trim_prefix("--terrain=")
	var root := TestTerrain.load_scene(path)
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	var size := int(terrain.get_meta(Meta.WORLD_SIZE))

	var t := Time.get_ticks_usec()
	var road_groups := RoadMesher.group_connected(roads)
	print("roads: %d in %d group(s), group_connected %.1f ms" % [roads.size(), road_groups.size(), _ms(t)])
	var cell_size := RoadMesher.union_cell_size(terrain)
	for group in road_groups:
		t = Time.get_ticks_usec()
		RoadMesher.build_surface_union(terrain, carve, group)
		print("  road group of %d: surface %.1f ms (union cell %.2f m)" % [group.size(), _ms(t), cell_size])

	t = Time.get_ticks_usec()
	var river_groups := RiverMesher.group_connected(terrain, rivers)
	print("rivers: %d in %d group(s), group_connected %.1f ms" % [rivers.size(), river_groups.size(), _ms(t)])
	for group in river_groups:
		t = Time.get_ticks_usec()
		var water := RiverMesher.build_water_union(terrain, carve, group)
		print("  water group: %d verts, %.1f ms" % [water["vertices"].size(), _ms(t)])

	t = Time.get_ticks_usec()
	FeatureMesher.build(terrain, carve)
	print("FeatureMesher.build total: %.1f ms" % _ms(t))

	# Editor freeze: a raise stroke across a road/river, timed like the editor.
	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)
	var strokes := StrokeController.new(builder)
	strokes.mode = ToolMode.Mode.RAISE
	var start := Vector3(-0.15 * size, 0.0, 0.05 * size)
	t = Time.get_ticks_usec()
	strokes.begin(terrain, start)
	var begin_ms := _ms(t)
	t = Time.get_ticks_usec()
	for i in range(30):
		strokes.update(terrain, start + Vector3(float(i) * 0.5, 0.0, 0.0))
	var dab_ms := _ms(t) / 30.0
	t = Time.get_ticks_usec()
	strokes.end(terrain)
	print("stroke over features: begin %.1f ms, per dab %.1f ms, END (freeze) %.1f ms" % [begin_ms, dab_ms, _ms(t)])

	root.free()
	quit()
