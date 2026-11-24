@tool
extends RefCounted
## Your own 3D model (a .glb / .gltf / .blend / .fbx / .tscn scene) turned into
## ONE mesh a detail layer can scatter (LowpolyDetailLayer.model): every
## MeshInstance3D of the scene, placed as in the scene, keeping its materials
## (one surface per material). Still one MultiMesh per layer and chunk.
##
## By default the model is moved so the bottom centre of its bounding box is
## at the origin (it stands on the ground, centred on its place); a layer can
## keep the model's own origin instead (model_keep_origin).
## Built once per model and kept until the model file changes.

## "<model path>|<keep_origin>" -> [scene instance id, file time, mesh].
## One entry per model: a reimport replaces it instead of adding one.
static var _cache: Dictionary = {}

## Merged mesh of `scene`, or null if it holds no mesh.
static func mesh_of(scene: PackedScene, keep_origin: bool = false) -> ArrayMesh:
	if scene == null:
		return null
	var path := scene.resource_path if not scene.resource_path.is_empty() else "#%d" % scene.get_instance_id()
	var key := "%s|%s" % [path, keep_origin]
	# The file only changes in the editor (reimport): the game skips the
	# disk query, asked once per chunk.
	var modified := _modified_time(scene.resource_path) if Engine.is_editor_hint() else 0
	var entry: Array = _cache.get(key, [])
	if not entry.is_empty() and entry[0] == scene.get_instance_id() and entry[1] == modified:
		return entry[2]
	var mesh := _merge(scene, keep_origin)
	_cache[key] = [scene.get_instance_id(), modified, mesh]
	return mesh

static func _modified_time(path: String) -> int:
	if path.is_empty() or not FileAccess.file_exists(path):
		return 0
	return FileAccess.get_modified_time(path)

static func _merge(scene: PackedScene, keep_origin: bool) -> ArrayMesh:
	var root := scene.instantiate()
	if root == null:
		return null
	var parts: Array = []  # [arrays, material]
	var bounds := AABB()
	var has_bounds := false
	_collect(root, Transform3D.IDENTITY, root, parts)
	root.free()
	if parts.is_empty():
		return null
	for part: Array in parts:
		var part_arrays: Array = part[0]
		var part_vertices: PackedVector3Array = part_arrays[Mesh.ARRAY_VERTEX]
		for v: Vector3 in part_vertices:
			if has_bounds:
				bounds = bounds.expand(v)
			else:
				bounds = AABB(v, Vector3.ZERO)
				has_bounds = true
	var shift := Vector3.ZERO
	if not keep_origin:
		shift = -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var mesh := ArrayMesh.new()
	for part: Array in parts:
		var arrays: Array = part[0]
		if shift != Vector3.ZERO:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in vertices.size():
				vertices[i] += shift
			arrays[Mesh.ARRAY_VERTEX] = vertices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var material: Material = part[1]
		if material != null:
			mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	return mesh

## Surfaces of every visible MeshInstance3D under `node`, in `root` space.
static func _collect(node: Node, parent_xform: Transform3D, root: Node, parts: Array) -> void:
	var xform := parent_xform
	if node is Node3D:
		if node != root:
			xform = parent_xform * (node as Node3D).transform
		if not (node as Node3D).visible:
			return
	var instance := node as MeshInstance3D
	if instance != null and instance.mesh != null:
		var normal_basis := xform.basis.inverse().transposed()
		for s in instance.mesh.get_surface_count():
			# Lines / points (ArrayMesh only; primitive meshes are triangles).
			if instance.mesh is ArrayMesh and (instance.mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var source := instance.mesh.surface_get_arrays(s)
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			var vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
			for i in vertices.size():
				vertices[i] = xform * vertices[i]
			arrays[Mesh.ARRAY_VERTEX] = vertices
			if source[Mesh.ARRAY_NORMAL] != null:
				var normals: PackedVector3Array = source[Mesh.ARRAY_NORMAL]
				for i in normals.size():
					normals[i] = (normal_basis * normals[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = normals
			if source[Mesh.ARRAY_TANGENT] != null:
				var tangents: PackedFloat32Array = source[Mesh.ARRAY_TANGENT]
				for i in range(0, tangents.size(), 4):
					var t := (xform.basis * Vector3(tangents[i], tangents[i + 1], tangents[i + 2])).normalized()
					tangents[i] = t.x
					tangents[i + 1] = t.y
					tangents[i + 2] = t.z
				arrays[Mesh.ARRAY_TANGENT] = tangents
			# Colours, UVs and indices as they are (no bones: the rest pose).
			for channel: int in [Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX]:
				arrays[channel] = source[channel]
			if xform.basis.determinant() < 0.0 and arrays[Mesh.ARRAY_INDEX] != null:
				# Mirrored node: flip the winding so faces still point out.
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				for i in range(0, indices.size() - 2, 3):
					var swap := indices[i + 1]
					indices[i + 1] = indices[i + 2]
					indices[i + 2] = swap
				arrays[Mesh.ARRAY_INDEX] = indices
			parts.append([arrays, instance.get_active_material(s)])
	for child in node.get_children():
		_collect(child, xform, root, parts)
