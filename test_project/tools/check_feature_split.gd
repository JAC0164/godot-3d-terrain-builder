extends SceneTree
## Checks the roads and rivers cut by chunk (FeatureMesher.start_threaded
## with split, as a streamed game loads them: TerrainRuntime puts each piece
## under its chunk): every triangle of the single mesh is in exactly one
## piece (same count, same order-free sum of triangle hashes, per road /
## river), the collision faces too, and each piece's triangles have their
## centre over their chunk. On the audit savanna (+ one river) and the open
## world (seed 7).
##   godot --headless --path . --script res://tools/check_feature_split.gd
## Prints FAIL lines and "feature split: N failures" at the end.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const MeshUtils = preload(ADDON + "mesh/mesh_utils.gd")

var _failures := 0

func _initialize() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var savanna := _map(holder, "senegal_savanna_map.tres")
	var size: float = float(savanna.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(savanna, FeatureStyle.RIVER, points)
	_check("audit savanna", savanna)
	_check("open world", _map(holder, "senegal_savanna_open_world_map.tres"))
	print("feature split: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)

func _map(holder: Node3D, recipe: String) -> Node3D:
	var terrain := Node3D.new()
	holder.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(ADDON + "generation/presets/" + recipe), 7)
	return terrain

func _check(label: String, terrain: Node3D) -> void:
	var carve := RiverMesher.compute_carve(terrain)
	var whole := FeatureMesher.build(terrain, carve)
	var mesh: ArrayMesh = whole["mesh"]
	var expected := {}
	for surface in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface)
		var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
		_sum(expected, String(mesh.surface_get_material(surface).resource_name), arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL],
			uvs if uvs != null else PackedVector2Array())
	var whole_faces: PackedVector3Array = whole["collision_faces"]
	_sum(expected, "collision", whole_faces, PackedVector3Array(), PackedVector2Array())

	var t0 := Time.get_ticks_usec()
	var job := FeatureMesher.start_threaded(terrain, carve, true)
	while not FeatureMesher.step(job, 2000):
		pass
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var grid := FeatureMesher.chunk_grid(terrain)
	var count := int(grid.z)
	var got := {}
	var outside := 0
	var chunks: Dictionary = job["chunks"]
	var vertices_total := 0
	for index: int in chunks:
		var bounds := Rect2(Vector2(index % count, index / count) * grid.y - Vector2(grid.x, grid.x), Vector2(grid.y, grid.y))
		for piece: Array in chunks[index]:
			var material: Material = piece[0]
			var vertices: PackedVector3Array = piece[1]
			vertices_total += vertices.size()
			# Through an ArrayMesh as the whole one (normals are stored packed).
			var piece_mesh := ArrayMesh.new()
			MeshUtils.add_packed_surface(piece_mesh, vertices, piece[2], material, piece[3])
			var arrays := piece_mesh.surface_get_arrays(0)
			var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
			_sum(got, String(material.resource_name), arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL],
				uvs if uvs != null else PackedVector2Array())
			for t in range(vertices.size() / 3):
				var centre := (vertices[t * 3] + vertices[t * 3 + 1] + vertices[t * 3 + 2]) / 3.0
				# Off the map (a road or river leaving it): in the edge chunk.
				var at := Vector2(clampf(centre.x, -grid.x, grid.x - 0.01), clampf(centre.z, -grid.x, grid.x - 0.01))
				if not bounds.grow(0.001).has_point(at):
					outside += 1
	var chunk_faces: Dictionary = job["chunk_faces"]
	for index: int in chunk_faces:
		_sum(got, "collision", chunk_faces[index], PackedVector3Array(), PackedVector2Array())
	_report(outside == 0, "%s: %d triangles outside their chunk" % [label, outside])
	for key: String in expected:
		var e: Array = expected[key]
		var g: Array = got.get(key, [0, 0])
		_report(e == g, "%s: %s %d triangles (split %d), sums %s" % [label, key, e[0], g[0], "equal" if e[1] == g[1] else "DIFFERENT"])
	_report(got.size() == expected.size(), "%s: same kinds of surfaces (%d)" % [label, expected.size()])
	print("%s: %d pieces in %d chunks, %d vertices, split job %.0f ms" % [label, _pieces(chunks), chunks.size(), vertices_total, ms])

## Count and order-free sum of the triangle hashes into sums[key].
func _sum(sums: Dictionary, key: String, vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array) -> void:
	var entry: Array = sums.get(key, [0, 0])
	var total: int = entry[1]
	for t in range(vertices.size() / 3):
		var parts: Array = [vertices[t * 3], vertices[t * 3 + 1], vertices[t * 3 + 2]]
		if not normals.is_empty():
			parts.append_array([normals[t * 3], normals[t * 3 + 1], normals[t * 3 + 2]])
		if not uvs.is_empty():
			parts.append_array([uvs[t * 3], uvs[t * 3 + 1], uvs[t * 3 + 2]])
		total = (total + hash(parts)) & 0xFFFFFFFFFFFF
	sums[key] = [int(entry[0]) + vertices.size() / 3, total]

func _pieces(chunks: Dictionary) -> int:
	var n := 0
	for index: int in chunks:
		n += (chunks[index] as Array).size()
	return n

func _report(ok: bool, text: String) -> void:
	if not ok:
		_failures += 1
	print(("ok   " if ok else "FAIL ") + text)
