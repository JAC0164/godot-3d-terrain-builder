extends SceneTree
## Rebuilds every terrain chunk of a saved scene with the current plugin code
## and compares it with the chunk meshes stored in the scene.
##
##   --zero   set every baked-shading setting to 0 first (must be IDENTICAL
##            to scenes generated before shading existed)
##   --time   only time a full chunk rebuild with the scene's settings and
##            with shading off
##
##   godot --headless --path . --script res://tools/compare_chunks.gd -- --terrain=res://scenes/savanna_128.tscn --zero

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _set_zero(terrain: Node3D) -> void:
	for key in TerrainData.SHADE_DEFAULTS:
		terrain.set_meta(key, 0)

func _build_all(terrain: Node3D, carve: PackedFloat32Array) -> Dictionary:
	var meshes := {}
	var count := TerrainMesher.chunk_count(terrain)
	for cz in range(count):
		for cx in range(count):
			var mesh := TerrainMesher.build_chunk(terrain, carve, cx, cz)
			if mesh != null:
				meshes[TerrainMesher.chunk_name(cx, cz)] = mesh
	return meshes

func _initialize() -> void:
	var path := "res://scenes/savanna_128.tscn"
	var zero := false
	var time_only := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):
			path = arg.trim_prefix("--terrain=")
		elif arg == "--zero":
			zero = true
		elif arg == "--time":
			time_only = true
	var root := TestTerrain.load_scene(path)
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	var carve := RiverMesher.compute_carve(terrain)
	WaterholeMesher.add_carve(terrain, carve)

	if time_only:
		for label in ["defaults", "zero"]:
			if label == "zero":
				_set_zero(terrain)
			var best := INF
			for run in range(3):
				var t0 := Time.get_ticks_usec()
				_build_all(terrain, carve)
				best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
			# One chunk, as rebuilt by a brush stroke.
			var t1 := Time.get_ticks_usec()
			for run in range(5):
				TerrainMesher.build_chunk(terrain, carve, 1, 1)
			print("%s: all chunks %.1f ms (best of 3), one chunk %.1f ms" % [label, best, (Time.get_ticks_usec() - t1) / 5000.0])
		root.free()
		quit(0)
		return

	if zero:
		_set_zero(terrain)
	var rebuilt := _build_all(terrain, carve)
	var container: Node = terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null or container.get_child_count() == 0:
		# "All at runtime" scenes (New Terrain default) store no meshes.
		print("RESULT: SKIPPED (this scene stores no chunk meshes: Runtime Build is not \"Save everything\"; pass --terrain=<a scene saved with Save everything>)")
		root.free()
		quit(0)
		return
	var ok := true
	var compared := 0
	for child in container.get_children():
		var stored: ArrayMesh = (child as MeshInstance3D).mesh
		var fresh: ArrayMesh = rebuilt.get(child.name)
		if fresh == null or stored.get_surface_count() != fresh.get_surface_count():
			print("  %s: surface count differs" % child.name)
			ok = false
			continue
		for i in range(stored.get_surface_count()):
			var a := stored.surface_get_arrays(i)
			var b := fresh.surface_get_arrays(i)
			for kind in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV]:
				if a[kind] != b[kind]:
					print("  %s surface %d array %d DIFFERENT (%s vs %s values)" % [child.name, i, kind, a[kind].size() if a[kind] != null else -1, b[kind].size() if b[kind] != null else -1])
					ok = false
		compared += 1
	print("chunks compared: %d / rebuilt %d" % [compared, rebuilt.size()])
	print("RESULT: %s" % ("IDENTICAL" if ok and compared == rebuilt.size() else "DIFFERENT"))
	root.free()
	quit(0 if ok else 1)
