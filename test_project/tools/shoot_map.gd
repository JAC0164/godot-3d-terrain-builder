extends SceneTree
## Screenshots of a savanna map from several distances (real window, not
## headless), same light as bench/bench.gd, to judge the look:
##   godot --path . --rendering-method mobile --script res://tools/shoot_map.gd -- --scene=res://scenes/savanna_map_192.tscn --tag=before
## --lighting=biome uses the project's savanna sky (world/savanna_sky.tscn) instead of the
## bench light. Writes res://results/polish/<tag>_<view>.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

var _terrain: Node3D
var _heights: PackedFloat32Array
var _resolution := 0
var _world_size := 0.0

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_heights, PackedFloat32Array(), _resolution, _world_size, p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

## Largest instance of the detail layer whose node name contains `part`.
func _biggest(part: String) -> Vector3:
	var best := -1.0
	var found := Vector3.ZERO
	for node in _terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(part):
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		for i in range(0, buffer.size(), 16):
			var s := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
			# Prefer instances near the centre (inside the map, good light).
			var p := Vector3(buffer[i + 3], buffer[i + 7], buffer[i + 11])
			var score := s - p.length() * 0.01
			if score > best:
				best = score
				found = p
	return found

## A point on the edge of a plateau (big height step), near the centre.
func _plateau_edge() -> Vector2:
	var spacing := _world_size / float(_resolution - 1)
	var half := _world_size * 0.5
	var best := INF
	var found := Vector2.ZERO
	for z in range(4, _resolution - 4, 2):
		for x in range(4, _resolution - 4, 2):
			var h := _heights[z * _resolution + x]
			var h2 := _heights[z * _resolution + x + 3]
			if h2 - h > 1.6:
				var p := Vector2(x * spacing - half, z * spacing - half)
				if p.length() < best:
					best = p.length()
					found = p + Vector2(spacing * 1.5, 0)
	return found

func _initialize() -> void:
	var args := {"scene": "res://scenes/savanna_map_192.tscn", "tag": "before", "out": "res://results/polish", "only": "", "lighting": "bench"}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	var root := (load(args["scene"]) as PackedScene).instantiate()
	get_root().add_child(root)
	_terrain = root.get_node("LowpolyTerrain")
	TerrainStorage.unpack(_terrain)
	_heights = _terrain.get_meta(Meta.HEIGHTS)
	_resolution = _terrain.get_meta(Meta.RESOLUTION)
	_world_size = _terrain.get_meta(Meta.WORLD_SIZE)

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
	# --lighting=biome: the project's savanna sky and sun (world/savanna_sky.tscn).
	var savanna_sky: Node = load("res://world/savanna_sky.tscn").instantiate() if args["lighting"] == "biome" else null
	var use_biome := savanna_sky != null
	if use_biome:
		environment = (savanna_sky.get_node("WorldEnvironment") as WorldEnvironment).environment
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	root.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	if use_biome:
		var savanna_sun := savanna_sky.get_node("Sun") as DirectionalLight3D
		sun.transform = savanna_sun.transform
		sun.light_color = savanna_sun.light_color
		sun.light_energy = savanna_sun.light_energy
		savanna_sky.free()
	root.add_child(sun)
	var camera := Camera3D.new()
	camera.fov = 55.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true

	var baobab := _biggest("Baobabs")
	var acacia := _biggest("Acacias")
	var mound := _biggest("Termite")
	var edge := _plateau_edge()
	var hole: Dictionary = WaterholeStyle.migrate(WaterholeStyle.list(_terrain)[0])
	var hc: Vector2 = hole["center"]
	var hr: float = hole["radius"]
	var bb := Vector2(baobab.x, baobab.z)
	var ac := Vector2(acacia.x, acacia.z)
	var mo := Vector2(mound.x, mound.z)
	var roads: Array = _terrain.get_meta(Meta.ROADS, [])
	var road_points: Array = roads[0]["points"] if not roads.is_empty() else [Vector2.ZERO, Vector2(1, 0)]
	var rp: Vector2 = road_points[road_points.size() / 2]
	var rdir: Vector2 = (road_points[road_points.size() / 2 + 1] - rp).normalized()
	var views := {
		"track": [_at(rp - rdir * 10.0 + rdir.orthogonal() * 4.0, 3.0), _at(rp + rdir * 4.0, 0.0)],
		"overview": [Vector3(0, 95, 105), Vector3(0, 0, 5)],
		"mid": [_at(Vector2(-20, 40), 22.0), _at(Vector2(5, 5), 0.0)],
		"eye": [_at(Vector2(-6, 30), 1.7), _at(Vector2(10, -10), 2.0)],
		"baobab": [_at(bb + Vector2(-9, 11), 3.0), _at(bb, 4.0)],
		"acacia": [_at(ac + Vector2(-8, 9), 2.5), _at(ac, 2.5)],
		"mound": [_at(mo + Vector2(-3.5, 4.5), 1.8), _at(mo, 1.0)],
		"plateau": [_at(edge + Vector2(-14, 12), 4.0), _at(edge + Vector2(3, 0), 1.5)],
		"waterhole": [_at(hc + Vector2(-hr * 1.4, hr * 1.7), hr * 1.0), _at(hc, -0.5)],
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(args["out"]))
	for view_name in views:
		if args["only"] != "" and not String(args["only"]).split(",").has(view_name):
			continue
		var view: Array = views[view_name]
		camera.look_at_from_position(_terrain.to_global(view[0]), _terrain.to_global(view[1]))
		for i in range(8):
			await RenderingServer.frame_post_draw
		var path := "%s/%s_%s.png" % [args["out"], args["tag"], view_name]
		get_root().get_texture().get_image().save_png(path)
		print("wrote ", path)
	quit(0)
