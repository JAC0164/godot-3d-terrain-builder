extends SceneTree
## A/B control: rebuilds a terrain scene in the OLD surface layout (one surface
## + one duplicated StandardMaterial3D per colour) from the new merged layout,
## so both layouts can be benchmarked in the same machine state.
##
##   godot --headless --path . --script res://tools/make_split_variant.gd -- --terrain=res://scenes/savanna_128.tscn

const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var source := "res://scenes/savanna_128.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--terrain="):
			source = arg.trim_prefix("--terrain=")

	var root := TestTerrain.load_scene(source)
	var surfaces := 0
	for chunk in root.get_node("LowpolyTerrain/_GeneratedTerrainChunks").get_children():
		var merged: ArrayMesh = chunk.mesh
		if merged == null or merged.get_surface_count() == 0:
			continue
		var arrays := merged.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var groups := {}
		for i in range(vertices.size()):
			var key := colors[i].to_html()
			if not groups.has(key):
				groups[key] = {"color": colors[i], "v": PackedVector3Array(), "n": PackedVector3Array()}
			groups[key]["v"].append(vertices[i])
			groups[key]["n"].append(normals[i])
		var split := ArrayMesh.new()
		for key in groups:
			var surface := []
			surface.resize(Mesh.ARRAY_MAX)
			surface[Mesh.ARRAY_VERTEX] = groups[key]["v"]
			surface[Mesh.ARRAY_NORMAL] = groups[key]["n"]
			split.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface)
			var material := StandardMaterial3D.new()
			material.albedo_color = groups[key]["color"]
			material.roughness = 1.0
			split.surface_set_material(split.get_surface_count() - 1, material)
			surfaces += 1
		# Keep any textured surfaces as they are.
		for i in range(1, merged.get_surface_count()):
			split.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged.surface_get_arrays(i))
			split.surface_set_material(split.get_surface_count() - 1, merged.surface_get_material(i).duplicate())
			surfaces += 1
		chunk.mesh = split

	var packed := PackedScene.new()
	packed.pack(root)
	var target := source.get_basename() + "_split.tscn"
	ResourceSaver.save(packed, target)
	print("Saved %s with %d terrain surfaces" % [target, surfaces])
	root.free()
	quit()
