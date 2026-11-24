extends SceneTree
## Splits the cost of baked shading for one chunk: prepare() vs per-face work.
##   godot --headless --path . --script res://tools/profile_shading.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainShading = preload(ADDON + "mesh/terrain_shading.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var root := TestTerrain.load_scene()
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--zero="):
			terrain.set_meta(arg.trim_prefix("--zero="), 0)
	var runs := 10
	var t0 := Time.get_ticks_usec()
	var ctx: TerrainShading.Context
	for i in range(runs):
		ctx = TerrainShading.prepare(terrain, carve, 32, 32, 64, 64)
	var t1 := Time.get_ticks_usec()
	var t2 := Time.get_ticks_usec()
	print("prepare (incl. every top face colour) %.2f ms" % [(t1 - t0) / 1000.0 / runs])
	root.free()
	quit(0)
