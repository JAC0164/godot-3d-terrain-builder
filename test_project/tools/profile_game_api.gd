extends SceneTree
## What the game API of LowpolyTerrainRuntime costs the main thread (final
## audit 2026-11-27), on the savanna (192 cells, built whole, collision on)
## and on the open world (1 024 cells, stream_ground, seed 7):
##   - questions: first call (copy of the ground data, RAM), then per call
##     (get_height, get_normal, get_ground_style_name, get_intersection);
##   - edits: raise_area + commit_edits (then split into its steps) (main-thread ms of the commit, then the
##     worst runtime frame until the change is in), first question after it;
##   - export_edits size / time; navigation bake (whole / 128 m box);
##   - heightmap export / import.
## Headless: no GPU upload, so mesh swaps cost a little more in a game.
##   godot --headless --path . --script res://tools/profile_game_api.gd [-- --defaults]
## --defaults: only the savanna with the runtime's default settings.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainNavigation = preload(ADDON + "navigation/terrain_navigation.gd")
const HeightmapIO = preload(ADDON + "generation/heightmap_io.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const FeatureEraser = preload(ADDON + "editing/feature_eraser.gd")
const SAVANNA := ADDON + "generation/presets/senegal_savanna_map.tres"
const OPEN_WORLD := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"

func _initialize() -> void:
	_run.call_deferred()

func _world(world_name: String, recipe_path: String, cells: int, stream: bool, defaults := false) -> LowpolyTerrainRuntime:
	var world := Node3D.new()
	world.name = world_name
	root.add_child(world)
	var t := Node3D.new()
	t.name = "LowpolyTerrain"
	world.add_child(t)
	TerrainData.initialize(t)
	var recipe: MapRecipe = (load(recipe_path) as MapRecipe).duplicate()
	if cells > 0:
		recipe.size = cells
		recipe.cell_size = 1.5
	MapGenerator.generate(t, recipe, 7)
	t.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	t.set_meta(Meta.COLLISION_ENABLED, true)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.far = 700.0
	world.add_child(camera)
	camera.current = true
	camera.global_position = Vector3(0, 30, 0)
	var runtime := LowpolyTerrainRuntime.new()
	runtime.name = "Runtime"
	runtime.build_on_ready = false
	runtime.stream_ground = stream
	if not defaults:
		runtime.stream_details = stream
		runtime.progressive = stream
	if stream:
		runtime.ground_distance = 160.0
		runtime.far_distance = 600.0
	t.add_child(runtime)
	runtime.build()
	await _idle(runtime)
	return runtime

func _idle(runtime: LowpolyTerrainRuntime) -> float:
	# Worst runtime frame (ms, timed around _process) until it is idle.
	runtime.set_process(false)
	var worst := 0.0
	var guard := 0
	var last := Time.get_ticks_usec()
	while (guard < 30 or not runtime.is_finished or not runtime.is_streaming_idle or runtime.has_pending_edits()) and guard < 20000:
		await process_frame
		var now := Time.get_ticks_usec()
		var t0 := Time.get_ticks_usec()
		runtime._process((now - last) / 1000000.0)
		worst = maxf(worst, (Time.get_ticks_usec() - t0) / 1000.0)
		last = now
		guard += 1
	runtime.set_process(true)
	return worst

func _points(runtime: LowpolyTerrainRuntime, count: int) -> PackedVector3Array:
	var range_ := runtime.get_height_range()
	var t := runtime.get_parent() as Node3D
	var half: float = Meta.get_float(t, Meta.WORLD_SIZE, 64.0) * 0.45
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var points := PackedVector3Array()
	for i in count:
		points.append(Vector3(rng.randf_range(-half, half), range_.y + 5.0, rng.randf_range(-half, half)))
	return points

func _questions(label: String, runtime: LowpolyTerrainRuntime) -> void:
	runtime.refresh_query()
	var ram := Performance.get_monitor(Performance.MEMORY_STATIC)
	var t0 := Time.get_ticks_usec()
	runtime.get_height(Vector3.ZERO)
	var first := (Time.get_ticks_usec() - t0) / 1000.0
	var ram_mb := (Performance.get_monitor(Performance.MEMORY_STATIC) - ram) / 1048576.0
	var points := _points(runtime, 20000)
	var times := {}
	t0 = Time.get_ticks_usec()
	for p in points:
		runtime.get_height(p)
	times["get_height"] = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for p in points:
		runtime.get_normal(p)
	times["get_normal"] = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for p in points:
		runtime.get_ground_style_name(p)
	times["get_ground_style_name"] = Time.get_ticks_usec() - t0
	var rays := points.slice(0, 2000)
	t0 = Time.get_ticks_usec()
	for p in rays:
		runtime.get_intersection(p, Vector3(0.3, -1.0, 0.2).normalized(), 300.0)
	var ray_us := float(Time.get_ticks_usec() - t0) / rays.size()
	print("%s questions: first call %.1f ms (+%.1f MB RAM) | per call: %s, get_intersection %.1f us" % [
		label, first, ram_mb,
		", ".join(times.keys().map(func(k: String) -> String: return "%s %.2f us" % [k, float(times[k]) / points.size()])),
		ray_us])

func _edits(label: String, runtime: LowpolyTerrainRuntime) -> void:
	var points := _points(runtime, 5)
	for i in points.size():
		var p := points[i]
		var ground := runtime.get_height(p)
		if is_nan(ground):
			continue
		var t0 := Time.get_ticks_usec()
		runtime.raise_area(Vector3(p.x, ground, p.z), 6.0, -2.0)
		var edit_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var t3d := runtime.get_parent() as Node3D
		var near := RiverMesher.any_river_near(t3d, runtime._edit_rect)
		var roads := FeatureEraser.any_feature_intersects(t3d, runtime._edit_rect)
		t0 = Time.get_ticks_usec()
		runtime.commit_edits()
		var commit_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var worst := await _idle(runtime)
		t0 = Time.get_ticks_usec()
		runtime.get_height(p)
		var question_ms := (Time.get_ticks_usec() - t0) / 1000.0
		print("%s edit %d (river %s, roads %s): raise_area %.2f ms, commit_edits %.1f ms, worst frame after %.1f ms, first question after %.1f ms" % [
			label, i, near, roads, edit_ms, commit_ms, worst, question_ms])
	var t1 := Time.get_ticks_usec()
	var data := runtime.export_edits()
	print("%s export_edits: %d bytes in %.1f ms" % [label, data.size(), (Time.get_ticks_usec() - t1) / 1000.0])

## commit_edits split into its steps (same calls as the runtime's
## _rebuild_edited), for one raise_area at each of `count` points.
func _breakdown(label: String, runtime: LowpolyTerrainRuntime, count: int) -> void:
	var t := runtime.get_parent() as Node3D
	var builder: TerrainBuilder = runtime._builder
	var points := _points(runtime, count + 7).slice(7)
	for p in points:
		var ground := runtime.get_height(p)
		if is_nan(ground):
			continue
		runtime.raise_area(Vector3(p.x, ground, p.z), 6.0, -2.0)
		var rect: Rect2 = runtime._edit_rect
		runtime._edit_rect = Rect2()
		runtime._has_edits = false
		var steps := PackedStringArray()
		var t0 := Time.get_ticks_usec()
		var keys := builder.chunks_for_local_rect(t, rect)
		var river_near := RiverMesher.any_river_near(t, rect)
		steps.append("river near %s %.1f" % [river_near, (Time.get_ticks_usec() - t0) / 1000.0])
		if river_near:
			t0 = Time.get_ticks_usec()
			var carved := builder.rebuild_river_carve(t)
			steps.append("river carve %.1f (+%d chunks)" % [(Time.get_ticks_usec() - t0) / 1000.0, carved.size()])
			for key in carved:
				if not keys.has(key):
					keys.append(key)
		t0 = Time.get_ticks_usec()
		var roads := FeatureEraser.any_feature_intersects(t, rect)
		steps.append("roads near %s %.1f" % [roads, (Time.get_ticks_usec() - t0) / 1000.0])
		if runtime._ground_streaming:
			t0 = Time.get_ticks_usec()
			runtime._rebuild_streamed_edits(t, keys, rect, roads)
			steps.append("streamed swap queued %.1f" % ((Time.get_ticks_usec() - t0) / 1000.0))
		else:
			var chunk_ms := 0.0
			for c in keys:
				t0 = Time.get_ticks_usec()
				builder.rebuild_chunk(t, c.x, c.y, true)
				chunk_ms += (Time.get_ticks_usec() - t0) / 1000.0
			steps.append("%d chunks (with details) %.1f" % [keys.size(), chunk_ms])
			if roads:
				steps.append("roads on worker threads")
			t0 = Time.get_ticks_usec()
			builder.rebuild_waterholes(t, rect)
			steps.append("waterholes %.1f" % ((Time.get_ticks_usec() - t0) / 1000.0))
			t0 = Time.get_ticks_usec()
			var body := t.get_node_or_null(runtime.GROUND_COLLISION_NAME) as StaticBody3D
			if body != null:
				for c in keys:
					runtime._replace_ground_shape(body, c, runtime._chunk_faces(c.x, c.y))
			steps.append("collision %.1f" % ((Time.get_ticks_usec() - t0) / 1000.0))
		runtime._query = null
		t0 = Time.get_ticks_usec()
		var carve := runtime._query_carve(t)
		var carve_ms := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		LowpolyTerrainQuery.from_terrain(t, carve)
		steps.append("query: carve %.1f + copy %.1f" % [carve_ms, (Time.get_ticks_usec() - t0) / 1000.0])
		print("%s commit steps (ms): %s" % [label, " | ".join(steps)])
		await _idle(runtime)

func _navigation(label: String, runtime: LowpolyTerrainRuntime, box: bool) -> void:
	var t := runtime.get_parent() as Node3D
	var carve := TerrainBuilder.new().get_river_carve(t)
	var region := TerrainNavigation.ensure_region(t)
	var bounds := AABB(Vector3(-64, -1000, -64), Vector3(128, 2000, 128)) if box else AABB()
	var t0 := Time.get_ticks_msec()
	TerrainNavigation.bake(t, region, carve, bounds, false)
	print("%s navigation bake (%s, not threaded): %d ms, %d polygons" % [
		label, "128 m box" if box else "whole map", Time.get_ticks_msec() - t0, region.navigation_mesh.get_polygon_count()])

func _heightmap(label: String, runtime: LowpolyTerrainRuntime) -> void:
	var t := runtime.get_parent() as Node3D
	var base := OS.get_user_data_dir().path_join("profile_game_api_height")
	var t0 := Time.get_ticks_msec()
	HeightmapIO.export_files(t, base + ".exr")
	var export_ms := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	HeightmapIO.import_file(t, base + ".png")
	print("%s heightmap: export (exr + png + json) %d ms, import png %d ms" % [label, export_ms, Time.get_ticks_msec() - t0])

func _run() -> void:
	if OS.get_cmdline_user_args().has("--defaults"):
		# The runtime's own defaults (stream_details on, progressive), ground built whole.
		var plain: LowpolyTerrainRuntime = await _world("Default", SAVANNA, 192, false, true)
		await _edits("savanna 192 runtime defaults", plain)
		await _breakdown("savanna 192 runtime defaults", plain, 4)
		quit()
		return
	var savanna: LowpolyTerrainRuntime = await _world("Savanna", SAVANNA, 192, false)
	_questions("savanna 192 whole", savanna)
	await _edits("savanna 192 whole", savanna)
	await _breakdown("savanna 192 whole", savanna, 4)
	_navigation("savanna 192", savanna, false)
	_heightmap("savanna 192", savanna)
	savanna.get_parent().get_parent().queue_free()
	await process_frame
	var open_world: LowpolyTerrainRuntime = await _world("OpenWorld", OPEN_WORLD, 0, true)
	_questions("open world 1024 streamed", open_world)
	await _edits("open world 1024 streamed", open_world)
	await _breakdown("open world 1024 streamed", open_world, 4)
	_navigation("open world 1024", open_world, true)
	_heightmap("open world 1024", open_world)
	quit()
