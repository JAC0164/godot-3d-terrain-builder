@tool
extends RefCounted
## Pure grid and 2D geometry helpers. No dependency on nodes or metadata.
##
## Terrain layout: a square grid of `resolution x resolution` vertices spread
## over `world_size` units, centred on the terrain origin. Cells are the
## `(resolution - 1)^2` squares between vertices. 2D points use Vector2(x, z).

static func grid_to_local(x: int, z: int, resolution: int, world_size: float) -> Vector3:
	var spacing := world_size / float(resolution - 1)
	var half_size := world_size * 0.5
	return Vector3(float(x) * spacing - half_size, 0.0, float(z) * spacing - half_size)

static func local_to_grid(point: Vector2, resolution: int, world_size: float) -> Vector2:
	var half_size := world_size * 0.5
	return Vector2(
		(point.x + half_size) / world_size * float(resolution - 1),
		(point.y + half_size) / world_size * float(resolution - 1)
	)

## Index of a vertex in the mask / heights arrays.
static func grid_index(x: int, z: int, resolution: int) -> int:
	return z * resolution + x

## Index of a cell in the cell_active / cell_styles arrays.
static func cell_index(x: int, z: int, resolution: int) -> int:
	return z * (resolution - 1) + x

## A cell is considered painted when the average of its four corner mask values
## reaches 0.5.
static func cell_active_for_mask(mask: PackedFloat32Array, x: int, z: int, resolution: int) -> bool:
	if x < 0 or z < 0 or x >= resolution - 1 or z >= resolution - 1:
		return false
	var average := (
		mask[grid_index(x, z, resolution)] +
		mask[grid_index(x + 1, z, resolution)] +
		mask[grid_index(x, z + 1, resolution)] +
		mask[grid_index(x + 1, z + 1, resolution)]
	) * 0.25
	return average >= 0.5

## Brush smoothing curve: 1 at the centre, 0 at the radius.
static func brush_falloff(distance: float, radius: float) -> float:
	var t := clampf(distance / maxf(radius, 0.001), 0.0, 1.0)
	return 1.0 - smoothstep(0.0, 1.0, t)

static func distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(a)

	var t := clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
	var closest: Vector2 = a + ab * t
	return point.distance_to(closest)

static func distance_to_polyline(point: Vector2, points: Array) -> float:
	if points.size() == 0: return INF
	if points.size() == 1:
		var only: Vector2 = points[0]
		return point.distance_to(only)

	var best := INF
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var distance := distance_to_segment(point, a, b)
		best = min(best, distance)
	return best

## Returns the intersection point of two segments, or null.
static func segment_intersection_2d(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> Variant:
	var r := a1 - a0
	var s := b1 - b0
	var denominator := r.cross(s)
	if absf(denominator) <= 0.000001:
		return null
	var offset := b0 - a0
	var t := offset.cross(s) / denominator
	var u := offset.cross(r) / denominator
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return null
	return a0 + r * t

static func segment_segment_distance_2d(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> float:
	var hit: Variant = segment_intersection_2d(a0, a1, b0, b1)
	if hit != null:
		return 0.0
	return minf(
		minf(distance_to_segment(a0, b0, b1), distance_to_segment(a1, b0, b1)),
		minf(distance_to_segment(b0, a0, a1), distance_to_segment(b1, a0, a1))
	)

## True when some segment of polyline `points_a` comes within `max_distance`
## of some segment of `points_b` (by segment_segment_distance_2d). Segment
## pairs whose bounding boxes are clearly farther apart are skipped, which
## does not change the answer.
static func polylines_within_distance(points_a: Array, points_b: Array, max_distance: float) -> bool:
	# Generous margin so float rounding in the exact test can never matter.
	var margin := max_distance + 0.001
	for ai in range(points_a.size() - 1):
		var a0: Vector2 = points_a[ai]
		var a1: Vector2 = points_a[ai + 1]
		var a_min := Vector2(minf(a0.x, a1.x), minf(a0.y, a1.y))
		var a_max := Vector2(maxf(a0.x, a1.x), maxf(a0.y, a1.y))
		for bi in range(points_b.size() - 1):
			var b0: Vector2 = points_b[bi]
			var b1: Vector2 = points_b[bi + 1]
			if minf(b0.x, b1.x) - a_max.x > margin or a_min.x - maxf(b0.x, b1.x) > margin:
				continue
			if minf(b0.y, b1.y) - a_max.y > margin or a_min.y - maxf(b0.y, b1.y) > margin:
				continue
			if segment_segment_distance_2d(a0, a1, b0, b1) <= max_distance:
				return true
	return false

## Box around a point list, grown by `margin` (an empty list gives a box at
## the origin).
static func polyline_bounds(points: Array, margin: float) -> Rect2:
	var bounds := Rect2()
	if not points.is_empty():
		var first: Vector2 = points[0]
		bounds = Rect2(first, Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	return bounds.grow(margin)

## Splits items into connected networks, breadth-first in index order: one
## PackedInt32Array of item indices per network. Items i and j are linked
## when `touch.call(i, j)` is true; `bounds[i]` (one box per item) only skips
## the far-apart pairs, so each box must hold everything its item can touch.
static func connected_groups(bounds: Array[Rect2], touch: Callable) -> Array[PackedInt32Array]:
	var groups: Array[PackedInt32Array] = []
	var visited := PackedByteArray()
	visited.resize(bounds.size())
	for start in bounds.size():
		if visited[start] != 0:
			continue
		visited[start] = 1
		var group := PackedInt32Array([start])
		var next := 0
		while next < group.size():
			var index := group[next]
			next += 1
			for candidate in bounds.size():
				if visited[candidate] == 0 and bounds[index].intersects(bounds[candidate], true) and touch.call(index, candidate):
					visited[candidate] = 1
					group.append(candidate)
		groups.append(group)
	return groups

## Copies a raw point list, dropping consecutive duplicates.
static func dedupe_points(raw_points: Array) -> Array[Vector2]:
	var points: Array[Vector2] = []
	for point_variant: Variant in raw_points:
		var point: Vector2 = point_variant
		if points.is_empty() or points[-1].distance_squared_to(point) > 0.000001:
			points.append(point)
	return points

## Subdivides long segments so no step is longer than `spacing`.
static func resample_points(points: Array[Vector2], spacing: float) -> Array[Vector2]:
	if points.size() < 2:
		return points.duplicate()
	var result: Array[Vector2] = []
	result.append(points[0])
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var length := a.distance_to(b)
		var steps := maxi(1, int(ceilf(length / maxf(spacing, 0.05))))
		for step in range(1, steps + 1):
			result.append(a.lerp(b, float(step) / float(steps)))
	return result
