extends SceneTree
## Time DetailScatter.build over every chunk of a terrain (best of 3).
##   godot --headless --path . --script res://tools/profile_details.gd -- --terrain=res://scenes/savanna_128.tscn

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var path := "res://scenes/savanna_128.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):
			path = arg.trim_prefix("--terrain=")
	var root := TestTerrain.load_scene(path)
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	WaterholeMesher.add_carve(terrain, carve)
	var count := TerrainMesher.chunk_count(terrain)
	var shading := {}
	for cz in range(count):
		for cx in range(count):
			var parts := TerrainMesher.build_chunk_parts(terrain, carve, cx, cz)
			shading[Vector2i(cx, cz)] = parts.get("shading")
	var best := INF
	var instances := 0
	var checksum := 0.0
	for run in range(3):
		instances = 0
		checksum = 0.0
		var t0 := Time.get_ticks_usec()
		for cz in range(count):
			for cx in range(count):
				var d := DetailScatter.build(terrain, carve, cx, cz, shading[Vector2i(cx, cz)])
				for entry in d:
					instances += int(entry[1])
					var buffer: PackedFloat32Array = entry[2]
					for i in range(0, buffer.size(), 97):
						checksum += buffer[i]
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
	print("details: %.1f ms for %d chunks (%.2f ms/chunk), %d instances, checksum %.4f" % [best, count * count, best / (count * count), instances, checksum])
	root.free()
	quit(0)
