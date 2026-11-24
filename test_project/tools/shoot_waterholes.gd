extends SceneTree
## Close-up screenshots of the dried waterholes of a savanna scene (real
## window, not headless), same light as bench/bench.gd:
##   godot --path . --rendering-method mobile --script res://tools/shoot_waterholes.gd -- --scene=res://scenes/savanna_256.tscn --hole=0
## Writes res://results/waterholes/waterhole_<hole>_<view>.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

func _initialize() -> void:
	var args := {"scene": "res://scenes/savanna_256.tscn", "hole": "0", "out": "res://results/waterholes"}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	var root := (load(args["scene"]) as PackedScene).instantiate()
	get_root().add_child(root)
	var terrain: Node3D = root.get_node("LowpolyTerrain")

	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.32, 0.55, 0.85)
	sky_material.sky_horizon_color = Color(0.72, 0.82, 0.92)
	sky_material.ground_horizon_color = Color(0.72, 0.82, 0.92)
	sky_material.ground_bottom_color = Color(0.25, 0.45, 0.6)
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	root.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	root.add_child(sun)
	var camera := Camera3D.new()
	camera.fov = 55.0
	root.add_child(camera)
	camera.current = true

	var holes := WaterholeStyle.list(terrain)
	var index := clampi(int(args["hole"]), 0, holes.size() - 1)
	var hole := WaterholeStyle.migrate(holes[index])
	var center: Vector2 = hole["center"]
	var radius: float = hole["radius"]
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var ground := func(p: Vector2) -> float:
		return WaterholeMesher.surface_height(heights, PackedFloat32Array(), resolution, world_size, p)
	var floor_y: float = ground.call(center) - float(hole["depth"])
	var target := Vector3(center.x, floor_y, center.y)
	var rim := center + Vector2(-0.8, 1.0).normalized() * radius * 1.35
	var views := {
		"oblique": [target + Vector3(-radius * 1.3, radius * 1.1, radius * 1.6), target],
		"ground": [Vector3(rim.x, float(ground.call(rim)) + 1.7, rim.y), target + Vector3(radius * 0.3, 0.0, -radius * 0.4)],
		"top": [target + Vector3(0.0, radius * 2.4, radius * 0.25), target],
		"close": [target + Vector3(-1.2, 1.6, 2.2), target + Vector3(0.6, 0.0, -0.6)],
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(args["out"]))
	for view_name in views:
		var view: Array = views[view_name]
		camera.look_at_from_position(terrain.to_global(view[0]), terrain.to_global(view[1]))
		for i in range(6):
			await RenderingServer.frame_post_draw
		var path := "%s/waterhole_%d_%s.png" % [args["out"], index, view_name]
		get_root().get_texture().get_image().save_png(path)
		print("wrote ", path)
	quit(0)
