extends SceneTree
## The open world's horizon with the game's sky (world/savanna_sky.tscn) and
## a few fog / far-distance pairs: is the end of the far blocks hidden, how
## far can the player see. Needs a window (not --headless):
##   godot --path . --position -3000,-3000 --resolution 1280x720 --script res://tools/horizon_look.gd
## Writes results/big_world/horizon_<variant>_<view>.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")

## name, far_distance, fog begin, fog end (fog end 0 = the game's fog as is).
const VARIANTS := [
	["game", 1000.0, 0.0, 0.0],
	["far600", 600.0, 80.0, 600.0],
	["far450", 450.0, 70.0, 450.0],
]

func _initialize() -> void:
	await process_frame
	var root := Node3D.new()
	get_root().add_child(root)
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	root.add_child(sky)
	var world := sky.find_children("*", "WorldEnvironment", true, false)[0] as WorldEnvironment
	var game_env: Environment = world.environment
	var terrain := _new_terrain(root)
	# Spots: the middle of the longest track, at eye height and from 25 m.
	var best: Array = []
	for road: Dictionary in terrain.get_meta(Meta.ROADS, []):
		if (road["points"] as Array).size() > best.size():
			best = road["points"]
	var at: Vector2 = best[best.size() / 2]
	var ahead: Vector2 = best[mini(best.size() / 2 + 20, best.size() - 1)]
	var direction := (ahead - at).normalized()
	var views := [["eye", 1.7, 0.0], ["high", 25.0, -6.0]]
	var camera := Camera3D.new()
	camera.fov = 75.0
	root.add_child(camera)
	camera.current = true
	camera.position = _at(terrain, at, 1.7)
	for variant: Array in VARIANTS:
		var env := game_env.duplicate() as Environment
		if float(variant[3]) > 0.0:
			env.fog_depth_begin = float(variant[2])
			env.fog_depth_end = float(variant[3])
		world.environment = env
		camera.far = float(variant[1]) + 100.0
		if terrain == null:
			terrain = _new_terrain(root)
		var runtime := TerrainRuntime.new()
		runtime.name = "Runtime"
		runtime.stream_ground = true
		runtime.stream_details = true
		runtime.ground_distance = 160.0
		runtime.far_distance = float(variant[1])
		terrain.add_child(runtime)
		for view: Array in views:
			camera.position = _at(terrain, at, float(view[1]))
			camera.look_at(camera.position + Vector3(direction.x, 0.0, direction.y) * 100.0 + Vector3.UP * float(view[2]))
			for i in 4000:
				await process_frame
				if i > 30 and runtime.is_finished and runtime.is_streaming_idle and runtime._ground_tasks.is_empty() and runtime._far_queue.is_empty():
					break
			for i in 20:
				await process_frame
			get_root().get_texture().get_image().save_png("res://results/big_world/horizon_%s_%s.png" % [variant[0], view[0]])
			print("saved horizon_%s_%s.png" % [variant[0], view[0]])
		# A fresh terrain for the next variant (nothing left from this one).
		terrain.free()
		terrain = null
		await process_frame
	quit()

static func _new_terrain(parent: Node3D) -> Node3D:
	var terrain := Node3D.new()
	parent.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(ADDON + "generation/presets/senegal_savanna_open_world_map.tres"), 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	return terrain

static func _at(terrain: Node3D, point: Vector2, above: float) -> Vector3:
	return Vector3(point.x, TerrainSampler.uncarved_height(terrain, point) + above, point.y)
