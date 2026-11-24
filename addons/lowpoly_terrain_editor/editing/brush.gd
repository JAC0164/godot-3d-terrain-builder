@tool
extends RefCounted
## Brush operations on the terrain mask / heights / cell flags.
##
## Pure data edits: they only read and write terrain metadata. Mesh updates are
## the caller's job (see StrokeController).

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const ToolMode = preload("tool_mode.gd")

## Mask change per brush sample at full falloff and strength 1.
const PAINT_RATE := 0.20
## Height change per brush sample at full falloff and strength 1.
const SCULPT_RATE := 0.12
const SMOOTH_RATE := 0.20
## Vegetation value change per brush sample at full falloff and strength 1
## (Meta.VEGETATION_NORMAL = biome density: ~3 samples from normal to none).
const VEGETATION_RATE := 22.0

## Vertex index range {min_x, max_x, min_z, max_z} covered by a circle,
## grown by `padding_cells` and clamped to the grid.
static func vertex_bounds(terrain: Node3D, target_pos: Vector2, radius: float, padding_cells: int = 0) -> Dictionary:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var spacing: float = world_size / maxf(float(resolution - 1), 1.0)
	var center := GridMath.local_to_grid(target_pos, resolution, world_size)
	var grid_radius: float = radius / maxf(spacing, 0.0001) + float(padding_cells)

	return {
		"min_x": clampi(int(floorf(center.x - grid_radius)), 0, resolution - 1),
		"max_x": clampi(int(ceilf(center.x + grid_radius)), 0, resolution - 1),
		"min_z": clampi(int(floorf(center.y - grid_radius)), 0, resolution - 1),
		"max_z": clampi(int(ceilf(center.y + grid_radius)), 0, resolution - 1),
	}

## Applies one PAINT / ERASE / RAISE / LOWER / FLATTEN sample to the vertex
## mask or heights. Other modes are ignored. `flatten_height` is only used by
## FLATTEN.
static func apply_vertex_brush(terrain: Node3D, mode: ToolMode.Mode, target_pos: Vector2, radius: float, strength: float, flatten_height: float = 0.0) -> void:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var bounds := vertex_bounds(terrain, target_pos, radius)
	var min_height := TerrainData.height_min(terrain)
	var max_height := TerrainData.height_max(terrain)

	for z in range(bounds["min_z"], bounds["max_z"] + 1):
		for x in range(bounds["min_x"], bounds["max_x"] + 1):
			var point := GridMath.grid_to_local(x, z, resolution, world_size)
			var distance := Vector2(point.x, point.z).distance_to(target_pos)

			if distance > radius:
				continue

			var falloff := GridMath.brush_falloff(distance, radius)
			var index := GridMath.grid_index(x, z, resolution)

			match mode:
				ToolMode.Mode.PAINT:
					mask[index] = clamp(mask[index] + falloff * PAINT_RATE * strength, 0.0, 1.0)
				ToolMode.Mode.ERASE:
					mask[index] = clamp(mask[index] - falloff * PAINT_RATE * strength, 0.0, 1.0)
				ToolMode.Mode.RAISE:
					heights[index] = clampf(heights[index] + falloff * SCULPT_RATE * strength, min_height, max_height)
				ToolMode.Mode.LOWER:
					heights[index] = clampf(heights[index] - falloff * SCULPT_RATE * strength, min_height, max_height)
				ToolMode.Mode.FLATTEN:
					var blend := clampf(falloff * SCULPT_RATE * strength, 0.0, 1.0)
					heights[index] = lerp(heights[index], flatten_height, blend)

	terrain.set_meta(Meta.MASK, mask)
	terrain.set_meta(Meta.HEIGHTS, heights)

## Blends each height inside the brush toward the 3x3 average around it.
static func apply_smooth(terrain: Node3D, target_pos: Vector2, radius: float, strength: float) -> void:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var source: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var output := source.duplicate()
	var bounds := vertex_bounds(terrain, target_pos, radius, 1)
	var bounds_min_x: int = bounds["min_x"]
	var bounds_max_x: int = bounds["max_x"]
	var bounds_min_z: int = bounds["min_z"]
	var bounds_max_z: int = bounds["max_z"]

	var min_x: int = maxi(1, bounds_min_x)
	var max_x: int = mini(resolution - 2, bounds_max_x)
	var min_z: int = maxi(1, bounds_min_z)
	var max_z: int = mini(resolution - 2, bounds_max_z)

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var point := GridMath.grid_to_local(x, z, resolution, world_size)
			var distance := Vector2(point.x, point.z).distance_to(target_pos)

			if distance > radius:
				continue

			var average := 0.0
			var count := 0
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					average += source[GridMath.grid_index(x + dx, z + dz, resolution)]
					count += 1
			average /= float(count)

			var falloff := GridMath.brush_falloff(distance, radius)
			var blend := clampf(falloff * SMOOTH_RATE * strength, 0.0, 1.0)
			var index := GridMath.grid_index(x, z, resolution)
			output[index] = lerp(source[index], average, blend)

	terrain.set_meta(Meta.HEIGHTS, output)

## Applies one Vegetation sample (VEGETATION / _CLEAR / _RESET) to the cells
## whose centre is inside the brush, for `target` (Meta.VEGETATION_ALL or a
## detail layer name). Returns true when a value changed.
static func apply_vegetation(terrain: Node3D, mode: ToolMode.Mode, target_pos: Vector2, radius: float, strength: float, target: String = Meta.VEGETATION_ALL) -> bool:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	if resolution < 2:
		return false
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var cell_count := resolution - 1
	var paint := Meta.vegetation_paint(terrain).duplicate()
	var values: PackedByteArray = paint.get(target, PackedByteArray())
	if values.size() != cell_count * cell_count:
		values = PackedByteArray()
		values.resize(cell_count * cell_count)
		values.fill(Meta.VEGETATION_NORMAL)
	var spacing := world_size / float(cell_count)
	var bounds := vertex_bounds(terrain, target_pos, radius, 1)
	var bounds_min_x: int = bounds["min_x"]
	var bounds_max_x: int = bounds["max_x"]
	var bounds_min_z: int = bounds["min_z"]
	var bounds_max_z: int = bounds["max_z"]
	var changed := false
	for z in range(clampi(bounds_min_z - 1, 0, cell_count - 1), clampi(bounds_max_z, 0, cell_count - 1) + 1):
		for x in range(clampi(bounds_min_x - 1, 0, cell_count - 1), clampi(bounds_max_x, 0, cell_count - 1) + 1):
			var center := Vector2((float(x) + 0.5) * spacing, (float(z) + 0.5) * spacing) - Vector2(world_size, world_size) * 0.5
			var distance := center.distance_to(target_pos)
			if distance > radius:
				continue
			var step := GridMath.brush_falloff(distance, radius) * VEGETATION_RATE * strength
			var index := GridMath.cell_index(x, z, resolution)
			var value := float(values[index])
			match mode:
				ToolMode.Mode.VEGETATION:
					value = minf(value + step, 255.0)
				ToolMode.Mode.VEGETATION_CLEAR:
					value = maxf(value - step, 0.0)
				ToolMode.Mode.VEGETATION_RESET:
					value = move_toward(value, float(Meta.VEGETATION_NORMAL), step)
			# Round away from the old value so weak strokes still progress.
			var new_value := clampi(int(ceilf(value)) if value > float(values[index]) else int(floorf(value)), 0, 255)
			if new_value != values[index]:
				values[index] = new_value
				changed = true
	if changed:
		# A target painted back to normal everywhere is dropped (= never painted).
		if values.count(Meta.VEGETATION_NORMAL) == values.size():
			paint.erase(target)
		else:
			paint[target] = values
		Meta.set_optional(terrain, Meta.CELL_VEGETATION, paint if not paint.is_empty() else null)
	return changed

## Updates the explicit cell flags near the brush from the vertex mask.
## With `allow_activation` false (Erase) cells can only be deactivated.
## Returns the indices of newly activated cells.
static func sync_cell_active_near(terrain: Node3D, target_pos: Vector2, radius: float, allow_activation: bool = true) -> PackedInt32Array:
	var activated := PackedInt32Array()
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	if resolution < 2:
		return activated

	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	var cells: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	var expected_size: int = (resolution - 1) * (resolution - 1)

	if cells.size() != expected_size:
		cells.resize(expected_size)
		cells.fill(0)

	var spacing: float = world_size / float(resolution - 1)
	var influence: float = radius + spacing * 1.5
	var bounds := vertex_bounds(terrain, target_pos, influence, 1)
	var bounds_min_x: int = bounds["min_x"]
	var bounds_max_x: int = bounds["max_x"]
	var bounds_min_z: int = bounds["min_z"]
	var bounds_max_z: int = bounds["max_z"]
	var min_x: int = clampi(bounds_min_x - 1, 0, resolution - 2)
	var max_x: int = clampi(bounds_max_x, 0, resolution - 2)
	var min_z: int = clampi(bounds_min_z - 1, 0, resolution - 2)
	var max_z: int = clampi(bounds_max_z, 0, resolution - 2)

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var a := GridMath.grid_to_local(x, z, resolution, world_size)
			var b := GridMath.grid_to_local(x + 1, z + 1, resolution, world_size)
			var center := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
			if center.distance_to(target_pos) > influence:
				continue

			var index: int = GridMath.cell_index(x, z, resolution)
			var was_active: bool = cells[index] != 0
			var mask_active: bool = GridMath.cell_active_for_mask(mask, x, z, resolution)

			if allow_activation:
				cells[index] = 1 if mask_active else 0
				if not was_active and mask_active:
					activated.append(index)
			else:
				if was_active and not mask_active:
					cells[index] = 0

	terrain.set_meta(Meta.CELL_ACTIVE, cells)
	return activated
