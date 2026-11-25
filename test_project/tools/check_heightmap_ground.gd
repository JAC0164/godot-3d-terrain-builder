extends SceneTree
## The streamed ground's height map collision (TerrainMesher.height_field)
## against the chunk's triangles, on the open-world map (seed 7, rivers
## carved): rays straight down on random points of every sampled chunk, the
## two shapes must agree to TOLERANCE. Jolt stores a height field's samples
## on 8 bits per block, so it is off by up to ~1/500 of the chunk's height
## range (5-11 mm on this map; Jolt's own shape margin is 5 cm). Also: share
## of chunks that get a height map (the others, along the map border, have
## cliff walls and keep their triangles).
##   Godot --headless --path . --script res://tools/check_heightmap_ground.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
const SAMPLE_STEP := 5
const RAYS := 200
const TOLERANCE := 0.025

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	var carve: PackedFloat32Array = builder.get_river_carve(terrain)
	var count := TerrainMesher.chunk_count(terrain)
	var looks := TerrainMesher.chunk_looks(terrain)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var space := root.get_world_3d().direct_space_state
	var sampled := 0
	var fields := 0
	var worst := 0.0
	var misses := 0
	var errors := 0
	for cz in range(0, count, SAMPLE_STEP):
		for cx in range(0, count, SAMPLE_STEP):
			var arrays := TerrainMesher.build_chunk_arrays(terrain, carve, cx, cz)
			if arrays.is_empty():
				continue
			sampled += 1
			var packed := TerrainMesher.pack_chunk(arrays, looks)
			var field: Array = packed["field"]
			if field.is_empty():
				continue
			fields += 1
			var faces: PackedVector3Array = packed["faces"]
			var trimesh := StaticBody3D.new()
			trimesh.name = "Trimesh"
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(faces)
			trimesh.shape_owner_add_shape(trimesh.create_shape_owner(trimesh), shape)
			trimesh.position = Vector3(0, 0, 0)
			var height_map := StaticBody3D.new()
			height_map.name = "HeightMap"
			var hm := HeightMapShape3D.new()
			hm.map_width = field[1]
			hm.map_depth = field[1]
			hm.map_data = field[0]
			var owner_id := height_map.create_shape_owner(height_map)
			height_map.shape_owner_add_shape(owner_id, hm)
			height_map.shape_owner_set_transform(owner_id, field[2])
			# Far apart: each ray sees one body.
			height_map.position = Vector3(0, 0, 100000)
			root.add_child(trimesh)
			root.add_child(height_map)
			await physics_frame
			await physics_frame
			var bounds := AABB(faces[0], Vector3.ZERO)
			for p in faces:
				bounds = bounds.expand(p)
			for k in RAYS:
				var x := rng.randf_range(bounds.position.x + 0.01, bounds.end.x - 0.01)
				var z := rng.randf_range(bounds.position.z + 0.01, bounds.end.z - 0.01)
				var a := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 500, z), Vector3(x, -500, z)))
				var b := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 500, z + 100000), Vector3(x, -500, z + 100000)))
				if a.is_empty() or b.is_empty():
					misses += 1
					continue
				worst = maxf(worst, absf((a["position"] as Vector3).y - (b["position"] as Vector3).y))
			trimesh.free()
			height_map.free()
	if fields == 0:
		errors += 1
		print("FAIL no chunk got a height map")
	if misses > 0:
		errors += 1
		print("FAIL %d rays hit only one of the two shapes" % misses)
	if worst > TOLERANCE:
		errors += 1
		print("FAIL height map off the ground by %.4f m" % worst)
	print("%d chunks sampled, %d with a height map (%.0f %%), largest gap %.5f m over %d rays" % [
		sampled, fields, 100.0 * fields / maxf(sampled, 1), worst, fields * RAYS])
	print("OK" if errors == 0 else "FAILED (%d)" % errors)
	quit(0 if errors == 0 else 1)
