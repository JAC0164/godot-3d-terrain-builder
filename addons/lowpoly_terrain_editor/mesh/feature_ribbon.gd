@tool
extends RefCounted
## Ribbon geometry following a road/river stroke. Used for the live preview
## while a feature is being drawn (committed features use the union meshers).

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const MeshUtils = preload("mesh_utils.gd")

## Returns {vertices, normals, uvs}. One ribbon with a shared left/right vertex
## pair at every path sample, mitred at the turns.
static func build(terrain: Node3D, carve: PackedFloat32Array, feature: Dictionary, feature_type: String) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var raw_points: Array = feature.get("points", [])
	if raw_points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	var points := GridMath.dedupe_points(raw_points)
	if points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	var is_road := feature_type == FeatureStyle.ROAD
	if is_road:
		# Resample long road segments so both road edges query the terrain often
		# enough to conform over hills instead of cutting straight through them.
		points = GridMath.resample_points(points, Meta.ROAD_SAMPLE_SPACING)

	var raw_width: float = feature.get("width", Meta.DEFAULT_ROAD_WIDTH if is_road else Meta.DEFAULT_RIVER_WIDTH)
	var width: float = maxf(raw_width, 0.01)
	var half_width: float = width * 0.5
	var raw_tile_size: float = feature.get("tile_size", Meta.DEFAULT_ROAD_TILE_SIZE if is_road else Meta.DEFAULT_RIVER_TILE_SIZE)
	var tile_size: float = maxf(raw_tile_size, 0.001)
	var feature_offset: float = Meta.get_float(terrain, Meta.FEATURE_Y_OFFSET, 0.0)
	var y_offset: float
	var preview: bool = feature.get("preview", false)
	if is_road:
		y_offset = feature.get("y_offset", Meta.DEFAULT_ROAD_Y_OFFSET)
	elif preview:
		# Before the river is committed the bed has not been carved yet, so keep
		# the preview just above the surface instead of hiding it underground.
		y_offset = 0.03
	else:
		var surface_drop: float = feature.get("surface_drop", Meta.DEFAULT_RIVER_SURFACE_DROP)
		y_offset = -surface_drop

	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	var distances: Array[float] = []
	var accumulated: float = 0.0

	for i in range(points.size()):
		if i > 0:
			accumulated += points[i - 1].distance_to(points[i])
		distances.append(accumulated)

		var offset_vector := _side_offset(points, i, half_width)
		var left_2d := points[i] + offset_vector
		var right_2d := points[i] - offset_vector

		var left_height: float
		var right_height: float
		if feature_type == FeatureStyle.RIVER:
			# Water follows the pre-carve surface, then sits below it by Surface Drop.
			left_height = TerrainSampler.uncarved_height(terrain, left_2d)
			right_height = TerrainSampler.uncarved_height(terrain, right_2d)
		else:
			left_height = TerrainSampler.effective_height(terrain, carve, left_2d)
			right_height = TerrainSampler.effective_height(terrain, carve, right_2d)

		left_positions.append(Vector3(left_2d.x, left_height + y_offset + feature_offset, left_2d.y))
		right_positions.append(Vector3(right_2d.x, right_height + y_offset + feature_offset, right_2d.y))

	for i in range(points.size() - 1):
		var p0: Vector3 = left_positions[i]
		var p1: Vector3 = right_positions[i]
		var p2: Vector3 = left_positions[i + 1]
		var p3: Vector3 = right_positions[i + 1]
		var u0: float = distances[i] / tile_size
		var u1: float = distances[i + 1] / tile_size
		var v_max: float = width / tile_size
		MeshUtils.add_upward_triangle_uv(vertices, normals, uvs, p0, p1, p3, Vector2(u0, 0.0), Vector2(u0, v_max), Vector2(u1, v_max))
		MeshUtils.add_upward_triangle_uv(vertices, normals, uvs, p0, p3, p2, Vector2(u0, 0.0), Vector2(u1, v_max), Vector2(u1, 0.0))

	return {"vertices": vertices, "normals": normals, "uvs": uvs}

## Half-width offset perpendicular to the path at sample `i` (mitred joint).
static func _side_offset(points: Array[Vector2], i: int, half_width: float) -> Vector2:
	if i == 0:
		var first_dir: Vector2 = (points[1] - points[0]).normalized()
		return Vector2(-first_dir.y, first_dir.x) * half_width
	if i == points.size() - 1:
		var last_dir: Vector2 = (points[i] - points[i - 1]).normalized()
		return Vector2(-last_dir.y, last_dir.x) * half_width

	var prev_dir: Vector2 = (points[i] - points[i - 1]).normalized()
	var next_dir: Vector2 = (points[i + 1] - points[i]).normalized()
	var prev_normal := Vector2(-prev_dir.y, prev_dir.x)
	var next_normal := Vector2(-next_dir.y, next_dir.x)
	var miter := prev_normal + next_normal
	if miter.length_squared() <= 0.000001:
		return prev_normal * half_width
	miter = miter.normalized()
	var denominator := miter.dot(prev_normal)
	if absf(denominator) <= 0.15:
		return prev_normal * half_width
	var miter_length := clampf(half_width / denominator, -half_width * 1.65, half_width * 1.65)
	return miter * miter_length
