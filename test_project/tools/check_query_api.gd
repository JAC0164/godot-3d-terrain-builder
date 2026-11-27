extends SceneTree
## Ground questions of LowpolyTerrainRuntime / LowpolyTerrainQuery, compared
## with physics rays on the built collision (= the drawn triangles):
## - get_height / get_normal on 400 random points, terrain moved, turned
##   around Y and scaled;
## - get_intersection vs a slanted physics ray;
## - get_ground_style = the painted cell style, its name = its biome style;
## - NAN outside the map and over an emptied cell (is_on_terrain false);
## - a query copy answers the same on a worker thread.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_query_api.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var world := (root.get_child(0) as Node3D).get_world_3d()
	return world.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	t.set_meta(Meta.COLLISION_ENABLED, true)
	# Empty one cell in the middle of the map (a hole).
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var world_size: float = t.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var hole := Vector2i(resolution / 2, resolution / 2)
	var active: PackedByteArray = t.get_meta(Meta.CELL_ACTIVE)
	active[hole.y * (resolution - 1) + hole.x] = 0
	t.set_meta(Meta.CELL_ACTIVE, active)
	t.position = Vector3(40.0, -3.0, -25.0)
	t.rotation_degrees = Vector3(0.0, 33.0, 0.0)
	t.scale = Vector3(1.25, 0.8, 1.25)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(t)
	var runtime := LowpolyTerrainRuntime.new()
	runtime.name = "Runtime"
	runtime.build_on_ready = false
	t.add_child(runtime)
	# Ground only: roads / rivers sit a few cm above it in the collision.
	var features := t.get_node("%s/%s" % [Meta.GENERATED_COLLISION_BODY_NAME, TerrainBuilder.FEATURE_COLLISION_SHAPE_NAME]) as CollisionShape3D
	features.disabled = true
	await physics_frame
	await physics_frame

	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var half := world_size * 0.48
	var worst_height := 0.0
	var worst_normal := 0.0
	var compared := 0
	var missing := 0
	for i in 400:
		var local := Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half))
		var point := t.global_transform * local
		var hit := _ray(Vector3(point.x, 500.0, point.z), Vector3(point.x, -500.0, point.z))
		var h := runtime.get_height(point)
		if hit.is_empty() or is_nan(h):
			if hit.is_empty() != is_nan(h):
				missing += 1
			continue
		var hit_position: Vector3 = hit["position"]
		var hit_normal: Vector3 = hit["normal"]
		worst_height = maxf(worst_height, absf(hit_position.y - h))
		worst_normal = maxf(worst_normal, 1.0 - absf(runtime.get_normal(point).dot(hit_normal)))
		compared += 1
	check("get_height = physics ray on %d points (worst %.4f m), moved / turned / scaled terrain" % [compared, worst_height], compared > 300 and worst_height < 0.01 and missing == 0)
	check("get_normal = facet normal (worst 1 - dot %.6f)" % worst_normal, worst_normal < 0.0005)

	# Slanted ray.
	var target := t.global_transform * Vector3(10.0, 0.0, -12.0)
	target.y = runtime.get_height(target)
	var from := target + Vector3(-30.0, 25.0, 18.0)
	var dir := (target - from).normalized()
	var mine := runtime.get_intersection(from, dir, 200.0)
	var physics := _ray(from, from + dir * 200.0)
	check("get_intersection = slanted physics ray (%.3f m apart)" % (mine.distance_to(physics["position"]) if not physics.is_empty() else INF), not physics.is_empty() and mine.distance_to(physics["position"]) < 0.02)
	check("get_intersection misses upwards (NAN)", is_nan(runtime.get_intersection(from, Vector3.UP, 200.0).x))

	# Styles.
	var cell := Vector2i(20, 30)
	var styles: PackedInt32Array = t.get_meta(Meta.CELL_STYLES)
	var centre := t.global_transform * Vector3((cell.x + 0.5) * spacing - world_size * 0.5, 0.0, (cell.y + 0.5) * spacing - world_size * 0.5)
	var style := runtime.get_ground_style(centre)
	var palette: Array = t.get_meta(Meta.STYLE_PALETTE)
	var expected_name := StringName(str((palette[style] as Dictionary).get("biome_style", ""))) if style >= 0 else &""
	check("get_ground_style = painted cell style (%d), name %s" % [style, runtime.get_ground_style_name(centre)], style == styles[cell.y * (resolution - 1) + cell.x] and runtime.get_ground_style_name(centre) == expected_name and expected_name != &"")

	# No ground.
	var outside := t.global_transform * Vector3(world_size, 0.0, 0.0)
	var in_hole := t.global_transform * Vector3((hole.x + 0.5) * spacing - world_size * 0.5, 0.0, (hole.y + 0.5) * spacing - world_size * 0.5)
	check("outside the map: NAN, not on terrain, style -1", is_nan(runtime.get_height(outside)) and not runtime.is_on_terrain(outside) and runtime.get_ground_style(outside) == -1 and is_nan(runtime.get_normal(outside).x))
	check("emptied cell: NAN, not on terrain (physics agrees: %s)" % [_ray(in_hole + Vector3.UP * 500.0, in_hole + Vector3.DOWN * 500.0).is_empty()], is_nan(runtime.get_height(in_hole)) and not runtime.is_on_terrain(in_hole))
	var range_y := runtime.get_height_range()
	check("height range %s holds the heights" % range_y, range_y.x <= worst_height + range_y.y and range_y.x < range_y.y and runtime.get_height(centre) >= range_y.x - 0.001 and runtime.get_height(centre) <= range_y.y + 0.001)

	# A copy on a worker thread.
	var query := runtime.get_query()
	var points := PackedVector3Array()
	for i in 200:
		points.append(t.global_transform * Vector3(rng.randf_range(-half, half), 0.0, rng.randf_range(-half, half)))
	var answers := PackedFloat32Array()
	answers.resize(points.size())
	var task := WorkerThreadPool.add_task(func() -> void:
		for i in points.size():
			answers[i] = query.get_height(points[i]))
	WorkerThreadPool.wait_for_task_completion(task)
	var same := true
	for i in points.size():
		var h := runtime.get_height(points[i])
		same = same and (is_nan(h) == is_nan(answers[i])) and (is_nan(h) or absf(h - answers[i]) < 0.0001)
	check("a query copy answers the same on a worker thread", same)

	# Moving the terrain: answers follow.
	var before := runtime.get_height(centre)
	t.position += Vector3(0.0, 5.0, 0.0)
	check("terrain moved up 5 m: height follows", absf(runtime.get_height(centre + Vector3(0.0, 5.0, 0.0)) - (before + 5.0)) < 0.001)

	var start := Time.get_ticks_usec()
	for i in 10000:
		runtime.get_height(points[i % points.size()])
	print("      get_height: %.2f us per call" % ((Time.get_ticks_usec() - start) / 10000.0))
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
