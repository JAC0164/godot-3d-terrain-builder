extends SceneTree
## Memory audit of the open world as the game streams it (seed 7, game
## settings of bench/big_world_bench.gd REFERENCE), standing at the map
## centre once the runtime is finished:
##   - Performance monitors (static RAM, video, buffers, textures, objects)
##     before the map, after generation, after the build;
##   - GPU vertex/index bytes of every mesh, by node kind (digits in node
##     names folded), from the real surface formats (RenderingServer strides);
##   - MultiMesh buffers (instances x stride), shared detail meshes once;
##   - collision faces, runtime caches (bytes of their packed arrays);
##   - experiments: one ground chunk re-uploaded with
##     ARRAY_FLAG_COMPRESS_ATTRIBUTES (stride + max position error), and the
##     static RAM of 64 trimesh vs height map collision bodies.
## Needs a real renderer (video memory): an off-screen window.
##   Godot --path . --position -3000,-3000 --script res://tools/profile_memory.gd [-- --noshadow]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"

var _rows: Dictionary = {}

func _mb(bytes: float) -> String:
	return "%.2f Mo" % (bytes / 1048576.0)

func _monitors(label: String) -> Dictionary:
	var m := {
		"static": Performance.get_monitor(Performance.MEMORY_STATIC),
		"video": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		"buffers": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED),
		"textures": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
	}
	print("MON %-12s static %s | video %s (buffers %s, textures %s) | objects %d, resources %d, nodes %d" % [
		label, _mb(m["static"]), _mb(m["video"]), _mb(m["buffers"]), _mb(m["textures"]),
		m["objects"], m["resources"], m["nodes"]])
	return m

func _kind(node: Node) -> String:
	var regex := RegEx.create_from_string("[0-9]+")
	return regex.sub(String(node.name), "#", true)

## GPU bytes of a mesh: [vertex bytes, index bytes, vertices, indices].
func _mesh_bytes(mesh: Mesh) -> Array:
	var array_mesh := mesh as ArrayMesh
	if array_mesh == null:
		return [0, 0, 0, 0]
	var vb := 0
	var ib := 0
	var vertices := 0
	var indices := 0
	for s in array_mesh.get_surface_count():
		var format := array_mesh.surface_get_format(s)
		var count := array_mesh.surface_get_array_len(s)
		var index_count := array_mesh.surface_get_array_index_len(s)
		vb += (RenderingServer.mesh_surface_get_format_vertex_stride(format, count)
			+ RenderingServer.mesh_surface_get_format_normal_tangent_stride(format, count)
			+ RenderingServer.mesh_surface_get_format_attribute_stride(format, count)) * count
		ib += index_count * (2 if count <= 65535 else 4)
		vertices += count
		indices += index_count
	return [vb, ib, vertices, indices]

func _add(kind: String, bytes: float, count: int = 1, extra := "") -> void:
	var row: Array = _rows.get(kind, [0.0, 0, ""])
	row[0] = float(row[0]) + bytes
	row[1] = int(row[1]) + count
	if extra != "":
		row[2] = extra
	_rows[kind] = row

func _walk(node: Node, seen_meshes: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			var b := _mesh_bytes(mesh)
			_add("mesh " + _kind(node), b[0] + b[1], 1, "%d sommets, %d index" % [b[2], b[3]])
			_add("_sommets " + _kind(node), b[2])
	elif node is MultiMeshInstance3D:
		var mm := (node as MultiMeshInstance3D).multimesh
		if mm != null:
			var floats := (12 if mm.transform_format == MultiMesh.TRANSFORM_3D else 8) + (4 if mm.use_colors else 0) + (4 if mm.use_custom_data else 0)
			_add("multimesh " + _kind(node), mm.instance_count * floats * 4.0, 1, "%d o/instance" % (floats * 4))
			_add("_instances " + _kind(node), mm.instance_count)
			if mm.mesh != null and not seen_meshes.has(mm.mesh.get_rid()):
				seen_meshes[mm.mesh.get_rid()] = true
				var b := _mesh_bytes(mm.mesh)
				_add("mesh partagé détails", b[0] + b[1], 1)
	elif node is CollisionObject3D:
		var body := node as CollisionObject3D
		for owner_id in body.get_shape_owners():
			for i in body.shape_owner_get_shape_count(owner_id):
				var shape := body.shape_owner_get_shape(owner_id, i)
				if shape is ConcavePolygonShape3D:
					var faces := (shape as ConcavePolygonShape3D).get_faces().size()
					_add("collision trimesh " + _kind(node), faces * 12.0, 1, "copie Godot des faces")
					_add("_triangles collision " + _kind(node), faces / 3)
				elif shape != null:
					_add("collision " + shape.get_class() + " " + _kind(node), 0.0, 1)
	for child in node.get_children():
		_walk(child, seen_meshes)

## Bytes held by packed arrays inside a Variant (dictionaries, arrays).
func _packed_bytes(value: Variant) -> int:
	match typeof(value):
		TYPE_PACKED_VECTOR3_ARRAY:
			return (value as PackedVector3Array).size() * 12
		TYPE_PACKED_VECTOR2_ARRAY:
			return (value as PackedVector2Array).size() * 8
		TYPE_PACKED_FLOAT32_ARRAY:
			return (value as PackedFloat32Array).size() * 4
		TYPE_PACKED_FLOAT64_ARRAY:
			return (value as PackedFloat64Array).size() * 8
		TYPE_PACKED_INT32_ARRAY:
			return (value as PackedInt32Array).size() * 4
		TYPE_PACKED_INT64_ARRAY:
			return (value as PackedInt64Array).size() * 8
		TYPE_PACKED_BYTE_ARRAY:
			return (value as PackedByteArray).size()
		TYPE_PACKED_COLOR_ARRAY:
			return (value as PackedColorArray).size() * 16
		TYPE_DICTIONARY:
			var total := 0
			var dict: Dictionary = value
			for key: Variant in dict:
				total += _packed_bytes(dict[key])
			return total
		TYPE_ARRAY:
			var total := 0
			for item: Variant in (value as Array):
				total += _packed_bytes(item)
			return total
	return 0

func _initialize() -> void:
	_run.call_deferred()

func _frames(n: int) -> void:
	for i in n:
		await process_frame

func _run() -> void:
	await _frames(10)
	var m0 := _monitors("vide")
	var level := Node3D.new()
	level.name = "Level"
	root.add_child(level)
	var sky := (load("res://world/open_world_sky.tscn") as PackedScene).instantiate()
	if OS.get_cmdline_user_args().has("--noshadow"):
		for light in sky.find_children("*", "DirectionalLight3D", true, false):
			(light as DirectionalLight3D).shadow_enabled = false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--radiance="):
			for env_node in sky.find_children("*", "WorldEnvironment", true, false):
				var env := (env_node as WorldEnvironment).environment
				if env.sky != null:
					env.sky.radiance_size = int(arg.substr(11)) as Sky.RadianceSize
	level.add_child(sky)
	await _frames(10)
	var m1 := _monitors("ciel")
	if OS.get_cmdline_user_args().has("--sky-only"):
		var cam := Camera3D.new()
		level.add_child(cam)
		cam.current = true
		await _frames(30)
		_monitors("ciel+caméra")
		quit(0)
		return

	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	await _frames(5)
	var m2 := _monitors("carte")
	var data_bytes := 0
	for key in terrain.get_meta_list():
		var b := _packed_bytes(terrain.get_meta(key))
		if b > 65536:
			print("  DATA %-40s %s" % [key, _mb(b)])
		data_bytes += b
	print("  DATA total tableaux %s" % _mb(data_bytes))

	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	var camera := Camera3D.new()
	camera.far = 800.0
	level.add_child(camera)
	var spawn := Vector3(0.0, TerrainSampler.uncarved_height(terrain, Vector2.ZERO) + 1.7, 0.0)
	camera.transform = Transform3D(Basis(), spawn).looking_at(spawn + Vector3(1, -0.1, 1))
	camera.current = true
	await _frames(30)
	var mc := _monitors("caméra")
	var runtime := TerrainRuntime.new()
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	runtime.stream_ground = true
	runtime.stream_details = true
	runtime.ground_distance = 160.0
	runtime.far_distance = 600.0
	runtime.far_step = 4
	runtime.ground_threads = true
	terrain.add_child(runtime)
	level.add_child(terrain)
	var t := Time.get_ticks_msec()
	var frames := 0
	while (not runtime.is_finished or not runtime.is_streaming_idle) and frames < 20000:
		await process_frame
		frames += 1
	print("build fini: %d images, %.1f s" % [frames, (Time.get_ticks_msec() - t) / 1000.0])
	await _frames(30)
	var m3 := _monitors("construit")
	var vp := root.get_viewport_rid()
	for pass_name: String in ["visible", "shadow"]:
		var type := RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE if pass_name == "visible" else RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW
		print("RENDER %-8s draws %d, objets %d, primitives %d" % [pass_name,
			RenderingServer.viewport_get_render_info(vp, type, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
			RenderingServer.viewport_get_render_info(vp, type, RenderingServer.VIEWPORT_RENDER_INFO_OBJECTS_IN_FRAME),
			RenderingServer.viewport_get_render_info(vp, type, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)])
	print("DELTA caméra (buffers de rendu + ombres, sans terrain): video %s, textures %s" % [_mb(mc["video"] - m2["video"]), _mb(mc["textures"] - m2["textures"])])
	print("DELTA carte: static %s | construit: static %s, video %s, buffers %s" % [
		_mb(m2["static"] - m1["static"]), _mb(m3["static"] - m2["static"]),
		_mb(m3["video"] - m2["video"]), _mb(m3["buffers"] - m2["buffers"])])

	_walk(terrain, {})
	var keys := _rows.keys()
	keys.sort()
	var gpu_total := 0.0
	for key: String in keys:
		var row: Array = _rows[key]
		if key.begins_with("_"):
			print("  COUNT %-40s %d" % [key.substr(1), row[0]])
		else:
			print("  ROW %-40s %s  (%d noeuds) %s" % [key, _mb(row[0]), row[1], row[2]])
			if not key.begins_with("collision"):
				gpu_total += float(row[0])
	print("  ROW total GPU calculé %s" % _mb(gpu_total))

	for name: String in ["_chunk_face_cache", "_shading_cache", "_road_pieces", "_road_faces", "_far_data", "_shape_cache", "_ground_carve"]:
		print("  CACHE %-20s %s (%d entrées)" % [name, _mb(_packed_bytes(runtime.get(name))),
			(runtime.get(name) as Dictionary).size() if runtime.get(name) is Dictionary else 0])
	var builder: Variant = runtime.get("_builder")
	if builder != null:
		for prop in (builder as Object).get_property_list():
			var value: Variant = (builder as Object).get(prop["name"])
			var b := _packed_bytes(value)
			if b > 65536:
				print("  BUILDER %-20s %s" % [prop["name"], _mb(b)])

	# Seams between neighbouring chunks (compressed vertices are rounded in
	# each chunk's own box): the same corner, read back from both meshes.
	_seams(terrain)

	# Attribution: static RAM freed by dropping each part (the runtime is
	# stopped first so it rebuilds nothing).
	runtime.set_process(false)
	runtime.set_physics_process(false)
	var parts := {
		"caches routes (_road_pieces + _road_faces)": func() -> void:
			runtime.set("_road_pieces", {})
			runtime.set("_road_faces", {}),
		"cache faces chunks (_chunk_face_cache)": func() -> void:
			runtime.set("_chunk_face_cache", {}),
		"cache ombrage (_shading_cache)": func() -> void:
			runtime.set("_shading_cache", {}),
		"données lointaines (_far_data)": func() -> void:
			runtime.set("_far_data", {}),
		"collisions du sol (corps)": func() -> void:
			var shapes: Dictionary = runtime.get("_ground_shapes")
			for body: Node in shapes.values():
				if is_instance_valid(body):
					body.free()
			shapes.clear(),
	}
	for label: String in parts:
		await _frames(5)
		var before := Performance.get_monitor(Performance.MEMORY_STATIC)
		(parts[label] as Callable).call()
		await _frames(5)
		print("FREE %-45s -%s" % [label, _mb(before - Performance.get_monitor(Performance.MEMORY_STATIC))])

	_compress_experiment(terrain)
	await _collision_experiment(level)
	quit(0)

## Largest gap between the copies of a ground corner in the meshes of the
## chunks that share it (read back from the GPU: compressed as drawn).
func _seams(terrain: Node3D) -> void:
	var corners := {}
	var worst := 0.0
	var shared := 0
	var stack: Array[Node] = [terrain]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if not (node is MeshInstance3D and String(node.name).begins_with("Chunk")):
			continue
		var mesh := (node as MeshInstance3D).mesh as ArrayMesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var seen := {}
			for p: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				# Top corners on the grid (1.5 m), not the skirts below.
				var key := Vector2i(roundi(p.x / 1.5 * 100.0), roundi(p.z / 1.5 * 100.0))
				if key.x % 100 != 0 or key.y % 100 != 0 or seen.has(key):
					continue
				seen[key] = true
				if corners.has(key):
					var other: Array = corners[key]
					if other[1] != node:
						var q: Vector3 = other[0]
						if absf(q.y - p.y) < 0.5:
							worst = maxf(worst, q.distance_to(p))
							shared += 1
				else:
					corners[key] = [p, node]
	print("SEAM %d coins partagés entre chunks, écart max %.2f mm" % [shared, worst * 1000.0])

## One ground chunk mesh re-uploaded with ARRAY_FLAG_COMPRESS_ATTRIBUTES.
func _compress_experiment(terrain: Node3D) -> void:
	var source: ArrayMesh = null
	var stack: Array[Node] = [terrain]
	while not stack.is_empty() and source == null:
		var node: Node = stack.pop_back()
		if node is MeshInstance3D and String(node.name).begins_with("Chunk") and (node as MeshInstance3D).mesh is ArrayMesh:
			var candidate := (node as MeshInstance3D).mesh as ArrayMesh
			if candidate.get_surface_count() > 0 and candidate.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR:
				source = candidate
		stack.append_array(node.get_children())
	if source == null:
		print("COMPRESS no chunk mesh found")
		return
	var before := _mesh_bytes(source)
	var packed := ArrayMesh.new()
	var max_error := 0.0
	var normal_error := 0.0
	for s in source.get_surface_count():
		var arrays := source.surface_get_arrays(s)
		# Compression wants normals WITH tangents (or neither): any vector
		# across the normal.
		var tangent_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var tangents := PackedFloat32Array()
		tangents.resize(tangent_normals.size() * 4)
		for i in tangent_normals.size():
			var n := tangent_normals[i]
			var t := (n.cross(Vector3.FORWARD) if absf(n.z) < 0.9 else n.cross(Vector3.RIGHT)).normalized()
			tangents[i * 4] = t.x
			tangents[i * 4 + 1] = t.y
			tangents[i * 4 + 2] = t.z
			tangents[i * 4 + 3] = 1.0
		arrays[Mesh.ARRAY_TANGENT] = tangents
		packed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES)
		var back := packed.surface_get_arrays(s)
		var a: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var c: PackedVector3Array = back[Mesh.ARRAY_VERTEX]
		var na: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var nc: PackedVector3Array = back[Mesh.ARRAY_NORMAL]
		var bad := 0
		for i in a.size():
			max_error = maxf(max_error, a[i].distance_to(c[i]))
			if i < na.size() and i < nc.size():
				var e := rad_to_deg(na[i].angle_to(nc[i]))
				normal_error = maxf(normal_error, e)
				if e > 1.0:
					bad += 1
					if bad <= 3:
						print("COMPRESS normale %s -> %s" % [na[i], nc[i]])
		print("COMPRESS sommets avec normale > 1 deg: %d / %d" % [bad, a.size()])
		print("COMPRESS surface %d format %d -> %d, stride %d -> %d o/sommet" % [s,
			source.surface_get_format(s), packed.surface_get_format(s),
			(RenderingServer.mesh_surface_get_format_vertex_stride(source.surface_get_format(s), a.size())
				+ RenderingServer.mesh_surface_get_format_normal_tangent_stride(source.surface_get_format(s), a.size())
				+ RenderingServer.mesh_surface_get_format_attribute_stride(source.surface_get_format(s), a.size())),
			(RenderingServer.mesh_surface_get_format_vertex_stride(packed.surface_get_format(s), a.size())
				+ RenderingServer.mesh_surface_get_format_normal_tangent_stride(packed.surface_get_format(s), a.size())
				+ RenderingServer.mesh_surface_get_format_attribute_stride(packed.surface_get_format(s), a.size()))])
	var after := _mesh_bytes(packed)
	print("COMPRESS chunk %s -> %s, erreur position max %.2f mm, normale max %.3f deg, AABB %s" % [
		_mb(before[0]), _mb(after[0]), max_error * 1000.0, normal_error, source.get_aabb().size])

## Static RAM of 64 collision bodies: one chunk's trimesh vs a 33 x 33 height map.
func _collision_experiment(level: Node3D) -> void:
	var faces := PackedVector3Array()
	var heights := PackedFloat32Array()
	heights.resize(33 * 33)
	for z in 33:
		for x in 33:
			heights[z * 33 + x] = sin(x * 0.3) * cos(z * 0.2) * 3.0
	for z in 32:
		for x in 32:
			var p00 := Vector3(x * 1.5, heights[z * 33 + x], z * 1.5)
			var p10 := Vector3((x + 1) * 1.5, heights[z * 33 + x + 1], z * 1.5)
			var p01 := Vector3(x * 1.5, heights[(z + 1) * 33 + x], (z + 1) * 1.5)
			var p11 := Vector3((x + 1) * 1.5, heights[(z + 1) * 33 + x + 1], (z + 1) * 1.5)
			faces.append_array([p00, p10, p11, p00, p11, p01])
	for kind in ["trimesh", "heightmap"]:
		await _frames(5)
		var before := Performance.get_monitor(Performance.MEMORY_STATIC)
		var bodies: Array[StaticBody3D] = []
		var t := Time.get_ticks_usec()
		for i in 64:
			var body := StaticBody3D.new()
			body.name = "Probe%d" % i
			var shape_node := CollisionShape3D.new()
			shape_node.name = "Shape"
			if kind == "trimesh":
				var shape := ConcavePolygonShape3D.new()
				shape.set_faces(faces)
				shape_node.shape = shape
			else:
				var shape := HeightMapShape3D.new()
				shape.map_width = 33
				shape.map_depth = 33
				shape.map_data = heights
				shape_node.shape = shape
				shape_node.scale = Vector3(1.5, 1.0, 1.5)
			body.add_child(shape_node)
			body.position = Vector3(5000 + i * 60, 0, 5000)
			level.add_child(body)
			bodies.append(body)
		var build_ms := (Time.get_ticks_usec() - t) / 1000.0
		await _frames(5)
		var after := Performance.get_monitor(Performance.MEMORY_STATIC)
		print("COLLISION %-9s 64 corps: +%s RAM (%.0f Ko par chunk), %.1f ms" % [kind, _mb(after - before), (after - before) / 64.0 / 1024.0, build_ms])
		for body in bodies:
			body.free()
