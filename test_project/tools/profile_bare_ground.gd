extends SceneTree
## Details Everywhere on / off on the same terrain: detail instances and the
## time of DetailScatter.build over every chunk (best of 3).
##   everywhere   = old behaviour, the biome grows on all ground
##   generated    = off, the map made by Generate Map ("#grow" cells): same result
##   hand-painted = off, ground painted by hand (no "#grow" cells): only the
##                  scene's Vegetation brush strokes grow
##   bare         = off, no brush strokes either: nothing at all
##   godot --headless --path . --script res://tools/profile_bare_ground.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var root := TestTerrain.load_scene()
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	WaterholeMesher.add_carve(terrain, carve)
	var count := TerrainMesher.chunk_count(terrain)
	var shading := {}
	for cz in range(count):
		for cx in range(count):
			shading[Vector2i(cx, cz)] = TerrainMesher.build_chunk_parts(terrain, carve, cx, cz).get("shading")

	var results := {}
	var strokes := Meta.vegetation_paint(terrain).duplicate()
	strokes.erase(Meta.VEGETATION_GROW)
	print("brush strokes in the scene: %s" % [strokes.keys()])
	for mode in ["everywhere", "generated", "hand-painted", "bare"]:
		var paint := {} if mode == "bare" else strokes.duplicate()
		if mode == "generated":
			paint[Meta.VEGETATION_GROW] = Meta.generated_vegetation(terrain.get_meta(Meta.CELL_ACTIVE))[Meta.VEGETATION_GROW]
		terrain.set_meta(Meta.CELL_VEGETATION, paint)
		terrain.set_meta(Meta.DETAILS_EVERYWHERE, mode == "everywhere")
		var best := INF
		var instances := 0
		var checksum := 0.0
		for run in range(3):
			instances = 0
			checksum = 0.0
			var t0 := Time.get_ticks_usec()
			for cz in range(count):
				for cx in range(count):
					for entry in DetailScatter.build(terrain, carve, cx, cz, shading[Vector2i(cx, cz)]):
						instances += int(entry[1])
						var buffer: PackedFloat32Array = entry[2]
						for i in range(0, buffer.size(), 97):
							checksum += buffer[i]
			best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
		results[mode] = [instances, checksum]
		print("%-13s %7d instances, %6.1f ms for %d chunks (%.2f ms/chunk), checksum %.4f" % [mode, instances, best, count * count, best / (count * count), checksum])
	var same: bool = results["generated"] == results["everywhere"]
	var bare: bool = results["bare"][0] == 0 and results["hand-painted"][0] < results["everywhere"][0]
	print("RESULT: %s (generated = everywhere: %s, bare ground empty: %s)" % ["OK" if same and bare else "FAIL", same, bare])
	root.free()
	quit(0 if same and bare else 1)
