@tool
extends RefCounted
## Ground edits made by a game (LowpolyTerrainRuntime.set_height /
## raise_area / flatten_area / paint_style), and their save format
## (export_edits / import_edits). Pure data in terrain-local space, like the
## editor's Brush: the runtime rebuilds the meshes (commit_edits).
## Heights are ground levels before the river carve (the drawn height under a
## river bed is lower), kept within the terrain's height range.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const TerrainSnapshot = preload("../core/terrain_snapshot.gd")

enum Op { RAISE, FLATTEN }

## Most bytes import() unpacks (a 4097 x 4097 map edited everywhere is less).
const MAX_UNPACKED := 256 * 1024 * 1024
## First 4 bytes of export_edits() data ("LTE1"), then the unpacked size.
const FORMAT := 0x3145544C

## Vertex heights inside the circle: RAISE adds `value` (m) times the brush
## falloff (whole at the centre, none at the edge), FLATTEN blends towards the
## level `value` by it. Returns the terrain-local X / Z rectangle of the
## vertices that changed, empty when none did.
static func shape(terrain: Node3D, op: Op, center: Vector2, radius: float, value: float) -> Rect2:
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size := Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	if resolution < 2 or heights.size() != resolution * resolution or radius <= 0.0:
		return Rect2()
	var low := TerrainData.height_min(terrain)
	var high := TerrainData.height_max(terrain)
	var top_offset := Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var target := value - top_offset
	var spacing := world_size / float(resolution - 1)
	var grid := GridMath.local_to_grid(center, resolution, world_size)
	var reach := radius / spacing
	var changed := Rect2i()
	for z in range(maxi(int(floorf(grid.y - reach)), 0), mini(int(ceilf(grid.y + reach)), resolution - 1) + 1):
		for x in range(maxi(int(floorf(grid.x - reach)), 0), mini(int(ceilf(grid.x + reach)), resolution - 1) + 1):
			var point := GridMath.grid_to_local(x, z, resolution, world_size)
			var distance := Vector2(point.x, point.z).distance_to(center)
			if distance > radius:
				continue
			var falloff := GridMath.brush_falloff(distance, radius)
			var index := z * resolution + x
			var before := heights[index]
			var after := before + value * falloff if op == Op.RAISE else lerpf(before, target, falloff)
			after = clampf(after, low, high)
			if after != before:
				heights[index] = after
				changed = _grow(changed, Vector2i(x, z))
	if not changed.has_area():
		return Rect2()
	terrain.set_meta(Meta.HEIGHTS, heights)
	return vertex_rect_to_local(changed, resolution, world_size)

## The ground level of the vertex nearest `point` set to `level`.
static func set_level(terrain: Node3D, point: Vector2, level: float) -> Rect2:
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size := Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	if resolution < 2 or heights.size() != resolution * resolution:
		return Rect2()
	var grid := GridMath.local_to_grid(point, resolution, world_size)
	var x := clampi(roundi(grid.x), 0, resolution - 1)
	var z := clampi(roundi(grid.y), 0, resolution - 1)
	var index := z * resolution + x
	var after := clampf(level - Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0), TerrainData.height_min(terrain), TerrainData.height_max(terrain))
	if heights[index] == after:
		return Rect2()
	heights[index] = after
	terrain.set_meta(Meta.HEIGHTS, heights)
	return vertex_rect_to_local(Rect2i(x, z, 1, 1), resolution, world_size)

## Palette style `style` on the cells whose centre is inside the circle (at
## least the cell under `center`). Returns the changed cells' rectangle.
static func paint(terrain: Node3D, center: Vector2, radius: float, style: int) -> Rect2:
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size := Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	var cells := resolution - 1
	if cells < 1 or styles.size() != cells * cells or style < 0 or style >= palette.size():
		return Rect2()
	var spacing := world_size / float(cells)
	var half := world_size * 0.5
	var reach := radius / spacing + 1.0
	var cx := (center.x + half) / spacing - 0.5
	var cz := (center.y + half) / spacing - 0.5
	var under := Vector2i(clampi(int(floorf(cx + 0.5)), 0, cells - 1), clampi(int(floorf(cz + 0.5)), 0, cells - 1))
	var changed := Rect2i()
	for z in range(maxi(int(floorf(cz - reach)), 0), mini(int(ceilf(cz + reach)), cells - 1) + 1):
		for x in range(maxi(int(floorf(cx - reach)), 0), mini(int(ceilf(cx + reach)), cells - 1) + 1):
			var cell_centre := Vector2((float(x) + 0.5) * spacing - half, (float(z) + 0.5) * spacing - half)
			if cell_centre.distance_to(center) > radius and Vector2i(x, z) != under:
				continue
			var index := z * cells + x
			if styles[index] != style:
				styles[index] = style
				changed = _grow(changed, Vector2i(x, z))
	if not changed.has_area():
		return Rect2()
	terrain.set_meta(Meta.CELL_STYLES, styles)
	# A cell's corners are its vertices: one more row / column of them.
	return vertex_rect_to_local(Rect2i(changed.position, changed.size + Vector2i.ONE), resolution, world_size)

## Copy of the data the edits change (what export() compares with).
static func base_of(terrain: Node3D) -> Dictionary:
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	return {"heights": heights.duplicate(), "cell_styles": styles.duplicate()}

## What changed since `base` (base_of), small: the rectangle of heights and
## the rectangle of cell styles that differ, zstd-packed. Empty when nothing
## changed or the grid size changed.
static func export_edits(terrain: Node3D, base: Dictionary) -> PackedByteArray:
	if base.is_empty():
		return PackedByteArray()
	var current := base_of(terrain)
	var common := {
		"resolution": Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION),
		"world_size": Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE),
		# Same arrays on both sides (never changed by the edits).
		"mask": terrain.get_meta(Meta.MASK, PackedFloat32Array()),
		"cell_active": terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray()),
	}
	var before := common.duplicate()
	before.merge(base)
	var after := common.duplicate()
	after.merge(current)
	var pair := TerrainSnapshot.delta_pair(before, after)
	if pair.is_empty() or not (pair[1].has("vertex_rect") or pair[1].has("cell_rect")):
		return PackedByteArray()
	var delta := pair[1]
	delta.erase("mask")
	delta.erase("cell_active")
	var bytes := var_to_bytes(delta)
	# The unpacked size first: zstd data needs it to be unpacked.
	var header := PackedByteArray()
	header.resize(8)
	header.encode_u32(0, FORMAT)
	header.encode_u32(4, bytes.size())
	return header + bytes.compress(FileAccess.COMPRESSION_ZSTD)

## Puts export_edits() data back on the terrain (same map, same grid size).
## Returns the terrain-local rectangle it changed, or null when `data` is not
## edits of this terrain.
static func import_edits(terrain: Node3D, data: PackedByteArray) -> Variant:
	if data.size() <= 8 or data.decode_u32(0) != FORMAT:
		return null
	var size := data.decode_u32(4)
	if size == 0 or size > MAX_UNPACKED:
		return null
	var unpacked := data.slice(8).decompress(size, FileAccess.COMPRESSION_ZSTD)
	# No objects decoded: only plain data comes out of a save file.
	var value: Variant = bytes_to_var(unpacked) if not unpacked.is_empty() else null
	if not (value is Dictionary):
		return null
	var delta: Dictionary = value
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size := Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var saved_resolution: Variant = delta.get("resolution")
	var saved_world_size: Variant = delta.get("world_size")
	if not delta.get("delta", false) or not (saved_resolution is int) or saved_resolution != resolution or not (saved_world_size is float):
		return null
	var saved_size: float = saved_world_size
	if not is_equal_approx(saved_size, world_size):
		return null
	var area := Rect2()
	for key: String in ["vertex_rect", "cell_rect"]:
		var rect_value: Variant = delta.get(key)
		if rect_value == null:
			continue
		if not (rect_value is Rect2i):
			return null
		var rect: Rect2i = rect_value
		var width := resolution if key == "vertex_rect" else resolution - 1
		var grid_key := "heights" if key == "vertex_rect" else "cell_styles"
		var block_value: Variant = delta.get(grid_key)
		if rect.position.x < 0 or rect.position.y < 0 or rect.end.x > width or rect.end.y > width or not (block_value is PackedByteArray):
			return null
		var block: PackedByteArray = block_value
		if block.size() != rect.size.x * rect.size.y * 4:
			return null
		var vertices := rect if key == "vertex_rect" else Rect2i(rect.position, rect.size + Vector2i.ONE)
		var local := vertex_rect_to_local(vertices, resolution, world_size)
		area = local if not area.has_area() else area.merge(local)
	# Only what this format holds (heights, cell styles) is written.
	for key: String in delta.keys():
		if not key in ["delta", "resolution", "world_size", "vertex_rect", "cell_rect", "heights", "cell_styles"]:
			delta.erase(key)
	TerrainSnapshot.apply(terrain, delta)
	return area

## Terrain-local X / Z rectangle of the cells around a vertex rectangle (the
## faces those vertices belong to).
static func vertex_rect_to_local(rect: Rect2i, resolution: int, world_size: float) -> Rect2:
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	return Rect2(float(rect.position.x - 1) * spacing - half, float(rect.position.y - 1) * spacing - half,
		float(rect.size.x + 1) * spacing, float(rect.size.y + 1) * spacing)

static func _grow(rect: Rect2i, point: Vector2i) -> Rect2i:
	if not rect.has_area():
		return Rect2i(point, Vector2i.ONE)
	return rect.expand(point).expand(point + Vector2i.ONE)
