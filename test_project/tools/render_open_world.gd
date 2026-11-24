extends SceneTree
## Renders the open-world preset (seed 7) in 3D, streamed like in game, from
## a few viewpoints: where a river crosses the border hills, along a river,
## and on a track at a waterhole. Needs a window (not --headless):
##   godot --path . --position -3000,-3000 --resolution 1280x720 --script res://tools/render_open_world.gd
## Writes results/big_world/open_world_*.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")

func _initialize() -> void:
	await process_frame
	var root := Node3D.new()
	get_root().add_child(root)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_SKY
	environment.environment.sky = Sky.new()
	environment.environment.sky.sky_material = ProceduralSkyMaterial.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	root.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.shadow_enabled = true
	root.add_child(sun)
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(ADDON + "generation/presets/senegal_savanna_open_world_map.tres"), 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)

	# Viewpoints from the generated features.
	var river: Array = (terrain.get_meta(Meta.RIVERS) as Array)[0]["points"]
	var exit_point: Vector2 = river[0]
	var inside: Vector2 = river[mini(60, river.size() - 1)]
	var middle: Vector2 = river[river.size() / 2]
	var after_middle: Vector2 = river[river.size() / 2 + 15]
	var hole: Vector2 = (terrain.get_meta(Meta.WATERHOLES) as Array)[0]["center"]
	var views: Array = [
		["valley", inside + (inside - exit_point).normalized() * 30.0, 18.0, exit_point],
		["river", middle - (after_middle - middle).normalized() * 25.0 + Vector2(12, 0), 9.0, after_middle],
		["waterhole", hole + Vector2(30, 24), 6.0, hole],
	]

	var camera := Camera3D.new()
	camera.far = 4000.0
	root.add_child(camera)
	camera.current = true
	var first: Array = views[0]
	camera.position = _at(terrain, first[1], first[2])
	var runtime := TerrainRuntime.new()
	runtime.build_on_ready = false
	runtime.stream_ground = true
	runtime.ground_distance = 200.0
	runtime.far_distance = 1200.0
	terrain.add_child(runtime)
	runtime.build()
	while not runtime.is_finished:
		await process_frame
	for view: Array in views:
		camera.position = _at(terrain, view[1], view[2])
		var target: Vector2 = view[3]
		camera.look_at(_at(terrain, target, 0.0))
		# Until the streaming around the camera is done (ground, details,
		# far blocks).
		for i in 4000:
			await process_frame
			if i > 30 and runtime.is_streaming_idle and runtime._ground_tasks.is_empty() and runtime._far_queue.is_empty():
				break
		for i in 30:
			await process_frame
		var image := get_root().get_texture().get_image()
		image.save_png("res://results/big_world/open_world_%s.png" % view[0])
		print("saved open_world_%s.png" % view[0])
	quit()

## A point `above` m over the ground at local x / z.
static func _at(terrain: Node3D, point: Vector2, above: float) -> Vector3:
	return Vector3(point.x, TerrainSampler.uncarved_height(terrain, point) + above, point.y)
