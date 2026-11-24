extends SceneTree
## Pictures of the savanna map through several fog settings of the game sky
## (world/savanna_sky.tscn), from above, half-way up and at eye height, to
## tune a fog that keeps the haze on the ground without washing out the view
## from above.
##   godot --path . --position -3000,-3000 --script res://tools/fog_look.gd -- --tag=v1 [--only=variant]
##   --env=res://path.tres: start from this Environment instead of the sky's.
##   --horizon: with the game's MapHorizon around the map (world/map_horizon.gd).
## Writes results/fog_look/<tag>_<variant>_<view>.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

## Environment properties per variant (empty = the file as saved).
const VARIANTS := {
	"preset": {},
	# The fog the file had before 2026-11-23 (exponential, washed out from above).
	"exponential": {"fog_mode": 0},
	# Godot's height fog ADDS fog below fog_height: thicker at eye height
	# (tried, rejected).
	"height_a": {"fog_height": 8.0, "fog_height_density": 0.08},
	"depth": {"fog_mode": 1, "fog_depth_begin": 40.0, "fog_depth_end": 420.0, "fog_depth_curve": 1.6},
	"depth_b": {"fog_mode": 1, "fog_depth_begin": 20.0, "fog_depth_end": 350.0, "fog_depth_curve": 1.2},
	"depth_c": {"fog_mode": 1, "fog_depth_begin": 30.0, "fog_depth_end": 300.0, "fog_depth_curve": 1.0},
	"exp_low": {"fog_density": 0.0025},
	# depth_d = what the game file holds since 2026-11-23.
	"depth_d": {"fog_mode": 1, "fog_depth_begin": 60.0, "fog_depth_end": 320.0, "fog_depth_curve": 2.0},
	"depth_e": {"fog_mode": 1, "fog_depth_begin": 50.0, "fog_depth_end": 280.0, "fog_depth_curve": 2.2},
}

func _initialize() -> void:
	get_root().size = Vector2i(960, 540)
	var tag := "shot"
	var only := ""
	var horizon := OS.get_cmdline_user_args().has("--horizon")
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
	TerrainBuilder.new().rebuild_all(terrain)
	if horizon:
		var far_land: Node3D = load("res://world/map_horizon.gd").new()
		terrain.add_child(far_land)
		far_land.rebuild()
	await process_frame
	var world := sky.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment
	var saved: Environment = world.environment
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--env="):
			saved = load(arg.substr(6))
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var ground := func(p: Vector2) -> float:
		return TerrainSampler.uncarved_height_in(heights, resolution, size, p)
	var camera := Camera3D.new()
	camera.fov = 75.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true
	# [from, height above ground, look at, height there]
	var views := {
		"above": [Vector2(-size * 0.35, size * 0.35), 45.0, Vector2.ZERO, 0.0],
		"mid": [Vector2(-size * 0.2, size * 0.1), 15.0, Vector2(size * 0.15, -size * 0.1), 0.0],
		"eye": [Vector2(-6.0, 4.0), 1.7, Vector2(30.0, -20.0), 1.2],
	}
	var out := "res://results/fog_look"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	for variant in VARIANTS:
		if only != "" and variant != only:
			continue
		# "preset" renders the Environment exactly as loaded, as the game does.
		var environment: Environment = saved if VARIANTS[variant].is_empty() else saved.duplicate()
		for key in VARIANTS[variant]:
			environment.set(key, VARIANTS[variant][key])
		world.environment = environment
		for view in views:
			var v: Array = views[view]
			var from: Vector2 = v[0]
			var target: Vector2 = v[2]
			camera.look_at_from_position(Vector3(from.x, ground.call(from) + float(v[1]), from.y), Vector3(target.x, ground.call(target) + float(v[3]), target.y))
			for f in 12:
				await RenderingServer.frame_post_draw
			get_root().get_texture().get_image().save_png("%s/%s_%s_%s.png" % [out, tag, variant, view])
	print("wrote %s/%s_*.png" % [out, tag])
	root.free()
	quit()
