extends SceneTree
## Rebuilds the road/river mesh of a saved terrain scene with the current
## plugin code and compares it with the mesh stored in the scene (produced by
## whatever code generated the scene). Used to prove a mesher optimisation
## does not change the output.
##
##   godot --headless --path . --script res://tools/compare_feature_mesh.gd -- --terrain=res://scenes/savanna_128.tscn

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var path := "res://scenes/savanna_128.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):
			path = arg.trim_prefix("--terrain=")
	var root := TestTerrain.load_scene(path)
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var stored: ArrayMesh = terrain.get_node(Meta.GENERATED_MESH_NAME).mesh
	var rebuilt: ArrayMesh = FeatureMesher.build(terrain, RiverMesher.compute_carve(terrain))["mesh"]

	var ok := stored.get_surface_count() == rebuilt.get_surface_count()
	print("surfaces: stored %d, rebuilt %d" % [stored.get_surface_count(), rebuilt.get_surface_count()])
	for i in range(mini(stored.get_surface_count(), rebuilt.get_surface_count())):
		var a := stored.surface_get_arrays(i)
		var b := rebuilt.surface_get_arrays(i)
		for kind in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
			var same: bool = a[kind] == b[kind]
			var max_delta := 0.0
			if not same and a[kind] != null and b[kind] != null and a[kind].size() == b[kind].size():
				for j in range(a[kind].size()):
					max_delta = maxf(max_delta, (a[kind][j] - b[kind][j]).length())
			print("  surface %d array %d: %s (%d values, max delta %g)" % [i, kind, "identical" if same else "DIFFERENT", a[kind].size(), max_delta])
			ok = ok and same
	print("RESULT: %s" % ("IDENTICAL" if ok else "DIFFERENT"))
	root.free()
	quit(0 if ok else 1)
