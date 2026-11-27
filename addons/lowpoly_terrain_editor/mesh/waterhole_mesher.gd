@tool
extends RefCounted
## Dried waterhole geometry: the carve of the depression and the cracked mud
## plates of its floor (see styles/waterhole_style.gd for the data).
##
## The plates are the cells of a jittered-grid Voronoi diagram, each shrunk
## along its borders so the cracks between them show the dark ground below.
## Crack widths vary per border (hairlines next to wide cracks). Each plate is
## a low fan with curled-up edges, a slight tilt and a thin side skirt, flat
## shaded and vertex coloured: one opaque surface per waterhole that shares
## the terrain's vertex-colour material, no texture.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")

## Plates start this far above the ground, and dig this far below it with
## their side skirt (hides the gap on uneven ground).
const LIFT := 0.03
const SKIRT_DEPTH := 0.03
## Range of a seed point inside its grid cell (0.5 = anywhere).
const JITTER := 0.48
## Share of the plates split in two by a thinner secondary crack.
const SPLIT_CHANCE := 0.45
## Random tilt of a plate, in height per unit of distance from its centre.
const TILT := 0.035

## Adds the depression of every waterhole to `carve` (per-vertex depths, see
## RiverMesher.compute_carve). Digging keeps the deepest value; the lip only
## raises vertices that nothing digs.
static func add_carve(terrain: Node3D, carve: PackedFloat32Array) -> void:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	if resolution < 2 or carve.size() != resolution * resolution:
		return
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	for shape in WaterholeStyle.shapes(terrain):
		if shape.depth <= 0.0 and shape.lip <= 0.0:
			continue
		var b := shape.bounds
		var x0 := clampi(int(floorf((b.position.x + half) / spacing)), 0, resolution - 1)
		var x1 := clampi(int(ceilf((b.end.x + half) / spacing)), 0, resolution - 1)
		var z0 := clampi(int(floorf((b.position.y + half) / spacing)), 0, resolution - 1)
		var z1 := clampi(int(ceilf((b.end.y + half) / spacing)), 0, resolution - 1)
		for z in range(z0, z1 + 1):
			for x in range(x0, x1 + 1):
				var value := shape.carve_at(shape.distance(float(x) * spacing - half, float(z) * spacing - half))
				var index := z * resolution + x
				if value > 0.0:
					carve[index] = maxf(carve[index], value)
				elif value < 0.0 and carve[index] <= 0.0:
					carve[index] = minf(carve[index], value)

## Height of the carved terrain surface at a point, on the cell's two top
## triangles (split along p00-p11, like the terrain mesher). Same as
## TerrainSampler.surface_height_in(), kept for the tools that call it here.
static func surface_height(heights: PackedFloat32Array, carve: PackedFloat32Array, resolution: int, world_size: float, point: Vector2) -> float:
	return TerrainSampler.surface_height_in(heights, carve, resolution, world_size, point)

static func _hash(a: int, b: int, salt: int) -> int:
	var h: int = a * 374761393 + b * 668265263 + salt * 1442695041
	h = (h ^ (h >> 15)) * 2246822519
	h = (h ^ (h >> 13)) * 3266489917
	return h ^ (h >> 16)

static func _unit(h: int, shift: int) -> float:
	return float((h >> shift) & 0xFFFF) / 65536.0

## Mud plate mesh of one waterhole (terrain-local space), or null when it has
## no floor. `carve` must include the waterholes (TerrainBuilder's carve).
static func build(terrain: Node3D, carve: PackedFloat32Array, hole_variant: Variant) -> ArrayMesh:
	return assemble(terrain, build_arrays(terrain, carve, hole_variant))

## build() in two halves, like TerrainMesher.build_chunk_arrays /
## assemble_chunk: build_arrays() only reads the terrain metadata (a worker
## thread can run it on a TerrainMesher.thread_snapshot()), assemble() makes
## the mesh on the main thread. Empty arrays = no plates.
static func assemble(terrain: Node3D, arrays: Array) -> ArrayMesh:
	if arrays.is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, MaterialFactory.terrain_vertex_color_material(terrain))
	return mesh

static func build_arrays(terrain: Node3D, carve: PackedFloat32Array, hole_variant: Variant) -> Array:
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	var hole := WaterholeStyle.migrate(hole_variant, biome)
	var shape := WaterholeStyle.make_shape(hole, biome)
	if shape.floor_ratio <= 0.0:
		return []
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var top_offset: float = Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var plate_size: float = hole["plate_size"]
	var size := maxf(plate_size, 0.15)
	var hole_crack_width: float = hole["crack_width"]
	var crack_width := clampf(hole_crack_width, 0.0, size * 0.6)
	var hole_curl: float = hole["curl"]
	var curl := maxf(hole_curl, 0.0)
	var seed := shape.seed

	# Seed points on a grid rotated by the seed, in that grid's frame.
	var angle := float(seed & 0xFFFF) / 65536.0 * TAU
	var axis_u := Vector2(cos(angle), sin(angle))
	var axis_v := Vector2(-axis_u.y, axis_u.x)
	var center := Vector2(shape.cx, shape.cz)
	var reach := shape.radius * (1.0 + shape.irregularity) * shape.floor_ratio + size
	var n := int(ceilf(reach / size))
	var side := 2 * n + 5
	var points := PackedVector2Array()
	points.resize(side * side)
	for j in range(side):
		for i in range(side):
			var h := _hash(i - n - 2, j - n - 2, seed)
			points[j * side + i] = Vector2(
				(float(i - n - 2) + 0.5 + (_unit(h, 0) - 0.5) * 2.0 * JITTER) * size,
				(float(j - n - 2) + 0.5 + (_unit(h, 16) - 0.5) * 2.0 * JITTER) * size
			)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var clay := shape.clay
	var floor_ratio := shape.floor_ratio
	for j in range(2, side - 2):
		for i in range(2, side - 2):
			var key := j * side + i
			var p := points[key]
			var world_p := center + axis_u * p.x + axis_v * p.y
			var d := shape.distance(world_p.x, world_p.y)
			var t := d / floor_ratio
			if t > 1.05:
				continue
			var h := _hash(i, j, seed ^ 0x5bd1e995)
			# Plates thin out and shrink toward the edge of the floor.
			if t > 0.8 and _unit(h, 0) > 1.0 - (t - 0.8) / 0.25:
				continue

			# Voronoi cell: a square around the point clipped by the half-planes
			# of its neighbours, each moved inward by half the crack.
			var poly := PackedVector2Array([
				p + Vector2(-size, -size) * 1.6, p + Vector2(size, -size) * 1.6,
				p + Vector2(size, size) * 1.6, p + Vector2(-size, size) * 1.6,
			])
			for dj in range(-2, 3):
				for di in range(-2, 3):
					if di == 0 and dj == 0:
						continue
					var other_key := (j + dj) * side + (i + di)
					var q := points[other_key]
					var normal := (q - p).normalized()
					var pair := _hash(mini(key, other_key), maxi(key, other_key), seed)
					var gap := crack_width * (0.35 + 1.3 * _unit(pair, 0) * _unit(pair, 16))
					poly = _clip(poly, normal, normal.dot((p + q) * 0.5) - gap * 0.5)
					if poly.size() < 3:
						break
				if poly.size() < 3:
					break
			if poly.size() < 3:
				continue
			if t > 0.8:
				var shrink := lerpf(1.0, 0.55, clampf((t - 0.8) / 0.25, 0.0, 1.0))
				for k in range(poly.size()):
					poly[k] = p + (poly[k] - p) * shrink

			# Secondary crack: some plates split in two along a random line
			# (irregular shapes and sizes, like real drying mud).
			var pieces: Array[PackedVector2Array] = [poly]
			var h2 := _hash(j, i, seed ^ 0x27d4eb2f)
			if _unit(h2, 0) < SPLIT_CHANCE and poly.size() >= 4:
				var split_angle := _unit(h2, 16) * PI
				var split := Vector2(cos(split_angle), sin(split_angle))
				var offset := split.dot(p) + (_unit(h2, 32) - 0.5) * size * 0.35
				var half_gap := crack_width * 0.25
				pieces = [_clip(poly, split, offset - half_gap), _clip(poly, -split, -(offset + half_gap))]

			for piece_index in range(pieces.size()):
				var piece := pieces[piece_index]
				if piece.size() < 3:
					continue
				var hp := h if piece_index == 0 else _hash(i, j, seed ^ 0x165667b1)
				_emit_plate(vertices, normals, colors, piece, center, axis_u, axis_v, hp, t, size, curl, clay,
					heights, carve, resolution, world_size, top_offset)

	if vertices.is_empty():
		return []
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	return arrays

## One plate: `poly` in the seed grid frame. Fan top with curled edges, a
## random tilt, and a side skirt down into the ground.
static func _emit_plate(
	vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
	poly: PackedVector2Array, center: Vector2, axis_u: Vector2, axis_v: Vector2, h: int, t: float,
	size: float, curl: float, clay: Color,
	heights: PackedFloat32Array, carve: PackedFloat32Array, resolution: int, world_size: float, top_offset: float
) -> void:
	# To terrain space, with heights on the carved ground.
	var points := PackedVector2Array()
	var centroid := Vector2.ZERO
	for local in poly:
		var q := center + axis_u * local.x + axis_v * local.y
		points.append(q)
		centroid += q
	centroid /= float(points.size())
	var tilt_angle := _unit(h, 16) * TAU
	var tilt := Vector2(cos(tilt_angle), sin(tilt_angle)) * TILT * _unit(h, 32)
	# Raised by the largest tilt drop so no corner sinks into the ground.
	var tilt_base := tilt.length() * size
	var plate_curl := curl * (0.6 + 0.8 * _unit(h, 48))
	var tops := PackedVector3Array()
	var bottoms := PackedVector3Array()
	for q in points:
		var ground := surface_height(heights, carve, resolution, world_size, q) + top_offset
		var tilt_y := tilt.dot(q - centroid) + tilt_base
		tops.append(Vector3(q.x, ground + LIFT + plate_curl + tilt_y, q.y))
		bottoms.append(Vector3(q.x, ground - SKIRT_DEPTH, q.y))
	var mid_ground := surface_height(heights, carve, resolution, world_size, centroid) + top_offset
	var mid := Vector3(centroid.x, mid_ground + LIFT + tilt_base, centroid.y)

	# Some plates sun-bleached, darker toward the bank.
	var light := 0.86 + 0.2 * _unit(h, 8) - 0.08 * clampf(t, 0.0, 1.0)
	var warm := (_unit(h, 24) - 0.5) * 0.08
	var top_color := Color(clay.r * light * (1.0 + warm), clay.g * light, clay.b * light * (1.0 - warm)).clamp()
	var side_color := Color(top_color.r * 0.72, top_color.g * 0.68, top_color.b * 0.64)
	var count := points.size()
	for k in range(count):
		var a := tops[k]
		var b := tops[(k + 1) % count]
		_tri(vertices, normals, colors, mid, a, b, top_color, Vector3.UP)
		var outward := Vector3((a.x + b.x) * 0.5 - mid.x, 0.0, (a.z + b.z) * 0.5 - mid.z)
		_tri(vertices, normals, colors, a, b, bottoms[(k + 1) % count], side_color, outward)
		_tri(vertices, normals, colors, a, bottoms[(k + 1) % count], bottoms[k], side_color, outward)

## Keeps the part of a convex polygon where dot(point, normal) <= limit.
static func _clip(poly: PackedVector2Array, normal: Vector2, limit: float) -> PackedVector2Array:
	var output := PackedVector2Array()
	var count := poly.size()
	for k in range(count):
		var a := poly[k]
		var b := poly[(k + 1) % count]
		var da := normal.dot(a) - limit
		var db := normal.dot(b) - limit
		if da <= 0.0:
			output.append(a)
		if (da <= 0.0) != (db <= 0.0):
			output.append(a + (b - a) * (da / (da - db)))
	return output

## Appends a flat-shaded triangle facing `facing` (winding fixed to match).
static func _tri(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, c: Vector3, color: Color, facing: Vector3) -> void:
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < 1e-12:
		return
	if normal.dot(facing) < 0.0:
		var swap := b
		b = c
		c = swap
		normal = -normal
	normal = normal.normalized()
	vertices.append_array([a, b, c])
	normals.append_array([normal, normal, normal])
	colors.append_array([color, color, color])
