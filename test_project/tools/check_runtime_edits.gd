extends SceneTree
## Ground edits in game (LowpolyTerrainRuntime.raise_area / flatten_area /
## set_height / paint_style / commit_edits / export_edits / import_edits), on
## a savanna built whole by the runtime, then on one streamed (stream_ground):
## - the ground is where asked (get_height) and the collision agrees (physics
##   ray);
## - the details on the edited ground follow it (not left floating / buried);
## - a road on the edited ground follows it;
## - only the chunks around the edit are rebuilt; terrain_changed is emitted;
## - paint_style: the cell style changes (find_ground_style);
## - export_edits is small, import_edits on a fresh load gives the same data
##   and ground; garbage is refused.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_runtime_edits.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const FeatureEraser = preload(ADDON + "editing/feature_eraser.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

## A savanna of `cells` cells built by its runtime (streamed or whole).
func _world(world_name: String, cells: int, stream: bool) -> LowpolyTerrainRuntime:
	var world := Node3D.new()
	world.name = world_name
	root.add_child(world)
	var t := Node3D.new()
	t.name = "LowpolyTerrain"
	world.add_child(t)
	TerrainData.initialize(t)
	var recipe: MapRecipe = (load(RECIPE) as MapRecipe).duplicate()
	recipe.size = cells
	recipe.cell_size = 1.5
	MapGenerator.generate(t, recipe, 7)
	t.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	t.set_meta(Meta.COLLISION_ENABLED, true)
	var camera := Camera3D.new()
	camera.name = "Camera"
	world.add_child(camera)
	camera.current = true
	camera.global_position = Vector3(0, 2, 0)
	var runtime := LowpolyTerrainRuntime.new()
	runtime.name = "Runtime"
	runtime.build_on_ready = false
	runtime.stream_ground = stream
	runtime.stream_details = stream
	runtime.progressive = stream
	runtime.far_distance = 300.0
	t.add_child(runtime)
	runtime.build()
	return runtime

func _idle(runtime: LowpolyTerrainRuntime) -> void:
	var guard := 0
	while not runtime.is_finished and guard < 20000:
		await process_frame
		guard += 1
	var until := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < until:
		await process_frame
	guard = 0
	while (not runtime.is_streaming_idle or runtime.has_pending_edits()) and guard < 20000:
		await process_frame
		guard += 1
	for i in 3:
		await physics_frame

## Physics ray down at `point` (X / Z). Keep it off the grid vertices: Jolt's
## HeightMapShape3D (streamed ground collision) lets a vertical ray through
## exactly at some of them.
func _ray(world: Node3D, point: Vector3) -> float:
	var space := world.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(point.x, 500.0, point.z), Vector3(point.x, -500.0, point.z)))
	if hit.is_empty():
		return NAN
	var position: Vector3 = hit["position"]
	return position.y

## A point a little off the grid vertex `point`, for _ray().
static func _off(point: Vector3) -> Vector3:
	return point + Vector3(0.37, 0.0, 0.21)

## Mesh RIDs of the chunks, by name.
func _meshes(t: Node3D) -> Dictionary:
	var result := {}
	for chunk in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var mesh_instance := chunk as MeshInstance3D
		if mesh_instance != null and mesh_instance.mesh != null:
			result[String(chunk.name)] = mesh_instance.mesh.get_rid()
	return result

func _changed(before: Dictionary, after: Dictionary) -> int:
	var count := 0
	for key: String in after:
		if before.get(key) != after[key]:
			count += 1
	return count

## Worst |instance foot - ground| of the details within `radius` of `point`.
func _detail_offset(runtime: LowpolyTerrainRuntime, t: Node3D, point: Vector3, radius: float) -> Vector2:
	var worst := 0.0
	var count := 0
	for chunk in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		for child in chunk.get_children():
			var layer := child as MultiMeshInstance3D
			if layer == null or layer.multimesh == null:
				continue
			# The buffer (get_instance_transform() reads the rendering
			# server, empty in headless runs).
			var multimesh := layer.multimesh
			var buffer := multimesh.buffer
			var stride := 12 + (4 if multimesh.use_colors else 0) + (4 if multimesh.use_custom_data else 0)
			var shown := multimesh.visible_instance_count if multimesh.visible_instance_count >= 0 else multimesh.instance_count
			for i in mini(shown, buffer.size() / stride):
				var o := i * stride
				var foot := layer.global_transform * Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11])
				if Vector2(foot.x - point.x, foot.z - point.z).length() > radius:
					continue
				var ground := runtime.get_height(foot)
				if not is_nan(ground):
					worst = maxf(worst, absf(foot.y - ground))
					count += 1
	return Vector2(worst, count)

## Highest road / river mesh vertex within 1 m of `point` (X / Z), NAN if none.
func _road_top(t: Node3D, point: Vector3) -> float:
	var top := NAN
	var meshes: Array[MeshInstance3D] = []
	var whole := t.get_node_or_null(Meta.GENERATED_MESH_NAME) as MeshInstance3D
	if whole != null:
		meshes.append(whole)
	for chunk in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var pieces := chunk.get_node_or_null("_Roads") as MeshInstance3D
		if pieces != null:
			meshes.append(pieces)
	for mesh_instance in meshes:
		if mesh_instance.mesh == null:
			continue
		for v in mesh_instance.mesh.get_faces():
			var p := mesh_instance.global_transform * v
			if Vector2(p.x - point.x, p.z - point.z).length() < 1.0:
				top = p.y if is_nan(top) else maxf(top, p.y)
	return top

## A grid vertex (global) with ground around it, away from roads, rivers and
## waterholes, near `near` (terrain-local X / Z).
func _clear_vertex(t: Node3D, near: Vector2) -> Vector3:
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var world_size: float = t.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	var river := RiverMesher.compute_carve(t)
	for ring in 60:
		for side in 8:
			var angle := TAU * float(side) / 8.0
			var local := near + Vector2(cos(angle), sin(angle)) * float(ring) * spacing * 2.0
			var x := clampi(roundi((local.x + half) / spacing), 8, resolution - 9)
			var z := clampi(roundi((local.y + half) / spacing), 8, resolution - 9)
			var vertex := Vector2(x * spacing - half, z * spacing - half)
			if river[z * resolution + x] == 0.0 and not FeatureEraser.has_feature_at(t, vertex, 10.0):
				return t.to_global(Vector3(vertex.x, 0.0, vertex.y))
	return Vector3(NAN, NAN, NAN)

func _road_point(t: Node3D) -> Vector3:
	for road: Dictionary in t.get_meta(Meta.ROADS, []):
		var points: Array = road.get("points", [])
		if points.size() >= 3:
			var p: Vector2 = points[points.size() / 2]
			if absf(p.x) < 60.0 and absf(p.y) < 60.0:
				return t.to_global(Vector3(p.x, 0.0, p.y))
	return Vector3(NAN, NAN, NAN)

func _edits(label: String, runtime: LowpolyTerrainRuntime) -> PackedByteArray:
	var t := runtime.get_parent() as Node3D
	var world := t.get_parent() as Node3D
	await _idle(runtime)
	var builder := TerrainBuilder.new()
	var changed_rects: Array[Rect2] = []
	runtime.terrain_changed.connect(func(rect: Rect2) -> void: changed_rects.append(rect))

	# Raise 3 m.
	var p := _clear_vertex(t, Vector2(42.0, -38.0))
	var before_h := runtime.get_height(p)
	var before_details := _detail_offset(runtime, t, p, 5.0)
	var meshes_before := _meshes(t)
	var start := Time.get_ticks_usec()
	runtime.raise_area(p, 6.0, 3.0)
	runtime.commit_edits()
	var commit_ms := (Time.get_ticks_usec() - start) / 1000.0
	await _idle(runtime)
	var after_h := runtime.get_height(p)
	check("%s: raised 3 m (%.3f -> %.3f), commit %.1f ms" % [label, before_h, after_h, commit_ms], absf(after_h - before_h - 3.0) < 0.001)
	var ray := _ray(world, _off(p))
	check("%s: collision agrees (ray %.3f, ground %.3f)" % [label, ray, runtime.get_height(_off(p))], absf(ray - runtime.get_height(_off(p))) < 0.02)
	var after_details := _detail_offset(runtime, t, p, 5.0)
	check("%s: details follow the ground (worst %.2f m before, %.2f m after, %d instances)" % [label, before_details.x, after_details.x, after_details.y], after_details.y > 0 and after_details.x <= before_details.x + 0.1)
	var rebuilt := _changed(meshes_before, _meshes(t))
	var expected := builder.chunks_for_local_rect(t, changed_rects[0] if not changed_rects.is_empty() else Rect2()).size()
	check("%s: terrain_changed, %d chunks rebuilt (of %d around the edit, %d in all)" % [label, rebuilt, expected, meshes_before.size()], changed_rects.size() == 1 and rebuilt >= 1 and rebuilt <= expected and rebuilt < meshes_before.size())

	# Flatten, then set one vertex.
	var q := _clear_vertex(t, Vector2(-20.0, 15.0))
	var level := runtime.get_height(q) + 1.5
	runtime.flatten_area(q, 5.0, level)
	var r := _clear_vertex(t, Vector2(-5.0, -25.0))
	runtime.set_height(r, runtime.get_height(r) - 2.0)
	var r_target := runtime.get_height(r) - 2.0
	runtime.commit_edits()
	await _idle(runtime)
	check("%s: flatten_area to %.2f (%.3f), set_height (%.3f of %.3f)" % [label, level, runtime.get_height(q), runtime.get_height(r), r_target], absf(runtime.get_height(q) - level) < 0.001 and absf(runtime.get_height(r) - r_target) < 0.001 and absf(_ray(world, _off(q)) - runtime.get_height(_off(q))) < 0.02)

	# Paint.
	var s := _clear_vertex(t, Vector2(25.0, 20.0)) + Vector3(0.75, 0.0, 0.75)
	var old_style := runtime.get_ground_style(s)
	var palette: Array = t.get_meta(Meta.STYLE_PALETTE)
	var new_name := &""
	for entry: Dictionary in palette:
		var style_name := StringName(str(entry.get("biome_style", "")))
		if style_name != &"" and style_name != runtime.get_ground_style_name(s):
			new_name = style_name
			break
	var new_style := runtime.find_ground_style(new_name)
	runtime.paint_style(s, 2.0, new_style)
	runtime.commit_edits()
	await _idle(runtime)
	check("%s: paint_style %s (%d -> %d)" % [label, new_name, old_style, runtime.get_ground_style(s)], new_style >= 0 and new_style != old_style and runtime.get_ground_style(s) == new_style and runtime.get_ground_style_name(s) == new_name)

	# A road on raised ground.
	var road := _road_point(t)
	if not is_nan(road.x):
		runtime.raise_area(road, 8.0, 2.0)
		runtime.commit_edits()
		await _idle(runtime)
		var top := _road_top(t, road)
		var ground := runtime.get_height(road)
		check("%s: the road follows the raised ground (road %.2f, ground %.2f)" % [label, top, ground], not is_nan(top) and absf(top - ground) < 0.4 and absf(_ray(world, _off(road)) - runtime.get_height(_off(road))) < 0.4)
	else:
		check("%s: a road near the centre to raise" % label, false)
	var data := runtime.export_edits()
	check("%s: export_edits %d bytes" % [label, data.size()], data.size() > 0 and data.size() < 64 * 1024)
	return data

func _same_data(a: Node3D, b: Node3D) -> bool:
	var ha: PackedFloat32Array = a.get_meta(Meta.HEIGHTS)
	var hb: PackedFloat32Array = b.get_meta(Meta.HEIGHTS)
	var sa: PackedInt32Array = a.get_meta(Meta.CELL_STYLES)
	var sb: PackedInt32Array = b.get_meta(Meta.CELL_STYLES)
	return ha == hb and sa == sb

func _run() -> void:
	# Built whole.
	var whole := _world("Whole", 128, false)
	var data: PackedByteArray = await _edits("whole", whole)
	var fresh := _world("Fresh", 128, false)
	await _idle(fresh)
	var whole_t := whole.get_parent() as Node3D
	var fresh_t := fresh.get_parent() as Node3D
	check("import_edits refuses garbage", not fresh.import_edits(PackedByteArray([1, 2, 3, 4])) and not fresh.import_edits("hello".to_utf8_buffer().compress(FileAccess.COMPRESSION_ZSTD)))
	var imported := fresh.import_edits(data)
	await _idle(fresh)
	var p := Vector3(42.0, 0.0, -38.0)
	check("import_edits on a fresh load: same heights and styles, same ground", imported and _same_data(whole_t, fresh_t) and absf(fresh.get_height(p) - whole.get_height(p)) < 0.0001)
	var again := fresh.export_edits()
	check("export after import: same edits (%d bytes)" % again.size(), again.size() > 0 and again.size() <= data.size() + 64)
	for world_name: String in ["Whole", "Fresh"]:
		var world := root.get_node(world_name)
		root.remove_child(world)
		world.free()

	# Streamed ground.
	var streamed := _world("Streamed", 256, true)
	await _edits("streamed", streamed)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
