@tool
extends RefCounted
## Low-detail ground of the far chunks (LowpolyTerrainRuntime.far_distance):
## one mesh per block of BLOCK_CHUNKS x BLOCK_CHUNKS chunks, keeping one
## vertex in `step` (2, 4 or 8). Faceted, vertex colours only (one draw call
## per block): each kept vertex takes the baked colour of the full-detail
## cell at it, blended across the triangles, so it reads as the same ground
## from afar (one colour per coarse cell looked like pixels).
##
## A block leaves out the chunks shown in full detail (`excluded`, one bit per
## chunk), and hangs a skirt under its border and around those chunks: the
## coarse edge does not follow the detailed one between two kept vertices.
## The detailed chunks get one too (add_chunk_skirt), as the gap opens on
## whichever side is lower. Map edges and holes get the usual cliff down to
## Base Y.
##
## Same split as TerrainMesher: block_data() and block_arrays() only read
## metadata (worker thread, on a TerrainMesher.thread_snapshot()), assemble()
## makes the mesh on the main thread.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const MeshUtils = preload("mesh_utils.gd")
const TerrainMesher = preload("terrain_mesher.gd")
const TerrainShading = preload("terrain_shading.gd")

## Chunks per side of a block.
const BLOCK_CHUNKS := 4

## Blocks along one side of the grid.
static func block_count(terrain: Node3D) -> int:
	return int(ceilf(float(TerrainMesher.chunk_count(terrain)) / float(BLOCK_CHUNKS)))

## Bit of chunk (chunk_x, chunk_z) in the `excluded` mask of its block.
static func chunk_bit(chunk_x: int, chunk_z: int) -> int:
	return 1 << ((chunk_z % BLOCK_CHUNKS) * BLOCK_CHUNKS + chunk_x % BLOCK_CHUNKS)

## The coarse grid of a block (corners, colours, active cells), made once:
## block_arrays() turns it into a mesh for any set of excluded chunks.
## Empty when the block lies outside the grid.
static func block_data(terrain: Node3D, carve: PackedFloat32Array, block_x: int, block_z: int, step: int) -> Dictionary:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var cell_count := resolution - 1
	var span := BLOCK_CHUNKS * Meta.TERRAIN_CHUNK_CELLS
	var x0 := block_x * span
	var z0 := block_z * span
	if x0 >= cell_count or z0 >= cell_count:
		return {}
	var x1 := mini(x0 + span, cell_count)
	var z1 := mini(z0 + span, cell_count)
	var cw := ceili(float(x1 - x0) / float(step))
	var ch := ceili(float(z1 - z0) / float(step))

	# Corners: the same positions as the full-detail mesh at those vertices.
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var top_offset := Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var corners := PackedVector3Array()
	corners.resize((cw + 1) * (ch + 1))
	for j in ch + 1:
		var vz := mini(z0 + j * step, z1)
		for i in cw + 1:
			var vx := mini(x0 + i * step, x1)
			var p := GridMath.grid_to_local(vx, vz, resolution, world_size)
			p.y = TerrainSampler.effective_height_at_grid_in(heights, carve, resolution, vx, vz) + top_offset
			corners[j * (cw + 1) + i] = p

	# Active coarse cells (the full-detail cell at their centre), with a ring
	# of one coarse cell around the block for the cliffs.
	var flags_w := (x1 - x0) + 2 * step
	var flags := TerrainMesher._active_flags(terrain, x0 - step, z0 - step, flags_w, (z1 - z0) + 2 * step)
	var active := PackedByteArray()
	active.resize((cw + 2) * (ch + 2))
	for j in range(-1, ch + 1):
		for i in range(-1, cw + 1):
			var fx := mini(x0 + i * step + step / 2, x1 - 1) if i < cw else x1 + step / 2
			var fz := mini(z0 + j * step + step / 2, z1 - 1) if j < ch else z1 + step / 2
			var lx := fx - (x0 - step)
			var lz := fz - (z0 - step)
			var on := lx >= 0 and lz >= 0 and lx < flags_w and lz < (z1 - z0) + 2 * step and flags[lz * flags_w + lx] != 0
			active[(j + 1) * (cw + 2) + i + 1] = 1 if on else 0

	# Colours: the baked faces of the cell at each kept vertex, else the
	# style colours; the side colour of the cell at each coarse cell's centre.
	var shading := TerrainShading.prepare(terrain, carve, x0, z0, x1, z1)
	var colors := PackedColorArray()
	colors.resize((cw + 1) * (ch + 1))
	for j in ch + 1:
		var fz := mini(z0 + j * step, z1 - 1)
		for i in cw + 1:
			var fx := mini(x0 + i * step, x1 - 1)
			colors[j * (cw + 1) + i] = _top_color(terrain, shading, x0, z0, fx, fz)
	var cliffs := PackedColorArray()
	cliffs.resize(cw * ch)
	for j in ch:
		var fz := mini(z0 + j * step + step / 2, z1 - 1)
		for i in cw:
			var fx := mini(x0 + i * step + step / 2, x1 - 1)
			cliffs[j * cw + i] = MaterialFactory.terrain_style_color(terrain, _style_at(terrain, fx, fz), false)
	return {
		"block_x": block_x, "block_z": block_z, "step": step, "cw": cw, "ch": ch,
		"corners": corners, "active": active, "colors": colors, "cliffs": cliffs,
		"base_y": Meta.get_float(terrain, Meta.BASE_Y, Meta.DEFAULT_BASE_Y),
		"cliff_offset": Meta.get_float(terrain, Meta.CLIFF_Y_OFFSET, 0.0),
		"up_bias": clampf(MaterialFactory.TerrainBiome.of(terrain).flat_top_lighting, 0.0, 1.0),
		"skirt": float(step) * world_size / float(maxi(cell_count, 1)),
	}

## Mesh arrays of a block (block_data) without the chunks of `excluded`:
## [vertices, normals, colors] (Arrays), empty when nothing is left.
static func block_arrays(data: Dictionary, excluded: int) -> Array:
	if data.is_empty():
		return []
	var step: int = data["step"]
	var cw: int = data["cw"]
	var ch: int = data["ch"]
	var corners: PackedVector3Array = data["corners"]
	var active: PackedByteArray = data["active"]
	var colors: PackedColorArray = data["colors"]
	var cliffs: PackedColorArray = data["cliffs"]
	var base_y: float = data["base_y"]
	var cliff_offset: float = data["cliff_offset"]
	var up_bias: float = data["up_bias"]
	var skirt: float = data["skirt"]
	var cells_per_chunk := Meta.TERRAIN_CHUNK_CELLS / step
	var vertices: Array = []
	var normals: Array = []
	var vertex_colors: Array = []
	for j in ch:
		for i in cw:
			if active[(j + 1) * (cw + 2) + i + 1] == 0 or _excluded(excluded, i, j, cells_per_chunk):
				continue
			var p00 := corners[j * (cw + 1) + i]
			var p10 := corners[j * (cw + 1) + i + 1]
			var p01 := corners[(j + 1) * (cw + 1) + i]
			var p11 := corners[(j + 1) * (cw + 1) + i + 1]
			var k := j * cw + i
			var c00 := colors[j * (cw + 1) + i]
			var c10 := colors[j * (cw + 1) + i + 1]
			var c01 := colors[(j + 1) * (cw + 1) + i]
			var c11 := colors[(j + 1) * (cw + 1) + i + 1]
			_add_top(vertices, normals, vertex_colors, p00, p10, p11, c00, c10, c11, up_bias)
			_add_top(vertices, normals, vertex_colors, p00, p11, p01, c00, c11, c01, up_bias)
			# Sides: a cliff where the neighbour is off the map, a skirt where
			# it is another mesh (an excluded chunk, the next block).
			var cliff := cliffs[k]
			# A skirt shows only through a gap: the ground's colour, not the
			# darker side colour.
			var ground := (c00 + c10 + c01 + c11) * 0.25
			var sides: Array[Array] = [
				[i - 1, j, p00, p01, Vector3.LEFT],
				[i + 1, j, p11, p10, Vector3.RIGHT],
				[i, j - 1, p10, p00, Vector3.FORWARD],
				[i, j + 1, p01, p11, Vector3.BACK],
			]
			for side: Array in sides:
				var ni: int = side[0]
				var nj: int = side[1]
				var a: Vector3 = side[2]
				var b: Vector3 = side[3]
				var outward: Vector3 = side[4]
				var size := vertices.size()
				var color := cliff
				if active[(nj + 1) * (cw + 2) + ni + 1] == 0:
					TerrainMesher._add_cliff_quad(base_y, cliff_offset, a, b, outward, vertices, normals)
				elif ni < 0 or nj < 0 or ni >= cw or nj >= ch or _excluded(excluded, ni, nj, cells_per_chunk):
					_add_skirt(a, b, skirt, outward, vertices, normals)
					color = ground
				for n in vertices.size() - size:
					vertex_colors.append(color)
	if vertices.is_empty():
		return []
	return [vertices, normals, vertex_colors]

## block_arrays() as packed arrays, with the tangents of the compressed
## vertex format (MeshUtils.tangents_for), on the worker:
## [vertices, normals, colors, tangents], empty when empty.
static func pack_block(arrays: Array) -> Array:
	if arrays.is_empty():
		return []
	var vertex_list: Array = arrays[0]
	var normal_list: Array = arrays[1]
	var color_list: Array = arrays[2]
	var normals := PackedVector3Array(normal_list)
	return [PackedVector3Array(vertex_list), normals, PackedColorArray(color_list), MeshUtils.tangents_for(normals)]

## The block mesh (main thread: shared material), null when empty. From
## block_arrays(), or from pack_block() (compressed vertices).
static func assemble(terrain: Node3D, arrays: Array) -> ArrayMesh:
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	var material := MaterialFactory.terrain_vertex_color_material(terrain)
	if arrays.size() == 4:
		var packed_vertices: PackedVector3Array = arrays[0]
		var packed_normals: PackedVector3Array = arrays[1]
		var packed_colors: PackedColorArray = arrays[2]
		var tangents: PackedFloat32Array = arrays[3]
		MeshUtils.add_arrays_surface(mesh, packed_vertices, packed_normals, material, PackedVector2Array(), packed_colors, tangents)
		return mesh
	var vertices: Array = arrays[0]
	var normals: Array = arrays[1]
	var colors: Array = arrays[2]
	MeshUtils.add_surface(mesh, vertices, normals, material, [], colors)
	return mesh

## A detailed chunk's skirt (see the header), into the build_chunk_arrays()
## result of that chunk: assemble_chunk() merges it into the vertex-colour
## surface (no extra draw call). Along the chunk border, `step` cells deep,
## where both cells beside the edge are on (elsewhere a cliff is there).
static func add_chunk_skirt(terrain: Node3D, carve: PackedFloat32Array, arrays: Dictionary, chunk_x: int, chunk_z: int, step: int) -> void:
	if arrays.is_empty():
		return
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var cell_count := resolution - 1
	var x0 := chunk_x * Meta.TERRAIN_CHUNK_CELLS
	var z0 := chunk_z * Meta.TERRAIN_CHUNK_CELLS
	var x1 := mini(x0 + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var z1 := mini(z0 + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var depth := float(step) * world_size / float(maxi(cell_count, 1))
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var top_offset := Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var flags_w := x1 - x0 + 2
	var flags := TerrainMesher._active_flags(terrain, x0 - 1, z0 - 1, flags_w, z1 - z0 + 2)
	var shading: TerrainShading.Context = arrays["shading"]
	var vertices: Array = []
	var normals: Array = []
	var colors: Array = []
	# [inside cell, outside cell, edge start vertex, edge end vertex, outward]
	var edges: Array[Array] = []
	for x in range(x0, x1):
		edges.append([Vector2i(x, z0), Vector2i(x, z0 - 1), Vector2i(x + 1, z0), Vector2i(x, z0), Vector3.FORWARD])
		edges.append([Vector2i(x, z1 - 1), Vector2i(x, z1), Vector2i(x, z1), Vector2i(x + 1, z1), Vector3.BACK])
	for z in range(z0, z1):
		edges.append([Vector2i(x0, z), Vector2i(x0 - 1, z), Vector2i(x0, z), Vector2i(x0, z + 1), Vector3.LEFT])
		edges.append([Vector2i(x1 - 1, z), Vector2i(x1, z), Vector2i(x1, z + 1), Vector2i(x1, z), Vector3.RIGHT])
	for edge: Array in edges:
		var inside: Vector2i = edge[0]
		var outside: Vector2i = edge[1]
		if flags[(inside.y - z0 + 1) * flags_w + inside.x - x0 + 1] == 0 or flags[(outside.y - z0 + 1) * flags_w + outside.x - x0 + 1] == 0:
			continue
		var from: Vector2i = edge[2]
		var to: Vector2i = edge[3]
		var a := GridMath.grid_to_local(from.x, from.y, resolution, world_size)
		a.y = TerrainSampler.effective_height_at_grid_in(heights, carve, resolution, from.x, from.y) + top_offset
		var b := GridMath.grid_to_local(to.x, to.y, resolution, world_size)
		b.y = TerrainSampler.effective_height_at_grid_in(heights, carve, resolution, to.x, to.y) + top_offset
		var outward: Vector3 = edge[4]
		var size := vertices.size()
		_add_skirt(a, b, depth, outward, vertices, normals)
		var color := _top_color(terrain, shading, x0, z0, inside.x, inside.y)
		for n in vertices.size() - size:
			colors.append(color)
	if not vertices.is_empty():
		arrays["skirt"] = [vertices, normals, colors]

## Baked colour of cell (x, z) (mean of its two faces) from a shading
## context starting at (x0, z0), else its style's top colour.
static func _top_color(terrain: Node3D, shading: TerrainShading.Context, x0: int, z0: int, x: int, z: int) -> Color:
	if shading != null:
		var face := ((z - z0) * shading.cw + (x - x0)) * 2
		return shading.faces[face].lerp(shading.faces[face + 1], 0.5)
	return MaterialFactory.terrain_style_color(terrain, _style_at(terrain, x, z), true)

static func _style_at(terrain: Node3D, x: int, z: int) -> int:
	var cell_count: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION) - 1
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	var index := z * cell_count + x
	return maxi(cell_styles[index], 0) if index < cell_styles.size() else 0

## A top triangle with one colour per corner (MeshUtils.add_top_triangle,
## the colours following when the corners are swapped to face up).
static func _add_top(vertices: Array, normals: Array, colors: Array, a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color, up_bias: float) -> void:
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	var normal := MeshUtils.upward_face_normal(a, b, c)
	if up_bias > 0.0:
		normal = normal.lerp(Vector3.UP, up_bias).normalized()
	if cross.dot(normal) > 0.0:
		var swap := b
		b = c
		c = swap
		var swap_color := cb
		cb = cc
		cc = swap_color
	vertices.append_array([a, b, c])
	normals.append_array([normal, normal, normal])
	colors.append_array([ca, cb, cc])

static func _excluded(excluded: int, i: int, j: int, cells_per_chunk: int) -> bool:
	if excluded == 0:
		return false
	var bit := 1 << ((j / cells_per_chunk) * BLOCK_CHUNKS + i / cells_per_chunk)
	return (excluded & bit) != 0

## A vertical band under the edge a-b, `depth` below its lower end, facing
## `outward` but lit as the ground (normals up): a side normal made the 1 px
## seen through the gap a dark line.
static func _add_skirt(a: Vector3, b: Vector3, depth: float, outward: Vector3, vertices: Array, normals: Array) -> void:
	var first := normals.size()
	var bottom := minf(a.y, b.y) - depth
	var bottom_a := Vector3(a.x, bottom, a.z)
	var bottom_b := Vector3(b.x, bottom, b.z)
	MeshUtils.add_oriented_triangle(vertices, normals, a, b, bottom_b, outward)
	MeshUtils.add_oriented_triangle(vertices, normals, a, bottom_b, bottom_a, outward)
	for n in range(first, normals.size()):
		normals[n] = Vector3.UP
