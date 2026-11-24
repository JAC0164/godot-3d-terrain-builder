@tool
extends RefCounted
## Road surface geometry.
##
## Roads are generated from a unified footprint per connected network: the
## distance to the network's centre lines is sampled on the terrain's own grid
## (union_cell_size), and each cell is split along the terrain's diagonal, so
## every road triangle lies in one ground triangle, at the same slope: the
## ground never pokes through, however steep. Cells fully inside the road are
## kept whole; triangles crossed by the road edge are clipped along it
## (marching triangles), so the edge is a straight-cut line instead of a
## staircase. This removes overlapping
## ribbon surfaces, junction special cases, sharp-corner self-overlap, loop
## seams and coplanar z-fighting.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const MeshUtils = preload("mesh_utils.gd")

## Groups roads into connected networks: two roads are in the same network
## when their footprints touch (edges closer than about one road-grid cell).
## Each group holds the roads as stored, in network order.
static func group_connected(roads: Array) -> Array:
	# Every road read once (migrate() copies it): its points, width and a box
	# that holds all it can touch, so far-apart pairs are skipped at once.
	var lines: Array[Array] = []
	var widths := PackedFloat64Array()
	var bounds: Array[Rect2] = []
	for road_variant: Variant in roads:
		var road: Dictionary = FeatureStyle.migrate(road_variant, FeatureStyle.ROAD)
		var points: Array = road.get("points", [])
		var raw_width: float = road.get("width", Meta.DEFAULT_ROAD_WIDTH)
		var width := maxf(raw_width, 0.01)
		lines.append(points)
		widths.append(width)
		bounds.append(GridMath.polyline_bounds(points, width * 0.5 + Meta.ROAD_NOMINAL_CELL * 0.375 + 0.01))
	var touch := func(a: int, b: int) -> bool:
		if lines[a].size() < 2 or lines[b].size() < 2:
			return false
		var touch_distance := (widths[a] + widths[b]) * 0.5 + Meta.ROAD_NOMINAL_CELL * 0.75
		return GridMath.polylines_within_distance(lines[a], lines[b], touch_distance)
	var groups: Array = []
	for indices in GridMath.connected_groups(bounds, touch):
		var group: Array = []
		for index in indices:
			group.append(roads[index])
		groups.append(group)
	return groups

## Cell of the road mesh grid: the terrain spacing, divided in n so it is at
## most ROAD_UNION_MAX_CELL. The grid's corners include every terrain vertex
## (union_grid_origin), so no road cell straddles a ground fold.
static func union_cell_size(terrain: Node3D) -> float:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var terrain_spacing := world_size / maxf(float(resolution - 1), 1.0)
	return terrain_spacing / maxf(ceilf(terrain_spacing / Meta.ROAD_UNION_MAX_CELL - 0.001), 1.0)

## Local x / z of the road grid's corner 0: the terrain's first vertex.
static func union_grid_origin(terrain: Node3D) -> float:
	return -Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE) * 0.5

## Signed distance to the road edge (negative inside) on the grid corners
## (corner (i, j) at grid_origin + (i, j) * cell_size) around the group's
## centre lines, stored densely (row-major) over the group's bounding box:
##   {origin: Vector2i (first corner), width: int, height: int,
##    values: PackedFloat32Array (`outside` far from every centre line),
##    cells: PackedInt32Array (sorted indices of the cells touching at least
##    one inside corner; a cell has the index of its lowest corner)}.
static func corner_field(road_group: Array, cell_size: float, grid_origin: float = 0.0) -> Dictionary:
	# The edge sits slightly outside the nominal width (it used to hide the
	# terrain poking through a sloped edge; kept so roads keep their width).
	var edge_margin := Meta.ROAD_NOMINAL_CELL * Meta.ROAD_UNION_EDGE_PADDING * 0.5
	var outside := cell_size * 4.0
	var segments: Array = []
	var min_corner := Vector2i(1 << 30, 1 << 30)
	var max_corner := Vector2i(-(1 << 30), -(1 << 30))
	for road_variant: Variant in road_group:
		var road: Dictionary = FeatureStyle.migrate(road_variant, FeatureStyle.ROAD)
		var raw_points: Array = road.get("points", [])
		if raw_points.size() < 2:
			continue
		var points := GridMath.dedupe_points(raw_points)
		if points.size() < 2:
			continue
		var raw_width: float = road.get("width", Meta.DEFAULT_ROAD_WIDTH)
		var radius := maxf(raw_width * 0.5, 0.01) + edge_margin
		# At least 1.5 cells beyond the edge, so every inside corner has its
		# four cells (and their corners) inside the box.
		var reach := radius + cell_size * 1.5
		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var low := Vector2i(int(floorf((minf(a.x, b.x) - reach - grid_origin) / cell_size)), int(floorf((minf(a.y, b.y) - reach - grid_origin) / cell_size)))
			var high := Vector2i(int(ceilf((maxf(a.x, b.x) + reach - grid_origin) / cell_size)), int(ceilf((maxf(a.y, b.y) + reach - grid_origin) / cell_size)))
			min_corner = min_corner.min(low)
			max_corner = max_corner.max(high)
			segments.append([a, b, radius, low, high])
	if segments.is_empty():
		return {"origin": Vector2i.ZERO, "width": 0, "height": 0, "values": PackedFloat32Array(), "cells": PackedInt32Array()}

	var width := max_corner.x - min_corner.x + 1
	var height := max_corner.y - min_corner.y + 1
	var values := PackedFloat32Array()
	values.resize(width * height)
	values.fill(outside)
	var inside_corners := PackedInt32Array()
	for segment: Array in segments:
		var a: Vector2 = segment[0]
		var ab: Vector2 = segment[1] - a
		var radius: float = segment[2]
		var low: Vector2i = segment[3]
		var high: Vector2i = segment[4]
		var length_squared := ab.length_squared()
		var inverse_length := 1.0 / length_squared if length_squared > 0.000001 else 0.0
		for corner_z in range(low.y, high.y + 1):
			var row := (corner_z - min_corner.y) * width - min_corner.x
			var z := float(corner_z) * cell_size + grid_origin
			for corner_x in range(low.x, high.x + 1):
				# Inlined GridMath.distance_to_segment (hot loop).
				var point := Vector2(float(corner_x) * cell_size + grid_origin, z)
				var t := clampf((point - a).dot(ab) * inverse_length, 0.0, 1.0)
				var value := point.distance_to(a + ab * t) - radius
				var index := row + corner_x
				var previous := values[index]
				if value < previous:
					values[index] = value
					if value <= 0.0 and previous > 0.0:
						inside_corners.append(index)

	var marked := PackedByteArray()
	marked.resize(width * height)
	var cells := PackedInt32Array()
	for corner: int in inside_corners:
		for cell: int in [corner, corner - 1, corner - width, corner - width - 1]:
			if marked[cell] == 0:
				marked[cell] = 1
				cells.append(cell)
	cells.sort()
	return {"origin": min_corner, "width": width, "height": height, "values": values, "cells": cells}

## Road surface for a connected group, styled after its first road.
## Returns {vertices, normals, uvs}.
static func build_surface_union(terrain: Node3D, carve: PackedFloat32Array, road_group: Array) -> Dictionary:
	var state := union_begin(terrain, carve, road_group)
	union_step(state)
	return union_result(state)

## build_surface_union() in slices, so a game can spread a big road network
## over several frames (TerrainRuntime): state := union_begin(), then
## union_step(state, budget) until it returns true, then union_result(state).
## Same output however it is sliced.
static func union_begin(terrain: Node3D, carve: PackedFloat32Array, road_group: Array) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var state := {"vertices": vertices, "normals": normals, "uvs": uvs, "next": 0, "cells": PackedInt32Array()}
	if road_group.is_empty():
		return state

	var representative: Dictionary = FeatureStyle.migrate(road_group[0], FeatureStyle.ROAD)
	var cell_size := union_cell_size(terrain)
	var grid_origin := union_grid_origin(terrain)
	var field := corner_field(road_group, cell_size, grid_origin)
	var values: PackedFloat32Array = field["values"]
	var feature_offset: float = Meta.get_float(terrain, Meta.FEATURE_Y_OFFSET, 0.0)
	var road_y_offset: float = representative.get("y_offset", Meta.DEFAULT_ROAD_Y_OFFSET)
	var y_offset: float = road_y_offset + feature_offset
	# Each grid corner and each edge crossing is sampled once (corner heights
	# on first use, crossings in the sampler's cache).
	var corner_heights := PackedFloat32Array()
	corner_heights.resize(values.size())
	corner_heights.fill(INF)
	var raw_tile_size: float = representative.get("tile_size", Meta.DEFAULT_ROAD_TILE_SIZE)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	state.merge({
		"cells": field["cells"],
		"values": values,
		"origin": field["origin"],
		"width": field["width"],
		"cell_size": cell_size,
		"grid_origin": grid_origin,
		"tile_size": maxf(raw_tile_size, 0.001),
		"corner_heights": corner_heights,
		"sampler": [terrain.get_meta(Meta.HEIGHTS), carve, resolution, world_size, y_offset, {}],
	}, true)
	return state

## Triangulates the next cells of union_begin()'s state; `budget_usec` > 0
## stops after about that long (0 = all). True when every cell is done.
static func union_step(state: Dictionary, budget_usec: int = 0) -> bool:
	var cells: PackedInt32Array = state["cells"]
	var next: int = state["next"]
	if next >= cells.size():
		return true
	var start := Time.get_ticks_usec()
	var vertices: Array[Vector3] = state["vertices"]
	var normals: Array[Vector3] = state["normals"]
	var uvs: Array[Vector2] = state["uvs"]
	next = _triangulate(state, next, cells.size(), vertices, normals, uvs, budget_usec, start)
	state["next"] = next
	return next >= cells.size()

## Triangulates cells[from] to cells[to - 1] into the arrays; returns the
## index of the next cell (before `to` when `budget_usec` > 0 ran out).
static func _triangulate(state: Dictionary, from: int, to: int, vertices: Array, normals: Array, uvs: Array, budget_usec: int = 0, start: int = 0) -> int:
	var cells: PackedInt32Array = state["cells"]
	var values: PackedFloat32Array = state["values"]
	var origin: Vector2i = state["origin"]
	var width: int = state["width"]
	var cell_size: float = state["cell_size"]
	var grid_origin: float = state["grid_origin"]
	var tile_size: float = state["tile_size"]
	var corner_heights: PackedFloat32Array = state["corner_heights"]
	var sampler: Array = state["sampler"]
	# Hot loop: the terrain data in locals.
	var heights: PackedFloat32Array = sampler[0]
	var carve: PackedFloat32Array = sampler[1]
	var resolution: int = sampler[2]
	var world_size: float = sampler[3]
	var y_offset: float = sampler[4]
	var next := from
	while next < to:
		if budget_usec > 0 and (next & 255) == 0 and next != from and Time.get_ticks_usec() - start >= budget_usec:
			break
		var cell: int = cells[next]
		next += 1
		for corner: int in [cell, cell + 1, cell + width, cell + width + 1]:
			if corner_heights[corner] == INF:
				var point := Vector2(float(origin.x + corner % width) * cell_size + grid_origin, float(origin.y + corner / width) * cell_size + grid_origin)
				corner_heights[corner] = TerrainSampler.surface_height_in(heights, carve, resolution, world_size, point) + y_offset
		var i00 := cell
		var i10 := cell + 1
		var i01 := cell + width
		var i11 := cell + width + 1
		var in00 := values[i00] <= 0.0
		var in10 := values[i10] <= 0.0
		var in01 := values[i01] <= 0.0
		var in11 := values[i11] <= 0.0
		var x0 := float(origin.x + cell % width) * cell_size + grid_origin
		var z0 := float(origin.y + cell / width) * cell_size + grid_origin
		var x1 := x0 + cell_size
		var z1 := z0 + cell_size
		var p00 := Vector3(x0, corner_heights[i00], z0)
		var p10 := Vector3(x1, corner_heights[i10], z0)
		var p01 := Vector3(x0, corner_heights[i01], z1)
		var p11 := Vector3(x1, corner_heights[i11], z1)
		if in00 and in10 and in01 and in11:
			# Whole quad, same diagonal as the terrain cells. World-planar UVs
			# stay continuous across intersections, loops, overlaps and turns.
			_add_triangle(vertices, normals, uvs, p00, p11, p10, tile_size)
			_add_triangle(vertices, normals, uvs, p00, p01, p11, tile_size)
			continue
		# Cell crossed by the road edge: each of its two triangles (the
		# terrain's, split along 00-11) keeps its inside part, cut where the
		# distance crosses zero (marching triangles). Each crossing of a cell
		# side is computed from the side's lower corner, so both cells sharing
		# it get the exact same point.
		var diagonal := Vector3.ZERO
		if in00 != in11:
			diagonal = p00.lerp(p11, values[i00] / (values[i00] - values[i11]))
			diagonal.y = TerrainSampler.surface_height_in(heights, carve, resolution, world_size, Vector2(diagonal.x, diagonal.z)) + y_offset
		# Triangle 00 - 10 - 11.
		var ring: Array[Vector3] = []
		if in00:
			ring.append(p00)
		if in00 != in10:
			ring.append(_edge_point(values, sampler, i00, i10, 0, p00, p10))
		if in10:
			ring.append(p10)
		if in10 != in11:
			ring.append(_edge_point(values, sampler, i10, i11, 1, p10, p11))
		if in11:
			ring.append(p11)
		if in11 != in00:
			ring.append(diagonal)
		for i in range(1, ring.size() - 1):
			_add_triangle(vertices, normals, uvs, ring[0], ring[i], ring[i + 1], tile_size)
		# Triangle 00 - 11 - 01.
		ring.clear()
		if in00:
			ring.append(p00)
		if in00 != in11:
			ring.append(diagonal)
		if in11:
			ring.append(p11)
		if in11 != in01:
			ring.append(_edge_point(values, sampler, i01, i11, 0, p01, p11))
		if in01:
			ring.append(p01)
		if in01 != in00:
			ring.append(_edge_point(values, sampler, i00, i01, 1, p00, p01))
		for i in range(1, ring.size() - 1):
			_add_triangle(vertices, normals, uvs, ring[0], ring[i], ring[i + 1], tile_size)

	# Packed arrays are copied on write: keep the corners sampled so far.
	state["corner_heights"] = corner_heights
	return next

## {vertices, normals, uvs} of a finished union_step() state.
static func union_result(state: Dictionary) -> Dictionary:
	return {"vertices": state["vertices"], "normals": state["normals"], "uvs": state["uvs"]}

## Cell rows of a band (bands_begin).
const BAND_ROWS := 32

## The road surface of a group kept for later edits (editor): the
## union_begin() state, triangulated in bands of BAND_ROWS cell rows, each
## band's arrays packed. bands_update() redoes the bands an edit crosses;
## bands_result() is the same surface as build_surface_union().
static func bands_begin(terrain: Node3D, carve: PackedFloat32Array, road_group: Array) -> Dictionary:
	var state := union_begin(terrain, carve, road_group)
	var cells: PackedInt32Array = state["cells"]
	var width: int = state.get("width", 1)
	# Cells are sorted by row: each band is one run of them.
	var starts := PackedInt32Array()
	var band_rows := PackedInt32Array()
	var last := -1
	for i in range(cells.size()):
		var band := (cells[i] / width) / BAND_ROWS
		if band != last:
			starts.append(i)
			band_rows.append(band)
			last = band
	starts.append(cells.size())
	state["band_starts"] = starts
	state["band_rows"] = band_rows
	var bands: Array = []
	for b in range(band_rows.size()):
		bands.append(_band(state, starts[b], starts[b + 1]))
	state["bands"] = bands
	return state

## The ground under `rect` (terrain-local X/Z) changed: its corners and edge
## crossings are sampled again from `terrain`'s heights and `carve`, the
## bands of those rows triangulated again. Everything else is reused (same
## heights there, same samples).
static func bands_update(state: Dictionary, terrain: Node3D, carve: PackedFloat32Array, rect: Rect2) -> void:
	var cells: PackedInt32Array = state["cells"]
	if cells.is_empty():
		return
	var sampler: Array = state["sampler"]
	sampler[0] = terrain.get_meta(Meta.HEIGHTS)
	sampler[1] = carve
	var world_size: float = sampler[3]
	var resolution: int = sampler[2]
	var origin: Vector2i = state["origin"]
	var width: int = state["width"]
	var cell_size: float = state["cell_size"]
	var grid_origin: float = state["grid_origin"]
	var corner_heights: PackedFloat32Array = state["corner_heights"]
	var height := corner_heights.size() / width
	# A sample reads the ground vertices around it: one terrain cell more.
	var grown := rect.grow(world_size / float(maxi(resolution - 1, 1)) + cell_size)
	var x0 := clampi(int(floorf((grown.position.x - grid_origin) / cell_size)) - origin.x, 0, width - 1)
	var x1 := clampi(int(ceilf((grown.end.x - grid_origin) / cell_size)) - origin.x, 0, width - 1)
	var z0 := clampi(int(floorf((grown.position.y - grid_origin) / cell_size)) - origin.y, 0, height - 1)
	var z1 := clampi(int(ceilf((grown.end.y - grid_origin) / cell_size)) - origin.y, 0, height - 1)
	if x1 < x0 or z1 < z0:
		return
	var cache: Dictionary = sampler[5]
	for z in range(z0, z1 + 1):
		for x in range(x0, x1 + 1):
			var corner := z * width + x
			corner_heights[corner] = INF
			cache.erase(corner * 2)
			cache.erase(corner * 2 + 1)
	state["corner_heights"] = corner_heights
	# Cells of rows z0 - 1 .. z1 use those corners.
	var starts: PackedInt32Array = state["band_starts"]
	var band_rows: PackedInt32Array = state["band_rows"]
	var bands: Array = state["bands"]
	var first_band := maxi(z0 - 1, 0) / BAND_ROWS
	var last_band := z1 / BAND_ROWS
	for b in range(band_rows.size()):
		if band_rows[b] >= first_band and band_rows[b] <= last_band:
			bands[b] = _band(state, starts[b], starts[b + 1])

## {vertices, normals, uvs} (packed) of a bands_begin() state.
static func bands_result(state: Dictionary) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for band: Array in state.get("bands", []):
		var band_vertices: PackedVector3Array = band[0]
		var band_normals: PackedVector3Array = band[1]
		var band_uvs: PackedVector2Array = band[2]
		vertices.append_array(band_vertices)
		normals.append_array(band_normals)
		uvs.append_array(band_uvs)
	return {"vertices": vertices, "normals": normals, "uvs": uvs}

static func _band(state: Dictionary, from: int, to: int) -> Array:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	_triangulate(state, from, to, vertices, normals, uvs)
	return [PackedVector3Array(vertices), PackedVector3Array(normals), PackedVector2Array(uvs)]

## Local X/Z box of a bands_begin() state's grid (empty without cells).
static func bands_rect(state: Dictionary) -> Rect2:
	var cells: PackedInt32Array = state["cells"]
	if cells.is_empty():
		return Rect2()
	var origin: Vector2i = state["origin"]
	var width: int = state["width"]
	var cell_size: float = state["cell_size"]
	var grid_origin: float = state["grid_origin"]
	var corner_heights: PackedFloat32Array = state["corner_heights"]
	var height := corner_heights.size() / width
	return Rect2(Vector2(origin) * cell_size + Vector2(grid_origin, grid_origin), Vector2(width, height) * cell_size)

## Point where the road edge crosses the grid edge from corner `low` to corner
## `high` (`axis` 0 = along x, 1 = along z), on the terrain. `sampler` is
## [heights, carve, resolution, world_size, y_offset, cache].
static func _edge_point(values: PackedFloat32Array, sampler: Array, low: int, high: int, axis: int, p_low: Vector3, p_high: Vector3) -> Vector3:
	var cache: Dictionary = sampler[5]
	var key := low * 2 + axis
	var cached: Variant = cache.get(key)
	if cached != null:
		return cached
	var value_low := values[low]
	var t := value_low / (value_low - values[high])
	var point := p_low.lerp(p_high, t)
	var heights: PackedFloat32Array = sampler[0]
	var carve: PackedFloat32Array = sampler[1]
	var resolution: int = sampler[2]
	var world_size: float = sampler[3]
	var y_offset: float = sampler[4]
	point.y = TerrainSampler.surface_height_in(heights, carve, resolution, world_size, Vector2(point.x, point.z)) + y_offset
	cache[key] = point
	return point

static func _add_triangle(vertices: Array, normals: Array, uvs: Array, a: Vector3, b: Vector3, c: Vector3, tile_size: float) -> void:
	MeshUtils.add_upward_triangle_uv(vertices, normals, uvs, a, b, c,
		Vector2(a.x, a.z) / tile_size, Vector2(b.x, b.z) / tile_size, Vector2(c.x, c.z) / tile_size)
