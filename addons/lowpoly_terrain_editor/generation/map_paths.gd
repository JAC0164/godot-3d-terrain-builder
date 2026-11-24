@tool
extends RefCounted
## Paths over a generated map (rivers, track network): a native AStarGrid2D
## on a coarse grid of the cells (1 node per `step` x `step` cells), then a
## smooth polyline in cell coordinates (x, z from the map's corner).

## Cells per side of a coarse node: about 256 nodes a side at most.
static func step_for(n: int) -> int:
	return maxi(1, n / 256)

## Nodes per side.
static func side_for(n: int, step: int) -> int:
	return ceili(float(n) / float(step))

## The cell at the middle of coarse node (x, z).
static func node_cell(node: Vector2i, n: int, step: int) -> Vector2i:
	return Vector2i(mini(node.x * step + step / 2, n - 1), mini(node.y * step + step / 2, n - 1))

## Grid of side x side nodes: weights[i] scales the cost of entering node i
## (z * side + x); solid[i] != 0 is never entered.
static func make_grid(side: int, weights: PackedFloat32Array, solid: PackedByteArray) -> AStarGrid2D:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, side, side)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	for z in range(side):
		for x in range(side):
			var i := z * side + x
			if solid[i] != 0:
				grid.set_point_solid(Vector2i(x, z), true)
			else:
				grid.set_point_weight_scale(Vector2i(x, z), weights[i])
	return grid

## The node on the square edge of the grid in direction `angle` from its
## centre, moved inwards to the first node that is not solid (none: (-1, -1)).
static func edge_node(grid: AStarGrid2D, side: int, angle: float) -> Vector2i:
	var direction := Vector2(cos(angle), sin(angle))
	var centre := Vector2(side, side) * 0.5
	var reach := (float(side) * 0.5 - 0.5) / maxf(absf(direction.x), absf(direction.y))
	for k in range(int(reach) + 1):
		var p := centre + direction * (reach - float(k))
		var node := Vector2i(clampi(int(floorf(p.x)), 0, side - 1), clampi(int(floorf(p.y)), 0, side - 1))
		if not grid.is_point_solid(node):
			return node
	return Vector2i(-1, -1)

## The cheapest path from `from` to `to` (nodes), as cell coordinates of the
## node centres; empty when there is none.
static func find(grid: AStarGrid2D, from: Vector2i, to: Vector2i, n: int, step: int) -> PackedVector2Array:
	var points := PackedVector2Array()
	if from.x < 0 or to.x < 0 or from == to:
		return points
	var ids := grid.get_id_path(from, to)
	for id in ids:
		points.append(Vector2(minf(float(id.x * step) + float(step) * 0.5, float(n) - 0.5), minf(float(id.y * step) + float(step) * 0.5, float(n) - 0.5)))
	return points

## Moves the end of `points` that is near the map border onto the border, so
## the line leaves the map there (within `margin` cells).
static func reach_border(points: PackedVector2Array, n: int, margin: float) -> PackedVector2Array:
	if points.size() < 2:
		return points
	var out := points.duplicate()
	for end: int in [0, out.size() - 1]:
		var p: Vector2 = out[end]
		var to_left := p.x
		var to_right := float(n) - p.x
		var to_top := p.y
		var to_bottom := float(n) - p.y
		var nearest := minf(minf(to_left, to_right), minf(to_top, to_bottom))
		if nearest > margin:
			continue
		if nearest == to_left:
			p.x = 0.0
		elif nearest == to_right:
			p.x = float(n)
		elif nearest == to_top:
			p.y = 0.0
		else:
			p.y = float(n)
		out[end] = p
	return out

## Chaikin corner cutting (ends kept): smooth curves from the grid's steps.
static func smooth(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var out := points
	for iteration in range(iterations):
		if out.size() < 3:
			return out
		var next := PackedVector2Array()
		next.append(out[0])
		for i in range(out.size() - 1):
			var a := out[i]
			var b := out[i + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(out[out.size() - 1])
		out = next
	return out

## Points every `spacing` along the polyline (ends kept).
static func resample(points: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if points.size() < 2:
		return points
	out.append(points[0])
	var carried := 0.0
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var length := a.distance_to(b)
		var d := spacing - carried
		while d <= length:
			out.append(a.lerp(b, d / length))
			d += spacing
		carried = length - (d - spacing)
	if out[out.size() - 1].distance_to(points[points.size() - 1]) > spacing * 0.3:
		out.append(points[points.size() - 1])
	else:
		out[out.size() - 1] = points[points.size() - 1]
	return out

## Cell coordinates -> terrain-local X/Z.
static func to_local(points: PackedVector2Array, n: int, cell_size: float) -> Array[Vector2]:
	var half := Vector2(n, n) * 0.5
	var out: Array[Vector2] = []
	for p in points:
		out.append((p - half) * cell_size)
	return out

## Grid node of a cell position.
static func node_of(cell: Vector2, side: int, step: int) -> Vector2i:
	return Vector2i(clampi(int(cell.x) / step, 0, side - 1), clampi(int(cell.y) / step, 0, side - 1))

## Meanders: each point moved sideways by two sine waves along the line
## (wavelengths `wavelength` and ~0.4 of it, phases from `rng`), fading to
## nothing over the first and last `wavelength` / 2 so the ends stay put.
static func wobble(points: PackedVector2Array, rng: RandomNumberGenerator, amplitude: float, wavelength: float) -> PackedVector2Array:
	var phase_a := rng.randf() * TAU
	var phase_b := rng.randf() * TAU
	if points.size() < 3 or amplitude <= 0.0:
		return points
	var along := PackedFloat32Array([0.0])
	for i in range(1, points.size()):
		along.append(along[i - 1] + points[i - 1].distance_to(points[i]))
	var total := along[along.size() - 1]
	var out := points.duplicate()
	for i in range(1, points.size() - 1):
		var tangent := (points[i + 1] - points[i - 1]).normalized()
		var s := along[i]
		var fade := smoothstep(0.0, wavelength * 0.5, minf(s, total - s))
		var offset := sin(s * TAU / wavelength + phase_a) * 0.65 + sin(s * TAU / (wavelength * 0.41) + phase_b) * 0.35
		out[i] = points[i] + Vector2(-tangent.y, tangent.x) * offset * amplitude * fade
	return out

## Small fixed noise (0..1) per node: breaks the ties between equal paths,
## which would otherwise run along the grid's axes and diagonals.
static func jitter(x: int, z: int) -> float:
	return float(((x * 73856093) ^ (z * 19349663)) & 1023) / 1023.0
