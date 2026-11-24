@tool
extends RefCounted
## River carving and water surface geometry.
##
## Rivers do two things: they carve a channel into the terrain (a per-vertex
## depth array, see compute_carve) and they emit a water body on top of it.
## Rivers whose footprints touch are merged into a single water body.
##
## Water never climbs: each river has a water level along its centre line
## (water_levels) that only goes down from each end. Where the drawn path
## crosses higher ground (a hill), the channel is cut through it at that
## level, with banks sloping at BANK_SLOPE, instead of the water following
## the hill up and over.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const MeshUtils = preload("mesh_utils.gd")

## Rise of a cut bank per metre (1 = 45 degrees) where a river crosses
## higher ground, and how far (m) from the water edge a bank may reach.
const BANK_SLOPE := 1.0
const MAX_BANK_REACH := 10.0

## Water level along a river: its centre line resampled at the grid spacing
## {points: Array[Vector2], levels: PackedFloat32Array (level of each point,
## before Surface Drop), ground: PackedFloat32Array (uncarved ground there)}.
## From each end the level can only go down (running minimum of the ground)
## and the level is the higher of the two: on ground that only goes down it
## is the ground itself (as before), over a hill it stays at the height of
## the lower side (the channel is cut through), in a hollow lower than both
## ends it follows the ground. The drawing direction does not matter.
static func water_levels(heights: PackedFloat32Array, resolution: int, world_size: float, raw_points: Array) -> Dictionary:
	var spacing := world_size / maxf(float(resolution - 1), 1.0)
	var points := GridMath.resample_points(GridMath.dedupe_points(raw_points), spacing)
	var count := points.size()
	var ground := PackedFloat32Array()
	ground.resize(count)
	for i in count:
		ground[i] = TerrainSampler.uncarved_height_in(heights, resolution, world_size, points[i])
	var levels := PackedFloat32Array()
	levels.resize(count)
	var running := INF
	for i in count:
		running = minf(running, ground[i])
		levels[i] = running
	running = INF
	for i in range(count - 1, -1, -1):
		running = minf(running, ground[i])
		levels[i] = maxf(levels[i], running)
	return {"points": points, "levels": levels, "ground": ground}

## Carve depth per grid vertex (resolution^2 values, 0 where no river): the
## channel (Depth below the water level, smooth across the width) and, where
## the ground is higher than the water level, the cut through it.
static func compute_carve(terrain: Node3D) -> PackedFloat32Array:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var carve := PackedFloat32Array()
	carve.resize(resolution * resolution)
	carve.fill(0.0)

	if resolution < 2:
		return carve
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5

	for river_variant: Variant in terrain.get_meta(Meta.RIVERS, []):
		var river: Dictionary = FeatureStyle.migrate(river_variant, FeatureStyle.RIVER)
		var raw_points: Array = river.get("points", [])
		if raw_points.size() < 2:
			continue

		var raw_width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		var width: float = maxf(raw_width, 0.01)
		var radius: float = width * 0.62
		var flat_radius: float = width * 0.5
		var raw_depth: float = river.get("depth", Meta.DEFAULT_RIVER_DEPTH)
		var depth: float = maxf(raw_depth, 0.0)
		if depth <= 0.0:
			continue
		var line := water_levels(heights, resolution, world_size, raw_points)
		var points: Array[Vector2] = line["points"]
		var levels: PackedFloat32Array = line["levels"]
		var ground: PackedFloat32Array = line["ground"]

		for segment_index in range(points.size() - 1):
			var a: Vector2 = points[segment_index]
			var b: Vector2 = points[segment_index + 1]
			var level_a: float = levels[segment_index]
			var level_b: float = levels[segment_index + 1]
			# Higher ground than the water here: wider reach for the cut banks.
			var excess := maxf(maxf(ground[segment_index] - level_a, ground[segment_index + 1] - level_b), 0.0)
			var reach := minf(maxf(radius, flat_radius + excess / BANK_SLOPE + width * 0.5), flat_radius + MAX_BANK_REACH)
			var min_x := clampi(int(floorf((minf(a.x, b.x) - reach + half) / spacing)), 0, resolution - 1)
			var max_x := clampi(int(ceilf((maxf(a.x, b.x) + reach + half) / spacing)), 0, resolution - 1)
			var min_z := clampi(int(floorf((minf(a.y, b.y) - reach + half) / spacing)), 0, resolution - 1)
			var max_z := clampi(int(ceilf((maxf(a.y, b.y) + reach + half) / spacing)), 0, resolution - 1)
			var ab := b - a
			var length_squared := ab.length_squared()
			var inverse_length := 1.0 / length_squared if length_squared > 0.000001 else 0.0

			for z in range(min_z, max_z + 1):
				var pz := float(z) * spacing - half
				for x in range(min_x, max_x + 1):
					# Inlined GridMath.distance_to_segment (hot loop).
					var point := Vector2(float(x) * spacing - half, pz)
					var t := clampf((point - a).dot(ab) * inverse_length, 0.0, 1.0)
					var distance := point.distance_to(a + ab * t)
					if distance >= reach:
						continue
					var factor := 0.0
					if distance < radius:
						factor = smoothstep(0.0, 1.0, 1.0 - distance / radius)
					var index := z * resolution + x
					# Bed: Depth below the water level in the channel, then
					# rising with the bank slope; never above the ground.
					var bed := lerpf(level_a, level_b, t) - depth * factor + BANK_SLOPE * maxf(distance - flat_radius, 0.0)
					carve[index] = maxf(carve[index], maxf(depth * factor, heights[index] - bed))

	return carve

## True if a river's channel or cut banks may reach `rect` (terrain-local
## X/Z): heights changed there can change that river's carve and level.
static func any_river_near(terrain: Node3D, rect: Rect2) -> bool:
	for river_variant: Variant in terrain.get_meta(Meta.RIVERS, []):
		var river: Dictionary = river_variant
		var points: Array = river.get("points", [])
		if points.is_empty():
			continue
		var first_point: Vector2 = points[0]
		var bounds := Rect2(first_point, Vector2.ZERO)
		for point: Vector2 in points:
			bounds = bounds.expand(point)
		var river_width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		var reach := river_width * 0.5 + MAX_BANK_REACH + 1.0
		if bounds.grow(reach).intersects(rect, true):
			return true
	return false

## Groups rivers into connected networks: two rivers are in the same network
## when their rasterized beds touch. Each group holds the rivers as stored, in
## network order.
static func group_connected(terrain: Node3D, rivers: Array) -> Array:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var spacing: float = world_size / maxf(float(resolution - 1), 1.0)
	# Every river read once (migrate() copies it): its points, width and a box
	# that holds all it can touch, so far-apart pairs are skipped at once.
	var lines: Array[Array] = []
	var widths := PackedFloat64Array()
	var bounds: Array[Rect2] = []
	for river_variant: Variant in rivers:
		var river: Dictionary = FeatureStyle.migrate(river_variant, FeatureStyle.RIVER)
		var points: Array = river.get("points", [])
		var width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		lines.append(points)
		widths.append(width)
		bounds.append(GridMath.polyline_bounds(points, absf(width) * 0.5 + spacing * 0.7 + 0.01))
	var touch := func(a: int, b: int) -> bool:
		if lines[a].size() < 2 or lines[b].size() < 2:
			return false
		# The rasterized footprints, not only the centre lines, touch.
		var touch_distance: float = widths[a] * 0.5 + widths[b] * 0.5 + spacing * 1.40
		return GridMath.polylines_within_distance(lines[a], lines[b], touch_distance)
	var groups: Array = []
	for indices in GridMath.connected_groups(bounds, touch):
		var group: Array = []
		for index in indices:
			group.append(rivers[index])
		groups.append(group)
	return groups

## Water body for a connected group of rivers, styled after the first one.
## Returns {vertices, normals, uvs, collision_vertices}.
static func build_water_union(terrain: Node3D, carve: PackedFloat32Array, rivers: Array) -> Dictionary:
	var state := water_begin(terrain, carve, rivers)
	water_step(state)
	return water_result(state)

## build_water_union() in slices, so a game can spread it over several frames
## (TerrainRuntime): state := water_begin() (water cells and levels), then
## water_step(state, budget) until it returns true (water tops, then the
## skirts), then water_result(state). Same output however it is sliced.
static func water_begin(terrain: Node3D, carve: PackedFloat32Array, rivers: Array) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var collision_vertices: Array[Vector3] = []
	var state := {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices,
		"cells": [], "phase": 0, "next": 0}
	if rivers.is_empty():
		return state

	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	if resolution < 2:
		return state

	var spacing := world_size / float(resolution - 1)
	var water_cells: Dictionary = {}
	var representative: Dictionary = FeatureStyle.migrate(rivers[0], FeatureStyle.RIVER)
	var surface_drop: float = representative.get("surface_drop", Meta.DEFAULT_RIVER_SURFACE_DROP)
	var feature_offset: float = Meta.get_float(terrain, Meta.FEATURE_Y_OFFSET, 0.0)
	var raw_tile_size: float = representative.get("tile_size", Meta.DEFAULT_RIVER_TILE_SIZE)
	var tile_size: float = maxf(raw_tile_size, 0.001)

	# Rasterize every river into one shared cell mask. A cell claimed by several
	# rivers is still emitted exactly once, eliminating the dark overlapping top
	# faces at confluences and crossings.
	for river_variant: Variant in rivers:
		var river: Dictionary = FeatureStyle.migrate(river_variant, FeatureStyle.RIVER)
		var raw_points: Array = river.get("points", [])
		if raw_points.size() < 2:
			continue
		var points := GridMath.dedupe_points(raw_points)
		if points.size() < 2:
			continue

		var raw_width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		var width: float = maxf(raw_width, 0.01)
		var inclusion_radius: float = width * 0.5 + spacing * 0.70
		var min_px: float = points[0].x
		var max_px: float = points[0].x
		var min_pz: float = points[0].y
		var max_pz: float = points[0].y
		for p in points:
			min_px = minf(min_px, p.x)
			max_px = maxf(max_px, p.x)
			min_pz = minf(min_pz, p.y)
			max_pz = maxf(max_pz, p.y)

		var min_grid := GridMath.local_to_grid(Vector2(min_px - inclusion_radius, min_pz - inclusion_radius), resolution, world_size)
		var max_grid := GridMath.local_to_grid(Vector2(max_px + inclusion_radius, max_pz + inclusion_radius), resolution, world_size)
		var min_cell_x := clampi(int(floorf(minf(min_grid.x, max_grid.x))) - 1, 0, resolution - 2)
		var max_cell_x := clampi(int(ceilf(maxf(min_grid.x, max_grid.x))) + 1, 0, resolution - 2)
		var min_cell_z := clampi(int(floorf(minf(min_grid.y, max_grid.y))) - 1, 0, resolution - 2)
		var max_cell_z := clampi(int(ceilf(maxf(min_grid.y, max_grid.y))) + 1, 0, resolution - 2)

		# A cell is water when its centre lies within inclusion_radius of the
		# polyline, i.e. of at least one segment. Only cells near each segment
		# are tested (instead of every cell of the river's bounding box against
		# every segment), then added in row order so the mesh is unchanged.
		var river_cells: Dictionary = {}
		for segment_index in range(points.size() - 1):
			var a: Vector2 = points[segment_index]
			var b: Vector2 = points[segment_index + 1]
			var seg_min := GridMath.local_to_grid(Vector2(minf(a.x, b.x) - inclusion_radius, minf(a.y, b.y) - inclusion_radius), resolution, world_size)
			var seg_max := GridMath.local_to_grid(Vector2(maxf(a.x, b.x) + inclusion_radius, maxf(a.y, b.y) + inclusion_radius), resolution, world_size)
			var seg_min_x := maxi(int(floorf(seg_min.x)) - 1, min_cell_x)
			var seg_max_x := mini(int(ceilf(seg_max.x)) + 1, max_cell_x)
			var seg_min_z := maxi(int(floorf(seg_min.y)) - 1, min_cell_z)
			var seg_max_z := mini(int(ceilf(seg_max.y)) + 1, max_cell_z)
			for z in range(seg_min_z, seg_max_z + 1):
				for x in range(seg_min_x, seg_max_x + 1):
					var cell := Vector2i(x, z)
					if river_cells.has(cell):
						continue
					var p00 := GridMath.grid_to_local(x, z, resolution, world_size)
					var p11 := GridMath.grid_to_local(x + 1, z + 1, resolution, world_size)
					var center := Vector2((p00.x + p11.x) * 0.5, (p00.z + p11.z) * 0.5)
					if GridMath.distance_to_segment(center, a, b) <= inclusion_radius and TerrainData.cell_active(terrain, x, z):
						river_cells[cell] = true

		var ordered: Array = river_cells.keys()
		ordered.sort_custom(func(p: Vector2i, q: Vector2i) -> bool:
			return p.y < q.y or (p.y == q.y and p.x < q.x)
		)
		for cell: Vector2i in ordered:
			water_cells[cell] = true

	# Hot loops below: read the terrain data once and sample each grid corner
	# once (same function and inputs, so the same heights).
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var corner_levels := _corner_levels(heights, resolution, world_size, rivers, spacing)
	var surface_heights: Dictionary = {}
	var surface_at := func(x: int, z: int) -> Vector3:
		var corner := Vector2i(x, z)
		var cached: Variant = surface_heights.get(corner)
		if cached != null:
			return cached
		var p := GridMath.grid_to_local(x, z, resolution, world_size)
		# The ground, but never above the river's water level (no climbing).
		var level := TerrainSampler.uncarved_height_in(heights, resolution, world_size, Vector2(p.x, p.z))
		var nearest: Variant = corner_levels.get(corner)
		if nearest != null:
			var nearest_level: Vector2 = nearest
			level = minf(level, nearest_level.y)
		var top := Vector3(p.x, level - surface_drop + feature_offset, p.z)
		surface_heights[corner] = top
		return top

	# River bed height (with carving) at a grid corner, sampled once per corner.
	var bed_heights: Dictionary = {}
	var bed_at := func(x: int, z: int) -> float:
		var corner := Vector2i(x, z)
		var cached: Variant = bed_heights.get(corner)
		if cached != null:
			return cached
		var p := GridMath.grid_to_local(x, z, resolution, world_size)
		var bed := TerrainSampler.effective_height_in(heights, carve, resolution, world_size, Vector2(p.x, p.z)) + 0.01
		bed_heights[corner] = bed
		return bed

	state.merge({"cells": water_cells.keys(), "water_cells": water_cells, "surface_at": surface_at, "bed_at": bed_at, "tile_size": tile_size}, true)
	return state

## Builds the next water cells of water_begin()'s state: every water top
## first, then the skirts. `budget_usec` > 0 stops after about that long
## (0 = all). True when everything is built.
static func water_step(state: Dictionary, budget_usec: int = 0) -> bool:
	var cells: Array = state["cells"]
	var phase: int = state["phase"]
	var next: int = state["next"]
	if phase >= 2 or cells.is_empty():
		return true
	var start := Time.get_ticks_usec()
	var vertices: Array[Vector3] = state["vertices"]
	var normals: Array[Vector3] = state["normals"]
	var uvs: Array[Vector2] = state["uvs"]
	var collision_vertices: Array[Vector3] = state["collision_vertices"]
	var surface_at: Callable = state["surface_at"]
	var water_cells: Dictionary = state["water_cells"]
	var bed_at: Callable = state["bed_at"]
	var tile_size: float = state["tile_size"]
	var first := true
	while phase < 2:
		if next >= cells.size():
			phase += 1
			next = 0
			continue
		if budget_usec > 0 and not first and (next & 63) == 0 and Time.get_ticks_usec() - start >= budget_usec:
			break
		first = false
		var cell: Vector2i = cells[next]
		next += 1
		if phase == 0:
			var x: int = cell.x
			var z: int = cell.y
			var a: Vector3 = surface_at.call(x, z)
			var b: Vector3 = surface_at.call(x + 1, z)
			var c: Vector3 = surface_at.call(x + 1, z + 1)
			var d: Vector3 = surface_at.call(x, z + 1)
			var uv_a := Vector2(a.x / tile_size, a.z / tile_size)
			var uv_b := Vector2(b.x / tile_size, b.z / tile_size)
			var uv_c := Vector2(c.x / tile_size, c.z / tile_size)
			var uv_d := Vector2(d.x / tile_size, d.z / tile_size)
			MeshUtils.add_upward_triangle_uv(vertices, normals, uvs, a, b, c, uv_a, uv_b, uv_c)
			MeshUtils.add_upward_triangle_uv(vertices, normals, uvs, a, c, d, uv_a, uv_c, uv_d)
			MeshUtils.add_upward_triangle(collision_vertices, [], a, b, c)
			MeshUtils.add_upward_triangle(collision_vertices, [], a, c, d)
		else:
			# Only the outer boundary of the complete union receives skirts.
			# Internal river/river borders disappear, so intersections read as
			# one continuous body.
			for direction: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				_add_boundary_skirt(water_cells, cell.x, cell.y, direction, surface_at, bed_at, vertices, normals, uvs, tile_size)
	state["phase"] = phase
	state["next"] = next
	return phase >= 2

## {vertices, normals, uvs, collision_vertices} of a finished water_step() state.
static func water_result(state: Dictionary) -> Dictionary:
	return {"vertices": state["vertices"], "normals": state["normals"], "uvs": state["uvs"], "collision_vertices": state["collision_vertices"]}

## Water level of the nearest river centre line at each grid corner near the
## rivers: {Vector2i corner: Vector2(distance, level)} (see water_levels).
static func _corner_levels(heights: PackedFloat32Array, resolution: int, world_size: float, rivers: Array, spacing: float) -> Dictionary:
	var nearest: Dictionary = {}
	var half := world_size * 0.5
	for river_variant: Variant in rivers:
		var river: Dictionary = FeatureStyle.migrate(river_variant, FeatureStyle.RIVER)
		var raw_points: Array = river.get("points", [])
		if raw_points.size() < 2:
			continue
		# Corners of the water cells (centre within width / 2 + 0.7 cell).
		var raw_width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		var reach: float = maxf(raw_width, 0.01) * 0.5 + spacing * 1.5
		var line := water_levels(heights, resolution, world_size, raw_points)
		var points: Array[Vector2] = line["points"]
		var levels: PackedFloat32Array = line["levels"]
		for i in range(points.size() - 1):
			var a: Vector2 = points[i]
			var ab: Vector2 = points[i + 1] - a
			var length_squared := ab.length_squared()
			var inverse_length := 1.0 / length_squared if length_squared > 0.000001 else 0.0
			var min_x := clampi(int(floorf((minf(a.x, a.x + ab.x) - reach + half) / spacing)), 0, resolution - 1)
			var max_x := clampi(int(ceilf((maxf(a.x, a.x + ab.x) + reach + half) / spacing)), 0, resolution - 1)
			var min_z := clampi(int(floorf((minf(a.y, a.y + ab.y) - reach + half) / spacing)), 0, resolution - 1)
			var max_z := clampi(int(ceilf((maxf(a.y, a.y + ab.y) + reach + half) / spacing)), 0, resolution - 1)
			for z in range(min_z, max_z + 1):
				for x in range(min_x, max_x + 1):
					var point := Vector2(float(x) * spacing - half, float(z) * spacing - half)
					var t := clampf((point - a).dot(ab) * inverse_length, 0.0, 1.0)
					var distance := point.distance_to(a + ab * t)
					var corner := Vector2i(x, z)
					var previous: Variant = nearest.get(corner)
					if previous != null:
						var previous_nearest: Vector2 = previous
						if not (distance < previous_nearest.x):
							continue
					nearest[corner] = Vector2(distance, lerpf(levels[i], levels[i + 1], t))
	return nearest

## Closes an exposed water edge down to the carved river bed, so the water
## reads as a body at the banks and stroke tips instead of a paper-thin plane.
## `surface_at(x, z)` gives the water surface point of a grid corner and
## `bed_at(x, z)` the river bed height there (see build_water_union).
static func _add_boundary_skirt(water_cells: Dictionary, x: int, z: int, direction: Vector2i, surface_at: Callable, bed_at: Callable, vertices: Array, normals: Array, uvs: Array, tile_size: float) -> void:
	if water_cells.has(Vector2i(x, z) + direction):
		return

	# Corners of the exposed edge, in winding order, and the outward normal.
	var corner_a: Vector2i
	var corner_b: Vector2i
	var outward: Vector3
	if direction == Vector2i(-1, 0):
		corner_a = Vector2i(x, z + 1)
		corner_b = Vector2i(x, z)
		outward = Vector3.LEFT
	elif direction == Vector2i(1, 0):
		corner_a = Vector2i(x + 1, z)
		corner_b = Vector2i(x + 1, z + 1)
		outward = Vector3.RIGHT
	elif direction == Vector2i(0, -1):
		corner_a = Vector2i(x, z)
		corner_b = Vector2i(x + 1, z)
		outward = Vector3.FORWARD
	else:
		corner_a = Vector2i(x + 1, z + 1)
		corner_b = Vector2i(x, z + 1)
		outward = Vector3.BACK

	var top_a: Vector3 = surface_at.call(corner_a.x, corner_a.y)
	var top_b: Vector3 = surface_at.call(corner_b.x, corner_b.y)
	var bed_y_a: float = bed_at.call(corner_a.x, corner_a.y)
	var bed_a := Vector3(top_a.x, bed_y_a, top_a.z)
	var bed_y_b: float = bed_at.call(corner_b.x, corner_b.y)
	var bed_b := Vector3(top_b.x, bed_y_b, top_b.z)
	# Never let the skirt invert on shallow bank corners.
	bed_a.y = minf(bed_a.y, top_a.y - 0.015)
	bed_b.y = minf(bed_b.y, top_b.y - 0.015)

	var u0: float = 0.0
	var u1: float = top_a.distance_to(top_b) / maxf(tile_size, 0.001)
	var v0: float = 0.0
	var v1a: float = absf(top_a.y - bed_a.y) / maxf(tile_size, 0.001)
	var v1b: float = absf(top_b.y - bed_b.y) / maxf(tile_size, 0.001)
	MeshUtils.add_oriented_triangle_uv(vertices, normals, uvs, top_a, bed_b, top_b, outward, Vector2(u0, v0), Vector2(u1, v1b), Vector2(u1, v0))
	MeshUtils.add_oriented_triangle_uv(vertices, normals, uvs, top_a, bed_a, bed_b, outward, Vector2(u0, v0), Vector2(u0, v1a), Vector2(u1, v1b))
