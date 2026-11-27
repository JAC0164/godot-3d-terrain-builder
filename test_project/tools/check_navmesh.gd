extends SceneTree
## Navigation mesh of the terrain (navigation/terrain_navigation.gd, Game >
## Bake Navigation, LowpolyTerrainRuntime.bake_navigation):
## - the bake is not empty and its polygons lie on the ground (heights from
##   LowpolyTerrainQuery);
## - nothing over an emptied 4 x 4 cell patch, nor over a river bed;
## - trunks with collision are holes in it;
## - an agent path crosses the map;
## - bounds: a partial bake covers only its area;
## - the runtime's threaded bake fills the region and calls back.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_navmesh.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainNavigation = preload(ADDON + "navigation/terrain_navigation.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const DetailCollision = preload(ADDON + "mesh/detail_collision.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

## Polygon centres (region space = terrain space here).
func _centres(navigation_mesh: NavigationMesh) -> PackedVector3Array:
	var vertices := navigation_mesh.get_vertices()
	var result := PackedVector3Array()
	for p in navigation_mesh.get_polygon_count():
		var polygon := navigation_mesh.get_polygon(p)
		var sum := Vector3.ZERO
		for index in polygon:
			sum += vertices[index]
		result.append(sum / float(polygon.size()))
	return result

func _covers(navigation_mesh: NavigationMesh, point: Vector2) -> bool:
	var vertices := navigation_mesh.get_vertices()
	for p in navigation_mesh.get_polygon_count():
		var outline := PackedVector2Array()
		for index in navigation_mesh.get_polygon(p):
			outline.append(Vector2(vertices[index].x, vertices[index].z))
		if Geometry2D.is_point_in_polygon(point, outline):
			return true
	return false

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var world_size: float = t.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	# A 4 x 4 cell hole, and a river across the map.
	var hole := Rect2i(resolution / 2 - 20, resolution / 2 + 10, 4, 4)
	var active: PackedByteArray = t.get_meta(Meta.CELL_ACTIVE)
	for z in range(hole.position.y, hole.end.y):
		for x in range(hole.position.x, hole.end.x):
			active[z * (resolution - 1) + x] = 0
	t.set_meta(Meta.CELL_ACTIVE, active)
	var river_points: Array[Vector2] = []
	for i in 9:
		river_points.append(Vector2(-half * 0.8 + i * half * 0.2, half * 0.45 + sin(i * 0.7) * 4.0))
	FeatureStyle.commit(t, FeatureStyle.RIVER, river_points)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(t)
	var runtime := LowpolyTerrainRuntime.new()
	runtime.name = "Runtime"
	runtime.build_on_ready = false
	t.add_child(runtime)

	var region := TerrainNavigation.ensure_region(t)
	var start := Time.get_ticks_msec()
	TerrainNavigation.bake(t, region, builder.get_river_carve(t), AABB(), false)
	var navigation_mesh := region.navigation_mesh
	var polygons := navigation_mesh.get_polygon_count()
	check("bake: %d polygons in %d ms" % [polygons, Time.get_ticks_msec() - start], polygons > 50)
	var query := runtime.get_query()
	var worst := 0.0
	var off := 0
	for centre in _centres(navigation_mesh):
		var h := query.get_height(t.to_global(centre))
		if is_nan(h):
			off += 1
		else:
			worst = maxf(worst, absf(h - t.to_global(centre).y))
	check("polygons lie on the ground (worst %.2f m, %d off the map)" % [worst, off], off == 0 and worst < navigation_mesh.cell_height * 4.0 + 0.5)

	var hole_centre := Vector2((hole.position.x + 2) * spacing - half, (hole.position.y + 2) * spacing - half)
	check("nothing over the emptied cells", not _covers(navigation_mesh, hole_centre))
	var river := RiverMesher.compute_carve(t)
	var river_cells := 0
	var covered := 0
	for z in range(1, resolution - 1, 2):
		for x in range(1, resolution - 1, 2):
			if river[z * resolution + x] > 0.5:
				river_cells += 1
				if _covers(navigation_mesh, Vector2(x * spacing - half, z * spacing - half)):
					covered += 1
	check("nothing over the river bed (%d of %d deep points covered)" % [covered, river_cells], river_cells > 0 and covered == 0)

	var trunks := 0
	var trunks_covered := 0
	for chunk in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var job := DetailCollision.begin_chunk(t, chunk)
		if job["body"] is Node:
			(job["body"] as Node).free()
		for source: Array in job["sources"]:
			var buffer: PackedFloat32Array = source[0]
			var stride: int = source[1]
			var base: Transform3D = source[3]
			for i in mini(int(source[2]), 20):
				var p := base * Vector3(buffer[i * stride + 3], buffer[i * stride + 7], buffer[i * stride + 11])
				trunks += 1
				if _covers(navigation_mesh, Vector2(p.x, p.z)):
					trunks_covered += 1
	check("trunks are holes (%d of %d covered)" % [trunks_covered, trunks], trunks > 0 and trunks_covered == 0)

	# A path across the map.
	# Regions reach the map on a background iteration: wait for it.
	var map := region.get_navigation_map()
	var a := t.to_global(Vector3(-half * 0.7, 0.0, -half * 0.7))
	var b := t.to_global(Vector3(half * 0.6, 0.0, -half * 0.5))
	a.y = runtime.get_height(a)
	b.y = runtime.get_height(b)
	var frames := 0
	while (NavigationServer3D.map_get_iteration_id(map) == 0 or NavigationServer3D.map_get_closest_point(map, a).distance_to(a) > 2.0) and frames < 300:
		await physics_frame
		frames += 1
	var path := NavigationServer3D.map_get_path(map, a, b, true)
	check("an agent path crosses the map (%d points, ends %.1f m from the target)" % [path.size(), path[-1].distance_to(b) if not path.is_empty() else INF], path.size() >= 2 and path[-1].distance_to(b) < 2.0)

	# Partial bake.
	var partial := NavigationRegion3D.new()
	partial.name = "Partial"
	t.add_child(partial)
	var bounds := AABB(Vector3(-20.0, -100.0, -20.0), Vector3(40.0, 200.0, 40.0))
	TerrainNavigation.bake(t, partial, builder.get_river_carve(t), bounds, false)
	var outside := 0
	for centre in _centres(partial.navigation_mesh):
		if absf(centre.x) > 21.0 or absf(centre.z) > 21.0:
			outside += 1
	check("bounds: %d polygons, %d outside the area" % [partial.navigation_mesh.get_polygon_count(), outside], partial.navigation_mesh.get_polygon_count() > 0 and outside == 0)

	# Runtime, threaded.
	var threaded := NavigationRegion3D.new()
	threaded.name = "Threaded"
	threaded.navigation_mesh = NavigationMesh.new()
	t.add_child(threaded)
	var called := [false]
	var started := runtime.bake_navigation(threaded, AABB(), func() -> void: called[0] = true)
	var waited := 0
	while not called[0] and waited < 600:
		await process_frame
		waited += 1
	check("runtime threaded bake: called back, %d polygons" % threaded.navigation_mesh.get_polygon_count(), started and called[0] and threaded.navigation_mesh.get_polygon_count() == polygons)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
