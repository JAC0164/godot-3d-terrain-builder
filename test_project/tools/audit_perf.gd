extends SceneTree
## Performance audit of a whole game-like level (real window, Mobile renderer):
## a generated map built by the runtime node exactly as when a game starts
## (All at runtime, progressive, collision on), lit by world/savanna_sky.tscn
## (sun shadows), seen from a player's eyes. Measures:
##   - loading: map generation, time to walkable ground / everything built,
##     worst frame and frames over 33 ms while it builds;
##   - content: chunks, triangles, detail instances per layer, collision;
##   - rendering per view: GPU / CPU ms, draw calls, triangles, objects;
## and writes a screenshot per view (results/audit/<tag>_<view>.png) for the
## look review, plus results/audit/<tag>.json.
##   godot --path . --position -3000,-3000 --script res://tools/audit_perf.gd -- --map=savanna --tag=savanna
## Options: --map=savanna|island  --size=192 (cells per side)  --seed=7
##   --shadows=0  --grain=1 (world/looks/ground_detail.tres as Ground Material)
##   --mobile_water=1  --river=0 (no test river)  --draw_distance=70
##   --scale=0.5 (3D render scale, like a phone's lower resolution)
##   --distance_scale=0.6 (every detail layer's draw distance x 0.6)
##   --shadow_size=2048 (sun shadow map, as on phones)
##   --phone=1 (Godot's phone shadow defaults: 2048 map, hard edges)
##   --shadow_splits=1|2|4  --shadow_distance=50  --ground_shadows=0 (Game > Ground
##   Casts Shadows off: the ground casts none; trees still do)

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RECIPES := {
	"savanna": ADDON + "generation/presets/senegal_savanna_map.tres",
	"island": ADDON + "generation/presets/temperate_island_map.tres",
}

var _args := {"map": "savanna", "tag": "", "seed": "7", "shadows": "1", "grain": "0", "mobile_water": "0", "river": "1", "scale": "1"}
var _terrain: Node3D
var _report := {}

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(), int(_terrain.get_meta(Meta.RESOLUTION)), float(_terrain.get_meta(Meta.WORLD_SIZE)), p)

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else "1"
	if _args["tag"] == "":
		_args["tag"] = _args["map"]
	get_root().size = Vector2i(1280, 720)
	get_root().scaling_3d_scale = float(_args["scale"])
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)

	var root := Node3D.new()
	root.name = "Level"
	var recipe: Resource = (load(RECIPES[_args["map"]]) as Resource).duplicate()
	if _args.has("size"):
		recipe.size = int(_args["size"])
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	var t0 := Time.get_ticks_usec()
	MapGenerator.generate(_terrain, recipe, int(_args["seed"]))
	_report["map_generate_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	var cells: int = int(_terrain.get_meta(Meta.RESOLUTION)) - 1
	var size: float = float(_terrain.get_meta(Meta.WORLD_SIZE))
	if _args["river"] == "1":
		# One river across the map (the generator draws none).
		var points: Array[Vector2] = []
		for i in 9:
			var t := float(i) / 8.0
			points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
		FeatureStyle.commit(_terrain, FeatureStyle.RIVER, points)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_terrain.set_meta(Meta.RIVER_MOBILE_WATER, _args["mobile_water"] == "1")
	# Game > Ground Casts Shadows (roads, rivers and waterholes never cast).
	_terrain.set_meta(Meta.GROUND_SHADOWS, _args.get("ground_shadows", "1") != "0")
	if _args.has("draw_distance"):
		_terrain.set_meta(Meta.DETAIL_DRAW_DISTANCE, float(_args["draw_distance"]))
	if _args.has("distance_scale"):
		# Every layer's own draw distance x this (biome copy, file unchanged).
		var biome: Resource = (_terrain.get_meta(Meta.BIOME) as Resource).duplicate(true)
		for layer in biome.detail_layers:
			if layer != null and layer.draw_distance > 0.0:
				layer.draw_distance *= float(_args["distance_scale"])
		_terrain.set_meta(Meta.BIOME, biome)
	if _args["grain"] == "1":
		var grained: Resource = (_terrain.get_meta(Meta.BIOME) as Resource).duplicate()
		grained.set("ground_material", load("res://world/looks/ground_detail.tres"))
		_terrain.set_meta(Meta.BIOME, grained)
	var runtime := TerrainRuntime.new()
	# Every detail at load (as the earlier measures; on by default since 2026-11-24).
	runtime.stream_details = false
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	_terrain.add_child(runtime)
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	root.add_child(sky)
	for sun in sky.find_children("*", "DirectionalLight3D", true, false):
		(sun as DirectionalLight3D).shadow_enabled = _args["shadows"] == "1"
		if _args.has("shadow_splits"):
			(sun as DirectionalLight3D).directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL if _args["shadow_splits"] == "1" else (DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if _args["shadow_splits"] == "2" else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
		if _args.has("shadow_distance"):
			(sun as DirectionalLight3D).directional_shadow_max_distance = float(_args["shadow_distance"])
	if _args.has("shadow_size"):
		# Phones use rendering/lights_and_shadows/directional_shadow/size.mobile
		# (2048 by default) instead of the desktop 4096.
		RenderingServer.directional_shadow_atlas_set_size(int(_args["shadow_size"]), true)
	if _args.has("phone"):
		# Godot's phone defaults (*.mobile project settings): 2048 shadow map,
		# hard shadow edges (no soft filter taps in every pixel).
		RenderingServer.directional_shadow_atlas_set_size(2048, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
	var camera := Camera3D.new()
	camera.fov = 75.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true
	var centre := Vector2.ZERO
	camera.look_at_from_position(Vector3(0, 30, 30), Vector3.ZERO)

	# Loading, frame by frame, as a game sees it.
	var runtime_stats := {}
	runtime.finished.connect(func(stats: Dictionary) -> void: runtime_stats.merge(stats))
	var load_start := Time.get_ticks_usec()
	get_root().add_child(root)
	var worst := 0.0
	var slow := 0
	var frames := 0
	var ground_ms := -1.0
	var last := Time.get_ticks_usec()
	while not runtime.is_finished:
		await process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		frames += 1
		worst = maxf(worst, frame_ms)
		if frame_ms > 33.3:
			slow += 1
		if ground_ms < 0.0 and runtime.is_ground_ready:
			ground_ms = (now - load_start) / 1000.0
	_report["load"] = {"ground_ready_ms": ground_ms, "finished_ms": (Time.get_ticks_usec() - load_start) / 1000.0,
		"frames": frames, "worst_frame_ms": worst, "frames_over_33ms": slow,
		"worst_step_ms": runtime_stats.get("worst_step_ms", -1), "worst_step": runtime_stats.get("worst_step", -1), "steps": runtime_stats.get("steps", -1)}
	_report["map"] = {"cells": cells, "world_size_m": size}
	_report["content"] = _content()

	# Views at a player's eyes (1.7 m) and one from above.
	var eye := 1.7
	var views := {}
	for k in 4:
		var dir := Vector2.RIGHT.rotated(TAU * float(k) / 4.0 + 0.4)
		var from := centre - dir * 6.0
		views["eye_%d" % k] = [from, eye, from + dir * 30.0, eye - 0.8]
	views["overview"] = [Vector2(-size * 0.35, size * 0.35), 45.0, Vector2.ZERO, 0.0]
	var holes := WaterholeStyle.shapes(_terrain)
	if not holes.is_empty():
		var h: Vector2 = holes[0].bounds.get_center()
		views["waterhole"] = [h + Vector2(-14, 9), eye, h, 0.0]
	var rivers: Array = _terrain.get_meta(Meta.RIVERS, [])
	if not rivers.is_empty():
		var p: Vector2 = (rivers[0]["points"] as Array)[4]
		views["river"] = [p + Vector2(-6, -14), eye, p + Vector2(8, 10), 0.0]
	_report["views"] = {}
	for view_name in views:
		_report["views"][view_name] = await _measure(camera, view_name, views[view_name])
	# Worst case: an acacia forest painted at full density around the player.
	var spot := centre + Vector2(10, -10)
	for k in 12:
		Brush.apply_vegetation(_terrain, ToolMode.Mode.VEGETATION, spot + Vector2.RIGHT.rotated(k * 0.52) * float(k % 3) * 6.0, 8.0, 1.0)
		Brush.apply_vegetation(_terrain, ToolMode.Mode.VEGETATION, spot + Vector2.RIGHT.rotated(k * 0.52) * float(k % 3) * 6.0, 8.0, 1.0, "Acacias")
	var rebuild_start := Time.get_ticks_usec()
	TerrainBuilder.new().rebuild_all_details(_terrain)
	_report["forest_details_rebuild_ms"] = (Time.get_ticks_usec() - rebuild_start) / 1000.0
	_report["content_forest"] = _content()
	_report["views"]["forest"] = await _measure(camera, "forest", [spot + Vector2(-16, 12), eye, spot, eye - 0.5])
	# The same forest from above (crowns crossing or not).
	_report["views"]["forest_top"] = await _measure(camera, "forest_top", [spot + Vector2(-0.5, 9), 28.0, spot, 0.0])

	_print()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://results/audit"))
	var file := FileAccess.open("res://results/audit/%s.json" % _args["tag"], FileAccess.WRITE)
	file.store_string(JSON.stringify({"args": _args, "report": _report}, "  "))
	file.close()
	quit(0)

func _measure(camera: Camera3D, view_name: String, v: Array) -> Dictionary:
	var from: Vector2 = v[0]
	var to: Vector2 = v[2]
	camera.look_at_from_position(Vector3(from.x, _ground(from) + float(v[1]), from.y), Vector3(to.x, _ground(to) + float(v[3]), to.y))
	for i in 30:
		await process_frame
	var vp := get_root().get_viewport_rid()
	var gpu := 0.0
	var cpu := 0.0
	var frame := 0.0
	var n := 90
	var last := Time.get_ticks_usec()
	for i in n:
		await process_frame
		var now := Time.get_ticks_usec()
		frame += (now - last) / 1000.0
		last = now
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	var result := {
		"gpu_ms": gpu / n, "render_cpu_ms": cpu / n, "frame_ms": frame / n,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"triangles": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	}
	await RenderingServer.frame_post_draw
	get_root().get_texture().get_image().save_png("res://results/audit/%s_%s.png" % [_args["tag"], view_name])
	return result

## Triangles and instances of what the runtime built.
func _content() -> Dictionary:
	var chunks := _terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	var terrain_tris := 0
	var surfaces := 0
	var chunk_count := 0
	var layers := {}
	var multimeshes := 0
	if chunks:
		for chunk in chunks.get_children():
			chunk_count += 1
			var mi := chunk as MeshInstance3D
			if mi and mi.mesh:
				surfaces += mi.mesh.get_surface_count()
				terrain_tris += _tris(mi.mesh)
			for child in chunk.get_children():
				var mm := child as MultiMeshInstance3D
				if mm == null or mm.multimesh == null:
					continue
				multimeshes += 1
				var key := String(mm.name).get_slice("_", 3)
				var entry: Dictionary = layers.get(key, {"instances": 0, "mesh_tris": _tris(mm.multimesh.mesh), "nodes": 0})
				entry["instances"] += mm.multimesh.instance_count
				entry["nodes"] += 1
				layers[key] = entry
	var detail_tris := 0
	var instances := 0
	for key in layers:
		layers[key]["tris"] = int(layers[key]["instances"]) * int(layers[key]["mesh_tris"])
		detail_tris += int(layers[key]["tris"])
		instances += int(layers[key]["instances"])
	var others := 0
	for node in _terrain.get_children():
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			others += _tris((node as MeshInstance3D).mesh)
	var shapes := 0
	for body in _terrain.find_children("*", "StaticBody3D", true, false):
		for owner_id in (body as StaticBody3D).get_shape_owners():
			shapes += (body as StaticBody3D).shape_owner_get_shape_count(owner_id)
		shapes += body.find_children("*", "CollisionShape3D", true, false).size()
	return {"chunks": chunk_count, "terrain_triangles": terrain_tris, "terrain_surfaces": surfaces, "roads_rivers_waterholes_triangles": others + _waterhole_tris(),
		"detail_instances": instances, "detail_triangles_if_all_drawn": detail_tris, "detail_multimeshes": multimeshes, "collision_shapes": shapes, "layers": layers}

func _waterhole_tris() -> int:
	var total := 0
	var holder := _terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME)
	if holder == null:
		return 0
	for node in holder.find_children("*", "MeshInstance3D", true, false):
		if (node as MeshInstance3D).mesh:
			total += _tris((node as MeshInstance3D).mesh)
	return total

func _tris(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var total := 0
	var array_mesh := mesh as ArrayMesh
	for s in mesh.get_surface_count():
		if array_mesh:
			var indices := array_mesh.surface_get_array_index_len(s)
			total += (indices if indices > 0 else array_mesh.surface_get_array_len(s)) / 3
		else:
			var arrays := mesh.surface_get_arrays(s)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			total += ((idx as PackedInt32Array).size() if idx != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return total

func _print() -> void:
	print("== AUDIT %s  %s" % [_args["tag"], _args])
	print("map: %s  generate %.0f ms" % [_report["map"], _report["map_generate_ms"]])
	print("load: %s" % _report["load"])
	for key in ["content", "content_forest"]:
		var c: Dictionary = _report[key]
		print("%s: chunks %d, terrain %d tris / %d surfaces, roads+rivers+waterholes %d tris, details %d instances (%d tris if all drawn) in %d multimeshes, collision shapes %d" % [
			key, c["chunks"], c["terrain_triangles"], c["terrain_surfaces"], c["roads_rivers_waterholes_triangles"], c["detail_instances"], c["detail_triangles_if_all_drawn"], c["detail_multimeshes"], c["collision_shapes"]])
		for layer in c["layers"]:
			var l: Dictionary = c["layers"][layer]
			print("   %-16s %7d inst x %4d tris = %8d" % [layer, l["instances"], l["mesh_tris"], l["tris"]])
	print("forest details rebuild %.0f ms" % _report["forest_details_rebuild_ms"])
	print("%-10s %7s %7s %7s %6s %9s %6s %6s" % ["view", "gpu", "cpu", "frame", "draws", "tris", "objs", "vram"])
	for view_name in _report["views"]:
		var r: Dictionary = _report["views"][view_name]
		print("%-10s %7.2f %7.2f %7.2f %6d %9d %6d %6.0f" % [view_name, r["gpu_ms"], r["render_cpu_ms"], r["frame_ms"], r["draw_calls"], r["triangles"], r["objects"], r["video_mem_mb"]])
