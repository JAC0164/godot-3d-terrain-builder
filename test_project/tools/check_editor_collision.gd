extends SceneTree
## Editor collision body (TerrainBuilder.rebuild_collision): one shape per
## chunk plus one for the roads / rivers.
## - a full build: a shape per chunk (named like it) + "Features", whose faces
##   are the chunk meshes' and the feature faces;
## - a stroke (heights changed in a small area, rebuild_area then
##   flush_collision, as the plugin does): only the chunks of that area get a
##   new shape, the others keep theirs; the faces still equal the meshes; a
##   ray down hits the new height;
## - collision off: shapes emptied; back on: rebuilt;
## - a scene with the old single whole-map shape: replaced.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_editor_collision.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _shapes(t: Node3D) -> Dictionary:
	var result := {}
	var body := t.get_node_or_null(Meta.GENERATED_COLLISION_BODY_NAME)
	if body:
		for child in body.get_children():
			if child is CollisionShape3D:
				result[String(child.name)] = child
	return result

## True when every chunk's shape holds its mesh faces and Features the roads.
func _faces_match(t: Node3D, builder: TerrainBuilder) -> bool:
	var shapes := _shapes(t)
	for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var mesh := (chunk as MeshInstance3D).mesh
		var node: CollisionShape3D = shapes.get(String(chunk.name))
		if node == null or node.shape == null or (node.shape as ConcavePolygonShape3D).get_faces() != mesh.get_faces():
			return false
	var features: CollisionShape3D = shapes.get(TerrainBuilder.FEATURE_COLLISION_SHAPE_NAME)
	var feature_faces := builder.get_feature_collision_faces(t)
	if feature_faces.is_empty():
		return features != null and features.shape == null
	return features != null and features.shape != null and (features.shape as ConcavePolygonShape3D).get_faces() == feature_faces

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	t.set_meta(Meta.COLLISION_ENABLED, true)
	var builder := TerrainBuilder.new()
	var start := Time.get_ticks_usec()
	builder.rebuild_all(t)
	var full_ms := (Time.get_ticks_usec() - start) / 1000.0
	var chunk_count := TerrainMesher.chunk_count(t)
	var shapes := _shapes(t)
	check("full build: %d chunk shapes + Features (%d chunks)" % [shapes.size() - 1, chunk_count * chunk_count], shapes.size() == chunk_count * chunk_count + 1 and shapes.has(TerrainBuilder.FEATURE_COLLISION_SHAPE_NAME))
	check("full build: shapes hold the chunk meshes' and roads' faces", _faces_match(t, builder))
	var nameless := 0
	for node: Node in shapes.values():
		if String(node.name).begins_with("@"):
			nameless += 1
	check("shapes are named", nameless == 0)

	# A stroke: raise a small square in the middle of chunk (1, 1).
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var world_size: float = t.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var heights: PackedFloat32Array = t.get_meta(Meta.HEIGHTS)
	var cell := Vector2i(Meta.TERRAIN_CHUNK_CELLS + 16, Meta.TERRAIN_CHUNK_CELLS + 16)
	for z in range(cell.y - 2, cell.y + 3):
		for x in range(cell.x - 2, cell.x + 3):
			heights[z * resolution + x] += 3.0
	t.set_meta(Meta.HEIGHTS, heights)
	var half := world_size * 0.5
	var centre := Vector2(cell.x * spacing - half, cell.y * spacing - half)
	var rect := Rect2(centre - Vector2.ONE * 3.0 * spacing, Vector2.ONE * 6.0 * spacing)
	var before := {}
	for shape_name: String in shapes:
		before[shape_name] = (shapes[shape_name] as CollisionShape3D).shape
	builder.rebuild_area(t, rect, {"details": false})
	start = Time.get_ticks_usec()
	builder.flush_collision()
	var stroke_ms := (Time.get_ticks_usec() - start) / 1000.0
	var expected := {}
	for key in builder.chunks_for_local_rect(t, rect):
		expected[TerrainMesher.chunk_name(key.x, key.y)] = true
	var rebuilt: Array[String] = []
	shapes = _shapes(t)
	for shape_name: String in shapes:
		if (shapes[shape_name] as CollisionShape3D).shape != before.get(shape_name):
			rebuilt.append(shape_name)
	var only_area := not rebuilt.is_empty()
	for shape_name in rebuilt:
		only_area = only_area and expected.has(shape_name)
	check("stroke: %d of %d shapes rebuilt (area: %d chunks), %.1f ms vs %.0f ms full build" % [rebuilt.size(), shapes.size(), expected.size(), stroke_ms, full_ms], only_area and rebuilt.size() < shapes.size())
	check("stroke: shapes still hold the meshes' faces", _faces_match(t, builder))
	await physics_frame
	await physics_frame
	var top := t.to_global(Vector3(centre.x, 200.0, centre.y))
	var hit := root3d.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(top, top + Vector3.DOWN * 400.0))
	var ground_y: float = heights[cell.y * resolution + cell.x]
	check("stroke: a ray down hits the raised ground (%.2f, expected %.2f)" % [hit.get("position", Vector3.ZERO).y if not hit.is_empty() else NAN, ground_y], not hit.is_empty() and absf((hit["position"] as Vector3).y - ground_y) < 0.6)

	# Collision off, then on again.
	t.set_meta(Meta.COLLISION_ENABLED, false)
	builder.rebuild_collision(t, builder.get_feature_collision_faces(t))
	var empty := true
	for node: CollisionShape3D in _shapes(t).values():
		empty = empty and node.shape == null and node.disabled
	check("collision off: shapes emptied", empty)
	t.set_meta(Meta.COLLISION_ENABLED, true)
	builder.rebuild_collision(t, builder.get_feature_collision_faces(t))
	check("collision on again: shapes rebuilt", _faces_match(t, builder))

	# An older scene: a single whole-map shape.
	var body := t.get_node(Meta.GENERATED_COLLISION_BODY_NAME)
	for child in body.get_children():
		body.remove_child(child)
		child.free()
	var legacy := CollisionShape3D.new()
	legacy.name = Meta.GENERATED_COLLISION_SHAPE_NAME
	legacy.shape = ConcavePolygonShape3D.new()
	body.add_child(legacy)
	builder.rebuild_collision(t, builder.get_feature_collision_faces(t))
	await process_frame
	check("old single shape replaced by per-chunk shapes", body.get_node_or_null(Meta.GENERATED_COLLISION_SHAPE_NAME) == null and _faces_match(t, builder))

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
