extends SceneTree
## Renders every built-in detail mesh side by side (real window, not headless):
##   godot --path . --rendering-method mobile --script res://tools/preview_props.gd -- --out=res://results/biomes/props.png

const ADDON := "res://addons/lowpoly_terrain_editor/"
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")

## [index, scale, tint]
const PROPS := [
	[DetailMeshes.GRASS_TUFT, 1.5, Color(0.5, 0.72, 0.3)],
	[DetailMeshes.DRY_GRASS_TUFT, 1.5, Color(0.85, 0.72, 0.42)],
	[DetailMeshes.ROCK, 1.0, Color(0.6, 0.55, 0.5)],
	[DetailMeshes.PEBBLES, 1.5, Color(0.62, 0.36, 0.24)],
	[DetailMeshes.SHRUB, 1.2, Color.WHITE],
	[DetailMeshes.TERMITE_MOUND, 2.2, Color(0.74, 0.42, 0.26)],
	[DetailMeshes.ZEBU_SKULL, 1.0, Color.WHITE],
	[DetailMeshes.DEAD_TREE, 3.0, Color.WHITE],
	[DetailMeshes.ACACIA, 4.0, Color.WHITE],
	[DetailMeshes.BAOBAB, 6.0, Color.WHITE],
]

func _initialize() -> void:
	var out := "res://results/biomes/props.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	var root := Node3D.new()
	get_root().add_child(root)

	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.74, 0.86)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.75, 0.8)
	env.environment.ambient_light_energy = 0.6
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_color = Color(1.0, 0.95, 0.85)
	sun.shadow_enabled = true
	root.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 30)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.78, 0.66, 0.4)
	ground.material_override = ground_material
	root.add_child(ground)

	var x := -14.0
	for prop in PROPS:
		var scale: float = prop[1]
		var node := MultiMeshInstance3D.new()
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = DetailMeshes.builtin(prop[0])
		multimesh.instance_count = 1
		multimesh.set_instance_transform(0, Transform3D(Basis().scaled(Vector3.ONE * scale), Vector3(x, 0, 0)))
		multimesh.set_instance_color(0, prop[2])
		node.multimesh = multimesh
		node.material_override = MaterialFactory.detail_material()
		root.add_child(node)
		x += maxf(scale * 0.9, 1.6) + 1.2
	var camera := Camera3D.new()
	camera.fov = 40
	root.add_child(camera)
	camera.look_at_from_position(Vector3(4.5, 6.0, 23.0), Vector3(4.5, 1.8, 0.0))

	for i in range(10):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out.get_base_dir()))
	image.save_png(out)
	print("wrote ", out)
	quit(0)
