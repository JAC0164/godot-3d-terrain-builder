@tool
extends RefCounted
## Builds terrain data from a pixel-art map.
##
## Each pixel becomes one cell:
##   WHITE / transparent -> empty      GREEN -> ground
##   RED                 -> raised     BLUE  -> indented
## Pixels matching none of these (within the colour tolerance) are empty.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const RowBands = preload("row_bands.gd")
const TerrainData = preload("../core/terrain_data.gd")
const GroundBumps = preload("../core/ground_bumps.gd")
const StylePalette = preload("../styles/style_palette.gd")

enum PixelClass { UNKNOWN = -1, EMPTY = 0, GROUND = 1, RAISED = 2, INDENTED = 3 }

const MIN_IMAGE_SIZE := 1
const MAX_IMAGE_SIZE := 256

const _REFERENCE_COLORS := [
	Color(1.0, 1.0, 1.0),
	Color(0.0, 1.0, 0.0),
	Color(1.0, 0.0, 0.0),
	Color(0.0, 0.0, 1.0),
]

## Returns an error message, or "" when the image can be used.
static func validate_image(image: Image) -> String:
	if image == null or image.is_empty():
		return "could not read pixels from the assigned Source Pixel Map."
	var width: int = image.get_width()
	var height: int = image.get_height()
	if width < MIN_IMAGE_SIZE or height < MIN_IMAGE_SIZE or width > MAX_IMAGE_SIZE or height > MAX_IMAGE_SIZE:
		return "source image must be between 1x1 and 256x256 pixels. Got %dx%d." % [width, height]
	return ""

## Nearest reference colour (Chebyshev distance on RGB), as a PixelClass.
static func classify_pixel(color: Color, tolerance: float) -> int:
	if color.a <= 0.01:
		return PixelClass.EMPTY

	var best_index := -1
	var best_error := INF
	for i in range(_REFERENCE_COLORS.size()):
		var reference: Color = _REFERENCE_COLORS[i]
		var error: float = maxf(absf(color.r - reference.r), maxf(absf(color.g - reference.g), absf(color.b - reference.b)))
		if error < best_error:
			best_error = error
			best_index = i

	if best_error > tolerance:
		return PixelClass.UNKNOWN
	return best_index

## Replaces the terrain grid, cells and styles with the image content (data
## only, meshes are not rebuilt). The image must pass validate_image().
## Returns {width, height, green, red, blue, unknown} pixel counts.
static func apply(terrain: Node3D, image: Image) -> Dictionary:
	StylePalette.ensure_material_data(terrain)
	# A texture imported VRAM-compressed: get_pixel() cannot read it.
	if image.is_compressed():
		image = image.duplicate()
		image.decompress()

	var width: int = image.get_width()
	var height: int = image.get_height()
	var side_cells: int = maxi(width, height)
	var resolution: int = side_cells + 1
	var world_size: float = float(side_cells)
	var offset_x: int = (side_cells - width) / 2
	var offset_z: int = (side_cells - height) / 2

	var raise_height: float = clampf(Meta.get_float(terrain, Meta.GENERATOR_RAISE_HEIGHT, Meta.DEFAULT_GENERATOR_RAISE_HEIGHT), 0.0, maxf(0.0, TerrainData.height_max(terrain)))
	var lower_depth: float = maxf(0.0, Meta.get_float(terrain, Meta.GENERATOR_LOWER_DEPTH, Meta.DEFAULT_GENERATOR_LOWER_DEPTH))
	var lower_height: float = clampf(-lower_depth, TerrainData.height_min(terrain), 0.0)
	var tolerance: float = clampf(Meta.get_float(terrain, Meta.GENERATOR_COLOR_TOLERANCE, Meta.DEFAULT_GENERATOR_COLOR_TOLERANCE), 0.0, 0.5)
	var smoothness: float = clampf(Meta.get_float(terrain, Meta.GENERATOR_SMOOTHNESS, 0.0), 0.0, 32.0)

	var cell_active := PackedByteArray()
	cell_active.resize(side_cells * side_cells)
	cell_active.fill(0)

	var desired_cell_heights := PackedFloat32Array()
	desired_cell_heights.resize(side_cells * side_cells)
	desired_cell_heights.fill(0.0)

	var use_single_style: bool = Meta.get_bool(terrain, Meta.GENERATOR_USE_SINGLE_STYLE, true)
	var shared_style_id: int = StylePalette.capture_current_paint_style(terrain)
	var green_style_id: int = shared_style_id if use_single_style else StylePalette.capture_generator_style(terrain, "green")
	var red_style_id: int = shared_style_id if use_single_style else StylePalette.capture_generator_style(terrain, "red")
	var blue_style_id: int = shared_style_id if use_single_style else StylePalette.capture_generator_style(terrain, "blue")

	var cell_styles := PackedInt32Array()
	cell_styles.resize(side_cells * side_cells)
	cell_styles.fill(-1)

	var stats := {"width": width, "height": height, "green": 0, "red": 0, "blue": 0, "unknown": 0}

	for image_y in range(height):
		for image_x in range(width):
			var pixel: Color = image.get_pixel(image_x, image_y)
			var cell_index: int = (offset_z + image_y) * side_cells + (offset_x + image_x)

			match classify_pixel(pixel, tolerance):
				PixelClass.EMPTY:
					pass
				PixelClass.GROUND:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = green_style_id
					desired_cell_heights[cell_index] = 0.0
					stats["green"] += 1
				PixelClass.RAISED:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = red_style_id
					desired_cell_heights[cell_index] = raise_height
					stats["red"] += 1
				PixelClass.INDENTED:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = blue_style_id
					desired_cell_heights[cell_index] = lower_height
					stats["blue"] += 1
				_:
					stats["unknown"] += 1

	# Smooth RED/BLUE regions before converting cell targets to shared grid
	# vertices. Large regions keep their requested peak/depth in the interior;
	# small regions naturally become rounded hills or dents.
	desired_cell_heights = smooth_cell_heights(cell_active, desired_cell_heights, side_cells, smoothness)

	var vertex_data := cell_heights_to_vertices(cell_active, desired_cell_heights, side_cells)

	write_grid(terrain, resolution, world_size, vertex_data, cell_active, cell_styles)
	# The terrain's small bumps (Look > Ground Bumps) on the new map too.
	GroundBumps.add_to_terrain(terrain, GroundBumps.amount(terrain))

	if Meta.get_bool(terrain, Meta.GENERATOR_CLEAR_FEATURES, true):
		terrain.set_meta(Meta.ROADS, [])
		terrain.set_meta(Meta.RIVERS, [])
		# The old map's waterholes too (as Generate Map): they would sit on
		# the new grid at random.
		terrain.set_meta(Meta.WATERHOLES, [])

	return stats

## Writes a generated grid onto the terrain (also used by MapGenerator):
## size, vertex mask and heights (from cell_heights_to_vertices()), cells,
## their ground styles, and a fresh vegetation paint: the biome grows on the
## whole new map, no brush strokes from the previous one.
static func write_grid(terrain: Node3D, resolution: int, world_size: float, vertices: Dictionary,
		cell_active: PackedByteArray, cell_styles: PackedInt32Array) -> void:
	terrain.set_meta(Meta.RESOLUTION, resolution)
	terrain.set_meta(Meta.WORLD_SIZE, world_size)
	terrain.set_meta(Meta.MASK, vertices["mask"])
	terrain.set_meta(Meta.HEIGHTS, vertices["heights"])
	terrain.set_meta(Meta.CELL_ACTIVE, cell_active)
	terrain.set_meta(Meta.CELL_VEGETATION, Meta.generated_vegetation(cell_active))
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)
	terrain.set_meta(Meta.MAX_RESOLUTION, maxi(Meta.get_int(terrain, Meta.MAX_RESOLUTION, Meta.DEFAULT_MAX_RESOLUTION), resolution))

## Neighbouring cells share terrain vertices. Each vertex takes the average
## requested height of the active cells touching it, so class boundaries become
## clean editable slopes instead of cracked duplicate geometry.
## Returns {"mask": PackedFloat32Array, "heights": PackedFloat32Array}.
## Bands of vertex rows run in parallel (RowBands).
static func cell_heights_to_vertices(cell_active: PackedByteArray, cell_heights: PackedFloat32Array, side_cells: int) -> Dictionary:
	var parts := RowBands.run(side_cells + 1, _vertex_rows.bind(cell_active, cell_heights, side_cells))
	var heights := PackedFloat32Array()
	var mask := PackedFloat32Array()
	for part: Array in parts:
		var part_heights: PackedFloat32Array = part[0]
		var part_mask: PackedFloat32Array = part[1]
		heights.append_array(part_heights)
		mask.append_array(part_mask)
	return {"mask": mask, "heights": heights}

## [heights, mask] of vertex rows `from` to `to`. The active cells around a
## vertex are summed in the same order as always (up-left, up, left, self),
## so the averages are the same to the bit.
static func _vertex_rows(from: int, to: int, cell_active: PackedByteArray, cell_heights: PackedFloat32Array, side_cells: int) -> Array:
	var resolution: int = side_cells + 1
	var heights := PackedFloat32Array()
	heights.resize((to - from) * resolution)
	heights.fill(0.0)
	var mask := PackedFloat32Array()
	mask.resize(heights.size())
	mask.fill(0.0)
	for vz in range(from, to):
		var up := (vz - 1) * side_cells
		var down := vz * side_cells
		var has_up := vz > 0
		var has_down := vz < side_cells
		var out := (vz - from) * resolution
		for vx in range(resolution):
			var sum_height := 0.0
			var active_neighbors := 0
			var has_left := vx > 0
			var has_right := vx < side_cells
			if has_up:
				if has_left and cell_active[up + vx - 1] != 0:
					sum_height += cell_heights[up + vx - 1]
					active_neighbors += 1
				if has_right and cell_active[up + vx] != 0:
					sum_height += cell_heights[up + vx]
					active_neighbors += 1
			if has_down:
				if has_left and cell_active[down + vx - 1] != 0:
					sum_height += cell_heights[down + vx - 1]
					active_neighbors += 1
				if has_right and cell_active[down + vx] != 0:
					sum_height += cell_heights[down + vx]
					active_neighbors += 1
			if active_neighbors > 0:
				heights[out + vx] = sum_height / float(active_neighbors)
				mask[out + vx] = 1.0
	return [heights, mask]

## Scales each raised/indented cell by its distance (in cells) to the region
## edge, over `smoothness` cells. 0 keeps regions flat.
## Bands of rows run in parallel (RowBands). The factor is 1 from
## `smoothness` cells on, so each band only needs the rows within
## ceil(smoothness) of it: the values are the same as one pass over the map.
static func smooth_cell_heights(
	cell_active: PackedByteArray,
	desired: PackedFloat32Array,
	side_cells: int,
	smoothness: float
) -> PackedFloat32Array:
	if smoothness <= 0.001 or side_cells <= 0:
		return desired.duplicate()
	var reach := ceili(smoothness)
	return RowBands.join_floats(RowBands.run(side_cells, _smooth_rows.bind(cell_active, desired, side_cells, smoothness, reach)))

## Smoothed heights of rows `from` to `to`, from a distance transform over
## those rows and `reach` rows on each side.
static func _smooth_rows(from: int, to: int, cell_active: PackedByteArray, desired: PackedFloat32Array,
		side_cells: int, smoothness: float, reach: int) -> PackedFloat32Array:
	var first := maxi(from - reach, 0)
	var rows := mini(to + reach, side_cells) - first
	var offset := first * side_cells
	var far := side_cells * 4 + 1024
	# Distance (in cells) of each raised cell to the nearest cell that is not
	# raised, as a positive number; of each indented cell to the nearest one
	# that is not indented, as a negative number; 0 elsewhere. A neighbour of
	# the other sign counts as 0, as if each sign had its own array.
	var distance := PackedInt32Array()
	distance.resize(rows * side_cells)
	distance.fill(0)
	for i in range(distance.size()):
		if cell_active[offset + i] == 0:
			continue
		var value := desired[offset + i]
		if value > 0.0001:
			distance[i] = far
		elif value < -0.0001:
			distance[i] = -far

	# Two-pass Manhattan distance transform.
	for z in range(rows):
		var row := z * side_cells
		for x in range(side_cells):
			var i := row + x
			var d := distance[i]
			if d == 0:
				continue
			if d > 0:
				if x > 0:
					d = mini(d, maxi(distance[i - 1], 0) + 1)
				if z > 0:
					d = mini(d, maxi(distance[i - side_cells], 0) + 1)
			else:
				if x > 0:
					d = maxi(d, mini(distance[i - 1], 0) - 1)
				if z > 0:
					d = maxi(d, mini(distance[i - side_cells], 0) - 1)
			distance[i] = d
	for z in range(rows - 1, -1, -1):
		var row := z * side_cells
		for x in range(side_cells - 1, -1, -1):
			var i := row + x
			var d := distance[i]
			if d == 0:
				continue
			if d > 0:
				if x < side_cells - 1:
					d = mini(d, maxi(distance[i + 1], 0) + 1)
				if z < rows - 1:
					d = mini(d, maxi(distance[i + side_cells], 0) + 1)
			else:
				if x < side_cells - 1:
					d = maxi(d, mini(distance[i + 1], 0) - 1)
				if z < rows - 1:
					d = maxi(d, mini(distance[i + side_cells], 0) - 1)
			distance[i] = d

	var result := desired.slice(from * side_cells, to * side_cells)
	var skip := (from - first) * side_cells
	for i in range(result.size()):
		var d := distance[skip + i]
		if d == 0:
			continue
		var factor := clampf(float(absi(d)) / maxf(smoothness, 0.001), 0.0, 1.0)
		factor = smoothstep(0.0, 1.0, factor)
		result[i] = desired[from * side_cells + i] * factor
	return result
