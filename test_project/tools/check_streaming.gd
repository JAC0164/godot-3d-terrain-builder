extends SceneTree
## Checks TerrainRuntime.stream_details on the explore map (seed 7 + one
## river, as bench/explore.gd builds it):
##   1. camera at the centre: each chunk holds exactly the layers within their
##      draw distance + stream_margin, with the same instances as a full build
##      (DetailScatter.build of the whole chunk), trunk collision only within
##      collision_distance;
##   2. teleport to a corner: the far layers are freed (past draw distance +
##      unload_margin), the near ones built;
##   3. run (10 m/s) to the opposite corner: no layer is ever missing on a
##      chunk the camera is within its draw distance of (no pop-in), and the
##      slowest frame;
##   4. load time and detail nodes compared with a full build.
##   godot --headless --path . --script res://tools/check_streaming.gd
## Prints FAIL lines and "streaming: N failures" at the end.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const RUN_SPEED := 10.0

var _failures := 0
var _terrain: Node3D
var _runtime: Node
var _camera: Camera3D
var _size := 0.0
var _count := 0
var _chunk_world := 0.0
var _radii := PackedFloat32Array()
## Vector2i -> {node name: [count, hash]} of a full build.
var _reference: Dictionary = {}

func _initialize() -> void:
	# The root enters the tree after _initialize().
	await process_frame
	var full: Dictionary = await _load(false)
	_free_world()
	var streamed: Dictionary = await _load(true)
	print("load: full %.0f ms, %d detail nodes / streamed %.0f ms (first ring), %d detail nodes" % [
		full["ms"], full["nodes"], streamed["ms"], streamed["nodes"]])
	_reference_build()
	print("map %.0f m, %d x %d chunks of %.0f m; layer radii %s" % [_size, _count, _count, _chunk_world, _radii])

	# 1. Centre.
	await _idle()
	_check("centre", true)
	print("centre: %d detail nodes, %d collision bodies" % [_detail_nodes(), _collision_bodies()])

	# 2. Teleport to a corner.
	_camera.global_position = Vector3(-_size * 0.45, 2.0, -_size * 0.45)
	await _idle()
	_check("corner", false)
	print("corner: %d detail nodes, %d collision bodies" % [_detail_nodes(), _collision_bodies()])

	# 3. Run to the opposite corner.
	var target := Vector3(_size * 0.45, 2.0, _size * 0.45)
	var worst_ms := 0.0
	var frames := 0
	var popped := 0
	# The runtime's streaming called here, timed alone (the frame time of a
	# headless run also holds whatever else the computer does).
	_runtime.set_process(false)
	var plugin_ms: Array[float] = []
	var events: Array = [0]
	_runtime.chunk_details_changed.connect(func(_x: int, _z: int) -> void: events[0] += 1)
	var slow: Array = []
	var last := Time.get_ticks_usec()
	while _camera.global_position.distance_to(target) > 0.5:
		await process_frame
		var now := Time.get_ticks_usec()
		var delta := (now - last) / 1e6
		worst_ms = maxf(worst_ms, delta * 1000.0)
		last = now
		frames += 1
		_camera.global_position = _camera.global_position.move_toward(target, RUN_SPEED * maxf(delta, 1.0 / 60.0))
		var before: Dictionary = _runtime._stream_job
		var before_text := "%s mask %d" % [before.get("chunk"), before.get("mask", 0)] if not before.is_empty() else "-"
		var queued: Array = _runtime._stream_queue.duplicate()
		events[0] = 0
		var t0 := Time.get_ticks_usec()
		_runtime._stream(delta)
		plugin_ms.append((Time.get_ticks_usec() - t0) / 1000.0)
		var after: Dictionary = _runtime._stream_job
		var next := "collision %s" % [queued[0][1]] if not queued.is_empty() and int(queued[0][2]) == 0 else "details"
		slow.append([plugin_ms[-1], frames, events[0], "job before %s, after %s, next queued %s" % [before_text, after.get("chunk", "-"), next]])
		popped += _missing_visible()
	slow.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	for i in mini(6, slow.size()):
		print("  slow frame %d: %.1f ms, %d chunk changes, %s" % [slow[i][1], slow[i][0], slow[i][2], slow[i][3]])
	_runtime.set_process(true)
	plugin_ms.sort()
	var total := 0.0
	for ms in plugin_ms:
		total += ms
	print("streaming per frame: median %.2f ms, 99%% %.2f ms, max %.2f ms, total %.0f ms" % [
		plugin_ms[plugin_ms.size() / 2], plugin_ms[int(plugin_ms.size() * 0.99)], plugin_ms[-1], total])
	_report(popped == 0, "run: %d frames, slowest frame %.1f ms, %d missing visible layer-chunk-frames" % [frames, worst_ms, popped])
	await _idle()
	_check("after run", false)

	print("streaming: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)

## Builds the explore map with or without streaming. {ms, nodes}.
func _load(stream: bool) -> Dictionary:
	var root := Node3D.new()
	root.name = "World"
	get_root().add_child(root)
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	MapGenerator.generate(_terrain, load(RECIPE), 7)
	_size = float(_terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * _size, sin(t * 5.0) * 0.12 * _size + 0.18 * _size))
	FeatureStyle.commit(_terrain, FeatureStyle.RIVER, points)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_camera = Camera3D.new()
	root.add_child(_camera)
	_camera.current = true
	_camera.global_position = Vector3(0, 2, 0)
	_runtime = TerrainRuntime.new()
	_runtime.name = String(Meta.RUNTIME_NODE_NAME)
	_runtime.build_on_ready = false
	_runtime.stream_details = stream
	_terrain.add_child(_runtime)
	var stats: Array = [{}]
	_runtime.finished.connect(func(s: Dictionary) -> void: stats[0] = s)
	_runtime.build()
	while not _runtime.is_finished:
		await process_frame
	return {"ms": float(stats[0].get("ms", 0.0)), "nodes": _detail_nodes()}

func _free_world() -> void:
	var root := get_root().get_node("World")
	get_root().remove_child(root)
	root.free()

## Full-chunk scatter of every chunk (what a full build puts there).
func _reference_build() -> void:
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(_terrain)
	var carve := builder.get_river_carve(_terrain)
	_count = TerrainMesher.chunk_count(_terrain)
	var resolution: int = int(_terrain.get_meta(Meta.RESOLUTION))
	_chunk_world = _size / float(resolution - 1) * float(Meta.TERRAIN_CHUNK_CELLS)
	_radii = DetailScatter.layer_radii(_terrain)
	for z in _count:
		for x in _count:
			var nodes := {}
			for entry in DetailScatter.build(_terrain, carve, x, z, builder.chunk_shading(_terrain, x, z)):
				if int(entry[1]) > 0:
					nodes[String(entry[0])] = [int(entry[1]), hash(entry[2])]
			_reference[Vector2i(x, z)] = nodes

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
		await process_frame

func _chunk(c: Vector2i) -> Node3D:
	return _terrain.get_node(String(Meta.GENERATED_CHUNKS_NAME)).get_node_or_null(TerrainMesher.chunk_name(c.x, c.y))

func _distance(c: Vector2i) -> float:
	var focus := Vector2(_camera.global_position.x, _camera.global_position.z)
	var lo := Vector2(c.x * _chunk_world - _size * 0.5, c.y * _chunk_world - _size * 0.5)
	return focus.clamp(lo, lo + Vector2(_chunk_world, _chunk_world)).distance_to(focus)

## Every chunk holds the layers it must (and only those, when `exact`: no
## unload margin), each with the instances of a full build.
func _check(label: String, exact: bool) -> void:
	var errors := 0
	for c: Vector2i in _reference:
		var chunk := _chunk(c)
		var distance := _distance(c)
		var reference: Dictionary = _reference[c]
		for node_name: String in reference:
			var index := DetailScatter.node_layer_index(node_name)
			var radius := _radii[index]
			var node := chunk.get_node_or_null(node_name) as MultiMeshInstance3D
			var must := distance <= radius + float(_runtime.stream_margin)
			# Exact: up to the layers built along with the wanted ones.
			var prefetch := (float(_runtime.stream_margin) + float(_runtime.unload_margin)) * 0.5
			var may := distance <= radius + (prefetch if exact else float(_runtime.unload_margin))
			if must and node == null:
				errors += 1
				if errors <= 5:
					print("FAIL %s: %s missing on chunk %s (%.0f m, radius %.0f)" % [label, node_name, c, distance, radius])
			elif node != null and not may:
				errors += 1
				if errors <= 5:
					print("FAIL %s: %s kept on chunk %s (%.0f m, radius %.0f)" % [label, node_name, c, distance, radius])
			elif node != null:
				var expected: Array = reference[node_name]
				var buffer := node.multimesh.buffer
				if node.multimesh.instance_count != expected[0] or (not buffer.is_empty() and hash(buffer) != expected[1]):
					errors += 1
					if errors <= 5:
						print("FAIL %s: %s on chunk %s differs from a full build" % [label, node_name, c])
		for child in chunk.get_children():
			if String(child.name).begins_with(DetailScatter.NODE_PREFIX) and not reference.has(String(child.name)):
				errors += 1
				print("FAIL %s: unexpected %s on chunk %s" % [label, child.name, c])
		var body := chunk.get_node_or_null(String(Meta.DETAIL_COLLISION_NAME))
		var collision_far := float(_runtime.collision_distance) + (0.0 if exact else float(_runtime.unload_margin))
		if body != null and distance > collision_far:
			errors += 1
			print("FAIL %s: collision kept on chunk %s (%.0f m)" % [label, c, distance])
		if body == null and distance <= float(_runtime.collision_distance) and _has_collision_layer(reference):
			errors += 1
			print("FAIL %s: collision missing on chunk %s (%.0f m)" % [label, c, distance])
	_report(errors == 0, "%s: %d errors" % [label, errors])

func _has_collision_layer(reference: Dictionary) -> bool:
	var biome: Resource = DetailScatter.biome_of(_terrain)
	for node_name: String in reference:
		var layer: Resource = biome.detail_layers[DetailScatter.node_layer_index(node_name) - 1]
		if float(layer.collision_radius) > 0.0:
			return true
	return false

## Layers missing on a chunk the camera is within draw distance of.
func _missing_visible() -> int:
	var missing := 0
	for c: Vector2i in _reference:
		var distance := _distance(c)
		var chunk := _chunk(c)
		for node_name: String in _reference[c]:
			if distance <= _radii[DetailScatter.node_layer_index(node_name)] and chunk.get_node_or_null(node_name) == null:
				missing += 1
	return missing

func _detail_nodes() -> int:
	var total := 0
	for chunk in _terrain.get_node(String(Meta.GENERATED_CHUNKS_NAME)).get_children():
		for child in chunk.get_children():
			if String(child.name).begins_with(DetailScatter.NODE_PREFIX):
				total += 1
	return total

func _collision_bodies() -> int:
	var total := 0
	for chunk in _terrain.get_node(String(Meta.GENERATED_CHUNKS_NAME)).get_children():
		if chunk.get_node_or_null(String(Meta.DETAIL_COLLISION_NAME)) != null:
			total += 1
	return total

func _report(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
	print(("ok   " if ok else "FAIL ") + text)
