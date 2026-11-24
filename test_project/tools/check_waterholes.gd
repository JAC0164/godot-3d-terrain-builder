extends SceneTree
## Checks of the dried waterholes (styles/waterhole_style.gd,
## mesh/waterhole_mesher.gd and their hooks). Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_waterholes.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const GridMath = preload(ADDON + "core/grid_math.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSnapshot = preload(ADDON + "core/terrain_snapshot.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TerrainShading = preload(ADDON + "mesh/terrain_shading.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const FeatureEraser = preload(ADDON + "editing/feature_eraser.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const DetailLayer = preload(ADDON + "biomes/detail_layer.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func _check(ok: bool, label: String) -> void:
	print("%s  %s" % ["OK  " if ok else "FAIL", label])
	if not ok:
		_failures += 1

func _chunk_vertices(terrain: Node3D) -> PackedVector3Array:
	var all := PackedVector3Array()
	var container := terrain.get_node(Meta.GENERATED_CHUNKS_NAME)
	for chunk in container.get_children():
		var mesh := (chunk as MeshInstance3D).mesh as ArrayMesh
		for s in range(mesh.get_surface_count()):
			all.append_array(mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX])
	return all

## Positions of every instance of the detail nodes whose name contains `part`.
func _instances(terrain: Node3D, part: String) -> PackedVector2Array:
	var points := PackedVector2Array()
	for node in terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(part):
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		for i in range(0, buffer.size(), 16):
			points.append(Vector2(buffer[i + 3], buffer[i + 11]))
	return points

func _initialize() -> void:
	# Generated island (no waterholes yet, flat areas), no scene file needed.
	var root := Node3D.new()
	root.name = "CheckWaterholes"
	get_root().add_child(root)
	var terrain := TestTerrain.island(root)
	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)

	# Find a flat, fully active spot (radius 7 cells) for the tests.
	var center := Vector2.ZERO
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var found := false
	for gz in range(12, resolution - 12, 4):
		for gx in range(12, resolution - 12, 4):
			var ok := true
			var h0 := heights[gz * resolution + gx]
			for dz in range(-8, 9):
				for dx in range(-8, 9):
					if not TerrainData.cell_active(terrain, gx + dx, gz + dz) or absf(heights[(gz + dz) * resolution + gx + dx] - h0) > 0.3:
						ok = false
			if ok:
				var p := GridMath.grid_to_local(gx, gz, resolution, world_size)
				center = Vector2(p.x, p.z)
				found = true
				break
		if found:
			break
	_check(found, "flat test spot found at %s" % center)

	Meta.set_optional(terrain, Meta.BIOME, TerrainBiome.make_senegal_savanna())
	builder.rebuild_all(terrain)
	var vertices_before := _chunk_vertices(terrain)
	var carve_before := builder.get_river_carve(terrain).duplicate()
	print("      carve before: max %.3f" % Array(carve_before).max())
	var heights_before := heights.duplicate()
	var before := TerrainSnapshot.capture(terrain)

	# 1. Commit: data only, heights untouched; carve digs the basin.
	var radius := 6.0 * spacing
	_check(not WaterholeStyle.commit(terrain, center, 0.2), "a too small waterhole is refused")
	_check(WaterholeStyle.commit(terrain, center, radius), "waterhole committed")
	var hole: Dictionary = WaterholeStyle.migrate(WaterholeStyle.list(terrain)[0])
	var area := WaterholeStyle.bounds_of(terrain, 0)
	var t := Time.get_ticks_usec()
	builder.rebuild_waterhole_area(terrain, area)
	var area_ms := (Time.get_ticks_usec() - t) / 1000.0
	_check(terrain.get_meta(Meta.HEIGHTS) == heights_before, "heights are not modified")
	var carve := builder.get_river_carve(terrain)
	var g := GridMath.local_to_grid(center, resolution, world_size)
	var center_index := int(round(g.y)) * resolution + int(round(g.x))
	_check(is_equal_approx(carve[center_index], float(hole["depth"])), "carve at the centre = depth (%.2f)" % carve[center_index])
	var lip_found := false
	for value in carve:
		if value < -0.01:
			lip_found = true
	_check(lip_found, "the rim lip raises a few vertices")
	var after := TerrainSnapshot.capture(terrain)
	_check(not TerrainSnapshot.equal(before, after), "snapshot sees the new waterhole")
	print("      partial rebuild after placing: %.0f ms" % area_ms)

	# 2. Mud plates.
	var node := terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME + "/Waterhole_0") as MeshInstance3D
	_check(node != null and node.mesh != null, "plate mesh built")
	if node != null and node.mesh != null:
		var arrays := (node.mesh as ArrayMesh).surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var tris := verts.size() / 3
		var up := 0
		var winding_ok := 0
		var below := 0
		var spread := 0.0
		for i in range(0, verts.size(), 3):
			var n := (verts[i + 2] - verts[i]).cross(verts[i + 1] - verts[i]).normalized()
			if n.dot(normals[i]) > 0.99:
				winding_ok += 1
			if normals[i].y > 0.9:
				up += 1
				for k in range(3):
					var v := verts[i + k]
					var ground := WaterholeMesher.surface_height(terrain.get_meta(Meta.HEIGHTS), carve, resolution, world_size, Vector2(v.x, v.z))
					if v.y < ground + WaterholeMesher.LIFT * 0.9:
						below += 1
					spread = maxf(spread, Vector2(v.x, v.z).distance_to(center))
		_check(tris > 40 and tris < 6000, "plate mesh: %d triangles (%d top faces)" % [tris, up])
		_check(winding_ok == tris, "plate normals match the winding (%d/%d)" % [winding_ok, tris])
		_check(below == 0, "no plate top vertex below the ground (%d)" % below)
		_check(spread < radius * 1.0, "plates stay inside the basin (%.2f < %.2f)" % [spread, radius])
		_check(node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "plates cast no shadow")
		var again := WaterholeMesher.build(terrain, carve, hole)
		_check(again.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == verts, "plates are deterministic")

	# 3. Shading: crack colour on the floor, clay on the bank, untouched far away.
	var cell_x := int(floor(g.x))
	var cell_z := int(floor(g.y))
	var ctx := TerrainShading.prepare(terrain, carve, cell_x - 10, cell_z - 10, cell_x + 10, cell_z + 10)
	var floor_color := TerrainShading.top_face_color(ctx, cell_x, cell_z, 0)
	var biome: Resource = TerrainBiome.of(terrain)
	var crack: Color = biome.waterhole_crack_color
	_check(floor_color.get_luminance() < crack.get_luminance() * 1.35, "floor is crack-coloured (%s)" % floor_color)
	var bank_x := cell_x + int(round(6.0 * 0.85))
	var bank_color := TerrainShading.top_face_color(ctx, bank_x, cell_z, 0)
	var shape := WaterholeStyle.make_shape(hole)
	var clay: Color = biome.waterhole_clay_color
	var bank_d := shape.distance((float(bank_x) + 0.6667) * spacing - world_size * 0.5, (float(cell_z) + 0.3333) * spacing - world_size * 0.5)
	_check(bank_d > 0.95 or Vector3(bank_color.r - clay.r, bank_color.g - clay.g, bank_color.b - clay.b).length() < 0.25, "bank is clay-coloured (%s, d %.2f)" % [bank_color, bank_d])

	# 4. Shading seams: a chunk's colours do not depend on the built region.
	var bad := 0
	var small := TerrainShading.prepare(terrain, carve, cell_x - 4, cell_z - 4, cell_x + 4, cell_z + 4)
	var large := TerrainShading.prepare(terrain, carve, cell_x - 12, cell_z - 9, cell_x + 15, cell_z + 11)
	for z in range(cell_z - 4, cell_z + 4):
		for x in range(cell_x - 4, cell_x + 4):
			for tri in range(2):
				if not TerrainShading.top_face_color(small, x, z, tri).is_equal_approx(TerrainShading.top_face_color(large, x, z, tri)):
					bad += 1
	_check(bad == 0, "waterhole colours are region independent (%d mismatches)" % bad)

	# 5. Detail zones.
	var outside_basin := 0
	for p in _instances(terrain, "BasinBones"):
		if shape.distance(p.x, p.y) >= 1.0:
			outside_basin += 1
	var off_rim := 0
	var rim_count := 0
	for p in _instances(terrain, "WaterholeReeds"):
		rim_count += 1
		var d := shape.distance(p.x, p.y)
		if d < 0.9 or d > 1.0 + shape.rim + 0.25:
			off_rim += 1
	var grass_in_basin := 0
	for p in _instances(terrain, "DryGrass"):
		if shape.distance(p.x, p.y) < 0.85:
			grass_in_basin += 1
	_check(rim_count > 0 and off_rim == 0, "rim layer only on the rim (%d instances, %d off)" % [rim_count, off_rim])
	_check(outside_basin == 0, "basin layer only in the basin")
	_check(grass_in_basin == 0, "default layers avoid the basin (%d)" % grass_in_basin)

	# 6. Apply settings to all.
	terrain.set_meta(WaterholeStyle.setting_key("depth"), 1.3)
	_check(WaterholeStyle.apply_settings_to_all(terrain) == 1 and is_equal_approx(float(WaterholeStyle.list(terrain)[0]["depth"]), 1.3), "apply settings to existing waterholes")
	_check(is_equal_approx(float(WaterholeStyle.list(terrain)[0]["radius"]), radius), "apply keeps the radius")

	# 7. Erase restores the terrain exactly.
	_check(FeatureEraser.has_feature_at(terrain, center + Vector2(0.3, 0.2), 0.5), "eraser hits the waterhole")
	_check(FeatureEraser.erase_at(terrain, center, 0.5), "eraser removes it")
	builder.rebuild_all(terrain)
	_check(WaterholeStyle.list(terrain).is_empty() and terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME) == null, "no waterhole node left")
	var vertices_after := _chunk_vertices(terrain)
	var first := -1
	for i in range(mini(vertices_after.size(), vertices_before.size())):
		if not vertices_after[i].is_equal_approx(vertices_before[i]):
			first = i
			break
	if first >= 0:
		print("      heights same: %s, carve max %.3f min %.3f" % [terrain.get_meta(Meta.HEIGHTS) == heights_before, Array(builder.get_river_carve(terrain)).max(), Array(builder.get_river_carve(terrain)).min()])
		print("      sizes %d / %d, first diff %d: %s vs %s" % [vertices_before.size(), vertices_after.size(), first, vertices_before[first], vertices_after[first]])
	_check(vertices_after == vertices_before, "terrain mesh identical to before the waterhole")
	TerrainSnapshot.apply(terrain, after)
	builder.rebuild_all(terrain)
	_check(WaterholeStyle.list(terrain).size() == 1 and terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME + "/Waterhole_0") != null, "undo snapshot restores it")

	# 8. Cost of the plates.
	for r in [6.0, 12.0, 24.0]:
		var big := hole.duplicate()
		big["radius"] = r
		t = Time.get_ticks_usec()
		var mesh := WaterholeMesher.build(terrain, carve, big)
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		print("      radius %.0f: %d triangles, built in %.1f ms" % [r, mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3, ms])
	t = Time.get_ticks_usec()
	var many := []
	for i in range(20):
		var h := hole.duplicate()
		h["center"] = center + Vector2(float(i % 5) * 9.0, float(i / 5) * 9.0)
		many.append(h)
	terrain.set_meta(Meta.WATERHOLES, many)
	builder.rebuild_river_carve(terrain)
	print("      carve with 20 waterholes: %.1f ms" % ((Time.get_ticks_usec() - t) / 1000.0))

	root.queue_free()
	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(0 if _failures == 0 else 1)
