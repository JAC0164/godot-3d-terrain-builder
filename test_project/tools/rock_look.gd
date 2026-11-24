extends SceneTree
## Pictures of the same savanna rocks with several Rocks layer colour settings,
## lit by the sun and against it, to tune how dark they look.
##   godot --path . --position -3000,-3000 --script res://tools/rock_look.gd -- --tag=before
## Writes results/rock_look/<tag>_<variant>_<view>.png. Variants are listed in
## VARIANTS (empty = the preset as saved).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

const VARIANTS := {
	"preset": {},
	"bright15": {"brightness": 1.5},
	"lighten30": {"lighten": 0.3},
	"mix": {"brightness": 1.35, "desaturate": 0.25, "lighten": 0.15},
	"grey15": {"brightness": 1.5, "desaturate": 0.6, "lighten": 0.1},
	"grey13": {"brightness": 1.3, "desaturate": 0.55, "lighten": 0.12},
	# "ambient" = the game sky's ambient light energy (savanna_environment.tres 0.85).
	"grey13_amb11": {"brightness": 1.3, "desaturate": 0.55, "lighten": 0.12, "ambient": 1.1},
	# "ambient_color" = warmer ambient (light bounced by the sand), sky share lower.
	"grey15_warm": {"brightness": 1.5, "desaturate": 0.6, "lighten": 0.1, "ambient": 1.0, "ambient_color": Color(0.86, 0.78, 0.68), "sky_share": 0.35},
	"preset_warm": {"ambient": 1.0, "ambient_color": Color(0.86, 0.78, 0.68), "sky_share": 0.35},
}

func _initialize() -> void:
	get_root().size = Vector2i(960, 540)
	var tag := "shot"
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="):
			tag = arg.substr(6)
		elif arg.begins_with("--only="):
			only = arg.substr(7)
	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := TestTerrain.savanna(root)
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	root.add_child(sky)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)
	await process_frame
	var sun: DirectionalLight3D = sky.find_children("*", "DirectionalLight3D", true, false)[0]
	var travel := -sun.global_basis.z
	print("sun travels %s" % travel)
	var flat := Vector2(travel.x, travel.z).normalized()
	var spots := _big_rocks(terrain, builder, 3)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var ground := func(p: Vector2) -> float:
		return TerrainSampler.uncarved_height_in(heights, resolution, size, p)
	var camera := Camera3D.new()
	camera.fov = 60.0
	root.add_child(camera)
	camera.current = true
	var layer: Resource = null
	for l in DetailScatter.biome_of(terrain).detail_layers:
		if l != null and l.name == "Rocks":
			layer = l
	var saved := {"brightness": layer.brightness, "desaturate": layer.desaturate, "lighten": layer.lighten}
	var environment: Environment = (sky.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment).environment.duplicate()
	(sky.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment).environment = environment
	var saved_ambient := environment.ambient_light_energy
	var saved_color := environment.ambient_light_color
	var saved_share := environment.ambient_light_sky_contribution
	var out := "res://results/rock_look"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for variant in VARIANTS:
		if only != "" and variant != only:
			continue
		for key in saved:
			layer.set(key, saved[key])
		environment.ambient_light_energy = saved_ambient
		environment.ambient_light_color = saved_color
		environment.ambient_light_sky_contribution = saved_share
		for key in VARIANTS[variant]:
			if key == "ambient":
				environment.ambient_light_energy = VARIANTS[variant][key]
			elif key == "ambient_color":
				environment.ambient_light_color = VARIANTS[variant][key]
			elif key == "sky_share":
				environment.ambient_light_sky_contribution = VARIANTS[variant][key]
			else:
				layer.set(key, VARIANTS[variant][key])
		builder.rebuild_all_details(terrain)
		for i in spots.size():
			var spot: Vector2 = spots[i]
			# Sun behind the camera (lit side), then against it (shaded side).
			var views := {"lit": spot - flat.rotated(0.5) * 3.2, "shade": spot + flat.rotated(0.5) * 3.2}
			for view in views:
				var from: Vector2 = views[view]
				camera.look_at_from_position(Vector3(from.x, ground.call(from) + 1.3, from.y), Vector3(spot.x, ground.call(spot) + 0.25, spot.y))
				for f in 10:
					await RenderingServer.frame_post_draw
				get_root().get_texture().get_image().save_png("%s/%s_%s_%d_%s.png" % [out, tag, variant, i, view])
	print("wrote %s/%s_*.png (%d rocks)" % [out, tag, spots.size()])
	root.free()
	quit()

## Centres of the `count` biggest rocks away from the map border and apart.
func _big_rocks(terrain: Node3D, builder: TerrainBuilder, count: int) -> Array[Vector2]:
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var found: Array = []
	var n := TerrainMesher.chunk_count(terrain)
	for cz in n:
		for cx in n:
			for d in DetailScatter.build(terrain, builder.get_river_carve(terrain), cx, cz, builder.chunk_shading(terrain, cx, cz)):
				if String(d[3].name) != "Rocks":
					continue
				var buffer: PackedFloat32Array = d[2]
				for k in range(0, buffer.size(), 16):
					var p := Vector2(buffer[k + 3], buffer[k + 11])
					if absf(p.x) < size * 0.35 and absf(p.y) < size * 0.35:
						found.append([Vector3(buffer[k], buffer[k + 4], buffer[k + 8]).length(), p])
	found.sort_custom(func(a, b): return a[0] > b[0])
	var spots: Array[Vector2] = []
	for f in found:
		if spots.size() < count and spots.all(func(s: Vector2) -> bool: return s.distance_to(f[1]) > 20.0):
			spots.append(f[1])
	return spots
