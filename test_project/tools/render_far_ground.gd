extends SceneTree
## Renders the streamed ground with its far blocks (stream_ground +
## far_distance) from a few viewpoints, to look at the seam between the
## detailed ring and the far blocks. Needs a window (not --headless):
##   godot --path . --position -3000,-3000 --resolution 1280x720 --script res://tools/render_far_ground.gd
## Writes results/big_world/far_*.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
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
	var recipe: MapRecipe = (load(ADDON + "generation/presets/senegal_savanna_map.tres") as MapRecipe).duplicate()
	recipe.size = 512
	recipe.cell_size = 1.5
	MapGenerator.generate(terrain, recipe, 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	var camera := Camera3D.new()
	camera.far = 4000.0
	root.add_child(camera)
	camera.current = true
	camera.position = Vector3(0, 3, 0)
	var runtime := TerrainRuntime.new()
	runtime.build_on_ready = false
	runtime.stream_ground = true
	runtime.ground_distance = 150.0
	runtime.far_distance = 1000.0
	terrain.add_child(runtime)
	runtime.build()
	while not runtime.is_finished:
		await process_frame
	var views: Array = [
		["eye", Vector3(0, 4, 0), Vector3(200, 0, 120)],
		["hill", Vector3(0, 40, 0), Vector3(260, 0, 160)],
		["above", Vector3(0, 420, 1), Vector3(0, 0, 0)],
	]
	for view: Array in views:
		var focus_node := Node3D.new()
		camera.position = view[1]
		camera.look_at(view[2])
		for i in 20:
			await process_frame
		var image := get_root().get_texture().get_image()
		image.save_png("res://results/big_world/far_%s.png" % view[0])
		print("saved far_%s.png" % view[0])
		focus_node.free()
	quit()
