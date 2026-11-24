@tool
extends RefCounted
## Combines all committed roads and rivers into a single ArrayMesh.

const Meta = preload("../core/terrain_meta.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const MeshUtils = preload("mesh_utils.gd")
const RoadMesher = preload("road_mesher.gd")
const RiverMesher = preload("river_mesher.gd")
const FeatureRibbon = preload("feature_ribbon.gd")
const TerrainMesher = preload("terrain_mesher.gd")

## Returns {"mesh": ArrayMesh, "collision_faces": PackedVector3Array}. Collision
## faces only include roads/rivers whose "collision" flag is set.
static func build(terrain: Node3D, carve: PackedFloat32Array) -> Dictionary:
	var job := start(terrain, carve)
	step(job)
	return finish(job)

## build() in slices, so a game can spread it over several frames
## (TerrainRuntime): job := start(), then step(job, budget) until it returns
## true, then finish(job). Same mesh however it is sliced. One surface per
## connected road group (big networks are triangulated a few thousand cells
## per slice, RoadMesher.union_step), then one per connected river group
## (RiverMesher.water_step).
static func start(terrain: Node3D, carve: PackedFloat32Array) -> Dictionary:
	var tasks: Array = []
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	if not roads.is_empty():
		for road_group_variant: Variant in RoadMesher.group_connected(roads):
			var road_group: Array = road_group_variant
			if not road_group.is_empty():
				tasks.append([FeatureStyle.ROAD, road_group])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	if not rivers.is_empty():
		# Only rivers whose footprints touch are merged. Each disconnected water
		# body keeps the style of its first river, so separate rivers can have
		# different colours/textures while confluences remain one mesh.
		for river_group_variant: Variant in RiverMesher.group_connected(terrain, rivers):
			var river_group: Array = river_group_variant
			if not river_group.is_empty():
				tasks.append([FeatureStyle.RIVER, river_group])
	return {"terrain": terrain, "carve": carve, "tasks": tasks, "index": 0, "union": null,
		"mesh": ArrayMesh.new(), "collision_faces": PackedVector3Array()}

## start() with each group's geometry computed on a worker thread (on a
## TerrainMesher.thread_snapshot() of the terrain), all groups at once; step()
## then only adds the finished groups' surfaces, in order: same mesh as
## start(). For big maps (TerrainRuntime stream_ground): ~1 s of work on a
## laptop for a 1.5 km open world, ~5 s on a phone. A job still running when
## its terrain goes must be given to wait_threads().
## `split`: no mesh; each group's triangles are cut by the ground chunk under
## their centre (on the worker too), and step() fills job["chunks"]
## {chunk index (z * chunks + x): Array of [material, vertices, normals,
## uvs]} and job["chunk_faces"] {chunk index: collision faces}; a streamed
## game puts each piece under its chunk (TerrainRuntime). Same triangles as
## the mesh, in the same order within a chunk.
static func start_threaded(terrain: Node3D, carve: PackedFloat32Array, split: bool = false) -> Dictionary:
	var job := start(terrain, carve)
	var grid := chunk_grid(terrain) if split else Vector3.ZERO
	if split:
		job["chunks"] = {}
		job["chunk_faces"] = {}
	var threads: Array = []
	for task: Array in job["tasks"]:
		var is_road: bool = task[0] == FeatureStyle.ROAD
		var group: Array = task[1]
		var snapshot := TerrainMesher.thread_snapshot(terrain)
		var result: Array = [{}]
		var work := func() -> void:
			if is_road:
				var road_union := RoadMesher.union_begin(snapshot, carve, group)
				RoadMesher.union_step(road_union)
				result[0] = _packed(RoadMesher.union_result(road_union))
			else:
				var water := RiverMesher.water_begin(snapshot, carve, group)
				RiverMesher.water_step(water)
				result[0] = _packed(RiverMesher.water_result(water))
			if split:
				var whole: Dictionary = result[0]
				result[0] = _split(whole, is_road, grid)
		# High priority: low priority tasks only get a few of the threads.
		var task_id := WorkerThreadPool.add_task(work, true)
		threads.append([task_id, result, snapshot])
	job["threads"] = threads
	return job

## Waits for the worker threads of a start_threaded() job and frees their
## snapshots (nothing else is done with the job).
static func wait_threads(job: Dictionary) -> void:
	var threads: Array = job.get("threads", [])
	for entry: Array in threads:
		var task_id: int = entry[0]
		if task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(task_id)
			var snapshot: Node3D = entry[2]
			snapshot.free()
			entry[0] = -1

## Does the next part of start()'s job; `budget_usec` > 0 returns after about
## that long (0 = everything). True when the whole mesh is built.
static func step(job: Dictionary, budget_usec: int = 0) -> bool:
	var started := Time.get_ticks_usec()
	if job.has("threads"):
		return _step_threaded(job, budget_usec, started)
	var terrain: Node3D = job["terrain"]
	var carve: PackedFloat32Array = job["carve"]
	var tasks: Array = job["tasks"]
	var array_mesh: ArrayMesh = job["mesh"]
	var collision_faces: PackedVector3Array = job["collision_faces"]
	while job["index"] < tasks.size():
		var task: Array = tasks[job["index"]]
		var feature_type: String = task[0]
		var is_road := feature_type == FeatureStyle.ROAD
		var group: Array = task[1]
		if job["union"] == null:
			# Starting a group (rasterizing it, ~5-15 ms) takes a fresh slice.
			if budget_usec > 0 and Time.get_ticks_usec() - started >= budget_usec / 4:
				return false
			job["union"] = RoadMesher.union_begin(terrain, carve, group) if is_road 				else RiverMesher.water_begin(terrain, carve, group)
		var union: Dictionary = job["union"]
		var left := budget_usec - (Time.get_ticks_usec() - started) if budget_usec > 0 else 0
		if budget_usec > 0 and left <= 0:
			return false
		var group_done: bool = RoadMesher.union_step(union, left) if is_road 			else RiverMesher.water_step(union, left)
		if not group_done:
			return false
		# The surface upload of a big network gets a slice of its own.
		if budget_usec > 0 and Time.get_ticks_usec() - started >= budget_usec / 2:
			return false
		var geometry: Dictionary = RoadMesher.union_result(union) if is_road 			else RiverMesher.water_result(union)
		job["union"] = null
		_add_group(terrain, array_mesh, collision_faces, feature_type, group, geometry)
		var done_index: int = job["index"]
		job["index"] = done_index + 1
		if budget_usec > 0 and Time.get_ticks_usec() - started >= budget_usec and job["index"] < tasks.size():
			return false
	return true

## step() of a start_threaded() job: the finished groups' surfaces, in order.
static func _step_threaded(job: Dictionary, budget_usec: int, started: int) -> bool:
	var terrain: Node3D = job["terrain"]
	var tasks: Array = job["tasks"]
	var threads: Array = job["threads"]
	while job["index"] < tasks.size():
		var index: int = job["index"]
		var entry: Array = threads[index]
		var task_id: int = entry[0]
		if budget_usec > 0 and not WorkerThreadPool.is_task_completed(task_id):
			return false
		WorkerThreadPool.wait_for_task_completion(task_id)
		var snapshot: Node3D = entry[2]
		snapshot.free()
		entry[0] = -1
		var task: Array = tasks[index]
		var feature_type: String = task[0]
		var group: Array = task[1]
		var result: Array = entry[1]
		var geometry: Dictionary = result[0]
		if job.has("chunks"):
			_add_split_group(terrain, job, feature_type, group, geometry)
		else:
			var array_mesh: ArrayMesh = job["mesh"]
			var collision_faces: PackedVector3Array = job["collision_faces"]
			_add_packed_group(terrain, array_mesh, collision_faces, feature_type, group, geometry)
		# Its arrays are in the mesh now (~100 MB of Variant arrays in all
		# for a 1.5 km world).
		result[0] = {}
		job["index"] = index + 1
		if budget_usec > 0 and Time.get_ticks_usec() - started >= budget_usec and job["index"] < tasks.size():
			return false
	return true

## A group's geometry as packed arrays (done on the worker: ~100 ms for the
## biggest road network of a 1.5 km world).
static func _packed(geometry: Dictionary) -> Dictionary:
	var vertices: Array = geometry["vertices"]
	var normals: Array = geometry["normals"]
	var uvs: Array = geometry["uvs"]
	var packed := {"vertices": PackedVector3Array(vertices), "normals": PackedVector3Array(normals),
		"uvs": PackedVector2Array(uvs) if uvs.size() == vertices.size() else PackedVector2Array()}
	if geometry.has("collision_vertices"):
		var collision: Array = geometry["collision_vertices"]
		packed["collision_vertices"] = PackedVector3Array(collision)
	return packed

## (half the map's side, a chunk's side, chunks per side) of a terrain.
static func chunk_grid(terrain: Node3D) -> Vector3:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var cells := maxi(resolution - 1, 1)
	return Vector3(world_size * 0.5, world_size / float(cells) * float(Meta.TERRAIN_CHUNK_CELLS),
		TerrainMesher.chunk_count(terrain))

## _packed() geometry cut by chunk: {"pieces": {chunk index: [vertices,
## normals, uvs]}, "faces": {chunk index: collision faces}} (faces only of
## what collides: a road's surface, a river's bed).
static func _split(geometry: Dictionary, is_road: bool, grid: Vector3) -> Dictionary:
	var vertices: PackedVector3Array = geometry["vertices"]
	var normals: PackedVector3Array = geometry["normals"]
	var uvs: PackedVector2Array = geometry["uvs"]
	var pieces := {}
	var by_chunk := _chunk_triangles(vertices, grid)
	for index: int in by_chunk:
		var triangles: PackedInt32Array = by_chunk[index]
		pieces[index] = [_pick(vertices, triangles), _pick(normals, triangles),
			_pick_uvs(uvs, triangles) if not uvs.is_empty() else PackedVector2Array()]
	var faces := {}
	if is_road:
		for index: int in pieces:
			var piece: Array = pieces[index]
			faces[index] = piece[0]
	elif geometry.has("collision_vertices"):
		var bed: PackedVector3Array = geometry["collision_vertices"]
		var bed_by_chunk := _chunk_triangles(bed, grid)
		for index: int in bed_by_chunk:
			var bed_triangles: PackedInt32Array = bed_by_chunk[index]
			faces[index] = _pick(bed, bed_triangles)
	return {"pieces": pieces, "faces": faces}

## {chunk index: indices of the triangles whose centre is over that chunk,
## in order} (a counting sort: one pass to count, one to place).
static func _chunk_triangles(vertices: PackedVector3Array, grid: Vector3) -> Dictionary:
	var half := grid.x
	var chunk_world := grid.y
	var count := int(grid.z)
	var triangle_count := vertices.size() / 3
	var ids := PackedInt32Array()
	ids.resize(triangle_count)
	var sizes := PackedInt32Array()
	sizes.resize(count * count)
	for t in range(triangle_count):
		var centre := (vertices[t * 3] + vertices[t * 3 + 1] + vertices[t * 3 + 2]) / 3.0
		var x := clampi(floori((centre.x + half) / chunk_world), 0, count - 1)
		var z := clampi(floori((centre.z + half) / chunk_world), 0, count - 1)
		var id := z * count + x
		ids[t] = id
		sizes[id] += 1
	var starts := PackedInt32Array()
	starts.resize(sizes.size() + 1)
	for id in range(sizes.size()):
		starts[id + 1] = starts[id] + sizes[id]
	var sorted := PackedInt32Array()
	sorted.resize(triangle_count)
	var next := starts.duplicate()
	for t in range(triangle_count):
		var id := ids[t]
		sorted[next[id]] = t
		next[id] += 1
	var out := {}
	for id in range(sizes.size()):
		if sizes[id] > 0:
			out[id] = sorted.slice(starts[id], starts[id + 1])
	return out

static func _pick(values: PackedVector3Array, triangles: PackedInt32Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(triangles.size() * 3)
	var i := 0
	for t in triangles:
		out[i] = values[t * 3]
		out[i + 1] = values[t * 3 + 1]
		out[i + 2] = values[t * 3 + 2]
		i += 3
	return out

static func _pick_uvs(values: PackedVector2Array, triangles: PackedInt32Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(triangles.size() * 3)
	var i := 0
	for t in triangles:
		out[i] = values[t * 3]
		out[i + 1] = values[t * 3 + 1]
		out[i + 2] = values[t * 3 + 2]
		i += 3
	return out

## A _split() group added to a split job (main thread): its material made
## once, its pieces and collision faces appended per chunk.
static func _add_split_group(terrain: Node3D, job: Dictionary, feature_type: String, group: Array, geometry: Dictionary) -> void:
	var is_road := feature_type == FeatureStyle.ROAD
	var representative: Dictionary = FeatureStyle.migrate(group[0], feature_type)
	var material: Material = MaterialFactory.road_material(terrain, representative) if is_road \
		else MaterialFactory.river_material(representative, Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false))
	var chunks: Dictionary = job["chunks"]
	var pieces: Dictionary = geometry["pieces"]
	for index: int in pieces:
		var piece: Array = pieces[index]
		var list: Array = chunks.get(index, [])
		list.append([material, piece[0], piece[1], piece[2]])
		chunks[index] = list
	if _any_collision(group, feature_type, is_road):
		var chunk_faces: Dictionary = job["chunk_faces"]
		var faces: Dictionary = geometry["faces"]
		for index: int in faces:
			var add: PackedVector3Array = faces[index]
			var all: PackedVector3Array = chunk_faces.get(index, PackedVector3Array())
			all.append_array(add)
			chunk_faces[index] = all

## _add_group() from _packed() geometry (no conversion on the main thread).
static func _add_packed_group(terrain: Node3D, array_mesh: ArrayMesh, collision_faces: PackedVector3Array,
		feature_type: String, group: Array, geometry: Dictionary) -> void:
	var is_road := feature_type == FeatureStyle.ROAD
	var representative: Dictionary = FeatureStyle.migrate(group[0], feature_type)
	var material: Material = MaterialFactory.road_material(terrain, representative) if is_road 		else MaterialFactory.river_material(representative, Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false))
	var vertices: PackedVector3Array = geometry["vertices"]
	var normals: PackedVector3Array = geometry["normals"]
	var uvs: PackedVector2Array = geometry["uvs"]
	MeshUtils.add_packed_surface(array_mesh, vertices, normals, material, uvs)
	if _any_collision(group, feature_type, is_road):
		var faces: PackedVector3Array = geometry["vertices" if is_road else "collision_vertices"]
		collision_faces.append_array(faces)

## Adds the surface of a finished road / river group, styled after its first
## feature, and its collision when one of its features has it (roads collide
## on their surface, rivers on their bed).
static func _add_group(terrain: Node3D, array_mesh: ArrayMesh, collision_faces: PackedVector3Array,
		feature_type: String, group: Array, geometry: Dictionary) -> void:
	var is_road := feature_type == FeatureStyle.ROAD
	var representative: Dictionary = FeatureStyle.migrate(group[0], feature_type)
	var material: Material = MaterialFactory.road_material(terrain, representative) if is_road 		else MaterialFactory.river_material(representative, Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false))
	var vertices: Array = geometry["vertices"]
	var normals: Array = geometry["normals"]
	var uvs: Array = geometry["uvs"]
	MeshUtils.add_surface(array_mesh, vertices, normals, material, uvs)
	if _any_collision(group, feature_type, is_road):
		var faces: Array = geometry["vertices" if is_road else "collision_vertices"]
		collision_faces.append_array(PackedVector3Array(faces))

## build() reusing `cache` (a Dictionary the caller keeps per terrain, the
## editor): a group whose features did not change is not made again. `dirty`:
## where the ground changed since the cache was filled (Rect2, terrain-local
## X/Z; null = nowhere): a road group crossing it re-triangulates only the
## bands of that area (RoadMesher.bands_update), a river group is made
## again. Same mesh as build(). The caller empties the cache when the ground
## may have changed anywhere (the river carve, a full rebuild).
static func build_cached(terrain: Node3D, carve: PackedFloat32Array, cache: Dictionary, dirty: Variant = null) -> Dictionary:
	var job := start(terrain, carve)
	var tasks: Array = job["tasks"]
	var array_mesh: ArrayMesh = job["mesh"]
	var collision_faces: PackedVector3Array = job["collision_faces"]
	var used: Dictionary = {}
	for task: Array in tasks:
		var feature_type: String = task[0]
		var is_road := feature_type == FeatureStyle.ROAD
		var group: Array = task[1]
		var key := "%s|%d|%d" % [feature_type, group.size(), hash(var_to_bytes(group))]
		var entry: Dictionary = cache.get(key, {})
		var crossed := false
		if not entry.is_empty() and dirty != null:
			var dirty_rect: Rect2 = dirty
			var entry_rect: Rect2 = entry["rect"]
			crossed = entry_rect.intersects(dirty_rect, true)
		var geometry: Dictionary
		if is_road:
			if entry.is_empty():
				var state := RoadMesher.bands_begin(terrain, carve, group)
				entry = {"state": state, "rect": RoadMesher.bands_rect(state)}
			var road_state: Dictionary = entry["state"]
			if crossed:
				var dirty_rect: Rect2 = dirty
				RoadMesher.bands_update(road_state, terrain, carve, dirty_rect)
			geometry = RoadMesher.bands_result(road_state)
		else:
			if entry.is_empty() or crossed:
				var water := RiverMesher.build_water_union(terrain, carve, group)
				entry = {"geometry": water, "rect": _vertices_rect(water["vertices"])}
			geometry = entry["geometry"]
		used[key] = entry
		_add_cached_group(terrain, array_mesh, collision_faces, feature_type, group, geometry)
	cache.clear()
	cache.merge(used)
	return finish(job)

## _add_group() of a cached geometry (packed road bands or a river's arrays).
static func _add_cached_group(terrain: Node3D, array_mesh: ArrayMesh, collision_faces: PackedVector3Array,
		feature_type: String, group: Array, geometry: Dictionary) -> void:
	if feature_type != FeatureStyle.ROAD:
		_add_group(terrain, array_mesh, collision_faces, feature_type, group, geometry)
		return
	var representative: Dictionary = FeatureStyle.migrate(group[0], feature_type)
	var vertices: PackedVector3Array = geometry["vertices"]
	var normals: PackedVector3Array = geometry["normals"]
	var uvs: PackedVector2Array = geometry["uvs"]
	MeshUtils.add_packed_surface(array_mesh, vertices, normals, MaterialFactory.road_material(terrain, representative), uvs)
	if _any_collision(group, feature_type, true):
		collision_faces.append_array(vertices)

## Local X/Z box of mesh vertices, a few metres larger (the ground beside a
## river moves its banks).
static func _vertices_rect(vertices: Variant) -> Rect2:
	var points: Array = vertices
	if points.is_empty():
		return Rect2()
	var first: Vector3 = points[0]
	var rect := Rect2(first.x, first.z, 0.0, 0.0)
	for point: Vector3 in points:
		rect = rect.expand(Vector2(point.x, point.z))
	return rect.grow(4.0)

## {"mesh", "collision_faces"} of a job step() has finished (as build()).
static func finish(job: Dictionary) -> Dictionary:
	return {"mesh": job["mesh"], "collision_faces": job["collision_faces"]}

## Mesh of the stroke currently being drawn (see FeatureStyle.make_preview()).
static func build_preview(terrain: Node3D, carve: PackedFloat32Array, preview_feature: Dictionary) -> ArrayMesh:
	var array_mesh := ArrayMesh.new()
	var preview_type: String = str(preview_feature.get("type", FeatureStyle.ROAD))
	var geometry := FeatureRibbon.build(terrain, carve, preview_feature, preview_type)
	var material: Material
	if preview_type == FeatureStyle.ROAD:
		material = MaterialFactory.road_material(terrain, preview_feature)
	else:
		material = MaterialFactory.river_material(preview_feature, Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false))
	var vertices: Array = geometry["vertices"]
	var normals: Array = geometry["normals"]
	var uvs: Array = geometry["uvs"]
	MeshUtils.add_surface(array_mesh, vertices, normals, material, uvs)
	return array_mesh

static func _any_collision(group: Array, feature_type: String, default_value: bool) -> bool:
	for feature_variant: Variant in group:
		var feature: Dictionary = FeatureStyle.migrate(feature_variant, feature_type)
		var collision: bool = feature.get("collision", default_value)
		if collision:
			return true
	return false
