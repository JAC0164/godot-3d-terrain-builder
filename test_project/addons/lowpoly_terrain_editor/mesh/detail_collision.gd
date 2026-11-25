@tool
extends RefCounted
## Collision of the detail layers that block the player (trunks, termite
## mounds...): one cylinder per instance of every layer whose
## `collision_radius` > 0, read back from the chunk's detail MultiMeshes so it
## matches what is drawn exactly.
##
## Layout: Chunk_X_Z/_DetailCollision (StaticBody3D, never saved). The shapes
## are shape owners of the body, not CollisionShape3D nodes: thousands of
## trunks cost one node per chunk. Cylinders of nearly the same size share one
## CylinderShape3D (radius rounded to 5 cm, height to 25 cm).
##
## Built in game by LowpolyTerrainRuntime; the editor does not need it.

const Meta = preload("../core/terrain_meta.gd")
const NodeNames = preload("../core/node_names.gd")
const DetailScatter = preload("detail_scatter.gd")
const DetailLayer = preload("../biomes/detail_layer.gd")

const RADIUS_STEP := 0.05
const HEIGHT_STEP := 0.25

## Rebuilds the collision of one chunk node. Returns the number of shapes.
static func build_chunk(terrain: Node3D, chunk: Node3D, shape_cache: Dictionary = {}) -> int:
	var job := begin_chunk(terrain, chunk)
	step_chunk(job, shape_cache)
	return finish_chunk(job)

## build_chunk() in slices (a streamed game): begin_chunk() copies what it
## reads from the chunk's detail MultiMeshes (their nodes may go meanwhile),
## step_chunk() fills the body, out of the tree, for about `budget_usec` (0 =
## to the end) and returns true when done, finish_chunk() puts it in place of
## the old one (cancel_chunk() drops it). Same shapes in the same order as
## build_chunk().
static func begin_chunk(terrain: Node3D, chunk: Node3D) -> Dictionary:
	var sources: Array = []
	var job := {"chunk": chunk, "sources": sources, "source": 0, "instance": 0, "body": null, "shapes": 0,
		"layer_number": clampi(Meta.get_int(terrain, Meta.COLLISION_LAYER, 1), 1, 32), "done": false}
	var biome := DetailScatter.biome_of(terrain)
	if biome == null:
		return job
	var layers: Array = biome.detail_layers
	for child in chunk.get_children():
		var node := child as MultiMeshInstance3D
		if node == null or node.multimesh == null or node.multimesh.mesh == null:
			continue
		var node_name := String(node.name)
		if not node_name.begins_with(DetailScatter.NODE_PREFIX + "_"):
			continue
		var index := int(node_name.substr(DetailScatter.NODE_PREFIX.length() + 1).get_slice("_", 0))
		if index < 1 or index > layers.size():
			continue
		var layer: DetailLayer = layers[index - 1]
		if layer == null or float(layer.collision_radius) <= 0.0:
			continue
		var multimesh := node.multimesh
		var aabb := multimesh.mesh.get_aabb()
		var radius_unit := float(layer.collision_radius) * maxf(aabb.size.x, aabb.size.z)
		var height_unit := float(layer.collision_height) * aabb.size.y
		if radius_unit <= 0.0 or height_unit <= 0.0:
			continue
		var stride := 12 + (4 if multimesh.use_colors else 0) + (4 if multimesh.use_custom_data else 0)
		sources.append([multimesh.buffer, stride, multimesh.instance_count, node.transform, radius_unit, height_unit])
	if not sources.is_empty():
		# Filled out of the tree, added once complete: a shape added to a
		# body in the tree makes Jolt rebuild the whole body each time.
		var body := StaticBody3D.new()
		body.name = Meta.DETAIL_COLLISION_NAME
		var layer_number: int = job["layer_number"]
		body.collision_layer = 1 << (layer_number - 1)
		body.collision_mask = 0
		job["body"] = body
	return job

static func step_chunk(job: Dictionary, shape_cache: Dictionary, budget_usec: int = 0) -> bool:
	var start := Time.get_ticks_usec()
	var sources: Array = job["sources"]
	var body: StaticBody3D = job["body"]
	var source_index: int = job["source"]
	var i: int = job["instance"]
	var shapes: int = job["shapes"]
	while source_index < sources.size():
		var source: Array = sources[source_index]
		var buffer: PackedFloat32Array = source[0]
		var stride: int = source[1]
		var count: int = source[2]
		var base: Transform3D = source[3]
		var radius_unit: float = source[4]
		var height_unit: float = source[5]
		while i < count:
			var o := i * stride
			# Row-major 3x4: column 0 = basis.x, column 1 = basis.y.
			var sx := Vector3(buffer[o], buffer[o + 4], buffer[o + 8]).length()
			var sy := Vector3(buffer[o + 1], buffer[o + 5], buffer[o + 9]).length()
			var radius := maxf(snappedf(radius_unit * sx, RADIUS_STEP), RADIUS_STEP)
			var height := maxf(snappedf(height_unit * sy, HEIGHT_STEP), HEIGHT_STEP)
			var key := Vector2i(roundi(radius / RADIUS_STEP), roundi(height / HEIGHT_STEP))
			var shape: CylinderShape3D = shape_cache.get(key)
			if shape == null:
				shape = CylinderShape3D.new()
				shape.radius = radius
				shape.height = height
				shape_cache[key] = shape
			var origin := base * Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11])
			# Bottom of the cylinder at the instance base (sunk props start
			# slightly below the ground, which is fine).
			var owner_id := body.create_shape_owner(body)
			body.shape_owner_set_transform(owner_id, Transform3D(Basis(), origin + Vector3(0.0, height * 0.5, 0.0)))
			body.shape_owner_add_shape(owner_id, shape)
			shapes += 1
			i += 1
			if budget_usec > 0 and i % 16 == 0 and Time.get_ticks_usec() - start >= budget_usec:
				job["source"] = source_index
				job["instance"] = i
				job["shapes"] = shapes
				return false
		source_index += 1
		i = 0
	job["source"] = source_index
	job["instance"] = 0
	job["shapes"] = shapes
	job["done"] = true
	return true

## Puts a finished job's body under its chunk, in place of the old one.
## Returns the number of shapes.
static func finish_chunk(job: Dictionary) -> int:
	var chunk: Node3D = job["chunk"]
	var body: StaticBody3D = job["body"]
	var shapes: int = job["shapes"]
	job["body"] = null
	if not is_instance_valid(chunk):
		if body != null:
			body.free()
		return 0
	clear_chunk(chunk)
	if body != null:
		if shapes > 0:
			NodeNames.add(chunk, body)
		else:
			body.free()
			shapes = 0
	return shapes

## Drops an unfinished job (frees its body, never in the tree).
static func cancel_chunk(job: Dictionary) -> void:
	var body: StaticBody3D = job.get("body")
	job["body"] = null
	if body != null:
		body.free()

## Removes the collision of one chunk node.
static func clear_chunk(chunk: Node3D) -> void:
	var old := chunk.get_node_or_null(Meta.DETAIL_COLLISION_NAME)
	if old:
		chunk.remove_child(old)
		old.queue_free()

## Rebuilds the collision of every chunk. Returns the number of shapes.
static func build_all(terrain: Node3D) -> int:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null:
		return 0
	var cache: Dictionary = {}
	var shapes := 0
	for chunk in container.get_children():
		if chunk is Node3D:
			shapes += build_chunk(terrain, chunk as Node3D, cache)
	return shapes

## True when at least one detail layer of the terrain's biome has collision.
static func has_collision_layers(terrain: Node3D) -> bool:
	var biome := DetailScatter.biome_of(terrain)
	if biome == null:
		return false
	for layer: DetailLayer in biome.detail_layers:
		if layer != null and layer.enabled and float(layer.collision_radius) > 0.0:
			return true
	return false

## Number of collision shapes currently built.
static func count_shapes(terrain: Node3D) -> int:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null:
		return 0
	var total := 0
	for chunk in container.get_children():
		var body := chunk.get_node_or_null(Meta.DETAIL_COLLISION_NAME) as StaticBody3D
		if body:
			total += body.get_shape_owners().size()
	return total
