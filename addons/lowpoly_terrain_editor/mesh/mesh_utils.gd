@tool
extends RefCounted
## Triangle emission and ArrayMesh helpers shared by every mesher.
##
## IMPORTANT: Godot considers CLOCKWISE triangles front-facing. With the
## conventional (b-a) x (c-a) cross product, a correctly wound front face has
## its cross product pointing OPPOSITE the desired outward lighting normal. The
## helpers below swap b/c whenever cross and desired normal point the same way.

## Face normal flipped so it always points upward (y >= 0).
static func upward_face_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	return normal

static func add_oriented_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3, desired_normal: Vector3) -> void:
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return

	var n := desired_normal.normalized()
	if cross.dot(n) > 0.0:
		var temp := b
		b = c
		c = temp

	vertices.append_array([a, b, c])
	normals.append_array([n, n, n])

static func add_upward_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	add_oriented_triangle(vertices, normals, a, b, c, upward_face_normal(a, b, c))

## Terrain top face. `up_bias` (0..1) blends the face normal toward +Y.
static func add_top_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3, up_bias: float) -> void:
	var normal := upward_face_normal(a, b, c)
	if up_bias > 0.0:
		normal = normal.lerp(Vector3.UP, up_bias).normalized()
	add_oriented_triangle(vertices, normals, a, b, c, normal)

static func add_oriented_triangle_uv(vertices: Array, normals: Array, uvs: Array, a: Vector3, b: Vector3, c: Vector3, desired_normal: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	var n := desired_normal.normalized()
	if cross.dot(n) > 0.0:
		var temp_vertex := b
		b = c
		c = temp_vertex
		var temp_uv := uv_b
		uv_b = uv_c
		uv_c = temp_uv
	vertices.append_array([a, b, c])
	normals.append_array([n, n, n])
	uvs.append_array([uv_a, uv_b, uv_c])

static func add_upward_triangle_uv(vertices: Array, normals: Array, uvs: Array, a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	var desired_normal := upward_face_normal(a, b, c)
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	if cross.dot(desired_normal) > 0.0:
		var temp_vertex := b
		b = c
		c = temp_vertex
		var temp_uv := uv_b
		uv_b = uv_c
		uv_c = temp_uv
	vertices.append_array([a, b, c])
	normals.append_array([desired_normal, desired_normal, desired_normal])
	uvs.append_array([uv_a, uv_b, uv_c])

## Appends a triangle surface to `mesh`. Does nothing for empty geometry.
## `material` is assigned as-is (not copied), so surfaces built from the same
## cached material share it. Optional `uvs` / `colors` must match `vertices`.
static func add_surface(mesh: ArrayMesh, vertices: Array, normals: Array, material: Material, uvs: Array = [], colors: Array = []) -> void:
	if vertices.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(vertices)
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(normals)
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)
	if colors.size() == vertices.size():
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray(colors)

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

## Tangents for compressed vertices (ARRAY_FLAG_COMPRESS_ATTRIBUTES): Godot
## only compresses normals given with tangents (without, some normals come
## out turned over). Any unit vector across the normal does (no normal map
## reads them): 4 floats per vertex. Pure: runs on a worker thread.
static func tangents_for(normals: PackedVector3Array) -> PackedFloat32Array:
	var tangents := PackedFloat32Array()
	tangents.resize(normals.size() * 4)
	for i in normals.size():
		var n := normals[i]
		var t := (n.cross(Vector3.FORWARD) if absf(n.z) < 0.9 else n.cross(Vector3.RIGHT)).normalized()
		tangents[i * 4] = t.x
		tangents[i * 4 + 1] = t.y
		tangents[i * 4 + 2] = t.z
		tangents[i * 4 + 3] = 1.0
	return tangents

## Tangents of a planar-projected texture (top_uvs / cliff_uvs) for normal
## maps: U along +X from above, along the wall for cliffs; the sign puts
## Godot's binormal (cross(normal, tangent) * w) towards -V. Pure (threads).
static func planar_tangents(normals: PackedVector3Array, top: bool) -> PackedFloat32Array:
	var tangents := PackedFloat32Array()
	tangents.resize(normals.size() * 4)
	for i in normals.size():
		var n := normals[i]
		var u_axis := Vector3.RIGHT
		var v_axis := Vector3.BACK
		if not top:
			u_axis = Vector3.BACK if absf(n.x) > absf(n.z) else Vector3.RIGHT
			v_axis = Vector3.DOWN
		var t := u_axis - n * n.dot(u_axis)
		t = t.normalized() if t.length_squared() > 0.000001 else Vector3.RIGHT
		tangents[i * 4] = t.x
		tangents[i * 4 + 1] = t.y
		tangents[i * 4 + 2] = t.z
		tangents[i * 4 + 3] = 1.0 if n.cross(t).dot(-v_axis) >= 0.0 else -1.0
	return tangents

## add_surface() from packed arrays, with colours (no conversion). With
## `tangents` (tangents_for), the vertices are stored compressed: 16 bytes
## instead of 24 for the vertex-coloured ground, positions within ~1 mm.
static func add_arrays_surface(mesh: ArrayMesh, vertices: PackedVector3Array, normals: PackedVector3Array, material: Material,
		uvs: PackedVector2Array, colors: PackedColorArray, tangents: PackedFloat32Array = PackedFloat32Array()) -> void:
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if colors.size() == vertices.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	var flags := 0
	if tangents.size() == vertices.size() * 4:
		arrays[Mesh.ARRAY_TANGENT] = tangents
		flags = Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

## Blended-texture surface (TerrainMesher SPLAT_GROUP): colours plus the
## layer weights as two RGBA8 CUSTOM arrays (CUSTOM0 = layers 0-3,
## CUSTOM1 = 4-7, see terrain_splat.gdshader).
static func add_splat_surface(mesh: ArrayMesh, vertices: PackedVector3Array, normals: PackedVector3Array,
		colors: PackedColorArray, weights_a: PackedByteArray, weights_b: PackedByteArray, material: Material,
		tangents: PackedFloat32Array = PackedFloat32Array()) -> void:
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_CUSTOM0] = weights_a
	arrays[Mesh.ARRAY_CUSTOM1] = weights_b
	var flags := (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA8_UNORM << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	if tangents.size() == vertices.size() * 4:
		arrays[Mesh.ARRAY_TANGENT] = tangents
		flags |= Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, flags)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

## add_surface() from packed arrays (no conversion).
static func add_packed_surface(mesh: ArrayMesh, vertices: PackedVector3Array, normals: PackedVector3Array, material: Material, uvs: PackedVector2Array = PackedVector2Array()) -> void:
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)

## Metres the back-face caster sits under the ground (see back_face_caster).
const BACK_FACE_DROP := 0.1

## The shadow caster of a ground chunk: every triangle of `mesh` (all
## surfaces in one), positions only, vertices welded and indexed, winding
## REVERSED. Drawn with SHADOW_CASTING_SETTING_SHADOWS_ONLY, it puts only the
## ground's back faces (slopes turned away from the sun) in the shadow map:
## the lit ground, most of the map, is no longer drawn there, and mounds
## still shade what lies behind them (same silhouette; no self-shadow acne
## either). No material: Godot's shared shadow material draws it.
## `drop` lowers it under the visible ground: faces almost edge-on to the sun
## (mound crests) would otherwise shade themselves in a speckled pattern.
static func back_face_caster(mesh: ArrayMesh, drop: float = BACK_FACE_DROP) -> ArrayMesh:
	var vertex_lists: Array = []
	for surface in mesh.get_surface_count():
		vertex_lists.append(mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX])
	return caster_mesh(back_face_arrays(vertex_lists, drop))

## back_face_caster() as data, from the surfaces' vertices (pure: runs on a
## worker thread): [positions, indices].
static func back_face_arrays(vertex_lists: Array, drop: float = BACK_FACE_DROP) -> Array:
	var index_of := {}
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for list: PackedVector3Array in vertex_lists:
		var source := list
		var base := indices.size()
		indices.resize(base + source.size())
		for i in source.size():
			var p := source[i]
			var index: int = index_of.get(p, -1)
			if index < 0:
				index = positions.size()
				index_of[p] = index
				positions.append(Vector3(p.x, p.y - drop, p.z))
			# a, b, c -> a, c, b
			var corner := i % 3
			indices[base + i - corner + (0 if corner == 0 else 3 - corner)] = index
	return [positions, indices]

## The caster mesh of back_face_arrays() (main thread: uploads).
static func caster_mesh(caster_arrays: Array) -> ArrayMesh:
	var positions: PackedVector3Array = caster_arrays[0]
	var indices: PackedInt32Array = caster_arrays[1]
	var caster := ArrayMesh.new()
	if positions.is_empty():
		return caster
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_INDEX] = indices
	caster.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return caster

## World-planar X/Z UVs for horizontal faces.
static func top_uvs(vertices: Array, tile_size: float) -> Array:
	var result: Array[Vector2] = []
	var divisor: float = maxf(tile_size, 0.001)
	for vertex_variant: Variant in vertices:
		var vertex: Vector3 = vertex_variant
		result.append(Vector2(vertex.x / divisor, vertex.z / divisor))
	return result

## Projects each vertical wall onto its dominant horizontal axis. Using local
## coordinates makes adjacent triangles share the same UV scale and prevents the
## texture from collapsing to a single sampled colour.
static func cliff_uvs(vertices: Array, normals: Array, tile_size: float) -> Array:
	var result: Array[Vector2] = []
	var divisor: float = maxf(tile_size, 0.001)
	for i in range(vertices.size()):
		var vertex: Vector3 = vertices[i]
		var normal: Vector3 = normals[i] if i < normals.size() else Vector3.FORWARD
		var u: float = vertex.z / divisor if abs(normal.x) > abs(normal.z) else vertex.x / divisor
		var v: float = -vertex.y / divisor
		result.append(Vector2(u, v))
	return result
