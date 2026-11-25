@tool
extends RefCounted
## Builds the terrain ground geometry (top faces + cliff walls), one chunk of
## TERRAIN_CHUNK_CELLS x TERRAIN_CHUNK_CELLS cells at a time.
##
## Pure functions: they read terrain metadata and return an ArrayMesh, without
## touching the scene tree.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const MeshUtils = preload("mesh_utils.gd")
const TerrainShading = preload("terrain_shading.gd")

## Number of chunks along one side of the grid.
## top_groups key of the blended-texture top faces (not a style id).
const SPLAT_GROUP := -2

static func chunk_count(terrain: Node3D) -> int:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var cell_count: int = maxi(0, resolution - 1)
	return int(ceilf(float(cell_count) / float(Meta.TERRAIN_CHUNK_CELLS)))

static func chunk_name(chunk_x: int, chunk_z: int) -> String:
	return "Chunk_%d_%d" % [chunk_x, chunk_z]

## The chunk node (chunk_x, chunk_z) under `terrain`, null when not built.
static func find_chunk(terrain: Node3D, chunk_x: int, chunk_z: int) -> MeshInstance3D:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	return container.get_node_or_null(chunk_name(chunk_x, chunk_z)) as MeshInstance3D if container else null

## Builds the mesh of one chunk. Returns null when the chunk lies outside the
## grid. Surface 0 holds every untextured face (vertex colours); then the
## blended-texture tops (TerrainShading weights, terrain_splat.gdshader) when
## textured styles are blended; then one surface per other textured style,
## tops first, then cliffs.
static func build_chunk(terrain: Node3D, carve: PackedFloat32Array, chunk_x: int, chunk_z: int) -> ArrayMesh:
	# An ArrayMesh, or null when the chunk lies outside the grid (no "mesh").
	var mesh: ArrayMesh = build_chunk_parts(terrain, carve, chunk_x, chunk_z).get("mesh")
	return mesh

## build_chunk() that also returns the baked shading context (null when
## shading is off), reused by DetailScatter: {"mesh", "shading"}. Empty
## when the chunk lies outside the grid.
static func build_chunk_parts(terrain: Node3D, carve: PackedFloat32Array, chunk_x: int, chunk_z: int) -> Dictionary:
	return assemble_chunk(terrain, build_chunk_arrays(terrain, carve, chunk_x, chunk_z))

## build_chunk_parts() in two halves, for a worker thread:
##   - build_chunk_arrays() computes the faces. It only reads the terrain
##     metadata, so it can run on a WorkerThreadPool task, given a
##     thread_snapshot() of the terrain (never the terrain itself);
##   - assemble_chunk() makes the ArrayMesh and its materials, on the main
##     thread (it fills the shared material cache).
## Same result as build_chunk_parts(), bit for bit. Empty when the chunk lies
## outside the grid. {"mesh", "shading", "faces", "caster"} (assemble_packed).
## A worker can go one step further: pack_chunk() there, assemble_packed()
## here (only the uploads left on the main thread).
static func assemble_chunk(terrain: Node3D, arrays: Dictionary) -> Dictionary:
	if arrays.is_empty():
		return {}
	return assemble_packed(terrain, pack_chunk(arrays, chunk_looks(terrain)))

## A detached copy of the terrain metadata that build_chunk_arrays() can read
## on a worker thread: packed arrays are shared (copy on write), the style
## palette is deep-copied (reading a style writes its migrated fields). Free
## it (Node.free) once the task is over. Call prepare_threads() first.
static func thread_snapshot(terrain: Node3D) -> Node3D:
	var snapshot := Node3D.new()
	for key: StringName in terrain.get_meta_list():
		var value: Variant = terrain.get_meta(key)
		if key == Meta.STYLE_PALETTE and value is Array:
			var palette: Array = value
			value = palette.duplicate(true)
		snapshot.set_meta(key, value)
	return snapshot

## Creates, on the main thread, what the mesher would otherwise create lazily
## on first use (default biome, border noise), so worker threads only read.
static func prepare_threads(terrain: Node3D) -> void:
	TerrainShading.settings(terrain)
	TerrainShading.prepare_noise()

static func build_chunk_arrays(terrain: Node3D, carve: PackedFloat32Array, chunk_x: int, chunk_z: int) -> Dictionary:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var cell_count: int = resolution - 1
	var min_x: int = chunk_x * Meta.TERRAIN_CHUNK_CELLS
	var min_z: int = chunk_z * Meta.TERRAIN_CHUNK_CELLS
	if min_x >= cell_count or min_z >= cell_count:
		return {}

	var max_x: int = mini(min_x + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var max_z: int = mini(min_z + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var top_groups: Dictionary = {}
	var cliff_groups: Dictionary = {}
	var top_offset: float = Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var up_bias: float = clampf(Meta.get_float(terrain, Meta.TOP_NORMAL_UP_BIAS, 0.0), 0.0, 1.0)
	var shading := TerrainShading.prepare(terrain, carve, min_x, min_z, max_x, max_z)
	var shaded := shading != null
	var base_y: float = terrain.get_meta(Meta.BASE_Y, Meta.DEFAULT_BASE_Y)
	var cliff_offset: float = terrain.get_meta(Meta.CLIFF_Y_OFFSET, 0.0)

	# Hot loop on pre-fetched data (same values as TerrainData.cell_active,
	# the cell style and the carved vertex position, ~4x fewer calls):
	# active flags of the chunk cells plus a one-cell ring (cliff neighbours),
	# and every corner vertex computed once instead of once per touching cell.
	var flags_w := max_x - min_x + 2
	var flags := _active_flags(terrain, min_x - 1, min_z - 1, flags_w, max_z - min_z + 2)
	var corners_w := max_x - min_x + 1
	var corners := _corner_vertices(terrain, carve, min_x, min_z, corners_w, max_z - min_z + 1, top_offset)
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES)
	var resolution_cells := resolution - 1
	# Smooth Ground: one normal (and baked colour) per vertex, shared by the
	# triangles around it. Same vertex count as the faceted ground.
	var smooth := Meta.get_bool(terrain, Meta.SHADE_SMOOTH, Meta.DEFAULT_SHADE_SMOOTH)
	var vertex_normals := PackedVector3Array()
	if smooth:
		vertex_normals = _vertex_normals(terrain, carve, flags, flags_w, min_x, min_z, corners_w, max_z - min_z + 1, up_bias)
	var vertex_colors := shading.vertex_colors if shaded and smooth else PackedColorArray()
	# Blended textures: faces with a texture weight go to one surface.
	var splat := shaded and not shading.layers.is_empty()
	var textured := shading.textured if splat else PackedByteArray()

	for z in range(min_z, max_z):
		for x in range(min_x, max_x):
			var lx := x - min_x
			var lz := z - min_z
			var flag_index := (lz + 1) * flags_w + lx + 1
			if flags[flag_index] == 0:
				continue

			var style_index := z * resolution_cells + x
			var style_id: int = maxi(cell_styles[style_index], 0) if style_index < cell_styles.size() else 0
			var top_group := _style_group(top_groups, style_id)
			var cliff_group := _style_group(cliff_groups, style_id)
			# Textured styles past the blended layers keep their own surface.
			var blends := splat and (shading.layers.has(style_id) or not shading.textured_top.has(style_id))
			# A blended style's own faces are always in the blended surface.
			var in_layer := splat and shading.layers.has(style_id)

			var corner := lz * corners_w + lx
			var p00 := corners[corner]
			var p10 := corners[corner + 1]
			var p01 := corners[corner + corners_w]
			var p11 := corners[corner + corners_w + 1]
			var open_left := flags[flag_index - 1] == 0
			var open_right := flags[flag_index + 1] == 0
			var open_forward := flags[flag_index - flags_w] == 0
			var open_back := flags[flag_index + flags_w] == 0

			if smooth:
				var n00 := vertex_normals[corner]
				var n10 := vertex_normals[corner + 1]
				var n01 := vertex_normals[corner + corners_w]
				var n11 := vertex_normals[corner + corners_w + 1]
				var i10 := corner + 1
				var i01 := corner + corners_w
				var i11 := corner + corners_w + 1
				if in_layer or (blends and (textured[corner] | textured[i10] | textured[i11]) != 0):
					var splat_group := _splat_group(top_groups)
					var splat_vertices: Array = splat_group["vertices"]
					var splat_normals: Array = splat_group["normals"]
					var order := _add_smooth_triangle(splat_vertices, splat_normals, p00, p10, p11, n00, n10, n11)
					_append_splat(splat_group, shading, order, corner, i10, i11)
				else:
					var smooth_vertices: Array = top_group["vertices"]
					var smooth_normals: Array = top_group["normals"]
					var order := _add_smooth_triangle(smooth_vertices, smooth_normals, p00, p10, p11, n00, n10, n11)
					if shaded and order != 0:
						var smooth_colors: Array = top_group["colors"]
						_append_corner_colors(smooth_colors, order, vertex_colors[corner], vertex_colors[i10], vertex_colors[i11])
				if in_layer or (blends and (textured[corner] | textured[i11] | textured[i01]) != 0):
					var splat_group := _splat_group(top_groups)
					var splat_vertices: Array = splat_group["vertices"]
					var splat_normals: Array = splat_group["normals"]
					var order := _add_smooth_triangle(splat_vertices, splat_normals, p00, p11, p01, n00, n11, n01)
					_append_splat(splat_group, shading, order, corner, i11, i01)
				else:
					var smooth_vertices: Array = top_group["vertices"]
					var smooth_normals: Array = top_group["normals"]
					var order := _add_smooth_triangle(smooth_vertices, smooth_normals, p00, p11, p01, n00, n11, n01)
					if shaded and order != 0:
						var smooth_colors: Array = top_group["colors"]
						_append_corner_colors(smooth_colors, order, vertex_colors[corner], vertex_colors[i11], vertex_colors[i01])
			elif not shaded:
				var flat_vertices: Array = top_group["vertices"]
				var flat_normals: Array = top_group["normals"]
				MeshUtils.add_top_triangle(flat_vertices, flat_normals, p00, p10, p11, up_bias)
				MeshUtils.add_top_triangle(flat_vertices, flat_normals, p00, p11, p01, up_bias)
			if not shaded:
				var cliff_vertices: Array = cliff_group["vertices"]
				var cliff_normals: Array = cliff_group["normals"]
				if open_left: _add_cliff_quad(base_y, cliff_offset, p00, p01, Vector3.LEFT, cliff_vertices, cliff_normals)
				if open_right: _add_cliff_quad(base_y, cliff_offset, p11, p10, Vector3.RIGHT, cliff_vertices, cliff_normals)
				# Grid z- is local -Z (Godot FORWARD); grid z+ is local +Z (BACK).
				if open_forward: _add_cliff_quad(base_y, cliff_offset, p10, p00, Vector3.FORWARD, cliff_vertices, cliff_normals)
				if open_back: _add_cliff_quad(base_y, cliff_offset, p01, p11, Vector3.BACK, cliff_vertices, cliff_normals)
				continue

			if not smooth and shaded and (in_layer or blends and (textured[((z - min_z) * shading.cw + (x - min_x)) * 2] | textured[((z - min_z) * shading.cw + (x - min_x)) * 2 + 1]) != 0):
				# Blended textures (one of the two faces at least): per face,
				# like the colours.
				var face := ((z - min_z) * shading.cw + (x - min_x)) * 2
				for tri in 2:
					var to_splat := in_layer or textured[face + tri] != 0
					var group := _splat_group(top_groups) if to_splat else top_group
					var tri_vertices: Array = group["vertices"]
					var tri_normals: Array = group["normals"]
					var emitted := tri_vertices.size()
					if tri == 0:
						MeshUtils.add_top_triangle(tri_vertices, tri_normals, p00, p10, p11, up_bias)
					else:
						MeshUtils.add_top_triangle(tri_vertices, tri_normals, p00, p11, p01, up_bias)
					if tri_vertices.size() == emitted:
						continue
					if to_splat:
						_append_splat_face(group, shading, face + tri)
					else:
						var tri_colors: Array = group["colors"]
						var color: Color = shading.faces[face + tri]
						tri_colors.append_array([color, color, color])
			elif not smooth:
				# Inlined (hot loop): one baked colour per emitted triangle.
				var top_vertices: Array = top_group["vertices"]
				var top_normals: Array = top_group["normals"]
				var top_colors: Array = top_group["colors"]
				var face := ((z - min_z) * shading.cw + (x - min_x)) * 2
				var emitted := top_vertices.size()
				MeshUtils.add_top_triangle(top_vertices, top_normals, p00, p10, p11, up_bias)
				if top_vertices.size() != emitted:
					var color: Color = shading.faces[face]
					top_colors.append_array([color, color, color])
				emitted = top_vertices.size()
				MeshUtils.add_top_triangle(top_vertices, top_normals, p00, p11, p01, up_bias)
				if top_vertices.size() != emitted:
					var color: Color = shading.faces[face + 1]
					top_colors.append_array([color, color, color])
			if open_left or open_right or open_forward or open_back:
				var fx := float(x)
				var fz := float(z)
				if open_left: _add_shaded_cliff_quad(base_y, cliff_offset, shading, cliff_group, x, z, 0, style_id, fx, fz + 0.5, p00, p01, Vector3.LEFT)
				if open_right: _add_shaded_cliff_quad(base_y, cliff_offset, shading, cliff_group, x, z, 1, style_id, fx + 1.0, fz + 0.5, p11, p10, Vector3.RIGHT)
				if open_forward: _add_shaded_cliff_quad(base_y, cliff_offset, shading, cliff_group, x, z, 2, style_id, fx + 0.5, fz, p10, p00, Vector3.FORWARD)
				if open_back: _add_shaded_cliff_quad(base_y, cliff_offset, shading, cliff_group, x, z, 3, style_id, fx + 0.5, fz + 1.0, p01, p11, Vector3.BACK)

	# Every cell of the chunk and of the ring around it painted (no cliff
	# wall) and a square chunk: its ground is a height map (height_field).
	var full := max_x - min_x == max_z - min_z and not flags.has(0)
	return {"top_groups": top_groups, "cliff_groups": cliff_groups, "shaded": shaded, "shading": shading,
		"corners": corners, "corners_w": corners_w, "full": full}

## The chunk's ground as a height map, for its collision (HeightMapShape3D:
## ~25x less memory than its triangles and ~40x faster to make, with Jolt):
## [map_data, side, shape transform (chunk-local = terrain-local)], or []
## when the chunk has cliff walls (unpainted cells in it or beside it) or is
## not square. The shape is turned 90 degrees about Y: a height map splits
## its cells along the (x+1, z)-(x, z+1) diagonal, the ground along
## (x, z)-(x+1, z+1); turned, they match to 0.1 mm
## (tools/check_heightmap_collision.gd). Heights are divided by the cell
## spacing, which the transform scales back (a uniform scale).
static func height_field(arrays: Dictionary) -> Array:
	if not arrays.get("full", false):
		return []
	var corners: PackedVector3Array = arrays["corners"]
	var n: int = arrays["corners_w"]
	if n < 2 or corners.size() != n * n:
		return []
	var spacing := corners[1].x - corners[0].x
	if spacing <= 0.0:
		return []
	var inverse := 1.0 / spacing
	var data := PackedFloat32Array()
	data.resize(n * n)
	for j in n:
		for i in n:
			data[j * n + i] = corners[(n - 1 - i) * n + j].y * inverse
	var centre := (corners[0] + corners[n * n - 1]) * 0.5
	var basis := Basis(Vector3.UP, PI * 0.5).scaled(Vector3(spacing, spacing, spacing))
	return [data, n, Transform3D(basis, Vector3(centre.x, 0.0, centre.z))]

## The chunk mesh from its faces grouped by style (style id -> {vertices,
## normals, colors}), tops and cliffs apart.
## The surfaces of a chunk mesh from build_chunk_arrays(), as packed arrays
## (pure data: runs on a worker thread, `looks` = chunk_looks() read on the
## main thread before). Untextured tops and cliffs of every style are merged
## into ONE surface that carries the style colours as vertex colours (one
## draw call per chunk); textured faces keep one surface per style, since
## they need their own texture and UV scale. Also the chunk's collision faces
## (every triangle, in surface order: = ArrayMesh.get_faces()) and its
## shadow caster (MeshUtils.back_face_arrays()), so the main thread only
## uploads: {"surfaces": [[style id (-1 = vertex colours), top, vertices,
## normals, colours, uvs]], "faces", "caster", "shading"}.
static func pack_chunk(arrays: Dictionary, looks: Dictionary) -> Dictionary:
	if arrays.is_empty():
		return {}
	var top_groups: Dictionary = arrays["top_groups"]
	var cliff_groups: Dictionary = arrays["cliff_groups"]
	var shaded: bool = arrays["shaded"]
	# LodMesher.add_chunk_skirt (far blocks on): merged into the colours.
	var extra: Array = arrays.get("skirt", [])
	var colored_vertices: Array = []
	var colored_normals: Array = []
	var colored_colors: Array = []
	var textured_surfaces: Array = []
	for is_top: bool in [true, false]:
		var groups: Dictionary = top_groups if is_top else cliff_groups
		var style_ids := groups.keys()
		style_ids.sort()
		for style_variant: int in style_ids:
			var style_id := int(style_variant)
			if style_id == SPLAT_GROUP:
				continue
			var group: Dictionary = groups[style_id]
			var group_vertices: Array = group["vertices"]
			if group_vertices.is_empty():
				continue
			var look := _look(looks, style_id, is_top)
			if not look[0]:
				var group_normals: Array = group["normals"]
				colored_vertices.append_array(group_vertices)
				colored_normals.append_array(group_normals)
				if shaded:
					var group_colors: Array = group["colors"]
					colored_colors.append_array(group_colors)
				else:
					var colors: Array = []
					colors.resize(group_vertices.size())
					colors.fill(look[2])
					colored_colors.append_array(colors)
			else:
				textured_surfaces.append([style_id, is_top, group, look[1]])
	if not extra.is_empty():
		# [vertices, normals, colors] in the vertex-colour surface.
		var extra_vertices: Array = extra[0]
		var extra_normals: Array = extra[1]
		var extra_colors: Array = extra[2]
		colored_vertices.append_array(extra_vertices)
		colored_normals.append_array(extra_normals)
		colored_colors.append_array(extra_colors)

	var surfaces: Array = []
	if not colored_vertices.is_empty():
		surfaces.append([-1, true, PackedVector3Array(colored_vertices), PackedVector3Array(colored_normals),
			PackedColorArray(colored_colors), PackedVector2Array()])
	var splat_group: Dictionary = top_groups.get(SPLAT_GROUP, {})
	var splat_vertices: Array = splat_group.get("vertices", [])
	if not splat_vertices.is_empty():
		# [SPLAT_GROUP, true, vertices, normals, colours, no uvs, weights 0-3, weights 4-7].
		var splat_normals: Array = splat_group["normals"]
		var splat_colors: Array = splat_group["colors"]
		var splat_weights_a: Array = splat_group["weights_a"]
		var splat_weights_b: Array = splat_group["weights_b"]
		surfaces.append([SPLAT_GROUP, true, PackedVector3Array(splat_vertices), PackedVector3Array(splat_normals),
			PackedColorArray(splat_colors), PackedVector2Array(),
			_weight_bytes(splat_weights_a), _weight_bytes(splat_weights_b)])
	for entry: Array in textured_surfaces:
		var group: Dictionary = entry[2]
		var group_vertices: Array = group["vertices"]
		var group_normals: Array = group["normals"]
		var tile_size: float = entry[3]
		var is_top: bool = entry[1]
		var uvs := MeshUtils.top_uvs(group_vertices, tile_size) if is_top else MeshUtils.cliff_uvs(group_vertices, group_normals, tile_size)
		# Shaded cliffs keep their baked greys (TerrainShading.cliff_colors),
		# multiplied with the texture by their material.
		var wall_colors := PackedColorArray()
		if shaded and not is_top:
			var group_colors: Array = group["colors"]
			if group_colors.size() == group_vertices.size():
				wall_colors = PackedColorArray(group_colors)
		surfaces.append([entry[0], is_top, PackedVector3Array(group_vertices), PackedVector3Array(group_normals),
			wall_colors, PackedVector2Array(uvs)])
	var faces := PackedVector3Array()
	var vertex_lists: Array = []
	# looks["compress"] (TerrainRuntime.compress_vertices): tangents for the
	# compressed vertex format, one PackedFloat32Array per surface.
	var tangents: Array = []
	var compress: bool = looks.get("compress", false)
	for surface: Array in surfaces:
		var vertices: PackedVector3Array = surface[2]
		faces.append_array(vertices)
		vertex_lists.append(vertices)
		if compress:
			var normals: PackedVector3Array = surface[3]
			tangents.append(MeshUtils.tangents_for(normals))
	return {"surfaces": surfaces, "faces": faces, "caster": MeshUtils.back_face_arrays(vertex_lists), "shading": arrays["shading"],
		"field": height_field(arrays), "tangents": tangents}

## What pack_chunk() needs from the materials, read on the main thread: per
## style id (clamped to the palette, as MaterialFactory does) and side,
## [textured, tile size, flat colour].
static func chunk_looks(terrain: Node3D) -> Dictionary:
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	var count := maxi(palette.size(), 1)
	var entries: Array = []
	for style_id in count:
		for is_top: bool in [true, false]:
			entries.append([MaterialFactory.terrain_style_texture(terrain, style_id, is_top) != null,
				MaterialFactory.terrain_style_tile_size(terrain, style_id, is_top),
				MaterialFactory.terrain_style_color(terrain, style_id, is_top)])
	return {"count": count, "entries": entries}

static func _look(looks: Dictionary, style_id: int, is_top: bool) -> Array:
	var count: int = looks["count"]
	var entries: Array = looks["entries"]
	return entries[clampi(style_id, 0, count - 1) * 2 + (0 if is_top else 1)]

## The ArrayMesh of pack_chunk() surfaces, with their materials (main
## thread: uploads, and fills the shared material cache).
static func assemble_packed(terrain: Node3D, packed: Dictionary) -> Dictionary:
	if packed.is_empty():
		return {}
	var array_mesh := ArrayMesh.new()
	var tangents: Array = packed.get("tangents", [])
	var surface_index := -1
	for surface: Array in packed["surfaces"]:
		surface_index += 1
		var surface_tangents: PackedFloat32Array = tangents[surface_index] if surface_index < tangents.size() else PackedFloat32Array()
		var style_id: int = surface[0]
		var is_top: bool = surface[1]
		var vertices: PackedVector3Array = surface[2]
		var normals: PackedVector3Array = surface[3]
		var colors: PackedColorArray = surface[4]
		var uvs: PackedVector2Array = surface[5]
		if style_id == SPLAT_GROUP:
			var weights_a: PackedByteArray = surface[6]
			var weights_b: PackedByteArray = surface[7]
			MeshUtils.add_splat_surface(array_mesh, vertices, normals, colors, weights_a, weights_b,
				MaterialFactory.terrain_splat_material(terrain), surface_tangents)
			continue
		var material := MaterialFactory.terrain_vertex_color_material(terrain) if style_id < 0 \
			else MaterialFactory.terrain_style_material(terrain, style_id, is_top)
		MeshUtils.add_arrays_surface(array_mesh, vertices, normals, material, uvs, colors, surface_tangents)
	return {"mesh": array_mesh, "shading": packed["shading"], "faces": packed["faces"], "caster": packed["caster"],
		"field": packed.get("field", [])}

## Active flag (TerrainData.cell_active) of the cells [x0, x0 + width) x
## [z0, z0 + height), row-major; out-of-grid cells are inactive.
static func _active_flags(terrain: Node3D, x0: int, z0: int, width: int, height: int) -> PackedByteArray:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var has_cells := terrain.has_meta(Meta.CELL_ACTIVE)
	var cells: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE) if has_cells else PackedByteArray()
	var mask: PackedFloat32Array = PackedFloat32Array() if has_cells else terrain.get_meta(Meta.MASK, PackedFloat32Array())
	var flags := PackedByteArray()
	flags.resize(width * height)
	for j in height:
		var z := z0 + j
		for i in width:
			var x := x0 + i
			var active := false
			if x >= 0 and z >= 0 and x < resolution - 1 and z < resolution - 1:
				var index := GridMath.cell_index(x, z, resolution)
				if has_cells and index >= 0 and index < cells.size():
					active = cells[index] != 0
				else:
					active = GridMath.cell_active_for_mask(mask, x, z, resolution)
			flags[j * width + i] = 1 if active else 0
	return flags

## Carved positions (+ top offset) of the grid vertices
## [x0, x0 + width) x [z0, z0 + height), row-major.
static func _corner_vertices(terrain: Node3D, carve: PackedFloat32Array, x0: int, z0: int, width: int, height: int, top_offset: float) -> PackedVector3Array:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var corners := PackedVector3Array()
	corners.resize(width * height)
	for j in height:
		for i in width:
			var p := GridMath.grid_to_local(x0 + i, z0 + j, resolution, world_size)
			p.y = TerrainSampler.effective_height_at_grid_in(heights, carve, resolution, x0 + i, z0 + j)
			p.y += top_offset
			corners[j * width + i] = p
	return corners

## Smooth Ground normals of the vertices [x0, x0 + width) x [z0, z0 + height):
## height gradient by central differences, using only the edges of active
## cells (a cliff top edge does not lean toward the void beside it).
static func _vertex_normals(terrain: Node3D, carve: PackedFloat32Array, flags: PackedByteArray, flags_w: int,
		x0: int, z0: int, width: int, height: int, up_bias: float) -> PackedVector3Array:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var carved := carve.size() == heights.size()
	var spacing := world_size / float(maxi(resolution - 1, 1))
	var last := resolution - 1
	var normals := PackedVector3Array()
	normals.resize(width * height)
	for j in height:
		var vz := z0 + j
		# Flag rows of the cells above (vz - 1) and below (vz) the vertex.
		var row_up := j * flags_w
		var row_down := (j + 1) * flags_w
		for i in width:
			var vx := x0 + i
			var index := vz * resolution + vx
			var h := heights[index] - (carve[index] if carved else 0.0)
			# Cells around the vertex: flags column i = cell vx - 1, i + 1 = cell vx.
			var up_left := flags[row_up + i] != 0
			var up_right := flags[row_up + i + 1] != 0
			var down_left := flags[row_down + i] != 0
			var down_right := flags[row_down + i + 1] != 0
			var slope_x := 0.0
			var left := vx > 0 and (up_left or down_left)
			var right := vx < last and (up_right or down_right)
			if left or right:
				var hl := h
				var hr := h
				var span := 0.0
				if left:
					hl = heights[index - 1] - (carve[index - 1] if carved else 0.0)
					span += spacing
				if right:
					hr = heights[index + 1] - (carve[index + 1] if carved else 0.0)
					span += spacing
				slope_x = (hr - hl) / span
			var slope_z := 0.0
			var up := vz > 0 and (up_left or up_right)
			var down := vz < last and (down_left or down_right)
			if up or down:
				var hu := h
				var hd := h
				var span := 0.0
				if up:
					hu = heights[index - resolution] - (carve[index - resolution] if carved else 0.0)
					span += spacing
				if down:
					hd = heights[index + resolution] - (carve[index + resolution] if carved else 0.0)
					span += spacing
				slope_z = (hd - hu) / span
			var normal := Vector3(-slope_x, 1.0, -slope_z).normalized()
			if up_bias > 0.0:
				normal = normal.lerp(Vector3.UP, up_bias).normalized()
			normals[j * width + i] = normal
	return normals

## Top triangle with per-vertex normals, wound like MeshUtils.add_top_triangle
## (b and c swapped when needed). Returns 0 when degenerate (nothing added),
## 1 as given, 2 swapped.
static func _add_smooth_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> int:
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return 0
	if cross.y > 0.0:
		vertices.append_array([a, c, b])
		normals.append_array([na, nc, nb])
		return 2
	vertices.append_array([a, b, c])
	normals.append_array([na, nb, nc])
	return 1

static func _append_corner_colors(colors: Array, order: int, ca: Color, cb: Color, cc: Color) -> void:
	if order == 2:
		colors.append_array([ca, cc, cb])
	else:
		colors.append_array([ca, cb, cc])

## The blended-texture group of `top_groups` (made on first use).
static func _splat_group(top_groups: Dictionary) -> Dictionary:
	if not top_groups.has(SPLAT_GROUP):
		top_groups[SPLAT_GROUP] = {"vertices": [], "normals": [], "colors": [], "weights_a": [], "weights_b": []}
	return top_groups[SPLAT_GROUP]

## Blended-texture data of a smooth triangle (corner vertex indices of the
## shading context), in the order _add_smooth_triangle emitted it. Colour =
## baked colour of the untextured part, alpha = shade of the textures / 2.
static func _append_splat(group: Dictionary, shading: TerrainShading.Context, order: int, ia: int, ib: int, ic: int) -> void:
	if order == 0:
		return
	if order == 2:
		var swap := ib
		ib = ic
		ic = swap
	var colors: Array = group["colors"]
	var weights_a: Array = group["weights_a"]
	var weights_b: Array = group["weights_b"]
	for i: int in [ia, ib, ic]:
		var c: Color = shading.vertex_colors[i]
		colors.append(Color(c.r, c.g, c.b, clampf(shading.shades[i] * 0.5, 0.0, 1.0)))
		weights_a.append(shading.weights_a[i])
		weights_b.append(shading.weights_b[i])

## Blended-texture data of a faceted top face (one value for its 3 vertices).
static func _append_splat_face(group: Dictionary, shading: TerrainShading.Context, face: int) -> void:
	var c: Color = shading.faces[face]
	var color := Color(c.r, c.g, c.b, clampf(shading.shades[face] * 0.5, 0.0, 1.0))
	var wa: Color = shading.weights_a[face]
	var wb: Color = shading.weights_b[face]
	var colors: Array = group["colors"]
	var weights_a: Array = group["weights_a"]
	var weights_b: Array = group["weights_b"]
	colors.append_array([color, color, color])
	weights_a.append_array([wa, wa, wa])
	weights_b.append_array([wb, wb, wb])

## Weights as the RGBA8 bytes of a CUSTOM array.
static func _weight_bytes(weights: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(weights.size() * 4)
	var b := 0
	for weight: Color in weights:
		bytes[b] = clampi(roundi(weight.r * 255.0), 0, 255)
		bytes[b + 1] = clampi(roundi(weight.g * 255.0), 0, 255)
		bytes[b + 2] = clampi(roundi(weight.b * 255.0), 0, 255)
		bytes[b + 3] = clampi(roundi(weight.a * 255.0), 0, 255)
		b += 4
	return bytes

static func _style_group(groups: Dictionary, style_id: int) -> Dictionary:
	if not groups.has(style_id):
		groups[style_id] = {"vertices": [], "normals": [], "colors": []}
	return groups[style_id]

## A wall on a cell side whose neighbour is not painted.
static func _add_cliff_quad(base_y: float, cliff_offset: float, top_a: Vector3, top_b: Vector3, outward: Vector3, vertices: Array, normals: Array) -> void:
	top_a.y += cliff_offset
	top_b.y += cliff_offset
	var bottom_a := Vector3(top_a.x, base_y, top_a.z)
	var bottom_b := Vector3(top_b.x, base_y, top_b.z)

	# A cliff is conceptually vertical. Both triangles share one horizontal
	# outward normal, so culling and lighting agree.
	var wall_normal := outward.normalized()
	MeshUtils.add_oriented_triangle(vertices, normals, top_a, top_b, bottom_b, wall_normal)
	MeshUtils.add_oriented_triangle(vertices, normals, top_a, bottom_b, bottom_a, wall_normal)

# -----------------------------------------------------------------------------
# Shaded variants (TerrainShading enabled): same geometry plus one colour per
# vertex; untextured cliffs may get an extra lip band.
# -----------------------------------------------------------------------------

## Cliff wall darkening toward BASE_Y. On untextured walls taller than twice
## the lip height, the top band takes the ground colour (grass lip).
static func _add_shaded_cliff_quad(
	base_y: float, cliff_offset: float, shading: TerrainShading.Context, group: Dictionary, x: int, z: int, side: int, style_id: int,
	fx: float, fz: float, top_a: Vector3, top_b: Vector3, outward: Vector3
) -> void:
	var vertices: Array = group["vertices"]
	var normals: Array = group["normals"]
	var colors: Array = group["colors"]
	top_a.y += cliff_offset
	top_b.y += cliff_offset
	var wall_normal := outward.normalized()
	var palette := TerrainShading.cliff_colors(shading, x, z, side, style_id, fx, fz)
	var lip: Color = palette[0]
	var wall: Color = palette[1]
	var bottom: Color = palette[2]

	var lip_height := shading.lip_height
	var lowest_top := minf(top_a.y, top_b.y)
	if lip_height > 0.0 and lowest_top - base_y > lip_height * 2.0 and shading.untextured_cliff.get(style_id, false):
		var lip_a := Vector3(top_a.x, top_a.y - lip_height, top_a.z)
		var lip_b := Vector3(top_b.x, top_b.y - lip_height, top_b.z)
		var before := vertices.size()
		MeshUtils.add_oriented_triangle(vertices, normals, top_a, top_b, lip_b, wall_normal)
		MeshUtils.add_oriented_triangle(vertices, normals, top_a, lip_b, lip_a, wall_normal)
		for i in range(vertices.size() - before):
			colors.append(lip)
		top_a = lip_a
		top_b = lip_b

	var bottom_a := Vector3(top_a.x, base_y, top_a.z)
	var bottom_b := Vector3(top_b.x, base_y, top_b.z)
	var start := vertices.size()
	MeshUtils.add_oriented_triangle(vertices, normals, top_a, top_b, bottom_b, wall_normal)
	MeshUtils.add_oriented_triangle(vertices, normals, top_a, bottom_b, bottom_a, wall_normal)
	for i in range(start, vertices.size()):
		var vertex: Vector3 = vertices[i]
		colors.append(bottom if vertex.y == base_y else wall)
