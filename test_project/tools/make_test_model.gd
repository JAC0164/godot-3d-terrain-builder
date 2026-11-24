extends SceneTree
## Writes res://assets/test_models/hut.glb: a small round hut (clay wall +
## straw roof, two materials), its origin in the middle of the wall on purpose
## (the detail layer stands it on its bottom). Example of "your own asset" for
## a biome layer's Model slot; check_custom_model.gd scatters it.
##   godot --headless --path . --script res://tools/make_test_model.gd
##   godot --headless --path . --import      (imports the new .glb)

const OUT := "res://assets/test_models/hut.glb"

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	return material

func _initialize() -> void:
	var root := Node3D.new()
	root.name = "Hut"
	var wall := MeshInstance3D.new()
	wall.name = "Wall"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.6
	cylinder.bottom_radius = 1.7
	cylinder.height = 1.8
	cylinder.radial_segments = 10
	cylinder.rings = 1
	cylinder.material = _material(Color(0.62, 0.38, 0.22))
	wall.mesh = cylinder
	root.add_child(wall)
	wall.owner = root
	var roof := MeshInstance3D.new()
	roof.name = "Roof"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 2.2
	cone.height = 1.6
	cone.radial_segments = 10
	cone.rings = 1
	cone.material = _material(Color(0.83, 0.70, 0.40))
	roof.mesh = cone
	roof.position = Vector3(0, 1.7, 0)
	root.add_child(roof)
	roof.owner = root
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT.get_base_dir()))
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var error := gltf.append_from_scene(root, state)
	if error == OK:
		error = gltf.write_to_filesystem(state, ProjectSettings.globalize_path(OUT))
	print("%s %s" % ["wrote" if error == OK else "FAILED", OUT])
	root.free()
	quit(0)
