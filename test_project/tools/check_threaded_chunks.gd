extends SceneTree
## Checks that a chunk built on a worker thread (TerrainMesher.thread_snapshot
## + build_chunk_arrays and pack_chunk on WorkerThreadPool, assemble_packed
## on the main thread, as TerrainRuntime streams) is bit-identical to the
## same chunk built on the main thread, and that its collision faces and
## shadow caster made on the worker are those of the mesh (get_faces(),
## MeshUtils.back_face_caster()), for
## every chunk of a generated savanna (faceted and Smooth Ground), all the
## tasks running at once. Prints the serial and the threaded time.
##   godot --headless --path . --script res://tools/check_threaded_chunks.gd [-- size]
## Prints FAIL lines and "threaded chunks: N failures" at the end.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const MeshUtils = preload(ADDON + "mesh/mesh_utils.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _failures := 0

func _initialize() -> void:
	var size := 256
	for arg in OS.get_cmdline_user_args():
		if arg.is_valid_int():
			size = arg.to_int()
	var recipe: MapRecipe = (load(RECIPE) as MapRecipe).duplicate()
	recipe.size = size
	recipe.cell_size = 1.5
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, recipe, 7)
	StylePalette.ensure_material_data(terrain)
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	var carve := builder.get_river_carve(terrain)
	for smooth: bool in [false, true]:
		terrain.set_meta(Meta.SHADE_SMOOTH, smooth)
		_compare(terrain, carve, "smooth" if smooth else "faceted")
	terrain.free()
	print("threaded chunks: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)

func _compare(terrain: Node3D, carve: PackedFloat32Array, label: String) -> void:
	var count := TerrainMesher.chunk_count(terrain)
	var expected: Dictionary = {}
	var t := Time.get_ticks_usec()
	for z in count:
		for x in count:
			var parts := TerrainMesher.build_chunk_parts(terrain, carve, x, z)
			var mesh: ArrayMesh = parts["mesh"]
			expected[Vector2i(x, z)] = _mesh_hash(mesh)
	var serial_ms := (Time.get_ticks_usec() - t) / 1000.0

	t = Time.get_ticks_usec()
	TerrainMesher.prepare_threads(terrain)
	var looks := TerrainMesher.chunk_looks(terrain)
	var tasks: Dictionary = {}
	for z in count:
		for x in count:
			var snapshot := TerrainMesher.thread_snapshot(terrain)
			var result: Array[Dictionary] = [{}]
			var cx := x
			var cz := z
			var task := WorkerThreadPool.add_task(func() -> void:
				result[0] = TerrainMesher.pack_chunk(TerrainMesher.build_chunk_arrays(snapshot, carve, cx, cz), looks))
			tasks[Vector2i(x, z)] = [task, result, snapshot]
	var mismatches := 0
	var extra_mismatches := 0
	for key: Vector2i in tasks:
		var entry: Array = tasks[key]
		var task_id: int = entry[0]
		WorkerThreadPool.wait_for_task_completion(task_id)
		var snapshot: Node3D = entry[2]
		snapshot.free()
		var result: Array[Dictionary] = entry[1]
		var parts := TerrainMesher.assemble_packed(terrain, result[0])
		if parts.is_empty():
			continue
		var mesh: ArrayMesh = parts["mesh"]
		if _mesh_hash(mesh) != expected[key]:
			mismatches += 1
			if mismatches <= 5:
				print("FAIL %s chunk %s differs from the main-thread build" % [label, key])
		var faces: PackedVector3Array = parts["faces"]
		var caster := MeshUtils.caster_mesh(parts["caster"])
		var reference := MeshUtils.back_face_caster(mesh)
		if not _same_faces(faces, mesh.get_faces()) or _mesh_hash(caster) != _mesh_hash(reference):
			extra_mismatches += 1
			if extra_mismatches <= 5:
				print("FAIL %s chunk %s: worker faces / caster differ from the mesh's" % [label, key])
	var threaded_ms := (Time.get_ticks_usec() - t) / 1000.0
	_failures += mismatches + extra_mismatches
	print("%s: %d chunks, %d differ, %d faces / casters differ | main thread %.0f ms, %d threads %.0f ms" % [
		label, count * count, mismatches, extra_mismatches, serial_ms, OS.get_processor_count(), threaded_ms])

## get_faces() goes through a TriangleMesh, which snaps the positions to
## 0.1 mm: the worker's faces are the exact ones.
static func _same_faces(exact: PackedVector3Array, snapped: PackedVector3Array) -> bool:
	if exact.size() != snapped.size():
		return false
	for i in exact.size():
		if not (exact[i] - snapped[i]).abs().is_zero_approx() and (exact[i] - snapped[i]).abs().length() > 0.0002:
			return false
	return true

static func _mesh_hash(mesh: ArrayMesh) -> int:
	var bytes := PackedByteArray()
	for surface in mesh.get_surface_count():
		bytes.append_array(var_to_bytes(mesh.surface_get_arrays(surface)))
		var material := mesh.surface_get_material(surface)
		bytes.append_array(str(material.get_instance_id() if material else 0).to_utf8_buffer())
	return hash(bytes)
