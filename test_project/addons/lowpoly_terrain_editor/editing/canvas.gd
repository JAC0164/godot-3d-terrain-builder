@tool
extends RefCounted
## Growing the terrain grid ("canvas") while keeping existing data in place.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const StylePalette = preload("../styles/style_palette.gd")
const GroundBumps = preload("../core/ground_bumps.gd")

## Returned by cells_needed_for_paint() when Maximum Resolution blocks growth.
const BLOCKED_BY_MAX_RESOLUTION := -1

static func _allowed_cells_per_side(terrain: Node3D) -> int:
	var max_resolution: int = maxi(64, Meta.get_int(terrain, Meta.MAX_RESOLUTION, Meta.DEFAULT_MAX_RESOLUTION))
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	return maxi(0, (max_resolution - resolution) / 2)

static func max_resolution(terrain: Node3D) -> int:
	return maxi(64, Meta.get_int(terrain, Meta.MAX_RESOLUTION, Meta.DEFAULT_MAX_RESOLUTION))

## Cells to add on each side so a Paint brush at `local_position` fits inside
## the canvas. 0 = no growth needed (or auto-expand off),
## BLOCKED_BY_MAX_RESOLUTION = growth needed but not allowed.
static func cells_needed_for_paint(terrain: Node3D, local_position: Vector3, brush_radius: float) -> int:
	if not Meta.get_bool(terrain, Meta.AUTO_EXPAND, true):
		return 0

	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	if resolution < 2:
		return 0

	var spacing: float = world_size / float(resolution - 1)
	var half_size: float = world_size * 0.5
	var required_half: float = maxf(absf(local_position.x), absf(local_position.z)) + brush_radius + spacing

	if required_half <= half_size:
		return 0

	var needed_per_side: int = int(ceilf((required_half - half_size) / spacing))
	var chunk: int = maxi(1, Meta.get_int(terrain, Meta.EXPAND_CHUNK, Meta.DEFAULT_EXPAND_CHUNK))
	var chunks_needed: int = int(ceilf(float(needed_per_side) / float(chunk)))
	var requested_per_side: int = maxi(chunk, chunks_needed * chunk)

	var cells_per_side: int = mini(requested_per_side, _allowed_cells_per_side(terrain))
	return cells_per_side if cells_per_side > 0 else BLOCKED_BY_MAX_RESOLUTION

## Cells per side for one manual "Grow Terrain" step (0 when at the limit).
static func cells_for_grow_step(terrain: Node3D) -> int:
	var chunk: int = maxi(1, Meta.get_int(terrain, Meta.EXPAND_CHUNK, Meta.DEFAULT_EXPAND_CHUNK))
	return maxi(0, mini(chunk, _allowed_cells_per_side(terrain)))

## Adds `cells_per_side` cells on every side. World size grows by exactly the
## same number of spacings, so every existing vertex keeps its local position.
static func expand(terrain: Node3D, cells_per_side: int) -> void:
	if cells_per_side <= 0:
		return

	StylePalette.ensure_material_data(terrain)

	var old_resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var old_world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	if old_resolution < 2:
		return

	var spacing: float = old_world_size / float(old_resolution - 1)
	var new_resolution: int = old_resolution + cells_per_side * 2
	var new_world_size: float = old_world_size + float(cells_per_side * 2) * spacing

	var old_mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	var old_heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var old_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	var old_active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())

	var new_mask := PackedFloat32Array()
	new_mask.resize(new_resolution * new_resolution)
	new_mask.fill(0.0)

	var new_heights := PackedFloat32Array()
	new_heights.resize(new_resolution * new_resolution)
	new_heights.fill(0.0)

	for z in range(old_resolution):
		for x in range(old_resolution):
			var old_index: int = GridMath.grid_index(x, z, old_resolution)
			var new_index: int = GridMath.grid_index(x + cells_per_side, z + cells_per_side, new_resolution)
			new_mask[new_index] = old_mask[old_index]
			new_heights[new_index] = old_heights[old_index]
	# The new ground gets the same small bumps as the rest.
	GroundBumps.add(new_heights, new_resolution, new_world_size, GroundBumps.amount(terrain),
		Meta.get_float(terrain, Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN), Meta.get_float(terrain, Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX),
		Rect2i(cells_per_side, cells_per_side, old_resolution, old_resolution))

	var new_styles := PackedInt32Array()
	new_styles.resize((new_resolution - 1) * (new_resolution - 1))
	new_styles.fill(-1)

	var new_active := PackedByteArray()
	new_active.resize((new_resolution - 1) * (new_resolution - 1))
	new_active.fill(0)

	var old_cell_count := (old_resolution - 1) * (old_resolution - 1)
	var old_paint := Meta.vegetation_paint(terrain)
	var new_paint := {}
	for target: Variant in old_paint:
		var old_vegetation: PackedByteArray = old_paint[target]
		if old_vegetation.size() != old_cell_count:
			continue
		var new_vegetation := PackedByteArray()
		new_vegetation.resize((new_resolution - 1) * (new_resolution - 1))
		# New cells: normal density, and bare for the generated-map cells.
		new_vegetation.fill(0 if target == Meta.VEGETATION_GROW else Meta.VEGETATION_NORMAL)
		for z in range(old_resolution - 1):
			for x in range(old_resolution - 1):
				new_vegetation[GridMath.cell_index(x + cells_per_side, z + cells_per_side, new_resolution)] = old_vegetation[GridMath.cell_index(x, z, old_resolution)]
		new_paint[target] = new_vegetation
	Meta.set_optional(terrain, Meta.CELL_VEGETATION, new_paint if not new_paint.is_empty() else null)
	if old_styles.size() == old_cell_count:
		for z in range(old_resolution - 1):
			for x in range(old_resolution - 1):
				var old_cell: int = GridMath.cell_index(x, z, old_resolution)
				var new_cell: int = GridMath.cell_index(x + cells_per_side, z + cells_per_side, new_resolution)
				new_styles[new_cell] = old_styles[old_cell]
				if old_active.size() == old_cell_count:
					new_active[new_cell] = old_active[old_cell]

	terrain.set_meta(Meta.RESOLUTION, new_resolution)
	terrain.set_meta(Meta.WORLD_SIZE, new_world_size)
	terrain.set_meta(Meta.MASK, new_mask)
	terrain.set_meta(Meta.HEIGHTS, new_heights)
	terrain.set_meta(Meta.CELL_STYLES, new_styles)
	terrain.set_meta(Meta.CELL_ACTIVE, new_active)
