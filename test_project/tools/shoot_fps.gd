extends SceneTree
## First-person screenshots of a playable scene, with its own sky and sun, to
## judge how the ground looks at eye height (real window, not headless; put
## it off-screen with --position -3000,-3000):
##   godot --path . --position -3000,-3000 --script res://tools/shoot_fps.gd -- --scene=res://scenes/savanna_128.tscn --tag=now
## Writes res://results/fps_look/<tag>_<view>.png.
## Look experiments (in memory, the scene file is not changed):
##   --smooth=0|1       Smooth Ground off / on
##   --bumps=0.3        Ground Bumps of this height (m), as Inspector > Look sets them
##   --variation=0.0    biome color variation, --blend_noise=0.0 style blend noise
##   --views=eye_2,feet only these views
##   --ground_material=res://world/looks/ground_detail.tres  Look > Ground Material
## Atmosphere experiments (the scene's WorldEnvironment / DirectionalLight3D):
##   --env=res://world/savanna_environment.tres  use this Environment
##   --fog=0.004 --saturation=1.0 --contrast=1.05 --sun=26 (sun height, degrees)

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const GroundBumps = preload(ADDON + "core/ground_bumps.gd")

func _initialize() -> void:
	var args := {"scene": "res://scenes/savanna_128.tscn", "tag": "now", "out": "res://results/fps_look", "views": ""}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	get_root().size = Vector2i(1280, 720)
	var root := (load(args["scene"]) as PackedScene).instantiate()
	# The player would capture the mouse and drive its own camera.
	for node in root.find_children("*", "CharacterBody3D", true, false):
		node.free()
	var terrain: Node3D = root.get_node("LowpolyTerrain")
	TerrainStorage.unpack(terrain)
	_experiment(terrain, args)
	_atmosphere(root, args)
	get_root().add_child(root)
	var runtime := terrain.get_node_or_null(String(Meta.RUNTIME_NODE_NAME))
	if runtime != null and not runtime.is_finished:
		await runtime.finished
	for i in 10:
		await process_frame

	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE)
	var cells := resolution - 1
	var spacing := world_size / float(cells)
	var ground := func(p: Vector2) -> float:
		return WaterholeMesher.surface_height(heights, PackedFloat32Array(), resolution, world_size, p)
	# Centre of the ground cells: the views stand around it.
	var centre := Vector2.ZERO
	var n := 0
	for i in active.size():
		if active[i] != 0:
			centre += (Vector2(i % cells, i / cells) + Vector2(0.5, 0.5)) * spacing - Vector2.ONE * world_size * 0.5
			n += 1
	centre /= maxf(float(n), 1.0)
	print("ground cells %d, cell %.2f m, centre %s" % [n, spacing, centre])

	var camera := Camera3D.new()
	camera.fov = 75.0
	camera.far = 1000.0
	root.add_child(camera)
	camera.current = true
	var eye := 1.7
	var views := {}
	for k in 4:
		var dir := Vector2.RIGHT.rotated(TAU * float(k) / 4.0 + 0.4)
		var from := centre - dir * 6.0
		views["eye_%d" % k] = [from, eye, from + dir * 20.0, eye - 0.6]
	views["feet"] = [centre, eye, centre + Vector2(2.5, 0.5), -0.2]
	views["low_far"] = [centre + Vector2(-15, 10), eye, centre + Vector2(40, -30), eye - 1.5]
	# From above, as a top-down or strategy camera sees it.
	views["high"] = [centre + Vector2(-45, 45), 60.0, centre, 0.0]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(args["out"]))
	for view_name in views:
		if args["views"] != "" and not String(args["views"]).split(",").has(view_name):
			continue
		var v: Array = views[view_name]
		var from: Vector2 = v[0]
		var to: Vector2 = v[2]
		var p0 := Vector3(from.x, ground.call(from) + float(v[1]), from.y)
		var p1 := Vector3(to.x, ground.call(to) + float(v[3]), to.y)
		camera.look_at_from_position(terrain.to_global(p0), terrain.to_global(p1))
		for i in 8:
			await RenderingServer.frame_post_draw
		var path := "%s/%s_%s.png" % [args["out"], args["tag"], view_name]
		get_root().get_texture().get_image().save_png(path)
		print("wrote ", path)
	quit(0)

func _atmosphere(root: Node, args: Dictionary) -> void:
	var world := root.find_children("*", "WorldEnvironment", true, false)
	if not world.is_empty():
		var we: WorldEnvironment = world[0]
		if args.has("env"):
			we.environment = load(args["env"])
		var env := we.environment.duplicate(true) as Environment
		if args.has("fog"):
			env.fog_density = float(args["fog"])
		if args.has("saturation"):
			env.adjustment_saturation = float(args["saturation"])
		if args.has("contrast"):
			env.adjustment_contrast = float(args["contrast"])
		we.environment = env
	if args.has("sun"):
		for node in root.find_children("*", "DirectionalLight3D", true, false):
			var sun := node as DirectionalLight3D
			# Same compass direction, new height above the horizon.
			var dir := -sun.transform.basis.z
			print("sun was %.1f deg high" % rad_to_deg(asin(-dir.y)))
			var flat := Vector2(dir.x, dir.z).normalized()
			var e := deg_to_rad(float(args["sun"]))
			var d := Vector3(flat.x * cos(e), -sin(e), flat.y * cos(e))
			sun.transform = Transform3D(Basis.looking_at(d, Vector3.UP), sun.position)

func _experiment(terrain: Node3D, args: Dictionary) -> void:
	if args.has("smooth"):
		terrain.set_meta(Meta.SHADE_SMOOTH, args["smooth"] == "1")
	if args.has("bumps"):
		# The plugin's own Ground Bumps (Inspector > Look).
		GroundBumps.set_amount(terrain, float(args["bumps"]))
	if args.has("ground_material"):
		terrain.set_meta(Meta.GROUND_MATERIAL, load(args["ground_material"]))
	if args.has("variation") or args.has("blend_noise"):
		var biome: Resource = (terrain.get_meta(Meta.BIOME) as Resource).duplicate()
		if args.has("variation"):
			biome.variation = float(args["variation"])
		if args.has("blend_noise"):
			biome.blend_noise = float(args["blend_noise"])
		terrain.set_meta(Meta.BIOME, biome)
