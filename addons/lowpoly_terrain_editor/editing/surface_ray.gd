@tool
extends RefCounted
## Mouse ray against the terrain surface (heightfield), in terrain local space.
## The brush used to hit the terrain's zero-height plane: on a plateau or in a
## valley it landed metres away from the cursor. Marching along the ray inside
## the height range, then refining by bisection, puts the brush (and its ring)
## exactly under the mouse.

const Meta = preload("../core/terrain_meta.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")

const MAX_STEPS := 2000
const REFINE_STEPS := 8

## Local hit point (y = surface height), or null when the ray misses.
## `carve` is the river carve (TerrainBuilder.get_river_carve).
static func hit(terrain: Node3D, carve: PackedFloat32Array, ray_origin: Vector3, ray_direction: Vector3) -> Variant:
	var inverse := terrain.global_transform.affine_inverse()
	var origin := inverse * ray_origin
	var direction := (inverse.basis * ray_direction).normalized()
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, 0)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, 0.0)
	if resolution < 2 or heights.size() < resolution * resolution or absf(direction.y) < 0.000001:
		return null

	# Only the part of the ray inside the height range can hit (rivers carve
	# below the minimum height, hence the margin).
	var top := Meta.get_float(terrain, Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX) + 0.5
	var bottom := Meta.get_float(terrain, Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN) - 4.0
	var t_start := (top - origin.y) / direction.y
	var t_end := (bottom - origin.y) / direction.y
	if t_start > t_end:
		var swap := t_start
		t_start = t_end
		t_end = swap
	t_start = maxf(t_start, 0.0)
	if t_end <= t_start:
		return null

	var step := maxf(world_size / float(resolution - 1), 0.05) * 0.5
	step = maxf(step, (t_end - t_start) / float(MAX_STEPS))
	var previous_t := t_start
	var t := t_start
	while t <= t_end + step:
		var point := origin + direction * minf(t, t_end)
		var ground := TerrainSampler.effective_height_in(heights, carve, resolution, world_size, Vector2(point.x, point.z))
		if point.y <= ground:
			# Bisection between the last point above and this one below.
			var low := previous_t
			var high := minf(t, t_end)
			for i in REFINE_STEPS:
				var middle := (low + high) * 0.5
				var probe := origin + direction * middle
				if probe.y <= TerrainSampler.effective_height_in(heights, carve, resolution, world_size, Vector2(probe.x, probe.z)):
					high = middle
				else:
					low = middle
			var found := origin + direction * high
			found.y = TerrainSampler.effective_height_in(heights, carve, resolution, world_size, Vector2(found.x, found.z))
			return found
		previous_t = t
		t += step
	return null

## Surface height at a local point (for drawing on the ground).
static func height_at(terrain: Node3D, carve: PackedFloat32Array, point: Vector2) -> float:
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, 0)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, 0.0)
	if resolution < 2 or heights.size() < resolution * resolution:
		return 0.0
	return TerrainSampler.effective_height_in(heights, carve, resolution, world_size, point)
