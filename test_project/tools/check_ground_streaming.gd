extends SceneTree
## Checks TerrainRuntime.stream_ground on a big generated savanna (512 cells
## of 1.5 m = 768 m by default):
##   1. camera at the centre: exactly the chunks within ground_distance +
##      stream_margin are built, each one bit-identical to a main-thread build
##      (TerrainMesher.build_chunk_parts), ground collision shapes only within
##      ground_collision_distance, waterholes only near (also identical);
##   2. teleport to a corner: the far chunks are freed (past ground_distance +
##      unload_margin), the near ones built;
##   3. run (10 m/s) to the opposite corner: never a missing chunk within
##      ground_distance, never a hole under the feet (ray down on the
##      collision), and the slowest frame of the streaming;
##   4. far blocks (far_distance 500 m): every frame, each chunk is shown
##      once at most (detailed, or by its far block), and once within
##      far_distance (no hole, no overlap); triangles and draw calls;
##   5. load time to terrain_ready, compared with a full build.
##   godot --headless --path . --script res://tools/check_ground_streaming.gd [-- size]
## Prints FAIL lines and "ground streaming: N failures" at the end.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const LodMesher = preload(ADDON + "mesh/lod_mesher.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const RUN_SPEED := 10.0
const FAR_DISTANCE := 500.0

var _failures := 0
var _map_cells := 512
var _terrain: Node3D
var _runtime: TerrainRuntime
var _camera: Camera3D
var _size := 0.0
var _count := 0
var _chunk_world := 0.0
var _carve := PackedFloat32Array()
## Vector2i -> mesh hash of a main-thread build (made when first needed).
var _reference: Dictionary = {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.is_valid_int():
			_map_cells = arg.to_int()
	await process_frame
	var full: Dictionary = await _load(false)
	_free_world()
	var streamed: Dictionary = await _load(true)
	print("load to terrain_ready: full %.0f ms (%d chunks) / streamed %.0f ms (%d chunks, worst step %.1f ms)" % [
		full["ready_ms"], full["chunks"], streamed["ready_ms"], streamed["chunks"], streamed["worst_step_ms"]])
	_count = TerrainMesher.chunk_count(_terrain)
	_chunk_world = _size / float(_count)
	var builder := TerrainBuilder.new()
	_carve = builder.get_river_carve(_terrain)
	print("map %.0f m, %d x %d chunks of %.0f m; ground %.0f m, collision %.0f m" % [
		_size, _count, _count, _chunk_world, _runtime.ground_distance, _runtime.ground_collision_distance])

	# 1. Centre.
	await _idle()
	_check("centre", true)
	_report(_coverage("centre", true) == 0, "centre: every chunk shown once")
	_print_draw("centre")

	# 2. Teleport to a corner.
	_camera.global_position = Vector3(-_size * 0.45, 2.0, -_size * 0.45)
	await _idle()
	_check("corner", false)
	_report(_coverage("corner", true) == 0, "corner: every chunk shown once")
	_print_draw("corner")

	# 3. Run to the opposite corner, the streaming timed alone.
	var target := Vector3(_size * 0.45, 2.0, _size * 0.45)
	_runtime.set_process(false)
	var plugin_ms: Array[float] = []
	var missing := 0
	var holes := 0
	var cover_errors := 0
	var frames := 0
	var slow: Array = []
	var last := Time.get_ticks_usec()
	while _camera.global_position.distance_to(target) > 0.5:
		await physics_frame
		var now := Time.get_ticks_usec()
		var delta := (now - last) / 1e6
		last = now
		frames += 1
		_camera.global_position = _camera.global_position.move_toward(target, RUN_SPEED * maxf(delta, 1.0 / 60.0))
		var before := [_runtime._ground.size(), _runtime._ground_shapes.size(), _runtime._holes.size(), _runtime._ground_tasks.size(), str(_runtime._stream_job.get("chunk", "-"))]
		var t0 := Time.get_ticks_usec()
		_runtime._stream(delta)
		plugin_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		slow.append([plugin_ms[-1], frames, "ground %d->%d, shapes %d->%d, holes %d->%d, tasks %d->%d, details job %s->%s" % [
			before[0], _runtime._ground.size(), before[1], _runtime._ground_shapes.size(), before[2], _runtime._holes.size(),
			before[3], _runtime._ground_tasks.size(), before[4], str(_runtime._stream_job.get("chunk", "-"))]])
		missing += _missing_near()
		cover_errors += _coverage("run", cover_errors < 3)
		if not _ground_under_camera():
			holes += 1
			if holes <= 3:
				print("FAIL run: no ground collision under %s" % _camera.global_position)
	_runtime.set_process(true)
	slow.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	for i in mini(8, slow.size()):
		print("  slow frame %d: %.1f ms, %s" % [slow[i][1], slow[i][0], slow[i][2]])
	plugin_ms.sort()
	print("streaming per frame: median %.2f ms, 99%% %.2f ms, max %.2f ms" % [
		plugin_ms[plugin_ms.size() / 2], plugin_ms[int(plugin_ms.size() * 0.99)], plugin_ms[-1]])
	_report(missing == 0, "run: %d frames, %d missing chunk-frames within ground_distance" % [frames, missing])
	_report(holes == 0, "run: %d frames without ground under the feet" % holes)
	_report(cover_errors == 0, "run: %d chunk-frames shown twice or not at all within far_distance" % cover_errors)
	await _idle()
	_check("after run", false)
	_report(_coverage("after run", true) == 0, "after run: every chunk shown once")
	_print_draw("after run")

	print("ground streaming: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)

## Builds the map, streamed or not. {ready_ms, chunks, worst_step_ms}.
func _load(stream: bool) -> Dictionary:
	var root := Node3D.new()
	root.name = "World"
	get_root().add_child(root)
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	var recipe: MapRecipe = (load(RECIPE) as MapRecipe).duplicate()
	recipe.size = _map_cells
	recipe.cell_size = 1.5
	MapGenerator.generate(_terrain, recipe, 7)
	_size = Meta.get_float(_terrain, Meta.WORLD_SIZE)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_camera.current = true
	_camera.global_position = Vector3(0, 2, 0)
	_runtime = TerrainRuntime.new()
	_runtime.name = String(Meta.RUNTIME_NODE_NAME)
	_runtime.build_on_ready = false
	_runtime.stream_ground = stream
	_runtime.far_distance = FAR_DISTANCE
	_terrain.add_child(_runtime)
	var stats: Array = [{}]
	_runtime.finished.connect(func(s: Dictionary) -> void: stats[0] = s)
	var started := Time.get_ticks_usec()
	var ready_ms: Array[float] = [0.0]
	_runtime.terrain_ready.connect(func() -> void: ready_ms[0] = (Time.get_ticks_usec() - started) / 1000.0)
	_runtime.build()
	while not _runtime.is_finished:
		await process_frame
	var finished: Dictionary = stats[0]
	print("  %s: worst load step %d of %d, %.1f ms" % ["streamed" if stream else "full", int(finished.get("worst_step", -1)), int(finished.get("steps", 0)), float(finished.get("worst_step_ms", 0.0))])
	return {"ready_ms": ready_ms[0], "chunks": _chunks_root().get_child_count(), "worst_step_ms": float(finished.get("worst_step_ms", 0.0))}

func _free_world() -> void:
	var root := get_root().get_node("World")
	get_root().remove_child(root)
	root.free()

func _idle() -> void:
	# Long enough for a retarget (every 0.25 s), then until nothing is left.
	var until := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < until:
		await process_frame
	var guard := 0
	while not _runtime.is_streaming_idle and guard < 20000:
		await process_frame
		guard += 1
	for i in 3:
		await physics_frame

func _chunks_root() -> Node:
	return _terrain.get_node(String(Meta.GENERATED_CHUNKS_NAME))

func _focus() -> Vector2:
	return Vector2(_camera.global_position.x, _camera.global_position.z)

func _distance(c: Vector2i) -> float:
	var focus := _focus()
	var lo := Vector2(c.x * _chunk_world - _size * 0.5, c.y * _chunk_world - _size * 0.5)
	return focus.clamp(lo, lo + Vector2(_chunk_world, _chunk_world)).distance_to(focus)

## Built chunks = those in range (exact: no unload margin), each identical to
## a main-thread build; collision shapes and waterholes in range too.
func _check(label: String, exact: bool) -> void:
	var errors := 0
	var built := 0
	var build_distance := _runtime.ground_distance + _runtime.stream_margin
	var free_distance := _runtime.ground_distance + (_runtime.stream_margin if exact else _runtime.unload_margin)
	for z in _count:
		for x in _count:
			var c := Vector2i(x, z)
			var distance := _distance(c)
			var chunk := TerrainMesher.find_chunk(_terrain, x, z)
			if chunk != null and chunk.is_queued_for_deletion():
				chunk = null
			if chunk == null and distance <= build_distance:
				errors += 1
				if errors <= 5:
					print("FAIL %s: chunk %s missing (%.0f m)" % [label, c, distance])
			elif chunk != null and distance > free_distance:
				errors += 1
				if errors <= 5:
					print("FAIL %s: chunk %s kept (%.0f m)" % [label, c, distance])
			elif chunk != null:
				built += 1
				if _mesh_hash(chunk.mesh) != _reference_hash(c):
					errors += 1
					if errors <= 5:
						print("FAIL %s: chunk %s differs from a main-thread build" % [label, c])
			var has_shape: bool = _runtime._ground_shapes.has(c)
			var collision := _runtime.ground_collision_distance
			if has_shape and distance > collision + (0.0 if exact else _runtime.unload_margin):
				errors += 1
				print("FAIL %s: collision kept on chunk %s (%.0f m)" % [label, c, distance])
			elif not has_shape and chunk != null and distance <= collision:
				errors += 1
				print("FAIL %s: collision missing on chunk %s (%.0f m)" % [label, c, distance])
	# One collision body per chunk in range. The roads and rivers are cut by
	# chunk: each built chunk with a piece has it as a child (_Roads), its
	# collision body has a shape more for the road faces, the terrain's
	# roads body and single road mesh stay empty.
	var bodies := 0
	for chunk in _chunks_root().get_children():
		if not chunk.is_queued_for_deletion() and chunk.get_node_or_null(TerrainRuntime.CHUNK_COLLISION_NAME) != null:
			bodies += 1
	if bodies != _runtime._ground_shapes.size():
		errors += 1
		print("FAIL %s: %d chunk collision bodies for %d chunk shapes" % [label, bodies, _runtime._ground_shapes.size()])
	var roads := _terrain.get_node(TerrainRuntime.GROUND_COLLISION_NAME) as StaticBody3D
	if roads.get_shape_owners().size() != 0:
		errors += 1
		print("FAIL %s: %d shape owners on the roads body (roads are cut by chunk)" % [label, roads.get_shape_owners().size()])
	var single := _terrain.get_node_or_null(Meta.GENERATED_MESH_NAME) as MeshInstance3D
	if single != null and single.mesh != null and single.mesh.get_surface_count() > 0:
		errors += 1
		print("FAIL %s: the single road mesh has %d surfaces" % [label, single.mesh.get_surface_count()])
	var pieces := 0
	for c: Vector2i in _runtime._road_pieces:
		var chunk := TerrainMesher.find_chunk(_terrain, c.x, c.y)
		if chunk == null or chunk.is_queued_for_deletion():
			continue
		var piece := chunk.get_node_or_null(TerrainRuntime.ROADS_NAME) as MeshInstance3D
		if piece == null:
			errors += 1
			print("FAIL %s: chunk %s has no road piece" % [label, c])
			continue
		pieces += 1
		if piece.mesh.get_surface_count() != (_runtime._road_pieces[c] as Array).size():
			errors += 1
			print("FAIL %s: chunk %s road piece has %d surfaces" % [label, c, piece.mesh.get_surface_count()])
		if _runtime._road_faces.has(c) and _runtime._ground_shapes.has(c):
			var body := chunk.get_node(TerrainRuntime.CHUNK_COLLISION_NAME) as StaticBody3D
			var faces := 0
			for owner_id in body.get_shape_owners():
				for i in range(body.shape_owner_get_shape_count(owner_id)):
					faces += (body.shape_owner_get_shape(owner_id, i) as ConcavePolygonShape3D).get_faces().size()
			var expected: int = chunk.mesh.get_faces().size() + (_runtime._road_faces[c] as PackedVector3Array).size()
			if faces != expected:
				errors += 1
				print("FAIL %s: chunk %s collision has %d face vertices, %d expected (ground + roads)" % [label, c, faces, expected])
	if _runtime._road_pieces.is_empty():
		errors += 1
		print("FAIL %s: no road pieces (the map has tracks)" % label)
	print("%s: %d chunks with their road piece" % [label, pieces])
	var hole_count := WaterholeStyle.list(_terrain).size()
	var holes_built := 0
	var container := _terrain.get_node_or_null(String(Meta.GENERATED_WATERHOLES_NAME))
	for i in hole_count:
		var bounds := WaterholeStyle.bounds_of(_terrain, i)
		var focus := _focus()
		var distance := focus.clamp(bounds.position, bounds.end).distance_to(focus)
		var node := container.get_node_or_null("Waterhole_%d" % i) if container else null
		if node != null and node.is_queued_for_deletion():
			node = null
		if node != null:
			holes_built += 1
			var mesh_node := node as MeshInstance3D
			var expected := WaterholeMesher.build(_terrain, _carve, WaterholeStyle.list(_terrain)[i])
			var same := (mesh_node.mesh == null and expected == null) or (mesh_node.mesh != null and expected != null and _mesh_hash(mesh_node.mesh) == _mesh_hash(expected))
			if not same:
				errors += 1
				print("FAIL %s: waterhole %d differs from a main-thread build" % [label, i])
		if node == null and distance <= build_distance:
			errors += 1
			print("FAIL %s: waterhole %d missing (%.0f m)" % [label, i, distance])
		elif node != null and distance > free_distance:
			errors += 1
			print("FAIL %s: waterhole %d kept (%.0f m)" % [label, i, distance])
	_report(errors == 0, "%s: %d errors (%d of %d chunks built, %d shapes, %d of %d waterholes)" % [
		label, errors, built, _count * _count, _runtime._ground_shapes.size(), holes_built, hole_count])

func _reference_hash(c: Vector2i) -> int:
	if not _reference.has(c):
		# The runtime's chunk: build_chunk_parts, plus the skirt next to the
		# far blocks.
		var arrays := TerrainMesher.build_chunk_arrays(_terrain, _carve, c.x, c.y)
		if _runtime._far_on:
			LodMesher.add_chunk_skirt(_terrain, _carve, arrays, c.x, c.y, _runtime._far_step())
		var parts := TerrainMesher.assemble_chunk(_terrain, arrays)
		var mesh: ArrayMesh = parts["mesh"]
		_reference[c] = _mesh_hash(mesh)
	return _reference[c]

## Chunks within ground_distance (without margin) that are not built.
func _missing_near() -> int:
	var missing := 0
	for z in _count:
		for x in _count:
			if _distance(Vector2i(x, z)) <= _runtime.ground_distance and TerrainMesher.find_chunk(_terrain, x, z) == null:
				missing += 1
	return missing

## Chunks shown twice (detailed and by their far block), or not at all within
## far_distance.
func _coverage(label: String, verbose: bool) -> int:
	var errors := 0
	for z in _count:
		for x in _count:
			var chunk := TerrainMesher.find_chunk(_terrain, x, z)
			var detailed := chunk != null and not chunk.is_queued_for_deletion() and chunk.visible
			var block := Vector2i(x / LodMesher.BLOCK_CHUNKS, z / LodMesher.BLOCK_CHUNKS)
			var far := false
			if _runtime._far_blocks.has(block):
				var mask: int = _runtime._far_masks[block]
				far = (mask & LodMesher.chunk_bit(x, z)) == 0
			var shown := int(detailed) + int(far)
			var distance := _distance(Vector2i(x, z))
			if shown > 1 or (shown == 0 and distance <= _runtime.far_distance):
				errors += 1
				if verbose and errors <= 3:
					print("FAIL %s: chunk %s shown %d times (%.0f m)" % [label, Vector2i(x, z), shown, distance])
	return errors

## Visible ground meshes (detailed chunks + far blocks): draw calls and
## triangles.
func _print_draw(label: String) -> void:
	var near := [0, 0]
	for chunk in _chunks_root().get_children():
		var mesh_chunk := chunk as MeshInstance3D
		if mesh_chunk != null and mesh_chunk.visible and not mesh_chunk.is_queued_for_deletion() and mesh_chunk.mesh != null:
			near[0] += mesh_chunk.mesh.get_surface_count()
			near[1] += _triangles(mesh_chunk.mesh)
	var far := [0, 0]
	for node: MeshInstance3D in _runtime._far_blocks.values():
		if node.mesh != null:
			far[0] += 1
			far[1] += _triangles(node.mesh)
	print("%s: detailed %d draws, %d k tris | far %d draws, %d k tris" % [label, near[0], near[1] / 1000, far[0], far[1] / 1000])

static func _triangles(mesh: Mesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		total += (mesh as ArrayMesh).surface_get_array_len(surface) / 3
	return total

func _ground_under_camera() -> bool:
	var from := Vector3(_camera.global_position.x, 200.0, _camera.global_position.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 400.0)
	var space := get_root().get_world_3d().direct_space_state
	return not space.intersect_ray(query).is_empty()

static func _mesh_hash(mesh: Mesh) -> int:
	var bytes := PackedByteArray()
	for surface in mesh.get_surface_count():
		bytes.append_array(var_to_bytes(mesh.surface_get_arrays(surface)))
		var material := mesh.surface_get_material(surface)
		bytes.append_array(str(material.get_instance_id() if material else 0).to_utf8_buffer())
	return hash(bytes)

func _report(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
	print(("ok   " if ok else "FAIL ") + text)
