extends SceneTree
## Close pictures of the roads of the savanna map, lit by the game sky, where
## the ground slopes most across the road (where the ground used to poke
## through), each also in wireframe to see the road mesh.
##   godot --path . --position -3000,-3000 --script res://tools/road_look.gd -- --tag=after
## Writes results/road_grid/<tag>_<view>.png and <tag>_<view>_wire.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const VIEWS := 3

func _initialize() -> void:
	get_root().size = Vector2i(960, 540)
	# Must be on before the meshes are made.
	RenderingServer.set_debug_generate_wireframes(true)
	var tag := "shot"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="):
			tag = arg.substr(6)
	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := TestTerrain.savanna(root)
	root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	TerrainBuilder.new().rebuild_all(terrain)
	await process_frame
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var ground := func(p: Vector2) -> float:
		return TerrainSampler.uncarved_height_in(heights, resolution, size, p)
	# Road points with the steepest ground across the road, 25 m apart.
	var spots: Array = []
	for road_variant in terrain.get_meta(Meta.ROADS, []):
		var road: Dictionary = FeatureStyle.migrate(road_variant, FeatureStyle.ROAD)
		var points: Array = road.get("points", [])
		for i in range(1, points.size() - 1):
			var p: Vector2 = points[i]
			var side: Vector2 = (points[i + 1] - points[i - 1]).normalized().orthogonal()
			var tilt := absf(ground.call(p + side * 1.5) - ground.call(p - side * 1.5)) / 3.0
			spots.append([tilt, p, side])
	spots.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var chosen: Array = []
	for spot in spots:
		var far := true
		for c in chosen:
			if (c[1] as Vector2).distance_to(spot[1]) < 25.0:
				far = false
		if far:
			chosen.append(spot)
		if chosen.size() == VIEWS:
			break
	var camera := Camera3D.new()
	camera.fov = 60.0
	root.add_child(camera)
	camera.current = true
	var out := "res://results/road_grid"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for v in chosen.size():
		var p: Vector2 = chosen[v][1]
		var side: Vector2 = chosen[v][2]
		var eye: Vector2 = p + side * 4.5 + side.orthogonal() * 3.0
		camera.look_at_from_position(Vector3(eye.x, ground.call(eye) + 2.2, eye.y), Vector3(p.x, ground.call(p), p.y))
		for wire in [false, true]:
			get_root().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if wire else Viewport.DEBUG_DRAW_DISABLED
			for f in 10:
				await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png("%s/%s_%d%s.png" % [out, tag, v, "_wire" if wire else ""])
		print("view %d: slope across the road %.0f %%" % [v, chosen[v][0] * 100.0])
	print("wrote %s/%s_*.png" % [out, tag])
	root.free()
	quit()
