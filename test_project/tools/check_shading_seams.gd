extends SceneTree
## Baked colours must not depend on which chunk / region is being built:
## colours of the cells of chunk (1, 1) are compared between a chunk-sized
## region and a larger region around it.
##   godot --headless --path . --script res://tools/check_shading_seams.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainShading = preload(ADDON + "mesh/terrain_shading.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")

func _initialize() -> void:
	var root := TestTerrain.load_scene()
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	WaterholeMesher.add_carve(terrain, carve)
	var bad := 0
	# The shading is read from the biome: tune a copy of it.
	var biome: Resource = TerrainBiome.of(terrain).duplicate(true)
	terrain.set_meta("_lte_biome", biome)
	for blend in [0, 1, 3]:
		biome.blend = blend
		var small := TerrainShading.prepare(terrain, carve, 32, 32, 64, 64)
		var large := TerrainShading.prepare(terrain, carve, 10, 20, 90, 70)
		for z in range(32, 64):
			for x in range(32, 64):
				for tri in range(2):
					var a := TerrainShading.top_face_color(small, x, z, tri)
					var b := TerrainShading.top_face_color(large, x, z, tri)
					if not a.is_equal_approx(b):
						bad += 1
				for side in range(4):
					var a: Array = TerrainShading.cliff_colors(small, x, z, side, 0, x + 0.5, z + 0.5)
					var b: Array = TerrainShading.cliff_colors(large, x, z, side, 0, x + 0.5, z + 0.5)
					for k in range(3):
						if not (a[k] as Color).is_equal_approx(b[k]):
							bad += 1
		print("blend %d: mismatches so far %d" % [blend, bad])
	print("RESULT: %s" % ("CONSISTENT" if bad == 0 else "SEAMS"))
	root.free()
	quit(0 if bad == 0 else 1)
